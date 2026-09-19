-- ============================================================================
-- One student's attendance — the per-student view the Student Dashboard needs.
--
-- core.sp_attendance_month_register already answers "the whole class, one month"
-- (the register grid). This is the other axis: one student, a whole session,
-- plus the day-by-day marks for whichever month is on screen.
--
-- It follows the register's conventions exactly, so the two screens can never
-- disagree about the same student:
--
--   * A "school day" is a day a register was actually taken for that class —
--     COUNT(DISTINCT attendance_date) — not a calendar day. A day nobody marked
--     is not a day the student was absent.
--   * Sundays are excluded (EXTRACT(DOW) <> 0), same as the register.
--   * Status folds the same way: Absent -> A, Leave -> L, everything else
--     (Present, Late) counts as present.
--
-- Percentage is computed over days the student's OWN class had a register, so a
-- student who joined in August is not marked down for July.
--
-- Target DB: PostgreSQL. Safe to re-run.
-- ============================================================================

CREATE OR REPLACE PROCEDURE core.sp_attendance_student(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_student_id     integer,
    IN    p_academic_year  varchar DEFAULT NULL,   -- NULL = the student's current session
    IN    p_month          integer DEFAULT NULL,   -- 1..12, for the day grid; NULL = no grid
    IN    p_year           integer DEFAULT NULL,
    INOUT p_summary        refcursor DEFAULT 'as_summary'::refcursor,
    INOUT p_months         refcursor DEFAULT 'as_months'::refcursor,
    INOUT p_days           refcursor DEFAULT 'as_days'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_year  varchar;
    v_cls   varchar;
    v_sec   varchar;
    v_start date;
    v_end   date;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR COALESCE(p_student_id, 0) <= 0 THEN
        OPEN p_summary FOR SELECT 0 AS school_days, 0 AS present, 0 AS absent, 0 AS leave_days, 0::numeric AS percent;
        OPEN p_months  FOR SELECT NULL::int AS month, NULL::int AS year, NULL::int AS school_days, NULL::int AS present WHERE FALSE;
        OPEN p_days    FOR SELECT NULL::int AS day, NULL::text AS mark WHERE FALSE;
        RETURN;
    END IF;

    -- The student's own session and class — attendance rows carry the class the
    -- student was in on that day, which is what we must count against.
    SELECT COALESCE(NULLIF(TRIM(COALESCE(p_academic_year, '')), ''), s.academic_year),
           s.class_name, COALESCE(s.section, '')
      INTO v_year, v_cls, v_sec
    FROM core.students s
    WHERE s.student_id = p_student_id
      AND s.tenant_id  = p_tenant_id
      AND s.school_id  = p_school_id;

    IF NOT FOUND THEN
        OPEN p_summary FOR SELECT 0 AS school_days, 0 AS present, 0 AS absent, 0 AS leave_days, 0::numeric AS percent;
        OPEN p_months  FOR SELECT NULL::int AS month, NULL::int AS year, NULL::int AS school_days, NULL::int AS present WHERE FALSE;
        OPEN p_days    FOR SELECT NULL::int AS day, NULL::text AS mark WHERE FALSE;
        RETURN;
    END IF;

    -- ── 1. Session summary ──────────────────────────────────────────────────
    -- school_days counts registers taken for the student's class in this session;
    -- the student's own marks are counted from their rows.
    OPEN p_summary FOR
    WITH held AS (
        SELECT DISTINCT a.attendance_date
        FROM core.student_attendance a
        WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
          AND a.academic_year = v_year
          AND LOWER(a.class_name)            = LOWER(v_cls)
          AND LOWER(COALESCE(a.section, '')) = LOWER(v_sec)
          AND EXTRACT(DOW FROM a.attendance_date) <> 0
    ),
    mine AS (
        SELECT a.attendance_date,
               CASE a.status WHEN 'Absent' THEN 'A' WHEN 'Leave' THEN 'L' ELSE 'P' END AS mark
        FROM core.student_attendance a
        WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
          AND a.student_id = p_student_id
          AND a.academic_year = v_year
          AND EXTRACT(DOW FROM a.attendance_date) <> 0
    )
    SELECT (SELECT COUNT(*) FROM held)::int                                  AS school_days,
           COUNT(*) FILTER (WHERE mark = 'P')::int                           AS present,
           COUNT(*) FILTER (WHERE mark = 'A')::int                           AS absent,
           COUNT(*) FILTER (WHERE mark = 'L')::int                           AS leave_days,
           CASE WHEN (SELECT COUNT(*) FROM held) = 0 THEN 0::numeric
                ELSE ROUND(COUNT(*) FILTER (WHERE mark = 'P') * 100.0
                           / (SELECT COUNT(*) FROM held), 1) END             AS percent
    FROM mine;

    -- ── 2. Month by month, for the page's month picker ──────────────────────
    OPEN p_months FOR
    SELECT EXTRACT(MONTH FROM a.attendance_date)::int AS month,
           EXTRACT(YEAR  FROM a.attendance_date)::int AS year,
           COUNT(*)::int                               AS school_days,
           COUNT(*) FILTER (WHERE a.status NOT IN ('Absent', 'Leave'))::int AS present
    FROM core.student_attendance a
    WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
      AND a.student_id = p_student_id
      AND a.academic_year = v_year
      AND EXTRACT(DOW FROM a.attendance_date) <> 0
    GROUP BY 1, 2
    ORDER BY year DESC, month DESC;

    -- ── 3. Day grid for one month (the calendar) ────────────────────────────
    IF p_month IS NULL OR p_year IS NULL THEN
        OPEN p_days FOR SELECT NULL::int AS day, NULL::text AS mark WHERE FALSE;
        RETURN;
    END IF;

    v_start := make_date(p_year, p_month, 1);
    v_end   := (v_start + INTERVAL '1 month' - INTERVAL '1 day')::date;

    OPEN p_days FOR
    SELECT EXTRACT(DAY FROM a.attendance_date)::int AS day,
           CASE a.status WHEN 'Absent' THEN 'A' WHEN 'Leave' THEN 'L' ELSE 'P' END AS mark
    FROM core.student_attendance a
    WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
      AND a.student_id = p_student_id
      AND a.attendance_date BETWEEN v_start AND v_end
      AND EXTRACT(DOW FROM a.attendance_date) <> 0
    ORDER BY day;
END;
$procedure$;
