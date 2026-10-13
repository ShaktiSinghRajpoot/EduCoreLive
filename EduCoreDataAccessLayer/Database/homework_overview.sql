-- ============================================================================
-- Homework overview (Homework page › Overview tab). Read-only.
--
-- Who teaches what comes from the LIVE timetable of the current session, so a
-- teacher who gives no homework still shows up (they have no homework row and
-- would otherwise be invisible). Homework is counted by the day it was given
-- (p_from .. p_to), only in sections of the current session.
--
--   cursor 1  teachers  one row per Teaching staff member with periods on the
--                       timetable: sections / periods taught, sections covered by
--                       homework, homework given, last given, how much of it was
--                       checked and how many students did it
--   cursor 2  classes   per class: sections, homework given, done / checked
--   cursor 3  subjects  per subject: homework given, done / checked
--
-- p_class (a class name) narrows everything to that class.
-- "expected" = homework x students of its section; "recorded" = students the
-- teacher marked (Done / NotDone / Late); "done" = marked Done or Late.
-- Re-runnable.
-- ============================================================================

CREATE OR REPLACE PROCEDURE academic.sp_homework_overview(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_from           date,
    IN    p_to             date,
    IN    p_class          varchar DEFAULT NULL,
    INOUT p_teachers       refcursor DEFAULT 'hw_teachers',
    INOUT p_classes        refcursor DEFAULT 'hw_classes',
    INOUT p_subjects       refcursor DEFAULT 'hw_subjects')
LANGUAGE plpgsql
AS $$
DECLARE
    v_year  integer;
    v_class varchar := NULLIF(trim(p_class), '');
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    SELECT ay.academic_year_id INTO v_year
      FROM academic.academic_years ay
     WHERE ay.tenant_id = p_tenant_id AND ay.school_id = p_school_id
       AND COALESCE(ay.is_current, FALSE) AND NOT COALESCE(ay.is_deleted, FALSE)
     LIMIT 1;

    -- the current session's sections (optionally one class), with their student count
    CREATE TEMP TABLE IF NOT EXISTS tmp_hw_sec (section_id int PRIMARY KEY, class_name varchar, display_order int, students int) ON COMMIT DROP;
    TRUNCATE tmp_hw_sec;
    INSERT INTO tmp_hw_sec
    SELECT sec.academic_class_section_id, c.class_name, COALESCE(c.display_order, 0),
           (SELECT COUNT(*) FROM core.students s
             WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id AND COALESCE(s.is_active, TRUE)
               AND s.class_name = c.class_name AND lower(COALESCE(s.section, '')) = lower(sec.section_name)
               AND s.academic_year = y.academic_year_name)::int
      FROM academic.academic_class_sections sec
      JOIN academic.academic_classes c ON c.academic_class_id = sec.academic_class_id
      JOIN academic.academic_years y ON y.academic_year_id = c.academic_year_id
     WHERE sec.tenant_id = p_tenant_id AND sec.school_id = p_school_id AND sec.academic_year_id = v_year
       AND NOT COALESCE(sec.is_deleted, FALSE) AND NOT COALESCE(c.is_deleted, FALSE)
       AND (v_class IS NULL OR c.class_name = v_class);

    -- homework in the window, with how many students were recorded / did it
    CREATE TEMP TABLE IF NOT EXISTS tmp_hw (homework_id int PRIMARY KEY, section_id int, subject_id int, staff_id int,
                                            assigned_on date, students int, recorded int, done int) ON COMMIT DROP;
    TRUNCATE tmp_hw;
    INSERT INTO tmp_hw
    SELECT h.homework_id, h.academic_class_section_id, h.subject_id, h.staff_id, h.assigned_on, ts.students,
           (SELECT COUNT(*) FROM academic.homework_status x WHERE x.homework_id = h.homework_id)::int,
           (SELECT COUNT(*) FROM academic.homework_status x WHERE x.homework_id = h.homework_id AND x.status IN ('Done', 'Late'))::int
      FROM academic.homework h
      JOIN tmp_hw_sec ts ON ts.section_id = h.academic_class_section_id
     WHERE h.tenant_id = p_tenant_id AND h.school_id = p_school_id AND NOT h.is_deleted
       AND h.assigned_on BETWEEN p_from AND p_to;

    -- ── 1. teachers (from the timetable)
    OPEN p_teachers FOR
    WITH taught AS (
        SELECT t.staff_id, COUNT(DISTINCT t.academic_class_section_id)::int AS sections, COUNT(*)::int AS periods
          FROM academic.timetable t
          JOIN tmp_hw_sec ts ON ts.section_id = t.academic_class_section_id
         WHERE t.tenant_id = p_tenant_id AND t.school_id = p_school_id AND t.academic_year_id = v_year
           AND t.staff_id IS NOT NULL
         GROUP BY t.staff_id
    )
    SELECT st.staff_id, st.full_name, tg.sections, tg.periods,
           (SELECT COUNT(DISTINCT h.section_id) FROM tmp_hw h
             WHERE h.staff_id = st.staff_id
               AND EXISTS (SELECT 1 FROM academic.timetable t
                            WHERE t.staff_id = st.staff_id AND t.academic_year_id = v_year
                              AND t.academic_class_section_id = h.section_id))::int AS covered,
           (SELECT COUNT(*) FROM tmp_hw h WHERE h.staff_id = st.staff_id)::int                    AS sets,
           (SELECT COUNT(*) FROM tmp_hw h WHERE h.staff_id = st.staff_id AND h.recorded > 0)::int AS checked_sets,
           (SELECT COALESCE(SUM(h.students), 0) FROM tmp_hw h WHERE h.staff_id = st.staff_id)::int AS expected,
           (SELECT COALESCE(SUM(h.recorded), 0) FROM tmp_hw h WHERE h.staff_id = st.staff_id)::int AS recorded,
           (SELECT COALESCE(SUM(h.done), 0) FROM tmp_hw h WHERE h.staff_id = st.staff_id)::int     AS done,
           (SELECT to_char(MAX(h2.assigned_on), 'YYYY-MM-DD') FROM academic.homework h2
             JOIN tmp_hw_sec ts ON ts.section_id = h2.academic_class_section_id
             WHERE h2.staff_id = st.staff_id AND NOT h2.is_deleted)                                AS last_given
      FROM taught tg
      JOIN core.staff st ON st.staff_id = tg.staff_id
     WHERE st.tenant_id = p_tenant_id AND st.school_id = p_school_id
       AND NOT COALESCE(st.is_deleted, FALSE) AND COALESCE(st.is_active, TRUE)
     ORDER BY st.full_name;

    -- ── 2. classes
    OPEN p_classes FOR
    SELECT ts.class_name, MIN(ts.display_order) AS display_order,
           COUNT(DISTINCT ts.section_id)::int AS sections,
           SUM(ts.students)::int AS students,
           (SELECT COUNT(*) FROM tmp_hw h JOIN tmp_hw_sec s2 ON s2.section_id = h.section_id WHERE s2.class_name = ts.class_name)::int AS sets,
           (SELECT COALESCE(SUM(h.students), 0) FROM tmp_hw h JOIN tmp_hw_sec s2 ON s2.section_id = h.section_id WHERE s2.class_name = ts.class_name)::int AS expected,
           (SELECT COALESCE(SUM(h.recorded), 0) FROM tmp_hw h JOIN tmp_hw_sec s2 ON s2.section_id = h.section_id WHERE s2.class_name = ts.class_name)::int AS recorded,
           (SELECT COALESCE(SUM(h.done), 0) FROM tmp_hw h JOIN tmp_hw_sec s2 ON s2.section_id = h.section_id WHERE s2.class_name = ts.class_name)::int AS done
      FROM tmp_hw_sec ts
     GROUP BY ts.class_name
     ORDER BY MIN(ts.display_order), ts.class_name;

    -- ── 3. subjects
    OPEN p_subjects FOR
    SELECT sj.subject_name, COUNT(*)::int AS sets,
           SUM(h.students)::int AS expected, SUM(h.recorded)::int AS recorded, SUM(h.done)::int AS done
      FROM tmp_hw h
      JOIN academic.school_subjects sj ON sj.subject_id = h.subject_id
     GROUP BY sj.subject_name
     ORDER BY COUNT(*) DESC, sj.subject_name;
END;
$$;
