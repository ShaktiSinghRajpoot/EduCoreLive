-- QA round 3 fixes (14 Oct 2026): checks on the QA Test School (tenant 32,
-- school 45; admin login 62, QA Teacher login 63 = staff 92). Every change is
-- made inside the transaction and ROLLED BACK, so it leaves nothing behind.
-- Run from this folder:
--     psql ... -f qa_round3_fixes_tests.sql
\set ON_ERROR_STOP 1
BEGIN;

DO $t$
DECLARE
    T int := 32; S int := 45; ADMIN int := 62; TEACHER int := 63;
    c refcursor; c2 refcursor; c3 refcursor; c4 refcursor; r record;
    v_id int; v_n int; v_txt text; v_num numeric; v_date date; v_cls int; v_sub int;
    pass int := 0; fail int := 0;
BEGIN
    -- 1. BUG-099 Day Close: the all-counters list also shows drawers never closed
    c := 'c1';
    CALL core.sp_fee_day_close_list(T, S, ADMIN, '2026-10-14', c);
    v_n := 0; v_txt := '';
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
        IF r.closed_at IS NULL THEN
            v_n := v_n + 1; v_txt := v_txt || r.cashier_name || ' ';
            IF EXISTS (SELECT 1 FROM core.fee_day_close d WHERE d.tenant_id = T AND d.school_id = S
                         AND d.close_date = '2026-10-14' AND d.cashier_id = r.cashier_id) THEN v_n := -100; END IF;
        END IF;
    END LOOP; CLOSE c;
    IF v_n > 0 THEN pass := pass + 1; RAISE NOTICE 'PASS 1 not-closed counters listed: %', v_txt;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 1 not-closed counters: %', v_n; END IF;

    -- 2. BUG-095 an absent paper is 0 out of its max in the total (every student, every exam)
    SELECT COUNT(*) INTO v_n
      FROM (SELECT DISTINCT m.exam_id, m.academic_class_id FROM academic.exam_marks m WHERE m.tenant_id = T) e,
           LATERAL academic.fn_exam_class_result(T, S, e.exam_id, e.academic_class_id) res
     WHERE res.out_total <> (SELECT COALESCE(SUM(es.max_marks), 0)
                               FROM academic.exam_marks m
                               JOIN academic.exam_subjects es ON es.exam_id = m.exam_id AND es.subject_id = m.subject_id
                                                             AND es.academic_class_id = m.academic_class_id
                              WHERE m.exam_id = e.exam_id AND m.academic_class_id = e.academic_class_id
                                AND m.student_id = res.out_student_id
                                AND (m.marks_obtained IS NOT NULL OR m.is_absent));
    SELECT r2.out_percent INTO v_num FROM academic.fn_exam_class_result(T, S, 53, 2435) r2 WHERE r2.out_student_id = 707;
    IF v_n = 0 AND v_num = 72.50 THEN pass := pass + 1; RAISE NOTICE 'PASS 2 absent = 0 of max (Om Chaurasia 72.50%%)';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 2 % mismatched totals, Om %', v_n, v_num; END IF;

    -- 3. BUG-094 an exam with an undated paper cannot be published
    BEGIN
        c := 'c3a'; c2 := 'c3b';
        CALL academic.sp_school_admin_exam_manage('SetStatus', T, S, ADMIN, p_exam_id => 55, p_status => 'Published',
                                                  p_result => c, p_result2 => c2);
        fail := fail + 1; RAISE NOTICE 'FAIL 3 publish with an undated paper accepted';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM LIKE '%no date yet%' THEN pass := pass + 1; RAISE NOTICE 'PASS 3 %', SQLERRM;
        ELSE fail := fail + 1; RAISE NOTICE 'FAIL 3 other error: %', SQLERRM; END IF;
    END;

    -- 4. BUG-076 no marks before the paper's date
    SELECT es.exam_id, es.academic_class_id, es.subject_id, es.exam_date::date INTO v_id, v_cls, v_sub, v_date
      FROM academic.exam_subjects es JOIN academic.exams e ON e.exam_id = es.exam_id
     WHERE e.tenant_id = T AND e.status = 'Published' AND COALESCE(e.results_status, '') <> 'Published' AND NULLIF(es.exam_date::text, '')::date > CURRENT_DATE
     LIMIT 1;
    BEGIN
        c := 'c4a'; c2 := 'c4b';
        CALL academic.sp_school_admin_exam_marks_manage('SaveMarks', T, S, ADMIN,
            p_exam_id => v_id,
            p_academic_class_id => v_cls, p_subject_id => v_sub, p_section => 'A', p_items => '[]',
            p_result => c, p_result2 => c2);
        fail := fail + 1; RAISE NOTICE 'FAIL 4 marks before the paper date accepted';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM LIKE 'This paper is on%' THEN pass := pass + 1; RAISE NOTICE 'PASS 4 %', SQLERRM;
        ELSE fail := fail + 1; RAISE NOTICE 'FAIL 4 other error: %', SQLERRM; END IF;
    END;

    -- 5. BUG-100 joining mid-month: that month falls due on the joining day, later months on the 1st
    SELECT string_agg(to_char(p.due_date, 'YYYY-MM-DD'), ',' ORDER BY p.due_date) INTO v_txt
      FROM core.fn_plan_periods(T, S, '2026-27', 'Monthly', '2026-10-14') p;
    IF v_txt LIKE '2026-10-14,2026-11-01,%' THEN pass := pass + 1; RAISE NOTICE 'PASS 5 periods: %', left(v_txt, 33);
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 5 %', v_txt; END IF;

    -- 6. BUG-110 inventory messages print stock without ".00"
    SELECT COUNT(*) INTO v_n FROM pg_proc
     WHERE proname IN ('sp_inventory_manage', 'sp_inventory_purchase_manage')
       AND pg_get_functiondef(oid) ~ 'TO_CHAR\((v_stock|p_quantity|v_line\.[a-z_ -]+), ''FM999999990\.00''';
    IF v_n = 0 THEN pass := pass + 1; RAISE NOTICE 'PASS 6 no quantity printed as 0.00';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 6 % proc(s) still format quantities with .00', v_n; END IF;

    -- 7. BUG-074 an admission without a roll number gets the next one in the section
    c := 'c7';
    CALL core.sp_admission_manage('SaveAdmission', T, S, ADMIN,
        p_student_name => 'Test Roll Auto', p_gender => 'Male', p_dob => '2014-05-05',
        p_class_name => 'Class 8', p_section => 'A', p_academic_year => '2026-27',
        p_admission_date => CURRENT_DATE, p_guardian_name => 'Test Father', p_mobile => '9000099001',
        p_result => c);
    FETCH c INTO r; CLOSE c;
    SELECT roll_no INTO v_txt FROM core.students WHERE student_id = r.student_id;
    IF r.success = 1 AND v_txt = (SELECT (MAX(o.roll_no::int))::text FROM core.students o
                                   WHERE o.tenant_id = T AND o.is_active AND o.class_name = 'Class 8' AND o.section = 'A'
                                     AND o.roll_no ~ '^[0-9]+$')
    THEN pass := pass + 1; RAISE NOTICE 'PASS 7 new student got roll %', v_txt;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 7 % roll %', r.message, v_txt; END IF;

    -- 8. BUG-085 a TC left blank is filled from the register and the ledger
    SELECT s2.student_id INTO v_id FROM core.students s2
     WHERE s2.tenant_id = T AND s2.is_active
       AND EXISTS (SELECT 1 FROM core.student_attendance a WHERE a.student_id = s2.student_id)
     LIMIT 1;
    UPDATE core.students SET is_active = FALSE, status = 'Transfer', date_of_leaving = CURRENT_DATE WHERE student_id = v_id;
    UPDATE core.student_ledger SET amount_paid = amount_due - COALESCE(concession, 0)
     WHERE student_id = v_id AND due_date <= '2026-12-31';
    DELETE FROM core.fee_payment_details d USING core.student_ledger l
     WHERE d.ledger_id = l.ledger_id AND l.student_id = v_id AND l.due_date > '2026-12-31';
    DELETE FROM core.student_ledger WHERE student_id = v_id AND due_date > '2026-12-31';
    c := 'c8';
    CALL core.sp_tc_manage('Issue', T, S, ADMIN, NULL, v_id, 'Basic', 'Good', 'Passed', 'Parent transfer', NULL, p_result_cur => c);
    FETCH c INTO r; CLOSE c;
    SELECT working_days || '/' || days_present || '/' || COALESCE(fees_paid_upto, '-') INTO v_txt
      FROM core.tc_register WHERE student_id = v_id AND NOT is_void;
    IF r.success AND v_txt LIKE '%/%/Dec 2026' THEN pass := pass + 1; RAISE NOTICE 'PASS 8 TC filled: %', v_txt;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 8 TC: %', v_txt; END IF;

    -- 9. BUG-114 acting class teacher: QA Teacher takes a period in Class 2-A on a day its
    --    class teacher is on leave -> may take the register; not for another class
    UPDATE academic.timetable SET staff_id = 92, day_of_week = 4
     WHERE timetable_id = (SELECT timetable_id FROM academic.timetable
                            WHERE academic_class_section_id = 2522 AND day_of_week = 4 LIMIT 1);
    INSERT INTO core.staff_leave (tenant_id, school_id, staff_id, leave_type, from_date, to_date, days, status, applied_by)
    VALUES (T, S, 121, 'Casual', '2026-10-15', '2026-10-15', 1, 'Approved', ADMIN);
    c := 'c9a';
    CALL core.sp_class_teacher_acting(T, S, TEACHER, 'Class 2', 'A', '2026-10-15', c); FETCH c INTO r; CLOSE c;
    v_txt := r.is_acting::text;
    c := 'c9b';
    CALL core.sp_class_teacher_acting(T, S, TEACHER, 'Class 3', 'A', '2026-10-15', c); FETCH c INTO r; CLOSE c;
    IF v_txt = 'true' AND NOT r.is_acting THEN pass := pass + 1; RAISE NOTICE 'PASS 9 acting for 2-A only';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 9 2-A %, 3-A %', v_txt, r.is_acting; END IF;

    -- 10. BUG-115 / BUG-090 approving leave names the class charge, periods to cover, paid salary
    INSERT INTO core.staff_leave (tenant_id, school_id, staff_id, leave_type, from_date, to_date, days, status, applied_by)
    VALUES (T, S, 92, 'Unpaid', '2026-10-19', '2026-10-21', 3, 'Pending', ADMIN) RETURNING leave_id INTO v_id;
    c := 'c10';
    CALL core.sp_staff_leave_manage('DECIDE', T, S, ADMIN, p_leave_id => v_id, p_status => 'Approved', p_result => c);
    FETCH c INTO r; CLOSE c;
    IF r.message LIKE '%class teacher of Class 1-A%' AND r.message LIKE '%need a substitute%'
    THEN pass := pass + 1; RAISE NOTICE 'PASS 10 %', left(r.message, 120);
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 10 %', r.message; END IF;

    -- 11. BUG-076 results cannot be published while a paper is still to come
    SELECT e.exam_id INTO v_id FROM academic.exams e
     WHERE e.tenant_id = T AND e.status = 'Published' AND COALESCE(e.results_status, '') <> 'Published'
       AND EXISTS (SELECT 1 FROM academic.exam_subjects es WHERE es.exam_id = e.exam_id
                     AND NULLIF(es.exam_date::text, '')::date > CURRENT_DATE)
     LIMIT 1;
    BEGIN
        c := 'c11'; c2 := 'c11b'; c3 := 'c11c'; c4 := 'c11d';
        CALL academic.sp_school_admin_exam_results_manage('PublishResults', T, S, ADMIN, p_exam_id => v_id,
            p_result => c, p_result2 => c2, p_result3 => c3, p_result4 => c4);
        fail := fail + 1; RAISE NOTICE 'FAIL 11 results published before the papers';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM LIKE '%before every paper is written%' THEN pass := pass + 1; RAISE NOTICE 'PASS 11 %', SQLERRM;
        ELSE fail := fail + 1; RAISE NOTICE 'FAIL 11 other error: %', SQLERRM; END IF;
    END;

    RAISE NOTICE '== % passed, % failed ==', pass, fail;
END;
$t$;

ROLLBACK;
