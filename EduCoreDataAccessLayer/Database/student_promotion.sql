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
--
-- PREREQUISITE: the target session must already have its classes and sections
-- (see academic_session_rollover.sql). Classes are per-session rows, so a new
-- session is empty until the structure is copied forward, and promoting into an
-- empty session would write students onto classes that do not exist.
--
-- MONEY: Promote / Retain bill the target class's recurring fee structure for
-- the new session (once per student per session) and re-bill a kept bus route;
-- PassOut closes later dues like an exit. Depends on student_money_lifecycle.sql,
-- transport_module.sql and student_exit.sql -- apply those first.
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
--
-- Classes are per-session rows, so the ladder MUST be scoped to one session.
-- Unscoped it returns every session's classes concatenated, which reads as
-- "1st, 1st, 2nd, 2nd, ..." the moment a second session has structure.
-- p_academic_year_name is optional; NULL means the current session.
DROP PROCEDURE IF EXISTS core.sp_class_ladder(integer, integer, integer, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_class_ladder(
    IN  p_tenant_id         integer,
    IN  p_school_id         integer,
    IN  p_action_user_id    integer,
    IN  p_academic_year_name character varying DEFAULT NULL,
    INOUT p_result          refcursor DEFAULT 'class_ladder_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_year varchar := NULLIF(TRIM(COALESCE(p_academic_year_name, '')), '');
    v_year_id integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        OPEN p_result FOR SELECT WHERE FALSE;
        RETURN;
    END IF;

    SELECT academic_year_id INTO v_year_id
    FROM   academic.academic_years
    WHERE  tenant_id = p_tenant_id
      AND  school_id = p_school_id
      AND  COALESCE(is_deleted, FALSE) = FALSE
      AND  (   (v_year IS NOT NULL AND academic_year_name = v_year)
            OR (v_year IS NULL     AND COALESCE(is_current, FALSE) = TRUE))
    LIMIT 1;

    IF v_year_id IS NULL THEN
        OPEN p_result FOR SELECT WHERE FALSE;
        RETURN;
    END IF;

    -- display_order comes back too: the Promotion page needs it to work out the
    -- next class exactly the way this proc's caller does (order from the SOURCE
    -- session, then the first higher class in the TARGET). Names alone are not
    -- enough once the two sessions hold different classes. Additive column —
    -- existing consumers read by name, so they are unaffected.
    OPEN p_result FOR
    SELECT class_name, display_order
    FROM academic.academic_classes
    WHERE tenant_id = p_tenant_id
      AND school_id = p_school_id
      AND academic_year_id = v_year_id
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
    r             record;
    v_src         varchar := TRIM(COALESCE(p_source_year, ''));
    v_tgt         varchar := TRIM(COALESCE(p_target_year, ''));
    v_sec         varchar := NULLIF(TRIM(COALESCE(p_target_section, '')), '');
    v_src_year_id integer;
    v_tgt_year_id integer;
    v_tgt_classes integer := 0;
    v_cur_order   integer;
    v_pick_order  integer;   -- display_order of an explicitly chosen target class
    v_outcome     varchar;
    v_next        varchar;
    v_to_class    varchar;
    v_to_section  varchar;
    v_dues        numeric(12,2);
    v_due_now     numeric(12,2);
    v_promoted    integer := 0;
    v_retained    integer := 0;
    v_passed      integer := 0;
    v_skipped     text[]  := '{}';
    v_tgt_start   date;
    v_plan        jsonb;
    v_billed      integer := 0;
    v_roll        varchar;   -- the roll number in the new class (see below)
    v_unbilled    text[]  := '{}';
    v_route       integer;
    v_stop        integer;
    v_bus         refcursor;
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

    SELECT academic_year_id, start_date::date INTO v_tgt_year_id, v_tgt_start
    FROM   academic.academic_years
    WHERE  tenant_id = p_tenant_id
      AND  school_id = p_school_id
      AND  academic_year_name = v_tgt
      AND  COALESCE(is_deleted, FALSE) = FALSE
      AND  COALESCE(is_active,  TRUE)  = TRUE;

    IF v_tgt_year_id IS NULL THEN
        RAISE EXCEPTION 'Academic session % is not set up for this school.', v_tgt;
    END IF;

    -- The session EXISTING is not enough. Classes and sections are per-session
    -- rows, so a freshly created session is empty, and promoting into it writes
    -- students into a class that does not exist anywhere in the setup — they
    -- then vanish from every class-filtered page. Stop before that happens.
    SELECT COUNT(*) INTO v_tgt_classes
    FROM   academic.academic_classes
    WHERE  tenant_id = p_tenant_id
      AND  school_id = p_school_id
      AND  academic_year_id = v_tgt_year_id
      AND  COALESCE(is_deleted, FALSE) = FALSE
      AND  COALESCE(is_active,  TRUE)  = TRUE;

    IF v_tgt_classes = 0 THEN
        RAISE EXCEPTION 'Session % has no classes or sections yet. Open Settings > Classes & Sections, pick %, and copy the structure from the previous session before promoting.', v_tgt, v_tgt;
    END IF;

    -- Optional: used only to read the student's current position on the ladder.
    SELECT academic_year_id INTO v_src_year_id
    FROM   academic.academic_years
    WHERE  tenant_id = p_tenant_id
      AND  school_id = p_school_id
      AND  academic_year_name = v_src
      AND  COALESCE(is_deleted, FALSE) = FALSE;

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
        SELECT x."studentId"                             AS student_id,
               LOWER(TRIM(COALESCE(x.outcome, '')))       AS outcome,
               NULLIF(TRIM(COALESCE(x."toClass", '')), '') AS to_class
        FROM jsonb_to_recordset(p_students) AS x("studentId" integer, outcome text, "toClass" text)
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

            -- What has fallen due by today. Holding a child back is about fees
            -- they owe now, not the months still ahead of the session.
            SELECT COALESCE(SUM(l.amount_due - l.amount_paid - COALESCE(l.concession, 0)), 0)
            INTO v_due_now
            FROM core.student_ledger l
            WHERE l.student_id = s.student_id
              AND (l.due_date IS NULL OR l.due_date::date <= CURRENT_DATE);

            -- The ledger is not year-scoped, so dues follow the student no
            -- matter what. Unticking the box therefore means "do not take the
            -- dues into the new session" -> those students must settle first.
            IF NOT p_carry_dues AND v_due_now > 0 AND v_outcome <> 'PassOut' THEN
                v_skipped := v_skipped || (s.student_name || ' (pending dues)');
                CONTINUE;
            END IF;

            -- 1. Work out where the student is going.
            IF v_outcome = 'Promote' THEN
                -- The student's rung on the ladder, read from the session they
                -- are leaving; fall back to the new session in case the old one
                -- was edited after they were admitted.
                SELECT display_order INTO v_cur_order
                FROM   academic.academic_classes
                WHERE  tenant_id = p_tenant_id
                  AND  school_id = p_school_id
                  AND  academic_year_id = COALESCE(v_src_year_id, v_tgt_year_id)
                  AND  class_name = s.class_name
                  AND  COALESCE(is_deleted, FALSE) = FALSE
                ORDER BY display_order, academic_class_id
                LIMIT 1;

                IF v_cur_order IS NULL THEN
                    SELECT display_order INTO v_cur_order
                    FROM   academic.academic_classes
                    WHERE  tenant_id = p_tenant_id
                      AND  school_id = p_school_id
                      AND  academic_year_id = v_tgt_year_id
                      AND  class_name = s.class_name
                      AND  COALESCE(is_deleted, FALSE) = FALSE
                    ORDER BY display_order, academic_class_id
                    LIMIT 1;
                END IF;

                IF v_cur_order IS NULL THEN
                    v_skipped := v_skipped || (s.student_name || ' (class ' || s.class_name || ' is not in the session setup)');
                    CONTINUE;
                END IF;

                IF r.to_class IS NOT NULL THEN
                    -- The office asked for a specific class (a double promotion,
                    -- 1st -> 3rd). Still has to be a real class in the TARGET
                    -- session, and still has to be ABOVE where they are now: this
                    -- operation only ever moves students up. Moving someone down
                    -- is a correction, and belongs on the student's own page where
                    -- it is one deliberate act rather than a bulk one.
                    SELECT display_order INTO v_pick_order
                    FROM   academic.academic_classes
                    WHERE  tenant_id = p_tenant_id
                      AND  school_id = p_school_id
                      AND  academic_year_id = v_tgt_year_id
                      AND  class_name = r.to_class
                      AND  COALESCE(is_deleted, FALSE) = FALSE
                      AND  COALESCE(is_active,  TRUE)  = TRUE
                    ORDER BY display_order, academic_class_id
                    LIMIT 1;

                    IF v_pick_order IS NULL THEN
                        v_skipped := v_skipped ||
                            (s.student_name || ' (chosen class ' || r.to_class || ' is not set up in ' || v_tgt || ')');
                        CONTINUE;
                    END IF;

                    IF v_pick_order <= v_cur_order THEN
                        v_skipped := v_skipped ||
                            (s.student_name || ' (' || r.to_class || ' is not above ' || s.class_name || ')');
                        CONTINUE;
                    END IF;

                    v_next := r.to_class;
                ELSE
                    -- Default: the next rung up. Read from the TARGET session, so a
                    -- student can only ever be moved into a class that exists there.
                    SELECT class_name INTO v_next
                    FROM   academic.academic_classes
                    WHERE  tenant_id = p_tenant_id
                      AND  school_id = p_school_id
                      AND  academic_year_id = v_tgt_year_id
                      AND  COALESCE(is_deleted, FALSE) = FALSE
                      AND  COALESCE(is_active,  TRUE)  = TRUE
                      AND  display_order > v_cur_order
                    ORDER BY display_order, academic_class_id
                    LIMIT 1;
                END IF;

                IF v_next IS NULL THEN
                    v_skipped := v_skipped || (s.student_name || ' (already in the final class — mark Pass Out)');
                    CONTINUE;
                END IF;

                v_to_class := v_next;

            ELSIF v_outcome = 'Retain' THEN
                v_to_class := s.class_name;

            ELSE
                v_to_class := NULL;   -- PassOut leaves the school; no class needed
            END IF;

            -- 2. A student may only land on a class + section that really exists
            --    in the target session. Carrying the old section forward blindly
            --    is how students used to end up in a section their new class has
            --    never had (1st-C -> 2nd-C, where 2nd only ever had A and B).
            IF v_outcome <> 'PassOut' THEN
                v_to_section := COALESCE(v_sec, s.section);

                IF NOT EXISTS (
                    SELECT 1
                    FROM   academic.academic_classes ac
                    WHERE  ac.tenant_id = p_tenant_id
                      AND  ac.school_id = p_school_id
                      AND  ac.academic_year_id = v_tgt_year_id
                      AND  ac.class_name = v_to_class
                      AND  COALESCE(ac.is_deleted, FALSE) = FALSE
                      AND  COALESCE(ac.is_active,  TRUE)  = TRUE
                ) THEN
                    v_skipped := v_skipped || (s.student_name || ' (' || v_to_class || ' is not set up in ' || v_tgt || ')');
                    CONTINUE;
                END IF;

                IF v_to_section IS NULL OR NOT EXISTS (
                    SELECT 1
                    FROM   academic.academic_class_sections acs
                    JOIN   academic.academic_classes ac
                           ON ac.academic_class_id = acs.academic_class_id
                    WHERE  ac.tenant_id = p_tenant_id
                      AND  ac.school_id = p_school_id
                      AND  ac.academic_year_id = v_tgt_year_id
                      AND  ac.class_name   = v_to_class
                      AND  acs.section_name = v_to_section
                      AND  COALESCE(ac.is_deleted,  FALSE) = FALSE
                      AND  COALESCE(acs.is_deleted, FALSE) = FALSE
                      AND  COALESCE(acs.is_active,  TRUE)  = TRUE
                ) THEN
                    v_skipped := v_skipped ||
                        (s.student_name || ' (section ' || COALESCE(v_to_section, '—') ||
                         ' does not exist in ' || v_to_class || ' for ' || v_tgt || ')');
                    CONTINUE;
                END IF;
            ELSE
                v_to_section := NULL;
            END IF;

            -- 3. Commit the move.
            --
            --    Two records are kept in step here: core.students carries the
            --    student's PRESENT position (overwritten), and
            --    core.student_enrolment gains a row per session so the position
            --    they are leaving is not lost. See student_enrolment.sql.
            -- Roll number in the new class: keep it, unless the student has none or
            -- someone already in that class-section uses it -- then the next free
            -- number (highest + 1). Renumbering a whole class is Students › Data Checks.
            v_roll := NULLIF(TRIM(COALESCE(s.roll_no, '')), '');
            IF v_outcome IN ('Promote', 'Retain') AND (v_roll IS NULL OR EXISTS (
                   SELECT 1 FROM core.students o
                    WHERE o.tenant_id = p_tenant_id AND o.school_id = p_school_id AND o.is_active
                      AND o.student_id <> s.student_id AND o.academic_year = v_tgt
                      AND o.class_name = v_to_class AND COALESCE(o.section, '') = COALESCE(v_to_section, '')
                      AND lower(TRIM(o.roll_no)) = lower(v_roll))) THEN
                -- counts those already moved in AND classmates of this run still to come,
                -- so a missing roll goes after everyone else's instead of taking roll 1
                SELECT (COALESCE(MAX(TRIM(x.roll_no)::int), 0) + 1)::text INTO v_roll
                  FROM (SELECT o.roll_no FROM core.students o
                         WHERE o.tenant_id = p_tenant_id AND o.school_id = p_school_id AND o.is_active
                           AND o.student_id <> s.student_id AND o.academic_year = v_tgt
                           AND o.class_name = v_to_class AND COALESCE(o.section, '') = COALESCE(v_to_section, '')
                        UNION ALL
                        SELECT o.roll_no FROM core.students o
                         WHERE o.student_id IN (SELECT (j->>'studentId')::int FROM jsonb_array_elements(p_students) j)
                           AND o.student_id <> s.student_id AND o.academic_year = s.academic_year
                           AND o.class_name = s.class_name AND COALESCE(o.section, '') = COALESCE(s.section, '')) x
                 WHERE TRIM(x.roll_no) ~ '^[0-9]{1,6}$';
            END IF;

            IF v_outcome = 'Promote' THEN
                UPDATE core.students
                SET class_name    = v_to_class,
                    roll_no       = v_roll,
                    section       = v_to_section,
                    academic_year = v_tgt,
                    updated_by    = p_action_user_id,
                    updated_at    = now()
                WHERE student_id = s.student_id;

                PERFORM core.fn_student_enrolment_close(
                    s.student_id, s.academic_year, 'Promoted', p_action_user_id);
                PERFORM core.fn_student_enrolment_open(
                    p_tenant_id, p_school_id, s.student_id,
                    v_tgt, v_to_class, v_to_section, v_roll, p_action_user_id);

                v_promoted := v_promoted + 1;

            ELSIF v_outcome = 'Retain' THEN
                UPDATE core.students
                SET section       = v_to_section,
                    roll_no       = v_roll,
                    academic_year = v_tgt,
                    updated_by    = p_action_user_id,
                    updated_at    = now()
                WHERE student_id = s.student_id;

                PERFORM core.fn_student_enrolment_close(
                    s.student_id, s.academic_year, 'Retained', p_action_user_id);
                PERFORM core.fn_student_enrolment_open(
                    p_tenant_id, p_school_id, s.student_id,
                    v_tgt, v_to_class, v_to_section, v_roll, p_action_user_id);

                v_retained := v_retained + 1;

            ELSE  -- PassOut: same shape as sp_student_exit, so they show up in
                  -- the Inactive list and stay eligible for a TC.
                UPDATE core.students
                SET status           = 'Passout',
                    is_active        = FALSE,
                    date_of_leaving  = CURRENT_DATE,
                    exit_recorded_by = p_action_user_id,
                    exit_recorded_at = now(),
                    updated_by       = p_action_user_id,
                    updated_at       = now()
                WHERE student_id = s.student_id;

                -- No new session opens; the last one just ends.
                PERFORM core.fn_student_enrolment_close(
                    s.student_id, s.academic_year, 'PassedOut', p_action_user_id);

                -- Same money rule as a manual exit: anything due after today
                -- is closed with a reason and the bus ends.
                PERFORM core.fn_student_leave_money(
                    p_tenant_id, p_school_id, s.student_id, CURRENT_DATE, p_action_user_id);

                v_passed := v_passed + 1;
            END IF;

            -- 4. Bill the new session (Promote and Retain).
            --
            --    The class's recurring fee structure for the TARGET session is
            --    billed exactly the way admission bills a plan
            --    (core.fn_student_bill_plan), from the session start. The
            --    admission fee and deposit are not charged again. Billing is
            --    once per student per session, so a repeated run never adds a
            --    second plan. Before this, promotion created no dues at all
            --    for the new year. Old unpaid dues are untouched: they carry.
            IF v_outcome IN ('Promote', 'Retain') THEN
                v_plan := core.fn_class_fee_plan(p_tenant_id, p_school_id, v_to_class, v_tgt);
                IF v_plan IS NULL THEN
                    v_unbilled := v_unbilled || (s.student_name || ' (' || v_to_class || ')');
                ELSIF core.fn_student_bill_plan(p_tenant_id, p_school_id, p_action_user_id,
                          s.student_id, v_tgt, COALESCE(v_tgt_start, CURRENT_DATE), v_plan) > 0 THEN
                    v_billed := v_billed + 1;
                END IF;

                -- A student who keeps a bus route is billed for it in the new
                -- session too, at the stop's current fare.
                v_route := NULL;
                SELECT route_id, stop_id INTO v_route, v_stop
                FROM core.student_transport
                WHERE student_id = s.student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
                  AND is_active = TRUE AND COALESCE(is_deleted, FALSE) = FALSE
                ORDER BY assignment_id DESC
                LIMIT 1;

                -- (not when the school's Transport module is off)
                IF v_route IS NOT NULL AND core.fn_module_on(p_tenant_id, p_school_id, 'transport') THEN
                    v_bus := 'promote_bus_' || s.student_id;
                    CALL core.sp_transport_assign_manage('SaveAssignment', p_tenant_id, p_school_id,
                         p_action_user_id, s.student_id, v_route, v_stop, v_tgt,
                         COALESCE(v_tgt_start, CURRENT_DATE), 12, v_bus);
                    CLOSE v_bus;
                END IF;
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
           v_passed   || ' passed out. ' ||
           v_billed   || ' billed for ' || v_tgt || '.' ||
           CASE WHEN array_length(v_unbilled, 1) > 0
                THEN ' Not billed — no fee structure for ' || v_tgt || ': ' ||
                     array_to_string(v_unbilled, ', ') || '.'
                ELSE '' END                       AS message,
           v_billed                               AS billed;
    RETURN;
END;
$procedure$;
