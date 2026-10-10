-- ============================================================================
-- Weekday bell schedules + calendar date ranges test suite.
--
-- Period Structure used to be ONE schedule per school. It is now a default
-- schedule plus an optional custom schedule per weekday (a short Saturday),
-- and the Timetable, Copy Day and the Smart Bell follow the day's schedule.
-- The School Calendar also takes a holiday as a date range.
--
-- Scenario: Sunrise Public School (tenant 24 / school 34) runs a 10-slot day
-- Monday to Friday and a short Saturday with an assembly and a Games period.
-- Lessons are booked, the Saturday is reshaped twice, the default gets a
-- morning assembly, Monday is copied across the week, and the office declares
-- a vacation week (a half day already sits inside it), then removes it.
--
-- Runs inside ONE transaction and ROLLS BACK.
--
--     psql ... -f weekday_schedules_tests.sql
--
-- COVERS
--   A. Migration - the existing schedule is the default, re-run safe, old calls work
--   B. Per-day schedules - save, read, validations, weekly off, Use default
--   C. Lessons follow their period by label, per day
--   D. Booking against the day's schedule (Timetable SaveCell / GetSetup)
--   E. Copy Day across days with different schedules
--   F. Calendar date ranges - add, skip, half-day hours per day, delete;
--      fn_school_day_type, attendance, leave days and exam papers over a range
--   G. Tenant isolation and platform scope (other school: tenant 23 / school 33)
-- ============================================================================

\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE TEMP TABLE _t(id serial, name text, ok boolean, detail text) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.chk(p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO _t(name, ok, detail) VALUES (p_name, COALESCE(p_ok, FALSE), p_detail);
    RAISE NOTICE '  [%] %  %', CASE WHEN COALESCE(p_ok, FALSE) THEN 'PASS' ELSE 'FAIL' END, rpad(p_name, 64), p_detail;
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

-- ── Period structure wrappers (same layout as SchoolSettingsService) ──
-- p_day NULL = the default schedule.
CREATE OR REPLACE FUNCTION pg_temp.ps_save(p_t int, p_s int, p_items text, p_day int DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c refcursor := pg_temp.cur(); r record;
BEGIN
    CALL academic.sp_school_admin_period_structure_manage('SavePeriodStructure', p_t, p_s, 39, p_items, c, p_day::smallint);
    FETCH c INTO r; CLOSE c;
    RETURN r.message;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.ps_use_default(p_t int, p_s int, p_day int)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c refcursor := pg_temp.cur(); r record;
BEGIN
    CALL academic.sp_school_admin_period_structure_manage('UseDefault', p_t, p_s, 39, NULL, c, p_day::smallint);
    FETCH c INTO r; CLOSE c;
    RETURN r.message;
END $$;

-- "seq:label@start-end/type;..." for GetPeriodStructure (p_day NULL = default).
CREATE OR REPLACE FUNCTION pg_temp.ps_get(p_t int, p_s int, p_day int DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c refcursor := pg_temp.cur(); r record; v text := '';
BEGIN
    CALL academic.sp_school_admin_period_structure_manage('GetPeriodStructure', p_t, p_s, 39, NULL, c, p_day::smallint);
    LOOP
        FETCH c INTO r; EXIT WHEN NOT FOUND;
        v := v || r.seq || ':' || r.label || '@' || r.start_time || '-' || r.end_time || '/' || r.period_type || ';';
    END LOOP;
    CLOSE c;
    RETURN v;
END $$;

-- The day_of_week values GetPeriodStructure returned ("d" for a default row).
CREATE OR REPLACE FUNCTION pg_temp.ps_get_days(p_t int, p_s int, p_day int)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c refcursor := pg_temp.cur(); r record; v text := '';
BEGIN
    CALL academic.sp_school_admin_period_structure_manage('GetPeriodStructure', p_t, p_s, 39, NULL, c, p_day::smallint);
    LOOP
        FETCH c INTO r; EXIT WHEN NOT FOUND;
        IF position(COALESCE(r.day_of_week::text, 'd') IN v) = 0 THEN
            v := v || COALESCE(r.day_of_week::text, 'd');
        END IF;
    END LOOP;
    CLOSE c;
    RETURN v;
END $$;

-- GetAllSchedules as "day:label;..." (d = default).
CREATE OR REPLACE FUNCTION pg_temp.ps_all(p_t int, p_s int)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c refcursor := pg_temp.cur(); r record; v text := '';
BEGIN
    CALL academic.sp_school_admin_period_structure_manage('GetAllSchedules', p_t, p_s, 39, NULL, c);
    LOOP
        FETCH c INTO r; EXIT WHEN NOT FOUND;
        v := v || COALESCE(r.day_of_week::text, 'd') || ':' || r.label || '@' || r.start_time || ';';
    END LOOP;
    CLOSE c;
    RETURN v;
END $$;

-- ── Subject wrapper (to map the subjects the timetable may use) ──
CREATE OR REPLACE FUNCTION pg_temp.subj_save(p_t int, p_s int, p_class int, p_items text)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE c refcursor := pg_temp.cur(); c2 refcursor := pg_temp.cur(); r record;
BEGIN
    CALL academic.sp_school_admin_subject_manage('SaveClassSubjects', p_t, p_s, 39, NULL, p_class, p_items, c, c2);
    FETCH c INTO r; CLOSE c; CLOSE c2;
    RETURN r.subject_count;
END $$;

-- ── Timetable wrappers (same positional layout as TimetableService) ──
CREATE OR REPLACE FUNCTION pg_temp.tt(p_op text, p_t int, p_s int, p_sec int, p_day int, p_seq int,
                                      p_subject int, p_staff int)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := pg_temp.cur(); c2 refcursor := pg_temp.cur();
        c3 refcursor := pg_temp.cur(); c4 refcursor := pg_temp.cur(); r record;
BEGIN
    CALL academic.sp_school_admin_timetable_manage(p_op, p_t, p_s, 39, NULL::int, p_sec,
         p_day::smallint, p_seq::smallint, p_subject, p_staff, NULL::varchar, c1, c2, c3, c4);
    FETCH c1 INTO r; CLOSE c1; CLOSE c2; CLOSE c3; CLOSE c4;
    RETURN to_jsonb(r);
END $$;

CREATE OR REPLACE FUNCTION pg_temp.tt_save(p_t int, p_s int, p_sec int, p_day int, p_seq int, p_subject int, p_staff int)
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    RETURN pg_temp.tt('SaveCell', p_t, p_s, p_sec, p_day, p_seq, p_subject, p_staff) ->> 'message';
END $$;

-- GetSetup result 1: how many periods it lists for one weekday.
CREATE OR REPLACE FUNCTION pg_temp.tt_setup_count(p_t int, p_s int, p_day int)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := pg_temp.cur(); c2 refcursor := pg_temp.cur();
        c3 refcursor := pg_temp.cur(); c4 refcursor := pg_temp.cur(); r record; n int := 0;
BEGIN
    CALL academic.sp_school_admin_timetable_manage('GetSetup', p_t, p_s, 39, NULL::int, NULL::int,
         NULL::smallint, NULL::smallint, NULL::int, NULL::int, NULL::varchar, c1, c2, c3, c4);
    LOOP FETCH c1 INTO r; EXIT WHEN NOT FOUND; IF r.day_of_week = p_day THEN n := n + 1; END IF; END LOOP;
    CLOSE c1; CLOSE c2; CLOSE c3; CLOSE c4;
    RETURN n;
END $$;

-- One section's lessons on one day as "seq:label;..." where the label comes from
-- the schedule that day runs on ("?" = the lesson sits on no period).
CREATE OR REPLACE FUNCTION pg_temp.lessons(p_t int, p_s int, p_sec int, p_day int)
RETURNS text LANGUAGE sql AS $$
    SELECT COALESCE(string_agg(t.period_seq || ':' || COALESCE(p.label, '?'), ';' ORDER BY t.period_seq), '')
    FROM academic.timetable t
    LEFT JOIN academic.fn_day_periods(p_t, p_s, p_day::smallint) p ON p.seq = t.period_seq
    WHERE t.tenant_id = p_t AND t.school_id = p_s
      AND t.academic_class_section_id = p_sec AND t.day_of_week = p_day
$$;

-- ── Calendar wrappers (same positional layout as SchoolCalendarService) ──
CREATE OR REPLACE FUNCTION pg_temp.cal(p_t int, p_s int, p_op text, p_from date, p_to date,
                                       p_type text DEFAULT NULL, p_title text DEFAULT NULL,
                                       p_half time DEFAULT NULL, p_weekly text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := pg_temp.cur(); c2 refcursor := pg_temp.cur(); r record;
BEGIN
    CALL academic.sp_school_admin_calendar_manage(p_op, p_t, p_s, 39, NULL, p_from, p_to,
         p_type, p_title, p_half, p_weekly, c1, c2);
    FETCH c1 INTO r; CLOSE c1; CLOSE c2;
    RETURN to_jsonb(r);
END $$;

CREATE OR REPLACE FUNCTION pg_temp.cal_count(p_t int, p_s int, p_from date, p_to date)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := pg_temp.cur(); c2 refcursor := pg_temp.cur(); r record; n int := 0;
BEGIN
    CALL academic.sp_school_admin_calendar_manage('GetCalendar', p_t, p_s, 39, NULL, p_from, p_to,
         NULL, NULL, NULL, NULL, c1, c2);
    LOOP FETCH c1 INTO r; EXIT WHEN NOT FOUND; n := n + 1; END LOOP;
    CLOSE c1; CLOSE c2;
    RETURN n;
END $$;

-- fn_school_day_type for every date in a range: "14:holiday,15:holiday,...".
CREATE OR REPLACE FUNCTION pg_temp.day_types(p_t int, p_s int, p_from date, p_to date)
RETURNS text LANGUAGE sql AS $$
    SELECT string_agg(to_char(d, 'DD') || ':' || academic.fn_school_day_type(p_t, p_s, d::date), ',' ORDER BY d)
    FROM generate_series(p_from, p_to, interval '1 day') d
$$;


DO $suite$
DECLARE
    c_tenant CONSTANT integer := 24;
    c_school CONSTANT integer := 34;
    c_user   CONSTANT integer := 39;
    o_tenant CONSTANT integer := 23;
    o_school CONSTANT integer := 33;

    -- Default day: 8 teaching periods, a break and lunch.
    c_default CONSTANT text := '[
      {"name":"P1","start":"08:00","end":"08:40","type":"class"},
      {"name":"P2","start":"08:40","end":"09:20","type":"class"},
      {"name":"P3","start":"09:20","end":"10:00","type":"class"},
      {"name":"Break","start":"10:00","end":"10:15","type":"break"},
      {"name":"P4","start":"10:15","end":"10:55","type":"class"},
      {"name":"P5","start":"10:55","end":"11:35","type":"class"},
      {"name":"Lunch","start":"11:35","end":"12:05","type":"lunch"},
      {"name":"P6","start":"12:05","end":"12:45","type":"class"},
      {"name":"P7","start":"12:45","end":"13:25","type":"class"},
      {"name":"P8","start":"13:25","end":"14:05","type":"class"}]';
    c_default_txt CONSTANT text :=
        '1:P1@08:00-08:40/class;2:P2@08:40-09:20/class;3:P3@09:20-10:00/class;4:Break@10:00-10:15/break;'
     || '5:P4@10:15-10:55/class;6:P5@10:55-11:35/class;7:Lunch@11:35-12:05/lunch;8:P6@12:05-12:45/class;'
     || '9:P7@12:45-13:25/class;10:P8@13:25-14:05/class;';

    -- Short Saturday: assembly, 4 periods, a break and a Games period, done by 12:00.
    c_sat CONSTANT text := '[
      {"name":"Assembly","start":"07:50","end":"08:00","type":"assembly"},
      {"name":"P1","start":"08:00","end":"08:40","type":"class"},
      {"name":"P2","start":"08:40","end":"09:20","type":"class"},
      {"name":"Break","start":"09:20","end":"09:35","type":"break"},
      {"name":"P3","start":"09:35","end":"10:15","type":"class"},
      {"name":"P4","start":"10:15","end":"10:55","type":"class"},
      {"name":"Games","start":"10:55","end":"12:00","type":"class"}]';
    c_sat_txt CONSTANT text :=
        '1:Assembly@07:50-08:00/assembly;2:P1@08:00-08:40/class;3:P2@08:40-09:20/class;4:Break@09:20-09:35/break;'
     || '5:P3@09:35-10:15/class;6:P4@10:15-10:55/class;7:Games@10:55-12:00/class;';

    v_year   integer;
    v_cls7   integer;
    v_cls8   integer;
    v_sec7a  integer;
    v_sec8a  integer;
    v_t1     integer;   -- active teaching staff
    v_t2     integer;
    v_math   integer;
    v_eng    integer;
    v_items  text;
    v_txt    text;
    v_n      integer;
    v_j      jsonb;
    v_def    text;      -- the default schedule as GetPeriodStructure prints it
    v_sat    text;
    v_ot_all text;      -- the other school's schedules before our tests
    c        refcursor;
    c2       refcursor;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '===== WEEKDAY SCHEDULES + CALENDAR RANGE TESTS =====';

    SELECT academic_year_id INTO v_year FROM academic.academic_years
     WHERE tenant_id = c_tenant AND school_id = c_school AND COALESCE(is_current, FALSE) AND NOT is_deleted LIMIT 1;
    SELECT academic_class_id INTO v_cls7 FROM academic.academic_classes
     WHERE tenant_id = c_tenant AND school_id = c_school AND academic_year_id = v_year AND class_name = '7' AND NOT is_deleted;
    SELECT academic_class_id INTO v_cls8 FROM academic.academic_classes
     WHERE tenant_id = c_tenant AND school_id = c_school AND academic_year_id = v_year AND class_name = '8' AND NOT is_deleted;
    SELECT s.academic_class_section_id INTO v_sec7a FROM academic.academic_class_sections s
     WHERE s.tenant_id = c_tenant AND s.school_id = c_school AND s.academic_year_id = v_year
       AND s.academic_class_id = v_cls7 AND s.section_name = 'A' AND NOT s.is_deleted;
    SELECT s.academic_class_section_id INTO v_sec8a FROM academic.academic_class_sections s
     WHERE s.tenant_id = c_tenant AND s.school_id = c_school AND s.academic_year_id = v_year
       AND s.academic_class_id = v_cls8 AND s.section_name = 'A' AND NOT s.is_deleted;
    SELECT staff_id INTO v_t1 FROM core.staff
     WHERE tenant_id = c_tenant AND school_id = c_school AND staff_type = 'Teaching'
       AND is_active AND NOT is_deleted ORDER BY staff_id LIMIT 1;
    SELECT staff_id INTO v_t2 FROM core.staff
     WHERE tenant_id = c_tenant AND school_id = c_school AND staff_type = 'Teaching'
       AND is_active AND NOT is_deleted AND staff_id <> v_t1 ORDER BY staff_id LIMIT 1;

    RAISE NOTICE 'fixture: year %, 7-A %, 8-A %, teachers % / %', v_year, v_sec7a, v_sec8a, v_t1, v_t2;

    -- A clean slate inside the transaction: no schedule, no lessons, Sunday the
    -- only weekly off, nothing on the calendar in September 2026 (either school).
    DELETE FROM academic.timetable        WHERE tenant_id = c_tenant AND school_id = c_school;
    DELETE FROM academic.period_structure WHERE tenant_id = c_tenant AND school_id = c_school;
    DELETE FROM academic.school_calendar
     WHERE ((tenant_id = c_tenant AND school_id = c_school) OR (tenant_id = o_tenant AND school_id = o_school))
       AND calendar_date::date BETWEEN DATE '2026-09-01' AND DATE '2026-09-30';
    PERFORM pg_temp.cal(c_tenant, c_school, 'SaveWeeklyOff', NULL, NULL, p_weekly => '0');

    PERFORM pg_temp.subj_save(c_tenant, c_school, v_cls7, '["Mathematics","English"]');
    PERFORM pg_temp.subj_save(c_tenant, c_school, v_cls8, '["Mathematics","English"]');
    SELECT subject_id INTO v_math FROM academic.school_subjects
     WHERE tenant_id = c_tenant AND school_id = c_school AND subject_name = 'Mathematics';
    SELECT subject_id INTO v_eng FROM academic.school_subjects
     WHERE tenant_id = c_tenant AND school_id = c_school AND subject_name = 'English';

    v_ot_all := pg_temp.ps_all(o_tenant, o_school);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- A. Migration: the existing schedule becomes the default ---';

    SELECT COUNT(*) INTO v_n FROM information_schema.columns
     WHERE table_schema = 'academic' AND table_name = 'period_structure'
       AND column_name = 'day_of_week' AND is_nullable = 'YES';
    PERFORM pg_temp.chk_eq('WDS-A1 period_structure.day_of_week exists and is nullable', v_n, 1);

    -- A schedule written the old way (no day) - exactly what every school had.
    INSERT INTO academic.period_structure (tenant_id, school_id, seq, period_type, label, start_time, end_time)
    VALUES (c_tenant, c_school, 1, 'class', 'Old P1', '08:00', '08:45'),
           (c_tenant, c_school, 2, 'break', 'Old Break', '08:45', '09:00'),
           (c_tenant, c_school, 3, 'class', 'Old P2', '09:00', '09:45');
    PERFORM pg_temp.chk_txt('WDS-A2 a pre-change schedule reads back as the default',
        pg_temp.ps_get(c_tenant, c_school),
        '1:Old P1@08:00-08:45/class;2:Old Break@08:45-09:00/break;3:Old P2@09:00-09:45/class;');
    SELECT COUNT(*) INTO v_n FROM generate_series(0, 6) d
     WHERE (SELECT COUNT(*) FROM academic.fn_day_periods(c_tenant, c_school, d::smallint)) = 3;
    PERFORM pg_temp.chk_eq('WDS-A3 every weekday (0..6) runs on it', v_n, 7);

    -- Re-running the migration DDL changes nothing (no double migration).
    EXECUTE 'ALTER TABLE academic.period_structure ADD COLUMN IF NOT EXISTS day_of_week smallint';
    SELECT COUNT(*) INTO v_n FROM academic.period_structure
     WHERE tenant_id = c_tenant AND school_id = c_school AND day_of_week IS NULL;
    PERFORM pg_temp.chk_eq('WDS-A4 re-running the migration keeps the 3 default rows as they were', v_n, 3);

    -- The 6-argument positional call every older caller uses still works.
    CALL academic.sp_school_admin_period_structure_manage('SavePeriodStructure', c_tenant, c_school, c_user, c_default, c);
    CLOSE c;
    PERFORM pg_temp.chk_txt('WDS-A5 the old positional call saves the default schedule',
        pg_temp.ps_get(c_tenant, c_school), c_default_txt);

    BEGIN
        INSERT INTO academic.period_structure (tenant_id, school_id, day_of_week, seq, period_type, label, start_time, end_time)
        VALUES (c_tenant, c_school, 7, 1, 'class', 'X', '08:00', '08:40');
        PERFORM pg_temp.chk('WDS-A6 day_of_week 7 refused by the table', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('WDS-A6 day_of_week 7 refused by the table', TRUE, SQLERRM); END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- B. Per-day schedules --------------------------------------';

    PERFORM pg_temp.chk_txt('WDS-B1 a short Saturday saves', pg_temp.ps_save(c_tenant, c_school, c_sat, 6), 'Schedule saved.');
    PERFORM pg_temp.chk_txt('WDS-B2 GetPeriodStructure(Saturday) = Saturday''s own 7 rows',
        pg_temp.ps_get(c_tenant, c_school, 6), c_sat_txt);
    PERFORM pg_temp.chk_txt('WDS-B3 ...flagged as Saturday rows (day_of_week 6)',
        pg_temp.ps_get_days(c_tenant, c_school, 6), '6');
    PERFORM pg_temp.chk_txt('WDS-B4 GetPeriodStructure(Monday) = the default (flagged default rows)',
        pg_temp.ps_get(c_tenant, c_school, 1) || pg_temp.ps_get_days(c_tenant, c_school, 1), c_default_txt || 'd');
    PERFORM pg_temp.chk_txt('WDS-B5 GetPeriodStructure(no day) = the default',
        pg_temp.ps_get(c_tenant, c_school), c_default_txt);
    SELECT COUNT(*) INTO v_n FROM regexp_matches(pg_temp.ps_all(c_tenant, c_school), ';', 'g');
    PERFORM pg_temp.chk_eq('WDS-B6 GetAllSchedules = 10 default + 7 Saturday rows', v_n, 17);
    PERFORM pg_temp.chk('WDS-B7 ...default rows first, then Saturday',
        pg_temp.ps_all(c_tenant, c_school) LIKE 'd:P1@08:00;%;6:Assembly@07:50;%', pg_temp.ps_all(c_tenant, c_school));

    -- Every rule of the default applies to a day's own schedule too.
    BEGIN PERFORM pg_temp.ps_save(c_tenant, c_school, '[{"name":"P1","start":"08:00","end":"08:40"},{"name":"P2","start":"08:30","end":"09:00"}]', 6);
        PERFORM pg_temp.chk('WDS-B8 overlapping Saturday periods refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('WDS-B8 overlapping Saturday periods refused', SQLERRM LIKE '%overlaps%', SQLERRM); END;
    BEGIN PERFORM pg_temp.ps_save(c_tenant, c_school, '[{"name":"P1","start":"08:00","end":"08:40"},{"name":" p1 ","start":"08:40","end":"09:00"}]', 6);
        PERFORM pg_temp.chk('WDS-B9 duplicate Saturday label (case/padding) refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('WDS-B9 duplicate Saturday label (case/padding) refused', SQLERRM LIKE '%two periods%', SQLERRM); END;
    BEGIN PERFORM pg_temp.ps_save(c_tenant, c_school, '[{"name":"P1","start":"08:00","end":"08:40","type":"sports"}]', 6);
        PERFORM pg_temp.chk('WDS-B10 unknown type on Saturday refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('WDS-B10 unknown type on Saturday refused', SQLERRM LIKE '%unknown type%', SQLERRM); END;
    BEGIN PERFORM pg_temp.ps_save(c_tenant, c_school, '[{"name":"P1","start":"09:00","end":"08:40"}]', 6);
        PERFORM pg_temp.chk('WDS-B11 backwards Saturday period refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('WDS-B11 backwards Saturday period refused', SQLERRM LIKE '%ends before%', SQLERRM); END;
    BEGIN PERFORM pg_temp.ps_save(c_tenant, c_school, '[]', 6);
        PERFORM pg_temp.chk('WDS-B12 empty Saturday schedule refused (use "Use default")', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('WDS-B12 empty Saturday schedule refused (use "Use default")', TRUE, SQLERRM); END;
    PERFORM pg_temp.chk('WDS-B13 every refused save left Saturday and the default untouched',
        pg_temp.ps_get(c_tenant, c_school, 6) = c_sat_txt AND pg_temp.ps_get(c_tenant, c_school) = c_default_txt, '');

    BEGIN PERFORM pg_temp.ps_save(c_tenant, c_school, c_sat, 0);
        PERFORM pg_temp.chk('WDS-B14 a schedule for the weekly off (Sunday) refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('WDS-B14 a schedule for the weekly off (Sunday) refused', SQLERRM LIKE '%weekly off%', SQLERRM); END;
    BEGIN PERFORM pg_temp.ps_save(c_tenant, c_school, c_sat, 7);
        PERFORM pg_temp.chk('WDS-B15 day 7 refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('WDS-B15 day 7 refused', SQLERRM LIKE '%not a day of the week%', SQLERRM); END;

    -- Editing the default leaves Saturday's own schedule alone.
    PERFORM pg_temp.ps_save(c_tenant, c_school, replace(c_default, '"13:25","end":"14:05"', '"13:25","end":"14:00"'));
    PERFORM pg_temp.chk('WDS-B16 editing the default (P8 ends 14:00) is stored',
        position('10:P8@13:25-14:00/class;' IN pg_temp.ps_get(c_tenant, c_school)) > 0, pg_temp.ps_get(c_tenant, c_school));
    PERFORM pg_temp.chk_txt('WDS-B17 ...and Saturday is unchanged', pg_temp.ps_get(c_tenant, c_school, 6), c_sat_txt);

    BEGIN PERFORM pg_temp.ps_use_default(c_tenant, c_school, NULL);
        PERFORM pg_temp.chk('WDS-B18 Use default without a day refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('WDS-B18 Use default without a day refused', TRUE, SQLERRM); END;

    PERFORM pg_temp.ps_save(c_tenant, c_school, c_sat, 5);
    PERFORM pg_temp.chk_txt('WDS-B19 Use default on Friday answers in words',
        pg_temp.ps_use_default(c_tenant, c_school, 5), 'Friday now uses the default schedule.');
    SELECT COUNT(*) INTO v_n FROM academic.period_structure
     WHERE tenant_id = c_tenant AND school_id = c_school AND day_of_week = 5;
    PERFORM pg_temp.chk_eq('WDS-B20 ...Friday''s own rows are gone', v_n, 0);
    PERFORM pg_temp.chk('WDS-B21 ...and Friday runs on the default again',
        pg_temp.ps_get(c_tenant, c_school, 5) = pg_temp.ps_get(c_tenant, c_school), '');
    PERFORM pg_temp.chk_txt('WDS-B22 Use default on a day that has none is harmless',
        pg_temp.ps_use_default(c_tenant, c_school, 3), 'Wednesday now uses the default schedule.');

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- C. Lessons follow their period by label, per day ---------';

    -- Default seqs: P1 1 .. P8 10. Saturday seqs: Assembly 1, P1 2, P2 3, Break 4, P3 5, P4 6, Games 7.
    PERFORM pg_temp.chk_txt('WDS-C1 Monday P1 booked', pg_temp.tt_save(c_tenant, c_school, v_sec7a, 1, 1, v_math, v_t1), 'Period updated.');
    PERFORM pg_temp.chk_txt('WDS-C2 Saturday P1 (seq 2 on Saturday) booked',
        pg_temp.tt_save(c_tenant, c_school, v_sec7a, 6, 2, v_math, v_t1), 'Period updated.');
    PERFORM pg_temp.tt_save(c_tenant, c_school, v_sec7a, 6, 6, v_eng, v_t2);      -- Saturday P4
    PERFORM pg_temp.tt_save(c_tenant, c_school, v_sec7a, 6, 7, v_eng, NULL);      -- Saturday Games
    PERFORM pg_temp.chk_txt('WDS-C3 Saturday lessons sit on Saturday''s periods',
        pg_temp.lessons(c_tenant, c_school, v_sec7a, 6), '2:P1;6:P4;7:Games');

    -- Saturday drops its assembly: Saturday renumbers, Monday does not.
    PERFORM pg_temp.ps_save(c_tenant, c_school, replace(c_sat, '{"name":"Assembly","start":"07:50","end":"08:00","type":"assembly"},', ''), 6);
    PERFORM pg_temp.chk_txt('WDS-C4 Saturday drops its assembly: Saturday lessons follow their labels',
        pg_temp.lessons(c_tenant, c_school, v_sec7a, 6), '1:P1;5:P4;6:Games');
    PERFORM pg_temp.chk_txt('WDS-C5 ...Monday''s lesson did not move', pg_temp.lessons(c_tenant, c_school, v_sec7a, 1), '1:P1');

    -- The default gets a morning assembly: Monday renumbers, Saturday does not.
    v_items := replace(replace(c_default, '"13:25","end":"14:05"', '"13:25","end":"14:00"'), '[', '[
      {"name":"Assembly","start":"07:40","end":"08:00","type":"assembly"},');
    PERFORM pg_temp.ps_save(c_tenant, c_school, v_items);
    PERFORM pg_temp.chk_txt('WDS-C6 the default gets an assembly: Monday P1 follows (seq 2)',
        pg_temp.lessons(c_tenant, c_school, v_sec7a, 1), '2:P1');
    PERFORM pg_temp.chk_txt('WDS-C7 ...Saturday (own schedule) is untouched',
        pg_temp.lessons(c_tenant, c_school, v_sec7a, 6), '1:P1;5:P4;6:Games');

    v_sat := pg_temp.ps_get(c_tenant, c_school, 6);
    BEGIN
        PERFORM pg_temp.ps_save(c_tenant, c_school, '[
          {"name":"P1","start":"08:00","end":"08:40"},{"name":"P2","start":"08:40","end":"09:20"},
          {"name":"P3","start":"09:35","end":"10:15"},{"name":"Games","start":"10:55","end":"12:00"}]', 6);
        PERFORM pg_temp.chk('WDS-C8 removing Saturday''s P4 while it has a Saturday lesson is refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('WDS-C8 removing Saturday''s P4 while it has a Saturday lesson is refused',
            SQLERRM LIKE '%"P4"%Saturday%', SQLERRM);
    END;
    BEGIN
        PERFORM pg_temp.ps_save(c_tenant, c_school, replace(v_items, '"P1","start":"08:00","end":"08:40","type":"class"', '"P1","start":"08:00","end":"08:40","type":"break"'), 6);
        PERFORM pg_temp.chk('WDS-C9 turning Saturday''s booked P1 into a break is refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('WDS-C9 turning Saturday''s booked P1 into a break is refused', TRUE, SQLERRM); END;
    PERFORM pg_temp.chk_txt('WDS-C10 ...Saturday unchanged after both refusals', pg_temp.ps_get(c_tenant, c_school, 6), v_sat);

    -- The default loses P4. Only Saturday has a P4 lesson, and Saturday has its
    -- own schedule, so the default may drop it.
    PERFORM pg_temp.chk_txt('WDS-C11 the default may drop P4: only Saturday (own schedule) teaches a P4',
        pg_temp.ps_save(c_tenant, c_school, replace(v_items, '{"name":"P4","start":"10:15","end":"10:55","type":"class"},', '')),
        'Schedule saved.');
    BEGIN
        PERFORM pg_temp.ps_use_default(c_tenant, c_school, 6);
        PERFORM pg_temp.chk('WDS-C12 Saturday cannot go back to a default that has no P4', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('WDS-C12 Saturday cannot go back to a default that has no P4', SQLERRM LIKE '%"P4"%Saturday%', SQLERRM);
    END;
    SELECT COUNT(*) INTO v_n FROM academic.period_structure WHERE tenant_id = c_tenant AND school_id = c_school AND day_of_week = 6;
    PERFORM pg_temp.chk_eq('WDS-C13 ...Saturday keeps its own 6 periods', v_n, 6);

    -- Put P4 back in the default, clear the Games lesson, and send Saturday back.
    PERFORM pg_temp.ps_save(c_tenant, c_school, v_items);
    PERFORM pg_temp.tt('ClearCell', c_tenant, c_school, v_sec7a, 6, 6, NULL, NULL);
    PERFORM pg_temp.chk_txt('WDS-C14 Saturday goes back to the default',
        pg_temp.ps_use_default(c_tenant, c_school, 6), 'Saturday now uses the default schedule.');
    -- Default with assembly: Assembly 1, P1 2, P2 3, P3 4, Break 5, P4 6, ...
    PERFORM pg_temp.chk_txt('WDS-C15 ...its lessons moved to the default''s P1 / P4',
        pg_temp.lessons(c_tenant, c_school, v_sec7a, 6), '2:P1;6:P4');
    SELECT COUNT(*) INTO v_n FROM academic.fn_day_periods(c_tenant, c_school, 6::smallint);
    PERFORM pg_temp.chk_eq('WDS-C16 ...and Saturday now runs on the 11-slot default', v_n, 11);
    SELECT COUNT(*) INTO v_n FROM academic.timetable t
     WHERE t.tenant_id = c_tenant AND t.school_id = c_school
       AND NOT EXISTS (SELECT 1 FROM academic.fn_day_periods(c_tenant, c_school, t.day_of_week) p
                        WHERE p.seq = t.period_seq AND p.period_type = 'class');
    PERFORM pg_temp.chk_eq('WDS-C17 no lesson anywhere sits on a missing / non-teaching period', v_n, 0);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- D. Booking against the day''s schedule ---------------------';

    -- A new short Saturday made from the default: P1 1, P2 2, Break 3, P3 4, P4 5.
    PERFORM pg_temp.ps_save(c_tenant, c_school, '[
      {"name":"P1","start":"08:00","end":"08:40"},{"name":"P2","start":"08:40","end":"09:20"},
      {"name":"Break","start":"09:20","end":"09:35","type":"break"},
      {"name":"P3","start":"09:35","end":"10:15"},{"name":"P4","start":"10:15","end":"10:55"}]', 6);
    PERFORM pg_temp.chk_txt('WDS-D1 creating a Saturday schedule moves Saturday''s lessons onto it',
        pg_temp.lessons(c_tenant, c_school, v_sec7a, 6), '1:P1;5:P4');

    BEGIN PERFORM pg_temp.tt_save(c_tenant, c_school, v_sec7a, 6, 7, v_math, NULL);
        PERFORM pg_temp.chk('WDS-D2 Saturday slot 7 (only the default has it) refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('WDS-D2 Saturday slot 7 (only the default has it) refused',
        SQLERRM LIKE '%not a teaching period on Saturday%', SQLERRM); END;
    BEGIN PERFORM pg_temp.tt_save(c_tenant, c_school, v_sec7a, 6, 3, v_math, NULL);
        PERFORM pg_temp.chk('WDS-D3 Saturday''s break (slot 3) refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('WDS-D3 Saturday''s break (slot 3) refused', TRUE, SQLERRM); END;
    PERFORM pg_temp.chk_txt('WDS-D4 Monday slot 7 (P5 on the default) books fine',
        pg_temp.tt_save(c_tenant, c_school, v_sec7a, 1, 7, v_math, NULL), 'Period updated.');
    PERFORM pg_temp.chk_eq('WDS-D5 GetSetup lists Saturday''s own 5 periods', pg_temp.tt_setup_count(c_tenant, c_school, 6), 5);
    PERFORM pg_temp.chk_eq('WDS-D6 GetSetup lists the default''s 11 for Monday', pg_temp.tt_setup_count(c_tenant, c_school, 1), 11);
    PERFORM pg_temp.chk_eq('WDS-D7 GetSetup lists nothing for the weekly off', pg_temp.tt_setup_count(c_tenant, c_school, 0), 0);
    BEGIN PERFORM pg_temp.tt_save(c_tenant, c_school, v_sec8a, 6, 1, v_math, v_t1);
        PERFORM pg_temp.chk('WDS-D8 teacher clash is per day: Saturday P1 teacher busy in 7-A', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('WDS-D8 teacher clash is per day: Saturday P1 teacher busy in 7-A',
        SQLERRM LIKE '%already teaching%', SQLERRM); END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- E. Copy Day across different schedules -------------------';

    DELETE FROM academic.timetable WHERE tenant_id = c_tenant AND school_id = c_school AND academic_class_section_id = v_sec7a;
    -- Monday (default): P1 slot 2, P2 slot 3, P5 slot 7, P7 slot 10.
    PERFORM pg_temp.tt_save(c_tenant, c_school, v_sec7a, 1, 2,  v_math, v_t1);
    PERFORM pg_temp.tt_save(c_tenant, c_school, v_sec7a, 1, 3,  v_eng,  v_t2);
    PERFORM pg_temp.tt_save(c_tenant, c_school, v_sec7a, 1, 7,  v_math, NULL);
    PERFORM pg_temp.tt_save(c_tenant, c_school, v_sec7a, 1, 10, v_eng,  NULL);
    PERFORM pg_temp.tt_save(c_tenant, c_school, v_sec7a, 6, 4,  v_eng,  NULL);     -- an old Saturday lesson (P3)

    v_j := pg_temp.tt('CopyDay', c_tenant, c_school, v_sec7a, 1, NULL, NULL, NULL);
    PERFORM pg_temp.chk_eq('WDS-E1 Monday copied: 4 x Tue-Fri + P1, P2 on Saturday', (v_j ->> 'copied')::int, 18);
    PERFORM pg_temp.chk_eq('WDS-E2 ...2 skipped because Saturday has no P5 / P7', (v_j ->> 'no_period')::int, 2);
    PERFORM pg_temp.chk('WDS-E3 ...and the message names them',
        v_j ->> 'message' LIKE '%Sat P5, Sat P7%', v_j ->> 'message');
    PERFORM pg_temp.chk_txt('WDS-E4 Saturday got P1 and P2 on its own slots (old P3 lesson cleared)',
        pg_temp.lessons(c_tenant, c_school, v_sec7a, 6), '1:P1;2:P2');
    PERFORM pg_temp.chk_txt('WDS-E5 Tuesday got all four on the default''s slots',
        pg_temp.lessons(c_tenant, c_school, v_sec7a, 2), '2:P1;3:P2;7:P5;10:P7');

    v_j := pg_temp.tt('CopyDay', c_tenant, c_school, v_sec7a, 6, NULL, NULL, NULL);
    PERFORM pg_temp.chk_eq('WDS-E6 copying the short Saturday: 2 x Mon-Fri', (v_j ->> 'copied')::int, 10);
    PERFORM pg_temp.chk_txt('WDS-E7 ...Monday now has Saturday''s P1, P2 on its own slots',
        pg_temp.lessons(c_tenant, c_school, v_sec7a, 1), '2:P1;3:P2');
    PERFORM pg_temp.chk_eq('WDS-E8 ...nothing missing the other way', (v_j ->> 'no_period')::int, 0);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- F. Calendar date ranges -----------------------------------';

    -- A half day already set inside the coming vacation week (Wed 16 Sep).
    PERFORM pg_temp.cal(c_tenant, c_school, 'SaveEntry', DATE '2026-09-16', NULL, 'half_day', 'ZZ PTM', TIME '11:00');

    v_j := pg_temp.cal(c_tenant, c_school, 'SaveRange', DATE '2026-09-14', DATE '2026-09-20', 'holiday', 'ZZ Vacation');
    PERFORM pg_temp.chk_eq('WDS-F1 Mon 14 - Sun 20 Sep holiday: 5 days created', (v_j ->> 'created')::int, 5);
    PERFORM pg_temp.chk_eq('WDS-F2 ...the day with an entry skipped', (v_j ->> 'skipped_existing')::int, 1);
    PERFORM pg_temp.chk_eq('WDS-F3 ...the weekly off (Sunday) skipped', (v_j ->> 'skipped_weekly_off')::int, 1);
    PERFORM pg_temp.chk('WDS-F4 ...the message reports both',
        v_j ->> 'message' LIKE '%16 Sep%' AND v_j ->> 'message' LIKE '%weekly off%', v_j ->> 'message');
    SELECT day_type || ' ' || to_char(half_day_end, 'HH24:MI') INTO v_txt FROM academic.school_calendar
     WHERE tenant_id = c_tenant AND school_id = c_school AND calendar_date = '2026-09-16';
    PERFORM pg_temp.chk_txt('WDS-F5 the existing half day was left as it was', v_txt, 'half_day 11:00');
    PERFORM pg_temp.chk_eq('WDS-F6 the calendar lists 6 entries that week', pg_temp.cal_count(c_tenant, c_school, DATE '2026-09-14', DATE '2026-09-20'), 6);
    PERFORM pg_temp.chk_txt('WDS-F7 fn_school_day_type across the range',
        pg_temp.day_types(c_tenant, c_school, DATE '2026-09-14', DATE '2026-09-21'),
        '14:holiday,15:holiday,16:half_day,17:holiday,18:holiday,19:holiday,20:weekly_off,21:working');

    BEGIN
        CALL core.sp_attendance_save(c_tenant, c_school, c_user, DATE '2026-09-15', '7', 'A', '[]'::jsonb, c);
        CLOSE c;
        PERFORM pg_temp.chk('WDS-F8 attendance on a day inside the range is refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('WDS-F8 attendance on a day inside the range is refused', SQLERRM LIKE '%holiday%', SQLERRM); END;
    PERFORM pg_temp.chk_eq('WDS-F9 leave / payroll count 0.5 working days that week (the half day)',
        core.fn_school_working_days(c_tenant, c_school, DATE '2026-09-14', DATE '2026-09-20'), 0.5);
    BEGIN
        CALL academic.sp_school_admin_exam_manage('SaveExam', c_tenant, c_school, c_user, v_year, NULL, NULL, 'ZZ Range Paper', 'Term',
             DATE '2026-09-17', DATE '2026-09-17', NULL,
             jsonb_build_array(jsonb_build_object('classId', v_cls7, 'sections', '[]'::jsonb, 'subjects',
                 jsonb_build_array(jsonb_build_object('subjectId', v_math, 'examDate', '2026-09-17', 'startTime', '09:00',
                                                      'endTime', '10:00', 'maxMarks', 100, 'passMarks', 33))))::text, c, c2);
        PERFORM pg_temp.chk('WDS-F10 an exam paper on a day inside the range is refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('WDS-F10 an exam paper on a day inside the range is refused', SQLERRM LIKE '%school is closed%', SQLERRM); END;

    BEGIN PERFORM pg_temp.cal(c_tenant, c_school, 'SaveRange', DATE '2026-09-14', DATE '2026-09-20', 'holiday', 'ZZ Again');
        PERFORM pg_temp.chk('WDS-F11 the same range again adds nothing and says so', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('WDS-F11 the same range again adds nothing and says so', SQLERRM LIKE 'Nothing was added%', SQLERRM); END;
    BEGIN PERFORM pg_temp.cal(c_tenant, c_school, 'SaveRange', DATE '2026-09-20', DATE '2026-09-14', 'holiday');
        PERFORM pg_temp.chk('WDS-F12 a range that ends before it starts is refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('WDS-F12 a range that ends before it starts is refused', SQLERRM LIKE '%ends before%', SQLERRM); END;
    BEGIN PERFORM pg_temp.cal(c_tenant, c_school, 'SaveRange', DATE '2026-09-01', DATE '2027-09-30', 'holiday');
        PERFORM pg_temp.chk('WDS-F13 a range longer than a year is refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('WDS-F13 a range longer than a year is refused', SQLERRM LIKE '%at most one year%', SQLERRM); END;
    BEGIN PERFORM pg_temp.cal(c_tenant, c_school, 'SaveRange', NULL, DATE '2026-09-20', 'holiday');
        PERFORM pg_temp.chk('WDS-F14 a range with no first date is refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('WDS-F14 a range with no first date is refused', TRUE, SQLERRM); END;
    BEGIN PERFORM pg_temp.cal(c_tenant, c_school, 'SaveRange', DATE '2026-09-21', DATE '2026-09-22', 'vacation');
        PERFORM pg_temp.chk('WDS-F15 an unknown day type is refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('WDS-F15 an unknown day type is refused', TRUE, SQLERRM); END;

    -- A half-day range closes at 12:30: inside Friday's default hours, after the
    -- short Saturday (ends 10:55) is already over. The whole range is refused.
    BEGIN PERFORM pg_temp.cal(c_tenant, c_school, 'SaveRange', DATE '2026-09-25', DATE '2026-09-26', 'half_day', 'ZZ Sports', TIME '12:30');
        PERFORM pg_temp.chk('WDS-F16 a half-day closing time is checked against each day''s own schedule', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('WDS-F16 a half-day closing time is checked against each day''s own schedule',
        SQLERRM LIKE '%Saturday%', SQLERRM); END;
    PERFORM pg_temp.chk_eq('WDS-F17 ...and nothing of that range was written (Friday too)',
        pg_temp.cal_count(c_tenant, c_school, DATE '2026-09-25', DATE '2026-09-26'), 0);
    v_j := pg_temp.cal(c_tenant, c_school, 'SaveRange', DATE '2026-09-25', DATE '2026-09-25', 'half_day', 'ZZ Sports', TIME '12:30');
    PERFORM pg_temp.chk_txt('WDS-F18 the Friday alone is accepted', v_j ->> 'message', '1 day marked.');
    v_j := pg_temp.cal(c_tenant, c_school, 'SaveRange', DATE '2026-09-27', DATE '2026-09-27', 'working', 'ZZ Make-up Sunday');
    PERFORM pg_temp.chk_txt('WDS-F19 a working-day range opens the weekly off (Sunday 27)',
        (v_j ->> 'created') || ' ' || academic.fn_school_day_type(c_tenant, c_school, DATE '2026-09-27'), '1 working');

    v_j := pg_temp.cal(c_tenant, c_school, 'DeleteRange', DATE '2026-09-14', DATE '2026-09-20');
    PERFORM pg_temp.chk_txt('WDS-F20 removing the vacation week removes all 6 entries', v_j ->> 'message', '6 entries removed.');
    PERFORM pg_temp.chk_txt('WDS-F21 ...the days are back on the weekly pattern',
        pg_temp.day_types(c_tenant, c_school, DATE '2026-09-14', DATE '2026-09-20'),
        '14:working,15:working,16:working,17:working,18:working,19:working,20:weekly_off');
    PERFORM pg_temp.chk_eq('WDS-F22 ...entries outside the range kept (25 and 27 Sep)',
        pg_temp.cal_count(c_tenant, c_school, DATE '2026-09-21', DATE '2026-09-30'), 2);
    BEGIN PERFORM pg_temp.cal(c_tenant, c_school, 'DeleteRange', DATE '2026-09-14', DATE '2026-09-20');
        PERFORM pg_temp.chk('WDS-F23 removing an empty range says nothing was there', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('WDS-F23 removing an empty range says nothing was there', SQLERRM LIKE '%no calendar entries%', SQLERRM); END;
    BEGIN PERFORM pg_temp.cal(c_tenant, c_school, 'DeleteRange', DATE '2026-09-20', DATE '2026-09-14');
        PERFORM pg_temp.chk('WDS-F24 a backwards delete range is refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('WDS-F24 a backwards delete range is refused', SQLERRM LIKE '%ends before%', SQLERRM); END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- G. Tenant isolation and platform scope --------------------';

    PERFORM pg_temp.chk_txt('WDS-G1 our schedule saves never touched the other school''s schedules',
        pg_temp.ps_all(o_tenant, o_school), v_ot_all);
    PERFORM pg_temp.chk('WDS-G2 the other school''s Saturday does not show our Saturday',
        pg_temp.ps_get(o_tenant, o_school, 6) <> pg_temp.ps_get(c_tenant, c_school, 6), '');
    PERFORM pg_temp.ps_use_default(o_tenant, o_school, 6);
    SELECT COUNT(*) INTO v_n FROM academic.period_structure WHERE tenant_id = c_tenant AND school_id = c_school AND day_of_week = 6;
    PERFORM pg_temp.chk_eq('WDS-G3 the other school''s "Use default" on Saturday leaves ours', v_n, 5);
    PERFORM pg_temp.chk_txt('WDS-G4 ...and our Saturday lessons', pg_temp.lessons(c_tenant, c_school, v_sec7a, 6), '1:P1;2:P2');
    BEGIN PERFORM pg_temp.tt_save(o_tenant, o_school, v_sec7a, 6, 1, v_math, NULL);
        PERFORM pg_temp.chk('WDS-G5 the other school cannot book our section''s Saturday', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('WDS-G5 the other school cannot book our section''s Saturday', TRUE, SQLERRM); END;

    BEGIN PERFORM pg_temp.cal(o_tenant, o_school, 'DeleteRange', DATE '2026-09-21', DATE '2026-09-30');
        PERFORM pg_temp.chk('WDS-G6 the other school''s delete range finds none of our entries', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('WDS-G6 the other school''s delete range finds none of our entries', SQLERRM LIKE '%no calendar entries%', SQLERRM); END;
    PERFORM pg_temp.chk_eq('WDS-G7 ...our 2 entries are still there', pg_temp.cal_count(c_tenant, c_school, DATE '2026-09-21', DATE '2026-09-30'), 2);
    v_j := pg_temp.cal(o_tenant, o_school, 'SaveRange', DATE '2026-09-25', DATE '2026-09-25', 'holiday', 'ZZ Their Holiday');
    PERFORM pg_temp.chk_eq('WDS-G8 our entry on 25 Sep does not count as theirs (their day is created)', (v_j ->> 'created')::int, 1);
    PERFORM pg_temp.chk_txt('WDS-G9 ...and our 25 Sep is still our half day',
        academic.fn_school_day_type(c_tenant, c_school, DATE '2026-09-25'), 'half_day');

    BEGIN PERFORM pg_temp.ps_save(1, 0, c_sat, 6);
        PERFORM pg_temp.chk('WDS-G10 platform scope cannot save a day schedule', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('WDS-G10 platform scope cannot save a day schedule', SQLERRM LIKE '%scope%', SQLERRM); END;
    BEGIN PERFORM pg_temp.ps_all(1, 0);
        PERFORM pg_temp.chk('WDS-G11 platform scope cannot read the schedules', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('WDS-G11 platform scope cannot read the schedules', SQLERRM LIKE '%scope%', SQLERRM); END;
    BEGIN PERFORM pg_temp.cal(1, 0, 'SaveRange', DATE '2026-09-21', DATE '2026-09-22', 'holiday');
        PERFORM pg_temp.chk('WDS-G12 platform scope cannot add a calendar range', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('WDS-G12 platform scope cannot add a calendar range', SQLERRM LIKE '%scope%', SQLERRM); END;
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
            RAISE NOTICE '   %  %', rpad(r.name, 64), r.detail;
        END LOOP;
    END IF;
    RAISE NOTICE '';
END
$sum$;

ROLLBACK;
