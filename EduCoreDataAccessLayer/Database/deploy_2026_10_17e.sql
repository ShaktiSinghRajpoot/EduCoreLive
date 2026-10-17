-- Bundle 2026-10-17e: staff attendance % -- leave (marked or approved) never counts against it. Run with:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_17e.sql
-- Sources: staff_attendance_history.sql

-- ============================================================================
-- Staff Attendance > Staff report: one staff member's attendance over a date range.
--
--   p_staff   : everyone who can be picked (active first, then those who left)
--   p_summary : working days, present (Present + Late), late, absent, half day,
--               leave, not marked, attendance %  -- only when p_staff_id is given
--   p_days    : one row per day of the range (up to today): the school's day type
--               (working / half_day / holiday / weekly_off), the mark, its remark,
--               and an approved leave covering the day; days before joining or
--               after the last working day say so
--
-- Attendance % = (present + half days x 0.5) / days marked present, absent or half
-- day. Leave (marked or approved) never counts against it, and a day nobody marked
-- is shown as "not marked", not counted as absent.
-- Read-only. Re-runnable.
-- ============================================================================
CREATE OR REPLACE PROCEDURE core.sp_staff_attendance_history(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_staff_id       integer DEFAULT NULL,
    IN    p_from           date    DEFAULT NULL,
    IN    p_to             date    DEFAULT NULL,
    INOUT p_staff          refcursor DEFAULT 'sah_staff'::refcursor,
    INOUT p_summary        refcursor DEFAULT 'sah_summary'::refcursor,
    INOUT p_days           refcursor DEFAULT 'sah_days'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_to   date := LEAST(COALESCE(p_to, CURRENT_DATE), CURRENT_DATE);
    v_from date := COALESCE(p_from, date_trunc('month', CURRENT_DATE)::date);
    v_join date;
    v_lwd  date;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    OPEN p_staff FOR
    SELECT s.staff_id, s.full_name, s.employee_code, s.designation,
           (COALESCE(s.status, 'Active') <> 'Inactive') AS is_active
      FROM core.staff s
     WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id AND NOT COALESCE(s.is_deleted, FALSE)
     ORDER BY (COALESCE(s.status, 'Active') <> 'Inactive') DESC, s.full_name;

    IF p_staff_id IS NOT NULL THEN
        IF v_from > v_to THEN
            RAISE EXCEPTION 'The "from" date is after the "to" date (or in the future).';
        END IF;
        IF v_to - v_from > 366 THEN
            RAISE EXCEPTION 'Choose a range of one year or less.';
        END IF;
        SELECT NULLIF(joining_date, '')::date, NULLIF(last_working_date, '')::date INTO v_join, v_lwd
          FROM core.staff
         WHERE staff_id = p_staff_id AND tenant_id = p_tenant_id AND school_id = p_school_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Staff member not found.';
        END IF;
    END IF;

    CREATE TEMP TABLE IF NOT EXISTS tmp_sah (d date, day_type varchar, employed boolean, status varchar,
                                             remark varchar, leave_type varchar) ON COMMIT DROP;
    TRUNCATE tmp_sah;
    IF p_staff_id IS NOT NULL THEN
        INSERT INTO tmp_sah
        SELECT g.d::date,
               academic.fn_school_day_type(p_tenant_id, p_school_id, g.d::date),
               (v_join IS NULL OR g.d::date >= v_join) AND (v_lwd IS NULL OR g.d::date <= v_lwd),
               a.status, a.remark,
               (SELECT l.leave_type FROM core.staff_leave l
                 WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id AND l.staff_id = p_staff_id
                   AND l.status = 'Approved' AND g.d::date BETWEEN l.from_date::date AND l.to_date::date
                 LIMIT 1)
          FROM generate_series(v_from, v_to, INTERVAL '1 day') g(d)
          LEFT JOIN core.staff_attendance a
                 ON a.tenant_id = p_tenant_id AND a.school_id = p_school_id
                AND a.staff_id = p_staff_id AND a.att_date = g.d::date;
    END IF;

    OPEN p_summary FOR
    WITH w AS (
        SELECT *, CASE day_type WHEN 'working' THEN 1 WHEN 'half_day' THEN 0.5 ELSE 0 END AS weight
          FROM tmp_sah WHERE employed
    )
    SELECT COALESCE(SUM(weight), 0)                                                     AS working_days,
           COUNT(*) FILTER (WHERE status IN ('Present', 'Late'))::int                   AS present,
           COUNT(*) FILTER (WHERE status = 'Late')::int                                 AS late,
           COUNT(*) FILTER (WHERE status = 'Absent')::int                               AS absent,
           COUNT(*) FILTER (WHERE status = 'HalfDay')::int                              AS half_day,
           COUNT(*) FILTER (WHERE status = 'Leave' OR (status IS NULL AND leave_type IS NOT NULL AND weight > 0))::int AS on_leave,
           COUNT(*) FILTER (WHERE status IS NULL AND leave_type IS NULL AND weight > 0)::int AS not_marked,
           CASE WHEN COUNT(*) FILTER (WHERE status IN ('Present', 'Late', 'Absent', 'HalfDay')) = 0 THEN 0
                ELSE ROUND((COUNT(*) FILTER (WHERE status IN ('Present', 'Late'))
                            + 0.5 * COUNT(*) FILTER (WHERE status = 'HalfDay')) * 100.0
                           / COUNT(*) FILTER (WHERE status IN ('Present', 'Late', 'Absent', 'HalfDay')), 1) END AS percent,
           to_char(v_from, 'YYYY-MM-DD') AS from_date, to_char(v_to, 'YYYY-MM-DD') AS to_date
      FROM w;

    OPEN p_days FOR
    SELECT to_char(d, 'YYYY-MM-DD') AS day, to_char(d, 'Dy') AS weekday, day_type, employed,
           status, remark, leave_type
      FROM tmp_sah
     ORDER BY d DESC;
END;
$procedure$;
