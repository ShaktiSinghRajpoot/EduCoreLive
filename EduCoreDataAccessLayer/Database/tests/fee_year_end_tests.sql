-- Year-End Fee Closure (fee_year_end.sql): end-to-end checks on the QA Test
-- School (tenant 32, school 45, session 2026-27, admin login 62). Creates the
-- columns/proc and a 2027-28 session inside the transaction and ROLLS BACK, so
-- it leaves nothing behind. Run from this folder:
--     psql ... -f fee_year_end_tests.sql
\set ON_ERROR_STOP 1
BEGIN;
\ir ../fee_year_end.sql

DO $t$
DECLARE
    TN int := 32; SC int := 45; U int := 62; Y varchar := '2026-27';
    c refcursor; r record;
    v_stu int; v_due int; v_due2 int; v_future int; v_open numeric; v_n int; v_txt text;
    pass int := 0; fail int := 0;
BEGIN
    -- a student with two lines already due and one not due yet
    SELECT student_id INTO v_stu FROM core.student_ledger
     WHERE tenant_id = TN AND school_id = SC AND amount_due > amount_paid + concession
     GROUP BY student_id
    HAVING COUNT(*) FILTER (WHERE due_date <= to_char(CURRENT_DATE, 'YYYY-MM-DD')) >= 2
       AND COUNT(*) FILTER (WHERE due_date >  to_char(CURRENT_DATE, 'YYYY-MM-DD')) >= 1
     ORDER BY student_id LIMIT 1;
    SELECT ledger_id INTO v_due FROM core.student_ledger WHERE student_id = v_stu AND amount_due > amount_paid + concession
       AND due_date <= to_char(CURRENT_DATE, 'YYYY-MM-DD') ORDER BY ledger_id LIMIT 1;
    SELECT ledger_id INTO v_due2 FROM core.student_ledger WHERE student_id = v_stu AND amount_due > amount_paid + concession
       AND due_date <= to_char(CURRENT_DATE, 'YYYY-MM-DD') AND ledger_id <> v_due ORDER BY ledger_id LIMIT 1;
    SELECT ledger_id INTO v_future FROM core.student_ledger WHERE student_id = v_stu AND amount_due > amount_paid + concession
       AND due_date > to_char(CURRENT_DATE, 'YYYY-MM-DD') ORDER BY ledger_id LIMIT 1;

    -- Sessions after 2026-27 that already exist on the QA school are hidden for this run
    -- (renamed + deleted, rolled back), so the test starts with no next session.
    UPDATE academic.academic_years SET academic_year_name = 'zz' || academic_year_id, is_deleted = TRUE
     WHERE tenant_id = TN AND school_id = SC AND start_date::date > '2026-04-01';

    -- 1. no next session yet: carry is refused with a clear reason
    BEGIN
        CALL core.sp_fee_year_end_manage('Carry', TN, SC, U, Y, v_due, NULL, NULL, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 1 carry without a next session';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 1 %', SQLERRM; END;

    INSERT INTO academic.academic_years (tenant_id, school_id, academic_year_name, start_date, end_date, is_current, created_by)
    VALUES (TN, SC, '2027-28', '2027-04-01', '2028-03-31', FALSE, U);

    -- 2. a line not due yet cannot be written off or carried
    BEGIN
        CALL core.sp_fee_year_end_manage('WriteOff', TN, SC, U, Y, v_future, NULL, 'test', c);
        fail := fail + 1; RAISE NOTICE 'FAIL 2 future line written off';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 2 %', SQLERRM; END;

    -- 3. carry moves a due line into 2027-28 and out of 2026-27's dues
    SELECT amount_due - amount_paid - concession INTO v_open FROM core.student_ledger WHERE ledger_id = v_due;
    CALL core.sp_fee_year_end_manage('Carry', TN, SC, U, Y, v_due, NULL, NULL, c); FETCH c INTO r; CLOSE c;
    IF (SELECT academic_year = '2027-28' AND carried_from = Y AND amount_due - amount_paid - concession = v_open
          FROM core.student_ledger WHERE ledger_id = v_due)
    THEN pass := pass + 1; RAISE NOTICE 'PASS 3 % (still owes %)', r.message, v_open;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 3 carry'; END IF;

    -- 4. the 2026-27 list still shows it as Carried (so it can be undone); 2027-28 defaulters now include it
    CALL core.sp_fee_year_end_manage('List', TN, SC, U, Y, NULL, NULL, NULL, c);
    v_txt := NULL;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.ledger_id = v_due THEN v_txt := r.state || '/' || r.reason; END IF; END LOOP; CLOSE c;
    IF v_txt = 'Carried/Moved to 2027-28' THEN pass := pass + 1; RAISE NOTICE 'PASS 4 list: %', v_txt;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 4 list: %', v_txt; END IF;

    -- 5. undo puts it back in 2026-27
    CALL core.sp_fee_year_end_manage('Undo', TN, SC, U, Y, v_due, NULL, NULL, c); CLOSE c;
    IF (SELECT academic_year = Y AND carried_from IS NULL FROM core.student_ledger WHERE ledger_id = v_due)
    THEN pass := pass + 1; RAISE NOTICE 'PASS 5 carry undone';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 5'; END IF;

    -- 6. write-off needs a reason, closes the due, and Undo reopens it
    BEGIN
        CALL core.sp_fee_year_end_manage('WriteOff', TN, SC, U, Y, v_due2, NULL, '  ', c);
        fail := fail + 1; RAISE NOTICE 'FAIL 6 no reason accepted';
    EXCEPTION WHEN raise_exception THEN
        SELECT amount_due - amount_paid - concession INTO v_open FROM core.student_ledger WHERE ledger_id = v_due2;
        CALL core.sp_fee_year_end_manage('WriteOff', TN, SC, U, Y, v_due2, NULL, 'Family relocated', c); CLOSE c;
        IF (SELECT amount_due - amount_paid - concession = 0 AND closed_amount = v_open FROM core.student_ledger WHERE ledger_id = v_due2) THEN
            CALL core.sp_fee_year_end_manage('Undo', TN, SC, U, Y, v_due2, NULL, NULL, c); CLOSE c;
            IF (SELECT amount_due - amount_paid - concession = v_open FROM core.student_ledger WHERE ledger_id = v_due2)
            THEN pass := pass + 1; RAISE NOTICE 'PASS 6 write-off % (reason required), undone', v_open;
            ELSE fail := fail + 1; RAISE NOTICE 'FAIL 6 undo'; END IF;
        ELSE fail := fail + 1; RAISE NOTICE 'FAIL 6 write-off'; END IF;
    END;

    -- 7. "carry all" for the student moves only the due lines; the future one stays
    CALL core.sp_fee_year_end_manage('Carry', TN, SC, U, Y, NULL, v_stu, NULL, c); FETCH c INTO r; CLOSE c;
    SELECT COUNT(*) INTO v_n FROM core.student_ledger WHERE student_id = v_stu AND carried_from = Y
       AND due_date > to_char(CURRENT_DATE, 'YYYY-MM-DD');
    IF v_n = 0 AND (SELECT academic_year FROM core.student_ledger WHERE ledger_id = v_future) = Y
    THEN pass := pass + 1; RAISE NOTICE 'PASS 7 %; not-due lines stayed', r.message;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 7 % future lines moved', v_n; END IF;

    -- 8. another school cannot touch this school's line
    BEGIN
        CALL core.sp_fee_year_end_manage('Undo', 30, 1, U, Y, v_due, NULL, NULL, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 8 cross-school undo accepted';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 8 cross-school refused: %', SQLERRM; END;

    RAISE NOTICE '== % passed, % failed ==', pass, fail;
END;
$t$;

ROLLBACK;
