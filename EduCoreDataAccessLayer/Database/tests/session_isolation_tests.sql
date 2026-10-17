-- Students of one session never show up in another (17 Oct 2026).
-- QA Test School (tenant 32, school 45, admin 62). 2026-27 is current; 703-705 were
-- promoted from Nursery-A to 2027-28 Class 1-A on 15 Oct (before the session ends);
-- 659, 706, 707 are 2026-27 Class 1-A. Everything is ROLLED BACK. Run from this folder:
--     psql ... -f session_isolation_tests.sql
\set ON_ERROR_STOP 1
BEGIN;
\o NUL
\ir ../session_rolls.sql
\ir ../student_attendance.sql
\ir ../attendance_student.sql
\ir ../attendance_report.sql
\ir ../attendance_overview.sql
\ir ../dashboard_summary.sql
\ir ../report_card_certificates.sql
\ir ../student_master_fields.sql
\ir ../student_update.sql
\ir ../student_data_checks.sql
\ir ../fee_dashboard.sql
\ir ../fee_reports.sql
\ir ../homework.sql
\o

DO $t$
DECLARE
    T int := 32; S int := 45; A int := 62;
    c refcursor; c2 refcursor; c3 refcursor; c4 refcursor; c5 refcursor; c6 refcursor; c7 refcursor; c8 refcursor; c9 refcursor; c10 refcursor; c11 refcursor;
    r record; v_txt text; v_n int; v_m int; v_students jsonb;
    pass int := 0; fail int := 0;
BEGIN
    -- 1. promoted early: still on the OLD class's register until the session ends
    SELECT string_agg(student_id::text, ',' ORDER BY student_id) INTO v_txt
      FROM core.fn_attendance_register(T, S, 'Nursery', 'A', CURRENT_DATE);
    IF v_txt LIKE '%703%' AND v_txt LIKE '%704%' AND v_txt LIKE '%705%'
    THEN pass := pass + 1; RAISE NOTICE 'PASS 1 Nursery-A today: %', v_txt;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 1 Nursery-A today: %', v_txt; END IF;

    -- 2. ...and not on the new class's register before the new session starts
    SELECT string_agg(student_id::text, ',' ORDER BY student_id) INTO v_txt
      FROM core.fn_attendance_register(T, S, 'Class 1', 'A', CURRENT_DATE);
    IF v_txt = '659,706,707' THEN pass := pass + 1; RAISE NOTICE 'PASS 2 Class 1-A today: %', v_txt;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 2 Class 1-A today: %', v_txt; END IF;

    -- 3. ...and on it once the new session starts
    SELECT string_agg(student_id::text, ',' ORDER BY student_id) INTO v_txt
      FROM core.fn_attendance_register(T, S, 'Class 1', 'A', DATE '2027-04-05');
    IF v_txt = '703,704,705' THEN pass := pass + 1; RAISE NOTICE 'PASS 3 Class 1-A in April 2027: %', v_txt;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 3 Class 1-A in April 2027: %', v_txt; END IF;

    -- 4. marking the old class saves the OLD class and this session on the row
    DELETE FROM core.student_attendance WHERE student_id = 703 AND attendance_date = to_char(CURRENT_DATE, 'YYYY-MM-DD');
    c := 'c4';
    CALL core.sp_attendance_save(T, S, A, CURRENT_DATE, 'Nursery', 'A',
         jsonb_build_array(jsonb_build_object('studentId', 703, 'status', 'Present', 'remarks', '')), c);
    CLOSE c;
    SELECT academic_year || '/' || class_name || '/' || section INTO v_txt
      FROM core.student_attendance WHERE student_id = 703 AND attendance_date = to_char(CURRENT_DATE, 'YYYY-MM-DD');
    IF v_txt = '2026-27/Nursery/A' THEN pass := pass + 1; RAISE NOTICE 'PASS 4 row saved as %', v_txt;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 4 row saved as %', v_txt; END IF;

    -- 5. marking a promoted child on the new class now is refused
    BEGIN
        c := 'c5';
        CALL core.sp_attendance_save(T, S, A, CURRENT_DATE, 'Class 1', 'A',
             jsonb_build_array(jsonb_build_object('studentId', 704, 'status', 'Present', 'remarks', '')), c);
        fail := fail + 1; RAISE NOTICE 'FAIL 5 next-session class marked today';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 5 %', SQLERRM; END;

    -- 6. promote Class 1-A to Class 2 (2027-28) now: they stay on Class 1-A today
    SELECT jsonb_agg(jsonb_build_object('studentId', id, 'outcome', 'Promote')) INTO v_students
      FROM unnest(ARRAY[659, 706, 707]) id;
    c := 'c6';
    CALL core.sp_student_promote(T, S, A, '2026-27', '2027-28', NULL, TRUE, v_students, c); FETCH c INTO r; CLOSE c;
    SELECT string_agg(student_id::text, ',' ORDER BY student_id) INTO v_txt
      FROM core.fn_attendance_register(T, S, 'Class 1', 'A', CURRENT_DATE);
    SELECT COUNT(*) INTO v_n FROM core.fn_attendance_register(T, S, 'Class 2', 'A', CURRENT_DATE)
     WHERE student_id IN (659, 706, 707);
    SELECT COUNT(*) INTO v_m FROM core.fn_attendance_register(T, S, 'Class 2', 'A', DATE '2027-04-05')
     WHERE student_id IN (659, 706, 707);
    IF v_txt = '659,706,707' AND v_n = 0 AND v_m = 3
    THEN pass := pass + 1; RAISE NOTICE 'PASS 6 promoted (%): Class 1-A today %, Class 2-A in April 2027 has all 3', r.message, v_txt;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 6 % / 1-A today % / 2-A today % / 2-A April %', r.message, v_txt, v_n, v_m; END IF;

    -- 7. their attendance page still shows this session (not the empty new one)
    c := 'c7'; c2 := 'c7b'; c3 := 'c7c';
    CALL core.sp_attendance_student(T, S, A, 659, NULL, NULL, NULL, c, c2, c3);
    FETCH c INTO r; CLOSE c; CLOSE c2; CLOSE c3;
    IF r.school_days > 0 THEN pass := pass + 1; RAISE NOTICE 'PASS 7 after promotion: % school days, % present (2026-27)', r.school_days, r.present;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 7 after promotion: no attendance shown'; END IF;

    -- 8. dashboard: the promoted children still count in 2026-27; Class 1 counted once
    c := 'k'; c2 := 't'; c3 := 'cl'; c4 := 'm'; c5 := 'd'; c6 := 'r'; c7 := 'a'; c8 := 'e'; c9 := 'b';
    CALL core.sp_dashboard_summary(T, S, A, c, c2, c3, c4, c5, c6, c7, c8, c9);
    FETCH c INTO r; v_n := r.students; CLOSE c;
    v_m := 0;
    LOOP FETCH c3 INTO r; EXIT WHEN NOT FOUND; IF r.class_name = 'Class 1' THEN v_m := r.students; END IF; END LOOP;
    CLOSE c2; CLOSE c3; CLOSE c4; CLOSE c5; CLOSE c6; CLOSE c7; CLOSE c8; CLOSE c9;
    IF v_n = (SELECT COUNT(DISTINCT student_id) FROM core.student_enrolment WHERE tenant_id = T AND school_id = S
               AND academic_year = '2026-27' AND status NOT IN ('Left', 'PassedOut'))
       AND v_m = (SELECT COUNT(*) FROM core.student_enrolment WHERE tenant_id = T AND school_id = S
               AND academic_year = '2026-27' AND class_name = 'Class 1' AND status NOT IN ('Left', 'PassedOut'))
    THEN pass := pass + 1; RAISE NOTICE 'PASS 8 dashboard: % students, Class 1 = %', v_n, v_m;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 8 dashboard: % students, Class 1 = %', v_n, v_m; END IF;

    -- 9. a roll held by a child promoted early is not handed out again in the old class
    SELECT (COALESCE(MAX(roll_no::int), 0) + 1) INTO v_n
      FROM core.fn_session_rolls(T, S, '2026-27', 'Class 1', 'A') WHERE roll_no ~ '^[0-9]+$';
    IF v_n > 3 THEN pass := pass + 1; RAISE NOTICE 'PASS 9 next free roll in 2026-27 Class 1-A is % (rolls of promoted children kept)', v_n;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 9 next roll %', v_n; END IF;

    -- 10. bonafide: promoted early -> still the old class; only next session -> refused
    c := 'c10';
    CALL core.sp_certificate_manage('Issue', T, S, A, NULL, 703, 'Bonafide', 'Bank account', NULL, NULL, NULL, c);
    FETCH c INTO r; CLOSE c;
    SELECT class_name || '/' || academic_year INTO v_txt FROM core.certificates WHERE student_id = 703 ORDER BY cert_id DESC LIMIT 1;
    DELETE FROM core.student_enrolment WHERE student_id = 704 AND academic_year = '2026-27';
    BEGIN
        c := 'c10b';
        CALL core.sp_certificate_manage('Issue', T, S, A, NULL, 704, 'Bonafide', 'Bank account', NULL, NULL, NULL, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 10 bonafide for a child whose session has not started';
    EXCEPTION WHEN raise_exception THEN
        IF v_txt = 'Nursery/2026-27' THEN pass := pass + 1; RAISE NOTICE 'PASS 10 promoted child: %; not started: %', v_txt, left(SQLERRM, 90);
        ELSE fail := fail + 1; RAISE NOTICE 'FAIL 10 certificate said %', v_txt; END IF;
    END;

    -- 11. month register: the promoted child is on Nursery-A this month
    c := 'm1'; c2 := 'm2'; c3 := 'm3'; c4 := 'm4';
    CALL core.sp_attendance_month_register(T, S, A, 'Nursery', 'A', EXTRACT(MONTH FROM CURRENT_DATE)::int,
         EXTRACT(YEAR FROM CURRENT_DATE)::int, c, c2, c3, c4);
    v_n := 0;
    LOOP FETCH c2 INTO r; EXIT WHEN NOT FOUND; IF r.student_id IN (703, 705) THEN v_n := v_n + 1; END IF; END LOOP;
    CLOSE c; CLOSE c2; CLOSE c3; CLOSE c4;
    IF v_n = 2 THEN pass := pass + 1; RAISE NOTICE 'PASS 11 month register Nursery-A lists the promoted children';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 11 month register found % of 2', v_n; END IF;

    -- 12. the fee dashboard, defaulters and attendance overview still run
    c := 'f1'; c2 := 'f2'; c3 := 'f3'; c4 := 'f4'; c5 := 'f5'; c6 := 'f6'; c7 := 'f7'; c8 := 'f8'; c9 := 'f9';
    c10 := 'f10'; c11 := 'f11';
    CALL core.sp_fee_dashboard(T, S, A, c, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11);
    CLOSE c; CLOSE c2; CLOSE c3; CLOSE c4; CLOSE c5; CLOSE c6; CLOSE c7; CLOSE c8; CLOSE c9; CLOSE c10; CLOSE c11;
    c := 'g1';
    CALL core.sp_fee_defaulters_get(T, S, A, 'Class 1', 'A', c, '2026-27'); CLOSE c;
    c := 'o1'; c2 := 'o2'; c3 := 'o3'; c4 := 'o4'; c5 := 'o5';
    CALL core.sp_attendance_overview(T, S, A, CURRENT_DATE, CURRENT_DATE - 7, CURRENT_DATE, c, c2, c3, c4, c5);
    v_n := 0;
    LOOP FETCH c2 INTO r; EXIT WHEN NOT FOUND; IF r.class_name = 'Class 1' THEN v_n := v_n + r.students; END IF; END LOOP;
    CLOSE c; CLOSE c2; CLOSE c3; CLOSE c4; CLOSE c5;
    IF v_n >= 3 THEN pass := pass + 1; RAISE NOTICE 'PASS 12 fee dashboard, defaulters run; overview Class 1 still has % after promotion', v_n;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 12 overview Class 1 = %', v_n; END IF;

    -- 13. a date before the school's first session belongs to no session: nobody on its register
    IF core.fn_session_on(T, S, DATE '2024-05-10') IS NULL
       AND NOT EXISTS (SELECT 1 FROM core.fn_attendance_register(T, S, 'Class 1', 'A', DATE '2024-05-10'))
       AND core.fn_session_on(T, S, DATE '2025-05-10') = '2025-26'
    THEN pass := pass + 1; RAISE NOTICE 'PASS 13 2024 = no session (empty register), 2025 = 2025-26';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 13 2024 -> %', core.fn_session_on(T, S, DATE '2024-05-10'); END IF;

    RAISE NOTICE '== % passed, % failed ==', pass, fail;
END;
$t$;

ROLLBACK;
