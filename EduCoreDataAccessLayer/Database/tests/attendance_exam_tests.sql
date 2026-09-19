-- ============================================================================
-- Attendance + Exam test suite.
--
-- Runs inside ONE transaction and ROLLS BACK — it admits students, marks
-- attendance, creates an exam and enters marks, none of which survives. Safe to
-- point at any database, including one holding real data.
--
--     psql ... -f attendance_exam_tests.sql
--
-- COVERS
--   A. Attendance save — the date guards (future, Sunday, back-date lock)
--   B. Attendance is one row per student per day, and re-saving corrects it
--   C. The per-student view: a day nobody marked is not an absence
--   D. Exam marks — the range check, the finalize lock, reopen
--   E. Per-student results — published only, absent excluded from totals
-- ============================================================================

\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE TEMP TABLE _t(id serial, name text, ok boolean, detail text) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.chk(p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO _t(name, ok, detail) VALUES (p_name, p_ok, p_detail);
    RAISE NOTICE '  [%] %  %', CASE WHEN p_ok THEN 'PASS' ELSE 'FAIL' END, rpad(p_name, 52), p_detail;
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

    v_year   varchar;
    v_class  varchar;
    v_clsid  integer;
    v_yearid integer;

    c   refcursor;
    c2  refcursor;
    v_sid  integer;
    v_sid2 integer;
    v_n    integer;
    v_txt  text;
    v_dec  numeric;
    v_mon  date;          -- a recent Monday, safely inside the back-date window
    v_sun  date;

    v_exam  integer;
    v_draft integer;
    v_sub1  integer;
    v_sub2  integer;

    k_ok boolean; k_msg text; k_n integer;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '========= ATTENDANCE + EXAM TESTS =========';

    SELECT academic_year_id, academic_year_name INTO v_yearid, v_year
    FROM academic.academic_years
    WHERE tenant_id = c_tenant AND school_id = c_school AND COALESCE(is_current, FALSE) LIMIT 1;

    SELECT academic_class_id, class_name INTO v_clsid, v_class
    FROM academic.academic_classes
    WHERE tenant_id = c_tenant AND school_id = c_school
      AND academic_year_id = v_yearid AND COALESCE(is_deleted, FALSE) = FALSE
    ORDER BY display_order LIMIT 1;

    IF v_year IS NULL OR v_class IS NULL THEN
        RAISE EXCEPTION 'Fixture missing: school % has no current session or classes.', c_school;
    END IF;

    -- Yesterday, unless that is a Sunday, in which case the day before. Keeps the
    -- fixture inside whatever back-date window the school has configured.
    v_mon := CURRENT_DATE - 1;
    IF EXTRACT(DOW FROM v_mon) = 0 THEN v_mon := v_mon - 1; END IF;
    v_sun := CURRENT_DATE - EXTRACT(DOW FROM CURRENT_DATE)::int;   -- the most recent Sunday

    RAISE NOTICE 'fixture: session=%  class=%  test date=%  (a Sunday: %)', v_year, v_class, v_mon, v_sun;

    -- Two students in the same class/section to mark.
    c := 's1';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-ATT-1', NULL, 'ZZ Att One', 'Male', DATE '2015-01-01',
         v_class, 'A', v_year, CURRENT_DATE - 30, p_result => c);
    SELECT student_id INTO v_sid FROM core.students WHERE admission_no = 'ZZ-ATT-1';

    c := 's2';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-ATT-2', NULL, 'ZZ Att Two', 'Female', DATE '2015-02-02',
         v_class, 'A', v_year, CURRENT_DATE - 30, p_result => c);
    SELECT student_id INTO v_sid2 FROM core.students WHERE admission_no = 'ZZ-ATT-2';

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- A. Attendance date guards -----------------------------';

    -- A1: the future cannot be marked. Nobody knows who will turn up tomorrow.
    BEGIN
        c := 'a1';
        CALL core.sp_attendance_save(c_tenant, c_school, c_user, CURRENT_DATE + 1,
             jsonb_build_array(jsonb_build_object('studentId', v_sid, 'status', 'Present')), c);
        PERFORM pg_temp.chk('A1 future date refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('A1 future date refused', TRUE, SQLERRM);
    END;

    -- A2: Sundays are not school days — the same rule the register, the leave
    --     module and payroll all use.
    BEGIN
        c := 'a2';
        CALL core.sp_attendance_save(c_tenant, c_school, c_user, v_sun,
             jsonb_build_array(jsonb_build_object('studentId', v_sid, 'status', 'Present')), c);
        PERFORM pg_temp.chk('A2 Sunday refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('A2 Sunday refused', TRUE, SQLERRM);
    END;

    -- A3: far enough back and the register locks, so yesterday's absence cannot
    --     be quietly rewritten months later.
    BEGIN
        c := 'a3';
        CALL core.sp_attendance_save(c_tenant, c_school, c_user, CURRENT_DATE - 400,
             jsonb_build_array(jsonb_build_object('studentId', v_sid, 'status', 'Present')), c);
        PERFORM pg_temp.chk('A3 long-past date is locked', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('A3 long-past date is locked', TRUE, SQLERRM);
    END;

    -- A4: an empty register is refused rather than silently recording nothing.
    BEGIN
        c := 'a4';
        CALL core.sp_attendance_save(c_tenant, c_school, c_user, v_mon, '[]'::jsonb, c);
        PERFORM pg_temp.chk('A4 empty register refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('A4 empty register refused', TRUE, SQLERRM);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- B. Marking and correcting -----------------------------';

    c := 'b1';
    CALL core.sp_attendance_save(c_tenant, c_school, c_user, v_mon,
         jsonb_build_array(
             jsonb_build_object('studentId', v_sid,  'status', 'Present'),
             jsonb_build_object('studentId', v_sid2, 'status', 'Absent')), c);

    SELECT COUNT(*) INTO v_n FROM core.student_attendance
     WHERE attendance_date = v_mon AND student_id IN (v_sid, v_sid2);
    PERFORM pg_temp.chk_eq('B1 both students marked', v_n, 2);

    SELECT status INTO v_txt FROM core.student_attendance
     WHERE attendance_date = v_mon AND student_id = v_sid2;
    PERFORM pg_temp.chk('B2 the absent one is Absent', v_txt = 'Absent', format('got %s', v_txt));

    -- Re-saving the same day must CORRECT, not duplicate — a teacher fixing a
    -- mistake should not leave two rows for one student on one day.
    c := 'b3';
    CALL core.sp_attendance_save(c_tenant, c_school, c_user, v_mon,
         jsonb_build_array(jsonb_build_object('studentId', v_sid2, 'status', 'Present')), c);

    SELECT COUNT(*) INTO v_n FROM core.student_attendance
     WHERE attendance_date = v_mon AND student_id = v_sid2;
    PERFORM pg_temp.chk_eq('B3 correcting does not duplicate the row', v_n, 1);

    SELECT status INTO v_txt FROM core.student_attendance
     WHERE attendance_date = v_mon AND student_id = v_sid2;
    PERFORM pg_temp.chk('B4 the correction stuck', v_txt = 'Present', format('got %s', v_txt));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- C. Per-student view -----------------------------------';

    c := 'c1'; c2 := 'c1b';
    DECLARE c3 refcursor := 'c1c'; sd int; pr int; ab int; lv int; pc numeric;
    BEGIN
        CALL core.sp_attendance_student(c_tenant, c_school, c_user, v_sid,
             v_year, EXTRACT(MONTH FROM v_mon)::int, EXTRACT(YEAR FROM v_mon)::int, c, c2, c3);
        FETCH c INTO sd, pr, ab, lv, pc;

        PERFORM pg_temp.chk_eq('C1 one school day counted (only one was marked)', sd, 1);
        PERFORM pg_temp.chk_eq('C2 present on that day', pr, 1);
        PERFORM pg_temp.chk_eq('C3 100% — unmarked days are not absences', pc, 100.0);
    END;

    -- A student with no register at all must read as "nothing marked", not 0%.
    DECLARE c4 refcursor := 'c4a'; c5 refcursor := 'c4b'; c6 refcursor := 'c4c';
            sd int; pr int; ab int; lv int; pc numeric; v_fresh int;
    BEGIN
        CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
             'ZZ-ATT-3', NULL, 'ZZ Att Three', 'Male', DATE '2015-03-03',
             v_class, 'B', v_year, CURRENT_DATE - 10, p_result => c4);
        SELECT student_id INTO v_fresh FROM core.students WHERE admission_no = 'ZZ-ATT-3';

        c4 := 'c4a2';
        CALL core.sp_attendance_student(c_tenant, c_school, c_user, v_fresh,
             v_year, NULL, NULL, c4, c5, c6);
        FETCH c4 INTO sd, pr, ab, lv, pc;
        PERFORM pg_temp.chk_eq('C4 never-marked student: 0 school days', sd, 0);
        PERFORM pg_temp.chk_eq('C5 never-marked student: 0%, not a false absence', pc, 0);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- D. Exam marks -----------------------------------------';

    INSERT INTO academic.school_subjects(tenant_id, school_id, subject_name, created_by)
    VALUES (c_tenant, c_school, 'ZZ Maths', c_user) RETURNING subject_id INTO v_sub1;
    INSERT INTO academic.school_subjects(tenant_id, school_id, subject_name, created_by)
    VALUES (c_tenant, c_school, 'ZZ Science', c_user) RETURNING subject_id INTO v_sub2;

    INSERT INTO academic.exams(tenant_id, school_id, academic_year_id, exam_name, exam_type,
                               start_date, end_date, status, created_by)
    VALUES (c_tenant, c_school, v_yearid, 'ZZ Half Yearly', 'Term',
            CURRENT_DATE, CURRENT_DATE + 5, 'Published', c_user)
    RETURNING exam_id INTO v_exam;

    INSERT INTO academic.exams(tenant_id, school_id, academic_year_id, exam_name, exam_type,
                               start_date, end_date, status, created_by)
    VALUES (c_tenant, c_school, v_yearid, 'ZZ Unit Test', 'Unit',
            CURRENT_DATE + 20, CURRENT_DATE + 22, 'Draft', c_user)
    RETURNING exam_id INTO v_draft;

    INSERT INTO academic.exam_class_sections(tenant_id, school_id, exam_id, academic_class_id, section)
    VALUES (c_tenant, c_school, v_exam, v_clsid, 'A')
    ON CONFLICT DO NOTHING;

    INSERT INTO academic.exam_subjects(tenant_id, school_id, exam_id, subject_id,
                                       academic_class_id, max_marks, pass_marks, display_order)
    VALUES (c_tenant, c_school, v_exam, v_sub1, v_clsid, 100, 33, 1),
           (c_tenant, c_school, v_exam, v_sub2, v_clsid, 100, 33, 2),
           (c_tenant, c_school, v_draft, v_sub1, v_clsid, 100, 33, 1);

    -- D1: marks above the paper's maximum are refused.
    BEGIN
        c := 'd1'; c2 := 'd1b';
        CALL academic.sp_school_admin_exam_marks_manage('SaveMarks', c_tenant, c_school, c_user,
             v_exam, v_clsid, v_sub1, 'A',
             json_build_array(json_build_object('studentId', v_sid, 'marks', 150, 'absent', false))::text,
             FALSE, c, c2);
        PERFORM pg_temp.chk('D1 marks above max refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('D1 marks above max refused', TRUE, SQLERRM);
    END;

    -- D2: negative marks are refused.
    BEGIN
        c := 'd2'; c2 := 'd2b';
        CALL academic.sp_school_admin_exam_marks_manage('SaveMarks', c_tenant, c_school, c_user,
             v_exam, v_clsid, v_sub1, 'A',
             json_build_array(json_build_object('studentId', v_sid, 'marks', -5, 'absent', false))::text,
             FALSE, c, c2);
        PERFORM pg_temp.chk('D2 negative marks refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('D2 negative marks refused', TRUE, SQLERRM);
    END;

    -- D3: a real save, finalised.
    c := 'd3'; c2 := 'd3b';
    CALL academic.sp_school_admin_exam_marks_manage('SaveMarks', c_tenant, c_school, c_user,
         v_exam, v_clsid, v_sub1, 'A',
         json_build_array(
            json_build_object('studentId', v_sid,  'marks', 78, 'absent', false),
            json_build_object('studentId', v_sid2, 'marks', NULL, 'absent', true))::text,
         TRUE, c, c2);

    SELECT marks_obtained INTO v_dec FROM academic.exam_marks
     WHERE exam_id = v_exam AND subject_id = v_sub1 AND student_id = v_sid;
    PERFORM pg_temp.chk_eq('D3 marks saved', v_dec, 78);

    SELECT is_absent INTO k_ok FROM academic.exam_marks
     WHERE exam_id = v_exam AND subject_id = v_sub1 AND student_id = v_sid2;
    PERFORM pg_temp.chk('D4 absent student flagged absent', COALESCE(k_ok, FALSE), '');

    SELECT marks_obtained INTO v_dec FROM academic.exam_marks
     WHERE exam_id = v_exam AND subject_id = v_sub1 AND student_id = v_sid2;
    PERFORM pg_temp.chk('D5 absent means NO marks, not zero', v_dec IS NULL,
                        format('marks = %s', COALESCE(v_dec::text, 'NULL')));

    -- D6: a finalised sheet is locked.
    BEGIN
        c := 'd6'; c2 := 'd6b';
        CALL academic.sp_school_admin_exam_marks_manage('SaveMarks', c_tenant, c_school, c_user,
             v_exam, v_clsid, v_sub1, 'A',
             json_build_array(json_build_object('studentId', v_sid, 'marks', 90, 'absent', false))::text,
             FALSE, c, c2);
        PERFORM pg_temp.chk('D6 finalised sheet is locked', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('D6 finalised sheet is locked', TRUE, SQLERRM);
    END;

    -- D7: reopen, then it can be edited again.
    c := 'd7'; c2 := 'd7b';
    CALL academic.sp_school_admin_exam_marks_manage('ReopenSheet', c_tenant, c_school, c_user,
         v_exam, v_clsid, v_sub1, 'A', NULL, FALSE, c, c2);

    c := 'd7c'; c2 := 'd7d';
    CALL academic.sp_school_admin_exam_marks_manage('SaveMarks', c_tenant, c_school, c_user,
         v_exam, v_clsid, v_sub1, 'A',
         json_build_array(json_build_object('studentId', v_sid, 'marks', 90, 'absent', false))::text,
         FALSE, c, c2);
    SELECT marks_obtained INTO v_dec FROM academic.exam_marks
     WHERE exam_id = v_exam AND subject_id = v_sub1 AND student_id = v_sid;
    PERFORM pg_temp.chk_eq('D7 reopened sheet accepts an edit', v_dec, 90);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- E. Per-student results -------------------------------';

    -- Second subject so the totals have something to exclude against.
    c := 'e0'; c2 := 'e0b';
    CALL academic.sp_school_admin_exam_marks_manage('SaveMarks', c_tenant, c_school, c_user,
         v_exam, v_clsid, v_sub2, 'A',
         json_build_array(json_build_object('studentId', v_sid, 'marks', 50, 'absent', false))::text,
         FALSE, c, c2);

    -- Marks on the DRAFT exam too — these must not show up anywhere.
    INSERT INTO academic.exam_marks(tenant_id, school_id, exam_id, subject_id, student_id,
                                    academic_class_id, marks_obtained, is_absent, created_by)
    VALUES (c_tenant, c_school, v_draft, v_sub1, v_sid, v_clsid, 95, FALSE, c_user);

    DECLARE ce refcursor := 'e1'; cm refcursor := 'e2'; cs refcursor := 'e3';
            eid int; enm text; ety text; edt date;
            subj text; obt numeric; mx numeric; pm numeric; ab bool; ps bool; pct numeric;
            n_sub int; t_obt numeric; t_tot numeric; t_pct numeric; n_abs int; n_fail int;
            v_drafts int := 0;
    BEGIN
        CALL core.sp_exam_result_student(c_tenant, c_school, c_user, v_sid, NULL, ce, cm, cs);

        LOOP FETCH ce INTO eid, enm, ety, edt; EXIT WHEN NOT FOUND;
            IF eid = v_draft THEN v_drafts := v_drafts + 1; END IF;
        END LOOP;
        PERFORM pg_temp.chk_eq('E1 draft exam does not appear', v_drafts, 0);

        FETCH cs INTO n_sub, t_obt, t_tot, t_pct, n_abs, n_fail;
        PERFORM pg_temp.chk_eq('E2 counted subjects', n_sub, 2);
        PERFORM pg_temp.chk_eq('E3 total obtained (90 + 50)', t_obt, 140);
        PERFORM pg_temp.chk_eq('E4 total out of (100 + 100)', t_tot, 200);
        PERFORM pg_temp.chk_eq('E5 percentage', t_pct, 70.0);
    END;

    -- And for the student who was absent in one subject, the absent paper must be
    -- out of the denominator.
    DECLARE ce refcursor := 'e6'; cm refcursor := 'e7'; cs refcursor := 'e8';
            n_sub int; t_obt numeric; t_tot numeric; t_pct numeric; n_abs int; n_fail int;
    BEGIN
        CALL core.sp_exam_result_student(c_tenant, c_school, c_user, v_sid2, NULL, ce, cm, cs);
        FETCH cs INTO n_sub, t_obt, t_tot, t_pct, n_abs, n_fail;
        PERFORM pg_temp.chk_eq('E6 absent paper counted as absent', n_abs, 1);
        PERFORM pg_temp.chk_eq('E7 absent paper NOT in the total', t_tot, 0);
        PERFORM pg_temp.chk_eq('E8 no false 0% from an absence', t_pct, 0);
    END;
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
            RAISE NOTICE '   %  %', rpad(r.name, 52), r.detail;
        END LOOP;
    END IF;
    RAISE NOTICE '';
END
$sum$;

ROLLBACK;
