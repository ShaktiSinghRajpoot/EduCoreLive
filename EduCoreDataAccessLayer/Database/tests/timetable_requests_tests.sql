-- Timetable requests (timetable_requests.sql): 11 checks. Uses the QA Test School
-- data (tenant 32: QA Teacher login 63 = staff 92, admin 62, accountant 64,
-- 7-A = section 2527, 2-A = 2522). Creates the table/proc inside the transaction
-- and ROLLS BACK, so it leaves nothing behind. Run from this folder:
--     psql ... -f timetable_requests_tests.sql
-- Timetable requests: end-to-end checks on QA Test School, all rolled back.
\set ON_ERROR_STOP 1
BEGIN;
\ir ../timetable_requests.sql

DO $t$
DECLARE
    T int := 32; S int := 45;
    TEACHER int := 63;       -- QA Teacher's login (staff 92)
    ADMIN int := 62;         -- QA School Admin
    ACCOUNTANT int := 64;    -- non-teaching login
    SEC7A int := 2527; SEC2A int := 2522;
    ENGLISH int := 153; BIOLOGY int;
    c refcursor; r record; v_id int; v_id2 int; v_id3 int; v_live text; v_n int; v_status text; v_note text;
    pass int := 0; fail int := 0;

    -- run one call that SHOULD fail and check its message
BEGIN
    SELECT subject_id INTO BIOLOGY FROM academic.school_subjects WHERE tenant_id = T AND school_id = S AND subject_name = 'Biology' LIMIT 1;

    -- 1. a teacher requests a free period: Pending, live timetable unchanged
    SELECT s.subject_name || '/' || st.full_name INTO v_live FROM academic.timetable t
      JOIN academic.school_subjects s ON s.subject_id = t.subject_id JOIN core.staff st ON st.staff_id = t.staff_id
     WHERE t.academic_class_section_id = SEC7A AND t.day_of_week = 5 AND t.period_seq = 6;
    CALL academic.sp_timetable_request_manage('Request', T, S, TEACHER, SEC7A, 5::smallint, 6::smallint, ENGLISH, NULL, NULL, c);
    FETCH c INTO r; CLOSE c;
    SELECT request_id, status INTO v_id, v_status FROM academic.timetable_requests WHERE staff_id = 92 ORDER BY request_id DESC LIMIT 1;
    IF v_status = 'Pending' AND (SELECT s.subject_name || '/' || st.full_name FROM academic.timetable t
          JOIN academic.school_subjects s ON s.subject_id = t.subject_id JOIN core.staff st ON st.staff_id = t.staff_id
         WHERE t.academic_class_section_id = SEC7A AND t.day_of_week = 5 AND t.period_seq = 6) = v_live
    THEN pass := pass + 1; RAISE NOTICE 'PASS 1 request is Pending, live 7-A Fri P6 still % (%)', v_live, r.message;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 1 status=% live changed', v_status; END IF;

    -- 2. a second request for the same period is refused
    BEGIN
        CALL academic.sp_timetable_request_manage('Request', T, S, TEACHER, SEC2A, 5::smallint, 6::smallint, ENGLISH, NULL, NULL, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 2 duplicate pending accepted';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 2 duplicate refused: %', SQLERRM; END;

    -- 3. a period where the teacher already teaches another section is refused
    BEGIN
        CALL academic.sp_timetable_request_manage('Request', T, S, TEACHER, SEC7A, 1::smallint, 10::smallint, ENGLISH, NULL, NULL, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 3 busy period accepted';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 3 busy refused: %', SQLERRM; END;

    -- 4. a subject the class does not study is refused
    BEGIN
        CALL academic.sp_timetable_request_manage('Request', T, S, TEACHER, SEC7A, 4::smallint, 6::smallint, BIOLOGY, NULL, NULL, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 4 wrong subject accepted';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 4 wrong subject refused: %', SQLERRM; END;

    -- 5. non-teaching staff cannot request
    BEGIN
        CALL academic.sp_timetable_request_manage('Request', T, S, ACCOUNTANT, SEC7A, 4::smallint, 6::smallint, ENGLISH, NULL, NULL, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 5 accountant accepted';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 5 non-teacher refused: %', SQLERRM; END;

    -- 6. teacher sees it under Mine; admin sees it under Pending with what is live now
    CALL academic.sp_timetable_request_manage('Mine', T, S, TEACHER, NULL, NULL, NULL, NULL, NULL, NULL, c);
    -- count only this test's request: the teacher may have real ones too
    v_n := 0; LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.request_id = v_id THEN v_n := v_n + 1; END IF; END LOOP; CLOSE c;
    CALL academic.sp_timetable_request_manage('Pending', T, S, ADMIN, NULL, NULL, NULL, NULL, NULL, NULL, c);
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND OR r.request_id = v_id; END LOOP; CLOSE c;
    IF v_n = 1 AND r.request_id = v_id AND r.live_now IS NOT NULL AND r.period_label LIKE 'Period %'
    THEN pass := pass + 1; RAISE NOTICE 'PASS 6 in Mine; admin Pending shows %, % % for % (live now: %)', r.period_label, r.section_label, r.subject_name, r.teacher_name, r.live_now;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 6 mine=% pending=%', v_n, r; END IF;

    -- a competing request from another teacher for the SAME section + period (no login, so inserted directly)
    INSERT INTO academic.timetable_requests (tenant_id, school_id, academic_year_id, academic_class_section_id, day_of_week, period_seq, subject_id, staff_id, requested_by)
    SELECT T, S, 37, SEC7A, 5, 6, 154, staff_id, ADMIN FROM core.staff WHERE tenant_id = T AND email = 'qa.t14@example.com'
    RETURNING request_id INTO v_id2;
    -- and one for the teacher that will clash once the first is approved
    INSERT INTO academic.timetable_requests (tenant_id, school_id, academic_year_id, academic_class_section_id, day_of_week, period_seq, subject_id, staff_id, requested_by)
    VALUES (T, S, 37, SEC2A, 5, 6, ENGLISH, 92, TEACHER) RETURNING request_id INTO v_id3;

    -- 7. admin approves: goes live, the competitor is rejected automatically
    CALL academic.sp_timetable_request_manage('Approve', T, S, ADMIN, NULL, NULL, NULL, NULL, v_id, NULL, c);
    FETCH c INTO r; CLOSE c;
    SELECT s.subject_name || '/' || st.full_name INTO v_live FROM academic.timetable t
      JOIN academic.school_subjects s ON s.subject_id = t.subject_id JOIN core.staff st ON st.staff_id = t.staff_id
     WHERE t.academic_class_section_id = SEC7A AND t.day_of_week = 5 AND t.period_seq = 6;
    SELECT status, note INTO v_status, v_note FROM academic.timetable_requests WHERE request_id = v_id2;
    IF v_live = 'English/QA Teacher' AND (SELECT status FROM academic.timetable_requests WHERE request_id = v_id) = 'Approved'
       AND v_status = 'Rejected'
    THEN pass := pass + 1; RAISE NOTICE 'PASS 7 approved: live 7-A Fri P6 = %; competitor % (%)', v_live, v_status, v_note;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 7 live=% competitor=%', v_live, v_status; END IF;

    -- 8. approving a request that now clashes is refused and stays pending
    BEGIN
        CALL academic.sp_timetable_request_manage('Approve', T, S, ADMIN, NULL, NULL, NULL, NULL, v_id3, NULL, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 8 clashing approval accepted';
    EXCEPTION WHEN raise_exception THEN
        pass := pass + 1; RAISE NOTICE 'PASS 8 clash refused: % (status still %)', SQLERRM,
            (SELECT status FROM academic.timetable_requests WHERE request_id = v_id3);
    END;

    -- 9. reject needs a reason; with one it is Rejected and the teacher sees why
    BEGIN
        CALL academic.sp_timetable_request_manage('Reject', T, S, ADMIN, NULL, NULL, NULL, NULL, v_id3, '  ', c);
        fail := fail + 1; RAISE NOTICE 'FAIL 9 reject without reason accepted';
    EXCEPTION WHEN raise_exception THEN
        CALL academic.sp_timetable_request_manage('Reject', T, S, ADMIN, NULL, NULL, NULL, NULL, v_id3, 'You teach 7-A in that period now.', c);
        CLOSE c;
        SELECT status, note INTO v_status, v_note FROM academic.timetable_requests WHERE request_id = v_id3;
        IF v_status = 'Rejected' THEN pass := pass + 1; RAISE NOTICE 'PASS 9 blank reason refused; rejected with note "%"', v_note;
        ELSE fail := fail + 1; RAISE NOTICE 'FAIL 9 status=%', v_status; END IF;
    END;

    -- 10. a change request for an approved period: old stays live until approved
    CALL academic.sp_timetable_request_manage('Request', T, S, TEACHER, SEC7A, 5::smallint, 6::smallint, 154, NULL, NULL, c);
    CLOSE c;
    SELECT request_id INTO v_id FROM academic.timetable_requests WHERE staff_id = 92 AND status = 'Pending' LIMIT 1;
    SELECT s.subject_name INTO v_live FROM academic.timetable t JOIN academic.school_subjects s ON s.subject_id = t.subject_id
     WHERE t.academic_class_section_id = SEC7A AND t.day_of_week = 5 AND t.period_seq = 6;
    IF v_live = 'English' AND v_id IS NOT NULL
    THEN pass := pass + 1; RAISE NOTICE 'PASS 10 change to Hindi is pending, English still live';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 10 live=%', v_live; END IF;

    -- 11. a teacher cancels their own pending request; nobody else can
    BEGIN
        CALL academic.sp_timetable_request_manage('Cancel', T, S, ACCOUNTANT, NULL, NULL, NULL, NULL, v_id, NULL, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 11 someone else cancelled it';
    EXCEPTION WHEN raise_exception THEN
        CALL academic.sp_timetable_request_manage('Cancel', T, S, TEACHER, NULL, NULL, NULL, NULL, v_id, NULL, c);
        CLOSE c;
        IF (SELECT status FROM academic.timetable_requests WHERE request_id = v_id) = 'Cancelled'
        THEN pass := pass + 1; RAISE NOTICE 'PASS 11 other user refused (%), own cancel worked', SQLERRM;
        ELSE fail := fail + 1; RAISE NOTICE 'FAIL 11'; END IF;
    END;

    RAISE NOTICE '==== % passed, % failed ====', pass, fail;
END $t$;
ROLLBACK;
