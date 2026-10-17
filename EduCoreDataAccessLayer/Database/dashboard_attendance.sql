-- ============================================================================
-- Dashboard: staff attendance today, and attendance defaulters (students + staff).
--
--   p_staff_today  : active staff, marked today, present (Present / Late),
--                    absent, half day, on leave (marked Leave or approved leave)
--   p_student_def  : students of the session in progress (core.student_enrolment)
--                    with at least 5 days marked and attendance below p_threshold %,
--                    lowest first, top 10 + how many in all
--   p_staff_def    : staff with absences this month (Absent = 1, HalfDay = 0.5),
--                    most first, top 10 + how many in all; late marks shown beside
--
-- Read-only. Re-runnable.
-- ============================================================================
CREATE OR REPLACE PROCEDURE core.sp_dashboard_attendance(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_threshold      numeric DEFAULT 75,
    INOUT p_staff_today    refcursor DEFAULT 'da_staff_today'::refcursor,
    INOUT p_student_def    refcursor DEFAULT 'da_student_def'::refcursor,
    INOUT p_staff_def      refcursor DEFAULT 'da_staff_def'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_session varchar;
    v_month   date := date_trunc('month', CURRENT_DATE)::date;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;
    v_session := core.fn_session_on(p_tenant_id, p_school_id, CURRENT_DATE);

    -- ── staff today ─────────────────────────────────────────────────────────
    OPEN p_staff_today FOR
    WITH st AS (
        SELECT s.staff_id,
               a.status,
               EXISTS (SELECT 1 FROM core.staff_leave l
                        WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
                          AND l.staff_id = s.staff_id AND l.status = 'Approved'
                          AND CURRENT_DATE BETWEEN l.from_date::date AND l.to_date::date) AS on_leave
          FROM core.staff s
          LEFT JOIN core.staff_attendance a
                 ON a.staff_id = s.staff_id AND a.tenant_id = p_tenant_id AND a.school_id = p_school_id
                AND a.att_date = CURRENT_DATE
         WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id
           AND NOT COALESCE(s.is_deleted, FALSE) AND COALESCE(s.status, 'Active') = 'Active'
           AND (NULLIF(s.joining_date, '') IS NULL OR s.joining_date::date <= CURRENT_DATE)
    )
    SELECT COUNT(*)::int                                                      AS total,
           COUNT(status)::int                                                 AS marked,
           COUNT(*) FILTER (WHERE status IN ('Present', 'Late'))::int         AS present,
           COUNT(*) FILTER (WHERE status = 'Absent')::int                     AS absent,
           COUNT(*) FILTER (WHERE status = 'HalfDay')::int                    AS half_day,
           COUNT(*) FILTER (WHERE status = 'Leave' OR (status IS NULL AND on_leave))::int AS on_leave
      FROM st;

    -- ── students below the line, this session ───────────────────────────────
    OPEN p_student_def FOR
    WITH roll AS (
        SELECT e.student_id, e.class_name, e.section
          FROM core.student_enrolment e
         WHERE e.tenant_id = p_tenant_id AND e.school_id = p_school_id
           AND e.academic_year = v_session AND COALESCE(e.status, '') NOT IN ('Left', 'PassedOut')
    ),
    marks AS (
        SELECT a.student_id,
               COUNT(*)                                                    AS marked,
               COUNT(*) FILTER (WHERE a.status IN ('Present', 'Late'))     AS present
          FROM core.student_attendance a
         WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id AND a.academic_year = v_session
         GROUP BY a.student_id
    ),
    low AS (
        SELECT r.student_id, r.class_name, r.section, m.marked::int AS marked, m.present::int AS present,
               ROUND(m.present * 100.0 / m.marked, 1) AS percent
          FROM roll r JOIN marks m ON m.student_id = r.student_id
         WHERE m.marked >= 5 AND m.present * 100.0 / m.marked < p_threshold
    )
    SELECT s.public_id, s.student_name, l.class_name, l.section, l.marked, l.present, l.percent,
           COUNT(*) OVER ()::int AS total_count
      FROM low l JOIN core.students s ON s.student_id = l.student_id
     ORDER BY l.percent, s.student_name
     LIMIT 10;

    -- ── staff absences, this month ──────────────────────────────────────────
    OPEN p_staff_def FOR
    WITH m AS (
        SELECT a.staff_id,
               SUM(CASE a.status WHEN 'Absent' THEN 1 WHEN 'HalfDay' THEN 0.5 ELSE 0 END) AS absent_days,
               COUNT(*) FILTER (WHERE a.status = 'Late')::int                            AS late_days,
               COUNT(*)::int                                                             AS marked
          FROM core.staff_attendance a
         WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
           AND a.att_date BETWEEN v_month AND CURRENT_DATE
         GROUP BY a.staff_id
    )
    SELECT s.public_id, s.full_name, s.designation, m.absent_days, m.late_days, m.marked,
           COUNT(*) OVER ()::int AS total_count
      FROM m JOIN core.staff s ON s.staff_id = m.staff_id
     WHERE NOT COALESCE(s.is_deleted, FALSE) AND COALESCE(s.status, 'Active') = 'Active'
       AND (m.absent_days > 0 OR m.late_days >= 3)
     ORDER BY m.absent_days DESC, m.late_days DESC, s.full_name
     LIMIT 10;
END;
$procedure$;
