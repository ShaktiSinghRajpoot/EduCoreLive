-- ============================================================================
-- Staff Leave + Payroll test suite.
--
-- Payroll pays people. Leave feeds it: an approved unpaid leave becomes Loss of
-- Pay, and LOP is money. The two are tested together because the interesting
-- rules live in the join between them.
--
-- Runs inside ONE transaction and ROLLS BACK.
--
--     psql ... -f leave_payroll_tests.sql
--
-- COVERS
--   A. Leave apply — the date and overlap guards
--   B. Working days: Sundays are not counted
--   C. Decide — approve/reject once, and only once
--   D. Payroll run — gross, LOP, net
--   E. Only APPROVED UNPAID leave costs the staff member money
--   F. Mark paid — once, and not re-runnable afterwards
--   G. Scope
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

    c      refcursor;
    v_st1  integer;    -- takes unpaid leave
    v_st2  integer;    -- takes casual (paid) leave
    v_lv1  integer;
    v_lv2  integer;
    v_n    integer;
    v_txt  text;
    v_dec  numeric;

    v_mon  integer;    -- a month safely in the past
    v_yr   integer;
    v_m1   date;       -- its first day
    v_wd   integer;    -- working days in it
    v_gross numeric := 30000;
    v_perday numeric;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '========= LEAVE + PAYROLL TESTS =========';

    -- Work in last month, so nothing depends on today being mid-month.
    v_m1  := DATE_TRUNC('month', CURRENT_DATE - INTERVAL '1 month')::date;
    v_mon := EXTRACT(MONTH FROM v_m1)::int;
    v_yr  := EXTRACT(YEAR  FROM v_m1)::int;
    v_wd  := core.fn_working_days(v_m1, (v_m1 + INTERVAL '1 month - 1 day')::date);
    v_perday := ROUND(v_gross / NULLIF(v_wd, 0), 2);

    RAISE NOTICE 'fixture: payroll month %-%  (% working days, gross %, ~%/day)',
                 v_mon, v_yr, v_wd, v_gross, v_perday;

    INSERT INTO core.staff(tenant_id, school_id, full_name, designation, department,
                           mobile, monthly_salary, joining_date, status, created_by)
    VALUES (c_tenant, c_school, 'ZZ Leave One', 'Teacher', 'Teaching',
            '9990001111', v_gross, v_m1 - 400, 'Active', c_user)
    RETURNING staff_id INTO v_st1;

    INSERT INTO core.staff(tenant_id, school_id, full_name, designation, department,
                           mobile, monthly_salary, joining_date, status, created_by)
    VALUES (c_tenant, c_school, 'ZZ Leave Two', 'Teacher', 'Teaching',
            '9990002222', v_gross, v_m1 - 400, 'Active', c_user)
    RETURNING staff_id INTO v_st2;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- A. Leave apply — the guards --------------------------';

    BEGIN
        c := 'a1';
        CALL core.sp_staff_leave_manage('APPLY', c_tenant, c_school, c_user, NULL,
             v_st1, 'Casual', v_m1 + 10, v_m1 + 5, 'backwards', NULL, NULL, c);
        PERFORM pg_temp.chk('A1 to-date before from-date refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('A1 to-date before from-date refused', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'a2';
        CALL core.sp_staff_leave_manage('APPLY', c_tenant, c_school, c_user, NULL,
             v_st1, NULL, v_m1 + 1, v_m1 + 2, 'no type', NULL, NULL, c);
        PERFORM pg_temp.chk('A2 missing leave type refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('A2 missing leave type refused', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'a3';
        CALL core.sp_staff_leave_manage('APPLY', c_tenant, c_school, c_user, NULL,
             999999, 'Casual', v_m1 + 1, v_m1 + 2, 'ghost staff', NULL, NULL, c);
        PERFORM pg_temp.chk('A3 unknown staff member refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('A3 unknown staff member refused', TRUE, SQLERRM);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- B. Working days -------------------------------------';

    -- A Sunday-only range has no working days in it, so it cannot be leave.
    DECLARE v_sun date;
    BEGIN
        v_sun := v_m1 + ((7 - EXTRACT(DOW FROM v_m1)::int) % 7);   -- first Sunday of the month
        BEGIN
            c := 'b1';
            CALL core.sp_staff_leave_manage('APPLY', c_tenant, c_school, c_user, NULL,
                 v_st1, 'Casual', v_sun, v_sun, 'sunday only', NULL, NULL, c);
            PERFORM pg_temp.chk('B1 a Sunday-only range is refused', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('B1 a Sunday-only range is refused', TRUE, SQLERRM);
        END;
    END;

    -- A full week is 6 working days, not 7 — the same rule the student register
    -- and payroll use, from one shared fn_working_days.
    PERFORM pg_temp.chk_eq('B2 a calendar week counts 6 working days',
                           core.fn_working_days(v_m1, v_m1 + 6), 6);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- C. Apply and decide ---------------------------------';

    -- Three working days of UNPAID leave for staff 1.
    DECLARE v_from date; v_to date;
    BEGIN
        v_from := v_m1 + 1;
        WHILE EXTRACT(DOW FROM v_from) = 0 LOOP v_from := v_from + 1; END LOOP;
        v_to := v_from + 2;
        WHILE core.fn_working_days(v_from, v_to) < 3 LOOP v_to := v_to + 1; END LOOP;

        c := 'c1';
        CALL core.sp_staff_leave_manage('APPLY', c_tenant, c_school, c_user, NULL,
             v_st1, 'Unpaid', v_from, v_to, 'family', NULL, NULL, c);

        SELECT leave_id, days, status INTO v_lv1, v_n, v_txt
          FROM core.staff_leave WHERE staff_id = v_st1 ORDER BY leave_id DESC LIMIT 1;
        PERFORM pg_temp.chk_eq('C1 three working days recorded', v_n, 3);
        PERFORM pg_temp.chk('C2 a new request starts Pending', v_txt = 'Pending', format('got %s', v_txt));

        -- An overlapping request must be refused while the first is live, or the
        -- same days are counted twice against pay.
        BEGIN
            c := 'c3';
            CALL core.sp_staff_leave_manage('APPLY', c_tenant, c_school, c_user, NULL,
                 v_st1, 'Casual', v_from, v_to, 'overlaps', NULL, NULL, c);
            PERFORM pg_temp.chk('C3 overlapping leave refused', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('C3 overlapping leave refused', TRUE, SQLERRM);
        END;
    END;

    -- Only approve/reject are valid decisions.
    BEGIN
        c := 'c4';
        CALL core.sp_staff_leave_manage('DECIDE', c_tenant, c_school, c_user, v_lv1,
             NULL, NULL, NULL, NULL, NULL, 'Maybe', 'hmm', c);
        PERFORM pg_temp.chk('C4 an invented decision is refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C4 an invented decision is refused', TRUE, SQLERRM);
    END;

    c := 'c5';
    CALL core.sp_staff_leave_manage('DECIDE', c_tenant, c_school, c_user, v_lv1,
         NULL, NULL, NULL, NULL, NULL, 'Approved', 'ok', c);

    SELECT status, decided_by INTO v_txt, v_n FROM core.staff_leave WHERE leave_id = v_lv1;
    PERFORM pg_temp.chk('C5 approved', v_txt = 'Approved', format('got %s', v_txt));
    PERFORM pg_temp.chk('C6 who decided it is recorded', v_n = c_user, format('decided_by = %s', v_n));

    -- Deciding twice must be refused — an approval is not something to re-do
    -- quietly after payroll has already used it.
    BEGIN
        c := 'c7';
        CALL core.sp_staff_leave_manage('DECIDE', c_tenant, c_school, c_user, v_lv1,
             NULL, NULL, NULL, NULL, NULL, 'Rejected', 'changed my mind', c);
        PERFORM pg_temp.chk('C7 deciding an already-decided request refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C7 deciding an already-decided request refused', TRUE, SQLERRM);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- D. Payroll run --------------------------------------';

    BEGIN
        c := 'd0';
        CALL core.sp_staff_payroll_manage('RUN', c_tenant, c_school, c_user, NULL, v_yr, NULL, NULL, c);
        PERFORM pg_temp.chk('D0 running without a month refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('D0 running without a month refused', TRUE, SQLERRM);
    END;

    c := 'd1';
    CALL core.sp_staff_payroll_manage('RUN', c_tenant, c_school, c_user, v_mon, v_yr, NULL, NULL, c);

    SELECT gross, lop_days, lop_amount, net_pay, status
      INTO v_dec, v_n, v_dec, v_dec, v_txt
      FROM core.staff_payroll WHERE staff_id = v_st1 AND pay_month = v_mon AND pay_year = v_yr;

    SELECT gross INTO v_dec FROM core.staff_payroll
     WHERE staff_id = v_st1 AND pay_month = v_mon AND pay_year = v_yr;
    PERFORM pg_temp.chk_eq('D1 gross comes from the staff record', v_dec, v_gross);

    SELECT lop_days INTO v_n FROM core.staff_payroll
     WHERE staff_id = v_st1 AND pay_month = v_mon AND pay_year = v_yr;
    PERFORM pg_temp.chk_eq('D2 three days of unpaid leave -> 3 LOP days', v_n, 3);

    SELECT lop_amount INTO v_dec FROM core.staff_payroll
     WHERE staff_id = v_st1 AND pay_month = v_mon AND pay_year = v_yr;
    PERFORM pg_temp.chk('D3 LOP is gross / working days x LOP days',
                        ABS(v_dec - (v_perday * 3)) <= 0.05,
                        format('LOP %s, expected about %s', v_dec, ROUND(v_perday * 3, 2)));

    SELECT net_pay, gross, lop_amount INTO v_dec, v_dec, v_dec
      FROM core.staff_payroll WHERE staff_id = v_st1;
    DECLARE g numeric; l numeric; nt numeric; od numeric;
    BEGIN
        SELECT gross, lop_amount, net_pay, COALESCE(other_deduct,0) INTO g, l, nt, od
          FROM core.staff_payroll WHERE staff_id = v_st1 AND pay_month = v_mon AND pay_year = v_yr;
        PERFORM pg_temp.chk('D4 net = gross - LOP - other deductions',
                            nt = g - l - od, format('%s - %s - %s = %s', g, l, od, nt));
        PERFORM pg_temp.chk('D5 net is never negative', nt >= 0, format('net %s', nt));
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- E. Only approved UNPAID leave costs money ------------';

    -- Staff 2 takes approved CASUAL leave in the same month. Casual is paid, so
    -- it must not reduce the salary.
    DECLARE v_from2 date; v_to2 date;
    BEGIN
        v_from2 := v_m1 + 15;
        WHILE EXTRACT(DOW FROM v_from2) = 0 LOOP v_from2 := v_from2 + 1; END LOOP;
        v_to2 := v_from2 + 1;

        c := 'e1';
        CALL core.sp_staff_leave_manage('APPLY', c_tenant, c_school, c_user, NULL,
             v_st2, 'Casual', v_from2, v_to2, 'casual', NULL, NULL, c);
        SELECT leave_id INTO v_lv2 FROM core.staff_leave WHERE staff_id = v_st2
         ORDER BY leave_id DESC LIMIT 1;

        c := 'e2';
        CALL core.sp_staff_leave_manage('DECIDE', c_tenant, c_school, c_user, v_lv2,
             NULL, NULL, NULL, NULL, NULL, 'Approved', 'fine', c);
    END;

    c := 'e3';
    CALL core.sp_staff_payroll_manage('RUN', c_tenant, c_school, c_user, v_mon, v_yr, NULL, NULL, c);

    SELECT lop_days INTO v_n FROM core.staff_payroll
     WHERE staff_id = v_st2 AND pay_month = v_mon AND pay_year = v_yr;
    PERFORM pg_temp.chk_eq('E1 approved CASUAL leave costs nothing', v_n, 0);

    SELECT net_pay INTO v_dec FROM core.staff_payroll
     WHERE staff_id = v_st2 AND pay_month = v_mon AND pay_year = v_yr;
    PERFORM pg_temp.chk_eq('E2 ...so casual leave is paid in full', v_dec, v_gross);

    -- A PENDING unpaid request must not be deducted — nobody has approved it yet.
    DECLARE v_st3 integer; v_from3 date;
    BEGIN
        INSERT INTO core.staff(tenant_id, school_id, full_name, designation, department,
                               mobile, monthly_salary, joining_date, status, created_by)
        VALUES (c_tenant, c_school, 'ZZ Leave Three', 'Teacher', 'Teaching',
                '9990003333', v_gross, v_m1 - 400, 'Active', c_user)
        RETURNING staff_id INTO v_st3;

        v_from3 := v_m1 + 20;
        WHILE EXTRACT(DOW FROM v_from3) = 0 LOOP v_from3 := v_from3 + 1; END LOOP;

        c := 'e4';
        CALL core.sp_staff_leave_manage('APPLY', c_tenant, c_school, c_user, NULL,
             v_st3, 'Unpaid', v_from3, v_from3, 'not decided yet', NULL, NULL, c);

        c := 'e5';
        CALL core.sp_staff_payroll_manage('RUN', c_tenant, c_school, c_user, v_mon, v_yr, NULL, NULL, c);

        SELECT lop_days INTO v_n FROM core.staff_payroll
         WHERE staff_id = v_st3 AND pay_month = v_mon AND pay_year = v_yr;
        PERFORM pg_temp.chk_eq('E3 a PENDING unpaid request is not deducted', v_n, 0);
    END;

    -- Re-running must not stack payslips.
    SELECT COUNT(*) INTO v_n FROM core.staff_payroll
     WHERE staff_id = v_st1 AND pay_month = v_mon AND pay_year = v_yr;
    PERFORM pg_temp.chk_eq('E4 re-running the month keeps one payslip each', v_n, 1);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- F. Mark paid ----------------------------------------';

    DECLARE v_pid integer;
    BEGIN
        SELECT payroll_id INTO v_pid FROM core.staff_payroll
         WHERE staff_id = v_st1 AND pay_month = v_mon AND pay_year = v_yr;

        c := 'f1';
        CALL core.sp_staff_payroll_manage('MARK_PAID', c_tenant, c_school, c_user,
             NULL, NULL, v_pid, NULL, c);

        SELECT status, paid_by INTO v_txt, v_n FROM core.staff_payroll WHERE payroll_id = v_pid;
        PERFORM pg_temp.chk('F1 payslip marked paid', v_txt = 'Paid', format('status %s', v_txt));
        PERFORM pg_temp.chk('F2 who paid it is recorded', v_n = c_user, format('paid_by %s', v_n));

        BEGIN
            c := 'f3';
            CALL core.sp_staff_payroll_manage('MARK_PAID', c_tenant, c_school, c_user,
                 NULL, NULL, v_pid, NULL, c);
            PERFORM pg_temp.chk('F3 paying twice refused', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('F3 paying twice refused', TRUE, SQLERRM);
        END;

        -- The important one: re-running the month must NOT rewrite a payslip that
        -- has already been paid, or the record stops matching the bank transfer.
        c := 'f4';
        CALL core.sp_staff_payroll_manage('RUN', c_tenant, c_school, c_user, v_mon, v_yr, NULL, NULL, c);

        SELECT status INTO v_txt FROM core.staff_payroll WHERE payroll_id = v_pid;
        PERFORM pg_temp.chk('F4 a re-run leaves a PAID payslip alone',
                            v_txt = 'Paid', format('status is now %s', v_txt));
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- G. Scope --------------------------------------------';

    BEGIN
        c := 'g1';
        CALL core.sp_staff_leave_manage('APPLY', 23, 33, c_user, NULL,
             v_st1, 'Casual', v_m1 + 25, v_m1 + 25, 'other school', NULL, NULL, c);
        PERFORM pg_temp.chk('G1 another school cannot file leave for our staff', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('G1 another school cannot file leave for our staff', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'g2';
        CALL core.sp_staff_payroll_manage('RUN', 1, 0, c_user, v_mon, v_yr, NULL, NULL, c);
        PERFORM pg_temp.chk('G2 platform scope payroll refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('G2 platform scope payroll refused', TRUE, SQLERRM);
    END;

    SELECT COUNT(*) INTO v_n FROM core.staff_payroll
     WHERE staff_id = v_st1 AND (tenant_id <> c_tenant OR school_id <> c_school);
    PERFORM pg_temp.chk_eq('G3 no payslip escaped to another school', v_n, 0);
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
