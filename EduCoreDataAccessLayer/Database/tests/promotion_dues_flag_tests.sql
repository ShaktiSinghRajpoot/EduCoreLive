-- Promotion's fee flag counts only what has FALLEN DUE (17 Oct 2026).
-- QA Test School (tenant 32, school 45, admin 62). Two Class 6 children who owe
-- fees today: one pays everything due so far (months ahead still open), the
-- other does not. With "Promote students who still owe fees" OFF, the first is
-- promoted and the second is held back. Also checks Year-End's carried_from
-- reaches the dues list. Everything is ROLLED BACK. Run from this folder:
--     psql ... -f promotion_dues_flag_tests.sql
\set ON_ERROR_STOP 1
BEGIN;

DO $t$
DECLARE
    T int := 32; S int := 45; A int := 62;
    v_paid int; v_late int; c refcursor; r record; v_n int; v_txt text;
    pass int := 0; fail int := 0;
BEGIN
    -- two Class 6 children of 2026-27 who owe something today and have months ahead
    SELECT e.student_id INTO v_paid FROM core.student_enrolment e
     WHERE e.tenant_id = T AND e.school_id = S AND e.academic_year = '2026-27' AND e.class_name = 'Class 6'
       AND COALESCE(e.status, '') NOT IN ('Left', 'PassedOut')
       AND EXISTS (SELECT 1 FROM core.student_ledger l WHERE l.student_id = e.student_id
                    AND l.amount_due > l.amount_paid + l.concession AND l.due_date::date <= CURRENT_DATE)
       AND EXISTS (SELECT 1 FROM core.student_ledger l WHERE l.student_id = e.student_id
                    AND l.amount_due > l.amount_paid + l.concession AND l.due_date::date > CURRENT_DATE)
     ORDER BY e.student_id LIMIT 1;
    SELECT e.student_id INTO v_late FROM core.student_enrolment e
     WHERE e.tenant_id = T AND e.school_id = S AND e.academic_year = '2026-27' AND e.class_name = 'Class 6'
       AND COALESCE(e.status, '') NOT IN ('Left', 'PassedOut') AND e.student_id <> v_paid
       AND EXISTS (SELECT 1 FROM core.student_ledger l WHERE l.student_id = e.student_id
                    AND l.amount_due > l.amount_paid + l.concession AND l.due_date::date <= CURRENT_DATE)
     ORDER BY e.student_id LIMIT 1;
    IF v_paid IS NULL OR v_late IS NULL THEN RAISE EXCEPTION 'Fixture: need two Class 6 children owing fees today'; END IF;

    -- the first child settles everything due so far (a concession stands in for cash)
    UPDATE core.student_ledger SET concession = amount_due - amount_paid
     WHERE student_id = v_paid AND due_date::date <= CURRENT_DATE AND amount_due > amount_paid + concession;

    -- 1. Student list columns: fee_due still has the months ahead, fee_due_now does not
    c := 'g';
    CALL core.sp_admission_manage('GetStudents', T, S, A, p_filter_class => 'Class 6', p_filter_year => '2026-27',
                                  p_page_number => 1, p_page_size => 500, p_result => c);
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
        IF r.student_id = v_paid THEN
            IF r.fee_due_now = 0 AND r.fee_due > 0 THEN pass := pass + 1; RAISE NOTICE 'PASS 1 paid-up child: due now 0, months ahead %', r.fee_due;
            ELSE fail := fail + 1; RAISE NOTICE 'FAIL 1 paid-up child: due now %, total %', r.fee_due_now, r.fee_due; END IF;
        ELSIF r.student_id = v_late THEN
            IF r.fee_due_now > 0 THEN pass := pass + 1; RAISE NOTICE 'PASS 2 late child: due now %', r.fee_due_now;
            ELSE fail := fail + 1; RAISE NOTICE 'FAIL 2 late child shows nothing due'; END IF;
        END IF;
    END LOOP; CLOSE c;

    -- 2. Promote both with "promote students who owe" OFF
    c := 'p';
    CALL core.sp_student_promote(T, S, A, '2026-27', '2027-28', NULL, FALSE,
         jsonb_build_array(jsonb_build_object('studentId', v_paid, 'outcome', 'Promote'),
                           jsonb_build_object('studentId', v_late, 'outcome', 'Promote')), c);
    CLOSE c;
    SELECT COUNT(*) INTO v_n FROM core.student_enrolment WHERE student_id = v_paid AND academic_year = '2027-28';
    IF v_n = 1 THEN pass := pass + 1; RAISE NOTICE 'PASS 3 owing only months ahead: promoted';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 3 paid-up child was not promoted'; END IF;
    SELECT COUNT(*) INTO v_n FROM core.student_enrolment WHERE student_id = v_late AND academic_year = '2027-28';
    IF v_n = 0 THEN pass := pass + 1; RAISE NOTICE 'PASS 4 overdue fee: held back';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 4 child with an overdue fee was promoted'; END IF;

    -- 3. A due carried forward by Year-End says where it came from
    UPDATE core.student_ledger SET academic_year = '2027-28', carried_from = '2026-27'
     WHERE ledger_id = (SELECT MIN(ledger_id) FROM core.student_ledger WHERE student_id = v_late
                         AND amount_due > amount_paid + concession AND due_date::date <= CURRENT_DATE);
    c := 'd';
    CALL core.sp_student_dues_get(T, S, A, v_late, c);
    v_n := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.carried_from = '2026-27' THEN v_n := v_n + 1; END IF; END LOOP; CLOSE c;
    IF v_n = 1 THEN pass := pass + 1; RAISE NOTICE 'PASS 5 dues list returns carried_from';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 5 carried_from rows: %', v_n; END IF;

    RAISE NOTICE '== % passed, % failed ==', pass, fail;
END $t$;

ROLLBACK;
