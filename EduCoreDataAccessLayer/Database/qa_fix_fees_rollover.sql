-- ============================================================================
-- qa_fix_fees_rollover.sql  (QA pack 18-Nov-2026: Fees + Session Rollover group)
--
-- Re-runnable: CREATE OR REPLACE / IF NOT EXISTS only, no BEGIN/COMMIT.
--
--   BUG-030  sp_student_promote: early promotion needs a typed confirmation
--            (p_confirm_early) and a pass-out no longer closes the running
--            session's fees (only lines due after the session ends).
--   G05/#7   sp_student_promote: p_roll_mode 'keep' (default) | 'renumber'.
--   G11/#8   core.student_promotion_run + sp_promotion_undo: undo the last run,
--            same day, before the target session is made current.
--   G02/G12  sp_promotion_context: exam result per student (pre-ticks Retain),
--            early-promotion facts, target fee structure, last undoable run.
--   BUG-031  academic.sp_academic_year_switch_check: what is still open before
--            "Make it current".
--   BUG-034  sp_fee_year_end_manage Status: the carry-from date and whether
--            carrying is open yet; "₹" not "Rs" in its messages.
--   BUG-031  sp_fee_month_dues: unpaid lines of earlier sessions (not carried,
--            not written off) still show, labelled with their session.
--   BUG-026  sp_fee_day_close: "₹" in its messages.
--   BUG-037  sp_attendance_overview: the session whose dates contain the day.
--   BUG-038  sp_inventory_class_register / _register_overview: a past session keeps
--            the children who left or passed out.
--   BUG-046  sp_transport_assign_manage: RemoveAssignment closes only bus fees
--            not yet due; new RemovePreview for the confirm dialog.
-- ============================================================================
SET client_encoding = 'UTF8';

-- ── 1. Promotion runs (Undo last run) ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS core.student_promotion_run (
    run_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id    integer     NOT NULL,
    school_id    integer     NOT NULL,
    source_year  varchar(20) NOT NULL,
    target_year  varchar(20) NOT NULL,
    run_by       integer     NOT NULL DEFAULT 0,
    run_at       timestamptz NOT NULL DEFAULT now(),
    undone_by    integer,
    undone_at    timestamptz
);
CREATE INDEX IF NOT EXISTS ix_student_promotion_run_school
    ON core.student_promotion_run (tenant_id, school_id, run_id DESC);

-- What the student looked like before the run, so Undo can put it back.
ALTER TABLE core.student_promotion_history ADD COLUMN IF NOT EXISTS run_id      integer;
ALTER TABLE core.student_promotion_history ADD COLUMN IF NOT EXISTS from_roll   varchar(20);
ALTER TABLE core.student_promotion_history ADD COLUMN IF NOT EXISTS from_status varchar(20);
CREATE INDEX IF NOT EXISTS ix_student_promotion_history_run
    ON core.student_promotion_history (run_id) WHERE run_id IS NOT NULL;

-- ── 2. sp_student_promote: new trailing parameters (named calls keep working) ─
DROP PROCEDURE IF EXISTS core.sp_student_promote(integer, integer, integer, character varying,
    character varying, character varying, boolean, jsonb, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_student_promote(IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_source_year character varying, IN p_target_year character varying, IN p_target_section character varying DEFAULT NULL::character varying, IN p_carry_dues boolean DEFAULT true, IN p_students jsonb DEFAULT '[]'::jsonb, INOUT p_result refcursor DEFAULT 'student_promote_cursor'::refcursor, IN p_confirm_early boolean DEFAULT false, IN p_roll_mode character varying DEFAULT 'keep'::character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_src_end     date;      -- the session being left: its last day
    v_src_last    date;      -- ... and the first day of its last month
    v_run_id      integer;   -- core.student_promotion_run (Undo last run)
    v_cut         date;      -- pass-out: dues after this day are not owed
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
        RAISE EXCEPTION 'Session % has no classes or sections yet. Open School Setup › Classes & Sections (/school/classes), pick %, and copy the structure from the previous session before promoting.', v_tgt, v_tgt;
    END IF;

    -- Optional: used only to read the student's current position on the ladder.
    SELECT academic_year_id, NULLIF(end_date, '')::date
      INTO v_src_year_id, v_src_end
    FROM   academic.academic_years
    WHERE  tenant_id = p_tenant_id
      AND  school_id = p_school_id
      AND  academic_year_name = v_src
      AND  COALESCE(is_deleted, FALSE) = FALSE;

    IF p_students IS NULL OR jsonb_array_length(p_students) = 0 THEN
        RAISE EXCEPTION 'No students were selected.';
    END IF;

    -- QA BUG-030: promoting before the session's last month (the month Year-End
    -- starts carrying dues) takes students out of a running year. Allowed, but
    -- only after the office typed the session name on the page (p_confirm_early).
    v_src_last := date_trunc('month', v_src_end)::date;
    IF v_src_last IS NOT NULL AND CURRENT_DATE < v_src_last AND NOT COALESCE(p_confirm_early, FALSE) THEN
        RAISE EXCEPTION 'Session % runs until %. Promoting before % (its last month) needs the typed confirmation on the Promote page.',
            v_src, to_char(v_src_end, 'DD Mon YYYY'), to_char(v_src_last, 'DD Mon YYYY');
    END IF;

    -- One row per run, so the last run can be undone (owner decision #8).
    -- now() is the transaction time: every fee line, plan row and bus assignment
    -- this run writes carries exactly this created_at, which is how Undo finds them.
    INSERT INTO core.student_promotion_run (tenant_id, school_id, source_year, target_year, run_by, run_at)
    VALUES (p_tenant_id, p_school_id, v_src, v_tgt, p_action_user_id, now())
    RETURNING run_id INTO v_run_id;

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

                -- QA BUG-030: a pass-out must NEVER cancel the running session's
                -- fees. A manual exit closes everything due after today; a pass-out
                -- closes only what falls due after the session ends, so a class
                -- passed out in November still owes December to March.
                v_cut := GREATEST(CURRENT_DATE, COALESCE(v_src_end, CURRENT_DATE));
                PERFORM core.fn_student_leave_money(
                    p_tenant_id, p_school_id, s.student_id, v_cut, p_action_user_id);

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
                outcome, dues_carried, promoted_by,
                run_id, from_roll, from_status)
            VALUES (
                p_tenant_id, p_school_id, s.student_id,
                s.academic_year, s.class_name, s.section,
                CASE WHEN v_outcome = 'PassOut' THEN s.academic_year ELSE v_tgt END,
                v_to_class, v_to_section,
                v_outcome, v_dues, p_action_user_id,
                v_run_id, s.roll_no, s.status);
        END;
    END LOOP;

    IF v_promoted + v_retained + v_passed = 0 THEN
        RAISE EXCEPTION 'Nothing was promoted. %',
            COALESCE(NULLIF(array_to_string(v_skipped, '; '), ''), 'No matching students in ' || v_src || '.');
    END IF;

    -- Owner decision #7: "Re-number alphabetically" gives every class-section this
    -- run moved students into fresh rolls 1..n by name (everyone in it for the new
    -- session, including students moved by an earlier run). Default keeps the rolls.
    IF lower(COALESCE(p_roll_mode, 'keep')) = 'renumber' THEN
        UPDATE core.students st
           SET roll_no = x.rn::text, updated_by = p_action_user_id, updated_at = now()
          FROM (SELECT o.student_id,
                       row_number() OVER (PARTITION BY o.class_name, COALESCE(o.section, '')
                                          ORDER BY lower(o.student_name), o.student_id) AS rn
                  FROM core.students o
                 WHERE o.tenant_id = p_tenant_id AND o.school_id = p_school_id AND o.is_active
                   AND o.academic_year = v_tgt
                   AND (o.class_name, COALESCE(o.section, '')) IN (
                         SELECT h.to_class, COALESCE(h.to_section, '')
                           FROM core.student_promotion_history h
                          WHERE h.run_id = v_run_id AND h.outcome IN ('Promote', 'Retain'))) x
         WHERE st.student_id = x.student_id;

        UPDATE core.student_enrolment e
           SET roll_no = st.roll_no, updated_by = p_action_user_id, updated_at = now()
          FROM core.students st
         WHERE st.student_id = e.student_id AND e.academic_year = v_tgt
           AND st.tenant_id = p_tenant_id AND st.school_id = p_school_id AND st.academic_year = v_tgt
           AND e.roll_no IS DISTINCT FROM st.roll_no;
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
           v_billed                               AS billed,
           v_run_id                               AS run_id;
    RETURN;
END;
$procedure$;


-- ── 3. What the Promote page needs to know before the run ──────────────────
--   p_info    : one row. The source session's end and last month (early warning,
--               BUG-030), how many target classes have a fee structure (G12), and
--               the school's last promotion run with whether it can be undone (G11).
--   p_results : per student of p_class_name in p_source_year, the latest PUBLISHED
--               exam of that session (G02): failed papers -> Compartment (1-2) or
--               Fail (3+). Empty when the class is not given or exams are not used.
CREATE OR REPLACE PROCEDURE core.sp_promotion_context(
    IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer,
    IN p_source_year character varying, IN p_target_year character varying,
    IN p_class_name character varying DEFAULT NULL,
    INOUT p_info refcursor DEFAULT 'promotion_info_cursor'::refcursor,
    INOUT p_results refcursor DEFAULT 'promotion_results_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_src_id  integer;
    v_src_end date;
    v_run     record;
    v_block   text;
    v_cur     boolean;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    SELECT academic_year_id, NULLIF(end_date, '')::date INTO v_src_id, v_src_end
      FROM academic.academic_years
     WHERE tenant_id = p_tenant_id AND school_id = p_school_id
       AND academic_year_name = TRIM(COALESCE(p_source_year, ''))
       AND NOT COALESCE(is_deleted, FALSE)
     LIMIT 1;

    -- The school's last run that has not been undone.
    SELECT r.*, (SELECT COUNT(*) FROM core.student_promotion_history h WHERE h.run_id = r.run_id) AS moved
      INTO v_run
      FROM core.student_promotion_run r
     WHERE r.tenant_id = p_tenant_id AND r.school_id = p_school_id AND r.undone_at IS NULL
     ORDER BY r.run_id DESC
     LIMIT 1;

    IF v_run.run_id IS NOT NULL THEN
        SELECT COALESCE(y.is_current, FALSE) INTO v_cur
          FROM academic.academic_years y
         WHERE y.tenant_id = p_tenant_id AND y.school_id = p_school_id
           AND y.academic_year_name = v_run.target_year AND NOT COALESCE(y.is_deleted, FALSE)
         LIMIT 1;
        v_block := CASE
            WHEN v_run.run_at::date <> CURRENT_DATE THEN 'Only a run made today can be undone.'
            WHEN COALESCE(v_cur, FALSE) THEN v_run.target_year || ' is already the current session.'
            ELSE NULL END;
    END IF;

    OPEN p_info FOR
    SELECT to_char(v_src_end, 'YYYY-MM-DD')                                      AS source_end,
           to_char(date_trunc('month', v_src_end), 'YYYY-MM-DD')                  AS last_month_start,
           (v_src_end IS NOT NULL AND CURRENT_DATE < date_trunc('month', v_src_end)::date) AS is_early,
           (SELECT COUNT(DISTINCT fs.class_name)::int
              FROM core.school_fee_structures fs
             WHERE fs.tenant_id = p_tenant_id AND fs.school_id = p_school_id
               AND fs.academic_year = TRIM(COALESCE(p_target_year, ''))
               AND NOT COALESCE(fs.is_deleted, FALSE))                           AS target_fee_classes,
           v_run.run_id                                                           AS undo_run_id,
           to_char(v_run.run_at AT TIME ZONE 'Asia/Kolkata', 'DD Mon YYYY, HH12:MI AM') AS undo_run_at,
           v_run.source_year                                                      AS undo_source,
           v_run.target_year                                                      AS undo_target,
           COALESCE(v_run.moved, 0)::int                                          AS undo_count,
           v_block                                                                AS undo_block;

    IF NULLIF(TRIM(COALESCE(p_class_name, '')), '') IS NULL OR v_src_id IS NULL THEN
        OPEN p_results FOR SELECT NULL::integer AS student_id, NULL::text AS exam_name,
                                  NULL::integer AS failed, NULL::text AS result WHERE FALSE;
        RETURN;
    END IF;

    OPEN p_results FOR
    SELECT s.student_id, x.exam_name, x.failed::int AS failed,
           CASE WHEN x.failed = 0 THEN 'Pass'
                WHEN x.failed <= 2 THEN 'Compartment'
                ELSE 'Fail' END AS result
      FROM core.students s
      CROSS JOIN LATERAL (
            SELECT e.exam_name,
                   COUNT(*) FILTER (WHERE m.marks_obtained IS NOT NULL AND es.pass_marks IS NOT NULL
                                      AND m.marks_obtained < es.pass_marks) AS failed
              FROM academic.exams e
              JOIN academic.exam_marks m ON m.exam_id = e.exam_id AND m.student_id = s.student_id
              JOIN academic.exam_subjects es
                ON es.exam_id = m.exam_id AND es.subject_id = m.subject_id
               AND es.academic_class_id = m.academic_class_id
             WHERE e.tenant_id = p_tenant_id AND e.school_id = p_school_id
               AND e.academic_year_id = v_src_id
               AND NOT COALESCE(e.is_deleted, FALSE)
               AND e.status = 'Published' AND e.results_status = 'Published'
             GROUP BY e.exam_id, e.exam_name, e.start_date
             ORDER BY e.start_date DESC, e.exam_id DESC
             LIMIT 1) x
     WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id AND s.is_active
       AND s.academic_year = TRIM(p_source_year)
       AND s.class_name = TRIM(p_class_name);
END;
$procedure$;


-- ── 4. Undo the last promotion run (owner decision #8) ─────────────────────
-- Same day only, and only while the target session is not current. Puts every
-- student of the run back (class, section, roll, session, status), re-opens the
-- old enrolment, removes the new one, and removes the fee lines / fee plan / bus
-- assignment the run created. Refused when any of those fee lines has been paid,
-- or when a student of the run has been changed since.
CREATE OR REPLACE PROCEDURE core.sp_promotion_undo(
    IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer,
    IN p_run_id integer,
    INOUT p_result refcursor DEFAULT 'promotion_undo_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_run     core.student_promotion_run%ROWTYPE;
    v_latest  integer;
    v_cur     boolean;
    v_bad     text;
    v_count   integer := 0;

    h         record;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    SELECT * INTO v_run FROM core.student_promotion_run
     WHERE run_id = p_run_id AND tenant_id = p_tenant_id AND school_id = p_school_id
       FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'This promotion run was not found.';
    END IF;
    IF v_run.undone_at IS NOT NULL THEN
        RAISE EXCEPTION 'This promotion run was already undone.';
    END IF;

    SELECT MAX(run_id) INTO v_latest FROM core.student_promotion_run
     WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND undone_at IS NULL;
    IF v_latest <> v_run.run_id THEN
        RAISE EXCEPTION 'Only the last promotion run can be undone.';
    END IF;
    IF v_run.run_at::date <> CURRENT_DATE THEN
        RAISE EXCEPTION 'Only a run made today can be undone. Correct older moves on the student''s own page.';
    END IF;

    SELECT COALESCE(y.is_current, FALSE) INTO v_cur
      FROM academic.academic_years y
     WHERE y.tenant_id = p_tenant_id AND y.school_id = p_school_id
       AND y.academic_year_name = v_run.target_year AND NOT COALESCE(y.is_deleted, FALSE)
     LIMIT 1;
    IF COALESCE(v_cur, FALSE) THEN
        RAISE EXCEPTION '% is already the current session, so this run can no longer be undone.', v_run.target_year;
    END IF;

    -- Every student must still be where the run left them.
    SELECT string_agg(st.student_name, ', ') INTO v_bad
      FROM core.student_promotion_history ph
      JOIN core.students st ON st.student_id = ph.student_id
     WHERE ph.run_id = v_run.run_id
       AND NOT (   (ph.outcome IN ('Promote', 'Retain') AND st.is_active
                    AND st.academic_year = ph.to_year AND st.class_name = ph.to_class)
                OR (ph.outcome = 'PassOut' AND NOT st.is_active AND st.status = 'Passout'));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'Cannot undo: these students were changed after the run: %.', v_bad;
    END IF;

    -- Fee lines the run created (same transaction time) that someone has paid.
    SELECT string_agg(DISTINCT st.student_name, ', ') INTO v_bad
      FROM core.student_ledger l
      JOIN core.students st ON st.student_id = l.student_id
     WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
       AND l.created_at = v_run.run_at
       AND l.student_id IN (SELECT student_id FROM core.student_promotion_history WHERE run_id = v_run.run_id)
       AND (l.amount_paid > 0 OR l.concession > 0 OR l.closed_amount > 0);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'Cannot undo: fees billed by this run have already been collected for %. Cancel those receipts first.', v_bad;
    END IF;

    FOR h IN
        SELECT * FROM core.student_promotion_history WHERE run_id = v_run.run_id
    LOOP
        -- Lines closed by the run (a pass-out's deposit / after-session dues, a
        -- replaced bus route) are re-opened; lines it created are removed.
        PERFORM core.fn_ledger_reopen(l.ledger_id)
           FROM core.student_ledger l
          WHERE l.student_id = h.student_id AND l.tenant_id = p_tenant_id AND l.school_id = p_school_id
            AND l.closed_at = v_run.run_at;

        DELETE FROM core.student_ledger
         WHERE student_id = h.student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
           AND created_at = v_run.run_at;


        DELETE FROM core.student_fee_plan
         WHERE student_id = h.student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
           AND created_at = v_run.run_at;

        -- Bus: drop the assignment the run created, bring back the one it ended.
        DELETE FROM core.student_transport
         WHERE student_id = h.student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
           AND created_at = v_run.run_at;
        UPDATE core.student_transport
           SET is_active = TRUE, is_deleted = FALSE, end_reason = NULL, ended_by = NULL, ended_at = NULL,
               updated_by = p_action_user_id, updated_at = now()
         WHERE student_id = h.student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
           AND ended_at = v_run.run_at;

        IF h.outcome = 'PassOut' THEN
            UPDATE core.students
               SET is_active = TRUE, status = COALESCE(NULLIF(h.from_status, ''), 'Active'),
                   date_of_leaving = NULL, exit_recorded_by = NULL, exit_recorded_at = NULL,
                   updated_by = p_action_user_id, updated_at = now()
             WHERE student_id = h.student_id;
        ELSE
            UPDATE core.students
               SET academic_year = h.from_year, class_name = h.from_class, section = h.from_section,
                   roll_no = h.from_roll, updated_by = p_action_user_id, updated_at = now()
             WHERE student_id = h.student_id;

            DELETE FROM core.student_enrolment
             WHERE student_id = h.student_id AND academic_year = h.to_year;
        END IF;

        UPDATE core.student_enrolment
           SET status = 'Active', is_current = TRUE, updated_by = p_action_user_id, updated_at = now()
         WHERE student_id = h.student_id AND academic_year = h.from_year;

        v_count := v_count + 1;
    END LOOP;

    DELETE FROM core.student_promotion_history WHERE run_id = v_run.run_id;
    UPDATE core.student_promotion_run
       SET undone_at = now(), undone_by = p_action_user_id
     WHERE run_id = v_run.run_id;

    OPEN p_result FOR
    SELECT TRUE AS success, v_count AS students,
           'Undone: ' || v_count || ' student(s) are back in ' || v_run.source_year || '.' AS message;
END;
$procedure$;


-- ── 5. "Make it current": what is still open (QA BUG-031) ──────────────────
-- One row about the session being made current and the one it replaces. The
-- page lists every non-empty point and asks for the session name to be typed.
CREATE OR REPLACE PROCEDURE academic.sp_academic_year_switch_check(
    IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer,
    IN p_academic_year_id integer,
    INOUT p_result refcursor DEFAULT 'year_switch_check_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_new   academic.academic_years%ROWTYPE;
    v_old   academic.academic_years%ROWTYPE;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    SELECT * INTO v_new FROM academic.academic_years
     WHERE academic_year_id = p_academic_year_id AND tenant_id = p_tenant_id AND school_id = p_school_id
       AND NOT COALESCE(is_deleted, FALSE);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'This academic year no longer exists. Refresh the page.';
    END IF;

    SELECT * INTO v_old FROM academic.academic_years
     WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND is_current
       AND NOT COALESCE(is_deleted, FALSE)
     LIMIT 1;

    OPEN p_result FOR
    SELECT v_new.academic_year_name                          AS year_name,
           v_new.start_date                                  AS start_date,
           (NULLIF(v_new.start_date, '')::date > CURRENT_DATE) AS starts_in_future,
           v_old.academic_year_name                          AS current_name,
           (v_old.academic_year_id IS NOT NULL AND v_old.fees_closed_at IS NULL) AS current_open,
           COALESCE(u.lines, 0)::int                         AS undecided_lines,
           COALESCE(u.amount, 0)                             AS undecided_amount
      FROM (SELECT COUNT(*) AS lines, SUM(l.amount_due - l.amount_paid - l.concession) AS amount
              FROM core.student_ledger l
              JOIN core.students s ON s.student_id = l.student_id
             WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
               AND v_old.academic_year_name IS NOT NULL
               AND lower(COALESCE(NULLIF(trim(l.academic_year), ''), s.academic_year)) = lower(v_old.academic_year_name)
               AND l.amount_due > l.amount_paid + l.concession
               AND COALESCE(l.close_source, '') <> 'YearEnd') u;
END;
$procedure$;


-- ── 6. Year-End status: carry-from date; "₹" in messages (BUG-034) ─────────
CREATE OR REPLACE PROCEDURE core.sp_fee_year_end_manage(IN p_operation character varying, IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_academic_year character varying, IN p_ledger_id integer DEFAULT NULL::integer, IN p_student_id integer DEFAULT NULL::integer, IN p_reason character varying DEFAULT NULL::character varying, INOUT p_result refcursor DEFAULT 'year_end_cursor'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_year   varchar := lower(NULLIF(trim(p_academic_year), ''));
    v_reason varchar := NULLIF(trim(p_reason), '');
    v_next   varchar;            -- the session after v_year, where carried dues go
    v_count  integer := 0;
    v_amount numeric(12,2) := 0;
    v_closed timestamptz;        -- when this session's fees were closed (NULL = open)
    v_open   integer := 0;       -- lines still to decide
    v_notdue integer := 0;       -- ... of which not due yet
    v_last   date;               -- first day of the session's last month: carrying opens then
    r        record;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;
    IF v_year IS NULL THEN
        RAISE EXCEPTION 'Choose a session.';
    END IF;

    SELECT n.academic_year_name INTO v_next
      FROM academic.academic_years n
      JOIN academic.academic_years cur ON cur.tenant_id = n.tenant_id AND cur.school_id = n.school_id
                                      AND lower(cur.academic_year_name) = v_year AND NOT COALESCE(cur.is_deleted, FALSE)
     WHERE n.tenant_id = p_tenant_id AND n.school_id = p_school_id AND NOT COALESCE(n.is_deleted, FALSE)
       AND n.start_date > cur.start_date
     ORDER BY n.start_date
     LIMIT 1;

    SELECT y.fees_closed_at, date_trunc('month', NULLIF(y.end_date, '')::date)::date INTO v_closed, v_last
      FROM academic.academic_years y
     WHERE y.tenant_id = p_tenant_id AND y.school_id = p_school_id
       AND lower(y.academic_year_name) = v_year AND NOT COALESCE(y.is_deleted, FALSE)
     LIMIT 1;

    -- Lines of this session still unpaid and not yet carried or written off.
    SELECT COUNT(*), COUNT(*) FILTER (WHERE NULLIF(l.due_date, '')::date > CURRENT_DATE)
      INTO v_open, v_notdue
      FROM core.student_ledger l
      JOIN core.students s ON s.student_id = l.student_id
     WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
       AND lower(COALESCE(NULLIF(trim(l.academic_year), ''), s.academic_year)) = v_year
       AND l.amount_due > l.amount_paid + l.concession
       AND COALESCE(l.close_source, '') <> 'YearEnd';

    -- ── Status: what the page needs to know about the session as a whole
    IF p_operation = 'Status' THEN
        OPEN p_result FOR
        SELECT v_next AS next_session, v_closed AS closed_at,
               (SELECT core.fn_user_display_name(y.fees_closed_by) FROM academic.academic_years y
                 WHERE y.tenant_id = p_tenant_id AND y.school_id = p_school_id
                   AND lower(y.academic_year_name) = v_year LIMIT 1) AS closed_by,
               v_open AS open_lines, v_notdue AS not_due_lines,
               -- QA BUG-034: the page disables "Carry all due" until this day
               to_char(v_last, 'DD Mon YYYY') AS carry_from,
               (v_last IS NULL OR CURRENT_DATE >= v_last) AS carry_open;
        RETURN;
    END IF;

    -- ── Close / Reopen the session's fees
    IF p_operation = 'Close' THEN
        IF v_closed IS NOT NULL THEN
            RAISE EXCEPTION 'This session is already closed.';
        END IF;
        IF v_open > 0 THEN
            RAISE EXCEPTION '% fee line(s) are still to decide% Carry or write off every line first.',
                v_open, CASE WHEN v_notdue > 0 THEN ' (' || v_notdue || ' not due yet).' ELSE '.' END;
        END IF;
        UPDATE academic.academic_years
           SET fees_closed_at = now(), fees_closed_by = p_action_user_id
         WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND lower(academic_year_name) = v_year;
        OPEN p_result FOR SELECT 'Session ' || p_academic_year || ' is closed.' AS message;
        RETURN;
    END IF;
    IF p_operation = 'Reopen' THEN
        IF v_closed IS NULL THEN
            RAISE EXCEPTION 'This session is not closed.';
        END IF;
        UPDATE academic.academic_years
           SET fees_closed_at = NULL, fees_closed_by = NULL
         WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND lower(academic_year_name) = v_year;
        OPEN p_result FOR SELECT 'Session ' || p_academic_year || ' is open again.' AS message;
        RETURN;
    END IF;

    -- ── List: the session's open lines, its write-offs, and what it carried forward
    IF p_operation = 'List' THEN
        OPEN p_result FOR
        -- the class the child was in during THIS session (core.student_enrolment):
        -- a child already promoted has next session's class on the student row
        SELECT l.ledger_id, l.student_id, s.student_name, s.admission_no,
               COALESCE(e.class_name, s.class_name) AS class_name, COALESCE(e.section, s.section) AS section,
               s.guardian_name, s.mobile,
               l.fee_head_name, l.installment_label, l.due_date,
               CASE WHEN l.close_source = 'YearEnd' THEN l.closed_amount
                    ELSE l.amount_due - l.amount_paid - l.concession END   AS amount,
               CASE WHEN l.close_source = 'YearEnd'          THEN 'WrittenOff'
                    WHEN lower(l.carried_from) = v_year      THEN 'Carried'
                    ELSE 'Open' END                                         AS state,
               (NULLIF(l.due_date, '')::date > CURRENT_DATE)               AS not_due,
               CASE WHEN l.close_source = 'YearEnd' THEN l.close_reason
                    WHEN lower(l.carried_from) = v_year THEN 'Moved to ' || l.academic_year END AS reason,
               COALESCE(CASE WHEN l.close_source = 'YearEnd' THEN l.closed_at END, l.carried_at) AS decided_at,
               v_next AS next_session
          FROM core.student_ledger l
          JOIN core.students s ON s.student_id = l.student_id
                              AND s.tenant_id = p_tenant_id AND s.school_id = p_school_id
          LEFT JOIN core.student_enrolment e ON e.student_id = l.student_id AND lower(e.academic_year) = v_year
         WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
           AND (   (lower(COALESCE(NULLIF(trim(l.academic_year), ''), s.academic_year)) = v_year
                    AND (l.amount_due > l.amount_paid + l.concession
                         OR (l.close_source = 'YearEnd' AND l.closed_amount > 0)))
                OR (lower(l.carried_from) = v_year AND l.amount_due > l.amount_paid + l.concession))
         ORDER BY COALESCE(e.class_name, s.class_name), COALESCE(e.section, s.section), s.student_name,
                  l.student_id, l.due_date NULLS LAST, l.ledger_id;
        RETURN;
    END IF;

    IF p_operation NOT IN ('Carry', 'WriteOff', 'Undo', 'CarryAll') THEN
        RAISE EXCEPTION 'Unknown operation.';
    END IF;
    IF v_closed IS NOT NULL THEN
        RAISE EXCEPTION 'Session % is closed. Re-open it to change anything.', p_academic_year;
    END IF;
    IF p_operation = 'WriteOff' AND v_reason IS NULL THEN
        RAISE EXCEPTION 'Give a reason for the write-off.';
    END IF;
    IF p_operation IN ('Carry', 'WriteOff') AND p_ledger_id IS NULL AND p_student_id IS NULL THEN
        RAISE EXCEPTION 'Choose a fee line or a student.';
    END IF;
    IF p_operation = 'Undo' AND p_ledger_id IS NULL THEN
        RAISE EXCEPTION 'Choose a fee line.';
    END IF;
    IF p_operation IN ('Carry', 'CarryAll') AND v_next IS NULL THEN
        RAISE EXCEPTION 'Create the next session first (School Setup › Sessions): carried dues move into it.';
    END IF;
    -- Carrying moves dues into next session's books; it is the year-end step. Done in
    -- October it put that month's fees under 2027-28, out of every 2026-27 report.
    -- Write-off stays open all year (waiving a due is an everyday decision).
    IF p_operation IN ('Carry', 'CarryAll') AND v_last IS NOT NULL AND CURRENT_DATE < v_last THEN
        RAISE EXCEPTION 'Dues can be carried to the next session from % (the last month of %). Until then collect them, or write them off.',
            to_char(v_last, 'DD Mon YYYY'), p_academic_year;
    END IF;

    -- The lines this call acts on, always inside this school: the session's own
    -- lines, and for Undo also the lines it carried into the next session.
    FOR r IN
        SELECT l.ledger_id, l.carried_from, l.close_source, l.closed_amount,
               l.amount_due - l.amount_paid - l.concession AS open_amount,
               COALESCE(NULLIF(l.due_date, '')::date, CURRENT_DATE) <= CURRENT_DATE AS is_due,
               lower(COALESCE(NULLIF(trim(l.academic_year), ''), s.academic_year)) = v_year AS in_session
          FROM core.student_ledger l
          JOIN core.students s ON s.student_id = l.student_id
         WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
           AND (lower(COALESCE(NULLIF(trim(l.academic_year), ''), s.academic_year)) = v_year
                OR (p_operation = 'Undo' AND lower(l.carried_from) = v_year))
           AND (p_ledger_id  IS NULL OR l.ledger_id  = p_ledger_id)
           AND (p_student_id IS NULL OR l.student_id = p_student_id)
         ORDER BY l.ledger_id
           FOR UPDATE OF l
    LOOP
        IF p_operation = 'Undo' THEN
            IF r.close_source = 'YearEnd' AND r.closed_amount > 0 THEN
                v_amount := v_amount + core.fn_ledger_reopen(r.ledger_id);
                v_count  := v_count + 1;
            ELSIF lower(r.carried_from) = v_year THEN
                UPDATE core.student_ledger
                   SET academic_year = carried_from, carried_from = NULL, carried_at = NULL, carried_by = NULL, updated_at = now()
                 WHERE ledger_id = r.ledger_id;
                v_amount := v_amount + r.open_amount;
                v_count  := v_count + 1;
            END IF;

        ELSIF r.open_amount > 0 AND r.in_session THEN
            IF NOT r.is_due THEN
                -- one line asked for by name gets a reason; a student / CarryAll just skips it
                IF p_ledger_id IS NOT NULL THEN
                    RAISE EXCEPTION 'This fee is not due yet. Only dues of past and current months can be carried or written off.';
                END IF;
                CONTINUE;
            END IF;
            IF p_operation = 'WriteOff' THEN
                v_amount := v_amount + core.fn_ledger_close(r.ledger_id, v_reason, 'YearEnd', p_action_user_id);
                v_count  := v_count + 1;
            ELSE   -- Carry / CarryAll: move into the next session
                UPDATE core.student_ledger
                   SET carried_from = COALESCE(NULLIF(trim(academic_year), ''), (SELECT s2.academic_year FROM core.students s2 WHERE s2.student_id = student_ledger.student_id)),
                       academic_year = v_next, carried_at = now(), carried_by = p_action_user_id, updated_at = now()
                 WHERE ledger_id = r.ledger_id;
                v_amount := v_amount + r.open_amount;
                v_count  := v_count + 1;
            END IF;
        END IF;
    END LOOP;

    IF v_count = 0 THEN
        RAISE EXCEPTION 'Nothing to change: the line is already settled, decided or not due yet.';
    END IF;

    OPEN p_result FOR
    SELECT v_count AS lines, v_amount AS amount,
           CASE p_operation
                WHEN 'WriteOff' THEN 'Written off'
                WHEN 'Undo'     THEN 'Undone'
                ELSE 'Carried to ' || v_next END
           || ': ' || v_count || ' line(s), ₹' || to_char(v_amount, 'FM99,99,99,990.00') AS message;
END;
$procedure$;


-- ── 7. Transport: Remove closes only bus fees not yet due; RemovePreview (BUG-046)
CREATE OR REPLACE PROCEDURE core.sp_transport_assign_manage(IN p_operation character varying, IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_student_id integer, IN p_route_id integer DEFAULT NULL::integer, IN p_stop_id integer DEFAULT NULL::integer, IN p_academic_year character varying DEFAULT NULL::character varying, IN p_start_date date DEFAULT NULL::date, IN p_months integer DEFAULT 12, INOUT p_result refcursor DEFAULT 'result_cursor'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_fare        numeric(12,2);
    v_stop_name   varchar(80);
    v_route_name  varchar(80);
    v_start       date;
    v_month_start date;
    v_i           integer;
    v_made        integer := 0;
    v_student_year varchar;
    v_year        varchar;
    v_sess_end    date;
    v_months      integer;
    v_max         integer;
    v_due         date;
    v_already     numeric(12,2);
    v_closed      numeric(12,2);
    v_reason      varchar(200);
    v_open        boolean;
    v_same_route  boolean;
    v_same_stop   boolean;
    v_seats       integer;
    v_riders      integer;
    r             record;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR p_student_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;

    IF p_operation = 'GetForStudent' THEN
        OPEN p_result FOR
        SELECT a.assignment_id, a.route_id, a.stop_id, a.monthly_fare, a.start_date,
               rt.route_name, s.stop_name
        FROM core.student_transport a
        -- "rt", not "r": r is a record variable of this proc, and PL/pgSQL read
        -- r.route_name as that (unassigned) variable -- every call failed.
        LEFT JOIN core.transport_routes rt ON rt.route_id = a.route_id
        LEFT JOIN core.transport_stops  s ON s.stop_id  = a.stop_id
        WHERE a.student_id = p_student_id AND a.tenant_id = p_tenant_id AND a.school_id = p_school_id
          AND a.is_active = TRUE AND COALESCE(a.is_deleted, FALSE) = FALSE
        ORDER BY a.assignment_id DESC
        LIMIT 1;

    ELSIF p_operation = 'SaveAssignment' THEN
        -- The student must be ours and still on the roll. Without this a stop
        -- of this school could be billed to ANY student id, including another
        -- school's, with the ledger rows written under this school's tenant.
        SELECT academic_year INTO v_student_year
        FROM core.students
        WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
          AND is_active = TRUE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Student not found, or no longer on the roll.';
        END IF;

        SELECT s.monthly_fare, s.stop_name, rt.route_name,
               (s.is_active AND rt.is_active AND NOT COALESCE(rt.is_deleted, FALSE))
          INTO v_fare, v_stop_name, v_route_name, v_open
        FROM core.transport_stops s
        JOIN core.transport_routes rt ON rt.route_id = s.route_id
        WHERE s.stop_id = p_stop_id AND s.route_id = p_route_id
          AND s.tenant_id = p_tenant_id AND s.school_id = p_school_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Selected stop not found.';
        END IF;

        -- Is the child already on this route / stop? Promotion re-bills a kept
        -- route for the new session through this same call, and that must keep
        -- working even if the route has since been closed or filled up.
        v_same_route := EXISTS (SELECT 1 FROM core.student_transport
                                 WHERE student_id = p_student_id AND route_id = p_route_id
                                   AND is_active AND NOT COALESCE(is_deleted, FALSE));
        v_same_stop  := EXISTS (SELECT 1 FROM core.student_transport
                                 WHERE student_id = p_student_id AND stop_id = p_stop_id
                                   AND is_active AND NOT COALESCE(is_deleted, FALSE));

        -- A switched-off route, a deleted route or a removed stop takes no new
        -- riders.
        IF NOT v_open AND NOT v_same_stop THEN
            RAISE EXCEPTION 'Route % / stop % is not in service. Pick an active route and stop.',
                v_route_name, v_stop_name;
        END IF;

        -- Seats: the route's active buses decide how many children it takes.
        -- Unlimited when no active bus on the route has a capacity set.
        IF NOT v_same_route THEN
            v_seats  := core.fn_transport_route_seats(p_route_id);
            -- riders already on the bus by the day this one starts
            v_riders := core.fn_transport_route_riders(p_route_id, p_student_id, COALESCE(p_start_date, CURRENT_DATE));
            IF v_seats IS NOT NULL AND v_riders >= v_seats THEN
                RAISE EXCEPTION 'Route % is full: % of % seats taken. Add a vehicle or pick another route.',
                    v_route_name, v_riders, v_seats;
            END IF;
        END IF;

        v_start := COALESCE(p_start_date, CURRENT_DATE);
        v_year  := COALESCE(NULLIF(TRIM(p_academic_year), ''), v_student_year);

        -- A start before the child joined would bill months they were not here.
        IF v_start < (SELECT NULLIF(admission_date, '')::date FROM core.students WHERE student_id = p_student_id) THEN
            RAISE EXCEPTION 'The bus start date is before the student''s admission date.';
        END IF;

        -- Bill to the end of the SESSION the assignment is for, read from its
        -- real end date. The controllers used to send a month count worked out
        -- from the session NAME on an April-March assumption, and this proc
        -- trusted it, so a 12-month count from October ran into the next session.
        SELECT NULLIF(end_date, '')::date, GREATEST(v_start, NULLIF(start_date, '')::date)
          INTO v_sess_end, v_start
        FROM academic.academic_years
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND academic_year_name = v_year AND COALESCE(is_deleted, FALSE) = FALSE
        LIMIT 1;
        -- (a start before the session begins is moved to the session's first day:
        --  an advance admission in February does not bill March of the old session)
        v_start := COALESCE(v_start, COALESCE(p_start_date, CURRENT_DATE));

        v_months := GREATEST(COALESCE(NULLIF(p_months, 0), 12), 1);
        IF v_sess_end IS NOT NULL THEN
            v_max := ((EXTRACT(YEAR FROM v_sess_end) * 12 + EXTRACT(MONTH FROM v_sess_end))
                    - (EXTRACT(YEAR FROM v_start)    * 12 + EXTRACT(MONTH FROM v_start)))::integer + 1;
            IF v_max <= 0 THEN
                RAISE EXCEPTION 'The start date is after session % ends.', v_year;
            END IF;
            v_months := LEAST(v_months, v_max);
        END IF;

        -- Replace the current assignment. Its unpaid dues from the start month
        -- on are CLOSED, not deleted: the row stays (a cancelled receipt may
        -- still point at it) with the reason, who and when, and only the part
        -- nobody paid is taken off. See student_money_lifecycle.sql.
        v_reason := 'Route changed on ' || to_char(v_start, 'YYYY-MM-DD');
        FOR r IN
            SELECT ledger_id FROM core.student_ledger
            WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
              AND fee_head_name = 'Transport Fee'
              AND due_date::date >= DATE_TRUNC('month', v_start)::date
              AND amount_due - amount_paid - concession > 0
        LOOP
            PERFORM core.fn_ledger_close(r.ledger_id, v_reason, 'Transport', p_action_user_id);
        END LOOP;

        UPDATE core.student_transport
        SET is_active = FALSE, is_deleted = TRUE,
            end_reason = 'Replaced by ' || COALESCE(v_route_name, '') || ' / ' || COALESCE(v_stop_name, '') ||
                         ' on ' || to_char(v_start, 'YYYY-MM-DD'),
            ended_by = p_action_user_id, ended_at = NOW(),
            updated_by = p_action_user_id, updated_at = NOW()
        WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
          AND is_active = TRUE;

        INSERT INTO core.student_transport
            (tenant_id, school_id, student_id, route_id, stop_id, monthly_fare,
             academic_year, start_date, created_by)
        VALUES
            (p_tenant_id, p_school_id, p_student_id, p_route_id, p_stop_id, v_fare,
             v_year, v_start, p_action_user_id);

        -- One 'Transport Fee' due per month. A month that already holds settled
        -- money (paid, or paid then closed) is only topped up to the new fare,
        -- so a part-paid month is never charged twice.
        v_month_start := DATE_TRUNC('month', v_start)::date;
        FOR v_i IN 0 .. v_months - 1 LOOP
            v_due := (v_month_start + make_interval(months => v_i))::date;

            SELECT COALESCE(SUM(amount_due), 0) INTO v_already
            FROM core.student_ledger
            WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
              AND fee_head_name = 'Transport Fee'
              AND due_date::date = v_due;

            IF v_already < v_fare THEN
                INSERT INTO core.student_ledger
                    (tenant_id, school_id, student_id, fee_head_name, frequency,
                     installment_label, due_date, amount_due, status, academic_year)
                VALUES
                    (p_tenant_id, p_school_id, p_student_id, 'Transport Fee', 'Monthly',
                     TO_CHAR(v_due, 'Mon YYYY'), v_due, v_fare - v_already, 'Pending', v_year);
                v_made := v_made + 1;
            END IF;
        END LOOP;

        OPEN p_result FOR
        SELECT TRUE AS success,
               'Transport assigned. ' || v_made || ' monthly due(s) generated.' AS message,
               v_fare AS monthly_fare, v_made AS months_generated;

    ELSIF p_operation = 'RemovePreview' THEN
        -- What "Remove Transport" will do, for the confirm dialog (QA BUG-046):
        -- months not due yet are closed; months already due (the child rode the
        -- bus) stay owed.
        OPEN p_result FOR
        SELECT COALESCE(SUM(amount_due - amount_paid - concession)
                        FILTER (WHERE due_date::date > CURRENT_DATE), 0)            AS future_amount,
               COUNT(*) FILTER (WHERE due_date::date > CURRENT_DATE)::int           AS future_months,
               COALESCE(SUM(amount_due - amount_paid - concession)
                        FILTER (WHERE due_date::date <= CURRENT_DATE), 0)           AS overdue_amount,
               COUNT(*) FILTER (WHERE due_date::date <= CURRENT_DATE)::int          AS overdue_months
          FROM core.student_ledger
         WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
           AND fee_head_name = 'Transport Fee'
           AND NULLIF(due_date, '') IS NOT NULL
           AND amount_due - amount_paid - concession > 0;

    ELSIF p_operation = 'RemoveAssignment' THEN
        -- Unpaid bus dues NOT YET DUE are CLOSED with a reason (never deleted),
        -- including the unpaid part of a month that was paid in part. Months
        -- whose due date has passed stay owed: the child used the bus (QA BUG-046,
        -- this used to close the current, already overdue month too). Money
        -- already taken stays on the row and can be refunded.
        v_reason := 'Transport removed on ' || to_char(CURRENT_DATE, 'YYYY-MM-DD');
        v_closed := 0;
        FOR r IN
            SELECT ledger_id FROM core.student_ledger
            WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
              AND fee_head_name = 'Transport Fee'
              AND due_date::date > CURRENT_DATE
              AND amount_due - amount_paid - concession > 0
        LOOP
            v_closed := v_closed + core.fn_ledger_close(r.ledger_id, v_reason, 'Transport', p_action_user_id);
        END LOOP;

        UPDATE core.student_transport
        SET is_active = FALSE, is_deleted = TRUE,
            end_reason = v_reason, ended_by = p_action_user_id, ended_at = NOW(),
            updated_by = p_action_user_id, updated_at = NOW()
        WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
          AND is_active = TRUE;

        OPEN p_result FOR SELECT TRUE AS success,
               'Transport removed.' ||
               CASE WHEN v_closed > 0
                    THEN ' ₹' || to_char(v_closed, 'FM99,99,99,990.00') || ' of bus fees not yet due closed.'
                    ELSE '' END AS message;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;


-- ── 8. Month-wise Dues: unpaid lines of earlier sessions stay visible (BUG-031)
CREATE OR REPLACE PROCEDURE core.sp_fee_month_dues(IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_academic_year character varying, IN p_from_month character varying DEFAULT NULL::character varying, IN p_upto_month character varying DEFAULT NULL::character varying, IN p_class character varying DEFAULT NULL::character varying, IN p_section character varying DEFAULT NULL::character varying, INOUT p_months refcursor DEFAULT 'fmd_months'::refcursor, INOUT p_classes refcursor DEFAULT 'fmd_classes'::refcursor, INOUT p_students refcursor DEFAULT 'fmd_students'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_upto  date;
    v_from  date;
    v_start date;
    v_hold  integer;
    v_class varchar := NULLIF(trim(COALESCE(p_class, '')), '');
    v_sec   varchar := NULLIF(trim(COALESCE(p_section, '')), '');
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;
    IF NULLIF(trim(p_academic_year), '') IS NULL THEN
        RAISE EXCEPTION 'Choose the session.';
    END IF;

    -- the last day of the chosen month (default: this month)
    v_upto := (date_trunc('month', COALESCE(to_date(NULLIF(trim(p_upto_month), ''), 'YYYY-MM'), CURRENT_DATE))
               + interval '1 month - 1 day')::date;
    -- the session's first day, for lines without a due date
    SELECT NULLIF(y.start_date, '')::date INTO v_start
      FROM academic.academic_years y
     WHERE y.tenant_id = p_tenant_id AND y.school_id = p_school_id AND y.academic_year_name = p_academic_year
     LIMIT 1;
    v_start := COALESCE(v_start, date_trunc('month', CURRENT_DATE)::date);
    v_from := COALESCE(to_date(NULLIF(trim(p_from_month), ''), 'YYYY-MM'), DATE '1900-01-01');
    IF v_from > v_upto THEN
        RAISE EXCEPTION 'The "from" month is after the "to" month.';
    END IF;

    DROP TABLE IF EXISTS _fmd_kids;
    CREATE TEMP TABLE _fmd_kids ON COMMIT DROP AS
    SELECT s.student_id, s.public_id, s.student_name, s.admission_no, s.guardian_name, s.mobile,
           COALESCE(e.class_name, s.class_name) AS class_name, COALESCE(e.section, s.section) AS section,
           COALESCE(NULLIF(trim(e.roll_no), ''), s.roll_no) AS roll_no,
           CASE WHEN e.status IN ('Left', 'PassedOut') THEN e.status
                WHEN NOT COALESCE(s.is_active, TRUE) THEN COALESCE(NULLIF(s.status, ''), 'Left')
                ELSE 'Active' END AS kid_status
      FROM core.students s
      LEFT JOIN core.student_enrolment e ON e.student_id = s.student_id AND e.academic_year = p_academic_year
     WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id
       AND (e.student_id IS NOT NULL
            OR EXISTS (SELECT 1 FROM core.student_ledger l WHERE l.student_id = s.student_id AND l.academic_year = p_academic_year))
       AND (v_class IS NULL OR COALESCE(e.class_name, s.class_name) = v_class)
       AND (v_sec   IS NULL OR COALESCE(e.section, s.section) = v_sec);

    DROP TABLE IF EXISTS _fmd_lines;
    CREATE TEMP TABLE _fmd_lines ON COMMIT DROP AS
    SELECT l.student_id,
           date_trunc('month', COALESCE(NULLIF(l.due_date, '')::date, v_start))::date AS month,
           l.amount_due, l.amount_paid + l.concession AS settled,
           GREATEST(l.amount_due - l.amount_paid - l.concession, 0) AS pending,
           (l.fee_head_name = 'Late Fee') AS is_late,   -- money owed, but not a "month pending" of its own
           -- QA BUG-031: a line of an EARLIER session still unpaid (not carried, not
           -- written off) is still owed, so it shows here, labelled with its session
           CASE WHEN l.academic_year = p_academic_year THEN NULL ELSE l.academic_year END AS old_session
      FROM core.student_ledger l
      JOIN _fmd_kids k ON k.student_id = l.student_id
     WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
       AND (l.academic_year = p_academic_year
            OR (l.amount_due > l.amount_paid + l.concession
                AND COALESCE(l.close_source, '') <> 'YearEnd'
                AND EXISTS (SELECT 1 FROM academic.academic_years oy
                             WHERE oy.tenant_id = p_tenant_id AND oy.school_id = p_school_id
                               AND oy.academic_year_name = l.academic_year
                               AND NOT COALESCE(oy.is_deleted, FALSE)
                               AND NULLIF(oy.start_date, '')::date < v_start)))
       AND COALESCE(NULLIF(l.due_date, '')::date, v_start) BETWEEN v_from AND v_upto;

    OPEN p_months FOR
    SELECT to_char(month, 'YYYY-MM') AS month, SUM(amount_due) AS due, SUM(settled) AS collected,
           SUM(pending) AS pending, COUNT(DISTINCT student_id) FILTER (WHERE pending > 0)::int AS children,
           old_session AS session
      FROM _fmd_lines GROUP BY month, old_session ORDER BY month, old_session NULLS LAST;

    OPEN p_classes FOR
    SELECT k.class_name, COALESCE(k.section, '') AS section, COUNT(*)::int AS children,
           COUNT(*) FILTER (WHERE p.pending > 0)::int AS with_dues, COALESCE(SUM(p.pending), 0) AS pending
      FROM _fmd_kids k
      LEFT JOIN (SELECT student_id, SUM(pending) AS pending FROM _fmd_lines GROUP BY student_id) p ON p.student_id = k.student_id
     GROUP BY k.class_name, k.section
     ORDER BY COALESCE((SELECT MIN(c.display_order) FROM academic.academic_classes c
                          JOIN academic.academic_years y ON y.academic_year_id = c.academic_year_id
                         WHERE c.tenant_id = p_tenant_id AND c.school_id = p_school_id
                           AND y.academic_year_name = p_academic_year AND c.class_name = k.class_name
                           AND NOT COALESCE(c.is_deleted, FALSE)), 999),
              k.class_name, k.section;

    -- hold after N months pending (fee_dues_followup.sql; 0 = no hold rule)
    SELECT hold_after_months INTO v_hold FROM core.fee_dues_settings WHERE tenant_id = p_tenant_id AND school_id = p_school_id;
    v_hold := COALESCE(v_hold, 3);

    OPEN p_students FOR
    WITH pend AS (
        SELECT student_id, SUM(pending) AS pending,
               COUNT(DISTINCT month) FILTER (WHERE pending > 0 AND NOT is_late)::int AS months_count,
               string_agg(DISTINCT to_char(month, 'YYYY-MM'), ',') FILTER (WHERE pending > 0 AND NOT is_late) AS months,
               MIN(month) FILTER (WHERE pending > 0 AND NOT is_late) AS oldest,
               SUM(pending) FILTER (WHERE is_late) AS late_fee
          FROM _fmd_lines GROUP BY student_id
        HAVING SUM(pending) > 0
    ), att AS (
        -- the last 21 days: days the child's class register was taken, and the child's own present days
        SELECT k.student_id,
               (SELECT MAX(a.attendance_date) FROM core.student_attendance a
                 WHERE a.student_id = k.student_id AND a.status IN ('Present', 'Late')) AS last_present,
               (SELECT COUNT(DISTINCT a.attendance_date) FROM core.student_attendance a
                 WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
                   AND a.class_name = k.class_name AND COALESCE(a.section, '') = COALESCE(k.section, '')
                   AND a.attendance_date >= to_char(CURRENT_DATE - 21, 'YYYY-MM-DD'))::int AS class_days,
               (SELECT COUNT(*) FROM core.student_attendance a
                 WHERE a.student_id = k.student_id AND a.status IN ('Present', 'Late')
                   AND a.attendance_date >= to_char(CURRENT_DATE - 21, 'YYYY-MM-DD'))::int AS present_days
          FROM _fmd_kids k
         WHERE k.student_id IN (SELECT student_id FROM pend)
    )
    SELECT k.student_id, k.public_id, k.student_name, COALESCE(k.admission_no, '') AS admission_no,
           COALESCE(k.guardian_name, '') AS guardian_name, COALESCE(k.mobile, '') AS mobile,
           k.class_name, COALESCE(k.section, '') AS section, COALESCE(k.roll_no, '') AS roll_no, k.kid_status,
           p.pending, p.months_count, COALESCE(p.months, '') AS months, to_char(p.oldest, 'YYYY-MM') AS oldest_month,
           COALESCE((SELECT MAX(fp.payment_date) FROM core.fee_payments fp
                      WHERE fp.student_id = k.student_id AND NOT COALESCE(fp.is_cancelled, FALSE)), '') AS last_payment,
           COALESCE(a.last_present, '') AS last_present, a.class_days, a.present_days,
           (k.kid_status = 'Active' AND a.class_days >= 5 AND a.present_days = 0) AS may_have_left,
           COALESCE(p.late_fee, 0) AS late_fee,
           COALESCE((SELECT to_char(MAX(r.sent_at) AT TIME ZONE 'Asia/Kolkata', 'YYYY-MM-DD') FROM core.fee_reminder_log r
                      WHERE r.tenant_id = p_tenant_id AND r.school_id = p_school_id AND r.student_id = k.student_id
                        AND COALESCE(r.channels_delivered, '') <> ''), '') AS last_reminded,
           COALESCE(f.note, '') AS followup_note, COALESCE(f.promise_date::text, '') AS promise_date,
           COALESCE(nc.reason, '') AS no_chase,
           (v_hold > 0 AND p.months_count >= v_hold AND nc.reason IS NULL) AS on_hold
      FROM pend p
      JOIN _fmd_kids k ON k.student_id = p.student_id
      LEFT JOIN att a ON a.student_id = p.student_id
      -- the latest open follow-up note, and an active "don't chase"
      LEFT JOIN LATERAL (SELECT fu.note, fu.promise_date FROM core.fee_followups fu
                          WHERE fu.tenant_id = p_tenant_id AND fu.school_id = p_school_id AND fu.student_id = k.student_id AND NOT fu.is_done
                          ORDER BY fu.followup_id DESC LIMIT 1) f ON TRUE
      LEFT JOIN core.fee_no_chase nc ON nc.tenant_id = p_tenant_id AND nc.school_id = p_school_id AND nc.student_id = k.student_id
                                    AND nc.is_active AND (nc.until_date IS NULL OR nc.until_date >= CURRENT_DATE)
     ORDER BY p.pending DESC, k.student_name;
END;
$procedure$;


-- ── 9. Day Close messages use ₹, not Rs (BUG-026)
CREATE OR REPLACE PROCEDURE core.sp_fee_day_close(IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_date date, IN p_counted_cash numeric, IN p_remarks character varying, INOUT p_result refcursor DEFAULT 'result_cursor'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_date           date;
    v_iso            varchar(10);
    v_collected      numeric(12,2);
    v_refunded       numeric(12,2);
    v_cash_collected numeric(12,2);
    v_cash_refunded  numeric(12,2);
    v_expected       numeric(12,2);
    v_diff           numeric(12,2);
    v_modes          jsonb;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;
    v_date := COALESCE(p_date, CURRENT_DATE);
    v_iso  := to_char(v_date, 'YYYY-MM-DD');

    IF v_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'A future date can not be closed.';
    END IF;
    IF p_counted_cash IS NULL OR p_counted_cash < 0 THEN
        RAISE EXCEPTION 'Enter the cash counted in the drawer (zero or more).';
    END IF;
    IF core.fn_fee_day_closed(p_tenant_id, p_school_id, p_action_user_id, v_date) THEN
        RAISE EXCEPTION 'This day is already closed. Re-open it first to record a new count.';
    END IF;

    SELECT COALESCE(SUM(amount), 0),
           COALESCE(SUM(amount) FILTER (WHERE mode = 'Cash'), 0)
      INTO v_collected, v_cash_collected
    FROM core.fn_fee_money_lines(p_tenant_id, p_school_id, v_date, v_date)
    WHERE user_id = p_action_user_id;

    SELECT COALESCE(SUM(amount), 0),
           COALESCE(SUM(amount) FILTER (WHERE COALESCE(NULLIF(trim(refund_mode), ''), 'Cash') = 'Cash'), 0)
      INTO v_refunded, v_cash_refunded
    FROM core.fee_refunds
    WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND refunded_by = p_action_user_id
      AND refunded_at::date = v_date;

    v_expected := v_cash_collected - v_cash_refunded;
    v_diff     := p_counted_cash - v_expected;

    -- A drawer that does not tally needs a reason on record (QA BUG-097).
    IF v_diff <> 0 AND NULLIF(trim(p_remarks), '') IS NULL THEN
        RAISE EXCEPTION 'The cash is % by ₹%. Write a remark explaining the difference.',
            CASE WHEN v_diff < 0 THEN 'short' ELSE 'over' END, to_char(abs(v_diff), 'FM99,99,99,990.00');
    END IF;

    v_modes := (SELECT jsonb_agg(jsonb_build_object('mode', mode, 'amount', amt) ORDER BY mode)
                FROM (SELECT mode, SUM(amount) AS amt
                      FROM core.fn_fee_money_lines(p_tenant_id, p_school_id, v_date, v_date)
                      WHERE user_id = p_action_user_id
                      GROUP BY mode HAVING SUM(amount) <> 0) t);

    -- The current-state row. A re-opened day's row is re-used (its last count is
    -- already in the log), so the unique key still holds.
    INSERT INTO core.fee_day_close
        (tenant_id, school_id, close_date, cashier_id, total_collected, total_refunded,
         expected_cash, counted_cash, difference, mode_breakup, remarks, closed_by)
    VALUES
        (p_tenant_id, p_school_id, v_iso, p_action_user_id, v_collected, v_refunded,
         v_expected, p_counted_cash, v_diff, v_modes, NULLIF(trim(p_remarks), ''), p_action_user_id)
    ON CONFLICT (tenant_id, school_id, close_date, cashier_id)
    DO UPDATE SET total_collected = EXCLUDED.total_collected,
                  total_refunded  = EXCLUDED.total_refunded,
                  expected_cash   = EXCLUDED.expected_cash,
                  counted_cash    = EXCLUDED.counted_cash,
                  difference      = EXCLUDED.difference,
                  mode_breakup    = EXCLUDED.mode_breakup,
                  remarks         = EXCLUDED.remarks,
                  closed_by       = EXCLUDED.closed_by,
                  closed_at       = NOW(),
                  reopened_at     = NULL,
                  reopened_by     = NULL,
                  reopen_reason   = NULL;

    INSERT INTO core.fee_day_close_log
        (tenant_id, school_id, close_date, cashier_id, action, total_collected, total_refunded,
         expected_cash, counted_cash, difference, mode_breakup, note, action_by)
    VALUES
        (p_tenant_id, p_school_id, v_iso, p_action_user_id, 'Close', v_collected, v_refunded,
         v_expected, p_counted_cash, v_diff, v_modes, NULLIF(trim(p_remarks), ''), p_action_user_id);

    OPEN p_result FOR
    SELECT TRUE AS success,
           'Day ' || to_char(v_date, 'DD Mon YYYY') || ' closed. Expected cash ₹'
             || to_char(v_expected, 'FM99,99,99,990.00')
             || CASE WHEN v_diff = 0 THEN ', the drawer tallies.'
                     WHEN v_diff < 0 THEN ', short by ₹' || to_char(-v_diff, 'FM99,99,99,990.00') || '.'
                     ELSE ', over by ₹' || to_char(v_diff, 'FM99,99,99,990.00') || '.' END AS message,
           v_expected AS expected_cash,
           v_diff     AS difference;
END;
$procedure$;



-- ── 10. Attendance Overview: the session whose dates contain the day (BUG-037)
CREATE OR REPLACE PROCEDURE core.sp_attendance_overview(IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_day date, IN p_from date, IN p_to date, INOUT p_today refcursor DEFAULT 'ao_today'::refcursor, INOUT p_sections refcursor DEFAULT 'ao_sections'::refcursor, INOUT p_weeks refcursor DEFAULT 'ao_weeks'::refcursor, INOUT p_missing refcursor DEFAULT 'ao_missing'::refcursor, INOUT p_dayinfo refcursor DEFAULT 'ao_day'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_year_id integer;
    v_year    varchar;
    v_start   date;
    v_from    date;
    v_to      date;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    -- QA BUG-037: one rule for every attendance screen -- the day belongs to the
    -- session whose dates contain it (core.fn_session_on, as the roster and the
    -- register use), not to whichever session is marked current. Falls back to
    -- the current session when no session covers the day.
    SELECT y.academic_year_id, y.academic_year_name, NULLIF(y.start_date::text, '')::date
      INTO v_year_id, v_year, v_start
      FROM academic.academic_years y
     WHERE y.tenant_id = p_tenant_id AND y.school_id = p_school_id AND NOT COALESCE(y.is_deleted, FALSE)
       AND y.academic_year_name = core.fn_session_on(p_tenant_id, p_school_id, COALESCE(p_day, CURRENT_DATE))
     LIMIT 1;

    IF v_year_id IS NULL THEN
    SELECT y.academic_year_id, y.academic_year_name, NULLIF(y.start_date::text, '')::date
      INTO v_year_id, v_year, v_start
      FROM academic.academic_years y
     WHERE y.tenant_id = p_tenant_id AND y.school_id = p_school_id
       AND COALESCE(y.is_current, FALSE) AND NOT COALESCE(y.is_deleted, FALSE)
     LIMIT 1;
    END IF;

    v_from := GREATEST(COALESCE(p_from, CURRENT_DATE - 29), COALESCE(v_start, p_from, CURRENT_DATE - 29));
    v_to   := LEAST(COALESCE(p_to, CURRENT_DATE), CURRENT_DATE);

    -- the session's sections that have students, with their class teacher
    CREATE TEMP TABLE IF NOT EXISTS tmp_ao_sec (section_id int PRIMARY KEY, class_name varchar, section varchar,
                                                display_order int, students int, teacher_id int, teacher varchar,
                                                start_on date) ON COMMIT DROP;
    TRUNCATE tmp_ao_sec;
    INSERT INTO tmp_ao_sec
    SELECT x.* FROM (
        SELECT sec.academic_class_section_id, c.class_name, sec.section_name, COALESCE(c.display_order, 0),
               -- the section's roll for this session (core.student_enrolment): a child
               -- promoted early still belongs here until the session ends
               (SELECT COUNT(*) FROM core.student_enrolment e
                 WHERE e.tenant_id = p_tenant_id AND e.school_id = p_school_id
                   AND e.academic_year = v_year AND COALESCE(e.status, '') NOT IN ('Left', 'PassedOut')
                   AND e.class_name = c.class_name AND lower(COALESCE(e.section, '')) = lower(sec.section_name))::int AS students,
               sec.class_teacher_staff_id, st.full_name,
               -- the day the section's first (active) student was admitted
               COALESCE((SELECT MIN(NULLIF(s.admission_date, '')::date)
                           FROM core.student_enrolment e JOIN core.students s ON s.student_id = e.student_id
                          WHERE e.tenant_id = p_tenant_id AND e.school_id = p_school_id
                            AND e.academic_year = v_year AND COALESCE(e.status, '') NOT IN ('Left', 'PassedOut')
                            AND e.class_name = c.class_name AND lower(COALESCE(e.section, '')) = lower(sec.section_name)), v_start) AS start_on
          FROM academic.academic_class_sections sec
          JOIN academic.academic_classes c ON c.academic_class_id = sec.academic_class_id
          LEFT JOIN core.staff st ON st.staff_id = sec.class_teacher_staff_id
         WHERE sec.tenant_id = p_tenant_id AND sec.school_id = p_school_id AND sec.academic_year_id = v_year_id
           AND NOT COALESCE(sec.is_deleted, FALSE) AND NOT COALESCE(c.is_deleted, FALSE)) x
     WHERE x.students > 0;

    -- working days in the range
    CREATE TEMP TABLE IF NOT EXISTS tmp_ao_days (d date PRIMARY KEY) ON COMMIT DROP;
    TRUNCATE tmp_ao_days;
    IF v_from <= v_to THEN
        INSERT INTO tmp_ao_days
        SELECT g::date FROM generate_series(v_from, v_to, interval '1 day') g
         WHERE core.fn_school_working_days(p_tenant_id, p_school_id, g::date, g::date) > 0;
    END IF;

    -- registers actually taken in the range: section x date, with counts
    CREATE TEMP TABLE IF NOT EXISTS tmp_ao_reg (section_id int, d date, marked int, present int, same_day boolean) ON COMMIT DROP;
    TRUNCATE tmp_ao_reg;
    INSERT INTO tmp_ao_reg
    SELECT ts.section_id, a.attendance_date::date, COUNT(*)::int,
           COUNT(*) FILTER (WHERE a.status IN ('Present', 'Late'))::int,
           MIN(a.marked_at)::date <= a.attendance_date::date
      FROM core.student_attendance a
      JOIN tmp_ao_sec ts ON ts.class_name = a.class_name AND lower(ts.section) = lower(COALESCE(a.section, ''))
     WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id AND a.academic_year = v_year
       AND a.attendance_date BETWEEN to_char(v_from, 'YYYY-MM-DD') AND to_char(v_to, 'YYYY-MM-DD')
     GROUP BY ts.section_id, a.attendance_date;

    -- ── Today: every section with that day's marks
    OPEN p_today FOR
    SELECT ts.section_id, ts.class_name, ts.section, ts.display_order, ts.students, ts.teacher_id, ts.teacher,
           COUNT(a.attendance_id)::int                                         AS marked,
           COUNT(*) FILTER (WHERE a.status = 'Present')::int                   AS present,
           COUNT(*) FILTER (WHERE a.status = 'Absent')::int                    AS absent,
           COUNT(*) FILTER (WHERE a.status = 'Late')::int                      AS late,
           COUNT(*) FILTER (WHERE a.status = 'Leave')::int                     AS leave,
           core.fn_user_display_name(MIN(a.marked_by))                         AS marked_by,
           -- as text on the school's clock: a timestamp that travels through a DataTable
           -- loses its UTC tag, and the page would show 06:29 for 11:59 IST
           to_char(MIN(a.marked_at) AT TIME ZONE 'Asia/Kolkata', 'DD Mon, HH12:MI AM') AS marked_at
      FROM tmp_ao_sec ts
      LEFT JOIN core.student_attendance a
             ON a.tenant_id = p_tenant_id AND a.school_id = p_school_id AND a.academic_year = v_year
            AND a.class_name = ts.class_name AND lower(COALESCE(a.section, '')) = lower(ts.section)
            AND a.attendance_date = to_char(COALESCE(p_day, CURRENT_DATE), 'YYYY-MM-DD')
     GROUP BY ts.section_id, ts.class_name, ts.section, ts.display_order, ts.students, ts.teacher_id, ts.teacher
     ORDER BY ts.display_order, ts.class_name, ts.section;

    -- ── Insights per section
    OPEN p_sections FOR
    SELECT ts.section_id, ts.class_name, ts.section, ts.display_order, ts.students, ts.teacher_id, ts.teacher,
           (SELECT COUNT(*) FROM tmp_ao_days dd WHERE dd.d >= ts.start_on)::int                     AS expected,
           (SELECT COUNT(*) FROM tmp_ao_reg r JOIN tmp_ao_days dd ON dd.d = r.d WHERE r.section_id = ts.section_id)::int AS taken,
           (SELECT COUNT(*) FROM tmp_ao_reg r JOIN tmp_ao_days dd ON dd.d = r.d WHERE r.section_id = ts.section_id AND r.same_day)::int AS same_day,
           (SELECT COALESCE(SUM(r.marked), 0) FROM tmp_ao_reg r WHERE r.section_id = ts.section_id)::int  AS marked,
           (SELECT COALESCE(SUM(r.present), 0) FROM tmp_ao_reg r WHERE r.section_id = ts.section_id)::int AS present
      FROM tmp_ao_sec ts
     ORDER BY ts.display_order, ts.class_name, ts.section;

    -- ── week by week (week starting Monday)
    OPEN p_weeks FOR
    SELECT to_char(w.wk, 'YYYY-MM-DD') AS week_start, w.first_day::text AS first_day, w.last_day::text AS last_day,
           (SELECT COUNT(*) FROM tmp_ao_days dd JOIN tmp_ao_sec ts ON ts.start_on <= dd.d
             WHERE date_trunc('week', dd.d) = w.wk)::int AS expected,
           (SELECT COUNT(*) FROM tmp_ao_reg r JOIN tmp_ao_days dd ON dd.d = r.d WHERE date_trunc('week', r.d) = w.wk)::int AS taken,
           (SELECT COALESCE(SUM(r.marked), 0) FROM tmp_ao_reg r WHERE date_trunc('week', r.d) = w.wk)::int AS marked,
           (SELECT COALESCE(SUM(r.present), 0) FROM tmp_ao_reg r WHERE date_trunc('week', r.d) = w.wk)::int AS present
      FROM (SELECT date_trunc('week', d) AS wk, MIN(d) AS first_day, MAX(d) AS last_day, COUNT(*) AS days
              FROM tmp_ao_days GROUP BY 1) w
     ORDER BY w.wk;

    -- ── registers never taken, newest first
    OPEN p_missing FOR
    SELECT to_char(dd.d, 'YYYY-MM-DD') AS day, ts.section_id, ts.class_name, ts.section, ts.teacher
      FROM tmp_ao_days dd
      JOIN tmp_ao_sec ts ON ts.start_on <= dd.d
     WHERE NOT EXISTS (SELECT 1 FROM tmp_ao_reg r WHERE r.section_id = ts.section_id AND r.d = dd.d)
     ORDER BY dd.d DESC, ts.display_order, ts.class_name, ts.section
     LIMIT 500;

    -- ── the chosen day
    OPEN p_dayinfo FOR
    SELECT core.fn_school_working_days(p_tenant_id, p_school_id, COALESCE(p_day, CURRENT_DATE), COALESCE(p_day, CURRENT_DATE)) AS working,
           (SELECT c.day_type || COALESCE(': ' || c.title, '') FROM academic.school_calendar c
             WHERE c.tenant_id = p_tenant_id AND c.school_id = p_school_id
               AND c.calendar_date = to_char(COALESCE(p_day, CURRENT_DATE), 'YYYY-MM-DD') LIMIT 1) AS note,
           to_char(v_from, 'YYYY-MM-DD') AS range_from, to_char(v_to, 'YYYY-MM-DD') AS range_to;
END;
$procedure$;



-- ── 11. Books & Uniform register: a past session keeps left / passed-out children (BUG-038)
CREATE OR REPLACE PROCEDURE core.sp_inventory_class_register(IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_academic_year character varying, IN p_class character varying, IN p_section character varying DEFAULT NULL::character varying, INOUT p_students refcursor DEFAULT 'register_students'::refcursor, INOUT p_items refcursor DEFAULT 'register_items'::refcursor, INOUT p_held refcursor DEFAULT 'register_held'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    CREATE TEMP TABLE IF NOT EXISTS _reg_kids (student_id integer) ON COMMIT DROP;
    TRUNCATE _reg_kids;
    INSERT INTO _reg_kids
    SELECT e.student_id
      FROM core.student_enrolment e
      JOIN core.students s ON s.student_id = e.student_id
     WHERE e.tenant_id = p_tenant_id AND e.school_id = p_school_id
       AND e.academic_year = p_academic_year AND e.class_name = p_class
       AND (NULLIF(trim(p_section), '') IS NULL OR COALESCE(e.section, '') = trim(p_section))
       -- QA BUG-038: a past session's register is a record, so it keeps the children
       -- who left or passed out; the current session lists only those on the roll.
       AND (   (COALESCE(e.status, '') NOT IN ('Left', 'PassedOut') AND COALESCE(s.is_active, TRUE))
            OR NOT EXISTS (SELECT 1 FROM academic.academic_years cy
                            WHERE cy.tenant_id = p_tenant_id AND cy.school_id = p_school_id
                              AND cy.academic_year_name = p_academic_year AND cy.is_current
                              AND NOT COALESCE(cy.is_deleted, FALSE)));

    OPEN p_students FOR
    SELECT s.student_id, s.student_name, s.admission_no, e.section,
           COALESCE(NULLIF(trim(e.roll_no), ''), s.roll_no) AS roll_no
      FROM _reg_kids k
      JOIN core.students s ON s.student_id = k.student_id
      JOIN core.student_enrolment e ON e.student_id = k.student_id AND e.academic_year = p_academic_year
     ORDER BY e.section, NULLIF(regexp_replace(COALESCE(NULLIF(trim(e.roll_no), ''), s.roll_no, ''), '\D', '', 'g'), '')::int NULLS LAST,
              s.student_name;

    OPEN p_items FOR
    SELECT i.item_id, i.item_name, COALESCE(NULLIF(trim(i.category), ''), 'Other') AS category
      FROM core.inventory_items i
     WHERE i.tenant_id = p_tenant_id AND i.school_id = p_school_id AND NOT i.is_deleted
       AND ((i.is_active AND i.item_type = 'Saleable' AND (i.for_class IS NULL OR p_class = ANY (i.for_class)))
            OR EXISTS (SELECT 1 FROM core.inventory_student_sale_lines l
                         JOIN core.inventory_student_sales sa ON sa.sale_id = l.sale_id
                        WHERE l.item_id = i.item_id AND sa.academic_year = p_academic_year
                          AND sa.student_id IN (SELECT student_id FROM _reg_kids)))
     ORDER BY 3, i.item_name;

    OPEN p_held FOR
    SELECT sa.student_id, l.item_id,
           SUM(l.quantity) AS quantity,
           SUM(COALESCE(sl.amount_due - sl.amount_paid - sl.concession, 0)) AS unpaid
      FROM core.inventory_student_sale_lines l
      JOIN core.inventory_student_sales sa ON sa.sale_id = l.sale_id
      LEFT JOIN core.student_ledger sl ON sl.ledger_id = l.ledger_id
     WHERE sa.tenant_id = p_tenant_id AND sa.school_id = p_school_id
       AND sa.academic_year = p_academic_year
       AND l.returned_at IS NULL
       AND sa.student_id IN (SELECT student_id FROM _reg_kids)
     GROUP BY sa.student_id, l.item_id;
END;
$procedure$;


CREATE OR REPLACE PROCEDURE core.sp_inventory_register_overview(IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_academic_year character varying, INOUT p_students refcursor DEFAULT 'overview_students'::refcursor, INOUT p_items refcursor DEFAULT 'overview_items'::refcursor, INOUT p_held refcursor DEFAULT 'overview_held'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    OPEN p_students FOR
    SELECT e.student_id, e.class_name, COALESCE(e.section, '') AS section,
           COALESCE((SELECT c.display_order FROM academic.academic_classes c
                       JOIN academic.academic_years y ON y.academic_year_id = c.academic_year_id
                      WHERE c.tenant_id = p_tenant_id AND c.school_id = p_school_id
                        AND y.academic_year_name = p_academic_year AND c.class_name = e.class_name
                        AND NOT COALESCE(c.is_deleted, FALSE)
                      LIMIT 1), 999) AS class_order
      FROM core.student_enrolment e
      JOIN core.students s ON s.student_id = e.student_id
     WHERE e.tenant_id = p_tenant_id AND e.school_id = p_school_id
       AND e.academic_year = p_academic_year
       -- QA BUG-038: a past session's register is a record, so it keeps the children
       -- who left or passed out; the current session lists only those on the roll.
       AND (   (COALESCE(e.status, '') NOT IN ('Left', 'PassedOut') AND COALESCE(s.is_active, TRUE))
            OR NOT EXISTS (SELECT 1 FROM academic.academic_years cy
                            WHERE cy.tenant_id = p_tenant_id AND cy.school_id = p_school_id
                              AND cy.academic_year_name = p_academic_year AND cy.is_current
                              AND NOT COALESCE(cy.is_deleted, FALSE)));

    OPEN p_items FOR
    SELECT i.item_id, i.item_name, COALESCE(NULLIF(trim(i.category), ''), 'Other') AS category,
           array_to_string(i.for_class, '|') AS for_class
      FROM core.inventory_items i
     WHERE i.tenant_id = p_tenant_id AND i.school_id = p_school_id AND NOT i.is_deleted
       AND ((i.is_active AND i.item_type = 'Saleable')
            OR EXISTS (SELECT 1 FROM core.inventory_student_sale_lines l
                         JOIN core.inventory_student_sales sa ON sa.sale_id = l.sale_id
                        WHERE l.item_id = i.item_id AND sa.academic_year = p_academic_year))
     ORDER BY 3, i.item_name;

    OPEN p_held FOR
    SELECT DISTINCT sa.student_id, l.item_id
      FROM core.inventory_student_sale_lines l
      JOIN core.inventory_student_sales sa ON sa.sale_id = l.sale_id
     WHERE sa.tenant_id = p_tenant_id AND sa.school_id = p_school_id
       AND sa.academic_year = p_academic_year
       AND l.returned_at IS NULL;
END;
$procedure$;

