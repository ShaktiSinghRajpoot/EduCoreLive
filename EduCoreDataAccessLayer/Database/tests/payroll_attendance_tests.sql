-- Payroll <- Staff Attendance (staff_payroll.sql, absent_days): checks on the QA
-- Test School (tenant 32, school 45, admin login 62; QA Teacher = staff 92) for
-- September 2026, whose payslip is still a draft. The test adds an approved Sick
-- leave (9 Sep) and an approved Unpaid leave (10 Sep) itself.
-- Re-creates the payroll function/procs inside the transaction and ROLLS BACK.
-- Run from this folder:
--     psql ... -f payroll_attendance_tests.sql
\set ON_ERROR_STOP 1
BEGIN;
\ir ../staff_payroll.sql
\ir ../staff_self_service.sql

DO $t$
DECLARE
    TN int := 32; SC int := 45; ADMIN int := 62; QA_T int := 92;
    c refcursor; r record; v_base numeric; v_lop numeric; v_abs numeric; v_rate numeric; v_amt numeric;
    pass int := 0; fail int := 0;
BEGIN
    -- start from no attendance marks in September; add the two leaves
    DELETE FROM core.staff_attendance WHERE tenant_id = TN AND staff_id = QA_T AND att_date BETWEEN '2026-09-01' AND '2026-09-30';
    INSERT INTO core.staff_leave (tenant_id, school_id, staff_id, leave_type, from_date, to_date, days, status, applied_by) VALUES
        (TN, SC, QA_T, 'Sick',   '2026-09-09', '2026-09-09', 1, 'Approved', ADMIN),
        (TN, SC, QA_T, 'Unpaid', '2026-09-10', '2026-09-10', 1, 'Approved', ADMIN);

    -- 1. without attendance marks LOP is the approved Unpaid leave only (1 day, 10 Sep)
    PERFORM core.fn_staff_payslip_build(TN, SC, ADMIN, QA_T, 9, 2026);
    SELECT lop_days, absent_days INTO v_base, v_abs FROM core.staff_payroll WHERE tenant_id = TN AND staff_id = QA_T AND pay_month = 9 AND pay_year = 2026;
    IF v_base = 1 AND v_abs = 0 THEN pass := pass + 1; RAISE NOTICE 'PASS 1 leave-only LOP % day(s), absent 0', v_base;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 1 lop % absent %', v_base, v_abs; END IF;

    -- 2. marks: Absent 15 Sep (no leave) +1, HalfDay 16 Sep +0.5, Late 17 Sep +0,
    --    Absent 10 Sep (Unpaid leave, already counted) +0, Absent 9 Sep (Sick leave, paid) +0
    INSERT INTO core.staff_attendance (tenant_id, school_id, staff_id, att_date, status, marked_by) VALUES
        (TN, SC, QA_T, '2026-09-15', 'Absent',  ADMIN),
        (TN, SC, QA_T, '2026-09-16', 'HalfDay', ADMIN),
        (TN, SC, QA_T, '2026-09-17', 'Late',    ADMIN),
        (TN, SC, QA_T, '2026-09-10', 'Absent',  ADMIN),
        (TN, SC, QA_T, '2026-09-09', 'Absent',  ADMIN);
    PERFORM core.fn_staff_payslip_build(TN, SC, ADMIN, QA_T, 9, 2026);
    SELECT lop_days, absent_days, lop_amount, monthly_salary / working_days INTO v_lop, v_abs, v_amt, v_rate
      FROM core.staff_payroll WHERE tenant_id = TN AND staff_id = QA_T AND pay_month = 9 AND pay_year = 2026;
    IF v_lop = 2.5 AND v_abs = 1.5 THEN pass := pass + 1; RAISE NOTICE 'PASS 2 LOP % = 1 unpaid leave + % from attendance', v_lop, v_abs;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 2 lop % absent %', v_lop, v_abs; END IF;

    -- 3. the LOP amount follows the days (2.5 x the day rate, within rounding)
    IF abs(v_amt - round(2.5 * v_rate, 2)) <= 0.02 THEN pass := pass + 1; RAISE NOTICE 'PASS 3 LOP amount % (day rate %)', v_amt, round(v_rate, 2);
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 3 amount % rate %', v_amt, v_rate; END IF;

    -- 4. a regeneration is logged when attendance changes
    IF EXISTS (SELECT 1 FROM core.staff_payroll_history WHERE tenant_id = TN AND staff_id = QA_T AND pay_month = 9
                 AND pay_year = 2026 AND action = 'REGENERATED' AND lop_days = 2.5)
    THEN pass := pass + 1; RAISE NOTICE 'PASS 4 regeneration logged in the money trail';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 4 no history row'; END IF;

    -- 5. LIST and the staff member's own payslip carry absent_days
    CALL core.sp_staff_payroll_manage('LIST', TN, SC, ADMIN, 9, 2026, NULL, NULL, c);
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.staff_id = QA_T THEN v_abs := r.absent_days; END IF; END LOOP; CLOSE c;
    IF v_abs = 1.5 THEN pass := pass + 1; RAISE NOTICE 'PASS 5 LIST shows absent_days %', v_abs;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 5 %', v_abs; END IF;

    -- 6. a paid payslip is not changed by a later mark
    UPDATE core.staff_payroll SET status = 'Paid', payment_mode = 'Cash', paid_at = now(), paid_by = ADMIN
     WHERE tenant_id = TN AND staff_id = QA_T AND pay_month = 9 AND pay_year = 2026;
    INSERT INTO core.staff_attendance (tenant_id, school_id, staff_id, att_date, status, marked_by)
    VALUES (TN, SC, QA_T, '2026-09-18', 'Absent', ADMIN);
    IF core.fn_staff_payslip_build(TN, SC, ADMIN, QA_T, 9, 2026) = 'paid_differs'
       AND (SELECT lop_days FROM core.staff_payroll WHERE tenant_id = TN AND staff_id = QA_T AND pay_month = 9 AND pay_year = 2026) = 2.5
    THEN pass := pass + 1; RAISE NOTICE 'PASS 6 paid payslip kept, reported as differing';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 6'; END IF;

    RAISE NOTICE '== % passed, % failed ==', pass, fail;
END;
$t$;

ROLLBACK;
