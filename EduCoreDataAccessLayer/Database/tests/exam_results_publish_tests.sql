-- ============================================================================
-- Exam results test suite: grade scale, publishing results, lock, grades, rank.
--
-- Scenario: Sunrise Public School runs a Term Test for class 8 (sections A and
-- B): Maths out of 100, Science out of 50. Teachers type marks as drafts, one
-- student is absent in Science, one never gets a mark at all. The office tries to
-- publish too early, finalises the last sheet, publishes, and parents see grades
-- and class ranks (two students tie for first). Then a correction is needed: the
-- results are unpublished with a reason, a sheet reopened and a mark fixed.
--
-- Runs inside ONE transaction and ROLLS BACK.
--
--     psql ... -f exam_results_publish_tests.sql
--
-- COVERS
--   A. Grade scale - default, mapping, validation, custom scale, reset
--   B. Publish rules - draft datesheet, sheets not finalised, success, log
--   C. Lock - marks, reopen, exam edit and back-to-draft refused once published
--   D. Results - visibility, grade per subject / overall, rank with ties, sheet
--   E. Unpublish - reason required, log, hidden again, marks editable again
--   F. Scope - another school and the platform tenant
-- ============================================================================

\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE TEMP TABLE _t(id serial, name text, ok boolean, detail text) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.chk(p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO _t(name, ok, detail) VALUES (p_name, COALESCE(p_ok, FALSE), p_detail);
    RAISE NOTICE '  [%] %  %', CASE WHEN COALESCE(p_ok, FALSE) THEN 'PASS' ELSE 'FAIL' END, rpad(p_name, 60), p_detail;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.chk_eq(p_name text, p_got numeric, p_want numeric)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.chk(p_name, p_got IS NOT DISTINCT FROM p_want,
                        format('got %s, expected %s', COALESCE(p_got::text,'NULL'), COALESCE(p_want::text,'NULL')));
END $$;

CREATE OR REPLACE FUNCTION pg_temp.chk_txt(p_name text, p_got text, p_want text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.chk(p_name, p_got IS NOT DISTINCT FROM p_want,
                        format('got [%s], expected [%s]', COALESCE(p_got,'NULL'), COALESCE(p_want,'NULL')));
END $$;

-- A fresh cursor name per call, so helpers never collide on an open portal.
CREATE OR REPLACE FUNCTION pg_temp.cur() RETURNS refcursor LANGUAGE sql AS
$$ SELECT ('r' || replace(gen_random_uuid()::text, '-', ''))::refcursor $$;

-- ── Grade scale wrappers (same layout as ExamResultService) ──
CREATE OR REPLACE FUNCTION pg_temp.gs_save(p_t int, p_s int, p_items jsonb)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c refcursor := pg_temp.cur(); r record;
BEGIN
    CALL academic.sp_school_admin_grade_scale_manage('SaveScale', p_t, p_s, 39, p_items::text, c);
    FETCH c INTO r; CLOSE c;
    RETURN r.message;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.gs_reset(p_t int, p_s int)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c refcursor := pg_temp.cur(); r record;
BEGIN
    CALL academic.sp_school_admin_grade_scale_manage('ResetDefault', p_t, p_s, 39, NULL, c);
    FETCH c INTO r; CLOSE c;
    RETURN r.message;
END $$;

-- Rows of GetScale, the top band's label and whether it is the default scale.
CREATE OR REPLACE FUNCTION pg_temp.gs_get(p_t int, p_s int, OUT n int, OUT top text, OUT is_default boolean)
LANGUAGE plpgsql AS $$
DECLARE c refcursor := pg_temp.cur(); r record;
BEGIN
    CALL academic.sp_school_admin_grade_scale_manage('GetScale', p_t, p_s, 39, NULL, c);
    n := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
        n := n + 1;
        IF n = 1 THEN top := r.grade_label || ' ' || r.min_percent::numeric::text || '-' || r.max_percent::numeric::text; END IF;
        is_default := r.is_default;
    END LOOP;
    CLOSE c;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.band(p_label text, p_min numeric, p_max numeric)
RETURNS jsonb LANGUAGE sql AS
$$ SELECT jsonb_build_object('label', p_label, 'minPercent', p_min, 'maxPercent', p_max) $$;

-- ── Results wrappers ──
CREATE OR REPLACE FUNCTION pg_temp.rs(p_op text, p_t int, p_s int, p_exam int, p_reason text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := pg_temp.cur(); c2 refcursor := pg_temp.cur();
        c3 refcursor := pg_temp.cur(); c4 refcursor := pg_temp.cur(); r record;
BEGIN
    CALL academic.sp_school_admin_exam_results_manage(p_op, p_t, p_s, 39, p_exam, NULL, NULL, p_reason, c1, c2, c3, c4);
    FETCH c1 INTO r; CLOSE c1; CLOSE c2; CLOSE c3; CLOSE c4;
    RETURN r.message;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.rs_status(p_t int, p_s int, p_exam int,
    OUT results text, OUT sheets int, OUT pending int, OUT first_pending text, OUT log_rows int)
LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := pg_temp.cur(); c2 refcursor := pg_temp.cur();
        c3 refcursor := pg_temp.cur(); c4 refcursor := pg_temp.cur(); r record;
BEGIN
    CALL academic.sp_school_admin_exam_results_manage('GetStatus', p_t, p_s, 39, p_exam, NULL, NULL, NULL, c1, c2, c3, c4);
    FETCH c1 INTO r;
    results := r.results_status; sheets := r.sheet_count; pending := r.pending_count;
    FETCH c2 INTO r;
    IF FOUND THEN first_pending := r.class_name || '-' || r.section || ' ' || r.subject_name; END IF;
    log_rows := 0;
    LOOP FETCH c3 INTO r; EXIT WHEN NOT FOUND; log_rows := log_rows + 1; END LOOP;
    CLOSE c1; CLOSE c2; CLOSE c3; CLOSE c4;
END $$;

-- The class result sheet: student rows, cell rows, and one student's row.
CREATE OR REPLACE FUNCTION pg_temp.sheet(p_t int, p_s int, p_exam int, p_cls int, p_sec text, p_sid int,
    OUT students int, OUT cells int, OUT subjects int, OUT results text,
    OUT pct numeric, OUT grade text, OUT class_rank int, OUT section_rank int)
LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := pg_temp.cur(); c2 refcursor := pg_temp.cur();
        c3 refcursor := pg_temp.cur(); c4 refcursor := pg_temp.cur(); r record;
BEGIN
    CALL academic.sp_school_admin_exam_results_manage('GetClassResult', p_t, p_s, 39, p_exam, p_cls, p_sec, NULL,
         c1, c2, c3, c4);
    FETCH c1 INTO r; results := r.results_status;
    subjects := 0; LOOP FETCH c2 INTO r; EXIT WHEN NOT FOUND; subjects := subjects + 1; END LOOP;
    students := 0;
    LOOP FETCH c3 INTO r; EXIT WHEN NOT FOUND;
        students := students + 1;
        IF r.student_id = p_sid THEN
            pct := r.percent; grade := r.grade; class_rank := r.class_rank; section_rank := r.section_rank;
        END IF;
    END LOOP;
    cells := 0; LOOP FETCH c4 INTO r; EXIT WHEN NOT FOUND; cells := cells + 1; END LOOP;
    CLOSE c1; CLOSE c2; CLOSE c3; CLOSE c4;
END $$;

-- What a parent sees on the Student Dashboard (core.sp_exam_result_student).
CREATE OR REPLACE FUNCTION pg_temp.res(p_t int, p_s int, p_sid int, p_exam int,
    OUT exam_rows int, OUT pct numeric, OUT total numeric, OUT grade text,
    OUT class_rank int, OUT class_size int, OUT section_rank int, OUT section_size int)
LANGUAGE plpgsql AS $$
DECLARE ce refcursor := pg_temp.cur(); cm refcursor := pg_temp.cur(); cs refcursor := pg_temp.cur(); r record;
BEGIN
    CALL core.sp_exam_result_student(p_t, p_s, 39, p_sid, p_exam, ce, cm, cs);
    exam_rows := 0;
    LOOP FETCH ce INTO r; EXIT WHEN NOT FOUND; exam_rows := exam_rows + 1; END LOOP;
    FETCH cs INTO r;
    pct := r.percent; total := r.total;
    IF exam_rows > 0 THEN
        grade := r.grade; class_rank := r.class_rank; class_size := r.class_size;
        section_rank := r.section_rank; section_size := r.section_size;
    END IF;
    CLOSE ce; CLOSE cm; CLOSE cs;
END $$;

-- One subject's grade on the Student Dashboard.
CREATE OR REPLACE FUNCTION pg_temp.res_subject_grade(p_t int, p_s int, p_sid int, p_exam int, p_subject text)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE ce refcursor := pg_temp.cur(); cm refcursor := pg_temp.cur(); cs refcursor := pg_temp.cur();
        r record; v text;
BEGIN
    CALL core.sp_exam_result_student(p_t, p_s, 39, p_sid, p_exam, ce, cm, cs);
    LOOP FETCH cm INTO r; EXIT WHEN NOT FOUND; IF r.subject = p_subject THEN v := r.grade; END IF; END LOOP;
    CLOSE ce; CLOSE cm; CLOSE cs;
    RETURN v;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.marks_save(p_t int, p_s int, p_exam int, p_cls int, p_sub int,
                                              p_sec text, p_items jsonb, p_fin boolean DEFAULT FALSE)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := pg_temp.cur(); c2 refcursor := pg_temp.cur(); r record;
BEGIN
    CALL academic.sp_school_admin_exam_marks_manage('SaveMarks', p_t, p_s, 39, p_exam, p_cls, p_sub, p_sec,
         p_items::text, p_fin, c1, c2);
    FETCH c1 INTO r; CLOSE c1; CLOSE c2;
    RETURN r.saved;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.mk(p_sid int, p_marks text, p_absent boolean DEFAULT FALSE)
RETURNS jsonb LANGUAGE sql AS
$$ SELECT jsonb_build_object('studentId', p_sid, 'marks', p_marks, 'absent', p_absent) $$;

CREATE OR REPLACE FUNCTION pg_temp.reopen(p_t int, p_s int, p_exam int, p_cls int, p_sub int, p_sec text)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := pg_temp.cur(); c2 refcursor := pg_temp.cur(); r record;
BEGIN
    CALL academic.sp_school_admin_exam_marks_manage('ReopenSheet', p_t, p_s, 39, p_exam, p_cls, p_sub, p_sec,
         NULL, FALSE, c1, c2);
    FETCH c1 INTO r; CLOSE c1; CLOSE c2;
    RETURN r.message;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.sheet_locked(p_t int, p_s int, p_exam int, p_cls int, p_sub int, p_sec text)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := pg_temp.cur(); c2 refcursor := pg_temp.cur(); r record;
BEGIN
    CALL academic.sp_school_admin_exam_marks_manage('GetSheet', p_t, p_s, 39, p_exam, p_cls, p_sub, p_sec,
         NULL, FALSE, c1, c2);
    FETCH c2 INTO r; CLOSE c1; CLOSE c2;
    RETURN r.results_published;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.exam_op(p_t int, p_s int, p_op text, p_exam int, p_status text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := pg_temp.cur(); c2 refcursor := pg_temp.cur(); r record;
BEGIN
    CALL academic.sp_school_admin_exam_manage(p_op, p_t, p_s, 39, NULL, NULL, p_exam, NULL, NULL,
         NULL, NULL, p_status, NULL, c1, c2);
    FETCH c1 INTO r; CLOSE c1; CLOSE c2;
    RETURN r.message;
END $$;


DO $suite$
DECLARE
    c_tenant CONSTANT integer := 24;
    c_school CONSTANT integer := 34;
    c_user   CONSTANT integer := 39;
    o_tenant CONSTANT integer := 23;
    o_school CONSTANT integer := 33;

    v_year     integer;
    v_yearname varchar;
    v_cls8     integer;
    sub_m      integer;
    sub_sc     integer;
    ex         integer;
    r1 integer; r2 integer; r3 integer; r4 integer; r5 integer; r6 integer;

    c     refcursor;
    r     record;
    v_n   integer;
    v_txt text;
    v_dec numeric;
    v_b   boolean;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '===== EXAM RESULTS: GRADE SCALE / PUBLISH / LOCK / GRADES / RANK =====';

    -- ── Fixture ────────────────────────────────────────────────────────────
    SELECT academic_year_id, academic_year_name INTO v_year, v_yearname
    FROM academic.academic_years
    WHERE tenant_id = c_tenant AND school_id = c_school AND COALESCE(is_current, FALSE)
      AND NOT is_deleted LIMIT 1;
    SELECT academic_class_id INTO v_cls8 FROM academic.academic_classes
     WHERE tenant_id = c_tenant AND school_id = c_school AND academic_year_id = v_year
       AND class_name = '8' AND NOT is_deleted;

    IF v_year IS NULL OR v_cls8 IS NULL THEN
        RAISE EXCEPTION 'Fixture missing for school % (year=% class 8=%)', c_school, v_year, v_cls8;
    END IF;

    -- Class 8 gets the sections the scenario needs.
    INSERT INTO academic.academic_class_sections
        (tenant_id, school_id, academic_year_id, academic_class_id, section_name, display_order, created_by)
    SELECT c_tenant, c_school, v_year, v_cls8, x.sec, x.ord, c_user
    FROM (VALUES ('A', 1), ('B', 2)) x(sec, ord)
    WHERE NOT EXISTS (SELECT 1 FROM academic.academic_class_sections s
                      WHERE s.academic_class_id = v_cls8 AND lower(s.section_name) = lower(x.sec)
                        AND NOT s.is_deleted);

    INSERT INTO academic.school_subjects(tenant_id, school_id, subject_name, created_by)
    VALUES (c_tenant, c_school, 'ZZ R Maths', c_user) RETURNING subject_id INTO sub_m;
    INSERT INTO academic.school_subjects(tenant_id, school_id, subject_name, created_by)
    VALUES (c_tenant, c_school, 'ZZ R Science', c_user) RETURNING subject_id INTO sub_sc;
    INSERT INTO academic.class_subjects(tenant_id, school_id, academic_year_id, academic_class_id, subject_id, display_order, created_by)
    VALUES (c_tenant, c_school, v_year, v_cls8, sub_m, 1, c_user),
           (c_tenant, c_school, v_year, v_cls8, sub_sc, 2, c_user);

    -- Students: four in 8-A, two in 8-B.
    c := pg_temp.cur(); CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL, 'ZZ-RS-1', NULL,
         'ZZ RS Aditi', 'Female', DATE '2012-01-01', '8', 'A', v_yearname, CURRENT_DATE - 30, p_result => c);
    c := pg_temp.cur(); CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL, 'ZZ-RS-2', NULL,
         'ZZ RS Bharat', 'Male', DATE '2012-02-01', '8', 'A', v_yearname, CURRENT_DATE - 30, p_result => c);
    c := pg_temp.cur(); CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL, 'ZZ-RS-3', NULL,
         'ZZ RS Chetan', 'Male', DATE '2012-03-01', '8', 'A', v_yearname, CURRENT_DATE - 30, p_result => c);
    c := pg_temp.cur(); CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL, 'ZZ-RS-4', NULL,
         'ZZ RS Divya', 'Female', DATE '2012-04-01', '8', 'A', v_yearname, CURRENT_DATE - 30, p_result => c);
    c := pg_temp.cur(); CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL, 'ZZ-RS-5', NULL,
         'ZZ RS Esha', 'Female', DATE '2012-05-01', '8', 'B', v_yearname, CURRENT_DATE - 30, p_result => c);
    c := pg_temp.cur(); CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL, 'ZZ-RS-6', NULL,
         'ZZ RS Farhan', 'Male', DATE '2012-06-01', '8', 'B', v_yearname, CURRENT_DATE - 30, p_result => c);
    SELECT student_id INTO r1 FROM core.students WHERE school_id = c_school AND admission_no = 'ZZ-RS-1';
    SELECT student_id INTO r2 FROM core.students WHERE school_id = c_school AND admission_no = 'ZZ-RS-2';
    SELECT student_id INTO r3 FROM core.students WHERE school_id = c_school AND admission_no = 'ZZ-RS-3';
    SELECT student_id INTO r4 FROM core.students WHERE school_id = c_school AND admission_no = 'ZZ-RS-4';
    SELECT student_id INTO r5 FROM core.students WHERE school_id = c_school AND admission_no = 'ZZ-RS-5';
    SELECT student_id INTO r6 FROM core.students WHERE school_id = c_school AND admission_no = 'ZZ-RS-6';
    IF r1 IS NULL OR r6 IS NULL THEN
        RAISE EXCEPTION 'Fixture students were not admitted (r1=% r6=%)', r1, r6;
    END IF;

    -- The exam, stored the way SaveExam stores it: whole class 8, still a draft.
    INSERT INTO academic.exams(tenant_id, school_id, academic_year_id, exam_name, exam_type, start_date, end_date, status, created_by)
    VALUES (c_tenant, c_school, v_year, 'ZZ Results Term Test', 'Term',
            (CURRENT_DATE + 20)::text, (CURRENT_DATE + 25)::text, 'Draft', c_user)
    RETURNING exam_id INTO ex;
    INSERT INTO academic.exam_subjects(tenant_id, school_id, exam_id, academic_class_id, subject_id,
                                       exam_date, start_time, end_time, max_marks, pass_marks, display_order)
    VALUES (c_tenant, c_school, ex, v_cls8, sub_m,  (CURRENT_DATE + 20)::text, '09:00', '12:00', 100, 33, 1),
           (c_tenant, c_school, ex, v_cls8, sub_sc, (CURRENT_DATE + 21)::text, '09:00', '11:00',  50, 17, 2);

    RAISE NOTICE 'fixture: session=%  class 8=%  exam=%  students=%..%', v_yearname, v_cls8, ex, r1, r6;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- A. Grade scale ----------------------------------------------';

    PERFORM pg_temp.gs_reset(c_tenant, c_school);         -- start from the default
    SELECT * INTO r FROM pg_temp.gs_get(c_tenant, c_school);
    PERFORM pg_temp.chk('A1 no saved scale = the CBSE default (8 bands, A1 91-100)',
        r.n = 8 AND r.top = 'A1 91-100' AND r.is_default, format('n=%s top=%s default=%s', r.n, r.top, r.is_default));

    PERFORM pg_temp.chk_txt('A2 91% is A1',             academic.fn_grade_for_percent(c_tenant, c_school, 91),    'A1');
    PERFORM pg_temp.chk_txt('A3 90.5% is A2 (between bands = lower band)',
                                                        academic.fn_grade_for_percent(c_tenant, c_school, 90.5),  'A2');
    PERFORM pg_temp.chk_txt('A4 33% is D (the pass line)', academic.fn_grade_for_percent(c_tenant, c_school, 33), 'D');
    PERFORM pg_temp.chk_txt('A5 32.99% is E',           academic.fn_grade_for_percent(c_tenant, c_school, 32.99), 'E');
    PERFORM pg_temp.chk_txt('A6 100% is A1',            academic.fn_grade_for_percent(c_tenant, c_school, 100),   'A1');
    PERFORM pg_temp.chk_txt('A7 0% is E',               academic.fn_grade_for_percent(c_tenant, c_school, 0),     'E');
    PERFORM pg_temp.chk_txt('A8 no percentage = no grade', academic.fn_grade_for_percent(c_tenant, c_school, NULL), NULL);

    -- Validation: every refusal names the problem.
    BEGIN PERFORM pg_temp.gs_save(c_tenant, c_school, '[]');
          PERFORM pg_temp.chk('A9 an empty scale refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('A9 an empty scale refused', SQLERRM LIKE '%at least one%', SQLERRM); END;

    BEGIN PERFORM pg_temp.gs_save(c_tenant, c_school, jsonb_build_array(
              pg_temp.band('A', 50, 100), pg_temp.band('  ', 0, 49)));
          PERFORM pg_temp.chk('A10 a blank grade label refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('A10 a blank grade label refused', SQLERRM LIKE '%grade label%', SQLERRM); END;

    BEGIN PERFORM pg_temp.gs_save(c_tenant, c_school, jsonb_build_array(
              pg_temp.band('A', 50, 100), pg_temp.band('a', 0, 49)));
          PERFORM pg_temp.chk('A11 duplicate labels (any case) refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('A11 duplicate labels (any case) refused', SQLERRM LIKE '%more than once%', SQLERRM); END;

    BEGIN PERFORM pg_temp.gs_save(c_tenant, c_school, jsonb_build_array(
              pg_temp.band('A', 50, 100), pg_temp.band('B', 0, 55)));
          PERFORM pg_temp.chk('A12 overlapping bands refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('A12 overlapping bands refused', SQLERRM LIKE '%overlap%', SQLERRM); END;

    BEGIN PERFORM pg_temp.gs_save(c_tenant, c_school, jsonb_build_array(
              pg_temp.band('A', 60, 100), pg_temp.band('B', 0, 49)));
          PERFORM pg_temp.chk('A13 a gap between bands refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('A13 a gap between bands refused', SQLERRM LIKE '%gap%', SQLERRM); END;

    BEGIN PERFORM pg_temp.gs_save(c_tenant, c_school, jsonb_build_array(
              pg_temp.band('A', 50, 100), pg_temp.band('B', 10, 49)));
          PERFORM pg_temp.chk('A14 a scale that does not start at 0 refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('A14 a scale that does not start at 0 refused', SQLERRM LIKE '%start at 0%', SQLERRM); END;

    BEGIN PERFORM pg_temp.gs_save(c_tenant, c_school, jsonb_build_array(
              pg_temp.band('A', 50, 95), pg_temp.band('B', 0, 49)));
          PERFORM pg_temp.chk('A15 a scale that does not reach 100 refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('A15 a scale that does not reach 100 refused', SQLERRM LIKE '%end at 100%', SQLERRM); END;

    BEGIN PERFORM pg_temp.gs_save(c_tenant, c_school, jsonb_build_array(
              pg_temp.band('A', 100, 50), pg_temp.band('B', 0, 49)));
          PERFORM pg_temp.chk('A16 min above max refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('A16 min above max refused', SQLERRM LIKE '%cannot be more than%', SQLERRM); END;

    BEGIN PERFORM pg_temp.gs_save(c_tenant, c_school, jsonb_build_array(
              pg_temp.band('A', 50, 120), pg_temp.band('B', 0, 49)));
          PERFORM pg_temp.chk('A17 a percentage above 100 refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('A17 a percentage above 100 refused', SQLERRM LIKE '%between 0 and 100%', SQLERRM); END;

    BEGIN PERFORM pg_temp.gs_save(c_tenant, c_school,
              '[{"label":"A","minPercent":"fifty","maxPercent":100},{"label":"B","minPercent":0,"maxPercent":49}]');
          PERFORM pg_temp.chk('A18 a non-numeric percentage refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('A18 a non-numeric percentage refused', SQLERRM LIKE '%must be numbers%', SQLERRM); END;

    -- A school's own five-band scale.
    v_txt := pg_temp.gs_save(c_tenant, c_school, jsonb_build_array(
        jsonb_build_object('label', 'A', 'minPercent', 80, 'maxPercent', 100, 'gradePoint', 4, 'remark', 'Excellent'),
        pg_temp.band('B', 60, 79), pg_temp.band('C', 40, 59), pg_temp.band('D', 33, 39), pg_temp.band('F', 0, 32)));
    PERFORM pg_temp.chk_txt('A19 a valid custom scale is saved', v_txt, 'Grade scale saved.');
    SELECT * INTO r FROM pg_temp.gs_get(c_tenant, c_school);
    PERFORM pg_temp.chk('A20 GetScale returns the 5 saved bands, not the default',
        r.n = 5 AND r.top = 'A 80.00-100.00' AND NOT r.is_default, format('n=%s top=%s default=%s', r.n, r.top, r.is_default));
    PERFORM pg_temp.chk_txt('A21 grades now follow the school''s scale (85% = A)',
        academic.fn_grade_for_percent(c_tenant, c_school, 85), 'A');
    PERFORM pg_temp.chk_txt('A21b 79.5% = B (between 79 and 80 takes the lower band)',
        academic.fn_grade_for_percent(c_tenant, c_school, 79.5), 'B');
    PERFORM pg_temp.chk_txt('A22 another school still uses the default (85% = A2)',
        academic.fn_grade_for_percent(o_tenant, o_school, 85), 'A2');

    -- A refused save leaves the saved scale exactly as it was.
    BEGIN PERFORM pg_temp.gs_save(c_tenant, c_school, jsonb_build_array(pg_temp.band('X', 0, 90)));
    EXCEPTION WHEN OTHERS THEN NULL; END;
    SELECT COUNT(*) INTO v_n FROM academic.grade_scale WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk_eq('A23 a refused save keeps the previous scale', v_n, 5);

    BEGIN PERFORM pg_temp.gs_save(1, 0, jsonb_build_array(pg_temp.band('A', 0, 100)));
          PERFORM pg_temp.chk('A24 platform scope grade scale write refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('A24 platform scope grade scale write refused', TRUE, SQLERRM); END;

    PERFORM pg_temp.gs_reset(c_tenant, c_school);
    SELECT * INTO r FROM pg_temp.gs_get(c_tenant, c_school);
    PERFORM pg_temp.chk('A25 Reset puts the CBSE default back', r.n = 8 AND r.is_default,
        format('n=%s default=%s', r.n, r.is_default));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- B. Publish rules --------------------------------------------';

    BEGIN PERFORM pg_temp.rs('PublishResults', c_tenant, c_school, ex);
          PERFORM pg_temp.chk('B1 results of a draft datesheet cannot be published', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('B1 results of a draft datesheet cannot be published',
                                   SQLERRM LIKE '%still a draft%', SQLERRM); END;

    PERFORM pg_temp.exam_op(c_tenant, c_school, 'SetStatus', ex, 'Published');

    SELECT * INTO r FROM pg_temp.rs_status(c_tenant, c_school, ex);
    PERFORM pg_temp.chk('B2 a new exam''s results start Unpublished; 4 sheets (2 papers x 2 sections) pending',
        r.results = 'Unpublished' AND r.sheets = 4 AND r.pending = 4,
        format('results=%s sheets=%s pending=%s', r.results, r.sheets, r.pending));

    BEGIN PERFORM pg_temp.rs('PublishResults', c_tenant, c_school, ex);
          PERFORM pg_temp.chk('B3 publish refused while no sheet is finalised', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('B3 publish refused while no sheet is finalised',
                                   SQLERRM LIKE '%4 mark sheet(s) are not finalised%', SQLERRM); END;

    -- Drafts. r4 has nothing typed anywhere; r3 is absent in Science.
    v_n := pg_temp.marks_save(c_tenant, c_school, ex, v_cls8, sub_m, 'A', jsonb_build_array(
               pg_temp.mk(r1, '90'), pg_temp.mk(r2, '80'), pg_temp.mk(r3, '45'), pg_temp.mk(r4, '')));
    PERFORM pg_temp.chk_eq('B4 marks can be entered while results are unpublished', v_n, 4);
    v_n := pg_temp.marks_save(c_tenant, c_school, ex, v_cls8, sub_sc, 'A', jsonb_build_array(
               pg_temp.mk(r1, '40'), pg_temp.mk(r2, '45'), pg_temp.mk(r3, NULL, TRUE)));
    v_n := pg_temp.marks_save(c_tenant, c_school, ex, v_cls8, sub_m, 'B', jsonb_build_array(
               pg_temp.mk(r5, '90'), pg_temp.mk(r6, '30')));
    v_n := pg_temp.marks_save(c_tenant, c_school, ex, v_cls8, sub_sc, 'B', jsonb_build_array(
               pg_temp.mk(r5, '40'), pg_temp.mk(r6, '10')));

    SELECT * INTO r FROM pg_temp.res(c_tenant, c_school, r1, ex);
    PERFORM pg_temp.chk_eq('B5 draft marks are NOT visible to parents before publishing', r.exam_rows, 0);
    SELECT * INTO r FROM pg_temp.res(c_tenant, c_school, r1, NULL);
    PERFORM pg_temp.chk_eq('B5b ...nor as their "latest exam"', r.exam_rows, 0);

    -- Finalise three of the four sheets.
    v_n := pg_temp.marks_save(c_tenant, c_school, ex, v_cls8, sub_m,  'A', '[]', TRUE);
    v_n := pg_temp.marks_save(c_tenant, c_school, ex, v_cls8, sub_m,  'B', '[]', TRUE);
    v_n := pg_temp.marks_save(c_tenant, c_school, ex, v_cls8, sub_sc, 'B', '[]', TRUE);

    SELECT * INTO r FROM pg_temp.rs_status(c_tenant, c_school, ex);
    PERFORM pg_temp.chk('B6 GetStatus lists the one sheet still to finalise',
        r.pending = 1 AND r.first_pending = '8-A ZZ R Science',
        format('pending=%s first=%s', r.pending, r.first_pending));
    BEGIN PERFORM pg_temp.rs('PublishResults', c_tenant, c_school, ex);
          PERFORM pg_temp.chk('B7 publish refused while one sheet is still a draft', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('B7 publish refused while one sheet is still a draft',
                                   SQLERRM LIKE '%1 mark sheet(s)%8-A ZZ R Science%', SQLERRM); END;

    v_n := pg_temp.marks_save(c_tenant, c_school, ex, v_cls8, sub_sc, 'A', '[]', TRUE);
    SELECT is_absent INTO v_b FROM academic.exam_marks WHERE exam_id = ex AND subject_id = sub_m AND student_id = r4;
    PERFORM pg_temp.chk('B8 finalise recorded the blank student as Absent (today''s rule)', v_b, format('is_absent=%s', v_b));

    BEGIN PERFORM pg_temp.rs('PublishResults', o_tenant, o_school, ex);
          PERFORM pg_temp.chk('B9 another school cannot publish our results', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('B9 another school cannot publish our results',
                                   SQLERRM LIKE '%not found%', SQLERRM); END;

    v_txt := pg_temp.rs('PublishResults', c_tenant, c_school, ex);
    PERFORM pg_temp.chk('B10 publish succeeds once every sheet is finalised', v_txt LIKE 'Results published%', v_txt);
    SELECT results_status || '/' || results_published_by INTO v_txt FROM academic.exams WHERE exam_id = ex;
    PERFORM pg_temp.chk_txt('B11 results_status Published, by the acting user', v_txt, 'Published/' || c_user);
    SELECT COUNT(*) INTO v_n FROM academic.exam_result_log
     WHERE exam_id = ex AND action = 'Publish' AND done_by = c_user AND done_at IS NOT NULL;
    PERFORM pg_temp.chk_eq('B12 the publish is logged (who, when)', v_n, 1);

    BEGIN PERFORM pg_temp.rs('PublishResults', c_tenant, c_school, ex);
          PERFORM pg_temp.chk('B13 publishing twice refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('B13 publishing twice refused', SQLERRM LIKE '%already published%', SQLERRM); END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- C. Lock -----------------------------------------------------';

    PERFORM pg_temp.chk('C1 GetSheet tells the page the results are published',
        pg_temp.sheet_locked(c_tenant, c_school, ex, v_cls8, sub_m, 'A'), '');

    BEGIN PERFORM pg_temp.marks_save(c_tenant, c_school, ex, v_cls8, sub_m, 'A', jsonb_build_array(pg_temp.mk(r1, '99')));
          PERFORM pg_temp.chk('C2 marks cannot change once results are published', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('C2 marks cannot change once results are published',
                                   SQLERRM LIKE '%published%locked%', SQLERRM); END;
    SELECT marks_obtained INTO v_dec FROM academic.exam_marks WHERE exam_id = ex AND subject_id = sub_m AND student_id = r1;
    PERFORM pg_temp.chk_eq('C3 ...and the mark is unchanged', v_dec, 90);

    BEGIN PERFORM pg_temp.reopen(c_tenant, c_school, ex, v_cls8, sub_m, 'A');
          PERFORM pg_temp.chk('C4 a sheet cannot be reopened while results are published', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('C4 a sheet cannot be reopened while results are published',
                                   SQLERRM LIKE '%Unpublish the results%', SQLERRM); END;

    BEGIN
        DECLARE c1 refcursor := pg_temp.cur(); c2 refcursor := pg_temp.cur();
        BEGIN
            CALL academic.sp_school_admin_exam_manage('SaveExam', c_tenant, c_school, c_user, v_year, NULL, ex,
                 'ZZ Results Term Test', 'Term', CURRENT_DATE + 20, CURRENT_DATE + 25, NULL,
                 jsonb_build_array(jsonb_build_object('classId', v_cls8, 'sections', '[]'::jsonb,
                     'subjects', jsonb_build_array(jsonb_build_object('subjectId', sub_m, 'maxMarks', 50))))::text,
                 c1, c2);
        END;
        PERFORM pg_temp.chk('C5 the exam cannot be edited while results are published', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('C5 the exam cannot be edited while results are published',
                                   SQLERRM LIKE '%cannot be edited%', SQLERRM); END;

    BEGIN PERFORM pg_temp.exam_op(c_tenant, c_school, 'SetStatus', ex, 'Draft');
          PERFORM pg_temp.chk('C6 the datesheet cannot go back to draft while results are published', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('C6 the datesheet cannot go back to draft while results are published',
                                   SQLERRM LIKE '%Unpublish the results%', SQLERRM); END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- D. Results: grades and rank ---------------------------------';

    -- Aditi (8-A): 90 + 40 of 150 = 86.67%  -> A2, rank 1 (tie)
    -- Esha  (8-B): 90 + 40 of 150 = 86.67%  -> A2, rank 1 (tie)
    -- Bharat(8-A): 80 + 45 of 150 = 83.33%  -> A2, rank 3
    -- Chetan(8-A): 45 of 100 (Science absent, out of the total) = 45% -> C2, rank 4
    -- Farhan(8-B): 30 + 10 of 150 = 26.67%  -> E,  rank 5
    -- Divya (8-A): absent in both           -> no %, no grade, no rank
    SELECT * INTO r FROM pg_temp.res(c_tenant, c_school, r1, ex);
    PERFORM pg_temp.chk_eq('D1 published results are visible to parents', r.exam_rows, 1);
    PERFORM pg_temp.chk_eq('D2 overall percentage 86.7', r.pct, 86.7);
    PERFORM pg_temp.chk_txt('D3 overall grade from the percentage (A2)', r.grade, 'A2');
    PERFORM pg_temp.chk('D4 class rank 1 of 5 ranked students', r.class_rank = 1 AND r.class_size = 5,
        format('rank=%s of %s', r.class_rank, r.class_size));

    SELECT * INTO r FROM pg_temp.res(c_tenant, c_school, r5, ex);
    PERFORM pg_temp.chk('D5 a tie on percentage shares rank 1 (other section)', r.class_rank = 1 AND r.section_rank = 1,
        format('class rank=%s section rank=%s', r.class_rank, r.section_rank));

    SELECT * INTO r FROM pg_temp.res(c_tenant, c_school, r2, ex);
    PERFORM pg_temp.chk('D6 the next student is rank 3, not 2 (1, 1, 3)', r.class_rank = 3,
        format('class rank=%s', r.class_rank));
    PERFORM pg_temp.chk('D7 ...and rank 2 of 3 within section A', r.section_rank = 2 AND r.section_size = 3,
        format('section rank=%s of %s', r.section_rank, r.section_size));

    SELECT * INTO r FROM pg_temp.res(c_tenant, c_school, r3, ex);
    PERFORM pg_temp.chk('D8 an absent paper is out of the total: 45/100 = 45%, grade C2, rank 4',
        r.total = 100 AND r.pct = 45.0 AND r.grade = 'C2' AND r.class_rank = 4,
        format('total=%s pct=%s grade=%s rank=%s', r.total, r.pct, r.grade, r.class_rank));

    SELECT * INTO r FROM pg_temp.res(c_tenant, c_school, r6, ex);
    PERFORM pg_temp.chk('D9 26.67% is grade E, last of 5', r.grade = 'E' AND r.class_rank = 5,
        format('grade=%s rank=%s', r.grade, r.class_rank));

    SELECT * INTO r FROM pg_temp.res(c_tenant, c_school, r4, ex);
    PERFORM pg_temp.chk('D10 absent from every paper: no grade and no rank',
        r.exam_rows = 1 AND r.grade IS NULL AND r.class_rank IS NULL,
        format('rows=%s grade=%s rank=%s', r.exam_rows, r.grade, r.class_rank));

    PERFORM pg_temp.chk_txt('D11 subject grade: Maths 90/100 = A2', pg_temp.res_subject_grade(c_tenant, c_school, r1, ex, 'ZZ R Maths'), 'A2');
    PERFORM pg_temp.chk_txt('D12 subject grade: Science 40/50 = 80% = B1 (out of its own max)',
        pg_temp.res_subject_grade(c_tenant, c_school, r1, ex, 'ZZ R Science'), 'B1');
    PERFORM pg_temp.chk_txt('D13 an absent subject has no grade',
        pg_temp.res_subject_grade(c_tenant, c_school, r3, ex, 'ZZ R Science'), NULL);

    -- The class result sheet.
    SELECT * INTO r FROM pg_temp.sheet(c_tenant, c_school, ex, v_cls8, NULL, r2);
    PERFORM pg_temp.chk('D14 class sheet: 6 students x 2 papers = 12 cells, results Published',
        r.students = 6 AND r.subjects = 2 AND r.cells = 12 AND r.results = 'Published',
        format('students=%s subjects=%s cells=%s results=%s', r.students, r.subjects, r.cells, r.results));
    PERFORM pg_temp.chk('D15 class sheet agrees with the dashboard (83.33%, A2, rank 3, section rank 2)',
        r.pct = 83.33 AND r.grade = 'A2' AND r.class_rank = 3 AND r.section_rank = 2,
        format('pct=%s grade=%s rank=%s/%s', r.pct, r.grade, r.class_rank, r.section_rank));

    SELECT * INTO r FROM pg_temp.sheet(c_tenant, c_school, ex, v_cls8, 'b', r6);
    PERFORM pg_temp.chk('D16 section filter (any case): 8-B only, class rank kept (Farhan 5th, 2nd in B)',
        r.students = 2 AND r.cells = 4 AND r.class_rank = 5 AND r.section_rank = 2,
        format('students=%s cells=%s rank=%s/%s', r.students, r.cells, r.class_rank, r.section_rank));

    -- A school's own scale changes the grade on the next read (nothing is stored).
    PERFORM pg_temp.gs_save(c_tenant, c_school, jsonb_build_array(
        pg_temp.band('P', 50, 100), pg_temp.band('Q', 0, 49)));
    SELECT * INTO r FROM pg_temp.res(c_tenant, c_school, r1, ex);
    PERFORM pg_temp.chk_txt('D17 grades follow the school''s current scale', r.grade, 'P');
    PERFORM pg_temp.gs_reset(c_tenant, c_school);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- E. Unpublish ------------------------------------------------';

    BEGIN PERFORM pg_temp.rs('UnpublishResults', c_tenant, c_school, ex, '   ');
          PERFORM pg_temp.chk('E1 unpublishing without a reason refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('E1 unpublishing without a reason refused', SQLERRM LIKE '%reason%', SQLERRM); END;

    BEGIN PERFORM pg_temp.rs('UnpublishResults', o_tenant, o_school, ex, 'not yours');
          PERFORM pg_temp.chk('E2 another school cannot unpublish our results', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('E2 another school cannot unpublish our results', SQLERRM LIKE '%not found%', SQLERRM); END;

    v_txt := pg_temp.rs('UnpublishResults', c_tenant, c_school, ex, 'Science total of Aditi was wrong');
    PERFORM pg_temp.chk('E3 unpublish with a reason succeeds', v_txt LIKE 'Results unpublished%', v_txt);
    SELECT COUNT(*) INTO v_n FROM academic.exam_result_log
     WHERE exam_id = ex AND action = 'Unpublish' AND reason = 'Science total of Aditi was wrong' AND done_by = c_user;
    PERFORM pg_temp.chk_eq('E4 the unpublish is logged with its reason, who and when', v_n, 1);
    SELECT * INTO r FROM pg_temp.rs_status(c_tenant, c_school, ex);
    PERFORM pg_temp.chk('E5 GetStatus: Unpublished, with both log entries',
        r.results = 'Unpublished' AND r.log_rows = 2, format('results=%s log=%s', r.results, r.log_rows));

    SELECT * INTO r FROM pg_temp.res(c_tenant, c_school, r1, ex);
    PERFORM pg_temp.chk_eq('E6 unpublished results are hidden from parents again', r.exam_rows, 0);

    BEGIN PERFORM pg_temp.rs('UnpublishResults', c_tenant, c_school, ex, 'again');
          PERFORM pg_temp.chk('E7 unpublishing results that are not published refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('E7 unpublishing results that are not published refused',
                                   SQLERRM LIKE '%not published%', SQLERRM); END;

    -- The correction: reopen the sheet, fix the mark, finalise, publish again.
    v_txt := pg_temp.reopen(c_tenant, c_school, ex, v_cls8, sub_sc, 'A');
    PERFORM pg_temp.chk('E8 after unpublishing, a sheet can be reopened', v_txt LIKE 'Sheet reopened%', v_txt);
    v_n := pg_temp.marks_save(c_tenant, c_school, ex, v_cls8, sub_sc, 'A', jsonb_build_array(pg_temp.mk(r1, '45')), TRUE);
    SELECT COUNT(*) INTO v_n FROM academic.exam_marks_history
     WHERE exam_id = ex AND subject_id = sub_sc AND student_id = r1 AND old_marks = 40 AND new_marks = 45;
    PERFORM pg_temp.chk_eq('E9 the corrected mark is in the edit history (40 -> 45)', v_n, 1);
    PERFORM pg_temp.rs('PublishResults', c_tenant, c_school, ex);
    SELECT * INTO r FROM pg_temp.res(c_tenant, c_school, r1, ex);
    PERFORM pg_temp.chk('E10 republished: Aditi 135/150 = 90%, now sole rank 1',
        r.pct = 90.0 AND r.class_rank = 1, format('pct=%s rank=%s', r.pct, r.class_rank));
    SELECT * INTO r FROM pg_temp.res(c_tenant, c_school, r5, ex);
    PERFORM pg_temp.chk_eq('E11 ...and Esha moves to rank 2', r.class_rank, 2);

    -- Marks of a paper no longer on the datesheet do not count (today's rule):
    -- remove Science behind the procs' back and Aditi is 90/100.
    DELETE FROM academic.exam_subjects WHERE exam_id = ex AND academic_class_id = v_cls8 AND subject_id = sub_sc;
    SELECT out_percent INTO v_dec FROM academic.fn_exam_class_result(c_tenant, c_school, ex, v_cls8) WHERE out_student_id = r1;
    PERFORM pg_temp.chk_eq('E12 marks of a removed paper do not count (90/100)', v_dec, 90.00);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- F. Scope ----------------------------------------------------';

    BEGIN PERFORM pg_temp.sheet(o_tenant, o_school, ex, v_cls8, NULL, r1);
          PERFORM pg_temp.chk('F1 another school cannot read our class result sheet', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('F1 another school cannot read our class result sheet',
                                   SQLERRM LIKE '%not found%', SQLERRM); END;

    BEGIN PERFORM pg_temp.rs_status(o_tenant, o_school, ex);
          PERFORM pg_temp.chk('F2 another school cannot read our publish status', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('F2 another school cannot read our publish status',
                                   SQLERRM LIKE '%not found%', SQLERRM); END;

    SELECT * INTO r FROM pg_temp.res(o_tenant, o_school, r1, ex);
    PERFORM pg_temp.chk_eq('F3 another school sees none of our student''s results', r.exam_rows, 0);

    BEGIN PERFORM pg_temp.rs('GetStatus', 1, 0, ex);
          PERFORM pg_temp.chk('F4 platform scope refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('F4 platform scope refused', SQLERRM LIKE '%scope%', SQLERRM); END;

    -- Our class result does not include another school's marks even if one is
    -- planted under our exam id.
    SELECT COUNT(*) INTO v_n FROM academic.fn_exam_class_result(o_tenant, o_school, ex, v_cls8);
    PERFORM pg_temp.chk_eq('F5 the result function is tenant-scoped (0 rows for another school)', v_n, 0);

    PERFORM pg_temp.gs_save(o_tenant, o_school, jsonb_build_array(pg_temp.band('Z', 0, 100)));
    PERFORM pg_temp.chk_txt('F6 another school''s scale does not change our grades',
        academic.fn_grade_for_percent(c_tenant, c_school, 85), 'A2');
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
            RAISE NOTICE '   %  %', rpad(r.name, 60), r.detail;
        END LOOP;
    END IF;
    RAISE NOTICE '';
END
$sum$;

ROLLBACK;
