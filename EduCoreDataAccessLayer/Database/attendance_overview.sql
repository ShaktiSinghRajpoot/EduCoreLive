-- ============================================================================
-- Attendance Overview (Attendance › Overview). Read-only.
--
-- A REGISTER is one class section's attendance on one school working day
-- (core.fn_school_working_days > 0 for that date). It is "taken" when at least
-- one student of the section has a mark that day. The class teacher of the
-- section (academic_class_sections.class_teacher_staff_id) is the one
-- responsible for it. Only sections of the current session that have students
-- count, and only days from the session start up to today — and for each
-- section only from the day its first student was admitted (QA BUG-104: a
-- section filled in October is not "missing" September's registers).
--
--   p_day   (Today tab) cursor 1 sections: every section with that day's counts
--                                          (present / absent / late / leave), who marked it
--   p_from..p_to (Insights) cursor 2 sections: expected / taken registers, student-days
--                                              marked and present, registers taken the same day
--                            cursor 3 weeks:    the same per week
--                            cursor 4 missing:  every register not taken, newest first
--   cursor 5 day: whether p_day is a working day / the calendar's note
-- Present = Present or Late.
-- Re-runnable.
-- ============================================================================

CREATE OR REPLACE PROCEDURE core.sp_attendance_overview(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_day            date,
    IN    p_from           date,
    IN    p_to             date,
    INOUT p_today          refcursor DEFAULT 'ao_today',
    INOUT p_sections       refcursor DEFAULT 'ao_sections',
    INOUT p_weeks          refcursor DEFAULT 'ao_weeks',
    INOUT p_missing        refcursor DEFAULT 'ao_missing',
    INOUT p_dayinfo        refcursor DEFAULT 'ao_day')
LANGUAGE plpgsql
AS $$
DECLARE
    v_year_id integer;
    v_year    varchar;
    v_start   date;
    v_from    date;
    v_to      date;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    SELECT y.academic_year_id, y.academic_year_name, NULLIF(y.start_date::text, '')::date
      INTO v_year_id, v_year, v_start
      FROM academic.academic_years y
     WHERE y.tenant_id = p_tenant_id AND y.school_id = p_school_id
       AND COALESCE(y.is_current, FALSE) AND NOT COALESCE(y.is_deleted, FALSE)
     LIMIT 1;

    v_from := GREATEST(COALESCE(p_from, CURRENT_DATE - 29), COALESCE(v_start, p_from, CURRENT_DATE - 29));
    v_to   := LEAST(COALESCE(p_to, CURRENT_DATE), CURRENT_DATE);

    -- the session's sections that have students, with their class teacher
    CREATE TEMP TABLE IF NOT EXISTS tmp_ao_sec (section_id int PRIMARY KEY, class_name varchar, section varchar,
                                                display_order int, students int, teacher_id int, teacher varchar,
                                                start_on date) ON COMMIT DROP;
    TRUNCATE tmp_ao_sec;
    INSERT INTO tmp_ao_sec
    SELECT x.* FROM (
        SELECT sec.academic_class_section_id, c.class_name, sec.section_name, COALESCE(c.display_order, 0),
               (SELECT COUNT(*) FROM core.students s
                 WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id AND COALESCE(s.is_active, TRUE)
                   AND s.class_name = c.class_name AND lower(COALESCE(s.section, '')) = lower(sec.section_name)
                   AND s.academic_year = v_year)::int AS students,
               sec.class_teacher_staff_id, st.full_name,
               -- the day the section's first (active) student was admitted
               COALESCE((SELECT MIN(NULLIF(s.admission_date, '')::date) FROM core.students s
                          WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id AND COALESCE(s.is_active, TRUE)
                            AND s.class_name = c.class_name AND lower(COALESCE(s.section, '')) = lower(sec.section_name)
                            AND s.academic_year = v_year), v_start) AS start_on
          FROM academic.academic_class_sections sec
          JOIN academic.academic_classes c ON c.academic_class_id = sec.academic_class_id
          LEFT JOIN core.staff st ON st.staff_id = sec.class_teacher_staff_id
         WHERE sec.tenant_id = p_tenant_id AND sec.school_id = p_school_id AND sec.academic_year_id = v_year_id
           AND NOT COALESCE(sec.is_deleted, FALSE) AND NOT COALESCE(c.is_deleted, FALSE)) x
     WHERE x.students > 0;

    -- working days in the range
    CREATE TEMP TABLE IF NOT EXISTS tmp_ao_days (d date PRIMARY KEY) ON COMMIT DROP;
    TRUNCATE tmp_ao_days;
    IF v_from <= v_to THEN
        INSERT INTO tmp_ao_days
        SELECT g::date FROM generate_series(v_from, v_to, interval '1 day') g
         WHERE core.fn_school_working_days(p_tenant_id, p_school_id, g::date, g::date) > 0;
    END IF;

    -- registers actually taken in the range: section x date, with counts
    CREATE TEMP TABLE IF NOT EXISTS tmp_ao_reg (section_id int, d date, marked int, present int, same_day boolean) ON COMMIT DROP;
    TRUNCATE tmp_ao_reg;
    INSERT INTO tmp_ao_reg
    SELECT ts.section_id, a.attendance_date::date, COUNT(*)::int,
           COUNT(*) FILTER (WHERE a.status IN ('Present', 'Late'))::int,
           MIN(a.marked_at)::date <= a.attendance_date::date
      FROM core.student_attendance a
      JOIN tmp_ao_sec ts ON ts.class_name = a.class_name AND lower(ts.section) = lower(COALESCE(a.section, ''))
     WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id AND a.academic_year = v_year
       AND a.attendance_date BETWEEN to_char(v_from, 'YYYY-MM-DD') AND to_char(v_to, 'YYYY-MM-DD')
     GROUP BY ts.section_id, a.attendance_date;

    -- ── Today: every section with that day's marks
    OPEN p_today FOR
    SELECT ts.section_id, ts.class_name, ts.section, ts.display_order, ts.students, ts.teacher_id, ts.teacher,
           COUNT(a.attendance_id)::int                                         AS marked,
           COUNT(*) FILTER (WHERE a.status = 'Present')::int                   AS present,
           COUNT(*) FILTER (WHERE a.status = 'Absent')::int                    AS absent,
           COUNT(*) FILTER (WHERE a.status = 'Late')::int                      AS late,
           COUNT(*) FILTER (WHERE a.status = 'Leave')::int                     AS leave,
           core.fn_user_display_name(MIN(a.marked_by))                         AS marked_by,
           -- as text on the school's clock: a timestamp that travels through a DataTable
           -- loses its UTC tag, and the page would show 06:29 for 11:59 IST
           to_char(MIN(a.marked_at) AT TIME ZONE 'Asia/Kolkata', 'DD Mon, HH12:MI AM') AS marked_at
      FROM tmp_ao_sec ts
      LEFT JOIN core.student_attendance a
             ON a.tenant_id = p_tenant_id AND a.school_id = p_school_id AND a.academic_year = v_year
            AND a.class_name = ts.class_name AND lower(COALESCE(a.section, '')) = lower(ts.section)
            AND a.attendance_date = to_char(COALESCE(p_day, CURRENT_DATE), 'YYYY-MM-DD')
     GROUP BY ts.section_id, ts.class_name, ts.section, ts.display_order, ts.students, ts.teacher_id, ts.teacher
     ORDER BY ts.display_order, ts.class_name, ts.section;

    -- ── Insights per section
    OPEN p_sections FOR
    SELECT ts.section_id, ts.class_name, ts.section, ts.display_order, ts.students, ts.teacher_id, ts.teacher,
           (SELECT COUNT(*) FROM tmp_ao_days dd WHERE dd.d >= ts.start_on)::int                     AS expected,
           (SELECT COUNT(*) FROM tmp_ao_reg r JOIN tmp_ao_days dd ON dd.d = r.d WHERE r.section_id = ts.section_id)::int AS taken,
           (SELECT COUNT(*) FROM tmp_ao_reg r JOIN tmp_ao_days dd ON dd.d = r.d WHERE r.section_id = ts.section_id AND r.same_day)::int AS same_day,
           (SELECT COALESCE(SUM(r.marked), 0) FROM tmp_ao_reg r WHERE r.section_id = ts.section_id)::int  AS marked,
           (SELECT COALESCE(SUM(r.present), 0) FROM tmp_ao_reg r WHERE r.section_id = ts.section_id)::int AS present
      FROM tmp_ao_sec ts
     ORDER BY ts.display_order, ts.class_name, ts.section;

    -- ── week by week (week starting Monday)
    OPEN p_weeks FOR
    SELECT to_char(w.wk, 'YYYY-MM-DD') AS week_start, w.first_day::text AS first_day, w.last_day::text AS last_day,
           (SELECT COUNT(*) FROM tmp_ao_days dd JOIN tmp_ao_sec ts ON ts.start_on <= dd.d
             WHERE date_trunc('week', dd.d) = w.wk)::int AS expected,
           (SELECT COUNT(*) FROM tmp_ao_reg r JOIN tmp_ao_days dd ON dd.d = r.d WHERE date_trunc('week', r.d) = w.wk)::int AS taken,
           (SELECT COALESCE(SUM(r.marked), 0) FROM tmp_ao_reg r WHERE date_trunc('week', r.d) = w.wk)::int AS marked,
           (SELECT COALESCE(SUM(r.present), 0) FROM tmp_ao_reg r WHERE date_trunc('week', r.d) = w.wk)::int AS present
      FROM (SELECT date_trunc('week', d) AS wk, MIN(d) AS first_day, MAX(d) AS last_day, COUNT(*) AS days
              FROM tmp_ao_days GROUP BY 1) w
     ORDER BY w.wk;

    -- ── registers never taken, newest first
    OPEN p_missing FOR
    SELECT to_char(dd.d, 'YYYY-MM-DD') AS day, ts.section_id, ts.class_name, ts.section, ts.teacher
      FROM tmp_ao_days dd
      JOIN tmp_ao_sec ts ON ts.start_on <= dd.d
     WHERE NOT EXISTS (SELECT 1 FROM tmp_ao_reg r WHERE r.section_id = ts.section_id AND r.d = dd.d)
     ORDER BY dd.d DESC, ts.display_order, ts.class_name, ts.section
     LIMIT 500;

    -- ── the chosen day
    OPEN p_dayinfo FOR
    SELECT core.fn_school_working_days(p_tenant_id, p_school_id, COALESCE(p_day, CURRENT_DATE), COALESCE(p_day, CURRENT_DATE)) AS working,
           (SELECT c.day_type || COALESCE(': ' || c.title, '') FROM academic.school_calendar c
             WHERE c.tenant_id = p_tenant_id AND c.school_id = p_school_id
               AND c.calendar_date = to_char(COALESCE(p_day, CURRENT_DATE), 'YYYY-MM-DD') LIMIT 1) AS note,
           to_char(v_from, 'YYYY-MM-DD') AS range_from, to_char(v_to, 'YYYY-MM-DD') AS range_to;
END;
$$;
