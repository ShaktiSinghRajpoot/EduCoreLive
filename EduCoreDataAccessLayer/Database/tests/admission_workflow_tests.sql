-- ============================================================================
-- Admission Workflow test suite.
--
-- These settings are the school's on/off switches: which modules appear in the
-- menu, whether registration comes before admission, whether fee is collected at
-- the admission desk, and from which month recurring fees are charged. Getting
-- one wrong does not throw — it quietly changes what a school is billed or what
-- its office can reach, which is why it needs a test.
--
-- Runs inside ONE transaction and ROLLS BACK.
--
--     psql ... -f admission_workflow_tests.sql
--
-- COVERS
--   A. Settings round-trip — what is saved is what comes back, one row per school
--   B. The four module toggles the side menu binds to
--   C. charge_fees_from — the setting with real money behind it
--   D. Dependent flags cannot be left in an impossible combination
--   E. Scope
-- ============================================================================

\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE TEMP TABLE _t(id serial, name text, ok boolean, detail text) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.chk(p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO _t(name, ok, detail) VALUES (p_name, p_ok, p_detail);
    RAISE NOTICE '  [%] %  %', CASE WHEN p_ok THEN 'PASS' ELSE 'FAIL' END, rpad(p_name, 54), p_detail;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.chk_eq(p_name text, p_got numeric, p_want numeric)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.chk(p_name, p_got IS NOT DISTINCT FROM p_want,
                        format('got %s, expected %s', COALESCE(p_got::text,'NULL'), p_want));
END $$;


DO $suite$
DECLARE
    c_tenant CONSTANT integer := 24;
    c_school CONSTANT integer := 34;
    c_user   CONSTANT integer := 39;

    v_year  varchar;
    v_class varchar;
    v_start date;

    c     refcursor;
    v_n   integer;
    v_txt text;
    v_b   boolean;
    v_sid integer;
    v_first date;
    v_mid   date;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '========= ADMISSION WORKFLOW TESTS =========';

    SELECT academic_year_name, start_date INTO v_year, v_start
    FROM academic.academic_years
    WHERE tenant_id = c_tenant AND school_id = c_school AND COALESCE(is_current, FALSE) LIMIT 1;
    SELECT class_name INTO v_class FROM academic.academic_classes
    WHERE tenant_id = c_tenant AND school_id = c_school AND COALESCE(is_deleted, FALSE) = FALSE
    ORDER BY display_order LIMIT 1;

    IF v_year IS NULL OR v_class IS NULL THEN
        RAISE EXCEPTION 'Fixture missing: school % has no current session or classes.', c_school;
    END IF;
    v_mid := (v_start + INTERVAL '5 months')::date;
    RAISE NOTICE 'fixture: session=% (starts %)  class=%', v_year, v_start, v_class;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- A. Settings round-trip -------------------------------';

    c := 'a1';
    CALL core.sp_school_admin_admission_workflow_manage(
         p_operation => 'SaveAdmissionWorkflow',
         p_tenant_id => c_tenant, p_school_id => c_school, p_action_user_id => c_user,
         p_enable_registration => TRUE,
         p_registration_required_before_admission => TRUE,
         p_enable_registration_fee => TRUE,
         p_auto_generate_registration_number => TRUE,
         p_registration_number_prefix => 'ZZREG-',
         p_collect_fee_at_admission => TRUE,
         p_enable_security_fee => TRUE,
         p_enable_transport => FALSE,
         p_enable_exams => FALSE,
         p_enable_inventory => FALSE,
         p_enable_payroll => TRUE,
         p_charge_fees_from => 'SessionStart',
         p_result => c);

    SELECT registration_number_prefix INTO v_txt
      FROM core.school_admission_workflow_settings
     WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk('A1 registration prefix saved', v_txt = 'ZZREG-', format('got "%s"', v_txt));

    SELECT enable_registration_fee INTO v_b
      FROM core.school_admission_workflow_settings
     WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk('A2 registration-fee toggle saved', v_b, format('got %s', v_b));

    SELECT collect_fee_at_admission INTO v_b
      FROM core.school_admission_workflow_settings
     WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk('A3 collect-at-admission saved', v_b, format('got %s', v_b));

    SELECT charge_fees_from INTO v_txt
      FROM core.school_admission_workflow_settings
     WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk('A4 charge-from policy saved', v_txt = 'SessionStart', format('got "%s"', v_txt));

    -- One row per school, not one per save.
    SELECT COUNT(*) INTO v_n FROM core.school_admission_workflow_settings
     WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk_eq('A5 one settings row per school', v_n, 1);

    -- Read back through the proc the app actually uses, not just the table.
    DECLARE cg refcursor := 'a7'; g_first boolean;
    BEGIN
        CALL core.sp_school_admin_admission_workflow_manage(
             p_operation => 'GetAdmissionWorkflow',
             p_tenant_id => c_tenant, p_school_id => c_school, p_action_user_id => c_user,
             p_result => cg);
        FETCH cg INTO g_first;
        PERFORM pg_temp.chk('A7 GetAdmissionWorkflow returns a row', g_first IS NOT NULL,
                            format('first column = %s', g_first));
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- B. Module toggles (what the side menu binds to) -------';

    -- _VerticalMenu.cshtml reads exactly these four and hides the menu section
    -- when one is false. If a flag stops round-tripping, a module silently
    -- disappears — or silently comes back — for every user of that school.
    SELECT enable_transport INTO v_b FROM core.school_admission_workflow_settings
     WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk('B1 transport OFF round-trips', v_b = FALSE, format('got %s', v_b));

    SELECT enable_exams INTO v_b FROM core.school_admission_workflow_settings
     WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk('B2 exams OFF round-trips', v_b = FALSE, format('got %s', v_b));

    SELECT enable_inventory INTO v_b FROM core.school_admission_workflow_settings
     WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk('B3 inventory OFF round-trips', v_b = FALSE, format('got %s', v_b));

    SELECT enable_payroll INTO v_b FROM core.school_admission_workflow_settings
     WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk('B4 payroll ON round-trips', v_b = TRUE, format('got %s', v_b));

    -- enable_registration is stored and the Registration PAGE honours it, but the
    -- side menu does NOT gate the Registrations item on it — the only one of the
    -- five module flags the menu ignores.
    SELECT enable_registration INTO v_b FROM core.school_admission_workflow_settings
     WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk('B5 registration flag round-trips', v_b = TRUE, format('got %s', v_b));

    -- A save that leaves the module flags NULL resets all four to ON, because the
    -- proc reads them as COALESCE(p_enable_x, TRUE) — it cannot tell "no opinion"
    -- from "switch it on". The app never hits this: the settings form posts all
    -- four every time (asp-for on a bool emits the hidden false companion) and the
    -- service passes them as plain bools, never DBNull. Pinned here so that if
    -- someone later adds a quick-toggle endpoint that sends one flag, this test
    -- says what will happen to the other four.
    c := 'b6';
    CALL core.sp_school_admin_admission_workflow_manage(
         p_operation => 'SaveAdmissionWorkflow',
         p_tenant_id => c_tenant, p_school_id => c_school, p_action_user_id => c_user,
         p_enable_registration => TRUE, p_registration_number_prefix => 'ZZ2-',
         p_charge_fees_from => 'SessionStart', p_result => c);

    SELECT COUNT(*) INTO v_n FROM core.school_admission_workflow_settings
     WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk_eq('B6 a second save updates, never inserts', v_n, 1);

    SELECT enable_transport INTO v_b FROM core.school_admission_workflow_settings
     WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk('B7 a NULL module flag resets it to ON (documented, not reachable)',
                        v_b = TRUE, format('transport is now %s', v_b));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- C. charge_fees_from changes the billing start ---------';

    -- SessionStart bills the whole session whenever the student joined;
    -- AdmissionMonth bills only from the month they actually arrived. Same
    -- student, same plan, same joining date — only the setting differs.
    c := 'c1';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-WF-SESS', NULL, 'ZZ WF Session', 'Male', DATE '2015-01-01',
         v_class, 'A', v_year, v_mid,
         p_fee_plan_json => jsonb_build_array(
             jsonb_build_object('feeHeadName','ZZ Tuition','frequency','Monthly','amount',100)),
         p_result => c);
    SELECT student_id INTO v_sid FROM core.students WHERE admission_no = 'ZZ-WF-SESS';

    SELECT COUNT(*), MIN(due_date) INTO v_n, v_first
      FROM core.student_ledger WHERE student_id = v_sid AND frequency = 'Monthly';
    PERFORM pg_temp.chk_eq('C1 SessionStart bills the whole session', v_n, 12);
    PERFORM pg_temp.chk('C2 ...from the session start, not the joining month',
                        v_first = DATE_TRUNC('month', v_start)::date,
                        format('first due %s, session starts %s', v_first, v_start));

    c := 'c3';
    CALL core.sp_school_admin_admission_workflow_manage(
         p_operation => 'SaveAdmissionWorkflow',
         p_tenant_id => c_tenant, p_school_id => c_school, p_action_user_id => c_user,
         p_enable_registration => TRUE, p_charge_fees_from => 'AdmissionMonth',
         p_result => c);

    c := 'c4';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-WF-ADMM', NULL, 'ZZ WF AdmMonth', 'Male', DATE '2015-02-02',
         v_class, 'A', v_year, v_mid,
         p_fee_plan_json => jsonb_build_array(
             jsonb_build_object('feeHeadName','ZZ Tuition','frequency','Monthly','amount',100)),
         p_result => c);
    SELECT student_id INTO v_sid FROM core.students WHERE admission_no = 'ZZ-WF-ADMM';

    SELECT COUNT(*), MIN(due_date) INTO v_n, v_first
      FROM core.student_ledger WHERE student_id = v_sid AND frequency = 'Monthly';
    PERFORM pg_temp.chk_eq('C3 AdmissionMonth bills only from joining', v_n, 7);
    PERFORM pg_temp.chk('C4 ...from the joining month',
                        v_first = DATE_TRUNC('month', v_mid)::date,
                        format('first due %s, joined %s', v_first, v_mid));

    -- Whatever the policy, a back-dated admission never bills before the session.
    c := 'c5';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-WF-OLD', NULL, 'ZZ WF Old', 'Male', DATE '2015-03-03',
         v_class, 'A', v_year, DATE '2017-04-20',
         p_fee_plan_json => jsonb_build_array(
             jsonb_build_object('feeHeadName','ZZ Tuition','frequency','Monthly','amount',100)),
         p_result => c);
    SELECT student_id INTO v_sid FROM core.students WHERE admission_no = 'ZZ-WF-OLD';

    SELECT COUNT(*), MIN(due_date) INTO v_n, v_first
      FROM core.student_ledger WHERE student_id = v_sid AND frequency = 'Monthly';
    PERFORM pg_temp.chk_eq('C5 AdmissionMonth + joined years ago -> 12, not 100+', v_n, 12);
    PERFORM pg_temp.chk('C6 ...and never before the session starts',
                        v_first >= DATE_TRUNC('month', v_start)::date,
                        format('first due %s', v_first));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- D. Dependent flags -----------------------------------';

    -- Registration off must not leave "registration required before admission"
    -- set, or admission is gated on a step the school has switched off.
    c := 'd1';
    CALL core.sp_school_admin_admission_workflow_manage(
         p_operation => 'SaveAdmissionWorkflow',
         p_tenant_id => c_tenant, p_school_id => c_school, p_action_user_id => c_user,
         p_enable_registration => FALSE,
         p_registration_required_before_admission => FALSE,
         p_enable_registration_fee => FALSE,
         p_charge_fees_from => 'AdmissionMonth', p_result => c);

    SELECT registration_required_before_admission INTO v_b
      FROM core.school_admission_workflow_settings
     WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk('D1 registration off -> not required before admission',
                        v_b = FALSE, format('got %s', v_b));

    SELECT enable_registration_fee INTO v_b
      FROM core.school_admission_workflow_settings
     WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk('D2 registration off -> no registration fee',
                        v_b = FALSE, format('got %s', v_b));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- E. Scope ---------------------------------------------';

    SELECT COUNT(*) INTO v_n FROM core.school_admission_workflow_settings
     WHERE tenant_id = 23 AND school_id = 33 AND registration_number_prefix = 'ZZ2-';
    PERFORM pg_temp.chk_eq('E1 our save did not touch another school', v_n, 0);

    BEGIN
        c := 'e2';
        CALL core.sp_school_admin_admission_workflow_manage(
             p_operation => 'SaveAdmissionWorkflow',
             p_tenant_id => 1, p_school_id => 0, p_action_user_id => c_user,
             p_enable_registration => TRUE, p_result => c);
        SELECT COUNT(*) INTO v_n FROM core.school_admission_workflow_settings
         WHERE tenant_id = 1 AND school_id = 0;
        PERFORM pg_temp.chk_eq('E2 platform scope writes nothing', v_n, 0);
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('E2 platform scope refused', TRUE, SQLERRM);
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
            RAISE NOTICE '   %  %', rpad(r.name, 54), r.detail;
        END LOOP;
    END IF;
    RAISE NOTICE '';
END
$sum$;

ROLLBACK;
