-- Promote a class during the session and check nothing leaks between sessions (17 Oct 2026).
-- QA Test School (tenant 32, school 45, admin 62). Class 7-A (725, 726, 727; class
-- teacher staff 130) is promoted to Class 8 for 2027-28 while 2026-27 is current.
-- Everything is ROLLED BACK. Run from this folder:
--     psql ... -f promotion_flow_tests.sql
\set ON_ERROR_STOP 1
BEGIN;
\o NUL
\ir ../class_teacher_of.sql
\ir ../fee_year_end.sql
\o

DO $t$
DECLARE
    T int := 32; S int := 45; A int := 62;
    KIDS int[] := ARRAY[725, 726, 727];
    c refcursor; c2 refcursor; c3 refcursor; c4 refcursor; c5 refcursor; c6 refcursor; c7 refcursor; c8 refcursor; c9 refcursor;
    r record; v_txt text; v_n int; v_m int; v_students jsonb; v_cls7 int; v_sec7 int; v_y int := 37;
    v_before_kpi int; v_before_c7 int; v_rolls_before text;
    pass int := 0; fail int := 0;

BEGIN
    SELECT c.academic_class_id, sec.academic_class_section_id INTO v_cls7, v_sec7
      FROM academic.academic_classes c JOIN academic.academic_class_sections sec ON sec.academic_class_id = c.academic_class_id
     WHERE c.tenant_id = T AND c.class_name = 'Class 7' AND c.academic_year_id = v_y AND sec.section_name = 'A';

    -- dashboard numbers before
    c := 'k'; c2 := 't'; c3 := 'cl'; c4 := 'm'; c5 := 'd'; c6 := 'r'; c7 := 'a'; c8 := 'e'; c9 := 'b';
    CALL core.sp_dashboard_summary(T, S, A, c, c2, c3, c4, c5, c6, c7, c8, c9);
    FETCH c INTO r; v_before_kpi := r.students; v_before_c7 := 0;
    LOOP FETCH c3 INTO r; EXIT WHEN NOT FOUND; IF r.class_name = 'Class 7' THEN v_before_c7 := r.students; END IF; END LOOP;
    CLOSE c; CLOSE c2; CLOSE c3; CLOSE c4; CLOSE c5; CLOSE c6; CLOSE c7; CLOSE c8; CLOSE c9;
    SELECT string_agg(roll_no, ',' ORDER BY student_id) INTO v_rolls_before FROM core.student_enrolment
     WHERE student_id = ANY(KIDS) AND academic_year = '2026-27';

    -- ── PROMOTE ──
    SELECT jsonb_agg(jsonb_build_object('studentId', id, 'outcome', 'Promote')) INTO v_students FROM unnest(KIDS) id;
    c := 'p';
    CALL core.sp_student_promote(T, S, A, '2026-27', '2027-28', NULL, TRUE, v_students, c); FETCH c INTO r; CLOSE c;

    -- 1. moved: present record is Class 8 / 2027-28, old enrolment kept as Promoted
    SELECT COUNT(*) INTO v_n FROM core.students WHERE student_id = ANY(KIDS) AND class_name = 'Class 8' AND academic_year = '2027-28';
    SELECT COUNT(*) INTO v_m FROM core.student_enrolment WHERE student_id = ANY(KIDS) AND academic_year = '2026-27' AND status = 'Promoted' AND class_name = 'Class 7';
    IF v_n = 3 AND v_m = 3 AND r.promoted = 3 THEN pass := pass + 1; RAISE NOTICE 'PASS 1 %', r.message;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 1 moved %, old rows %, %', v_n, v_m, r.message; END IF;

    -- 2. billed for 2027-28 (due from April 2027), 2026-27 dues untouched
    SELECT COUNT(*) INTO v_n FROM core.student_ledger WHERE student_id = ANY(KIDS) AND academic_year = '2027-28';
    -- (lines carried from 2026-27 by Year-End keep their old due dates; only NEW 2027-28 charges count)
    SELECT COUNT(*) INTO v_m FROM core.student_ledger WHERE student_id = ANY(KIDS) AND academic_year = '2027-28'
       AND carried_from IS NULL AND due_date::date < DATE '2027-04-01';
    IF v_n > 0 AND v_m = 0 THEN pass := pass + 1; RAISE NOTICE 'PASS 2 % fee lines for 2027-28, none due before April 2027', v_n;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 2 2027-28 lines %, due early %', v_n, v_m; END IF;

    -- 3. attendance: still on Class 7-A today, not on Class 8-A until 2027-28
    SELECT COUNT(*) INTO v_n FROM core.fn_attendance_register(T, S, 'Class 7', 'A', CURRENT_DATE) WHERE student_id = ANY(KIDS);
    SELECT COUNT(*) INTO v_m FROM core.fn_attendance_register(T, S, 'Class 8', 'A', CURRENT_DATE) WHERE student_id = ANY(KIDS);
    IF v_n = 3 AND v_m = 0 AND (SELECT COUNT(*) FROM core.fn_attendance_register(T, S, 'Class 8', 'A', DATE '2027-04-05') WHERE student_id = ANY(KIDS)) = 3
    THEN pass := pass + 1; RAISE NOTICE 'PASS 3 register: Class 7-A today, Class 8-A from April 2027';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 3 7-A today %, 8-A today %', v_n, v_m; END IF;

    -- 4. dashboard: same student count, Class 7 count unchanged
    c := 'k2'; c2 := 't2'; c3 := 'cl2'; c4 := 'm2'; c5 := 'd2'; c6 := 'r2'; c7 := 'a2'; c8 := 'e2'; c9 := 'b2';
    CALL core.sp_dashboard_summary(T, S, A, c, c2, c3, c4, c5, c6, c7, c8, c9);
    FETCH c INTO r; v_n := r.students; v_m := 0;
    LOOP FETCH c3 INTO r; EXIT WHEN NOT FOUND; IF r.class_name = 'Class 7' THEN v_m := r.students; END IF; END LOOP;
    CLOSE c; CLOSE c2; CLOSE c3; CLOSE c4; CLOSE c5; CLOSE c6; CLOSE c7; CLOSE c8; CLOSE c9;
    IF v_n = v_before_kpi AND v_m = v_before_c7 THEN pass := pass + 1; RAISE NOTICE 'PASS 4 dashboard unchanged: % students, Class 7 = %', v_n, v_m;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 4 dashboard % -> %, Class 7 % -> %', v_before_kpi, v_n, v_before_c7, v_m; END IF;

    -- 5. class teacher card: Class 7-A still has its children
    c := 'ct';
    CALL core.sp_class_teacher_of(T, S, A, 130, c);
    v_n := NULL;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.class_name = 'Class 7' AND r.section_name = 'A' THEN v_n := r.students; END IF; END LOOP; CLOSE c;
    IF v_n >= 3 THEN pass := pass + 1; RAISE NOTICE 'PASS 5 class teacher card: Class 7-A has % students', v_n;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 5 class teacher card shows %', v_n; END IF;

    -- 6. exam sheet for 2026-27 Class 7-A still lists them (marks of this year stay with this class)
    SELECT COUNT(*) INTO v_n FROM academic.fn_exam_sheet_roster(T, S, v_y, v_cls7, 'A') WHERE out_student_id = ANY(KIDS);
    IF v_n = 3 THEN pass := pass + 1; RAISE NOTICE 'PASS 6 2026-27 Class 7-A exam sheet lists all 3';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 6 exam sheet has %', v_n; END IF;

    -- 7. homework: the section count keeps them, and a child's own homework is Class 7-A's
    SELECT COUNT(*) INTO v_n FROM core.student_enrolment e
     WHERE e.academic_year = '2026-27' AND e.class_name = 'Class 7' AND e.section = 'A' AND e.status NOT IN ('Left', 'PassedOut');
    INSERT INTO academic.homework (tenant_id, school_id, academic_class_section_id, subject_id, staff_id, title, assigned_on, due_on, created_by)
    SELECT T, S, v_sec7, (SELECT subject_id FROM academic.school_subjects WHERE tenant_id = T LIMIT 1), 130, 'Promotion test homework', CURRENT_DATE, CURRENT_DATE + 2, A;
    c := 'hw';
    CALL academic.sp_homework_manage('Student', T, S, A, FALSE, NULL, NULL, NULL, NULL, NULL, NULL, NULL, FALSE, NULL, NULL, 725, c);
    v_txt := NULL;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.title = 'Promotion test homework' THEN v_txt := r.title; END IF; END LOOP; CLOSE c;
    IF v_n >= 3 AND v_txt IS NOT NULL THEN pass := pass + 1; RAISE NOTICE 'PASS 7 homework: section roll %, child sees Class 7-A homework', v_n;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 7 roll %, homework seen %', v_n, v_txt; END IF;

    -- 8. ID cards: 2026-27 Class 7 still prints them as Class 7; 2027-28 Class 8 has them as Class 8
    c := 'id1';
    CALL core.sp_id_card_students(T, S, A, 'Class 7', 'A', '2026-27', NULL, c);
    v_n := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.student_id = ANY(KIDS) THEN v_n := v_n + 1; END IF; END LOOP; CLOSE c;
    c := 'id2';
    CALL core.sp_id_card_students(T, S, A, 'Class 8', 'A', '2027-28', NULL, c);
    v_m := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.student_id = ANY(KIDS) THEN v_m := v_m + 1; END IF; END LOOP; CLOSE c;
    IF v_n = 3 AND v_m = 3 THEN pass := pass + 1; RAISE NOTICE 'PASS 8 ID cards: 2026-27 Class 7 = 3, 2027-28 Class 8 = 3';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 8 ID cards 2026-27 %, 2027-28 %', v_n, v_m; END IF;

    -- 9. roll numbers: their 2026-27 rolls stay, and Class 7-A's next free roll is after them
    SELECT string_agg(roll_no, ',' ORDER BY student_id) INTO v_txt FROM core.student_enrolment
     WHERE student_id = ANY(KIDS) AND academic_year = '2026-27';
    SELECT COALESCE(MAX(roll_no::int), 0) + 1 INTO v_n FROM core.fn_session_rolls(T, S, '2026-27', 'Class 7', 'A') WHERE roll_no ~ '^[0-9]+$';
    IF v_txt = v_rolls_before AND v_n >= 4 THEN pass := pass + 1; RAISE NOTICE 'PASS 9 2026-27 rolls kept (%), next free roll in 7-A = %', v_txt, v_n;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 9 rolls % -> %, next %', v_rolls_before, v_txt, v_n; END IF;

    -- 10. bonafide now: still says Class 7, 2026-27
    c := 'bc';
    CALL core.sp_certificate_manage('Issue', T, S, A, NULL, 725, 'Bonafide', 'Bank account', NULL, NULL, NULL, c); CLOSE c;
    SELECT class_name || '/' || academic_year INTO v_txt FROM core.certificates WHERE student_id = 725 ORDER BY cert_id DESC LIMIT 1;
    IF v_txt = 'Class 7/2026-27' THEN pass := pass + 1; RAISE NOTICE 'PASS 10 bonafide says %', v_txt;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 10 bonafide says %', v_txt; END IF;

    -- 11. fee due list: listed under Class 7 (this session), not Class 8
    c := 'fd';
    CALL core.sp_fee_due_list(T, S, A, NULL, 'Class 7', NULL, 1, 100, NULL, NULL, c);
    v_n := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.student_id = ANY(KIDS) THEN v_n := v_n + 1; END IF; END LOOP; CLOSE c;
    c := 'fd2';
    CALL core.sp_fee_due_list(T, S, A, NULL, 'Class 8', NULL, 1, 100, NULL, NULL, c);
    v_m := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.student_id = ANY(KIDS) THEN v_m := v_m + 1; END IF; END LOOP; CLOSE c;
    IF v_m = 0 THEN pass := pass + 1; RAISE NOTICE 'PASS 11 fee due list: % under Class 7, none under Class 8', v_n;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 11 fee due list Class 7 %, Class 8 %', v_n, v_m; END IF;

    -- 12. promoting them again is refused / skipped (they are not in 2026-27 any more)
    BEGIN
        c := 'p2';
        CALL core.sp_student_promote(T, S, A, '2026-27', '2027-28', NULL, TRUE, v_students, c); FETCH c INTO r; CLOSE c;
        IF COALESCE(r.promoted, 0) = 0 THEN pass := pass + 1; RAISE NOTICE 'PASS 12 second promotion did nothing: %', r.message;
        ELSE fail := fail + 1; RAISE NOTICE 'FAIL 12 promoted twice: %', r.message; END IF;
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 12 second promotion refused: %', left(SQLERRM, 100); END;

    -- 13. 2027-28 cannot be made current while 2026-27 still has students
    BEGIN
        c := 'sc';
        CALL academic.sp_school_admin_academic_year_manage('SetCurrentAcademicYear', T, S, A, 49, NULL, NULL, NULL, NULL, NULL, c);
        FETCH c INTO r; CLOSE c;
        IF r.success::text IN ('false', '0') THEN pass := pass + 1; RAISE NOTICE 'PASS 13 set-current refused: %', left(r.message, 100);
        ELSE fail := fail + 1; RAISE NOTICE 'FAIL 13 2027-28 made current while 2026-27 has students'; END IF;
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 13 set-current refused: %', left(SQLERRM, 100); END;

    -- 14. Year-End: carrying this session's dues forward is refused before its last month
    BEGIN
        c := 'ye';
        CALL core.sp_fee_year_end_manage('CarryAll', T, S, A, '2026-27', NULL, NULL, NULL, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 14 dues carried to 2027-28 in October';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM LIKE '%last month%' THEN pass := pass + 1; RAISE NOTICE 'PASS 14 %', SQLERRM;
        ELSE fail := fail + 1; RAISE NOTICE 'FAIL 14 other refusal: %', SQLERRM; END IF;
    END;

    RAISE NOTICE '== % passed, % failed ==', pass, fail;
END;
$t$;

ROLLBACK;
