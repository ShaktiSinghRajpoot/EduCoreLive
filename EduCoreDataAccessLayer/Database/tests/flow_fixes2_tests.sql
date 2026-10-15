-- Real-world flow fixes, part 2 (15 Oct 2026): exam publish with missing marks,
-- advance wallet on the due list, bus start date / driver / seats, a driver who
-- leaves, payroll Mark Paid. QA Test School (tenant 32, school 45, admin login 62).
-- Everything happens inside the transaction and is ROLLED BACK. Run from this folder:
--     psql ... -f flow_fixes2_tests.sql
\set ON_ERROR_STOP 1
BEGIN;
\o NUL
\ir ../exam_results_publish.sql
\ir ../fee_due_list.sql
\ir ../transport_module.sql
\ir ../sp_staff_manage.sql
\ir ../staff_payroll.sql
\o

DO $t$
DECLARE
    T int := 32; S int := 45; A int := 62;
    c refcursor; c2 refcursor; c3 refcursor; c4 refcursor; r record;
    v_n int; v_num numeric; v_pid int;
    pass int := 0; fail int := 0;
BEGIN
    -- 1. results are not published while a roster student has no mark row
    UPDATE academic.exams SET results_status = 'Unpublished' WHERE exam_id = 53;
    UPDATE academic.exam_subjects SET exam_date = CURRENT_DATE - 1 WHERE exam_id = 53;  -- every paper written
    DELETE FROM academic.exam_marks
     WHERE exam_mark_id = (SELECT MIN(exam_mark_id) FROM academic.exam_marks WHERE exam_id = 53);
    BEGIN
        c := 'c1'; c2 := 'c1b'; c3 := 'c1c'; c4 := 'c1d';
        CALL academic.sp_school_admin_exam_results_manage('PublishResults', T, S, A, 53, NULL, NULL, NULL, c, c2, c3, c4);
        fail := fail + 1; RAISE NOTICE 'FAIL 1 published with a missing mark';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM LIKE '%missing%' THEN pass := pass + 1; RAISE NOTICE 'PASS 1 %', left(SQLERRM, 140);
        ELSE fail := fail + 1; RAISE NOTICE 'FAIL 1 other refusal: %', SQLERRM; END IF;
    END;

    -- 2. money in the advance wallet is set against the dues: a fully covered
    --    student leaves the due list
    INSERT INTO core.student_advance (student_id, tenant_id, school_id, balance, updated_at)
    VALUES (754, T, S, 9999999, now())
    ON CONFLICT (student_id) DO UPDATE SET balance = 9999999;
    c := 'c2';
    CALL core.sp_fee_due_list(T, S, A, 'Flow Kumar', NULL, NULL, 1, 50, NULL, NULL, c);
    v_n := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.student_id = 754 THEN v_n := v_n + 1; END IF; END LOOP; CLOSE c;
    IF v_n = 0 THEN pass := pass + 1; RAISE NOTICE 'PASS 2 wallet covers the dues: not on the due list';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 2 still on the due list'; END IF;

    -- 3. a bus start before the admission date is refused
    BEGIN
        c := 'c3';
        CALL core.sp_transport_assign_manage('SaveAssignment', T, S, A, 754, 37, 61, '2026-27', '2026-10-01', 12, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 3 bus start before admission accepted';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 3 %', SQLERRM; END;

    -- 4. a bus start before the session is moved to the session's first day
    --    (the child is billed from the admission month, nothing earlier)
    UPDATE core.students SET admission_date = '2026-03-01' WHERE student_id = 754;
    c := 'c4';
    CALL core.sp_transport_assign_manage('SaveAssignment', T, S, A, 754, 37, 61, '2026-27', '2026-03-01', 12, c);
    CLOSE c;
    SELECT start_date::date INTO r FROM core.student_transport WHERE student_id = 754 AND is_active;
    IF r.start_date >= '2026-04-01' THEN pass := pass + 1; RAISE NOTICE 'PASS 4 start moved to %', r.start_date;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 4 start %', r.start_date; END IF;

    -- 5. a bus cannot be cut below the children riding its route
    v_n := core.fn_transport_route_riders(38);
    BEGIN
        c := 'c5';
        CALL core.sp_transport_vehicle_manage('SaveVehicle', T, S, A, 4, 'HR26FZ1597', GREATEST(v_n - 1, 1), NULL, NULL, 38, 144, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 5 capacity cut below % riders', v_n;
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 5 %', SQLERRM; END;

    -- 6. an unchanged save of the same bus still works
    c := 'c6';
    CALL core.sp_transport_vehicle_manage('SaveVehicle', T, S, A, 4, 'HR26FZ1597', 50, NULL, NULL, 38, 144, c);
    FETCH c INTO r; CLOSE c;
    IF r.success THEN pass := pass + 1; RAISE NOTICE 'PASS 6 %', r.message;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 6 %', r.message; END IF;

    -- 7. a driver marked as left cannot be put on a bus
    UPDATE core.staff SET status = 'Inactive' WHERE staff_id = 144;
    BEGIN
        c := 'c7';
        CALL core.sp_transport_vehicle_manage('SaveVehicle', T, S, A, 4, 'HR26FZ1597', 50, NULL, NULL, 38, 144, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 7 left driver accepted';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 7 %', SQLERRM; END;
    UPDATE core.staff SET status = 'Active' WHERE staff_id = 144;

    -- 8. a driver who leaves is taken off the bus
    c := 'c8';
    CALL core.sp_staff_manage('DELETE', T, S, A, 144, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
         NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
         FALSE, NULL, NULL, NULL, NULL, c, CURRENT_DATE);
    CLOSE c;
    SELECT COUNT(*) INTO v_n FROM core.transport_vehicles WHERE driver_staff_id = 144;
    IF v_n = 0 THEN pass := pass + 1; RAISE NOTICE 'PASS 8 driver released from the bus';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 8 still driving % bus(es)', v_n; END IF;

    -- 9. Mark Paid pays today's figures, not an old draft
    UPDATE core.staff_payroll SET net_pay = 1 WHERE payroll_id = 973;
    c := 'c9';
    CALL core.sp_staff_payroll_manage('MARK_PAID', T, S, A, NULL, NULL, 973, NULL, c, 'Cash', NULL);
    CLOSE c;
    SELECT status, net_pay INTO r FROM core.staff_payroll WHERE staff_id = 91 AND pay_month = 9 AND pay_year = 2026;
    IF r.status = 'Paid' AND r.net_pay > 1 THEN pass := pass + 1; RAISE NOTICE 'PASS 9 paid % (draft rebuilt)', r.net_pay;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 9 % %', r.status, r.net_pay; END IF;

    -- 10. the running month cannot be marked paid
    c := 'c10';
    CALL core.sp_staff_payroll_manage('RUN', T, S, A, EXTRACT(MONTH FROM CURRENT_DATE)::int, EXTRACT(YEAR FROM CURRENT_DATE)::int, NULL, NULL, c);
    CLOSE c;
    SELECT MIN(payroll_id) INTO v_pid FROM core.staff_payroll
     WHERE tenant_id = T AND school_id = S AND status = 'Draft'
       AND pay_month = EXTRACT(MONTH FROM CURRENT_DATE) AND pay_year = EXTRACT(YEAR FROM CURRENT_DATE);
    BEGIN
        c := 'c10b';
        CALL core.sp_staff_payroll_manage('MARK_PAID', T, S, A, NULL, NULL, v_pid, NULL, c, 'Cash', NULL);
        fail := fail + 1; RAISE NOTICE 'FAIL 10 running month marked paid (payslip %)', v_pid;
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 10 %', SQLERRM; END;

    RAISE NOTICE '== % passed, % failed ==', pass, fail;
END;
$t$;

ROLLBACK;
