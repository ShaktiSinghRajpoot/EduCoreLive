-- ============================================================================
-- Student exit flow — the foundation the Transfer Certificate sits on.
--
-- A student who leaves is NOT deleted: the record stays, is_active goes FALSE
-- and status records how they left. Fee ledger, receipts and (later) the TC
-- register all keep pointing at the same student_id.
--
--   core.sp_student_exit        mark a student as left (or undo it)
--   core.sp_student_exit_list   the real "Inactive / Left" list
--
-- status values used here:
--   Active     still studying
--   Transfer   left for another school   -> eligible for a TC
--   Passout    completed the final class -> eligible for a TC
--   Struck Off removed by the school (long absence, discipline)
--   Withdrawn  parents withdrew, no TC sought
-- ============================================================================

-- ── columns ────────────────────────────────────────────────────────────────
ALTER TABLE core.students
    ADD COLUMN IF NOT EXISTS date_of_leaving  date,
    ADD COLUMN IF NOT EXISTS leaving_reason   varchar(300),
    ADD COLUMN IF NOT EXISTS exit_recorded_by integer,
    ADD COLUMN IF NOT EXISTS exit_recorded_at timestamptz;

COMMENT ON COLUMN core.students.date_of_leaving IS
    'Last day at this school. Printed on the TC, so it is set once at exit.';


-- ── mark / unmark a student as left ────────────────────────────────────────
CREATE OR REPLACE PROCEDURE core.sp_student_exit(
    IN  p_operation      varchar,    -- 'Exit' | 'Undo'
    IN  p_tenant_id      integer,
    IN  p_school_id      integer,
    IN  p_action_user_id integer,
    IN  p_student_id     integer,
    IN  p_status         varchar DEFAULT NULL,  -- Transfer | Passout | Struck Off | Withdrawn
    IN  p_date_of_leaving date   DEFAULT NULL,
    IN  p_reason         varchar DEFAULT NULL,
    INOUT p_result       refcursor DEFAULT 'student_exit_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_name   varchar;
    v_active boolean;
    v_year   varchar;   -- session the student is sitting in (for the enrolment row)
    v_dues   numeric(12,2);
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    SELECT student_name, is_active, academic_year INTO v_name, v_active, v_year
    FROM core.students
    WHERE student_id = p_student_id
      AND tenant_id  = p_tenant_id
      AND school_id  = p_school_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Student not found.';
    END IF;

    IF p_operation = 'Exit' THEN
        IF NOT v_active THEN
            RAISE EXCEPTION '% has already left.', v_name;
        END IF;

        IF COALESCE(TRIM(p_status), '') NOT IN ('Transfer', 'Passout', 'Struck Off', 'Withdrawn') THEN
            RAISE EXCEPTION 'Choose how the student left.';
        END IF;

        IF p_date_of_leaving IS NULL THEN
            RAISE EXCEPTION 'Date of leaving is required.';
        END IF;

        -- Outstanding dues do NOT block the exit: the student has physically left
        -- either way, and pretending otherwise loses the record. The dues are
        -- reported so the office can chase them, and the TC step checks them again.
        SELECT COALESCE(SUM(l.amount_due - l.amount_paid - COALESCE(l.concession, 0)), 0)
        INTO v_dues
        FROM core.student_ledger l
        WHERE l.student_id = p_student_id;

        UPDATE core.students
        SET status           = TRIM(p_status),
            is_active        = FALSE,
            date_of_leaving  = p_date_of_leaving,
            leaving_reason   = NULLIF(TRIM(p_reason), ''),
            exit_recorded_by = p_action_user_id,
            exit_recorded_at = now(),
            updated_by       = p_action_user_id,
            updated_at       = now()
        WHERE student_id = p_student_id;

        -- Close the session they were in. is_current stays TRUE: this is still
        -- their latest enrolment, it just ended early.
        PERFORM core.fn_student_enrolment_close(
            p_student_id, v_year,
            CASE WHEN TRIM(p_status) = 'Passout' THEN 'PassedOut' ELSE 'Left' END,
            p_action_user_id);

        OPEN p_result FOR
        SELECT TRUE AS success,
               v_name || ' marked as ' || TRIM(p_status) || '.' AS message,
               GREATEST(v_dues, 0) AS outstanding;

    ELSIF p_operation = 'Undo' THEN
        IF v_active THEN
            RAISE EXCEPTION '% is already an active student.', v_name;
        END IF;

        UPDATE core.students
        SET status           = 'Active',
            is_active        = TRUE,
            date_of_leaving  = NULL,
            leaving_reason   = NULL,
            exit_recorded_by = NULL,
            exit_recorded_at = NULL,
            updated_by       = p_action_user_id,
            updated_at       = now()
        WHERE student_id = p_student_id;

        -- Put them back on the roll for the session they were in.
        PERFORM core.fn_student_enrolment_close(
            p_student_id, v_year, 'Active', p_action_user_id);

        OPEN p_result FOR
        SELECT TRUE AS success,
               v_name || ' re-activated.' AS message,
               0::numeric AS outstanding;
    ELSE
        RAISE EXCEPTION 'Unknown operation %.', p_operation;
    END IF;
END;
$procedure$;


-- ── the "Inactive / Left" list ─────────────────────────────────────────────
-- Same shape as sp_student_list: search + filters + whitelisted sort +
-- pagination, with window aggregates so the tiles stay right across pages.
CREATE OR REPLACE PROCEDURE core.sp_student_exit_list(
    IN  p_tenant_id      integer,
    IN  p_school_id      integer,
    IN  p_action_user_id integer,
    IN  p_search         text    DEFAULT NULL,
    IN  p_filter_status  text    DEFAULT NULL,   -- Transfer | Passout | Struck Off | Withdrawn
    IN  p_filter_dues    text    DEFAULT NULL,   -- 'pending' | 'clear'
    IN  p_page_no        integer DEFAULT 1,
    IN  p_page_size      integer DEFAULT 10,
    IN  p_sort_column    text    DEFAULT NULL,
    IN  p_sort_dir       text    DEFAULT 'desc',
    INOUT p_result       refcursor DEFAULT 'student_exit_list_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_offset integer;
    v_col    text;
    v_asc    boolean;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        OPEN p_result FOR SELECT WHERE FALSE;
        RETURN;
    END IF;

    v_offset := (GREATEST(COALESCE(p_page_no, 1), 1) - 1) * COALESCE(p_page_size, 10);
    v_col    := LOWER(TRIM(COALESCE(p_sort_column, '')));
    v_asc    := LOWER(TRIM(COALESCE(p_sort_dir, 'desc'))) <> 'desc';

    OPEN p_result FOR
        WITH filtered AS (
            SELECT
                s.student_id, s.admission_no, s.student_name,
                s.class_name, s.section, s.academic_year,
                s.guardian_name, s.mobile,
                s.admission_date, s.date_of_leaving,
                s.status, s.leaving_reason,
                COALESCE((
                    SELECT SUM(l.amount_due - l.amount_paid - COALESCE(l.concession, 0))
                    FROM core.student_ledger l
                    WHERE l.student_id = s.student_id
                ), 0) AS outstanding
            FROM core.students s
            WHERE s.tenant_id = p_tenant_id
              AND s.school_id = p_school_id
              AND s.is_active = FALSE
              AND (
                  p_search IS NULL OR TRIM(p_search) = ''
                  OR LOWER(s.student_name) LIKE '%' || LOWER(TRIM(p_search)) || '%'
                  OR LOWER(s.admission_no) LIKE '%' || LOWER(TRIM(p_search)) || '%'
                  OR COALESCE(s.mobile, '') LIKE '%' || TRIM(p_search) || '%'
              )
              AND (p_filter_status IS NULL OR TRIM(p_filter_status) = ''
                   OR LOWER(s.status) = LOWER(TRIM(p_filter_status)))
        ),
        scored AS (
            SELECT * FROM filtered f
            WHERE p_filter_dues IS NULL OR TRIM(p_filter_dues) = ''
               OR (LOWER(TRIM(p_filter_dues)) = 'pending' AND f.outstanding > 0)
               OR (LOWER(TRIM(p_filter_dues)) = 'clear'   AND f.outstanding <= 0)
        )
        SELECT
            student_id, admission_no, student_name, class_name, section,
            academic_year, guardian_name, mobile, admission_date,
            date_of_leaving, status, leaving_reason,
            GREATEST(outstanding, 0) AS outstanding,
            COUNT(*)                                                        OVER() AS total_count,
            COUNT(*) FILTER (WHERE status = 'Transfer')                     OVER() AS transfer_count,
            COUNT(*) FILTER (WHERE status = 'Passout')                      OVER() AS passout_count,
            COUNT(*) FILTER (WHERE outstanding > 0)                         OVER() AS dues_count
        FROM scored
        ORDER BY
            CASE WHEN v_col = 'name'  AND v_asc     THEN student_name    END ASC,
            CASE WHEN v_col = 'name'  AND NOT v_asc THEN student_name    END DESC,
            CASE WHEN v_col = 'left'  AND v_asc     THEN date_of_leaving END ASC,
            CASE WHEN v_col = 'left'  AND NOT v_asc THEN date_of_leaving END DESC,
            CASE WHEN v_col = 'dues'  AND v_asc     THEN outstanding     END ASC,
            CASE WHEN v_col = 'dues'  AND NOT v_asc THEN outstanding     END DESC,
            -- Default: most recently left first.
            date_of_leaving DESC NULLS LAST, student_id DESC
        LIMIT  COALESCE(p_page_size, 10)
        OFFSET v_offset;
    RETURN;
END;
$procedure$;
