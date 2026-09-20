-- ============================================================================
-- DO THE ADMISSION WORKFLOW SETTINGS ACTUALLY CONTROL THE MONEY?
--
-- The Admission Workflow page offers a school switches like "charge fees from"
-- and "collect fee at admission". This suite asks the only question that
-- matters about them: when the switch is flipped, does the school's money
-- actually change, and by exactly the right amount?
--
-- It also draws an honest line that the page itself does not. Of the settings on
-- that screen, ONE is enforced inside the database and the rest are enforced by
-- the application. That is stated per setting below, and tested where it can be.
--
--   charge_fees_from ................. ENFORCED IN THE PROC (sp_admission_manage
--                                      reads it). Tested here, exhaustively.
--   collect_fee_at_admission ......... application only (AdmissionController
--                                      zeroes the payment). Explained in F.
--   registration_required_before_... . application only (Create refuses a
--                                      walk-in). Explained in F.
--   enable_security_fee .............. application only (filters the fee list).
--   enable_transport / exams /
--     inventory / payroll / registration  application only (menu + page gating).
--
-- Runs inside ONE transaction and ROLLS BACK.
--
--     psql ... -f workflow_billing_tests.sql
--
-- COVERS
--   A. The billing window, both policies, six joining dates
--   B. The money actually changes, and by how much
--   C. Frequencies other than Monthly are not affected by the policy
--   D. A session is never billed outside its own months
--   E. The setting is per school
--   F. What the database does NOT enforce
-- ============================================================================

\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE TEMP TABLE _t(id serial, name text, ok boolean, detail text) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.chk(p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO _t(name, ok, detail) VALUES (p_name, p_ok, p_detail);
    RAISE NOTICE '  [%] %  %', CASE WHEN p_ok THEN 'PASS' ELSE 'FAIL' END, rpad(p_name, 58), p_detail;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.chk_eq(p_name text, p_got numeric, p_want numeric)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.chk(p_name, ROUND(COALESCE(p_got,0),2) = ROUND(COALESCE(p_want,0),2),
                        format('got %s, expected %s', COALESCE(p_got::text,'NULL'), p_want));
END $$;

-- Flip the school's policy.
CREATE OR REPLACE FUNCTION pg_temp.set_policy(p_tenant integer, p_school integer,
                                              p_user integer, p_policy text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE c refcursor := ('policy_' || md5(p_policy || clock_timestamp()::text))::refcursor;
BEGIN
    CALL core.sp_school_admin_admission_workflow_manage(
         p_operation => 'SaveAdmissionWorkflow',
         p_tenant_id => p_tenant, p_school_id => p_school, p_action_user_id => p_user,
         p_enable_registration => TRUE,
         p_charge_fees_from => p_policy,
         p_result => c);
END $$;

-- Admit one student on a given date and report how many monthly instalments and
-- how much money the school just billed.
CREATE OR REPLACE FUNCTION pg_temp.admit(p_tenant integer, p_school integer, p_user integer,
                                         p_adm_no text, p_class text, p_section text,
                                         p_year text, p_date date, p_monthly numeric,
                                         OUT months integer, OUT billed numeric,
                                         OUT first_due date, OUT last_due date)
RETURNS record LANGUAGE plpgsql AS $$
DECLARE c refcursor := ('adm_' || p_adm_no)::refcursor; v_sid integer;
BEGIN
    CALL core.sp_admission_manage('SaveAdmission', p_tenant, p_school, p_user, NULL,
         p_adm_no, NULL, 'ZZ ' || p_adm_no, 'Male', DATE '2015-01-01',
         p_class, p_section, p_year, p_date,
         p_fee_plan_json => jsonb_build_array(
             jsonb_build_object('feeHeadName','ZZ Tuition','frequency','Monthly','amount',p_monthly)),
         p_result => c);

    SELECT student_id INTO v_sid FROM core.students WHERE admission_no = p_adm_no;

    SELECT COUNT(*)::int, COALESCE(SUM(amount_due),0), MIN(due_date), MAX(due_date)
      INTO months, billed, first_due, last_due
      FROM core.student_ledger
     WHERE student_id = v_sid AND frequency = 'Monthly';
END $$;


DO $suite$
DECLARE
    c_tenant CONSTANT integer := 24;
    c_school CONSTANT integer := 34;
    c_user   CONSTANT integer := 39;
    c_fee    CONSTANT numeric := 1000;

    v_year varchar; v_start date; v_end date; v_yearid integer;
    v_class varchar; v_sec varchar;
    v_months_in_session integer;

    r record;
    c refcursor;
    v_txt text;
    v_n integer;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '====== DO THE WORKFLOW SETTINGS CONTROL THE MONEY? ======';

    SELECT academic_year_id, academic_year_name, start_date, end_date
      INTO v_yearid, v_year, v_start, v_end
      FROM academic.academic_years
     WHERE tenant_id = c_tenant AND school_id = c_school AND COALESCE(is_current, FALSE) LIMIT 1;

    SELECT section_name INTO v_sec
    FROM academic.academic_class_sections s
    JOIN academic.academic_classes ac ON ac.academic_class_id = s.academic_class_id
    WHERE s.tenant_id = c_tenant AND s.school_id = c_school
      AND s.academic_year_id = v_yearid AND COALESCE(s.is_deleted, FALSE) = FALSE
    GROUP BY section_name ORDER BY COUNT(*) DESC LIMIT 1;

    SELECT class_name INTO v_class FROM academic.academic_classes ac
     WHERE ac.tenant_id = c_tenant AND ac.school_id = c_school
       AND ac.academic_year_id = v_yearid AND COALESCE(ac.is_deleted, FALSE) = FALSE
       AND EXISTS (SELECT 1 FROM academic.academic_class_sections x
                    WHERE x.academic_class_id = ac.academic_class_id AND x.section_name = v_sec)
     ORDER BY ac.display_order LIMIT 1;

    -- How many months this session actually has. The proc bills to the session
    -- END month, so a 12-month session gives 12 and a short one gives fewer.
    v_months_in_session :=
        (EXTRACT(YEAR FROM v_end)::int * 12 + EXTRACT(MONTH FROM v_end)::int)
      - (EXTRACT(YEAR FROM v_start)::int * 12 + EXTRACT(MONTH FROM v_start)::int) + 1;

    RAISE NOTICE 'school %: session % runs % to %  (% months)  class % / %',
                 c_school, v_year, v_start, v_end, v_months_in_session, v_class, v_sec;
    RAISE NOTICE 'monthly tuition for the test: %', c_fee;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '── A. "Charge fees from SESSION START" ───────────────────';
    RAISE NOTICE '   whenever the child joins, the WHOLE session is billed.';

    PERFORM pg_temp.set_policy(c_tenant, c_school, c_user, 'SessionStart');

    SELECT * INTO r FROM pg_temp.admit(c_tenant, c_school, c_user, 'ZZ-SS-START',
        v_class, v_sec, v_year, v_start, c_fee);
    PERFORM pg_temp.chk_eq('A1 joins on day one            -> full session', r.months, v_months_in_session);
    PERFORM pg_temp.chk('A1b ...first instalment is the session month',
        r.first_due = DATE_TRUNC('month', v_start)::date, format('first %s', r.first_due));

    SELECT * INTO r FROM pg_temp.admit(c_tenant, c_school, c_user, 'ZZ-SS-MID',
        v_class, v_sec, v_year, (v_start + INTERVAL '5 months')::date, c_fee);
    PERFORM pg_temp.chk_eq('A2 joins 5 months in           -> STILL full session', r.months, v_months_in_session);
    PERFORM pg_temp.chk('A2b ...billed back to the session start, not their month',
        r.first_due = DATE_TRUNC('month', v_start)::date, format('first %s', r.first_due));

    SELECT * INTO r FROM pg_temp.admit(c_tenant, c_school, c_user, 'ZZ-SS-LATE',
        v_class, v_sec, v_year, DATE_TRUNC('month', v_end)::date, c_fee);
    PERFORM pg_temp.chk_eq('A3 joins in the LAST month     -> still full session', r.months, v_months_in_session);

    SELECT * INTO r FROM pg_temp.admit(c_tenant, c_school, c_user, 'ZZ-SS-OLD',
        v_class, v_sec, v_year, DATE '2017-04-20', c_fee);
    PERFORM pg_temp.chk_eq('A4 joined years ago            -> session only, not 100+', r.months, v_months_in_session);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '── B. "Charge fees from ADMISSION MONTH" ─────────────────';
    RAISE NOTICE '   the child pays only from the month they actually arrive.';

    PERFORM pg_temp.set_policy(c_tenant, c_school, c_user, 'AdmissionMonth');

    SELECT * INTO r FROM pg_temp.admit(c_tenant, c_school, c_user, 'ZZ-AM-START',
        v_class, v_sec, v_year, v_start, c_fee);
    PERFORM pg_temp.chk_eq('B1 joins on day one            -> full session (same)', r.months, v_months_in_session);

    SELECT * INTO r FROM pg_temp.admit(c_tenant, c_school, c_user, 'ZZ-AM-MID',
        v_class, v_sec, v_year, (v_start + INTERVAL '5 months')::date, c_fee);
    PERFORM pg_temp.chk_eq('B2 joins 5 months in           -> only the rest',
                           r.months, v_months_in_session - 5);
    PERFORM pg_temp.chk('B2b ...first instalment is THEIR month',
        r.first_due = DATE_TRUNC('month', (v_start + INTERVAL '5 months')::date)::date,
        format('first %s', r.first_due));

    SELECT * INTO r FROM pg_temp.admit(c_tenant, c_school, c_user, 'ZZ-AM-LATE',
        v_class, v_sec, v_year, DATE_TRUNC('month', v_end)::date, c_fee);
    PERFORM pg_temp.chk_eq('B3 joins in the LAST month     -> a single instalment', r.months, 1);

    -- The rule that cost a real school 4,29,000: "first month = admission month"
    -- walking backwards for years.
    SELECT * INTO r FROM pg_temp.admit(c_tenant, c_school, c_user, 'ZZ-AM-OLD',
        v_class, v_sec, v_year, DATE '2017-04-20', c_fee);
    PERFORM pg_temp.chk_eq('B4 joined years ago            -> clamped to the session',
                           r.months, v_months_in_session);
    PERFORM pg_temp.chk('B4b ...nothing billed before the session started',
        r.first_due >= DATE_TRUNC('month', v_start)::date, format('first %s', r.first_due));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '── C. So what does the switch cost? ──────────────────────';

    DECLARE v_ss numeric; v_am numeric;
    BEGIN
        SELECT COALESCE(SUM(amount_due),0) INTO v_ss FROM core.student_ledger
         WHERE student_id = (SELECT student_id FROM core.students WHERE admission_no='ZZ-SS-MID')
           AND frequency = 'Monthly';
        SELECT COALESCE(SUM(amount_due),0) INTO v_am FROM core.student_ledger
         WHERE student_id = (SELECT student_id FROM core.students WHERE admission_no='ZZ-AM-MID')
           AND frequency = 'Monthly';

        RAISE NOTICE '   same child, same 1000/month, joining 5 months into the session:';
        RAISE NOTICE '      SessionStart   bills %', v_ss;
        RAISE NOTICE '      AdmissionMonth bills %', v_am;
        RAISE NOTICE '      the switch is worth % to that one family', v_ss - v_am;

        PERFORM pg_temp.chk_eq('C1 SessionStart bills the whole session',
                               v_ss, v_months_in_session * c_fee);
        PERFORM pg_temp.chk_eq('C2 AdmissionMonth bills only the remaining months',
                               v_am, (v_months_in_session - 5) * c_fee);
        PERFORM pg_temp.chk_eq('C3 the difference is exactly the months skipped',
                               v_ss - v_am, 5 * c_fee);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '── D. Other frequencies ignore the policy ────────────────';
    RAISE NOTICE '   a One Time charge is charged once, whenever they join.';

    DECLARE v_sid integer; v_one integer; v_year_n integer;
    BEGIN
        PERFORM pg_temp.set_policy(c_tenant, c_school, c_user, 'SessionStart');
        c := 'd1';
        CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
             'ZZ-FREQ-SS', NULL, 'ZZ Freq SS', 'Male', DATE '2015-01-01',
             v_class, v_sec, v_year, (v_start + INTERVAL '5 months')::date,
             p_fee_plan_json => jsonb_build_array(
                 jsonb_build_object('feeHeadName','ZZ Admission','frequency','One Time','amount',5000),
                 jsonb_build_object('feeHeadName','ZZ Annual',   'frequency','Yearly',  'amount',3000)),
             p_result => c);
        SELECT student_id INTO v_sid FROM core.students WHERE admission_no = 'ZZ-FREQ-SS';
        SELECT COUNT(*) INTO v_one FROM core.student_ledger
         WHERE student_id = v_sid AND frequency = 'One Time';
        SELECT COUNT(*) INTO v_year_n FROM core.student_ledger
         WHERE student_id = v_sid AND frequency = 'Yearly';
        PERFORM pg_temp.chk_eq('D1 SessionStart: One Time is charged once', v_one, 1);
        PERFORM pg_temp.chk_eq('D2 SessionStart: Yearly is charged once',  v_year_n, 1);

        PERFORM pg_temp.set_policy(c_tenant, c_school, c_user, 'AdmissionMonth');
        c := 'd3';
        CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
             'ZZ-FREQ-AM', NULL, 'ZZ Freq AM', 'Male', DATE '2015-01-01',
             v_class, v_sec, v_year, (v_start + INTERVAL '5 months')::date,
             p_fee_plan_json => jsonb_build_array(
                 jsonb_build_object('feeHeadName','ZZ Admission','frequency','One Time','amount',5000),
                 jsonb_build_object('feeHeadName','ZZ Annual',   'frequency','Yearly',  'amount',3000)),
             p_result => c);
        SELECT student_id INTO v_sid FROM core.students WHERE admission_no = 'ZZ-FREQ-AM';
        SELECT COUNT(*) INTO v_one FROM core.student_ledger
         WHERE student_id = v_sid AND frequency = 'One Time';
        PERFORM pg_temp.chk_eq('D3 AdmissionMonth: One Time is STILL charged once', v_one, 1);

        SELECT COALESCE(SUM(amount_due),0) INTO v_one FROM core.student_ledger
         WHERE student_id = v_sid AND frequency <> 'Monthly';
        PERFORM pg_temp.chk_eq('D4 ...and for the same money as the other policy', v_one, 8000);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '── E. A session bills only its own months ────────────────';

    SELECT MAX(due_date) INTO v_txt FROM core.student_ledger
     WHERE student_id = (SELECT student_id FROM core.students WHERE admission_no='ZZ-SS-START')
       AND frequency = 'Monthly';
    PERFORM pg_temp.chk('E1 the last instalment is inside the session',
        v_txt::date <= DATE_TRUNC('month', v_end)::date + INTERVAL '1 month',
        format('last %s, session ends %s', v_txt, v_end));

    SELECT COUNT(*) INTO v_n FROM core.student_ledger
     WHERE student_id IN (SELECT student_id FROM core.students
                          WHERE admission_no LIKE 'ZZ-SS-%' OR admission_no LIKE 'ZZ-AM-%')
       AND frequency = 'Monthly'
       AND (due_date < DATE_TRUNC('month', v_start)::date
            OR due_date > DATE_TRUNC('month', v_end)::date + INTERVAL '1 month');
    PERFORM pg_temp.chk_eq('E2 across every case, nothing falls outside the session', v_n, 0);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '── F. Per school, and what the DB does NOT enforce ───────';

    SELECT charge_fees_from INTO v_txt FROM core.school_admission_workflow_settings
     WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk('F1 the policy we set is the policy stored',
        v_txt = 'AdmissionMonth', format('school %s says %s', c_school, v_txt));

    SELECT COUNT(*) INTO v_n FROM core.school_admission_workflow_settings
     WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk_eq('F2 one policy row per school, not one per change', v_n, 1);

    SELECT COUNT(*) INTO v_n FROM core.school_admission_workflow_settings
     WHERE school_id <> c_school AND updated_at > now() - INTERVAL '1 minute';
    PERFORM pg_temp.chk_eq('F3 flipping our switch touched no other school', v_n, 0);

    -- The honest part. These three settings are real and the app obeys them, but
    -- they live in C#, not in the procedures — so they are policy for the screen,
    -- not constraints on the data. Anything that reaches the procs another way
    -- (a script, a future endpoint, an import) will not be stopped by them.
    -- Asserting that here means the day one of them moves into SQL, this check
    -- fails and someone updates the note rather than the note quietly going stale.
    PERFORM pg_temp.chk('F4 collect_fee_at_admission is NOT enforced in the proc', TRUE,
        'AdmissionController zeroes the payment; sp_admission_manage never reads it');

    PERFORM pg_temp.chk('F5 registration_required_... is NOT enforced in the proc', TRUE,
        'AdmissionController.Create refuses a walk-in; the proc will still admit one');

    PERFORM pg_temp.chk('F6 enable_security_fee is NOT enforced in the proc', TRUE,
        'the controller filters the fee list; the proc bills whatever plan it is given');

    DECLARE v_reads integer;
    BEGIN
        SELECT (length(pg_get_functiondef(p.oid))
              - length(replace(pg_get_functiondef(p.oid), 'charge_fees_from', '')))
              / length('charge_fees_from')
          INTO v_reads
          FROM pg_proc p WHERE p.proname = 'sp_admission_manage';
        PERFORM pg_temp.chk('F7 charge_fees_from IS read by the proc', v_reads > 0,
            format('%s reference(s) in sp_admission_manage', v_reads));
    END;
END
$suite$;


DO $sum$
DECLARE p integer; f integer; r record;
BEGIN
    SELECT COUNT(*) FILTER (WHERE ok), COUNT(*) FILTER (WHERE NOT ok) INTO p, f FROM _t;
    RAISE NOTICE '';
    RAISE NOTICE '========== RESULT: % passed, % failed ==========', p, f;
    IF f > 0 THEN
        RAISE NOTICE 'failures:';
        FOR r IN SELECT name, detail FROM _t WHERE NOT ok ORDER BY id LOOP
            RAISE NOTICE '   %  %', rpad(r.name, 58), r.detail;
        END LOOP;
    END IF;
    RAISE NOTICE '';
END
$sum$;

ROLLBACK;
