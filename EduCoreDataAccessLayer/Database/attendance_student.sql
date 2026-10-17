-- ============================================================================
-- One student's attendance — the per-student view the Student Dashboard needs.
--
-- core.sp_attendance_month_register answers "the whole class, one month" (the
-- register grid). This is the other axis: one student, a whole session, plus
-- the day-by-day marks for whichever month is on screen.
--
-- A "school day" for a student is a day a register was taken for the
-- class-section the student belonged to THAT day (core.fn_attendance_student_days):
--
--   * every day the student has a mark (the row's class-section snapshot says
--     where they were), plus
--   * registers of their CURRENT class-section taken on/after their admission,
--     on/before their date of leaving, and after the last day they were marked
--     in a different class-section (so a student who moved from 7-A to 7-B is
--     not charged with 7-B's registers from before the move).
--
-- A day nobody marked is not a day the student was absent. Weekly offs and
-- holidays have no register (sp_attendance_save refuses them), so there is no
-- calendar filter here; a declared working Sunday counts like any other day.
--
-- Status folds the same way as the register: Absent -> A, Leave -> L, Present
-- and Late -> P. Leave is NOT present: it stays in the denominator and is
-- reported separately.
--
-- Target DB: PostgreSQL. Safe to re-run.
-- ============================================================================

-- The school days one student belonged to in one session (see above).
CREATE OR REPLACE FUNCTION core.fn_attendance_student_days(
    p_tenant_id integer, p_school_id integer, p_student_id integer, p_academic_year varchar)
RETURNS TABLE (day date)
LANGUAGE sql
STABLE
AS $function$
    -- The class-section they had IN THAT SESSION (core.student_enrolment); the
    -- present row is next session's class once they are promoted.
    WITH st AS (
        SELECT COALESCE(e.class_name, s.class_name) AS cls, COALESCE(e.section, s.section, '') AS sec,
               NULLIF(s.admission_date::text, '')::date AS adm,
               CASE WHEN COALESCE(e.status, '') IN ('Left', 'PassedOut') OR (e.status IS NULL AND NOT s.is_active)
                    THEN NULLIF(s.date_of_leaving::text, '')::date END AS lv
        FROM core.students s
        LEFT JOIN core.student_enrolment e ON e.student_id = s.student_id AND e.academic_year = p_academic_year
        WHERE s.student_id = p_student_id AND s.tenant_id = p_tenant_id AND s.school_id = p_school_id
    ),
    mine AS (
        SELECT a.attendance_date::date AS d, a.class_name, COALESCE(a.section, '') AS sec
        FROM core.student_attendance a
        WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
          AND a.student_id = p_student_id AND a.academic_year = p_academic_year
    ),
    last_other AS (
        SELECT MAX(m.d) AS d
        FROM mine m, st
        WHERE NOT (LOWER(m.class_name) = LOWER(st.cls) AND LOWER(m.sec) = LOWER(st.sec))
    )
    SELECT d FROM mine
    UNION
    SELECT DISTINCT a.attendance_date::date
    FROM core.student_attendance a, st, last_other lo
    WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
      AND a.academic_year = p_academic_year
      AND LOWER(a.class_name)            = LOWER(st.cls)
      AND LOWER(COALESCE(a.section, '')) = LOWER(st.sec)
      AND (st.adm IS NULL OR a.attendance_date::date >= st.adm)
      AND (st.lv  IS NULL OR a.attendance_date::date <= st.lv)
      AND (lo.d   IS NULL OR a.attendance_date::date >  lo.d);
$function$;


CREATE OR REPLACE PROCEDURE core.sp_attendance_student(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_student_id     integer,
    IN    p_academic_year  varchar DEFAULT NULL,   -- NULL = the session in progress today
    IN    p_month          integer DEFAULT NULL,   -- 1..12, for the day grid; NULL = no grid
    IN    p_year           integer DEFAULT NULL,
    INOUT p_summary        refcursor DEFAULT 'as_summary'::refcursor,
    INOUT p_months         refcursor DEFAULT 'as_months'::refcursor,
    INOUT p_days           refcursor DEFAULT 'as_days'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_year  varchar;
    v_start date;
    v_end   date;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR COALESCE(p_student_id, 0) <= 0 THEN
        OPEN p_summary FOR SELECT 0 AS school_days, 0 AS present, 0 AS absent, 0 AS leave_days, 0::numeric AS percent;
        OPEN p_months  FOR SELECT NULL::int AS month, NULL::int AS year, NULL::int AS school_days, NULL::int AS present WHERE FALSE;
        OPEN p_days    FOR SELECT NULL::int AS day, NULL::text AS mark WHERE FALSE;
        RETURN;
    END IF;

    -- No session asked for: the one in progress today, if they are enrolled in it
    -- (a child promoted early still shows this year's attendance), else theirs.
    SELECT COALESCE(NULLIF(TRIM(COALESCE(p_academic_year, '')), ''),
                    (SELECT e.academic_year FROM core.student_enrolment e
                      WHERE e.student_id = s.student_id
                        AND e.academic_year = core.fn_session_on(p_tenant_id, p_school_id, CURRENT_DATE)),
                    s.academic_year)
      INTO v_year
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
    OPEN p_summary FOR
    WITH held AS (
        SELECT day FROM core.fn_attendance_student_days(p_tenant_id, p_school_id, p_student_id, v_year)
    ),
    mine AS (
        SELECT CASE a.status WHEN 'Absent' THEN 'A' WHEN 'Leave' THEN 'L' ELSE 'P' END AS mark
        FROM core.student_attendance a
        WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
          AND a.student_id = p_student_id AND a.academic_year = v_year
    )
    SELECT (SELECT COUNT(*) FROM held)::int                                  AS school_days,
           (SELECT COUNT(*) FROM mine WHERE mark = 'P')::int                 AS present,
           (SELECT COUNT(*) FROM mine WHERE mark = 'A')::int                 AS absent,
           (SELECT COUNT(*) FROM mine WHERE mark = 'L')::int                 AS leave_days,
           CASE WHEN (SELECT COUNT(*) FROM held) = 0 THEN 0::numeric
                ELSE ROUND((SELECT COUNT(*) FROM mine WHERE mark = 'P') * 100.0
                           / (SELECT COUNT(*) FROM held), 1) END             AS percent;

    -- ── 2. Month by month, for the page's month picker ──────────────────────
    -- Same denominator as the summary, month by month.
    OPEN p_months FOR
    SELECT EXTRACT(MONTH FROM h.day)::int                                    AS month,
           EXTRACT(YEAR  FROM h.day)::int                                    AS year,
           COUNT(*)::int                                                     AS school_days,
           COUNT(*) FILTER (WHERE a.status IN ('Present', 'Late'))::int      AS present
    FROM core.fn_attendance_student_days(p_tenant_id, p_school_id, p_student_id, v_year) h
    LEFT JOIN core.student_attendance a
           ON a.tenant_id = p_tenant_id AND a.school_id = p_school_id
          AND a.student_id = p_student_id
          AND a.attendance_date = to_char(h.day, 'YYYY-MM-DD')
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
    SELECT EXTRACT(DAY FROM a.attendance_date::date)::int AS day,
           CASE a.status WHEN 'Absent' THEN 'A' WHEN 'Leave' THEN 'L' ELSE 'P' END AS mark
    FROM core.student_attendance a
    WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
      AND a.student_id = p_student_id
      AND a.attendance_date::date BETWEEN v_start AND v_end
    ORDER BY day;
END;
$procedure$;
