-- Real-world flow fixes (15 Oct 2026): leaving / TC / re-admit, class change,
-- fee heads, calendar, staff leaving, session dates, admission "pay today".
-- QA Test School (tenant 32, school 45, admin login 62). Everything happens
-- inside the transaction and is ROLLED BACK. Run from this folder:
--     psql ... -f flow_fixes_tests.sql
\set ON_ERROR_STOP 1
BEGIN;
\o NUL
\ir ../student_money_lifecycle.sql
\ir ../student_exit.sql
\ir ../transfer_certificate.sql
\ir ../fee_receipt_cancel.sql
\ir ../fee_advance.sql
\ir ../student_master_fields.sql
\ir ../student_update.sql
\ir ../fee_head_cascade_delete.sql
\ir ../fee_head_identity.sql
\ir ../school_calendar.sql
\ir ../sp_staff_manage.sql
\ir ../academic_year_class_section_fixes.sql
\o

DO $t$
DECLARE
    T int := 32; S int := 45; A int := 62;
    c refcursor; c2 refcursor; r record;
    v_id int; v_n int; v_txt text; v_num numeric; v_lid int; v_rcp text;
    pass int := 0; fail int := 0;
BEGIN
    -- 1. admission: the first instalments are due on the joining day
    c := 'c1';
    CALL core.sp_plan_instalments(T, S, A, '2026-27', CURRENT_DATE, c);
    v_txt := '';
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_txt := v_txt || r.frequency || '=' || r.due_now || ' '; END LOOP; CLOSE c;
    IF v_txt LIKE '%Monthly=1%' AND v_txt LIKE '%One Time=1%' THEN pass := pass + 1; RAISE NOTICE 'PASS 1 due on joining: %', v_txt;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 1 %', v_txt; END IF;

    -- 2. leaving date in the future is refused
    BEGIN
        c := 'c2';
        CALL core.sp_student_exit('Exit', T, S, A, 754, 'Transfer', CURRENT_DATE + 3, NULL, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 2 future leaving date accepted';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 2 %', SQLERRM; END;

    -- 3. class change: the running half-year stays with the old class, not billed twice
    SELECT * INTO r FROM core.students WHERE student_id = 754;
    c := 'c3';
    CALL core.sp_student_update(T, S, A, 754, r.student_name, r.roll_no, r.gender, r.dob::date, 'Class 4', 'A',
         r.guardian_name, r.mother_name, r.mobile, NULL, r.address, NULL, NULL, NULL, NULL, NULL, NULL, c);
    CLOSE c;
    SELECT COUNT(*) INTO v_n FROM core.student_ledger
     WHERE student_id = 754 AND academic_year = '2026-27' AND lower(frequency) = 'half yearly'
       AND installment_label LIKE 'Oct 2026%' AND amount_due > 0 AND COALESCE(closed_amount, 0) = 0;   -- paid or not, once
    IF v_n = 1 THEN pass := pass + 1; RAISE NOTICE 'PASS 3 running half-year billed once after the class change';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 3 % open Oct-Mar half-year lines', v_n; END IF;

    -- 4. class change refused when later months are already paid
    UPDATE core.student_ledger SET amount_paid = amount_due
     WHERE ledger_id = (SELECT ledger_id FROM core.student_ledger
                         WHERE student_id = 754 AND lower(frequency) = 'monthly' AND due_date::date > CURRENT_DATE
                           AND amount_due - amount_paid - concession > 0 ORDER BY due_date LIMIT 1);
    BEGIN
        SELECT * INTO r FROM core.students WHERE student_id = 754;
        c := 'c4';
        CALL core.sp_student_update(T, S, A, 754, r.student_name, r.roll_no, r.gender, r.dob::date, 'Class 5', 'A',
             r.guardian_name, r.mother_name, r.mobile, NULL, r.address, NULL, NULL, NULL, NULL, NULL, NULL, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 4 class change with prepaid months accepted';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 4 %', left(SQLERRM, 110); END;

    -- 5. leaving: unpaid caution deposit is closed, prepaid later months reported
    UPDATE core.student_ledger SET amount_paid = 0 WHERE student_id = 754 AND fee_head_name = 'Caution Money';
    c := 'c5';
    CALL core.sp_student_exit('Exit', T, S, A, 754, 'Transfer', CURRENT_DATE, 'Family moved', c);
    FETCH c INTO r; CLOSE c;
    SELECT COUNT(*) INTO v_n FROM core.student_ledger l
      JOIN core.school_fee_heads h ON h.fee_head_id = l.fee_head_id AND h.is_refundable
     WHERE l.student_id = 754 AND l.amount_due - l.amount_paid - l.concession > 0;
    IF v_n = 0 AND r.message LIKE '%already paid for months after leaving%' THEN pass := pass + 1; RAISE NOTICE 'PASS 5 %', r.message;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 5 % unpaid deposit lines; %', v_n, r.message; END IF;

    -- 6. new admission of the same child who left this session is refused (re-admit instead)
    SELECT * INTO r FROM core.students WHERE student_id = 754;
    c := 'c6';
    CALL core.sp_admission_manage('SaveAdmission', T, S, A, p_student_name => r.student_name, p_gender => r.gender,
         p_dob => r.dob::date, p_class_name => 'Class 3', p_section => 'A', p_academic_year => '2026-27',
         p_admission_date => CURRENT_DATE, p_guardian_name => r.guardian_name, p_mobile => r.mobile, p_result => c);
    FETCH c INTO r; CLOSE c;
    IF r.success = 0 AND r.message LIKE '%Re-admit%' THEN pass := pass + 1; RAISE NOTICE 'PASS 6 %', r.message;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 6 %', r.message; END IF;

    -- 7. re-admit: months away stay closed; a roll taken meanwhile gets the next free one
    UPDATE core.student_ledger SET due_date = to_char(date_trunc('month', CURRENT_DATE) - INTERVAL '1 month', 'YYYY-MM-DD')
     WHERE ledger_id = (SELECT ledger_id FROM core.student_ledger WHERE student_id = 754 AND close_source = 'Exit'
                         AND closed_amount > 0 ORDER BY due_date LIMIT 1)
    RETURNING ledger_id INTO v_lid;
    UPDATE core.students SET roll_no = (SELECT roll_no FROM core.students WHERE student_id = 754)
     WHERE student_id = (SELECT student_id FROM core.students WHERE is_active AND tenant_id = T AND class_name = 'Class 4' AND section = 'A' LIMIT 1);
    c := 'c7';
    CALL core.sp_student_exit('Undo', T, S, A, 754, NULL, NULL, NULL, c); CLOSE c;
    SELECT (SELECT closed_amount > 0 FROM core.student_ledger WHERE ledger_id = v_lid)::text || '/'
           || (SELECT COUNT(*) FROM core.students o, core.students me
                WHERE me.student_id = 754 AND o.is_active AND o.student_id <> 754 AND o.class_name = me.class_name
                  AND COALESCE(o.section,'') = COALESCE(me.section,'') AND o.academic_year = me.academic_year AND o.roll_no = me.roll_no)
      INTO v_txt;
    IF v_txt = 'true/0' THEN pass := pass + 1; RAISE NOTICE 'PASS 7 re-admit: past month stays closed, roll unique';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 7 %', v_txt; END IF;

    -- 8. re-admit refused once the session they left is over
    c := 'c8a';
    CALL core.sp_student_exit('Exit', T, S, A, 754, 'Withdrawn', CURRENT_DATE, NULL, c); CLOSE c;
    UPDATE core.students SET academic_year = '2025-26' WHERE student_id = 754;
    BEGIN
        c := 'c8';
        CALL core.sp_student_exit('Undo', T, S, A, 754, NULL, NULL, NULL, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 8 re-admitted into an old session';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 8 %', SQLERRM; END;

    -- 9. TC: fees paid up to is a month actually paid, attendance only up to leaving
    UPDATE core.student_ledger SET amount_paid = amount_due - concession
     WHERE student_id = 659 AND (due_date IS NULL OR due_date::date <= CURRENT_DATE);
    c := 'c9a';
    CALL core.sp_student_exit('Exit', T, S, A, 659, 'Transfer', CURRENT_DATE, 'Transfer', c); CLOSE c;
    DELETE FROM core.student_advance WHERE student_id = 659;
    c := 'c9';
    CALL core.sp_tc_manage('Issue', T, S, A, NULL, 659, 'Basic', 'Good', 'Passed', 'Transfer', NULL, p_result_cur => c);
    FETCH c INTO r; CLOSE c;
    SELECT fees_paid_upto || ' / ' || working_days INTO v_txt FROM core.tc_register WHERE student_id = 659 AND NOT is_void;
    -- the month named must be one actually PAID (not a line closed at leaving)
    IF EXISTS (SELECT 1 FROM core.student_ledger l, core.tc_register t
                WHERE t.student_id = 659 AND NOT t.is_void AND l.student_id = 659
                  AND l.installment_label = t.fees_paid_upto AND COALESCE(l.closed_amount, 0) = 0
                  AND l.amount_paid > 0) THEN pass := pass + 1; RAISE NOTICE 'PASS 9 TC: % (%)', v_txt, left(r.message, 80);
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 9 TC says %', v_txt; END IF;

    -- 10. after the TC: no collecting, no cancelling
    BEGIN
        c := 'c10';
        CALL core.sp_fee_payment_collect(T, S, A, 659, '[]'::jsonb,
             '[{"name":"Misc","amount":10}]'::jsonb, 'Cash', NULL, NULL, CURRENT_DATE, '2026-27',
             NULL, 0, NULL, NULL, 0, c, NULL, NULL);
        fail := fail + 1; RAISE NOTICE 'FAIL 10a money taken after the TC';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM LIKE '%Transfer Certificate%' THEN pass := pass + 1; RAISE NOTICE 'PASS 10a %', SQLERRM;
        ELSE fail := fail + 1; RAISE NOTICE 'FAIL 10a other error: %', SQLERRM; END IF;
    END;
    SELECT receipt_no INTO v_rcp FROM core.fee_payments WHERE student_id = 659 AND NOT is_cancelled LIMIT 1;
    BEGIN
        c := 'c10b';
        CALL core.sp_fee_receipt_cancel(T, S, A, v_rcp, 'test', NULL, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 10b receipt cancelled after the TC';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM LIKE '%Transfer Certificate%' THEN pass := pass + 1; RAISE NOTICE 'PASS 10b %', SQLERRM;
        ELSE fail := fail + 1; RAISE NOTICE 'FAIL 10b other error: %', SQLERRM; END IF;
    END;

    -- 11. a TC needs a leaving status that warrants one (Withdrawn does not)
    UPDATE core.students SET is_active = FALSE, status = 'Withdrawn' WHERE student_id = 706;
    BEGIN
        c := 'c11';
        CALL core.sp_tc_manage('Issue', T, S, A, NULL, 706, 'Basic', 'Good', 'Passed', 'x', NULL, p_result_cur => c);
        fail := fail + 1; RAISE NOTICE 'FAIL 11 TC for a withdrawn student';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 11 %', SQLERRM; END;

    -- 12. fee head with last session's unpaid arrears cannot be deleted
    INSERT INTO core.student_ledger (tenant_id, school_id, student_id, fee_head_name, fee_head_id, frequency,
                                     installment_label, due_date, amount_due, status, academic_year)
    SELECT T, S, 707, h.fee_head_name, h.fee_head_id, 'Yearly', 'Annual', '2026-03-01', 300, 'Pending', '2025-26'
      FROM core.school_fee_heads h WHERE h.fee_head_id = 160;
    c := 'c12';
    CALL core.sp_fee_head_delete_cascade(T, S, A, 160, c); FETCH c INTO r; CLOSE c;
    IF NOT r.success AND r.message LIKE '%earlier session%' THEN pass := pass + 1; RAISE NOTICE 'PASS 12 %', r.message;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 12 %', r.message; END IF;

    -- 13. deactivating a fee head says what stays billed
    c := 'c13';
    CALL core.sp_school_admin_fee_head_manage('ToggleFeeHeadStatus', T, S, A, 153, NULL, NULL, NULL, NULL, NULL, NULL, NULL, c);
    FETCH c INTO r; CLOSE c;
    IF r.message LIKE '%already billed%' THEN pass := pass + 1; RAISE NOTICE 'PASS 13 %', left(r.message, 140);
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 13 %', r.message; END IF;

    -- 14. a day whose attendance was taken cannot become a holiday
    BEGIN
        c := 'c14'; c2 := 'c14b';
        CALL academic.sp_school_admin_calendar_manage('SaveEntry', T, S, A, NULL, '2026-10-14', NULL, 'holiday', 'Test', NULL, NULL, c, c2);
        fail := fail + 1; RAISE NOTICE 'FAIL 14 holiday on a taught day accepted';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 14 %', SQLERRM; END;

    -- 15. a staff member who leaves is taken off class teacher and the timetable
    c := 'c15';
    CALL core.sp_staff_manage('DELETE', T, S, A, 121, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
         NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
         FALSE, NULL, NULL, NULL, NULL, c, CURRENT_DATE);
    CLOSE c;
    SELECT (SELECT COUNT(*) FROM academic.academic_class_sections WHERE class_teacher_staff_id = 121)
           + (SELECT COUNT(*) FROM academic.timetable t JOIN academic.academic_years y ON y.academic_year_id = t.academic_year_id
               WHERE t.staff_id = 121 AND y.end_date::date >= CURRENT_DATE) INTO v_n;
    IF v_n = 0 THEN pass := pass + 1; RAISE NOTICE 'PASS 15 class charge and periods released';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 15 % still assigned', v_n; END IF;

    -- 16. session dates cannot shrink past fees / attendance already in it
    BEGIN
        c := 'c16';
        CALL academic.sp_school_admin_academic_year_manage('SaveAcademicYear', T, S, A, 37, '2026-27',
             '2026-11-01', '2027-03-31', TRUE, 'AdmissionMonth', c);
        fail := fail + 1; RAISE NOTICE 'FAIL 16 session shrunk past billed / marked days';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 16 %', SQLERRM; END;

    RAISE NOTICE '== % passed, % failed ==', pass, fail;
END;
$t$;

ROLLBACK;
