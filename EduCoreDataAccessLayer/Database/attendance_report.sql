-- ============================================================================
-- Attendance reporting — the monthly register that feeds all three report views
-- (Register grid, Defaulters, Summary). One proc returns everything the page
-- needs for a class/section/month; the client derives per-student stats from it.
--
-- Design notes:
--   * Roster    = students CURRENTLY active in the class/section (same source as
--                 the marking screen), so the report matches what teachers see.
--   * Marks     = their student_attendance rows within the month.
--   * SchoolDays = distinct non-Sunday dates in the month that actually have a
--                 register for this class/section. No holiday calendar needed —
--                 a day with no register simply isn't a school day yet.
--   * Status letters: Present/Late -> P (Late counts present), Absent -> A,
--                 Leave -> L. Sundays render as H on the client (calendar-derived).
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

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
    INOUT p_marks          refcursor DEFAULT 'ar_marks'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_start date;
    v_end   date;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0
       OR p_class IS NULL OR TRIM(p_class) = ''
       OR p_month < 1 OR p_month > 12 OR p_year < 2000 THEN
        OPEN p_meta     FOR SELECT 0 AS school_days;
        OPEN p_students FOR SELECT NULL::int AS student_id, NULL::text AS roll_no, NULL::text AS student_name WHERE FALSE;
        OPEN p_marks    FOR SELECT NULL::int AS student_id, NULL::int AS day, NULL::text AS mark WHERE FALSE;
        RETURN;
    END IF;

    v_start := make_date(p_year, p_month, 1);
    v_end   := (v_start + INTERVAL '1 month' - INTERVAL '1 day')::date;

    -- School days actually held (a register exists, and not a Sunday).
    OPEN p_meta FOR
    SELECT COUNT(DISTINCT a.attendance_date)::int AS school_days
    FROM core.student_attendance a
    WHERE a.tenant_id = p_tenant_id
      AND a.school_id = p_school_id
      AND a.attendance_date BETWEEN v_start AND v_end
      AND EXTRACT(DOW FROM a.attendance_date) <> 0
      AND LOWER(a.class_name)              = LOWER(TRIM(p_class))
      AND LOWER(COALESCE(a.section, ''))   = LOWER(TRIM(COALESCE(p_section, '')));

    -- The roster (current active students in this class/section).
    OPEN p_students FOR
    SELECT s.student_id, s.roll_no, s.student_name
    FROM core.students s
    WHERE s.tenant_id = p_tenant_id
      AND s.school_id = p_school_id
      AND s.is_active = TRUE
      AND LOWER(s.class_name)            = LOWER(TRIM(p_class))
      AND LOWER(COALESCE(s.section, '')) = LOWER(TRIM(COALESCE(p_section, '')))
    ORDER BY
        CASE WHEN s.roll_no ~ '^[0-9]+$' THEN lpad(s.roll_no, 6, '0') ELSE NULL END NULLS LAST,
        s.student_name;

    -- Their marks for the month, as a day-number + single letter.
    OPEN p_marks FOR
    SELECT
        a.student_id,
        EXTRACT(DAY FROM a.attendance_date)::int AS day,
        CASE a.status
            WHEN 'Absent' THEN 'A'
            WHEN 'Leave'  THEN 'L'
            ELSE 'P'                       -- Present / Late count as present
        END AS mark
    FROM core.student_attendance a
    JOIN core.students s
      ON s.student_id = a.student_id
     AND s.tenant_id  = a.tenant_id
     AND s.school_id  = a.school_id
    WHERE a.tenant_id = p_tenant_id
      AND a.school_id = p_school_id
      AND a.attendance_date BETWEEN v_start AND v_end
      AND s.is_active = TRUE
      AND LOWER(s.class_name)            = LOWER(TRIM(p_class))
      AND LOWER(COALESCE(s.section, '')) = LOWER(TRIM(COALESCE(p_section, '')));
END;
$procedure$;
