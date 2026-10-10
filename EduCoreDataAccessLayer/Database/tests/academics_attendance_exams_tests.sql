-- ============================================================================
-- Daily academics test suite: attendance, exams, timetable, calendar, bell.
--
-- Goes deeper than attendance_exam_tests.sql and
-- settings_subjects_teachers_periods_tests.sql (it does not repeat their checks).
--
-- Scenario: Sunrise Public School, FY 26-27.
--   * Vinod is class teacher of 7-A. He marks a month of registers, corrects a
--     mistake, and tries to mark a 7-B student. A girl joins 7-A mid-month, a boy
--     moves from 7-A to 7-B, another boy leaves the school.
--   * The office declares a holiday, a half day, a Saturday weekly off and a
--     compensatory working Sunday; the bell and the register should agree.
--   * A Half Yearly exam runs for classes 6, 7 and 8 (Maths in all three, with
--     a different max for class 6). Marks come in with blanks, absences,
--     decimals and over-max values; a sheet is finalised, reopened and edited.
--   * The timetable is filled: teacher double-booking, a shared room, a Sunday,
--     a teacher/subject from another school, Copy Day.
--
-- Runs inside ONE transaction and ROLLS BACK.
--
--     psql ... -f academics_attendance_exams_tests.sql
--
-- COVERS
--   A. School calendar + Smart Bell day status
--   B. Attendance vs the calendar, the class-teacher gate, statuses
--   C. Attendance over a month: mid-month admission, section change, exit, edits
--   D. Exam create / schedule (SaveExam) and datesheet clashes
--   E. Marks entry: blanks, absences, decimals, sections, draft exams, audit
--   F. Results: multi-class exams, removed papers
--   G. Timetable: validation, room clashes, weekly offs, Copy Day
--   H. Scope and cross-school isolation
--
-- Every check asserts the CORRECT behaviour. The few still named "BUG ..."
-- document behaviour that is wrong today and owned outside this area; they
-- fail until fixed. Do not weaken any check.
-- ============================================================================

\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE TEMP TABLE _t(id serial, name text, ok boolean, detail text) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.chk(p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO _t(name, ok, detail) VALUES (p_name, COALESCE(p_ok, FALSE), p_detail);
    RAISE NOTICE '  [%] %  %', CASE WHEN COALESCE(p_ok, FALSE) THEN 'PASS' ELSE 'FAIL' END, rpad(p_name, 62), p_detail;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.chk_eq(p_name text, p_got numeric, p_want numeric)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.chk(p_name, p_got IS NOT DISTINCT FROM p_want,
                        format('got %s, expected %s', COALESCE(p_got::text,'NULL'), p_want));
END $$;

CREATE OR REPLACE FUNCTION pg_temp.chk_txt(p_name text, p_got text, p_want text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.chk(p_name, p_got IS NOT DISTINCT FROM p_want,
                        format('got [%s], expected [%s]', COALESCE(p_got,'NULL'), COALESCE(p_want,'NULL')));
END $$;

-- A fresh cursor name per call, so helpers never collide on an open portal.
CREATE OR REPLACE FUNCTION pg_temp.cur() RETURNS refcursor LANGUAGE sql AS
$$ SELECT ('k' || replace(gen_random_uuid()::text, '-', ''))::refcursor $$;

-- ── Attendance wrappers (same positional layout as AttendanceService) ──
CREATE OR REPLACE FUNCTION pg_temp.att_save(p_t int, p_s int, p_u int, p_date date, p_cls text, p_sec text, p_items jsonb)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE c refcursor := pg_temp.cur(); r record;
BEGIN
    CALL core.sp_attendance_save(p_t, p_s, p_u, p_date, p_cls, p_sec, p_items, c);
    FETCH c INTO r; CLOSE c;
    RETURN r.saved;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.att_items(VARIADIC p_pairs text[])
RETURNS jsonb LANGUAGE plpgsql AS $$
-- att_items('12:Present', '13:Absent') -> [{"studentId":12,"status":"Present"}, ...]
DECLARE v jsonb := '[]'; x text;
BEGIN
    FOREACH x IN ARRAY p_pairs LOOP
        v := v || jsonb_build_array(jsonb_build_object(
                 'studentId', split_part(x, ':', 1)::int, 'status', split_part(x, ':', 2)));
    END LOOP;
    RETURN v;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.att_sum(p_t int, p_s int, p_sid int,
    OUT sd int, OUT pr int, OUT ab int, OUT lv int, OUT pc numeric)
LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := pg_temp.cur(); c2 refcursor := pg_temp.cur(); c3 refcursor := pg_temp.cur();
BEGIN
    CALL core.sp_attendance_student(p_t, p_s, 39, p_sid, NULL, NULL, NULL, c1, c2, c3);
    FETCH c1 INTO sd, pr, ab, lv, pc;
    CLOSE c1; CLOSE c2; CLOSE c3;
END $$;

-- One class-section's month register, seen from one student: the class's
-- school days, whether the student is listed, how many marks they have, the
-- number of this register's days they belonged to, and the shaded days off.
CREATE OR REPLACE FUNCTION pg_temp.att_reg(p_t int, p_s int, p_cls text, p_sec text, p_m int, p_y int, p_sid int,
    OUT school_days int, OUT listed boolean, OUT marks int, OUT my_days int, OUT days_off text)
LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := pg_temp.cur(); c2 refcursor := pg_temp.cur(); c3 refcursor := pg_temp.cur();
        c4 refcursor := pg_temp.cur(); r record;
BEGIN
    CALL core.sp_attendance_month_register(p_t, p_s, 39, p_cls, p_sec, p_m, p_y, c1, c2, c3, c4);
    FETCH c1 INTO school_days;
    listed := FALSE; marks := 0; days_off := ',';
    LOOP FETCH c2 INTO r; EXIT WHEN NOT FOUND;
        IF r.student_id = p_sid THEN listed := TRUE; my_days := r.school_days; END IF;
    END LOOP;
    LOOP FETCH c3 INTO r; EXIT WHEN NOT FOUND; IF r.student_id = p_sid THEN marks := marks + 1; END IF; END LOOP;
    LOOP FETCH c4 INTO r; EXIT WHEN NOT FOUND; days_off := days_off || r.day || ','; END LOOP;
    CLOSE c1; CLOSE c2; CLOSE c3; CLOSE c4;
END $$;

-- First day on/after p_from that the School Calendar has as a working day.
CREATE OR REPLACE FUNCTION pg_temp.next_working(p_t int, p_s int, p_from date)
RETURNS date LANGUAGE plpgsql AS $$
DECLARE d date := p_from;
BEGIN
    WHILE academic.fn_school_day_type(p_t, p_s, d) NOT IN ('working', 'half_day') LOOP
        d := d + 1;
    END LOOP;
    RETURN d;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.att_roster_has(p_t int, p_s int, p_cls text, p_sec text, p_date date, p_sid int)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE c refcursor := pg_temp.cur(); r record; v boolean := FALSE;
BEGIN
    CALL core.sp_attendance_roster(p_t, p_s, 39, p_cls, p_sec, p_date, c);
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.student_id = p_sid THEN v := TRUE; END IF; END LOOP;
    CLOSE c;
    RETURN v;
END $$;

-- ── Class teacher gate (10-arg session-aware overload) ──
CREATE OR REPLACE FUNCTION pg_temp.ct_assign(p_t int, p_s int, p_sec int, p_staff int)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c refcursor := pg_temp.cur(); r record;
BEGIN
    CALL core.sp_class_teacher_manage('Assign'::varchar, p_t, p_s, 39, NULL::int, p_sec, p_staff, NULL::varchar, NULL::varchar, c);
    FETCH c INTO r; CLOSE c;
    RETURN r.message;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.ct_is(p_t int, p_s int, p_user int, p_cls text, p_sec text)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE c refcursor := pg_temp.cur(); r record;
BEGIN
    CALL core.sp_class_teacher_manage('IsTeacher'::varchar, p_t, p_s, p_user, NULL::int, NULL::int, NULL::int, p_cls::varchar, p_sec::varchar, c);
    FETCH c INTO r; CLOSE c;
    RETURN r.is_teacher;
END $$;

-- ── Calendar wrappers (same positional layout as SchoolCalendarService) ──
CREATE OR REPLACE FUNCTION pg_temp.cal(p_t int, p_s int, p_op text, p_id int, p_date date,
                                       p_type text, p_title text, p_half time, p_weekly text)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := pg_temp.cur(); c2 refcursor := pg_temp.cur(); r record;
BEGIN
    CALL academic.sp_school_admin_calendar_manage(p_op, p_t, p_s, 39, p_id, p_date, NULL::date,
         p_type, p_title, p_half, p_weekly, c1, c2);
    FETCH c1 INTO r; CLOSE c1; CLOSE c2;
    RETURN r.message;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.cal_day(p_t int, p_s int, p_date date,
    OUT day_type text, OUT is_working boolean, OUT half_end text, OUT title text, OUT cal_date text)
LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := pg_temp.cur(); c2 refcursor := pg_temp.cur(); r record;
BEGIN
    CALL academic.sp_school_admin_calendar_manage('GetDayStatus', p_t, p_s, 39, NULL, p_date, NULL::date,
         NULL, NULL, NULL, NULL, c1, c2);
    FETCH c1 INTO r; CLOSE c1; CLOSE c2;
    day_type := r.day_type; is_working := r.is_working; half_end := r.half_day_end;
    title := r.title; cal_date := r.calendar_date;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.cal_get(p_t int, p_s int, p_from date, p_to date)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := pg_temp.cur(); c2 refcursor := pg_temp.cur(); r record; n int := 0;
BEGIN
    CALL academic.sp_school_admin_calendar_manage('GetCalendar', p_t, p_s, 39, NULL, p_from, p_to,
         NULL, NULL, NULL, NULL, c1, c2);
    LOOP FETCH c1 INTO r; EXIT WHEN NOT FOUND; n := n + 1; END LOOP;
    CLOSE c1; CLOSE c2;
    RETURN n;
END $$;

-- ── Exam wrappers (same positional layout as ExamService) ──
CREATE OR REPLACE FUNCTION pg_temp.exam_save(p_t int, p_s int, p_year int, p_exam int, p_name text,
                                             p_start date, p_end date, p_items jsonb)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := pg_temp.cur(); c2 refcursor := pg_temp.cur(); r record;
BEGIN
    CALL academic.sp_school_admin_exam_manage('SaveExam', p_t, p_s, 39, p_year, NULL, p_exam, p_name, 'Term',
         p_start, p_end, NULL, p_items::text, c1, c2);
    FETCH c1 INTO r; CLOSE c1; CLOSE c2;
    RETURN r.message;
END $$;

-- One class's datesheet item for exam_save.
CREATE OR REPLACE FUNCTION pg_temp.ex_cls(p_cls int, p_subs jsonb, p_secs jsonb DEFAULT '[]')
RETURNS jsonb LANGUAGE sql AS
$$ SELECT jsonb_build_object('classId', p_cls, 'sections', p_secs, 'subjects', p_subs) $$;

CREATE OR REPLACE FUNCTION pg_temp.ex_sub(p_sub int, p_date date, p_from text, p_to text,
                                          p_max numeric DEFAULT 100, p_pass numeric DEFAULT 33)
RETURNS jsonb LANGUAGE sql AS
$$ SELECT jsonb_build_object('subjectId', p_sub, 'examDate', p_date::text, 'startTime', p_from,
                             'endTime', p_to, 'maxMarks', p_max, 'passMarks', p_pass) $$;

CREATE OR REPLACE FUNCTION pg_temp.exam_op(p_t int, p_s int, p_op text, p_exam int, p_status text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := pg_temp.cur(); c2 refcursor := pg_temp.cur(); r record;
BEGIN
    CALL academic.sp_school_admin_exam_manage(p_op, p_t, p_s, 39, NULL, NULL, p_exam, NULL, NULL,
         NULL, NULL, p_status, NULL, c1, c2);
    FETCH c1 INTO r; CLOSE c1; CLOSE c2;
    RETURN r.message;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.exam_year_name(p_t int, p_s int, p_year int)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := pg_temp.cur(); c2 refcursor := pg_temp.cur(); r record;
BEGIN
    CALL academic.sp_school_admin_exam_manage('GetExams', p_t, p_s, 39, p_year, NULL, NULL, NULL, NULL,
         NULL, NULL, NULL, NULL, c1, c2);
    FETCH c2 INTO r; CLOSE c1; CLOSE c2;
    RETURN r.academic_year_name;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.exam_get_rows(p_t int, p_s int, p_exam int)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := pg_temp.cur(); c2 refcursor := pg_temp.cur(); r record; n int := 0;
BEGIN
    CALL academic.sp_school_admin_exam_manage('GetExam', p_t, p_s, 39, NULL, NULL, p_exam, NULL, NULL,
         NULL, NULL, NULL, NULL, c1, c2);
    LOOP FETCH c1 INTO r; EXIT WHEN NOT FOUND; n := n + 1; END LOOP;
    LOOP FETCH c2 INTO r; EXIT WHEN NOT FOUND; n := n + 1; END LOOP;
    CLOSE c1; CLOSE c2;
    RETURN n;
END $$;

-- has_clash of one datesheet row (exam, class, subject).
CREATE OR REPLACE FUNCTION pg_temp.ds_clash(p_t int, p_s int, p_exam int, p_cls int, p_subject text)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := pg_temp.cur(); c2 refcursor := pg_temp.cur(); r record; v boolean;
BEGIN
    CALL academic.sp_school_admin_exam_manage('GetDatesheet', p_t, p_s, 39, NULL, p_cls, p_exam, NULL, NULL,
         NULL, NULL, NULL, NULL, c1, c2);
    LOOP FETCH c1 INTO r; EXIT WHEN NOT FOUND; IF r.subject_name = p_subject THEN v := r.has_clash; END IF; END LOOP;
    CLOSE c1; CLOSE c2;
    RETURN v;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.marks_save(p_t int, p_s int, p_u int, p_exam int, p_cls int, p_sub int,
                                              p_sec text, p_items jsonb, p_fin boolean DEFAULT FALSE)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := pg_temp.cur(); c2 refcursor := pg_temp.cur(); r record;
BEGIN
    CALL academic.sp_school_admin_exam_marks_manage('SaveMarks', p_t, p_s, p_u, p_exam, p_cls, p_sub, p_sec,
         p_items::text, p_fin, c1, c2);
    FETCH c1 INTO r; CLOSE c1; CLOSE c2;
    RETURN r.saved;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.mk(p_sid int, p_marks text, p_absent boolean DEFAULT FALSE)
RETURNS jsonb LANGUAGE sql AS
$$ SELECT jsonb_build_object('studentId', p_sid, 'marks', p_marks, 'absent', p_absent) $$;

CREATE OR REPLACE FUNCTION pg_temp.sheet_has(p_t int, p_s int, p_exam int, p_cls int, p_sub int, p_sec text, p_sid int)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := pg_temp.cur(); c2 refcursor := pg_temp.cur(); r record; v boolean := FALSE;
BEGIN
    CALL academic.sp_school_admin_exam_marks_manage('GetSheet', p_t, p_s, 39, p_exam, p_cls, p_sub, p_sec,
         NULL, FALSE, c1, c2);
    LOOP FETCH c1 INTO r; EXIT WHEN NOT FOUND; IF r.student_id = p_sid THEN v := TRUE; END IF; END LOOP;
    CLOSE c1; CLOSE c2;
    RETURN v;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.setup_secs(p_t int, p_s int, p_exam int, p_cls int)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := pg_temp.cur(); c2 refcursor := pg_temp.cur(); r record; v text := '';
BEGIN
    CALL academic.sp_school_admin_exam_marks_manage('GetClassSetup', p_t, p_s, 39, p_exam, p_cls, NULL, NULL,
         NULL, FALSE, c1, c2);
    LOOP FETCH c2 INTO r; EXIT WHEN NOT FOUND;
        v := v || CASE WHEN v = '' THEN '' ELSE ',' END || r.section;
    END LOOP;
    CLOSE c1; CLOSE c2;
    RETURN v;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.reopen(p_t int, p_s int, p_exam int, p_cls int, p_sub int, p_sec text)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := pg_temp.cur(); c2 refcursor := pg_temp.cur(); r record;
BEGIN
    CALL academic.sp_school_admin_exam_marks_manage('ReopenSheet', p_t, p_s, 39, p_exam, p_cls, p_sub, p_sec,
         NULL, FALSE, c1, c2);
    FETCH c1 INTO r; CLOSE c1; CLOSE c2;
    RETURN r.message;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.res(p_t int, p_s int, p_sid int, p_exam int,
    OUT subjects int, OUT obtained numeric, OUT total numeric, OUT pct numeric, OUT absent int, OUT failed int,
    OUT exam_rows int)
LANGUAGE plpgsql AS $$
DECLARE ce refcursor := pg_temp.cur(); cm refcursor := pg_temp.cur(); cs refcursor := pg_temp.cur(); r record;
BEGIN
    CALL core.sp_exam_result_student(p_t, p_s, 39, p_sid, p_exam, ce, cm, cs);
    exam_rows := 0;
    LOOP FETCH ce INTO r; EXIT WHEN NOT FOUND; exam_rows := exam_rows + 1; END LOOP;
    FETCH cs INTO subjects, obtained, total, pct, absent, failed;
    CLOSE ce; CLOSE cm; CLOSE cs;
END $$;

-- ── Period structure + timetable wrappers ──
CREATE OR REPLACE FUNCTION pg_temp.ps_save(p_t int, p_s int, p_items text)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c refcursor := pg_temp.cur(); r record;
BEGIN
    CALL academic.sp_school_admin_period_structure_manage('SavePeriodStructure', p_t, p_s, 39, p_items, c);
    FETCH c INTO r; CLOSE c;
    RETURN r.message;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.tt(p_op text, p_t int, p_s int, p_sec int, p_day int, p_seq int,
                                      p_subject int, p_staff int, p_room text)
RETURNS record LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := pg_temp.cur(); c2 refcursor := pg_temp.cur();
        c3 refcursor := pg_temp.cur(); c4 refcursor := pg_temp.cur(); r record;
BEGIN
    CALL academic.sp_school_admin_timetable_manage(p_op, p_t, p_s, 39, NULL::int, p_sec,
         p_day::smallint, p_seq::smallint, p_subject, p_staff, p_room::varchar, c1, c2, c3, c4);
    FETCH c1 INTO r; CLOSE c1; CLOSE c2; CLOSE c3; CLOSE c4;
    RETURN r;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.tt_save(p_t int, p_s int, p_sec int, p_day int, p_seq int,
                                           p_subject int, p_staff int, p_room text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE r record;
BEGIN
    r := pg_temp.tt('SaveCell', p_t, p_s, p_sec, p_day, p_seq, p_subject, p_staff, p_room);
    RETURN r.message;
END $$;

-- Staff ids in GetSetup's teacher list that are NOT active teaching staff.
CREATE OR REPLACE FUNCTION pg_temp.tt_setup_nonteaching(p_t int, p_s int)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := pg_temp.cur(); c2 refcursor := pg_temp.cur();
        c3 refcursor := pg_temp.cur(); c4 refcursor := pg_temp.cur(); r record; n int := 0;
BEGIN
    CALL academic.sp_school_admin_timetable_manage('GetSetup', p_t, p_s, 39, NULL::int, NULL::int,
         NULL::smallint, NULL::smallint, NULL::int, NULL::int, NULL::varchar, c1, c2, c3, c4);
    LOOP FETCH c3 INTO r; EXIT WHEN NOT FOUND;
        IF EXISTS (SELECT 1 FROM core.staff WHERE staff_id = r.staff_id
                   AND LOWER(COALESCE(staff_type, '')) <> 'teaching') THEN n := n + 1; END IF;
    END LOOP;
    CLOSE c1; CLOSE c2; CLOSE c3; CLOSE c4;
    RETURN n;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.tt_grid_rows(p_t int, p_s int, p_sec int)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := pg_temp.cur(); c2 refcursor := pg_temp.cur();
        c3 refcursor := pg_temp.cur(); c4 refcursor := pg_temp.cur(); r record; n int := 0;
BEGIN
    CALL academic.sp_school_admin_timetable_manage('GetGrid', p_t, p_s, 39, NULL::int, p_sec,
         NULL::smallint, NULL::smallint, NULL::int, NULL::int, NULL::varchar, c1, c2, c3, c4);
    LOOP FETCH c1 INTO r; EXIT WHEN NOT FOUND; n := n + 1; END LOOP;
    CLOSE c1; CLOSE c2; CLOSE c3; CLOSE c4;
    RETURN n;
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
    v_ystart   date;
    v_cls6 integer; v_cls7 integer; v_cls8 integer;
    v_sec7a integer; v_sec7b integer; v_sec8a integer;

    v_vinod_staff integer; v_vinod_user integer;     -- class teacher of 7-A
    v_shiv_staff  integer; v_shiv_user  integer;     -- another teacher
    v_nt_staff    integer;                           -- active non-teaching staff
    v_in_staff    integer; v_in_user    integer;     -- inactive teaching staff with a login
    v_ot_staff    integer;                           -- staff of the other school
    v_ot_subject  integer;                           -- subject of the other school
    v_ot_class    integer;                           -- class of the other school
    v_ot_year     integer;                           -- session of the other school
    v_ot_student  integer;                           -- student of the other school
    v_ot_exam     integer;

    -- students
    s1 integer; s2 integer; s_mid integer; s_move integer; s_exit integer;
    s7b integer; s6 integer; s_cal integer;

    -- dates
    v_mon date; v_sun date; v_sat date; v_hol date; v_half date;
    v_mstart date; v_mm int; v_my int;
    d1 date; d2 date; d3 date; d4 date;
    v_days date[];

    -- exams / subjects
    sub_m integer; sub_sc integer; sub_art integer;
    ex_x integer;   -- Half Yearly, classes 6/7/8, Published, class 7 targets section A
    ex_y integer;   -- Unit Test, class 7 only
    ex_z integer;   -- another exam, class 7 section B
    ex_w integer;   -- another exam, whole class 7
    ex_d integer;   -- a draft exam

    c     refcursor;
    v_n   integer;
    v_m   integer;
    v_txt text;
    v_b   boolean;
    v_dec numeric;
    v_id  integer;
    v_cal integer;
    r     record;
    seq1 int; seq2 int; seq_brk int;
    wd_x1 date; wd_x2 date; wd_y1 date; wd_y2 date; wd_n date;   -- working days for exam papers
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '===== DAILY ACADEMICS: ATTENDANCE / EXAMS / TIMETABLE / CALENDAR =====';

    -- ── Fixture ────────────────────────────────────────────────────────────
    SELECT academic_year_id, academic_year_name, start_date::date INTO v_year, v_yearname, v_ystart
    FROM academic.academic_years
    WHERE tenant_id = c_tenant AND school_id = c_school AND COALESCE(is_current, FALSE)
      AND NOT is_deleted LIMIT 1;

    SELECT academic_class_id INTO v_cls6 FROM academic.academic_classes
     WHERE tenant_id = c_tenant AND school_id = c_school AND academic_year_id = v_year AND class_name = '6' AND NOT is_deleted;
    SELECT academic_class_id INTO v_cls7 FROM academic.academic_classes
     WHERE tenant_id = c_tenant AND school_id = c_school AND academic_year_id = v_year AND class_name = '7' AND NOT is_deleted;
    SELECT academic_class_id INTO v_cls8 FROM academic.academic_classes
     WHERE tenant_id = c_tenant AND school_id = c_school AND academic_year_id = v_year AND class_name = '8' AND NOT is_deleted;

    SELECT academic_class_section_id INTO v_sec7a FROM academic.academic_class_sections
     WHERE academic_class_id = v_cls7 AND section_name = 'A' AND NOT is_deleted;
    SELECT academic_class_section_id INTO v_sec8a FROM academic.academic_class_sections
     WHERE academic_class_id = v_cls8 AND section_name = 'A' AND NOT is_deleted;

    -- Class 7 gets a second section for the section-change scenario.
    SELECT academic_class_section_id INTO v_sec7b FROM academic.academic_class_sections
     WHERE academic_class_id = v_cls7 AND section_name = 'B' AND NOT is_deleted;
    IF v_sec7b IS NULL THEN
        INSERT INTO academic.academic_class_sections
            (tenant_id, school_id, academic_year_id, academic_class_id, section_name, display_order, created_by, room_no)
        VALUES (c_tenant, c_school, v_year, v_cls7, 'B', 2, c_user, NULL)
        RETURNING academic_class_section_id INTO v_sec7b;
    END IF;

    SELECT staff_id, user_id INTO v_vinod_staff, v_vinod_user FROM core.staff
     WHERE tenant_id = c_tenant AND school_id = c_school AND staff_type = 'Teaching'
       AND is_active AND NOT is_deleted AND user_id IS NOT NULL ORDER BY staff_id LIMIT 1;
    SELECT staff_id, user_id INTO v_shiv_staff, v_shiv_user FROM core.staff
     WHERE tenant_id = c_tenant AND school_id = c_school AND staff_type = 'Teaching'
       AND is_active AND NOT is_deleted AND user_id IS NOT NULL AND staff_id <> v_vinod_staff ORDER BY staff_id LIMIT 1;
    SELECT staff_id INTO v_nt_staff FROM core.staff
     WHERE tenant_id = c_tenant AND school_id = c_school AND staff_type <> 'Teaching'
       AND is_active AND NOT is_deleted ORDER BY staff_id LIMIT 1;
    SELECT staff_id, user_id INTO v_in_staff, v_in_user FROM core.staff
     WHERE tenant_id = c_tenant AND school_id = c_school AND staff_type = 'Teaching'
       AND NOT is_active AND NOT is_deleted AND user_id IS NOT NULL ORDER BY staff_id LIMIT 1;

    SELECT staff_id INTO v_ot_staff FROM core.staff
     WHERE tenant_id = o_tenant AND school_id = o_school AND NOT is_deleted ORDER BY staff_id LIMIT 1;
    SELECT academic_year_id INTO v_ot_year FROM academic.academic_years
     WHERE tenant_id = o_tenant AND school_id = o_school AND NOT is_deleted ORDER BY academic_year_id LIMIT 1;
    SELECT academic_class_id INTO v_ot_class FROM academic.academic_classes
     WHERE tenant_id = o_tenant AND school_id = o_school AND NOT is_deleted ORDER BY academic_class_id LIMIT 1;
    SELECT student_id INTO v_ot_student FROM core.students
     WHERE tenant_id = o_tenant AND school_id = o_school AND is_active ORDER BY student_id LIMIT 1;
    INSERT INTO academic.school_subjects(tenant_id, school_id, subject_name, created_by)
    VALUES (o_tenant, o_school, 'ZZ Other School Subject', c_user) RETURNING subject_id INTO v_ot_subject;

    IF v_year IS NULL OR v_cls6 IS NULL OR v_cls7 IS NULL OR v_cls8 IS NULL OR v_sec7a IS NULL OR v_sec8a IS NULL
       OR v_vinod_staff IS NULL OR v_shiv_staff IS NULL OR v_nt_staff IS NULL OR v_in_staff IS NULL
       OR v_ot_staff IS NULL OR v_ot_year IS NULL OR v_ot_class IS NULL OR v_ot_student IS NULL THEN
        RAISE EXCEPTION 'Fixture missing for school % (year=% 6=% 7=% 8=% 7A=% 8A=% vinod=% shiv=% nt=% in=% ot=%/%/%/%)',
            c_school, v_year, v_cls6, v_cls7, v_cls8, v_sec7a, v_sec8a, v_vinod_staff, v_shiv_staff,
            v_nt_staff, v_in_staff, v_ot_staff, v_ot_year, v_ot_class, v_ot_student;
    END IF;

    -- A wide back-date window so the month scenario can use real past dates.
    -- (The window rule itself is attendance_exam_tests.sql A3.)
    UPDATE core.school_settings SET attendance_backdate_days = 120
     WHERE tenant_id = c_tenant AND school_id = c_school;

    -- Dates. Today's week for calendar rules; a month ~6 weeks back for the
    -- register scenario, so the two never share a day.
    v_mon  := CURRENT_DATE - ((EXTRACT(DOW FROM CURRENT_DATE)::int + 6) % 7);   -- latest Monday <= today
    v_sun  := CURRENT_DATE - EXTRACT(DOW FROM CURRENT_DATE)::int;              -- latest Sunday <= today
    v_sat  := CURRENT_DATE - ((EXTRACT(DOW FROM CURRENT_DATE)::int + 1) % 7);  -- latest Saturday <= today
    v_hol  := v_mon - 7;                                                       -- the Monday before
    v_half := v_mon - 6;                                                       -- the Tuesday before
    v_mstart := date_trunc('month', CURRENT_DATE - 45)::date;
    v_mm := EXTRACT(MONTH FROM v_mstart)::int;
    v_my := EXTRACT(YEAR FROM v_mstart)::int;

    SELECT array_agg(d ORDER BY d) INTO v_days FROM (
        SELECT g::date AS d
        FROM generate_series(v_mstart, (v_mstart + INTERVAL '1 month - 1 day')::date, INTERVAL '1 day') g
        WHERE EXTRACT(DOW FROM g) <> 0
          AND NOT EXISTS (SELECT 1 FROM academic.school_calendar sc
                          WHERE sc.tenant_id = c_tenant AND sc.school_id = c_school
                            AND sc.calendar_date = to_char(g, 'YYYY-MM-DD'))
        ORDER BY g LIMIT 4) x;
    d1 := v_days[1]; d2 := v_days[2]; d3 := v_days[3]; d4 := v_days[4];

    -- Subjects: Maths is taught in 6, 7 and 8; Science in 7; Art in nobody's class.
    INSERT INTO academic.school_subjects(tenant_id, school_id, subject_name, created_by)
    VALUES (c_tenant, c_school, 'ZZ Maths', c_user) RETURNING subject_id INTO sub_m;
    INSERT INTO academic.school_subjects(tenant_id, school_id, subject_name, created_by)
    VALUES (c_tenant, c_school, 'ZZ Science', c_user) RETURNING subject_id INTO sub_sc;
    INSERT INTO academic.school_subjects(tenant_id, school_id, subject_name, created_by)
    VALUES (c_tenant, c_school, 'ZZ Art', c_user) RETURNING subject_id INTO sub_art;
    INSERT INTO academic.class_subjects(tenant_id, school_id, academic_year_id, academic_class_id, subject_id, display_order, created_by)
    VALUES (c_tenant, c_school, v_year, v_cls6, sub_m, 90, c_user),
           (c_tenant, c_school, v_year, v_cls7, sub_m, 90, c_user),
           (c_tenant, c_school, v_year, v_cls8, sub_m, 90, c_user),
           (c_tenant, c_school, v_year, v_cls7, sub_sc, 91, c_user);

    -- Students.
    c := pg_temp.cur();
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL, 'ZZ-AE-1', NULL, 'ZZ AE Aarav',
         'Male', DATE '2014-01-01', '7', 'A', v_yearname, v_mstart - 10, p_result => c);
    c := pg_temp.cur();
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL, 'ZZ-AE-2', NULL, 'ZZ AE Bhavna',
         'Female', DATE '2014-02-01', '7', 'A', v_yearname, v_mstart - 10, p_result => c);
    c := pg_temp.cur();
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL, 'ZZ-AE-3', NULL, 'ZZ AE Chhavi',
         'Female', DATE '2014-03-01', '7', 'A', v_yearname, d3, p_result => c);     -- joins mid-month
    c := pg_temp.cur();
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL, 'ZZ-AE-4', NULL, 'ZZ AE Dev',
         'Male', DATE '2014-04-01', '7', 'A', v_yearname, v_mstart - 10, p_result => c);  -- moves to 7-B
    c := pg_temp.cur();
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL, 'ZZ-AE-5', NULL, 'ZZ AE Eshan',
         'Male', DATE '2014-05-01', '7', 'A', v_yearname, v_mstart - 10, p_result => c);  -- leaves
    c := pg_temp.cur();
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL, 'ZZ-AE-6', NULL, 'ZZ AE Farah',
         'Female', DATE '2014-06-01', '7', 'B', v_yearname, v_mstart - 10, p_result => c);
    c := pg_temp.cur();
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL, 'ZZ-AE-7', NULL, 'ZZ AE Gita',
         'Female', DATE '2015-01-01', '6', 'A', v_yearname, v_mstart - 10, p_result => c);
    c := pg_temp.cur();
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL, 'ZZ-AE-9', NULL, 'ZZ AE Ishaan',
         'Male', DATE '2013-01-01', '8', 'A', v_yearname, v_ystart, p_result => c);

    SELECT student_id INTO s1     FROM core.students WHERE tenant_id = c_tenant AND admission_no = 'ZZ-AE-1';
    SELECT student_id INTO s2     FROM core.students WHERE tenant_id = c_tenant AND admission_no = 'ZZ-AE-2';
    SELECT student_id INTO s_mid  FROM core.students WHERE tenant_id = c_tenant AND admission_no = 'ZZ-AE-3';
    SELECT student_id INTO s_move FROM core.students WHERE tenant_id = c_tenant AND admission_no = 'ZZ-AE-4';
    SELECT student_id INTO s_exit FROM core.students WHERE tenant_id = c_tenant AND admission_no = 'ZZ-AE-5';
    SELECT student_id INTO s7b    FROM core.students WHERE tenant_id = c_tenant AND admission_no = 'ZZ-AE-6';
    SELECT student_id INTO s6     FROM core.students WHERE tenant_id = c_tenant AND admission_no = 'ZZ-AE-7';
    SELECT student_id INTO s_cal  FROM core.students WHERE tenant_id = c_tenant AND admission_no = 'ZZ-AE-9';

    IF s1 IS NULL OR s2 IS NULL OR s_mid IS NULL OR s_move IS NULL OR s_exit IS NULL
       OR s7b IS NULL OR s6 IS NULL OR s_cal IS NULL OR d4 IS NULL THEN
        RAISE EXCEPTION 'Fixture students/dates missing (s1=% s_cal=% d4=%)', s1, s_cal, d4;
    END IF;

    RAISE NOTICE 'fixture: session=% 6=% 7=% 8=% 7-A=% 7-B=% vinod=%/% shivam=%/% month=%-% days=% % % % week mon=% sun=% sat=% holiday=% halfday=%',
        v_yearname, v_cls6, v_cls7, v_cls8, v_sec7a, v_sec7b, v_vinod_staff, v_vinod_user, v_shiv_staff, v_shiv_user,
        v_my, v_mm, d1, d2, d3, d4, v_mon, v_sun, v_sat, v_hol, v_half;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- A. School calendar + Smart Bell ---------------------------------';

    -- CAL-A1: the School Calendar page's only read. The dates-as-text migration
    -- turned calendar_date into varchar and to_char(varchar, ...) does not exist.
    BEGIN
        v_n := pg_temp.cal_get(c_tenant, c_school, date_trunc('year', CURRENT_DATE)::date,
                               (date_trunc('year', CURRENT_DATE) + INTERVAL '1 year - 1 day')::date);
        PERFORM pg_temp.chk('CAL-A1 GetCalendar (the calendar page load) works', TRUE, format('%s entries', v_n));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CAL-A1 GetCalendar (the calendar page load) works', FALSE, SQLERRM);
    END;

    v_txt := pg_temp.cal(c_tenant, c_school, 'SaveEntry', NULL, v_hol, 'holiday', 'ZZ Local Festival', NULL, NULL);
    PERFORM pg_temp.chk_txt('CAL-A2 a holiday is saved', v_txt, 'Calendar updated.');
    SELECT * INTO r FROM pg_temp.cal_day(c_tenant, c_school, v_hol);
    PERFORM pg_temp.chk('CAL-A3 the bell sees the holiday as closed',
        r.day_type = 'holiday' AND r.is_working = FALSE AND r.title = 'ZZ Local Festival',
        format('%s / working=%s / %s', r.day_type, r.is_working, r.title));

    BEGIN
        PERFORM pg_temp.cal(c_tenant, c_school, 'SaveEntry', NULL, v_half, 'half_day', 'ZZ PTM', NULL, NULL);
        PERFORM pg_temp.chk('CAL-A4 a half day with no closing time refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CAL-A4 a half day with no closing time refused', SQLERRM LIKE '%closing time%', SQLERRM);
    END;

    PERFORM pg_temp.cal(c_tenant, c_school, 'SaveEntry', NULL, v_half, 'half_day', 'ZZ PTM', TIME '11:30', NULL);
    SELECT * INTO r FROM pg_temp.cal_day(c_tenant, c_school, v_half);
    PERFORM pg_temp.chk('CAL-A5 a half day is a working day that closes at 11:30',
        r.day_type = 'half_day' AND r.is_working AND r.half_end = '11:30',
        format('%s / working=%s / closes %s', r.day_type, r.is_working, r.half_end));

    BEGIN
        PERFORM pg_temp.cal(c_tenant, c_school, 'SaveEntry', NULL, v_half, 'vacation', 'x', NULL, NULL);
        PERFORM pg_temp.chk('CAL-A6 an unknown day type refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CAL-A6 an unknown day type refused', SQLERRM LIKE '%Unknown day type%', SQLERRM);
    END;

    -- Re-saving a date replaces the entry; switching half day -> holiday drops the time.
    PERFORM pg_temp.cal(c_tenant, c_school, 'SaveEntry', NULL, v_half, 'holiday', '', NULL, NULL);
    SELECT COUNT(*) INTO v_n
      FROM academic.school_calendar WHERE tenant_id = c_tenant AND school_id = c_school
       AND calendar_date = v_half::text;
    PERFORM pg_temp.chk_eq('CAL-A7 re-saving a date keeps one entry', v_n, 1);
    SELECT title || '|' || COALESCE(half_day_end::text, 'no time') INTO v_txt FROM academic.school_calendar
     WHERE tenant_id = c_tenant AND school_id = c_school AND calendar_date = v_half::text;
    PERFORM pg_temp.chk_txt('CAL-A8 ...blank title becomes "Holiday", the half-day time is dropped', v_txt, 'Holiday|no time');
    PERFORM pg_temp.cal(c_tenant, c_school, 'SaveEntry', NULL, v_half, 'half_day', 'ZZ PTM', TIME '11:30', NULL);

    -- Weekly offs: Saturday off as well as Sunday.
    v_txt := pg_temp.cal(c_tenant, c_school, 'SaveWeeklyOff', NULL, NULL, NULL, NULL, NULL, '0,6');
    SELECT * INTO r FROM pg_temp.cal_day(c_tenant, c_school, v_sat);
    PERFORM pg_temp.chk('CAL-A9 Saturday reads as a weekly off once configured',
        r.day_type = 'weekly_off' AND NOT r.is_working, format('%s / working=%s', r.day_type, r.is_working));

    -- A compensatory working Sunday overrides the weekly pattern.
    PERFORM pg_temp.cal(c_tenant, c_school, 'SaveEntry', NULL, v_sun, 'working', 'ZZ Compensatory day', NULL, NULL);
    SELECT * INTO r FROM pg_temp.cal_day(c_tenant, c_school, v_sun);
    PERFORM pg_temp.chk('CAL-A10 a declared working Sunday is a working day',
        r.day_type = 'working' AND r.is_working, format('%s / working=%s', r.day_type, r.is_working));

    SELECT * INTO r FROM pg_temp.cal_day(c_tenant, c_school, NULL);
    PERFORM pg_temp.chk_txt('BELL-A11 day status with no date = today (school clock)', r.cal_date, to_char(CURRENT_DATE, 'YYYY-MM-DD'));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- B. Attendance vs the calendar, the gate, statuses ---------------';

    -- B1: the bell is silent on a declared holiday, so nobody should be able to
    -- take a register for it either.
    BEGIN
        v_n := pg_temp.att_save(c_tenant, c_school, c_user, v_hol, '8', 'A', pg_temp.att_items(s_cal || ':Present'));
        PERFORM pg_temp.chk('ATT-B1 attendance on a declared holiday refused', FALSE, format('accepted, saved %s', v_n));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('ATT-B1 attendance on a declared holiday refused', SQLERRM LIKE '%school holiday%', SQLERRM);
    END;

    -- B2: Saturday is now a weekly off.
    IF v_sat < CURRENT_DATE - 120 OR v_sat > CURRENT_DATE THEN
        RAISE EXCEPTION 'fixture: Saturday % outside window', v_sat;
    END IF;
    BEGIN
        v_n := pg_temp.att_save(c_tenant, c_school, c_user, v_sat, '8', 'A', pg_temp.att_items(s_cal || ':Present'));
        PERFORM pg_temp.chk('ATT-B2 attendance on a configured weekly off refused', FALSE, format('accepted, saved %s', v_n));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('ATT-B2 attendance on a configured weekly off refused', SQLERRM LIKE '%weekly off%', SQLERRM);
    END;

    -- B3: the declared working Sunday is a school day.
    BEGIN
        v_n := pg_temp.att_save(c_tenant, c_school, c_user, v_sun, '8', 'A', pg_temp.att_items(s_cal || ':Present'));
        PERFORM pg_temp.chk_eq('ATT-B3 attendance on a declared working Sunday accepted', v_n, 1);
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('ATT-B3 attendance on a declared working Sunday accepted', FALSE, SQLERRM);
    END;

    -- B4: a half day is a working day; the register is taken.
    v_n := pg_temp.att_save(c_tenant, c_school, c_user, v_half, '8', 'A', pg_temp.att_items(s_cal || ':Present'));
    PERFORM pg_temp.chk_eq('ATT-B4 attendance on a half day is accepted', v_n, 1);

    -- Back to the default pattern for the rest of the suite.
    PERFORM pg_temp.cal(c_tenant, c_school, 'SaveWeeklyOff', NULL, NULL, NULL, NULL, NULL, '0');

    -- B5..B8: class-teacher gate (core.sp_class_teacher_manage IsTeacher).
    PERFORM pg_temp.ct_assign(c_tenant, c_school, v_sec7a, v_vinod_staff);
    PERFORM pg_temp.chk('ATT-B5 Vinod is class teacher of 7-A',
        pg_temp.ct_is(c_tenant, c_school, v_vinod_user, '7', 'A'), '');
    PERFORM pg_temp.chk('ATT-B6 ...but not of 7-B',
        NOT pg_temp.ct_is(c_tenant, c_school, v_vinod_user, '7', 'B'), '');
    PERFORM pg_temp.chk('ATT-B7 a non-class-teacher fails the gate for 7-A',
        NOT pg_temp.ct_is(c_tenant, c_school, v_shiv_user, '7', 'A'), '');

    -- A teacher assigned while active and later deactivated (left the school).
    UPDATE academic.academic_class_sections SET class_teacher_staff_id = v_in_staff
     WHERE academic_class_section_id = v_sec7b;
    PERFORM pg_temp.chk('BUG ATT-B8 an inactive staff member fails the gate',
        NOT pg_temp.ct_is(c_tenant, c_school, v_in_user, '7', 'B'), 'IsTeacher ignores core.staff.is_active');
    UPDATE academic.academic_class_sections SET class_teacher_staff_id = NULL
     WHERE academic_class_section_id = v_sec7b;

    -- B9: the gate approves "7-A"; the save then accepts ANY student of the
    -- school, because sp_attendance_save has no class/section to check against.
    BEGIN
        v_n := pg_temp.att_save(c_tenant, c_school, v_vinod_user, v_mon, '7', 'A', pg_temp.att_items(s7b || ':Absent'));
        PERFORM pg_temp.chk('ATT-B9 7-A''s teacher cannot mark a 7-B student', FALSE, format('accepted, saved %s', v_n));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('ATT-B9 7-A''s teacher cannot mark a 7-B student', SQLERRM LIKE '%Not on the 7-A register%', SQLERRM);
    END;

    -- B10: an unknown status is silently dropped and the call still "succeeds".
    BEGIN
        v_n := pg_temp.att_save(c_tenant, c_school, c_user, v_mon, '8', 'A', pg_temp.att_items(s_cal || ':present'));
        PERFORM pg_temp.chk('ATT-B10 an unknown status is refused, not silently skipped', FALSE,
                            format('success with saved=%s', v_n));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('ATT-B10 an unknown status is refused, not silently skipped', SQLERRM LIKE '%Unknown attendance status%', SQLERRM);
    END;

    -- B11: "Late" is stored and counts as present.
    v_n := pg_temp.att_save(c_tenant, c_school, c_user, v_mon, '8', 'A', pg_temp.att_items(s_cal || ':Late'));
    SELECT status INTO v_txt FROM core.student_attendance WHERE student_id = s_cal AND attendance_date = v_mon::text;
    PERFORM pg_temp.chk_txt('ATT-B11 Late is stored as Late', v_txt, 'Late');

    -- B12: the attendance row snapshots the student's class/section on the day.
    SELECT class_name || '-' || section INTO v_txt FROM core.student_attendance
     WHERE student_id = s_cal AND attendance_date = v_mon::text;
    PERFORM pg_temp.chk_txt('ATT-B12 the row records the class-section of that day', v_txt, '8-A');

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- C. A month of registers -----------------------------------------';

    -- Day 1 and 2: 7-A as it stood.
    BEGIN
        v_n := pg_temp.att_save(c_tenant, c_school, c_user, d1, '7', 'A',
                 pg_temp.att_items(s1 || ':Present', s_mid || ':Present'));
        PERFORM pg_temp.chk('ATT-C0 a student not yet admitted on that day is refused', FALSE, format('accepted, saved %s', v_n));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('ATT-C0 a student not yet admitted on that day is refused', SQLERRM LIKE '%ZZ AE Chhavi%', SQLERRM);
    END;
    v_n := pg_temp.att_save(c_tenant, c_school, c_user, d1, '7', 'A',
             pg_temp.att_items(s1 || ':Present', s2 || ':Absent', s_move || ':Present', s_exit || ':Present'));
    PERFORM pg_temp.chk_eq('ATT-C1 day 1: the four students of 7-A marked', v_n, 4);
    PERFORM pg_temp.chk('ATT-C2 day 1 roster does not list the girl admitted on day 3',
        NOT pg_temp.att_roster_has(c_tenant, c_school, '7', 'A', d1, s_mid), '');
    v_n := pg_temp.att_save(c_tenant, c_school, c_user, d2, '7', 'A',
             pg_temp.att_items(s1 || ':Present', s2 || ':Present', s_move || ':Present', s_exit || ':Present'));

    -- Dev moves to 7-B (Edit Student), Eshan leaves the school on day 2.
    c := pg_temp.cur();
    CALL core.sp_student_update(c_tenant, c_school, c_user, s_move, p_student_name => 'ZZ AE Dev',
         p_class_name => '7', p_section => 'B', p_result => c);
    c := pg_temp.cur();
    CALL core.sp_student_exit('Exit', c_tenant, c_school, c_user, s_exit, 'Transfer', d2, 'ZZ moved city', c);

    -- Day 3 and 4.
    v_n := pg_temp.att_save(c_tenant, c_school, c_user, d3, '7', 'A',
             pg_temp.att_items(s1 || ':Present', s2 || ':Present', s_mid || ':Present'));
    v_n := pg_temp.att_save(c_tenant, c_school, c_user, d3, '7', 'B',
             pg_temp.att_items(s_move || ':Present', s7b || ':Present'));
    v_n := pg_temp.att_save(c_tenant, c_school, c_user, d4, '7', 'A',
             pg_temp.att_items(s1 || ':Present', s2 || ':Leave', s_mid || ':Present'));

    -- C3: a student who left on day 2 cannot be marked present on day 3.
    BEGIN
        v_n := pg_temp.att_save(c_tenant, c_school, c_user, d3, '7', 'A', pg_temp.att_items(s_exit || ':Present'));
        PERFORM pg_temp.chk('ATT-C3 a student who has left cannot be marked after leaving', FALSE, format('accepted, saved %s', v_n));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('ATT-C3 a student who has left cannot be marked after leaving', SQLERRM LIKE '%ZZ AE Eshan%', SQLERRM);
    END;
    -- ...and a moved student is refused on his old section's register.
    BEGIN
        v_n := pg_temp.att_save(c_tenant, c_school, c_user, d3, '7', 'A', pg_temp.att_items(s_move || ':Present'));
        PERFORM pg_temp.chk('ATT-C3b a moved student is refused on his old section''s register', FALSE, format('accepted, saved %s', v_n));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('ATT-C3b a moved student is refused on his old section''s register', SQLERRM LIKE '%ZZ AE Dev%', SQLERRM);
    END;
    DELETE FROM core.student_attendance WHERE student_id = s_exit AND attendance_date = d3::text;

    -- C4: ...but a back-dated roster for a day they were still here lists them.
    PERFORM pg_temp.chk('ATT-C4 back-dated roster lists a student who left later',
        pg_temp.att_roster_has(c_tenant, c_school, '7', 'A', d1, s_exit), '');
    PERFORM pg_temp.chk('ATT-C4b ...but not on a day after he left',
        NOT pg_temp.att_roster_has(c_tenant, c_school, '7', 'A', d3, s_exit), '');
    PERFORM pg_temp.chk('ATT-C4c a moved student is on his old section''s roster for a day he was marked there',
        pg_temp.att_roster_has(c_tenant, c_school, '7', 'A', d1, s_move)
        AND NOT pg_temp.att_roster_has(c_tenant, c_school, '7', 'B', d1, s_move), '');

    -- C5..C7: the mid-month joiner. Two school days since she joined, present on both.
    SELECT * INTO r FROM pg_temp.att_sum(c_tenant, c_school, s_mid);
    PERFORM pg_temp.chk_eq('ATT-C5 mid-month joiner: present on 2 days', r.pr, 2);
    PERFORM pg_temp.chk_eq('ATT-C6 mid-month joiner: school days count from admission', r.sd, 2);
    PERFORM pg_temp.chk_eq('ATT-C7 mid-month joiner: 100%, not 50%', r.pc, 100.0);

    -- C8: the section changer. 2 days in 7-A + 1 in 7-B, present on all 3.
    SELECT * INTO r FROM pg_temp.att_sum(c_tenant, c_school, s_move);
    PERFORM pg_temp.chk('ATT-C8 section changer: 3 of 3 days = 100%',
        r.pr = 3 AND r.sd = 3 AND r.pc = 100, format('%s present of %s school days = %s%%', r.pr, r.sd, r.pc));

    -- C9..C11: 7-A's register for the month.
    SELECT * INTO r FROM pg_temp.att_reg(c_tenant, c_school, '7', 'A', v_mm, v_my, s2);
    PERFORM pg_temp.chk_eq('ATT-C9 7-A held 4 registers this month', r.school_days, 4);
    PERFORM pg_temp.chk_eq('ATT-C10 Bhavna has 4 marks (A, P, P, L)', r.marks, 4);
    SELECT * INTO r FROM pg_temp.att_reg(c_tenant, c_school, '7', 'A', v_mm, v_my, s_mid);
    PERFORM pg_temp.chk_eq('ATT-C10b the register counts the joiner''s % over her 2 days', r.my_days, 2);
    SELECT * INTO r FROM pg_temp.att_reg(c_tenant, c_school, '7', 'A', v_mm, v_my, s_move);
    PERFORM pg_temp.chk('ATT-C10c 7-A''s register keeps Dev for his 2 days there',
        r.listed AND r.marks = 2 AND r.my_days = 2, format('listed=%s marks=%s days=%s', r.listed, r.marks, r.my_days));
    SELECT * INTO r FROM pg_temp.att_reg(c_tenant, c_school, '7', 'A', v_mm, v_my, s_exit);
    PERFORM pg_temp.chk('ATT-C11 the month''s register still lists the boy who left in it',
        r.listed AND r.marks = 2 AND r.my_days = 2, format('listed=%s marks=%s days=%s', r.listed, r.marks, r.my_days));

    -- C12: 7-B's register for the month shows only marks taken in 7-B.
    SELECT * INTO r FROM pg_temp.att_reg(c_tenant, c_school, '7', 'B', v_mm, v_my, s_move);
    PERFORM pg_temp.chk_eq('ATT-C12 7-B held 1 register this month', r.school_days, 1);
    PERFORM pg_temp.chk_eq('ATT-C13 7-B register shows Dev''s 7-B days only', r.marks, 1);
    PERFORM pg_temp.chk_eq('ATT-C13b ...and counts his % over that 1 day', r.my_days, 1);

    -- C14..C18: the class teacher corrects a mistake (Bhavna was there on day 1).
    v_n := pg_temp.att_save(c_tenant, c_school, v_vinod_user, d1, '7', 'A', pg_temp.att_items(s2 || ':Present'));
    SELECT COUNT(*) INTO v_n FROM core.student_attendance WHERE student_id = s2 AND attendance_date = d1::text;
    PERFORM pg_temp.chk_eq('ATT-C14 the correction keeps one row for the day', v_n, 1);
    SELECT status, marked_by, updated_by INTO r FROM core.student_attendance
     WHERE student_id = s2 AND attendance_date = d1::text;
    PERFORM pg_temp.chk('ATT-C15 the row shows who first marked and who corrected it',
        r.status = 'Present' AND r.marked_by = c_user AND r.updated_by = v_vinod_user,
        format('status=%s marked_by=%s updated_by=%s', r.status, r.marked_by, r.updated_by));
    SELECT COUNT(*) INTO v_n FROM core.student_attendance_history
     WHERE student_id = s2 AND attendance_date = d1::text
       AND old_status = 'Absent' AND new_status = 'Present' AND changed_by = v_vinod_user;
    PERFORM pg_temp.chk_eq('ATT-C16 history keeps Absent -> Present, by whom, when', v_n, 1);

    -- The page re-posts the whole roster; an unchanged mark should not be
    -- re-stamped as "changed by" the last person to press Save.
    v_n := pg_temp.att_save(c_tenant, c_school, v_shiv_user, d1, '7', 'A', pg_temp.att_items(s1 || ':Present'));
    SELECT updated_by INTO v_id FROM core.student_attendance WHERE student_id = s1 AND attendance_date = d1::text;
    PERFORM pg_temp.chk('ATT-C17 re-saving an unchanged mark does not rewrite who changed it',
        v_id IS NULL, format('updated_by=%s', COALESCE(v_id::text, 'NULL')));
    SELECT COUNT(*) INTO v_n FROM core.student_attendance_history WHERE student_id = s1;
    PERFORM pg_temp.chk_eq('ATT-C17b ...and writes no history row', v_n, 0);

    SELECT * INTO r FROM pg_temp.att_sum(c_tenant, c_school, s2);
    PERFORM pg_temp.chk('ATT-C18 Bhavna after the fix: 3 P, 0 A, 1 L of 4 = 75%',
        r.pr = 3 AND r.ab = 0 AND r.lv = 1 AND r.sd = 4 AND r.pc = 75.0,
        format('P=%s A=%s L=%s days=%s pct=%s', r.pr, r.ab, r.lv, r.sd, r.pc));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- D. Exam create / schedule ---------------------------------------';

    wd_n  := pg_temp.next_working(c_tenant, c_school, CURRENT_DATE + 60);
    wd_x1 := pg_temp.next_working(c_tenant, c_school, CURRENT_DATE + 20);
    wd_x2 := pg_temp.next_working(c_tenant, c_school, wd_x1 + 1);
    wd_y1 := pg_temp.next_working(c_tenant, c_school, CURRENT_DATE + 40);
    wd_y2 := pg_temp.next_working(c_tenant, c_school, wd_y1 + 1);

    -- D1: the happy path. The clash check at the end of SaveExam calls
    -- to_char(exam_date, ...) on what is now a varchar column.
    BEGIN
        v_txt := pg_temp.exam_save(c_tenant, c_school, v_year, NULL, 'ZZ Weekly Test', wd_n, wd_n + 2,
                   jsonb_build_array(pg_temp.ex_cls(v_cls7, jsonb_build_array(
                       pg_temp.ex_sub(sub_m, wd_n, '09:00', '10:00')))));
        PERFORM pg_temp.chk_txt('EXM-D1 a valid exam can be created', v_txt, 'Exam saved as draft.');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('EXM-D1 a valid exam can be created', FALSE, SQLERRM);
    END;

    -- D2..D12: each validation fires with its own message (they run before the crash).
    BEGIN PERFORM pg_temp.exam_save(c_tenant, c_school, v_year, NULL, '   ', CURRENT_DATE, CURRENT_DATE, '[]');
          PERFORM pg_temp.chk('EXM-D2 blank exam name refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('EXM-D2 blank exam name refused', SQLERRM LIKE '%exam name%', SQLERRM); END;

    BEGIN PERFORM pg_temp.exam_save(c_tenant, c_school, v_year, NULL, 'ZZ Back', CURRENT_DATE + 5, CURRENT_DATE, '[]');
          PERFORM pg_temp.chk('EXM-D3 end before start refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('EXM-D3 end before start refused', SQLERRM LIKE '%before the start%', SQLERRM); END;

    BEGIN PERFORM pg_temp.exam_save(c_tenant, c_school, v_year, NULL, 'ZZ Empty', CURRENT_DATE, CURRENT_DATE + 1, '[]');
          PERFORM pg_temp.chk('EXM-D4 an exam with no class refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('EXM-D4 an exam with no class refused', SQLERRM LIKE '%at least one class%', SQLERRM); END;

    BEGIN PERFORM pg_temp.exam_save(c_tenant, c_school, v_year, NULL, 'ZZ Art', CURRENT_DATE, CURRENT_DATE + 1,
              jsonb_build_array(pg_temp.ex_cls(v_cls7, jsonb_build_array(pg_temp.ex_sub(sub_art, CURRENT_DATE, '09:00', '10:00')))));
          PERFORM pg_temp.chk('EXM-D5 a subject the class does not study refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('EXM-D5 a subject the class does not study refused', SQLERRM LIKE '%is not a subject of%', SQLERRM); END;

    BEGIN PERFORM pg_temp.exam_save(c_tenant, c_school, v_year, NULL, 'ZZ Foreign Sub', CURRENT_DATE, CURRENT_DATE + 1,
              jsonb_build_array(pg_temp.ex_cls(v_cls7, jsonb_build_array(pg_temp.ex_sub(v_ot_subject, CURRENT_DATE, '09:00', '10:00')))));
          PERFORM pg_temp.chk('EXM-D6 another school''s subject refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('EXM-D6 another school''s subject refused', SQLERRM LIKE '%subject does not belong%', SQLERRM); END;

    BEGIN PERFORM pg_temp.exam_save(c_tenant, c_school, v_year, NULL, 'ZZ Foreign Cls', CURRENT_DATE, CURRENT_DATE + 1,
              jsonb_build_array(pg_temp.ex_cls(v_ot_class, jsonb_build_array(pg_temp.ex_sub(sub_m, CURRENT_DATE, '09:00', '10:00')))));
          PERFORM pg_temp.chk('EXM-D7 another school''s class refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('EXM-D7 another school''s class refused', SQLERRM LIKE '%class does not belong%', SQLERRM); END;

    BEGIN PERFORM pg_temp.exam_save(c_tenant, c_school, v_year, NULL, 'ZZ Pass', CURRENT_DATE, CURRENT_DATE + 1,
              jsonb_build_array(pg_temp.ex_cls(v_cls7, jsonb_build_array(pg_temp.ex_sub(sub_m, CURRENT_DATE, '09:00', '10:00', 50, 60)))));
          PERFORM pg_temp.chk('EXM-D8 pass marks above max refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('EXM-D8 pass marks above max refused', SQLERRM LIKE '%cannot be more than its max%', SQLERRM); END;

    BEGIN PERFORM pg_temp.exam_save(c_tenant, c_school, v_year, NULL, 'ZZ Max0', CURRENT_DATE, CURRENT_DATE + 1,
              jsonb_build_array(pg_temp.ex_cls(v_cls7, jsonb_build_array(pg_temp.ex_sub(sub_m, CURRENT_DATE, '09:00', '10:00', 0, 0)))));
          PERFORM pg_temp.chk('EXM-D9 max marks 0 refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('EXM-D9 max marks 0 refused', SQLERRM LIKE '%must be more than 0%', SQLERRM); END;

    BEGIN PERFORM pg_temp.exam_save(c_tenant, c_school, v_year, NULL, 'ZZ Outside', CURRENT_DATE, CURRENT_DATE + 1,
              jsonb_build_array(pg_temp.ex_cls(v_cls7, jsonb_build_array(pg_temp.ex_sub(sub_m, CURRENT_DATE + 9, '09:00', '10:00')))));
          PERFORM pg_temp.chk('EXM-D10 a paper outside the exam dates refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('EXM-D10 a paper outside the exam dates refused', SQLERRM LIKE '%outside the exam dates%', SQLERRM); END;

    BEGIN PERFORM pg_temp.exam_save(c_tenant, c_school, v_year, NULL, 'ZZ Times', CURRENT_DATE, CURRENT_DATE + 1,
              jsonb_build_array(pg_temp.ex_cls(v_cls7, jsonb_build_array(pg_temp.ex_sub(sub_m, CURRENT_DATE, '11:00', '10:00')))));
          PERFORM pg_temp.chk('EXM-D11 finish time before start refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('EXM-D11 finish time before start refused', SQLERRM LIKE '%must be after its start%', SQLERRM); END;

    BEGIN PERFORM pg_temp.exam_save(c_tenant, c_school, v_year, NULL, 'ZZ NoSubs', CURRENT_DATE, CURRENT_DATE + 1,
              jsonb_build_array(pg_temp.ex_cls(v_cls7, '[]'::jsonb)));
          PERFORM pg_temp.chk('EXM-D12 a class with no papers refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('EXM-D12 a class with no papers refused', SQLERRM LIKE '%no subjects on its datesheet%', SQLERRM); END;

    -- D13: two papers for one class at the same time get the friendly clash
    -- message (today the same to_char crash).
    BEGIN PERFORM pg_temp.exam_save(c_tenant, c_school, v_year, NULL, 'ZZ Clash', wd_n, wd_n + 1,
              jsonb_build_array(pg_temp.ex_cls(v_cls7, jsonb_build_array(
                  pg_temp.ex_sub(sub_m,  wd_n, '09:00', '11:00'),
                  pg_temp.ex_sub(sub_sc, wd_n, '10:00', '12:00')))));
          PERFORM pg_temp.chk('EXM-D13 overlapping papers refused with the clash message', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('EXM-D13 overlapping papers refused with the clash message',
                                   SQLERRM LIKE '%at the same time%', SQLERRM); END;

    -- D19/D20: no paper on a day the School Calendar has the school shut.
    BEGIN PERFORM pg_temp.exam_save(c_tenant, c_school, v_year, NULL, 'ZZ Holiday Paper', v_hol, v_hol,
              jsonb_build_array(pg_temp.ex_cls(v_cls7, jsonb_build_array(pg_temp.ex_sub(sub_m, v_hol, '09:00', '10:00')))));
          PERFORM pg_temp.chk('EXM-D19 a paper on a declared holiday refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('EXM-D19 a paper on a declared holiday refused', SQLERRM LIKE '%school is closed%', SQLERRM); END;
    BEGIN PERFORM pg_temp.exam_save(c_tenant, c_school, v_year, NULL, 'ZZ Sunday Paper', v_sun - 7, v_sun - 7,
              jsonb_build_array(pg_temp.ex_cls(v_cls7, jsonb_build_array(pg_temp.ex_sub(sub_m, v_sun - 7, '09:00', '10:00')))));
          PERFORM pg_temp.chk('EXM-D20 a paper on the weekly off (Sunday) refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('EXM-D20 a paper on the weekly off (Sunday) refused', SQLERRM LIKE '%school is closed%', SQLERRM); END;

    -- The exams the rest of the suite uses, inserted as SaveExam would store them.
    INSERT INTO academic.exams(tenant_id, school_id, academic_year_id, exam_name, exam_type, start_date, end_date, status, created_by)
    VALUES (c_tenant, c_school, v_year, 'ZZ Half Yearly', 'Term', (CURRENT_DATE + 20)::text, (CURRENT_DATE + 40)::text, 'Published', c_user)
    RETURNING exam_id INTO ex_x;
    INSERT INTO academic.exam_subjects(tenant_id, school_id, exam_id, academic_class_id, subject_id, exam_date, start_time, end_time, max_marks, pass_marks, display_order)
    VALUES (c_tenant, c_school, ex_x, v_cls6, sub_m,  wd_x1::text, '09:00', '12:00',  80, 26, 1),
           (c_tenant, c_school, ex_x, v_cls7, sub_m,  wd_x1::text, '09:00', '12:00', 100, 33, 1),
           (c_tenant, c_school, ex_x, v_cls7, sub_sc, wd_x2::text, '09:00', '12:00', 100, 33, 2),
           (c_tenant, c_school, ex_x, v_cls8, sub_m,  wd_x1::text, '09:00', '12:00', 100, 33, 1);
    INSERT INTO academic.exam_class_sections(tenant_id, school_id, exam_id, academic_class_id, section)
    VALUES (c_tenant, c_school, ex_x, v_cls7, 'A');      -- class 7: section A only

    -- D14: a second exam for 7-B in the same slot is not a clash (different children).
    INSERT INTO academic.exams(tenant_id, school_id, academic_year_id, exam_name, exam_type, start_date, end_date, status, created_by)
    VALUES (c_tenant, c_school, v_year, 'ZZ 7B Retest', 'Unit', (CURRENT_DATE + 20)::text, (CURRENT_DATE + 20)::text, 'Published', c_user)
    RETURNING exam_id INTO ex_z;
    INSERT INTO academic.exam_subjects(tenant_id, school_id, exam_id, academic_class_id, subject_id, exam_date, start_time, end_time, max_marks, pass_marks, display_order)
    VALUES (c_tenant, c_school, ex_z, v_cls7, sub_sc, wd_x1::text, '10:00', '11:00', 50, 17, 1);
    INSERT INTO academic.exam_class_sections(tenant_id, school_id, exam_id, academic_class_id, section)
    VALUES (c_tenant, c_school, ex_z, v_cls7, 'B');
    PERFORM pg_temp.chk('EXM-D14 datesheet: 7-A and 7-B papers in one slot are not a clash',
        pg_temp.ds_clash(c_tenant, c_school, ex_x, v_cls7, 'ZZ Maths') = FALSE, '');

    -- D15: a whole-class paper in that slot IS a clash with 7-A's Maths.
    INSERT INTO academic.exams(tenant_id, school_id, academic_year_id, exam_name, exam_type, start_date, end_date, status, created_by)
    VALUES (c_tenant, c_school, v_year, 'ZZ Surprise Quiz', 'Unit', (CURRENT_DATE + 20)::text, (CURRENT_DATE + 20)::text, 'Published', c_user)
    RETURNING exam_id INTO ex_w;
    INSERT INTO academic.exam_subjects(tenant_id, school_id, exam_id, academic_class_id, subject_id, exam_date, start_time, end_time, max_marks, pass_marks, display_order)
    VALUES (c_tenant, c_school, ex_w, v_cls7, sub_sc, wd_x1::text, '10:00', '11:00', 20, 7, 1);
    PERFORM pg_temp.chk('EXM-D15 datesheet flags a whole-class paper overlapping 7-A''s Maths',
        pg_temp.ds_clash(c_tenant, c_school, ex_x, v_cls7, 'ZZ Maths') = TRUE, '');
    UPDATE academic.exams SET is_deleted = TRUE WHERE exam_id IN (ex_w, ex_z);

    -- D16: duplicate exam name in the same session refused.
    BEGIN PERFORM pg_temp.exam_save(c_tenant, c_school, v_year, NULL, 'zz half yearly', CURRENT_DATE, CURRENT_DATE + 1,
              jsonb_build_array(pg_temp.ex_cls(v_cls7, jsonb_build_array(pg_temp.ex_sub(sub_m, CURRENT_DATE, '09:00', '10:00')))));
          PERFORM pg_temp.chk('EXM-D16 duplicate exam name (any case) refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('EXM-D16 duplicate exam name (any case) refused', SQLERRM LIKE '%already exists%', SQLERRM); END;

    -- D17/D18: status rules.
    BEGIN PERFORM pg_temp.exam_op(c_tenant, c_school, 'SetStatus', ex_x, 'Closed');
          PERFORM pg_temp.chk('EXM-D17 an unknown status refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('EXM-D17 an unknown status refused', SQLERRM LIKE '%Draft or Published%', SQLERRM); END;

    INSERT INTO academic.exams(tenant_id, school_id, academic_year_id, exam_name, exam_type, start_date, end_date, status, created_by)
    VALUES (c_tenant, c_school, v_year, 'ZZ Draft Test', 'Unit', (CURRENT_DATE + 50)::text, (CURRENT_DATE + 51)::text, 'Draft', c_user)
    RETURNING exam_id INTO ex_d;
    BEGIN PERFORM pg_temp.exam_op(c_tenant, c_school, 'SetStatus', ex_d, 'Published');
          PERFORM pg_temp.chk('EXM-D18 publishing an exam with no papers refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('EXM-D18 publishing an exam with no papers refused', SQLERRM LIKE '%nothing to publish%', SQLERRM); END;
    INSERT INTO academic.exam_subjects(tenant_id, school_id, exam_id, academic_class_id, subject_id, exam_date, start_time, end_time, max_marks, pass_marks, display_order)
    VALUES (c_tenant, c_school, ex_d, v_cls7, sub_m, (CURRENT_DATE + 50)::text, '09:00', '10:00', 25, 8, 1);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- E. Marks entry --------------------------------------------------';

    PERFORM pg_temp.chk_txt('EXM-E1 class 7 sheets offer only the exam''s section (A)',
        pg_temp.setup_secs(c_tenant, c_school, ex_x, v_cls7), 'A');

    BEGIN PERFORM pg_temp.marks_save(c_tenant, c_school, c_user, ex_x, v_cls7, sub_m, 'A', jsonb_build_array(pg_temp.mk(s1, '100.01')));
          PERFORM pg_temp.chk('EXM-E2 100.01 out of 100 refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('EXM-E2 100.01 out of 100 refused', SQLERRM LIKE '%between 0 and%', SQLERRM); END;

    BEGIN PERFORM pg_temp.marks_save(c_tenant, c_school, c_user, ex_x, v_cls7, sub_m, 'A', jsonb_build_array(pg_temp.mk(s1, 'abc')));
          PERFORM pg_temp.chk('EXM-E3 non-numeric marks refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('EXM-E3 non-numeric marks refused', TRUE, SQLERRM); END;

    BEGIN PERFORM pg_temp.marks_save(c_tenant, c_school, c_user, ex_x, v_cls7, sub_m, 'A', jsonb_build_array(pg_temp.mk(s_exit, '50')));
          PERFORM pg_temp.chk('EXM-E4 a student who left cannot get marks', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('EXM-E4 a student who left cannot get marks', SQLERRM LIKE '%not enrolled%', SQLERRM); END;

    BEGIN PERFORM pg_temp.marks_save(c_tenant, c_school, c_user, ex_x, v_cls7, sub_m, 'A', jsonb_build_array(pg_temp.mk(s6, '50')));
          PERFORM pg_temp.chk('EXM-E5 a class-6 student on the 7-A sheet refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('EXM-E5 a class-6 student on the 7-A sheet refused', SQLERRM LIKE '%not enrolled%', SQLERRM); END;

    BEGIN PERFORM pg_temp.marks_save(c_tenant, c_school, c_user, ex_x, v_cls7, sub_m, 'A', jsonb_build_array(pg_temp.mk(v_ot_student, '50')));
          PERFORM pg_temp.chk('EXM-E6 another school''s student refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('EXM-E6 another school''s student refused', SQLERRM LIKE '%not enrolled%', SQLERRM); END;

    -- E7..E10: a real sheet. Full marks, a half mark, a blank. (Dev has moved to
    -- 7-B, so he is no longer on the 7-A sheet - see E16.)
    BEGIN PERFORM pg_temp.marks_save(c_tenant, c_school, c_user, ex_x, v_cls7, sub_m, 'A', jsonb_build_array(pg_temp.mk(s_move, '50')));
          PERFORM pg_temp.chk('EXM-E7a a student moved to 7-B is refused on the 7-A sheet', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('EXM-E7a a student moved to 7-B is refused on the 7-A sheet', SQLERRM LIKE '%not enrolled%', SQLERRM); END;
    v_n := pg_temp.marks_save(c_tenant, c_school, c_user, ex_x, v_cls7, sub_m, 'A', jsonb_build_array(
             pg_temp.mk(s1, '100'), pg_temp.mk(s2, '33.5'), pg_temp.mk(s_mid, '')));
    PERFORM pg_temp.chk_eq('EXM-E7 three rows saved as draft', v_n, 3);
    SELECT marks_obtained INTO v_dec FROM academic.exam_marks WHERE exam_id = ex_x AND subject_id = sub_m AND student_id = s1;
    PERFORM pg_temp.chk_eq('EXM-E8 full marks (= max) accepted', v_dec, 100);
    SELECT marks_obtained INTO v_dec FROM academic.exam_marks WHERE exam_id = ex_x AND subject_id = sub_m AND student_id = s2;
    PERFORM pg_temp.chk_eq('EXM-E9 a half mark is kept exactly', v_dec, 33.5);
    -- An absentee who was also (wrongly) given marks, on the Science sheet.
    v_n := pg_temp.marks_save(c_tenant, c_school, c_user, ex_x, v_cls7, sub_sc, 'A', jsonb_build_array(pg_temp.mk(s_mid, '60', TRUE)));
    SELECT is_absent, marks_obtained INTO r FROM academic.exam_marks WHERE exam_id = ex_x AND subject_id = sub_sc AND student_id = s_mid;
    PERFORM pg_temp.chk('EXM-E10 absent wins over marks typed for an absentee',
        r.is_absent AND r.marks_obtained IS NULL, format('absent=%s marks=%s', r.is_absent, r.marks_obtained));

    -- E11: finalise. The dialog says unmarked students become Absent; a blank
    -- cell that was saved as a draft is just as unmarked.
    v_n := pg_temp.marks_save(c_tenant, c_school, c_user, ex_x, v_cls7, sub_m, 'A', '[]'::jsonb, TRUE);
    SELECT is_absent, marks_obtained INTO r FROM academic.exam_marks WHERE exam_id = ex_x AND subject_id = sub_m AND student_id = s_mid;
    PERFORM pg_temp.chk('EXM-E11 finalising records a blank draft mark as Absent',
        COALESCE(r.is_absent, FALSE), format('absent=%s marks=%s', r.is_absent, COALESCE(r.marks_obtained::text, 'NULL')));

    -- E11b: an exam with a finalised sheet cannot be deleted (it can be unpublished).
    BEGIN PERFORM pg_temp.exam_op(c_tenant, c_school, 'DeleteExam', ex_x);
          PERFORM pg_temp.chk('EXM-E11b an exam with finalised sheets cannot be deleted', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('EXM-E11b an exam with finalised sheets cannot be deleted', SQLERRM LIKE '%finalised mark sheets%', SQLERRM); END;

    -- E12..E14: reopen, correct, and see what the audit trail keeps.
    v_txt := pg_temp.reopen(c_tenant, c_school, ex_x, v_cls7, sub_m, 'A');
    SELECT reopened_by INTO v_id FROM academic.exam_mark_sheets
     WHERE exam_id = ex_x AND academic_class_id = v_cls7 AND subject_id = sub_m AND section = 'A';
    PERFORM pg_temp.chk_eq('EXM-E12 the sheet records who reopened it', v_id, c_user);
    v_n := pg_temp.marks_save(c_tenant, c_school, v_vinod_user, ex_x, v_cls7, sub_m, 'A', jsonb_build_array(pg_temp.mk(s1, '90')));
    SELECT marks_obtained, created_by, updated_by INTO r FROM academic.exam_marks
     WHERE exam_id = ex_x AND subject_id = sub_m AND student_id = s1;
    PERFORM pg_temp.chk('EXM-E13 the mark row shows who entered and who changed it',
        r.marks_obtained = 90 AND r.created_by = c_user AND r.updated_by = v_vinod_user,
        format('marks=%s created_by=%s updated_by=%s', r.marks_obtained, r.created_by, r.updated_by));
    SELECT COUNT(*) INTO v_n FROM academic.exam_marks_history
     WHERE exam_id = ex_x AND subject_id = sub_m AND student_id = s1
       AND old_marks = 100 AND new_marks = 90 AND changed_by = v_vinod_user;
    PERFORM pg_temp.chk_eq('EXM-E14 history keeps 100 -> 90, by whom, when', v_n, 1);
    SELECT COUNT(*) INTO v_n FROM academic.exam_marks_history
     WHERE exam_id = ex_x AND subject_id = sub_m AND student_id = s_mid AND old_absent = FALSE AND new_absent = TRUE;
    PERFORM pg_temp.chk_eq('EXM-E14b ...and the blank turned Absent at finalise', v_n, 1);
    -- Re-saving an unchanged mark writes no history and keeps updated_by.
    v_n := pg_temp.marks_save(c_tenant, c_school, v_shiv_user, ex_x, v_cls7, sub_m, 'A', jsonb_build_array(pg_temp.mk(s1, '90')));
    SELECT updated_by INTO v_id FROM academic.exam_marks WHERE exam_id = ex_x AND subject_id = sub_m AND student_id = s1;
    SELECT COUNT(*) INTO v_n FROM academic.exam_marks_history WHERE exam_id = ex_x AND subject_id = sub_m AND student_id = s1;
    PERFORM pg_temp.chk('EXM-E14c re-saving an unchanged mark changes nothing', v_id = v_vinod_user AND v_n = 1,
        format('updated_by=%s history rows=%s', v_id, v_n));

    -- E15: the exam targets 7-A only, so a 7-B sheet must not be accepted.
    BEGIN
        v_n := pg_temp.marks_save(c_tenant, c_school, c_user, ex_x, v_cls7, sub_m, 'B', jsonb_build_array(pg_temp.mk(s7b, '70')));
        PERFORM pg_temp.chk('EXM-E15 marks for a section the exam does not cover refused', FALSE, format('accepted, saved %s', v_n));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('EXM-E15 marks for a section the exam does not cover refused', SQLERRM LIKE '%not held for section B%', SQLERRM);
    END;
    DELETE FROM academic.exam_marks WHERE exam_id = ex_x AND student_id = s7b;

    -- E16: Dev moved to 7-B through Edit Student; sp_student_update moves the
    -- enrolment row too, so the exam sheets follow him.
    PERFORM pg_temp.chk('EXM-E16 a student moved to 7-B appears on 7-B''s sheet, not 7-A''s',
        pg_temp.sheet_has(c_tenant, c_school, ex_x, v_cls7, sub_sc, 'B', s_move)
        AND NOT pg_temp.sheet_has(c_tenant, c_school, ex_x, v_cls7, sub_sc, 'A', s_move),
        format('on 7-B=%s on 7-A=%s',
               pg_temp.sheet_has(c_tenant, c_school, ex_x, v_cls7, sub_sc, 'B', s_move),
               pg_temp.sheet_has(c_tenant, c_school, ex_x, v_cls7, sub_sc, 'A', s_move)));

    -- E17: a draft datesheet is not open for marks (the Marks Entry page hides
    -- it; the server should too).
    BEGIN
        v_n := pg_temp.marks_save(c_tenant, c_school, c_user, ex_d, v_cls7, sub_m, 'A', jsonb_build_array(pg_temp.mk(s1, '20')));
        PERFORM pg_temp.chk('EXM-E17 marks against a Draft exam refused', FALSE, format('accepted, saved %s', v_n));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('EXM-E17 marks against a Draft exam refused', SQLERRM LIKE '%still a draft%', SQLERRM);
    END;

    -- Science 7-A draft marks for the results section.
    v_n := pg_temp.marks_save(c_tenant, c_school, c_user, ex_x, v_cls7, sub_sc, 'A', jsonb_build_array(
             pg_temp.mk(s1, '50'), pg_temp.mk(s2, '40')));
    -- Class 6 Maths (out of 80).
    v_n := pg_temp.marks_save(c_tenant, c_school, c_user, ex_x, v_cls6, sub_m, 'A', jsonb_build_array(pg_temp.mk(s6, '60')));

    -- E18: dropping class 7 Science (it has marks) from the Half Yearly.
    BEGIN PERFORM pg_temp.exam_save(c_tenant, c_school, v_year, ex_x, 'ZZ Half Yearly', CURRENT_DATE + 20, CURRENT_DATE + 40,
              jsonb_build_array(
                  pg_temp.ex_cls(v_cls6, jsonb_build_array(pg_temp.ex_sub(sub_m, wd_x1, '09:00', '12:00', 80, 26))),
                  pg_temp.ex_cls(v_cls7, jsonb_build_array(pg_temp.ex_sub(sub_m, wd_x1, '09:00', '12:00')), '["A"]'),
                  pg_temp.ex_cls(v_cls8, jsonb_build_array(pg_temp.ex_sub(sub_m, wd_x1, '09:00', '12:00')))));
          PERFORM pg_temp.chk('EXM-E18 a paper that has marks cannot be removed', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('EXM-E18 a paper that has marks cannot be removed', SQLERRM LIKE '%cannot be removed%', SQLERRM); END;
    -- E19: lowering class 7 Maths to 50 when a 90 is on the sheet.
    BEGIN PERFORM pg_temp.exam_save(c_tenant, c_school, v_year, ex_x, 'ZZ Half Yearly', CURRENT_DATE + 20, CURRENT_DATE + 40,
              jsonb_build_array(
                  pg_temp.ex_cls(v_cls6, jsonb_build_array(pg_temp.ex_sub(sub_m, wd_x1, '09:00', '12:00', 80, 26))),
                  pg_temp.ex_cls(v_cls7, jsonb_build_array(pg_temp.ex_sub(sub_m, wd_x1, '09:00', '12:00', 50, 17),
                                                           pg_temp.ex_sub(sub_sc, wd_x2, '09:00', '12:00')), '["A"]'),
                  pg_temp.ex_cls(v_cls8, jsonb_build_array(pg_temp.ex_sub(sub_m, wd_x1, '09:00', '12:00')))));
          PERFORM pg_temp.chk('EXM-E19 max marks cannot go below a mark already entered', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('EXM-E19 max marks cannot go below a mark already entered', SQLERRM LIKE '%cannot go below 90%', SQLERRM); END;
    -- E20: the same edit with nothing broken is accepted (the save path works end to end).
    BEGIN
        v_txt := pg_temp.exam_save(c_tenant, c_school, v_year, ex_x, 'ZZ Half Yearly', CURRENT_DATE + 20, CURRENT_DATE + 40,
              jsonb_build_array(
                  pg_temp.ex_cls(v_cls6, jsonb_build_array(pg_temp.ex_sub(sub_m, wd_x1, '09:00', '12:00', 80, 26))),
                  pg_temp.ex_cls(v_cls7, jsonb_build_array(pg_temp.ex_sub(sub_m, wd_x1, '09:00', '12:00'),
                                                           pg_temp.ex_sub(sub_sc, wd_x2, '09:00', '12:00')), '["A"]'),
                  pg_temp.ex_cls(v_cls8, jsonb_build_array(pg_temp.ex_sub(sub_m, wd_x1, '09:00', '12:00')))));
        PERFORM pg_temp.chk_txt('EXM-E20 editing an exam with marks, nothing removed, is accepted', v_txt, 'Exam updated.');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('EXM-E20 editing an exam with marks, nothing removed, is accepted', FALSE, SQLERRM);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- F. Results ------------------------------------------------------';

    -- Results reach the student only once the exam's RESULTS are published
    -- (exam_results_publish.sql; that rule has its own suite). These checks are
    -- about the arithmetic, so the fixture flags the results published directly.
    UPDATE academic.exams SET results_status = 'Published' WHERE exam_id = ex_x;

    -- F1..F3: Aarav, class 7: Maths 90/100 + Science 50/100 = 140/200 = 70%.
    -- Maths is also on class 6's and class 8's datesheet in the same exam.
    SELECT * INTO r FROM pg_temp.res(c_tenant, c_school, s1, ex_x);
    PERFORM pg_temp.chk_eq('EXM-F1 multi-class exam: each paper counted once', r.subjects, 2);
    PERFORM pg_temp.chk_eq('EXM-F2 multi-class exam: total out of 200', r.total, 200);
    PERFORM pg_temp.chk_eq('EXM-F3 multi-class exam: 70%', r.pct, 70.0);

    -- F4: Gita, class 6: 60 out of class 6's 80, not out of class 7's 100.
    SELECT * INTO r FROM pg_temp.res(c_tenant, c_school, s6, ex_x);
    PERFORM pg_temp.chk('EXM-F4 class 6 Maths is out of class 6''s max (80) = 75%',
        r.subjects = 1 AND r.total = 80 AND r.pct = 75.0,
        format('subjects=%s obtained=%s total=%s pct=%s', r.subjects, r.obtained, r.total, r.pct));

    -- F5/F6: a paper removed from the datesheet after marks were entered.
    INSERT INTO academic.exams(tenant_id, school_id, academic_year_id, exam_name, exam_type, start_date, end_date, status, created_by)
    VALUES (c_tenant, c_school, v_year, 'ZZ Unit Test 2', 'Unit', wd_y1::text, wd_y2::text, 'Published', c_user)
    RETURNING exam_id INTO ex_y;
    INSERT INTO academic.exam_subjects(tenant_id, school_id, exam_id, academic_class_id, subject_id, exam_date, start_time, end_time, max_marks, pass_marks, display_order)
    VALUES (c_tenant, c_school, ex_y, v_cls7, sub_m,  wd_y1::text, '09:00', '10:00', 100, 33, 1),
           (c_tenant, c_school, ex_y, v_cls7, sub_sc, wd_y2::text, '09:00', '10:00', 100, 33, 2);
    v_n := pg_temp.marks_save(c_tenant, c_school, c_user, ex_y, v_cls7, sub_m,  'A', jsonb_build_array(pg_temp.mk(s2, '30')));
    v_n := pg_temp.marks_save(c_tenant, c_school, c_user, ex_y, v_cls7, sub_sc, 'A', jsonb_build_array(pg_temp.mk(s2, '40')));
    UPDATE academic.exams SET results_status = 'Published' WHERE exam_id = ex_y;
    SELECT * INTO r FROM pg_temp.res(c_tenant, c_school, s2, ex_y);
    PERFORM pg_temp.chk('EXM-F5 before: 70/200 = 35%', r.total = 200 AND r.pct = 35.0,
        format('obtained=%s total=%s pct=%s', r.obtained, r.total, r.pct));
    -- SaveExam now refuses to drop Science (it has marks) - see E18. A paper row
    -- removed any other way (old data, a direct delete) must still not leak
    -- into the result.
    DELETE FROM academic.exam_subjects WHERE exam_id = ex_y AND academic_class_id = v_cls7 AND subject_id = sub_sc;
    SELECT * INTO r FROM pg_temp.res(c_tenant, c_school, s2, ex_y);
    PERFORM pg_temp.chk('EXM-F6 marks of a removed paper do not inflate the result (30/100)',
        r.obtained = 30 AND r.total = 100 AND r.pct = 30.0,
        format('obtained=%s total=%s pct=%s', r.obtained, r.total, r.pct));

    -- F7: an exam moved back to Draft disappears from the student's results.
    -- Published results must be pulled back before the datesheet can go to draft
    -- (exam_results_publish_tests C6); the flag is then set again so this checks
    -- that a draft datesheet hides the exam on its own.
    UPDATE academic.exams SET results_status = 'Unpublished' WHERE exam_id = ex_y;
    PERFORM pg_temp.exam_op(c_tenant, c_school, 'SetStatus', ex_y, 'Draft');
    UPDATE academic.exams SET results_status = 'Published' WHERE exam_id = ex_y;
    SELECT * INTO r FROM pg_temp.res(c_tenant, c_school, s2, ex_y);
    PERFORM pg_temp.chk_eq('EXM-F7 an exam moved back to Draft is hidden from results', r.exam_rows, 1);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- G. Timetable ----------------------------------------------------';

    PERFORM pg_temp.ps_save(c_tenant, c_school, '[
      {"name":"ZZ P1","start":"08:00","end":"08:40","type":"class"},
      {"name":"ZZ P2","start":"08:40","end":"09:20","type":"class"},
      {"name":"ZZ Break","start":"09:20","end":"09:35","type":"break"},
      {"name":"ZZ P3","start":"09:35","end":"10:15","type":"class"}]');
    SELECT seq INTO seq1    FROM academic.period_structure WHERE tenant_id = c_tenant AND school_id = c_school AND label = 'ZZ P1';
    SELECT seq INTO seq2    FROM academic.period_structure WHERE tenant_id = c_tenant AND school_id = c_school AND label = 'ZZ P2';
    SELECT seq INTO seq_brk FROM academic.period_structure WHERE tenant_id = c_tenant AND school_id = c_school AND label = 'ZZ Break';

    BEGIN
        v_txt := pg_temp.tt_save(c_tenant, c_school, v_sec7a, 1, seq1, v_ot_subject, v_vinod_staff);
        PERFORM pg_temp.chk('TT-G1 another school''s subject cannot be booked', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('TT-G1 another school''s subject cannot be booked', TRUE, SQLERRM); END;

    BEGIN
        v_txt := pg_temp.tt_save(c_tenant, c_school, v_sec7a, 1, seq1, sub_art, v_vinod_staff);
        PERFORM pg_temp.chk('TT-G2 a subject the class does not study cannot be booked', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('TT-G2 a subject the class does not study cannot be booked', TRUE, SQLERRM); END;

    BEGIN
        v_txt := pg_temp.tt_save(c_tenant, c_school, v_sec7a, 1, seq1, sub_m, v_ot_staff);
        PERFORM pg_temp.chk('TT-G3 another school''s teacher cannot be booked', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('TT-G3 another school''s teacher cannot be booked', TRUE, SQLERRM); END;

    BEGIN
        v_txt := pg_temp.tt_save(c_tenant, c_school, v_sec7a, 1, seq1, sub_m, v_in_staff);
        PERFORM pg_temp.chk('TT-G4 an inactive teacher cannot be booked', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('TT-G4 an inactive teacher cannot be booked', TRUE, SQLERRM); END;

    PERFORM pg_temp.chk_eq('TT-G5 the teacher picker lists teaching staff only',
        pg_temp.tt_setup_nonteaching(c_tenant, c_school), 0);

    -- G6: Sunday is the weekly off; the grid has no Sunday column.
    BEGIN
        v_txt := pg_temp.tt_save(c_tenant, c_school, v_sec7a, 0, seq1, sub_m, v_vinod_staff);
        PERFORM pg_temp.chk('TT-G6 a lesson on the weekly off (Sunday) refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('TT-G6 a lesson on the weekly off (Sunday) refused', TRUE, SQLERRM); END;
    DELETE FROM academic.timetable WHERE tenant_id = c_tenant AND school_id = c_school AND day_of_week = 0;
    DELETE FROM academic.timetable WHERE tenant_id = c_tenant AND school_id = c_school
       AND (subject_id IN (v_ot_subject, sub_art) OR staff_id IN (v_ot_staff, v_in_staff));

    BEGIN
        v_txt := pg_temp.tt_save(c_tenant, c_school, v_sec7a, 7, seq1, sub_m, v_vinod_staff);
        PERFORM pg_temp.chk('TT-G7 day 7 (no such weekday) refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('TT-G7 day 7 (no such weekday) refused', TRUE, SQLERRM); END;

    -- Half-day closing time must fall inside the school day (08:00-10:15 here).
    BEGIN PERFORM pg_temp.cal(c_tenant, c_school, 'SaveEntry', NULL, v_half, 'half_day', 'ZZ PTM', TIME '07:00', NULL);
          PERFORM pg_temp.chk('CAL-G0 a half day closing before school starts refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('CAL-G0 a half day closing before school starts refused', SQLERRM LIKE '%during the school day%', SQLERRM); END;
    v_txt := pg_temp.cal(c_tenant, c_school, 'SaveEntry', NULL, v_half, 'half_day', 'ZZ PTM', TIME '09:30', NULL);
    PERFORM pg_temp.chk_txt('CAL-G0b a half day closing at 09:30 accepted', v_txt, 'Calendar updated.');

    -- G8..G10: Monday P1 7-A = Vinod in room ZZ-101.
    v_txt := pg_temp.tt_save(c_tenant, c_school, v_sec7a, 1, seq1, sub_m, v_vinod_staff, 'ZZ-101');
    PERFORM pg_temp.chk_txt('TT-G8 Monday P1 booked for 7-A', v_txt, 'Period updated.');
    v_txt := pg_temp.tt_save(c_tenant, c_school, v_sec7a, 1, seq1, sub_m, v_vinod_staff, 'ZZ-101');
    PERFORM pg_temp.chk_txt('TT-G9 re-saving the same slot is not a clash with itself', v_txt, 'Period updated.');

    -- Shivam takes 8-A in the same slot, same room.
    BEGIN
        v_txt := pg_temp.tt_save(c_tenant, c_school, v_sec8a, 1, seq1, sub_m, v_shiv_staff, 'ZZ-101');
        PERFORM pg_temp.chk('TT-G10 two sections in one room in one period refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('TT-G10 two sections in one room in one period refused', TRUE, SQLERRM); END;
    PERFORM pg_temp.tt('ClearCell', c_tenant, c_school, v_sec8a, 1, seq1, NULL, NULL, NULL);

    -- G11: the same teacher on a different day is fine.
    v_txt := pg_temp.tt_save(c_tenant, c_school, v_sec8a, 2, seq1, sub_m, v_vinod_staff);
    PERFORM pg_temp.chk_txt('TT-G11 Vinod can take 8-A on Tuesday P1', v_txt, 'Period updated.');

    -- G12: Copy Monday across the week. Mon-Sat minus Monday = 5 days x 2 lessons;
    -- Tuesday P1 is skipped because Vinod is in 8-A then.
    v_txt := pg_temp.tt_save(c_tenant, c_school, v_sec7a, 1, seq2, sub_sc, v_shiv_staff);
    r := pg_temp.tt('CopyDay', c_tenant, c_school, v_sec7a, 1, NULL, NULL, NULL, NULL);
    PERFORM pg_temp.chk('TT-G12 Copy Day: 9 copied, 1 skipped (teacher busy)',
        r.copied = 9 AND r.skipped = 1, r.message);
    SELECT COUNT(*) INTO v_n FROM academic.timetable
     WHERE tenant_id = c_tenant AND school_id = c_school AND academic_class_section_id = v_sec7a AND day_of_week = 0;
    PERFORM pg_temp.chk_eq('TT-G13 Copy Day leaves the weekly off empty', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM academic.timetable
     WHERE tenant_id = c_tenant AND school_id = c_school AND day_of_week = 2 AND period_seq = seq1 AND staff_id = v_vinod_staff;
    PERFORM pg_temp.chk_eq('TT-G14 Vinod is still booked once on Tuesday P1', v_n, 1);

    -- G15: the teacher view shows both sections.
    SELECT COUNT(DISTINCT academic_class_section_id) INTO v_n FROM academic.timetable
     WHERE tenant_id = c_tenant AND school_id = c_school AND staff_id = v_vinod_staff;
    PERFORM pg_temp.chk_eq('TT-G15 Vinod teaches two sections', v_n, 2);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- H. Scope and isolation ------------------------------------------';

    -- Attendance
    SELECT * INTO r FROM pg_temp.att_sum(o_tenant, o_school, s1);
    PERFORM pg_temp.chk_eq('ISO-H1 other school reads none of our student''s attendance', r.sd + r.pr, 0);
    SELECT * INTO r FROM pg_temp.att_reg(o_tenant, o_school, '7', 'A', v_mm, v_my, s1);
    PERFORM pg_temp.chk('ISO-H2 other school''s 7-A register does not list our student', NOT r.listed AND r.marks = 0, '');
    -- (v_mon: inside the other school's default 7-day window.)
    BEGIN
        v_n := pg_temp.att_save(o_tenant, o_school, c_user, v_mon, '7', 'A', pg_temp.att_items(s1 || ':Absent'));
        v_txt := 'accepted';
    EXCEPTION WHEN OTHERS THEN v_txt := SQLERRM; END;
    SELECT COUNT(*) INTO v_m FROM core.student_attendance WHERE student_id = s1 AND attendance_date = v_mon::text;
    PERFORM pg_temp.chk('ISO-H3 other school cannot mark our student', v_txt <> 'accepted' AND v_m = 0,
        format('%s, rows=%s', v_txt, v_m));
    BEGIN
        v_n := pg_temp.att_save(c_tenant, c_school, c_user, d1, '7', 'A', pg_temp.att_items(v_ot_student || ':Absent'));
        PERFORM pg_temp.chk('ISO-H4 we cannot mark the other school''s student', FALSE, format('accepted, saved %s', v_n));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('ISO-H4 we cannot mark the other school''s student', SQLERRM LIKE '%Not on the 7-A register%', SQLERRM);
    END;

    -- Calendar
    SELECT calendar_id INTO v_cal FROM academic.school_calendar
     WHERE tenant_id = c_tenant AND school_id = c_school AND calendar_date = v_hol::text;
    BEGIN PERFORM pg_temp.cal(o_tenant, o_school, 'DeleteEntry', v_cal, NULL, NULL, NULL, NULL, NULL);
          v_txt := 'accepted';
    EXCEPTION WHEN OTHERS THEN v_txt := SQLERRM; END;
    PERFORM pg_temp.chk('ISO-H5 other school cannot delete our holiday ("not found")',
        v_txt LIKE '%not found%' AND EXISTS (SELECT 1 FROM academic.school_calendar WHERE calendar_id = v_cal), v_txt);
    v_b := EXISTS (SELECT 1 FROM academic.school_calendar WHERE tenant_id = o_tenant AND school_id = o_school
                   AND calendar_date = v_hol::text AND day_type = 'holiday');
    SELECT * INTO r FROM pg_temp.cal_day(o_tenant, o_school, v_hol);
    PERFORM pg_temp.chk('ISO-H6 our holiday does not close the other school', (r.day_type = 'holiday') = v_b,
        format('their day: %s', r.day_type));

    -- Exams
    INSERT INTO academic.exams(tenant_id, school_id, academic_year_id, exam_name, exam_type, start_date, end_date, status, created_by)
    VALUES (o_tenant, o_school, v_ot_year, 'ZZ Their Exam', 'Term', (CURRENT_DATE + 20)::text, (CURRENT_DATE + 21)::text, 'Draft', c_user)
    RETURNING exam_id INTO v_ot_exam;
    PERFORM pg_temp.chk_eq('ISO-H7 we cannot read the other school''s exam', pg_temp.exam_get_rows(c_tenant, c_school, v_ot_exam), 0);
    BEGIN PERFORM pg_temp.exam_op(c_tenant, c_school, 'SetStatus', v_ot_exam, 'Draft');
          PERFORM pg_temp.chk('ISO-H8 we cannot change the other school''s exam status', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('ISO-H8 we cannot change the other school''s exam status', SQLERRM LIKE '%not found%', SQLERRM); END;
    BEGIN PERFORM pg_temp.exam_op(c_tenant, c_school, 'DeleteExam', v_ot_exam);
          PERFORM pg_temp.chk('ISO-H9 we cannot delete the other school''s exam', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('ISO-H9 we cannot delete the other school''s exam', SQLERRM LIKE '%not found%', SQLERRM); END;
    BEGIN PERFORM pg_temp.exam_save(c_tenant, c_school, v_year, v_ot_exam, 'ZZ Hijack', CURRENT_DATE, CURRENT_DATE + 1,
              jsonb_build_array(pg_temp.ex_cls(v_cls7, jsonb_build_array(pg_temp.ex_sub(sub_m, CURRENT_DATE, '09:00', '10:00')))));
          PERFORM pg_temp.chk('ISO-H10 we cannot edit the other school''s exam', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('ISO-H10 we cannot edit the other school''s exam', SQLERRM LIKE '%not found%', SQLERRM); END;
    PERFORM pg_temp.chk('ISO-H11 ...their exam is untouched',
        EXISTS (SELECT 1 FROM academic.exams WHERE exam_id = v_ot_exam AND exam_name = 'ZZ Their Exam' AND NOT is_deleted), '');
    BEGIN PERFORM pg_temp.marks_save(o_tenant, o_school, c_user, ex_x, v_cls7, sub_m, 'A', jsonb_build_array(pg_temp.mk(s1, '1')));
          PERFORM pg_temp.chk('ISO-H12 other school cannot enter marks on our exam', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('ISO-H12 other school cannot enter marks on our exam', SQLERRM LIKE '%not found%', SQLERRM); END;
    BEGIN PERFORM pg_temp.reopen(o_tenant, o_school, ex_x, v_cls7, sub_m, 'A');
          PERFORM pg_temp.chk('ISO-H13 other school cannot reopen our sheet', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('ISO-H13 other school cannot reopen our sheet', SQLERRM LIKE '%not found%', SQLERRM); END;
    SELECT * INTO r FROM pg_temp.res(o_tenant, o_school, s1, NULL);
    PERFORM pg_temp.chk_eq('ISO-H14 other school sees none of our student''s results', r.exam_rows, 0);
    PERFORM pg_temp.chk_txt('ISO-H15 the exam list does not name another school''s session',
        pg_temp.exam_year_name(c_tenant, c_school, v_ot_year), '');

    -- Timetable
    SELECT COUNT(*) INTO v_m FROM academic.timetable
     WHERE tenant_id = c_tenant AND school_id = c_school AND academic_class_section_id = v_sec7a;
    PERFORM pg_temp.tt('ClearCell', o_tenant, o_school, v_sec7a, 1, seq1, NULL, NULL, NULL);
    PERFORM pg_temp.tt('CopyDay',   o_tenant, o_school, v_sec7a, 3, NULL, NULL, NULL, NULL);
    SELECT COUNT(*) INTO v_n FROM academic.timetable
     WHERE tenant_id = c_tenant AND school_id = c_school AND academic_class_section_id = v_sec7a;
    PERFORM pg_temp.chk('ISO-H16 other school''s Clear/Copy leave our 7-A timetable alone', v_n = v_m,
        format('%s -> %s', v_m, v_n));
    PERFORM pg_temp.chk_eq('ISO-H17 other school reads nothing from our 7-A grid',
        pg_temp.tt_grid_rows(o_tenant, o_school, v_sec7a), 0);
    BEGIN
        v_txt := pg_temp.tt_save(o_tenant, o_school, v_sec7a, 4, seq1, sub_m, NULL);
        PERFORM pg_temp.chk('ISO-H18 other school cannot book our section', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('ISO-H18 other school cannot book our section', TRUE, SQLERRM); END;

    -- Platform scope
    BEGIN PERFORM pg_temp.att_save(1, 0, c_user, CURRENT_DATE, '7', 'A', pg_temp.att_items(s1 || ':Present'));
          PERFORM pg_temp.chk('ISO-H19 platform scope attendance save refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('ISO-H19 platform scope attendance save refused', TRUE, SQLERRM); END;
    BEGIN PERFORM pg_temp.cal(1, 0, 'SaveEntry', NULL, CURRENT_DATE, 'holiday', 'x', NULL, NULL);
          PERFORM pg_temp.chk('ISO-H20 platform scope calendar save refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('ISO-H20 platform scope calendar save refused', TRUE, SQLERRM); END;
    BEGIN PERFORM pg_temp.marks_save(24, 0, c_user, ex_x, v_cls7, sub_m, 'A', '[]'::jsonb);
          PERFORM pg_temp.chk('ISO-H21 schoolId 0 marks save refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('ISO-H21 schoolId 0 marks save refused', TRUE, SQLERRM); END;
END
$suite$;


DO $sum$
DECLARE p integer; f integer; b integer; r record;
BEGIN
    SELECT COUNT(*) FILTER (WHERE ok), COUNT(*) FILTER (WHERE NOT ok),
           COUNT(*) FILTER (WHERE NOT ok AND name LIKE 'BUG %') INTO p, f, b FROM _t;
    RAISE NOTICE '';
    RAISE NOTICE '========== RESULT: % passed, % failed (% of them BUG checks) ==========', p, f, b;
    IF f > 0 THEN
        RAISE NOTICE 'failures:';
        FOR r IN SELECT name, detail FROM _t WHERE NOT ok ORDER BY id LOOP
            RAISE NOTICE '   %  %', rpad(r.name, 62), r.detail;
        END LOOP;
    END IF;
    RAISE NOTICE '';
END
$sum$;

ROLLBACK;
