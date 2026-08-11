-- ============================================================================
-- Bulk student promotion — moving a class into the next academic session.
--
-- core.students holds ONE row per student: class_name, section and
-- academic_year live on that row, and there is no per-year enrolment table.
-- The unique (tenant_id, school_id, admission_no) constraint also forbids a
-- second row for the same student in a new year. So promotion is an in-place
-- UPDATE of the student row, exactly like the exit flow: the student_id never
-- changes, so the fee ledger, receipts and TC register keep pointing at it.
--
-- History is kept separately in core.student_promotion_history, because the
-- student row itself remembers nothing about the class it came from.
--
--   core.student_promotion_history  one row per student per promotion run
--   core.sp_class_ladder            classes in real teaching order
--   core.sp_student_promote         the promotion itself
--
-- outcome values:
--   Promote   moved up to the next class in the ladder, new session
--   Retain    stays in the same class, new session
--   PassOut   completed the final class -> inactive, TC-eligible
-- ============================================================================

-- ── history ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS core.student_promotion_history (
    promotion_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     integer      NOT NULL,
    school_id     integer      NOT NULL,
    student_id    integer      NOT NULL REFERENCES core.students(student_id) ON DELETE CASCADE,
    from_year     varchar(20)  NOT NULL,
    from_class    varchar(50)  NOT NULL,
    from_section  varchar(20),
    to_year       varchar(20)  NOT NULL,
    to_class      varchar(50),
    to_section    varchar(20),
    outcome       varchar(20)  NOT NULL,
    dues_carried  numeric(12,2) NOT NULL DEFAULT 0,
    promoted_by   integer      NOT NULL DEFAULT 0,
    promoted_at   timestamptz  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_student_promotion_history_student
    ON core.student_promotion_history (student_id);
CREATE INDEX IF NOT EXISTS idx_student_promotion_history_year
    ON core.student_promotion_history (tenant_id, school_id, to_year);

COMMENT ON TABLE core.student_promotion_history IS
    'Audit trail of promotions. The student row is updated in place, so this is the only record of which class a student came from.';
COMMENT ON COLUMN core.student_promotion_history.dues_carried IS
    'Outstanding balance at the moment of promotion. The ledger is not year-scoped, so the dues simply follow the student; this is the snapshot.';


-- ── the class ladder ───────────────────────────────────────────────────────
-- config.sp_dropdown_common returns classes newest-id-first, which is NOT
-- teaching order — using it to work out "the next class" walks DOWN the
-- school. display_order is the column meant for this, so promotion (and the
-- page's "next class" preview) reads the ladder from here instead.
CREATE OR REPLACE PROCEDURE core.sp_class_ladder(
    IN  p_tenant_id      integer,
    IN  p_school_id      integer,
    IN  p_action_user_id integer,
    INOUT p_result       refcursor DEFAULT 'class_ladder_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        OPEN p_result FOR SELECT WHERE FALSE;
        RETURN;
    END IF;

    OPEN p_result FOR
    SELECT class_name
    FROM academic.academic_classes
    WHERE tenant_id = p_tenant_id
      AND school_id = p_school_id
      AND COALESCE(is_deleted, FALSE) = FALSE
      AND COALESCE(is_active,  TRUE)  = TRUE
    ORDER BY display_order, academic_class_id;
    RETURN;
END;
$procedure$;


-- ── promote ────────────────────────────────────────────────────────────────
-- p_students is [{"studentId":1,"outcome":"promote"}, ...]. The target class
-- is NOT taken from the browser: it is derived here from the ladder above, so
-- a stale page cannot write the wrong class.
--
-- A student who cannot be promoted is skipped and reported, not fatal — one
-- student on a stale page should not roll back the whole class.
CREATE OR REPLACE PROCEDURE core.sp_student_promote(
    IN  p_tenant_id      integer,
    IN  p_school_id      integer,
    IN  p_action_user_id integer,
    IN  p_source_year    varchar,
    IN  p_target_year    varchar,
    IN  p_target_section varchar DEFAULT NULL,   -- NULL / 'keep' = keep the student's section
    IN  p_carry_dues     boolean DEFAULT TRUE,
    IN  p_students       jsonb   DEFAULT '[]'::jsonb,
    INOUT p_result       refcursor DEFAULT 'student_promote_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    r            record;
    v_src        varchar := TRIM(COALESCE(p_source_year, ''));
    v_tgt        varchar := TRIM(COALESCE(p_target_year, ''));
    v_sec        varchar := NULLIF(TRIM(COALESCE(p_target_section, '')), '');
    v_outcome    varchar;
    v_next       varchar;
    v_to_class   varchar;
    v_to_section varchar;
    v_dues       numeric(12,2);
    v_promoted   integer := 0;
    v_retained   integer := 0;
    v_passed     integer := 0;
    v_skipped    text[]  := '{}';
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    IF v_src = '' OR v_tgt = '' THEN
        RAISE EXCEPTION 'Choose both the current and the new academic session.';
    END IF;

    IF LOWER(v_src) = LOWER(v_tgt) THEN
        RAISE EXCEPTION 'The new session must be different from the current session.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM academic.academic_years
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND academic_year_name = v_tgt
          AND COALESCE(is_deleted, FALSE) = FALSE
          AND COALESCE(is_active,  TRUE)  = TRUE
    ) THEN
        RAISE EXCEPTION 'Academic session % is not set up for this school.', v_tgt;
    END IF;

    IF p_students IS NULL OR jsonb_array_length(p_students) = 0 THEN
        RAISE EXCEPTION 'No students were selected.';
    END IF;

    -- 'keep' is the page's own token for "leave the section alone".
    IF v_sec IS NOT NULL AND LOWER(v_sec) = 'keep' THEN
        v_sec := NULL;
    END IF;

    FOR r IN
        -- Column names are quoted so they match the camelCase JSON keys exactly —
        -- unquoted identifiers fold to lowercase and would never match "studentId".
        SELECT x."studentId" AS student_id, LOWER(TRIM(COALESCE(x.outcome, ''))) AS outcome
        FROM jsonb_to_recordset(p_students) AS x("studentId" integer, outcome text)
    LOOP
        DECLARE
            s core.students%ROWTYPE;
        BEGIN
            SELECT * INTO s
            FROM core.students
            WHERE student_id = r.student_id
              AND tenant_id  = p_tenant_id
              AND school_id  = p_school_id
            FOR UPDATE;

            IF NOT FOUND THEN
                v_skipped := v_skipped || ('#' || COALESCE(r.student_id::text, '?') || ' (not found)');
                CONTINUE;
            END IF;

            IF NOT s.is_active THEN
                v_skipped := v_skipped || (s.student_name || ' (already left)');
                CONTINUE;
            END IF;

            -- Guards a double submit: after a successful run the student sits
            -- on the target year, so a repeat finds nothing to move.
            IF TRIM(COALESCE(s.academic_year, '')) <> v_src THEN
                v_skipped := v_skipped || (s.student_name || ' (not in ' || v_src || ')');
                CONTINUE;
            END IF;

            v_outcome := CASE r.outcome
                            WHEN 'promote' THEN 'Promote'
                            WHEN 'retain'  THEN 'Retain'
                            WHEN 'passout' THEN 'PassOut'
                            ELSE NULL
                         END;
            IF v_outcome IS NULL THEN
                v_skipped := v_skipped || (s.student_name || ' (unknown outcome)');
                CONTINUE;
            END IF;

            SELECT COALESCE(SUM(l.amount_due - l.amount_paid - COALESCE(l.concession, 0)), 0)
            INTO v_dues
            FROM core.student_ledger l
            WHERE l.student_id = s.student_id;
            v_dues := GREATEST(v_dues, 0);

            -- The ledger is not year-scoped, so dues follow the student no
            -- matter what. Unticking the box therefore means "do not take the
            -- dues into the new session" -> those students must settle first.
            IF NOT p_carry_dues AND v_dues > 0 AND v_outcome <> 'PassOut' THEN
                v_skipped := v_skipped || (s.student_name || ' (pending dues)');
                CONTINUE;
            END IF;

            IF v_outcome = 'Promote' THEN
                WITH cur AS (
                    SELECT display_order, academic_class_id
                    FROM academic.academic_classes
                    WHERE tenant_id = p_tenant_id
                      AND school_id = p_school_id
                      AND class_name = s.class_name
                      AND COALESCE(is_deleted, FALSE) = FALSE
                    ORDER BY display_order, academic_class_id
                    LIMIT 1
                )
                SELECT c.class_name INTO v_next
                FROM academic.academic_classes c, cur
                WHERE c.tenant_id = p_tenant_id
                  AND c.school_id = p_school_id
                  AND COALESCE(c.is_deleted, FALSE) = FALSE
                  AND COALESCE(c.is_active,  TRUE)  = TRUE
                  AND (c.display_order, c.academic_class_id) > (cur.display_order, cur.academic_class_id)
                ORDER BY c.display_order, c.academic_class_id
                LIMIT 1;

                IF v_next IS NULL THEN
                    v_skipped := v_skipped || (s.student_name || ' (already in the final class — mark Pass Out)');
                    CONTINUE;
                END IF;

                v_to_class   := v_next;
                v_to_section := COALESCE(v_sec, s.section);

                UPDATE core.students
                SET class_name    = v_to_class,
                    section       = v_to_section,
                    academic_year = v_tgt,
                    updated_by    = p_action_user_id,
                    updated_at    = now()
                WHERE student_id = s.student_id;

                v_promoted := v_promoted + 1;

            ELSIF v_outcome = 'Retain' THEN
                v_to_class   := s.class_name;
                v_to_section := COALESCE(v_sec, s.section);

                UPDATE core.students
                SET section       = v_to_section,
                    academic_year = v_tgt,
                    updated_by    = p_action_user_id,
                    updated_at    = now()
                WHERE student_id = s.student_id;

                v_retained := v_retained + 1;

            ELSE  -- PassOut: same shape as sp_student_exit, so they show up in
                  -- the Inactive list and stay eligible for a TC.
                v_to_class   := NULL;
                v_to_section := NULL;

                UPDATE core.students
                SET status           = 'Passout',
                    is_active        = FALSE,
                    date_of_leaving  = CURRENT_DATE,
                    exit_recorded_by = p_action_user_id,
                    exit_recorded_at = now(),
                    updated_by       = p_action_user_id,
                    updated_at       = now()
                WHERE student_id = s.student_id;

                v_passed := v_passed + 1;
            END IF;

            INSERT INTO core.student_promotion_history (
                tenant_id, school_id, student_id,
                from_year, from_class, from_section,
                to_year, to_class, to_section,
                outcome, dues_carried, promoted_by)
            VALUES (
                p_tenant_id, p_school_id, s.student_id,
                s.academic_year, s.class_name, s.section,
                CASE WHEN v_outcome = 'PassOut' THEN s.academic_year ELSE v_tgt END,
                v_to_class, v_to_section,
                v_outcome, v_dues, p_action_user_id);
        END;
    END LOOP;

    IF v_promoted + v_retained + v_passed = 0 THEN
        RAISE EXCEPTION 'Nothing was promoted. %',
            COALESCE(NULLIF(array_to_string(v_skipped, '; '), ''), 'No matching students in ' || v_src || '.');
    END IF;

    OPEN p_result FOR
    SELECT TRUE                                   AS success,
           v_promoted                             AS promoted,
           v_retained                             AS retained,
           v_passed                               AS passed_out,
           COALESCE(array_length(v_skipped, 1), 0) AS skipped,
           array_to_string(v_skipped, '; ')       AS skipped_detail,
           v_promoted || ' promoted, ' || v_retained || ' retained, ' ||
           v_passed   || ' passed out.'           AS message;
    RETURN;
END;
$procedure$;
