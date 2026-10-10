-- ============================================================================
-- Attendance reporting — the monthly register that feeds all three report views
-- (Register grid, Defaulters, Summary). One proc returns everything the page
-- needs for a class/section/month; the client derives per-student stats from it.
--
-- Design notes:
--   * Roster  = everyone who belonged to the class-section at some point in the
--               month: students in it now (admitted by month end, still active
--               or leaving on/after the 1st), plus anyone marked in it that
--               month (moved out or left since). A printed register keeps its
--               rows after a student leaves or changes section.
--   * Marks   = rows within the month whose class-section SNAPSHOT is this
--               class-section, so a student who moved shows only the days they
--               actually sat here.
--   * SchoolDays = distinct dates in the month with a register for this
--               class-section. Per student, school_days counts only the days
--               they belonged here (same rule as sp_attendance_student), so a
--               mid-month joiner or leaver is not marked down for other days.
--   * Days off = holidays / weekly offs from the School Calendar that had no
--               register, for shading on the client.
--   * Status letters: Present/Late -> P (Late counts present), Absent -> A,
--               Leave -> L (not present).
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- The signature gained p_days_off; drop the old one so callers cannot hit it.
DROP PROCEDURE IF EXISTS core.sp_attendance_month_register(
    integer, integer, integer, varchar, varchar, integer, integer, refcursor, refcursor, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_attendance_month_register(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_class          varchar,
    IN    p_section        varchar,
    IN    p_month          integer,   -- 1..12
    IN    p_year           integer,
    INOUT p_meta           refcursor DEFAULT 'ar_meta'::refcursor,
    INOUT p_students       refcursor DEFAULT 'ar_students'::refcursor,
    INOUT p_marks          refcursor DEFAULT 'ar_marks'::refcursor,
    INOUT p_days_off       refcursor DEFAULT 'ar_days_off'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_start date;
    v_end   date;
    v_cls   text;
    v_sec   text;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0
       OR p_class IS NULL OR TRIM(p_class) = ''
       OR p_month < 1 OR p_month > 12 OR p_year < 2000 THEN
        OPEN p_meta     FOR SELECT 0 AS school_days;
        OPEN p_students FOR SELECT NULL::int AS student_id, NULL::text AS roll_no, NULL::text AS student_name, NULL::int AS school_days WHERE FALSE;
        OPEN p_marks    FOR SELECT NULL::int AS student_id, NULL::int AS day, NULL::text AS mark WHERE FALSE;
        OPEN p_days_off FOR SELECT NULL::int AS day, NULL::text AS day_type, NULL::text AS title WHERE FALSE;
        RETURN;
    END IF;

    v_start := make_date(p_year, p_month, 1);
    v_end   := (v_start + INTERVAL '1 month' - INTERVAL '1 day')::date;
    v_cls   := LOWER(TRIM(p_class));
    v_sec   := LOWER(TRIM(COALESCE(p_section, '')));

    -- School days actually held by this class-section.
    OPEN p_meta FOR
    SELECT COUNT(DISTINCT a.attendance_date)::int AS school_days
    FROM core.student_attendance a
    WHERE a.tenant_id = p_tenant_id
      AND a.school_id = p_school_id
      AND a.attendance_date::date BETWEEN v_start AND v_end
      AND LOWER(a.class_name)            = v_cls
      AND LOWER(COALESCE(a.section, '')) = v_sec;

    -- Everyone who belonged here during the month, each with the number of this
    -- class-section's registers they belonged to.
    OPEN p_students FOR
    WITH reg AS (
        SELECT DISTINCT a.attendance_date::date AS d
        FROM core.student_attendance a
        WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
          AND a.attendance_date::date BETWEEN v_start AND v_end
          AND LOWER(a.class_name) = v_cls AND LOWER(COALESCE(a.section, '')) = v_sec
    ),
    cand AS (
        SELECT s.student_id
        FROM core.students s
        WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id
          AND LOWER(s.class_name) = v_cls AND LOWER(COALESCE(s.section, '')) = v_sec
          AND (NULLIF(s.admission_date, '') IS NULL OR s.admission_date::date <= v_end)
          AND (s.is_active OR (NULLIF(s.date_of_leaving, '') IS NOT NULL AND s.date_of_leaving::date >= v_start))
        UNION
        SELECT a.student_id
        FROM core.student_attendance a
        WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
          AND a.attendance_date::date BETWEEN v_start AND v_end
          AND LOWER(a.class_name) = v_cls AND LOWER(COALESCE(a.section, '')) = v_sec
    )
    SELECT s.student_id, s.roll_no, s.student_name,
           (SELECT COUNT(*) FROM reg r
            WHERE EXISTS (SELECT 1 FROM core.student_attendance o
                          WHERE o.tenant_id = s.tenant_id AND o.school_id = s.school_id
                            AND o.student_id = s.student_id
                            AND o.attendance_date = to_char(r.d, 'YYYY-MM-DD')
                            AND LOWER(o.class_name) = v_cls AND LOWER(COALESCE(o.section, '')) = v_sec)
               OR (    LOWER(s.class_name) = v_cls AND LOWER(COALESCE(s.section, '')) = v_sec
                   AND (NULLIF(s.admission_date, '') IS NULL OR r.d >= s.admission_date::date)
                   AND (s.is_active OR r.d <= s.date_of_leaving::date)
                   -- after the last day they were marked anywhere else (moved in)
                   AND r.d > COALESCE((SELECT MAX(o.attendance_date::date)
                                       FROM core.student_attendance o
                                       WHERE o.tenant_id = s.tenant_id AND o.school_id = s.school_id
                                         AND o.student_id = s.student_id
                                         AND NOT (LOWER(o.class_name) = v_cls
                                              AND LOWER(COALESCE(o.section, '')) = v_sec)),
                                      DATE '1900-01-01'))
           )::int AS school_days
    FROM cand c
    JOIN core.students s ON s.student_id = c.student_id
    ORDER BY
        CASE WHEN s.roll_no ~ '^[0-9]+$' THEN lpad(s.roll_no, 6, '0') ELSE NULL END NULLS LAST,
        s.student_name;

    -- Marks taken in THIS class-section, as a day-number + single letter.
    OPEN p_marks FOR
    SELECT
        a.student_id,
        EXTRACT(DAY FROM a.attendance_date::date)::int AS day,
        CASE a.status
            WHEN 'Absent' THEN 'A'
            WHEN 'Leave'  THEN 'L'
            ELSE 'P'                       -- Present / Late count as present
        END AS mark
    FROM core.student_attendance a
    WHERE a.tenant_id = p_tenant_id
      AND a.school_id = p_school_id
      AND a.attendance_date::date BETWEEN v_start AND v_end
      AND LOWER(a.class_name)            = v_cls
      AND LOWER(COALESCE(a.section, '')) = v_sec;

    -- Holidays and weekly offs that had no register, for shading.
    OPEN p_days_off FOR
    SELECT EXTRACT(DAY FROM g)::int AS day,
           academic.fn_school_day_type(p_tenant_id, p_school_id, g::date) AS day_type,
           COALESCE((SELECT c.title FROM academic.school_calendar c
                     WHERE c.tenant_id = p_tenant_id AND c.school_id = p_school_id
                       AND c.calendar_date = to_char(g, 'YYYY-MM-DD')),
                    trim(to_char(g, 'Day'))) AS title
    FROM generate_series(v_start, v_end, INTERVAL '1 day') g
    WHERE academic.fn_school_day_type(p_tenant_id, p_school_id, g::date) IN ('holiday', 'weekly_off')
      AND NOT EXISTS (SELECT 1 FROM core.student_attendance a
                      WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
                        AND a.attendance_date = to_char(g, 'YYYY-MM-DD')
                        AND LOWER(a.class_name) = v_cls AND LOWER(COALESCE(a.section, '')) = v_sec)
    ORDER BY 1;
END;
$procedure$;
