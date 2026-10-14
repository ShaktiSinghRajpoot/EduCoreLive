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


-- ── money when a student leaves / comes back ───────────────────────────────
-- Depends on student_money_lifecycle.sql (fn_student_close_future_dues,
-- fn_student_restore_closed_dues and the close columns).
--
-- Leaving: every instalment due AFTER the leaving date is CLOSED (never
-- deleted) with the reason 'Left on <date>', who and when, and the bus
-- assignment ends. Dues up to the leaving date stay owed. Before this, tuition
-- and bus fees for every month to March stayed on a leaver's ledger, and the TC
-- was refused for months the child never attended.
--
-- Coming back (Reactivate): exactly what the exit closed is put back — the rows
-- closed with close_source 'Exit' and the bus assignment ended by it.
CREATE OR REPLACE FUNCTION core.fn_student_leave_money(
    p_tenant_id      integer,
    p_school_id      integer,
    p_student_id     integer,
    p_date_of_leaving date,
    p_action_user_id integer)
RETURNS numeric
LANGUAGE plpgsql
AS $$
DECLARE
    v_reason varchar(200) := 'Left on ' || to_char(p_date_of_leaving, 'YYYY-MM-DD');
    v_closed numeric(12,2);
BEGIN
    v_closed := core.fn_student_close_future_dues(
        p_tenant_id, p_school_id, p_student_id, p_date_of_leaving,
        v_reason, 'Exit', p_action_user_id);

    UPDATE core.student_transport
       SET is_active  = FALSE,
           end_reason = v_reason,
           ended_by   = p_action_user_id,
           ended_at   = now(),
           updated_by = p_action_user_id,
           updated_at = now()
     WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
       AND is_active = TRUE;

    RETURN v_closed;
END;
$$;

CREATE OR REPLACE FUNCTION core.fn_student_return_money(
    p_tenant_id      integer,
    p_school_id      integer,
    p_student_id     integer,
    p_action_user_id integer)
RETURNS numeric
LANGUAGE plpgsql
AS $$
DECLARE
    v_restored numeric(12,2);
    v_assign   integer;
BEGIN
    v_restored := core.fn_student_restore_closed_dues(p_tenant_id, p_school_id, p_student_id, 'Exit');

    -- The bus assignment the exit ended (the latest one), if it was not
    -- replaced by another since.
    SELECT assignment_id INTO v_assign
      FROM core.student_transport
     WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
       AND is_active = FALSE AND COALESCE(is_deleted, FALSE) = FALSE
       AND end_reason LIKE 'Left on %'
     ORDER BY assignment_id DESC
     LIMIT 1;

    IF v_assign IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM core.student_transport
         WHERE student_id = p_student_id AND is_active = TRUE) THEN
        UPDATE core.student_transport
           SET is_active  = TRUE,
               end_reason = NULL, ended_by = NULL, ended_at = NULL,
               updated_by = p_action_user_id, updated_at = now()
         WHERE assignment_id = v_assign;
    END IF;

    RETURN v_restored;
END;
$$;


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
    v_closed numeric(12,2);
    s        core.students%ROWTYPE;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    SELECT * INTO s
    FROM core.students
    WHERE student_id = p_student_id
      AND tenant_id  = p_tenant_id
      AND school_id  = p_school_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Student not found.';
    END IF;
    v_name := s.student_name; v_active := s.is_active; v_year := s.academic_year;

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

        -- Instalments after the leaving date are closed and the bus ends.
        v_closed := core.fn_student_leave_money(
            p_tenant_id, p_school_id, p_student_id, p_date_of_leaving, p_action_user_id);

        -- What is still owed (up to the leaving date) does NOT block the exit:
        -- the student has physically left either way. It is reported so the
        -- office can chase it, and the TC step checks it again.
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

        INSERT INTO core.admission_audit (tenant_id, school_id, student_id, action, detail, action_by)
        VALUES (p_tenant_id, p_school_id, p_student_id, 'StudentExited',
                TRIM(p_status) || ' on ' || to_char(p_date_of_leaving, 'YYYY-MM-DD') ||
                COALESCE(' (' || NULLIF(TRIM(p_reason), '') || ')', '') ||
                '; ' || to_char(v_closed, 'FM99999990.00') || ' of later dues closed' ||
                '; ' || to_char(GREATEST(v_dues, 0), 'FM99999990.00') || ' still owed',
                p_action_user_id);

        OPEN p_result FOR
        SELECT TRUE AS success,
               v_name || ' marked as ' || TRIM(p_status) || '.' ||
               CASE WHEN v_closed > 0
                    THEN ' Rs ' || to_char(v_closed, 'FM99,99,99,990.00') || ' of fees due after the leaving date closed.'
                    ELSE '' END AS message,
               GREATEST(v_dues, 0) AS outstanding,
               v_closed AS closed_amount;

    ELSIF p_operation = 'Undo' THEN
        IF v_active THEN
            RAISE EXCEPTION '% is already an active student.', v_name;
        END IF;

        -- A live TC says the child has left. Void it first, so the register
        -- and the roll never disagree.
        IF EXISTS (SELECT 1 FROM core.tc_register
                    WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                      AND student_id = p_student_id AND is_void = FALSE) THEN
            RAISE EXCEPTION 'A Transfer Certificate has been issued for %. Void it before re-activating.', v_name;
        END IF;

        v_closed := core.fn_student_return_money(p_tenant_id, p_school_id, p_student_id, p_action_user_id);

        -- The exit details are cleared on the student row (they describe a
        -- leaving that no longer stands) but kept here, with the restore.
        INSERT INTO core.admission_audit (tenant_id, school_id, student_id, action, detail, action_by)
        VALUES (p_tenant_id, p_school_id, p_student_id, 'StudentReactivated',
                'Was ' || COALESCE(s.status, '?') || ' on ' || COALESCE(s.date_of_leaving::text, '?') ||
                COALESCE(' (' || s.leaving_reason || ')', '') ||
                ', recorded by user ' || COALESCE(s.exit_recorded_by::text, '?') ||
                ' at ' || COALESCE(LEFT(s.exit_recorded_at::text, 16), '?') ||
                '; ' || to_char(v_closed, 'FM99999990.00') || ' of dues restored',
                p_action_user_id);

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
               v_name || ' re-activated.' ||
               CASE WHEN v_closed > 0
                    THEN ' Rs ' || to_char(v_closed, 'FM99,99,99,990.00') || ' of dues closed at exit restored.'
                    ELSE '' END AS message,
               0::numeric AS outstanding,
               v_closed AS closed_amount;
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
                -- The uuid opens the (read-only) Student Dashboard of a leaver;
                -- has_tc stops the page offering a second TC.
                s.public_id,
                EXISTS (SELECT 1 FROM core.tc_register t
                         WHERE t.student_id = s.student_id AND t.tenant_id = s.tenant_id
                           AND t.school_id = s.school_id AND NOT t.is_void) AS has_tc,
                COALESCE((
                    SELECT SUM(l.amount_due - l.amount_paid - COALESCE(l.concession, 0))
                    FROM core.student_ledger l
                    WHERE l.student_id = s.student_id
                ), 0) AS outstanding
            FROM core.students s
            WHERE s.tenant_id = p_tenant_id
              AND s.school_id = p_school_id
              AND s.is_active = FALSE
              -- strpos, not LIKE: a typed % or _ is a character, not a wildcard.
              AND (
                  p_search IS NULL OR TRIM(p_search) = ''
                  OR strpos(LOWER(s.student_name), LOWER(TRIM(p_search))) > 0
                  OR strpos(LOWER(s.admission_no), LOWER(TRIM(p_search))) > 0
                  OR strpos(COALESCE(s.mobile, ''), TRIM(p_search)) > 0
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
            date_of_leaving, status, leaving_reason, public_id, has_tc,
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
