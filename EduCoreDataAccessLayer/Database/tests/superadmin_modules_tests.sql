-- Super Admin modules per school + Login as School Admin (16 Oct 2026).
-- QA Test School (tenant 32, school 45, admin login 62); Super Admin user 1.
-- Everything happens inside the transaction and is ROLLED BACK. Run from this folder:
--     psql ... -f superadmin_modules_tests.sql
\set ON_ERROR_STOP 1
BEGIN;
\o NUL
\ir ../superadmin_modules_login_as.sql
\ir ../student_exit.sql
\ir ../student_promotion.sql
\ir ../transport_live_tracking.sql
\o

DO $t$
DECLARE
    T int := 32; S int := 45; A int := 62; SA int := 1;
    c refcursor; r record; v_n int; v_txt text;
    pass int := 0; fail int := 0;
BEGIN
    -- 1. a school user cannot change modules
    BEGIN
        c := 'c1';
        CALL core.sp_superadmin_school_modules('Save', A, S, FALSE, TRUE, TRUE, TRUE, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 1 school admin changed modules';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 1 %', SQLERRM; END;

    -- 2. Transport cannot be taken away while children ride
    BEGIN
        c := 'c2';
        CALL core.sp_superadmin_school_modules('Save', SA, S, FALSE, TRUE, TRUE, TRUE, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 2 transport taken away with riders';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 2 %', left(SQLERRM, 150); END;

    -- 3. Exams taken away: the school's Workflow read says off, and the school cannot switch it on
    c := 'c3';
    CALL core.sp_superadmin_school_modules('Save', SA, S, TRUE, FALSE, TRUE, TRUE, c);
    FETCH c INTO r; CLOSE c;
    c := 'c3b';
    CALL core.sp_school_admin_admission_workflow_manage('SaveAdmissionWorkflow', T, S, A,
         TRUE, FALSE, TRUE, TRUE, 'REG-', TRUE, FALSE, TRUE, TRUE, TRUE, TRUE, c);
    CLOSE c;
    c := 'c3c';
    CALL core.sp_school_admin_admission_workflow_manage('GetAdmissionWorkflow', T, S, A, p_result => c);
    FETCH c INTO r; CLOSE c;
    IF NOT r.enable_exams AND NOT r.allow_exams AND r.enable_transport
       AND NOT core.fn_module_on(T, S, 'exams') AND core.fn_module_on(T, S, 'transport')
    THEN pass := pass + 1; RAISE NOTICE 'PASS 3 exams not given: off, school switch ignored';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 3 enable_exams % allow_exams %', r.enable_exams, r.allow_exams; END IF;

    -- 4. given back: on again with the school's own switch
    c := 'c4';
    CALL core.sp_superadmin_school_modules('Save', SA, S, TRUE, TRUE, TRUE, TRUE, c);
    CLOSE c;
    IF core.fn_module_on(T, S, 'exams') THEN pass := pass + 1; RAISE NOTICE 'PASS 4 exams given back: on';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 4 exams still off'; END IF;

    -- 5. the school cannot switch Transport off while children ride
    BEGIN
        c := 'c5';
        CALL core.sp_school_admin_admission_workflow_manage('SaveAdmissionWorkflow', T, S, A,
             TRUE, FALSE, TRUE, TRUE, 'REG-', TRUE, FALSE, FALSE, TRUE, TRUE, TRUE, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 5 school switched transport off with riders';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 5 %', left(SQLERRM, 120); END;

    -- 6. with no riders and no bus dues, Transport can be taken away; re-admit then
    --    brings back no bus
    UPDATE core.student_transport SET is_active = FALSE WHERE tenant_id = T AND school_id = S;
    UPDATE core.student_ledger SET amount_due = amount_paid + COALESCE(concession, 0)
     WHERE tenant_id = T AND school_id = S AND fee_head_name = 'Transport Fee'
       AND amount_due - amount_paid - COALESCE(concession, 0) > 0;
    c := 'c6';
    CALL core.sp_superadmin_school_modules('Save', SA, S, FALSE, TRUE, TRUE, TRUE, c);
    FETCH c INTO r; CLOSE c;
    IF NOT r.allow_transport AND NOT core.fn_module_on(T, S, 'transport')
    THEN pass := pass + 1; RAISE NOTICE 'PASS 6 %', r.message;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 6 transport still on'; END IF;

    -- 7. Login as: the school's admin login and a log row; End closes it
    c := 'c7';
    CALL core.sp_superadmin_login_as('Start', SA, S, NULL, c);
    FETCH c INTO r; CLOSE c;
    c := 'c7b';
    CALL core.sp_superadmin_login_as('End', SA, NULL, r.log_id, c);
    CLOSE c;
    SELECT COUNT(*) INTO v_n FROM core.superadmin_login_as_log
     WHERE log_id = r.log_id AND super_user_id = SA AND school_id = S AND ended_at IS NOT NULL;
    IF r.user_id = A AND r.tenant_id = T AND v_n = 1
    THEN pass := pass + 1; RAISE NOTICE 'PASS 7 login as user % logged and closed', r.user_id;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 7 user % tenant % log %', r.user_id, r.tenant_id, v_n; END IF;

    -- 8. a school user cannot use Login as
    BEGIN
        c := 'c8';
        CALL core.sp_superadmin_login_as('Start', A, S, NULL, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 8 school admin used login as';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 8 %', SQLERRM; END;

    RAISE NOTICE '== % passed, % failed ==', pass, fail;
END;
$t$;

ROLLBACK;
