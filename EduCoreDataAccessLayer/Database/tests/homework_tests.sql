-- Homework (homework.sql): checks on the QA Test School (tenant 32, school 45;
-- admin login 62; QA Teacher login 63 = staff 92; QA Accountant login 64 is
-- Non-Teaching). Creates the tables/proc inside the transaction and ROLLS BACK.
-- Run from this folder:
--     psql ... -f homework_tests.sql
\set ON_ERROR_STOP 1
BEGIN;
\ir ../homework.sql

DO $t$
DECLARE
    TN int := 32; SC int := 45; ADMIN int := 62; TEACHER int := 63; ACC int := 64;
    SEC int; SUBJ int; v_id int; v_id2 int; v_stu int[]; v_n int; v_txt text;
    c refcursor; r record;
    pass int := 0; fail int := 0;
BEGIN
    -- a class + subject QA Teacher really teaches (timetable), from MyClasses
    CALL academic.sp_homework_manage('MyClasses', TN, SC, TEACHER, FALSE, NULL, NULL, NULL, NULL, NULL, NULL, NULL, FALSE, NULL, NULL, NULL, c);
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
        IF r.subject_id IS NOT NULL AND SEC IS NULL THEN SEC := r.section_id; SUBJ := r.subject_id; END IF;
    END LOOP; CLOSE c;
    RAISE NOTICE 'QA Teacher teaches section % subject %', SEC, SUBJ;

    -- 0. a class the teacher does not teach is refused (QA BUG-098)
    BEGIN
        SELECT os.academic_class_section_id INTO v_n FROM academic.academic_class_sections os
         WHERE os.tenant_id = TN AND os.academic_class_section_id <> SEC
           AND COALESCE(os.class_teacher_staff_id, 0) <> 92
           AND NOT EXISTS (SELECT 1 FROM academic.timetable t WHERE t.academic_class_section_id = os.academic_class_section_id AND t.staff_id = 92)
         LIMIT 1;
        CALL academic.sp_homework_manage('Save', TN, SC, TEACHER, FALSE, NULL, v_n, SUBJ, 'x', NULL, CURRENT_DATE, CURRENT_DATE + 1, FALSE, NULL, NULL, NULL, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 0 homework for a class not taught';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 0 %', SQLERRM; END;

    -- 1. a teacher gives homework
    CALL academic.sp_homework_manage('Save', TN, SC, TEACHER, FALSE, NULL, SEC, SUBJ, 'Read chapter 3', 'Answer Q1-Q5 in the notebook.',
                                     CURRENT_DATE, CURRENT_DATE + 2, FALSE, NULL, NULL, NULL, c);
    FETCH c INTO r; CLOSE c; v_id := r.homework_id;
    IF v_id IS NOT NULL AND (SELECT staff_id FROM academic.homework WHERE homework_id = v_id) = 92
    THEN pass := pass + 1; RAISE NOTICE 'PASS 1 % (id %)', r.message, v_id;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 1'; END IF;

    -- 2. a non-teaching user cannot give homework
    BEGIN
        CALL academic.sp_homework_manage('Save', TN, SC, ACC, FALSE, NULL, SEC, SUBJ, 'x', NULL, CURRENT_DATE, CURRENT_DATE + 1, FALSE, NULL, NULL, NULL, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 2 accountant gave homework';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 2 %', SQLERRM; END;

    -- 3. due date before the day given is refused
    BEGIN
        CALL academic.sp_homework_manage('Save', TN, SC, TEACHER, FALSE, NULL, SEC, SUBJ, 'x', NULL, CURRENT_DATE, CURRENT_DATE - 1, FALSE, NULL, NULL, NULL, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 3 past due accepted';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 3 %', SQLERRM; END;

    -- 4. the list shows it with the class strength and can_edit for the teacher
    CALL academic.sp_homework_manage('List', TN, SC, TEACHER, FALSE, NULL, SEC, NULL, NULL, NULL, NULL, NULL, TRUE, NULL, NULL, NULL, c);
    v_txt := NULL;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.homework_id = v_id THEN v_txt := r.section_label || '/' || r.subject_name || '/' || r.student_count || '/' || r.can_edit; END IF; END LOOP; CLOSE c;
    IF v_txt LIKE '%/true' AND split_part(v_txt, '/', 3)::int > 0 THEN pass := pass + 1; RAISE NOTICE 'PASS 4 list: %', v_txt;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 4 list: %', v_txt; END IF;

    -- 5. Students lists the section; Check saves Done / NotDone, a blank clears
    CALL academic.sp_homework_manage('Students', TN, SC, TEACHER, FALSE, v_id, NULL, NULL, NULL, NULL, NULL, NULL, FALSE, NULL, NULL, NULL, c);
    v_stu := ARRAY[]::int[];
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_stu := v_stu || r.student_id; END LOOP; CLOSE c;
    CALL academic.sp_homework_manage('Check', TN, SC, TEACHER, FALSE, v_id, NULL, NULL, NULL, NULL, NULL, NULL, FALSE,
                                     v_stu[1:2], ARRAY['Done', 'NotDone'], NULL, c);
    FETCH c INTO r; CLOSE c;
    CALL academic.sp_homework_manage('Check', TN, SC, TEACHER, FALSE, v_id, NULL, NULL, NULL, NULL, NULL, NULL, FALSE,
                                     v_stu[2:2], ARRAY[''], NULL, c); CLOSE c;
    SELECT string_agg(status, ',' ORDER BY status) INTO v_txt FROM academic.homework_status WHERE homework_id = v_id;
    IF array_length(v_stu, 1) >= 2 AND v_txt = 'Done' THEN pass := pass + 1; RAISE NOTICE 'PASS 5 % students, marks now: %', array_length(v_stu, 1), v_txt;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 5 % / %', array_length(v_stu, 1), v_txt; END IF;

    -- 6. the student's own view shows the homework and their status
    CALL academic.sp_homework_manage('Student', TN, SC, ADMIN, TRUE, NULL, NULL, NULL, NULL, NULL, NULL, NULL, FALSE, NULL, NULL, v_stu[1], c);
    v_txt := NULL;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.homework_id = v_id THEN v_txt := r.title || '/' || r.status; END IF; END LOOP; CLOSE c;
    IF v_txt = 'Read chapter 3/Done' THEN pass := pass + 1; RAISE NOTICE 'PASS 6 student view: %', v_txt;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 6 %', v_txt; END IF;

    -- 7. the admin (no staff record) can give homework and edit the teacher's
    CALL academic.sp_homework_manage('Save', TN, SC, ADMIN, TRUE, NULL, SEC, SUBJ, 'Admin homework', NULL, CURRENT_DATE, CURRENT_DATE, FALSE, NULL, NULL, NULL, c);
    FETCH c INTO r; CLOSE c; v_id2 := r.homework_id;
    CALL academic.sp_homework_manage('Save', TN, SC, ADMIN, TRUE, v_id, SEC, SUBJ, 'Read chapter 3 and 4', NULL, CURRENT_DATE, CURRENT_DATE + 3, FALSE, NULL, NULL, NULL, c); CLOSE c;
    IF v_id2 IS NOT NULL AND (SELECT title FROM academic.homework WHERE homework_id = v_id) = 'Read chapter 3 and 4'
    THEN pass := pass + 1; RAISE NOTICE 'PASS 7 admin gave and edited homework';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 7'; END IF;

    -- 8. the teacher cannot edit / delete the admin's homework
    BEGIN
        CALL academic.sp_homework_manage('Delete', TN, SC, TEACHER, FALSE, v_id2, NULL, NULL, NULL, NULL, NULL, NULL, FALSE, NULL, NULL, NULL, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 8 teacher deleted someone else''s homework';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 8 %', SQLERRM; END;

    -- 9. the teacher deletes their own; it leaves the list
    CALL academic.sp_homework_manage('Delete', TN, SC, TEACHER, FALSE, v_id, NULL, NULL, NULL, NULL, NULL, NULL, FALSE, NULL, NULL, NULL, c); CLOSE c;
    CALL academic.sp_homework_manage('List', TN, SC, ADMIN, TRUE, NULL, NULL, NULL, NULL, NULL, NULL, NULL, FALSE, NULL, NULL, NULL, c);
    v_n := 0; LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.homework_id = v_id THEN v_n := v_n + 1; END IF; END LOOP; CLOSE c;
    IF v_n = 0 THEN pass := pass + 1; RAISE NOTICE 'PASS 9 deleted';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 9'; END IF;

    -- 10. another school cannot open it
    BEGIN
        CALL academic.sp_homework_manage('Students', 30, 1, ADMIN, TRUE, v_id2, NULL, NULL, NULL, NULL, NULL, NULL, FALSE, NULL, NULL, NULL, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 10 cross-school open';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 10 %', SQLERRM; END;

    RAISE NOTICE '== % passed, % failed ==', pass, fail;
END;
$t$;

ROLLBACK;
