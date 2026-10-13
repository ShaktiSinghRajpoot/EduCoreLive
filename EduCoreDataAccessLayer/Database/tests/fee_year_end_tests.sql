-- Year-End Fee Closure (fee_year_end.sql): end-to-end checks on the QA Test
-- School (tenant 32, school 45, session 2026-27, admin login 62). Creates the
-- columns/proc inside the transaction and ROLLS BACK, so it leaves nothing behind.
-- Run from this folder:
--     psql ... -f fee_year_end_tests.sql
\set ON_ERROR_STOP 1
BEGIN;
\ir ../fee_year_end.sql

DO $t$
DECLARE
    T int := 32; S int := 45; U int := 62; Y varchar := '2026-27';
    c refcursor; r record;
    v_stu int; v_line int; v_line2 int; v_open numeric; v_before numeric; v_after numeric;
    v_n int; v_state text; v_msg text;
    pass int := 0; fail int := 0;
BEGIN
    -- a student with at least two open lines, and the school's total before
    SELECT student_id INTO v_stu FROM core.student_ledger
     WHERE tenant_id = T AND school_id = S AND amount_due > amount_paid + concession
     GROUP BY student_id HAVING COUNT(*) >= 2 ORDER BY student_id LIMIT 1;
    SELECT ledger_id, amount_due - amount_paid - concession INTO v_line, v_open FROM core.student_ledger
     WHERE student_id = v_stu AND amount_due > amount_paid + concession ORDER BY ledger_id LIMIT 1;
    SELECT ledger_id INTO v_line2 FROM core.student_ledger
     WHERE student_id = v_stu AND amount_due > amount_paid + concession AND ledger_id <> v_line ORDER BY ledger_id LIMIT 1;
    SELECT SUM(amount_due - amount_paid - concession) INTO v_before FROM core.student_ledger
     WHERE tenant_id = T AND school_id = S AND amount_due > amount_paid + concession;

    -- 1. List shows every open line of the session as Open
    CALL core.sp_fee_year_end_manage('List', T, S, U, Y, NULL, NULL, NULL, c);
    v_n := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.state = 'Open' THEN v_n := v_n + 1; END IF; END LOOP; CLOSE c;
    IF v_n = (SELECT COUNT(*) FROM core.student_ledger WHERE tenant_id = T AND school_id = S AND amount_due > amount_paid + concession)
    THEN pass := pass + 1; RAISE NOTICE 'PASS 1 list has % open lines', v_n;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 1 list open lines %', v_n; END IF;

    -- 2. Carry one line: marked, still payable at the counter
    CALL core.sp_fee_year_end_manage('Carry', T, S, U, Y, v_line, NULL, NULL, c); FETCH c INTO r; CLOSE c;
    IF (SELECT carried_at IS NOT NULL AND amount_due - amount_paid - concession = v_open FROM core.student_ledger WHERE ledger_id = v_line)
    THEN pass := pass + 1; RAISE NOTICE 'PASS 2 carried, still owes % (%)', v_open, r.message;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 2 carry'; END IF;

    -- 3. Carrying it again is refused (nothing to change)
    BEGIN
        CALL core.sp_fee_year_end_manage('Carry', T, S, U, Y, v_line, NULL, NULL, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 3 double carry accepted';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 3 double carry refused: %', SQLERRM; END;

    -- 4. Write-off without a reason is refused
    BEGIN
        CALL core.sp_fee_year_end_manage('WriteOff', T, S, U, Y, v_line2, NULL, '  ', c);
        fail := fail + 1; RAISE NOTICE 'FAIL 4 write-off without reason accepted';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 4 reason required: %', SQLERRM; END;

    -- 5. Write off a line: outstanding becomes 0, the amount is kept in closed_amount
    SELECT amount_due - amount_paid - concession INTO v_open FROM core.student_ledger WHERE ledger_id = v_line2;
    CALL core.sp_fee_year_end_manage('WriteOff', T, S, U, Y, v_line2, NULL, 'Family relocated', c); FETCH c INTO r; CLOSE c;
    IF (SELECT amount_due - amount_paid - concession = 0 AND closed_amount = v_open AND close_source = 'YearEnd'
          FROM core.student_ledger WHERE ledger_id = v_line2)
    THEN pass := pass + 1; RAISE NOTICE 'PASS 5 written off % (%)', v_open, r.message;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 5 write-off'; END IF;

    -- 6. The fee counter no longer shows the written-off line
    CALL core.sp_student_dues_get(T, S, U, v_stu, c);
    v_n := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.ledger_id = v_line2 THEN v_n := v_n + 1; END IF; END LOOP; CLOSE c;
    IF v_n = 0 THEN pass := pass + 1; RAISE NOTICE 'PASS 6 counter hides the written-off line';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 6 counter still shows it'; END IF;

    -- 7. List shows it as WrittenOff with the reason
    CALL core.sp_fee_year_end_manage('List', T, S, U, Y, NULL, NULL, NULL, c);
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.ledger_id = v_line2 THEN v_state := r.state || '/' || r.reason || '/' || r.amount; END IF; END LOOP; CLOSE c;
    IF v_state = 'WrittenOff/Family relocated/' || v_open THEN pass := pass + 1; RAISE NOTICE 'PASS 7 list: %', v_state;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 7 list: %', v_state; END IF;

    -- 8. Undo the write-off: the due is back exactly
    CALL core.sp_fee_year_end_manage('Undo', T, S, U, Y, v_line2, NULL, NULL, c); FETCH c INTO r; CLOSE c;
    IF (SELECT amount_due - amount_paid - concession = v_open AND closed_amount = 0 AND close_source IS NULL
          FROM core.student_ledger WHERE ledger_id = v_line2)
    THEN pass := pass + 1; RAISE NOTICE 'PASS 8 write-off undone (%)', r.message;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 8 undo write-off'; END IF;

    -- 9. Undo the carry mark
    CALL core.sp_fee_year_end_manage('Undo', T, S, U, Y, v_line, NULL, NULL, c); FETCH c INTO r; CLOSE c;
    IF (SELECT carried_at IS NULL FROM core.student_ledger WHERE ledger_id = v_line)
    THEN pass := pass + 1; RAISE NOTICE 'PASS 9 carry undone';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 9 undo carry'; END IF;

    -- 10. Write All for one student closes every open line of that student
    CALL core.sp_fee_year_end_manage('WriteOff', T, S, U, Y, NULL, v_stu, 'Fee waived by management', c); FETCH c INTO r; CLOSE c;
    IF NOT EXISTS (SELECT 1 FROM core.student_ledger WHERE student_id = v_stu AND amount_due > amount_paid + concession)
    THEN pass := pass + 1; RAISE NOTICE 'PASS 10 student written off: %', r.message;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 10 student still owes'; END IF;

    -- 11. Carry All marks every other open line; total owed is unchanged by carrying
    CALL core.sp_fee_year_end_manage('CarryAll', T, S, U, Y, NULL, NULL, NULL, c); FETCH c INTO r; CLOSE c;
    SELECT SUM(amount_due - amount_paid - concession) INTO v_after FROM core.student_ledger
     WHERE tenant_id = T AND school_id = S AND amount_due > amount_paid + concession;
    IF NOT EXISTS (SELECT 1 FROM core.student_ledger WHERE tenant_id = T AND school_id = S
                     AND amount_due > amount_paid + concession AND carried_at IS NULL)
       AND v_after = v_before - (SELECT SUM(closed_amount) FROM core.student_ledger WHERE student_id = v_stu AND close_source = 'YearEnd')
    THEN pass := pass + 1; RAISE NOTICE 'PASS 11 carry all: % ; owed % -> %', r.message, v_before, v_after;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 11 carry all, owed % -> %', v_before, v_after; END IF;

    -- 12. Another school cannot touch this school''s line
    BEGIN
        CALL core.sp_fee_year_end_manage('Undo', 30, 1, U, Y, v_line, NULL, NULL, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 12 cross-school undo accepted';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 12 cross-school refused: %', SQLERRM; END;

    RAISE NOTICE '== % passed, % failed ==', pass, fail;
END;
$t$;

ROLLBACK;
