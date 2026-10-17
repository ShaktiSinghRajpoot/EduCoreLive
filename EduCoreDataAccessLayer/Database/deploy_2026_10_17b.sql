-- Bundle 2026-10-17b: students of one session never show up in another -- attendance register / save / month register / student % / overview, dashboard counts (class strength no longer doubled), roll numbers, certificates, fee dashboard + defaulters, homework read the session's enrolment. Run with:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_17b.sql
-- Sources (re-runnable, in this order): session_rolls.sql, student_attendance.sql, attendance_student.sql, attendance_report.sql, attendance_overview.sql, dashboard_summary.sql, report_card_certificates.sql, student_master_fields.sql, student_update.sql, student_data_checks.sql, fee_dashboard.sql, fee_reports.sql, homework.sql

-- ============================================================================
-- Roll numbers in one class + section + session.
--
-- core.students holds where a child is NOW. A child promoted before the session
-- ends has their student row in next session's class already, but their roll in
-- the old class still stands (core.student_enrolment, status 'Promoted') and is
-- what the old class's register, exam sheets and result sheet print. Checking only
-- core.students let a new admission or a renumbering take that roll a second time.
--
-- Used by: sp_admission_manage (roll check, next roll), sp_student_update (roll
-- check), sp_student_data_checks (duplicate rolls, Assign roll numbers).
--
-- Re-runnable.
-- ============================================================================
CREATE OR REPLACE FUNCTION core.fn_session_rolls(
    p_tenant_id integer, p_school_id integer, p_year varchar, p_class varchar, p_section varchar)
RETURNS TABLE (student_id integer, roll_no varchar)
LANGUAGE sql
STABLE
AS $function$
    -- children whose present row is in this class-section and session
    SELECT s.student_id, s.roll_no
      FROM core.students s
     WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id AND COALESCE(s.is_active, TRUE)
       AND s.academic_year = TRIM(p_year) AND s.class_name = TRIM(p_class)
       AND lower(COALESCE(s.section, '')) = lower(COALESCE(TRIM(p_section), ''))
    UNION
    -- plus those who were here this session and have moved on (promoted early)
    SELECT e.student_id, e.roll_no
      FROM core.student_enrolment e
     WHERE e.tenant_id = p_tenant_id AND e.school_id = p_school_id
       AND e.academic_year = TRIM(p_year) AND e.class_name = TRIM(p_class)
       AND lower(COALESCE(e.section, '')) = lower(COALESCE(TRIM(p_section), ''))
       AND COALESCE(e.status, '') NOT IN ('Left', 'PassedOut');
$function$;

-- ============================================================================
-- Student attendance — daily marking (the class teacher's core screen).
--
-- Real-world flow: teacher picks class + section + date, gets the roster (all
-- default Present), toggles the absentees, saves. One record per student per
-- day; re-opening a marked day shows the current marks so it can be corrected.
--
-- Class / section / academic year are SNAPSHOT on each record so a monthly or
-- year report stays correct even after a student changes class.
--
--   core.student_attendance      one row per student per day
--   core.sp_attendance_roster    the class roster for a date (+ existing marks)
--   core.sp_attendance_save      upsert the whole class's marks for a date
--   core.sp_class_active_sections sections that have active students (dropdown)
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

CREATE TABLE IF NOT EXISTS core.student_attendance (
    attendance_id   serial PRIMARY KEY,
    tenant_id       integer NOT NULL,
    school_id       integer NOT NULL,
    student_id      integer NOT NULL,
    attendance_date date    NOT NULL,
    status          varchar(20) NOT NULL,        -- Present | Absent | Late | Leave
    remarks         varchar(200),

    -- Snapshot so historical reports don't shift when a student is promoted.
    academic_year   varchar(20),
    class_name      varchar(50),
    section         varchar(20),

    marked_by       integer,
    marked_at       timestamptz NOT NULL DEFAULT now(),
    updated_by      integer,
    updated_at      timestamptz,

    CONSTRAINT chk_student_attendance_status
        CHECK (status IN ('Present', 'Absent', 'Late', 'Leave'))
);

-- How many days back a teacher may still enter/correct attendance. Older days are
-- locked (0 = only today). A school can raise it; principals handle rare fixes.
ALTER TABLE core.school_settings
    ADD COLUMN IF NOT EXISTS attendance_backdate_days integer NOT NULL DEFAULT 7;

-- One mark per student per day.
CREATE UNIQUE INDEX IF NOT EXISTS ux_student_attendance_day
    ON core.student_attendance (tenant_id, school_id, student_id, attendance_date);

-- Fast "who did this class have on this date".
CREATE INDEX IF NOT EXISTS ix_student_attendance_class_date
    ON core.student_attendance (tenant_id, school_id, class_name, section, attendance_date);


-- ── sections that have active students in a class (fills the Section dropdown) ─
CREATE OR REPLACE PROCEDURE core.sp_class_active_sections(
    IN    p_tenant_id integer,
    IN    p_school_id integer,
    IN    p_class     varchar,
    INOUT p_result    refcursor DEFAULT 'class_sections_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        OPEN p_result FOR SELECT WHERE FALSE;
        RETURN;
    END IF;

    -- sections with children on the roll of the session in progress (a section
    -- holding only next session's admissions is not offered)
    OPEN p_result FOR
    SELECT DISTINCT TRIM(e.section) AS section
    FROM core.student_enrolment e
    WHERE e.tenant_id = p_tenant_id
      AND e.school_id = p_school_id
      AND e.academic_year = core.fn_session_on(p_tenant_id, p_school_id, CURRENT_DATE)
      AND COALESCE(e.status, '') NOT IN ('Left', 'PassedOut')
      AND COALESCE(TRIM(e.section), '') <> ''
      AND (p_class IS NULL OR TRIM(p_class) = '' OR LOWER(e.class_name) = LOWER(TRIM(p_class)))
    ORDER BY 1;
END;
$procedure$;


-- ── the session a date falls in ─────────────────────────────────────────────
-- The session whose start..end contains the date; when none does (dates not set,
-- or a gap between sessions) the school's current session.
CREATE OR REPLACE FUNCTION core.fn_session_on(p_tenant_id integer, p_school_id integer, p_date date)
RETURNS varchar
LANGUAGE sql
STABLE
AS $function$
    SELECT COALESCE(
        (SELECT y.academic_year_name FROM academic.academic_years y
          WHERE y.tenant_id = p_tenant_id AND y.school_id = p_school_id AND NOT COALESCE(y.is_deleted, FALSE)
            AND NULLIF(y.start_date, '')::date <= p_date AND NULLIF(y.end_date, '')::date >= p_date
          ORDER BY y.is_current DESC LIMIT 1),
        (SELECT y.academic_year_name FROM academic.academic_years y
          WHERE y.tenant_id = p_tenant_id AND y.school_id = p_school_id AND NOT COALESCE(y.is_deleted, FALSE)
            AND y.is_current LIMIT 1));
$function$;


-- ── who belongs on a class-section's register on one date ───────────────────
-- Shared by the roster (what the teacher sees) and the save (what it accepts),
-- so the two can never disagree. It reads core.student_enrolment for the
-- session the date falls in (core.fn_session_on), not the student's present row:
--   * a child promoted before the session ends stays on the OLD class's register
--     until it ends (their old enrolment is kept as 'Promoted');
--   * a child admitted for next session is on no register until it starts;
--   * a child who left is on the register up to their leaving day;
--   * unless that day's row already puts them in another class-section (they
--     moved later, or were marked there);
--   * plus anyone whose row for that date is already in this class-section, so a
--     past day can be corrected after a student moved or left.
CREATE OR REPLACE FUNCTION core.fn_attendance_register(
    p_tenant_id integer, p_school_id integer, p_class varchar, p_section varchar, p_date date)
RETURNS TABLE (student_id integer)
LANGUAGE sql
STABLE
AS $function$
    SELECT e.student_id
    FROM core.student_enrolment e
    JOIN core.students s ON s.student_id = e.student_id
    WHERE e.tenant_id = p_tenant_id
      AND e.school_id = p_school_id
      AND e.academic_year = core.fn_session_on(p_tenant_id, p_school_id, p_date)
      AND LOWER(e.class_name)            = LOWER(TRIM(p_class))
      AND LOWER(COALESCE(e.section, '')) = LOWER(TRIM(COALESCE(p_section, '')))
      AND (s.admission_date IS NULL OR s.admission_date::date <= p_date)
      AND (COALESCE(e.status, '') NOT IN ('Left', 'PassedOut')
           OR (s.date_of_leaving IS NOT NULL AND s.date_of_leaving::date >= p_date))
      AND NOT EXISTS (
          SELECT 1 FROM core.student_attendance o
          WHERE o.tenant_id = s.tenant_id AND o.school_id = s.school_id
            AND o.student_id = s.student_id
            AND o.attendance_date = to_char(p_date, 'YYYY-MM-DD')
            AND NOT (LOWER(o.class_name)            = LOWER(TRIM(p_class))
                 AND LOWER(COALESCE(o.section, '')) = LOWER(TRIM(COALESCE(p_section, '')))))
    UNION
    SELECT a.student_id
    FROM core.student_attendance a
    WHERE a.tenant_id = p_tenant_id
      AND a.school_id = p_school_id
      AND a.attendance_date = to_char(p_date, 'YYYY-MM-DD')
      AND LOWER(a.class_name)            = LOWER(TRIM(p_class))
      AND LOWER(COALESCE(a.section, '')) = LOWER(TRIM(COALESCE(p_section, '')))
      AND a.academic_year = core.fn_session_on(p_tenant_id, p_school_id, p_date);
$function$;


-- ── the class roster for a date, with any marks already made ───────────────
CREATE OR REPLACE PROCEDURE core.sp_attendance_roster(
    IN    p_tenant_id integer,
    IN    p_school_id integer,
    IN    p_action_user_id integer,
    IN    p_class     varchar,
    IN    p_section   varchar,
    IN    p_date      date,
    INOUT p_result    refcursor DEFAULT 'attendance_roster_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR COALESCE(TRIM(p_class), '') = '' OR p_date IS NULL THEN
        OPEN p_result FOR SELECT WHERE FALSE;
        RETURN;
    END IF;

    OPEN p_result FOR
    SELECT
        s.student_id,
        COALESCE(NULLIF(TRIM(e.roll_no), ''), s.roll_no) AS roll_no,   -- the roll of THAT session
        s.admission_no, s.student_name,
        s.guardian_name, s.mobile,     -- for the absentee WhatsApp notification
        a.status  AS status,           -- NULL when not yet marked
        a.remarks AS remarks,
        (a.attendance_id IS NOT NULL) AS is_marked
    FROM core.fn_attendance_register(p_tenant_id, p_school_id, p_class, p_section, p_date) r
    JOIN core.students s
      ON s.student_id = r.student_id
    LEFT JOIN core.student_enrolment e
      ON e.student_id = s.student_id
     AND e.academic_year = core.fn_session_on(p_tenant_id, p_school_id, p_date)
    LEFT JOIN core.student_attendance a
           ON a.student_id      = s.student_id
          AND a.tenant_id       = s.tenant_id
          AND a.school_id       = s.school_id
          AND a.attendance_date = to_char(p_date, 'YYYY-MM-DD')
    ORDER BY
        CASE WHEN COALESCE(NULLIF(TRIM(e.roll_no), ''), s.roll_no) ~ '^[0-9]+$'
             THEN lpad(COALESCE(NULLIF(TRIM(e.roll_no), ''), s.roll_no), 6, '0') ELSE NULL END NULLS LAST,
        s.student_name;
END;
$procedure$;


-- ── save (upsert) one class-section's marks for a date ──────────────────────
-- p_items is a JSON array: [{ "studentId": 1, "status": "Present", "remarks": "" }, ...]
--
-- The class-section is part of the call so the save can check every student
-- against the same register the roster showed: the controller's class-teacher
-- gate approves a class-section, and this keeps the items inside it.
--
-- Rules, in order: school scope; date not in the future; the School Calendar
-- says the school is open that day (declared holidays and weekly offs refused,
-- declared working days allowed, a half day is a normal day); inside the
-- back-date window; every status is Present/Absent/Late/Leave; every student
-- is on the register. Nothing is saved if any item is refused.
--
-- A mark that does not change is not rewritten, so updated_by keeps meaning
-- "who last changed it", and the history trigger (academics_edit_history.sql)
-- records only real changes.
DROP PROCEDURE IF EXISTS core.sp_attendance_save(integer, integer, integer, date, jsonb, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_attendance_save(
    IN    p_tenant_id integer,
    IN    p_school_id integer,
    IN    p_action_user_id integer,
    IN    p_date      date,
    IN    p_class     varchar,
    IN    p_section   varchar,
    IN    p_items     jsonb,
    INOUT p_result    refcursor DEFAULT 'attendance_save_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_saved         integer := 0;
    v_backdate_days integer;
    v_day_type      text;
    v_title         text;
    v_bad           text;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Attendance date is required.';
    END IF;
    IF COALESCE(TRIM(p_class), '') = '' THEN
        RAISE EXCEPTION 'Choose a class first.';
    END IF;
    IF p_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'Attendance cannot be marked for a future date.';
    END IF;

    -- The School Calendar decides which days have a register — the same answer
    -- the Smart Bell gets.
    v_day_type := academic.fn_school_day_type(p_tenant_id, p_school_id, p_date);
    IF v_day_type = 'holiday' THEN
        SELECT title INTO v_title FROM academic.school_calendar
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND calendar_date = to_char(p_date, 'YYYY-MM-DD');
        RAISE EXCEPTION '% is a school holiday (%). No attendance is taken.',
            to_char(p_date, 'DD Mon YYYY'), COALESCE(v_title, 'Holiday');
    ELSIF v_day_type = 'weekly_off' THEN
        RAISE EXCEPTION '% is a weekly off (%). No attendance is taken.',
            to_char(p_date, 'DD Mon YYYY'), trim(to_char(p_date, 'Day'));
    END IF;

    -- Older days are locked. The window is per-school (default 7 days).
    SELECT COALESCE(attendance_backdate_days, 7) INTO v_backdate_days
    FROM core.school_settings
    WHERE tenant_id = p_tenant_id AND school_id = p_school_id
      AND COALESCE(is_deleted, FALSE) = FALSE
    LIMIT 1;
    v_backdate_days := COALESCE(v_backdate_days, 7);

    IF p_date < CURRENT_DATE - v_backdate_days THEN
        RAISE EXCEPTION 'Attendance for % is locked — it can be entered only up to % day(s) back.',
            to_char(p_date, 'DD Mon YYYY'), v_backdate_days;
    END IF;

    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'No students to save.';
    END IF;

    -- Column names are quoted so they match the camelCase JSON keys exactly —
    -- unquoted identifiers fold to lowercase and would never match "studentId".
    SELECT string_agg(DISTINCT COALESCE(i.status, '(blank)'), ', ') INTO v_bad
    FROM jsonb_to_recordset(p_items) AS i("studentId" integer, status text, remarks text)
    WHERE COALESCE(TRIM(i.status), '') NOT IN ('Present', 'Absent', 'Late', 'Leave');
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'Unknown attendance status: %. Use Present, Absent, Late or Leave.', v_bad;
    END IF;

    SELECT string_agg(COALESCE(s.student_name, 'Student #' || COALESCE(i."studentId"::text, '?')), ', ') INTO v_bad
    FROM jsonb_to_recordset(p_items) AS i("studentId" integer, status text, remarks text)
    LEFT JOIN core.students s
           ON s.student_id = i."studentId" AND s.tenant_id = p_tenant_id AND s.school_id = p_school_id
    WHERE i."studentId" IS NULL
       OR i."studentId" NOT IN (SELECT r.student_id
                                FROM core.fn_attendance_register(p_tenant_id, p_school_id, p_class, p_section, p_date) r);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'Not on the % register for %: %.',
            TRIM(p_class) || CASE WHEN COALESCE(TRIM(p_section), '') = '' THEN '' ELSE '-' || TRIM(p_section) END,
            to_char(p_date, 'DD Mon YYYY'), v_bad;
    END IF;

    INSERT INTO core.student_attendance AS a
        (tenant_id, school_id, student_id, attendance_date, status, remarks,
         academic_year, class_name, section, marked_by, marked_at)
    SELECT
        p_tenant_id, p_school_id, s.student_id, to_char(p_date, 'YYYY-MM-DD'),
        TRIM(i.status),
        NULLIF(TRIM(i.remarks), ''),
        -- the register's class, section and session -- not the student's present
        -- row, which after an early promotion is already next session's class
        core.fn_session_on(p_tenant_id, p_school_id, p_date),
        COALESCE(e.class_name, TRIM(p_class)), COALESCE(e.section, NULLIF(TRIM(p_section), '')),
        p_action_user_id, now()
    FROM jsonb_to_recordset(p_items) AS i("studentId" integer, status text, remarks text)
    JOIN core.students s
      ON s.student_id = i."studentId"
     AND s.tenant_id  = p_tenant_id
     AND s.school_id  = p_school_id
    LEFT JOIN core.student_enrolment e
      ON e.student_id = s.student_id
     AND e.academic_year = core.fn_session_on(p_tenant_id, p_school_id, p_date)
    ON CONFLICT (tenant_id, school_id, student_id, attendance_date) DO UPDATE
        SET status     = EXCLUDED.status,
            remarks    = EXCLUDED.remarks,
            updated_by = p_action_user_id,
            updated_at = now()
        WHERE a.status  IS DISTINCT FROM EXCLUDED.status
           OR a.remarks IS DISTINCT FROM EXCLUDED.remarks;

    v_saved := jsonb_array_length(p_items);

    OPEN p_result FOR
    SELECT TRUE AS success,
           'Attendance saved for ' || v_saved || ' student(s).' AS message,
           v_saved AS saved;
END;
$procedure$;

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
    -- class-section's registers they belonged to -- decided day by day by the same
    -- register the teacher marks (core.fn_attendance_register), so a child of
    -- another session never counts here.
    OPEN p_students FOR
    WITH reg AS (
        SELECT DISTINCT a.attendance_date::date AS d
        FROM core.student_attendance a
        WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
          AND a.attendance_date::date BETWEEN v_start AND v_end
          AND LOWER(a.class_name) = v_cls AND LOWER(COALESCE(a.section, '')) = v_sec
    ),
    onreg AS (
        SELECT r.d, x.student_id
        FROM reg r
        CROSS JOIN LATERAL core.fn_attendance_register(p_tenant_id, p_school_id, p_class, p_section, r.d) x
    ),
    cand AS (
        SELECT student_id FROM onreg
        UNION
        -- on the register now, even before a day is marked this month
        SELECT x.student_id
        FROM core.fn_attendance_register(p_tenant_id, p_school_id, p_class, p_section, LEAST(v_end, CURRENT_DATE)) x
        WHERE LEAST(v_end, CURRENT_DATE) >= v_start
    )
    SELECT s.student_id,
           COALESCE(NULLIF(TRIM(e.roll_no), ''), s.roll_no) AS roll_no,
           s.student_name,
           (SELECT COUNT(*) FROM onreg o WHERE o.student_id = s.student_id)::int AS school_days
    FROM cand c
    JOIN core.students s ON s.student_id = c.student_id
    LEFT JOIN core.student_enrolment e
           ON e.student_id = s.student_id
          AND e.academic_year = core.fn_session_on(p_tenant_id, p_school_id, v_start)
    ORDER BY
        CASE WHEN COALESCE(NULLIF(TRIM(e.roll_no), ''), s.roll_no) ~ '^[0-9]+$'
             THEN lpad(COALESCE(NULLIF(TRIM(e.roll_no), ''), s.roll_no), 6, '0') ELSE NULL END NULLS LAST,
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
               -- the section's roll for this session (core.student_enrolment): a child
               -- promoted early still belongs here until the session ends
               (SELECT COUNT(*) FROM core.student_enrolment e
                 WHERE e.tenant_id = p_tenant_id AND e.school_id = p_school_id
                   AND e.academic_year = v_year AND COALESCE(e.status, '') NOT IN ('Left', 'PassedOut')
                   AND e.class_name = c.class_name AND lower(COALESCE(e.section, '')) = lower(sec.section_name))::int AS students,
               sec.class_teacher_staff_id, st.full_name,
               -- the day the section's first (active) student was admitted
               COALESCE((SELECT MIN(NULLIF(s.admission_date, '')::date)
                           FROM core.student_enrolment e JOIN core.students s ON s.student_id = e.student_id
                          WHERE e.tenant_id = p_tenant_id AND e.school_id = p_school_id
                            AND e.academic_year = v_year AND COALESCE(e.status, '') NOT IN ('Left', 'PassedOut')
                            AND e.class_name = c.class_name AND lower(COALESCE(e.section, '')) = lower(sec.section_name)), v_start) AS start_on
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

-- ============================================================================
-- The landing dashboard, from real data.
--
-- This is the first page every user sees after signing in, and every number on
-- it was hardcoded — the same ₹13,201 and ₹1,41,912 for every school.
--
-- WHAT IS NOT IN HERE, and why. Three cards on that page cannot be answered
-- from anything the app records, so they are not faked:
--
--   * "Income vs Expense" — there is no expense module at all. Income alone on a
--     chart labelled income-vs-expense is worse than no chart.
--   * "Collection Target" — no target is configured anywhere; a progress ring
--     against an invented target means nothing.
--   * "Notice Board" — there is no notices table.
--
--   The calling page hides those cards rather than drawing empty ones.
--
-- CONVENTIONS kept in step with the rest of the app:
--   * Collection is read through core.fn_fee_money_lines (fee_day_close.sql),
--     exactly as Day Close and the Collection Register read it: a receipt counts
--     on the day it was issued, a cancellation is a negative on the day it was
--     cancelled (so yesterday's figure never changes), and modes are the real
--     tenders, never "Mixed". Apply this file AFTER fee_day_close.sql.
--   * Outstanding is read from core.student_ledger, the single source of truth
--     for money — never recomputed from payments. It is what has FALLEN DUE
--     (due_date on or before today), the same rule as Defaulters and the Fee Due
--     list; next months' instalments are not a debt yet. Students who have left
--     still count while they owe.
--   * "Today's attendance" counts only classes that actually took a register;
--     a class nobody marked is not a class that was absent.
--
-- Nine cursors, one round trip. The page draws a dozen cards and would otherwise
-- make a dozen calls on every sign-in.
--
-- Target DB: PostgreSQL. Safe to re-run.
-- ============================================================================

CREATE OR REPLACE PROCEDURE core.sp_dashboard_summary(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    INOUT p_kpi            refcursor DEFAULT 'db_kpi'::refcursor,
    INOUT p_trend          refcursor DEFAULT 'db_trend'::refcursor,
    INOUT p_classes        refcursor DEFAULT 'db_classes'::refcursor,
    INOUT p_modes          refcursor DEFAULT 'db_modes'::refcursor,
    INOUT p_defaulters     refcursor DEFAULT 'db_defaulters'::refcursor,
    INOUT p_recent         refcursor DEFAULT 'db_recent'::refcursor,
    INOUT p_approvals      refcursor DEFAULT 'db_approvals'::refcursor,
    INOUT p_events         refcursor DEFAULT 'db_events'::refcursor,
    INOUT p_birthdays      refcursor DEFAULT 'db_birthdays'::refcursor)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        OPEN p_kpi FOR SELECT 0 AS students, 0 AS staff, 0::numeric AS today_collection,
                              0::numeric AS outstanding, 0 AS due_students, 0 AS on_leave_today,
                              0::numeric AS yesterday_collection, 0 AS present_today,
                              0 AS marked_today;
        OPEN p_trend      FOR SELECT NULL::date AS d, 0::numeric AS amount WHERE FALSE;
        OPEN p_classes    FOR SELECT NULL::text AS class_name, 0 AS students WHERE FALSE;
        OPEN p_modes      FOR SELECT NULL::text AS mode, 0::numeric AS amount WHERE FALSE;
        OPEN p_defaulters FOR SELECT NULL::int AS student_id, NULL::text AS student_name WHERE FALSE;
        OPEN p_recent     FOR SELECT NULL::text AS receipt_no WHERE FALSE;
        OPEN p_approvals  FOR SELECT NULL::int AS leave_id WHERE FALSE;
        OPEN p_events     FOR SELECT NULL::date AS calendar_date WHERE FALSE;
        OPEN p_birthdays  FOR SELECT NULL::text AS name WHERE FALSE;
        RETURN;
    END IF;

    -- ── 1. Headline numbers ─────────────────────────────────────────────────
    OPEN p_kpi FOR
    SELECT
        -- Students on the roll of the session in progress (core.student_enrolment):
        -- a child admitted for next session does not count yet, a child promoted
        -- early still counts here until this session ends.
        (SELECT COUNT(DISTINCT e.student_id) FROM core.student_enrolment e
          WHERE e.tenant_id = p_tenant_id AND e.school_id = p_school_id
            AND e.academic_year = core.fn_session_on(p_tenant_id, p_school_id, CURRENT_DATE)
            AND COALESCE(e.status, '') NOT IN ('Left', 'PassedOut'))::int
            AS students,

        (SELECT COUNT(*) FROM core.staff st
          WHERE st.tenant_id = p_tenant_id AND st.school_id = p_school_id
            AND st.is_deleted = FALSE AND COALESCE(st.status,'Active') = 'Active')::int
            AS staff,

        -- Receipts issued today minus cancellations made today.
        (SELECT COALESCE(SUM(ml.amount), 0)
           FROM core.fn_fee_money_lines(p_tenant_id, p_school_id, CURRENT_DATE, CURRENT_DATE) ml)
            AS today_collection,

        (SELECT COALESCE(SUM(ml.amount), 0)
           FROM core.fn_fee_money_lines(p_tenant_id, p_school_id, CURRENT_DATE - 1, CURRENT_DATE - 1) ml)
            AS yesterday_collection,

        -- The ledger is the single source of truth for what is owed: rows that
        -- have fallen due, for students of this school.
        (SELECT COALESCE(SUM(l.amount_due - l.amount_paid - COALESCE(l.concession,0)), 0)
           FROM core.student_ledger l
           JOIN core.students s ON s.student_id = l.student_id
                               AND s.tenant_id = p_tenant_id AND s.school_id = p_school_id
          WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
            AND l.amount_due > l.amount_paid + COALESCE(l.concession,0)
            AND (l.due_date IS NULL OR l.due_date::date <= CURRENT_DATE))
            AS outstanding,

        (SELECT COUNT(DISTINCT l.student_id) FROM core.student_ledger l
           JOIN core.students s ON s.student_id = l.student_id
                               AND s.tenant_id = p_tenant_id AND s.school_id = p_school_id
          WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
            AND l.amount_due > l.amount_paid + COALESCE(l.concession,0)
            AND (l.due_date IS NULL OR l.due_date::date <= CURRENT_DATE))::int
            AS due_students,

        (SELECT COUNT(*) FROM core.staff_leave sl
          WHERE sl.tenant_id = p_tenant_id AND sl.school_id = p_school_id
            AND sl.status = 'Approved'
            AND CURRENT_DATE BETWEEN sl.from_date::date AND sl.to_date::date)::int
            AS on_leave_today,

        -- Today's attendance, over students whose class actually took a register.
        (SELECT COUNT(*) FROM core.student_attendance a
          WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
            AND a.attendance_date::date = CURRENT_DATE
            AND a.status NOT IN ('Absent', 'Leave'))::int
            AS present_today,

        (SELECT COUNT(*) FROM core.student_attendance a
          WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
            AND a.attendance_date::date = CURRENT_DATE)::int
            AS marked_today;

    -- ── 2. Collection, last 7 days ──────────────────────────────────────────
    -- generate_series so a day with no receipts is a zero on the chart rather
    -- than a missing point the line would skip over.
    OPEN p_trend FOR
    SELECT g.d::date AS d,
           COALESCE((SELECT SUM(ml.amount)
                       FROM core.fn_fee_money_lines(p_tenant_id, p_school_id, g.d::date, g.d::date) ml), 0) AS amount
    FROM generate_series(CURRENT_DATE - 6, CURRENT_DATE, INTERVAL '1 day') AS g(d)
    ORDER BY d;

    -- ── 3. Class-wise strength ──────────────────────────────────────────────
    -- The same roll, per class. The class is joined by its id: matching the name
    -- found it once per session, so every count doubled once a second session existed.
    OPEN p_classes FOR
    SELECT e.class_name, COUNT(DISTINCT e.student_id)::int AS students
    FROM core.student_enrolment e
    LEFT JOIN academic.academic_classes ac ON ac.academic_class_id = e.academic_class_id
    WHERE e.tenant_id = p_tenant_id AND e.school_id = p_school_id
      AND e.academic_year = core.fn_session_on(p_tenant_id, p_school_id, CURRENT_DATE)
      AND COALESCE(e.status, '') NOT IN ('Left', 'PassedOut')
    GROUP BY e.class_name
    ORDER BY MIN(COALESCE(ac.display_order, 9999)), e.class_name;   -- teaching order

    -- ── 4. Collection by payment mode, this month ───────────────────────────
    OPEN p_modes FOR
    -- By real tender. 'Advance' (paid from the wallet) and 'To wallet' (surplus
    -- saved to it) are not new money in a mode, so the chart leaves them out.
    SELECT ml.mode, SUM(ml.amount) AS amount
    FROM core.fn_fee_money_lines(p_tenant_id, p_school_id,
                                 DATE_TRUNC('month', CURRENT_DATE)::date, CURRENT_DATE) ml
    WHERE ml.mode NOT IN ('Advance', 'To wallet')
    GROUP BY ml.mode
    HAVING SUM(ml.amount) <> 0
    ORDER BY amount DESC;

    -- ── 5. Highest outstanding ──────────────────────────────────────────────
    OPEN p_defaulters FOR
    -- The ledger is summed FIRST and the last payment looked up on its own:
    -- joining payments into the ledger GROUP BY multiplied every figure by the
    -- number of receipts the student had.
    SELECT s.student_id, s.public_id, s.student_name, s.class_name, s.section,
           l.total, l.paid, l.due,
           (SELECT MAX(fp.payment_date) FROM core.fee_payments fp
             WHERE fp.tenant_id = p_tenant_id AND fp.school_id = p_school_id
               AND fp.student_id = s.student_id
               AND COALESCE(fp.is_cancelled, FALSE) = FALSE) AS last_payment
    FROM (SELECT ll.student_id,
                 SUM(ll.amount_due)  AS total,
                 SUM(ll.amount_paid) AS paid,
                 COALESCE(SUM(ll.amount_due - ll.amount_paid - COALESCE(ll.concession,0))
                          FILTER (WHERE ll.amount_due > ll.amount_paid + COALESCE(ll.concession,0)
                                    AND (ll.due_date IS NULL OR ll.due_date::date <= CURRENT_DATE)), 0) AS due
          FROM core.student_ledger ll
          WHERE ll.tenant_id = p_tenant_id AND ll.school_id = p_school_id
          GROUP BY ll.student_id) l
    JOIN core.students s ON s.student_id = l.student_id
                        AND s.tenant_id = p_tenant_id AND s.school_id = p_school_id
    WHERE l.due > 0
    ORDER BY l.due DESC
    LIMIT 10;

    -- ── 6. Recent receipts ──────────────────────────────────────────────────
    OPEN p_recent FOR
    -- A registration receipt has no student yet: name it from the enquiry.
    SELECT fp.receipt_no, fp.amount, fp.payment_mode, fp.payment_date,
           COALESCE(s.student_name, e.student_name) AS student_name,
           COALESCE(s.class_name, e.class_name)     AS class_name
    FROM core.fee_payments fp
    LEFT JOIN core.students  s ON s.student_id = fp.student_id
    LEFT JOIN core.enquiries e ON e.enquiry_id = fp.enquiry_id
    WHERE fp.tenant_id = p_tenant_id AND fp.school_id = p_school_id
      AND COALESCE(fp.is_cancelled, FALSE) = FALSE
    ORDER BY fp.payment_date DESC, fp.payment_id DESC
    LIMIT 8;

    -- ── 7. Pending approvals (leave is the only approval queue that exists) ─
    OPEN p_approvals FOR
    SELECT sl.leave_id, st.full_name, sl.leave_type, sl.from_date, sl.to_date,
           sl.days, sl.applied_at
    FROM core.staff_leave sl
    JOIN core.staff st ON st.staff_id = sl.staff_id
    WHERE sl.tenant_id = p_tenant_id AND sl.school_id = p_school_id
      AND sl.status = 'Pending'
    ORDER BY sl.applied_at
    LIMIT 8;

    -- ── 8. Upcoming calendar entries ────────────────────────────────────────
    OPEN p_events FOR
    SELECT c.calendar_date, c.title, c.day_type
    FROM academic.school_calendar c
    WHERE c.tenant_id = p_tenant_id AND c.school_id = p_school_id
      AND c.calendar_date::date >= CURRENT_DATE
    ORDER BY c.calendar_date
    LIMIT 6;

    -- ── 9. Birthdays today, students and staff together ─────────────────────
    -- Matched on day+month so the year (and leap years) do not matter.
    OPEN p_birthdays FOR
    SELECT s.student_name AS name, 'Student' AS who,
           s.class_name AS detail
    FROM core.students s
    WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id AND s.is_active
      AND s.dob IS NOT NULL
      AND EXTRACT(MONTH FROM s.dob::date) = EXTRACT(MONTH FROM CURRENT_DATE)
      AND EXTRACT(DAY   FROM s.dob::date) = EXTRACT(DAY   FROM CURRENT_DATE)
    UNION ALL
    SELECT st.full_name, 'Staff', COALESCE(st.designation, '')
    FROM core.staff st
    WHERE st.tenant_id = p_tenant_id AND st.school_id = p_school_id
      AND st.is_deleted = FALSE AND COALESCE(st.status,'Active') = 'Active'
      AND st.dob IS NOT NULL
      AND EXTRACT(MONTH FROM st.dob::date) = EXTRACT(MONTH FROM CURRENT_DATE)
      AND EXTRACT(DAY   FROM st.dob::date) = EXTRACT(DAY   FROM CURRENT_DATE);
END;
$procedure$;

-- ============================================================================
-- Report cards + Bonafide / Character certificates.
--
-- 1. core.sp_report_card_extras: what a report card needs beyond the exam
--    result (academic.sp_school_admin_exam_results_manage 'GetClassResult'):
--    mother's name and the session's attendance, for a list of students.
--    Attendance counts days exactly like the Student Dashboard
--    (core.fn_attendance_student_days; Present + Late = present).
--
-- 2. core.certificates: Bonafide and Character certificates, numbered
--    BC-YYYY-0001 / CC-YYYY-0001 per school and calendar year, frozen at issue
--    time like the TC (the student row is copied in). A certificate is never
--    deleted; Void keeps the number with a reason.
--      Bonafide  - only for a student studying here now (active).
--      Character - for a current or a former student.
-- Re-runnable.
-- ============================================================================

CREATE OR REPLACE PROCEDURE core.sp_report_card_extras(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_student_ids    integer[],
    IN    p_academic_year  varchar,
    INOUT p_result         refcursor DEFAULT 'report_card_cursor')
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    OPEN p_result FOR
    SELECT s.student_id, s.mother_name, s.guardian_name, s.dob,
           d.school_days, p.present,
           CASE WHEN d.school_days = 0 THEN NULL
                ELSE ROUND(p.present * 100.0 / d.school_days, 1) END AS percent
      FROM core.students s
      CROSS JOIN LATERAL (SELECT COUNT(*)::int AS school_days
                            FROM core.fn_attendance_student_days(p_tenant_id, p_school_id, s.student_id, p_academic_year)) d
      CROSS JOIN LATERAL (SELECT COUNT(*)::int AS present
                            FROM core.student_attendance a
                           WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
                             AND a.student_id = s.student_id AND a.academic_year = p_academic_year
                             AND a.status IN ('Present', 'Late')) p
     WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id
       AND s.student_id = ANY (p_student_ids);
END;
$$;


CREATE TABLE IF NOT EXISTS core.certificate_counters (
    tenant_id  integer     NOT NULL,
    school_id  integer     NOT NULL,
    cert_type  varchar(20) NOT NULL,
    year_no    integer     NOT NULL,
    last_seq   integer     NOT NULL DEFAULT 0,
    PRIMARY KEY (tenant_id, school_id, cert_type, year_no)
);

CREATE TABLE IF NOT EXISTS core.certificates (
    cert_id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       integer      NOT NULL,
    school_id       integer      NOT NULL,
    cert_no         varchar(30)  NOT NULL,
    cert_type       varchar(20)  NOT NULL CHECK (cert_type IN ('Bonafide', 'Character')),
    student_id      integer      NOT NULL,
    -- the student as they were on the day of issue
    student_name    varchar(150) NOT NULL,
    gender          varchar(20),
    father_name     varchar(150),
    mother_name     varchar(150),
    dob             varchar(10),
    admission_no    varchar(50),
    admission_date  varchar(10),
    class_name      varchar(100),
    section         varchar(20),
    academic_year   varchar(20),
    is_current      boolean      NOT NULL,     -- studying here on the day of issue
    date_of_leaving varchar(10),
    -- what the school wrote
    purpose         varchar(200),
    conduct         varchar(30),
    remarks         varchar(300),
    issue_date      date         NOT NULL DEFAULT CURRENT_DATE,
    issued_by       integer      NOT NULL,
    issued_at       timestamptz  NOT NULL DEFAULT now(),
    is_void         boolean      NOT NULL DEFAULT FALSE,
    void_reason     varchar(300),
    voided_by       integer,
    voided_at       timestamptz,
    CONSTRAINT uq_certificate_no UNIQUE (tenant_id, school_id, cert_no)
);


CREATE OR REPLACE PROCEDURE core.sp_certificate_manage(
    IN    p_operation      varchar,          -- Search | Issue | Get | List | Void
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_cert_id        integer DEFAULT NULL,
    IN    p_student_id     integer DEFAULT NULL,
    IN    p_cert_type      varchar DEFAULT NULL,
    IN    p_purpose        varchar DEFAULT NULL,
    IN    p_conduct        varchar DEFAULT NULL,
    IN    p_remarks        varchar DEFAULT NULL,   -- Issue: remarks; Void: the reason
    IN    p_search         varchar DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'certificate_cursor')
LANGUAGE plpgsql
AS $$
DECLARE
    s       record;
    v_type  varchar := NULLIF(trim(p_cert_type), '');
    v_q     varchar := '%' || lower(trim(COALESCE(p_search, ''))) || '%';
    v_year  integer := EXTRACT(YEAR FROM CURRENT_DATE)::int;
    v_seq   integer;
    v_no    varchar;
    v_id    integer;
    v_now   varchar;   -- the session in progress today
    v_cls   varchar;   -- class / section / session printed on the certificate
    v_sec   varchar;
    v_ses   varchar;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    -- ── Search: current AND former students (a character certificate is often for someone who left)
    IF p_operation = 'Search' THEN
        IF length(trim(COALESCE(p_search, ''))) < 2 THEN
            OPEN p_result FOR SELECT NULL::int AS student_id WHERE FALSE;
            RETURN;
        END IF;
        OPEN p_result FOR
        SELECT st.student_id, st.student_name, st.admission_no, st.class_name, st.section, st.academic_year,
               st.guardian_name, st.mobile, COALESCE(st.is_active, TRUE) AS is_current, st.status
          FROM core.students st
         WHERE st.tenant_id = p_tenant_id AND st.school_id = p_school_id
           AND (lower(st.student_name) LIKE v_q OR lower(COALESCE(st.admission_no, '')) LIKE v_q
                OR lower(COALESCE(st.guardian_name, '')) LIKE v_q OR COALESCE(st.mobile, '') LIKE v_q)
         ORDER BY COALESCE(st.is_active, TRUE) DESC, st.student_name
         LIMIT 20;
        RETURN;
    END IF;

    -- ── Issue
    IF p_operation = 'Issue' THEN
        IF v_type NOT IN ('Bonafide', 'Character') OR v_type IS NULL THEN
            RAISE EXCEPTION 'Choose the certificate type.';
        END IF;
        SELECT * INTO s FROM core.students
         WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id;
        IF NOT FOUND THEN RAISE EXCEPTION 'Student not found.'; END IF;
        IF v_type = 'Bonafide' AND NOT COALESCE(s.is_active, TRUE) THEN
            RAISE EXCEPTION 'A bonafide certificate is only for a student studying here now. Issue a character certificate instead.';
        END IF;
        IF v_type = 'Bonafide' AND NULLIF(trim(p_purpose), '') IS NULL THEN
            RAISE EXCEPTION 'Write what the certificate is needed for.';
        END IF;

        -- The class they study in NOW: their enrolment for the session in progress.
        -- A child promoted early is still in the old class until it ends; a child
        -- admitted for next session does not study here yet.
        v_now := core.fn_session_on(p_tenant_id, p_school_id, CURRENT_DATE);
        SELECT e.class_name, e.section, e.academic_year INTO v_cls, v_sec, v_ses
          FROM core.student_enrolment e
         WHERE e.student_id = s.student_id AND e.academic_year = v_now;
        IF v_type = 'Bonafide' AND v_ses IS NULL AND s.academic_year IS DISTINCT FROM v_now THEN
            RAISE EXCEPTION '% is admitted for session %, which has not started. A bonafide certificate can be issued once it starts.',
                s.student_name, s.academic_year;
        END IF;

        INSERT INTO core.certificate_counters (tenant_id, school_id, cert_type, year_no, last_seq)
        VALUES (p_tenant_id, p_school_id, v_type, v_year, 1)
        ON CONFLICT (tenant_id, school_id, cert_type, year_no)
        DO UPDATE SET last_seq = core.certificate_counters.last_seq + 1
        RETURNING last_seq INTO v_seq;
        v_no := CASE v_type WHEN 'Bonafide' THEN 'BC-' ELSE 'CC-' END || v_year || '-' || lpad(v_seq::text, 4, '0');

        INSERT INTO core.certificates (tenant_id, school_id, cert_no, cert_type, student_id, student_name, gender,
                                       father_name, mother_name, dob, admission_no, admission_date, class_name, section,
                                       academic_year, is_current, date_of_leaving, purpose, conduct, remarks, issued_by)
        VALUES (p_tenant_id, p_school_id, v_no, v_type, s.student_id, s.student_name, s.gender,
                s.guardian_name, s.mother_name, s.dob, s.admission_no, s.admission_date,
                COALESCE(v_cls, s.class_name), COALESCE(v_sec, s.section),
                COALESCE(v_ses, s.academic_year), COALESCE(s.is_active, TRUE), s.date_of_leaving,
                NULLIF(trim(p_purpose), ''), COALESCE(NULLIF(trim(p_conduct), ''), 'Good'),
                NULLIF(trim(p_remarks), ''), p_action_user_id)
        RETURNING cert_id INTO v_id;

        OPEN p_result FOR SELECT v_id AS cert_id, v_no AS cert_no,
               (v_type || ' certificate ' || v_no || ' issued.')::varchar AS message;
        RETURN;
    END IF;

    -- ── Get / List
    IF p_operation IN ('Get', 'List') THEN
        OPEN p_result FOR
        SELECT c.cert_id, c.cert_no, c.cert_type, c.student_id, c.student_name, c.gender, c.father_name, c.mother_name,
               c.dob, c.admission_no, c.admission_date, c.class_name, c.section, c.academic_year, c.is_current,
               c.date_of_leaving, c.purpose, c.conduct, c.remarks, to_char(c.issue_date, 'YYYY-MM-DD') AS issue_date,
               c.is_void, c.void_reason
          FROM core.certificates c
         WHERE c.tenant_id = p_tenant_id AND c.school_id = p_school_id
           AND (p_operation = 'List' OR c.cert_id = p_cert_id)
           AND (p_operation = 'Get' OR v_type IS NULL OR c.cert_type = v_type)
           AND (p_operation = 'Get' OR length(trim(COALESCE(p_search, ''))) = 0
                OR lower(c.student_name) LIKE v_q OR lower(c.cert_no) LIKE v_q OR lower(COALESCE(c.admission_no, '')) LIKE v_q)
         ORDER BY c.cert_id DESC
         LIMIT 200;
        RETURN;
    END IF;

    -- ── Void
    IF p_operation = 'Void' THEN
        IF NULLIF(trim(p_remarks), '') IS NULL THEN RAISE EXCEPTION 'Give a reason.'; END IF;
        UPDATE core.certificates
           SET is_void = TRUE, void_reason = trim(p_remarks), voided_by = p_action_user_id, voided_at = now()
         WHERE cert_id = p_cert_id AND tenant_id = p_tenant_id AND school_id = p_school_id AND NOT is_void
        RETURNING cert_id INTO v_id;
        IF v_id IS NULL THEN RAISE EXCEPTION 'Certificate not found or already void.'; END IF;
        OPEN p_result FOR SELECT 'Certificate voided.'::varchar AS message;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation.';
END;
$$;

-- ============================================================
--  Student master expansion — real-ERP admission record
--  Adds identity/demographics, previous school, full parent
--  details, and a documents checklist to core.students, and
--  extends core.sp_admission_manage (SaveAdmission) to persist
--  them. Parameters bind by name (Npgsql StoredProcedure), so
--  the new params are additive and safe for existing callers.
--
--  Depends on student_money_lifecycle.sql (fn_fee_plan_problem,
--  fn_student_bill_plan) -- apply that first.
-- ============================================================

-- ── 1. New columns (idempotent) ─────────────────────────────
ALTER TABLE core.students
    ADD COLUMN IF NOT EXISTS blood_group          varchar(5),
    ADD COLUMN IF NOT EXISTS religion             varchar(40),
    ADD COLUMN IF NOT EXISTS category             varchar(20),   -- General/OBC/SC/ST/EWS
    ADD COLUMN IF NOT EXISTS nationality          varchar(40),
    ADD COLUMN IF NOT EXISTS mother_tongue        varchar(40),
    ADD COLUMN IF NOT EXISTS id_proof_no          varchar(30),   -- Aadhaar / birth-cert no
    ADD COLUMN IF NOT EXISTS prev_school_name     varchar(150),
    ADD COLUMN IF NOT EXISTS prev_board           varchar(40),
    ADD COLUMN IF NOT EXISTS prev_class           varchar(40),
    ADD COLUMN IF NOT EXISTS prev_tc_no           varchar(50),
    ADD COLUMN IF NOT EXISTS father_occupation    varchar(80),
    ADD COLUMN IF NOT EXISTS father_qualification varchar(80),
    ADD COLUMN IF NOT EXISTS father_email         varchar(120),
    ADD COLUMN IF NOT EXISTS mother_occupation    varchar(80),
    ADD COLUMN IF NOT EXISTS mother_qualification varchar(80),
    ADD COLUMN IF NOT EXISTS mother_email         varchar(120),
    ADD COLUMN IF NOT EXISTS annual_income        numeric(12,2),
    ADD COLUMN IF NOT EXISTS documents            jsonb;         -- [{name,status}]

-- ── 2. Replace the admission proc with the extended signature ──
--  Widening the parameter list is a NEW signature, so CREATE OR REPLACE alone
--  would leave the OLD overload behind and calls fail with "procedure is not
--  unique". A hard-coded DROP-by-signature goes stale every time a param is
--  added (that is exactly what bit us), so instead drop ANY overload that
--  predates the current parameter set — identified by the absence of
--  p_apaar_id. After the CREATE below there is always exactly one.
DO $$
DECLARE r record;
BEGIN
    FOR r IN
        SELECT oid FROM pg_proc
        WHERE proname = 'sp_admission_manage'
          AND pg_get_function_identity_arguments(oid) NOT ILIKE '%p_apaar_id%'
    LOOP
        EXECUTE 'DROP PROCEDURE ' || r.oid::regprocedure;
    END LOOP;
END $$;

CREATE OR REPLACE PROCEDURE core.sp_admission_manage(
    IN p_operation text,
    IN p_tenant_id integer,
    IN p_school_id integer,
    IN p_action_user_id integer,
    IN p_student_id integer DEFAULT NULL::integer,
    IN p_admission_no text DEFAULT NULL::text,
    IN p_roll_no text DEFAULT NULL::text,
    IN p_student_name text DEFAULT NULL::text,
    IN p_gender text DEFAULT NULL::text,
    IN p_dob date DEFAULT NULL::date,
    IN p_class_name text DEFAULT NULL::text,
    IN p_section text DEFAULT NULL::text,
    IN p_academic_year text DEFAULT NULL::text,
    IN p_admission_date date DEFAULT NULL::date,
    IN p_guardian_name text DEFAULT NULL::text,
    IN p_mother_name text DEFAULT NULL::text,
    IN p_mobile text DEFAULT NULL::text,
    IN p_alt_mobile text DEFAULT NULL::text,
    IN p_address text DEFAULT NULL::text,
    -- ── new student-master fields ──
    IN p_blood_group text DEFAULT NULL::text,
    IN p_religion text DEFAULT NULL::text,
    IN p_category text DEFAULT NULL::text,
    IN p_nationality text DEFAULT NULL::text,
    IN p_mother_tongue text DEFAULT NULL::text,
    IN p_id_proof_no text DEFAULT NULL::text,
    IN p_apaar_id text DEFAULT NULL::text,
    IN p_udise_student_id text DEFAULT NULL::text,
    IN p_prev_school_name text DEFAULT NULL::text,
    IN p_prev_board text DEFAULT NULL::text,
    IN p_prev_class text DEFAULT NULL::text,
    IN p_prev_tc_no text DEFAULT NULL::text,
    IN p_father_occupation text DEFAULT NULL::text,
    IN p_father_qualification text DEFAULT NULL::text,
    IN p_father_email text DEFAULT NULL::text,
    IN p_mother_occupation text DEFAULT NULL::text,
    IN p_mother_qualification text DEFAULT NULL::text,
    IN p_mother_email text DEFAULT NULL::text,
    IN p_annual_income numeric DEFAULT NULL::numeric,
    IN p_documents jsonb DEFAULT NULL::jsonb,
    -- ── fee snapshot / concession ──
    IN p_pay_today_total numeric DEFAULT 0,
    IN p_monthly_total numeric DEFAULT 0,
    IN p_yearly_total numeric DEFAULT 0,
    IN p_annual_total numeric DEFAULT 0,
    IN p_concession_type text DEFAULT NULL::text,
    IN p_concession_value numeric DEFAULT 0,
    IN p_concession_amount numeric DEFAULT 0,
    IN p_concession_reason text DEFAULT NULL::text,
    IN p_concession_cap numeric DEFAULT 100000,
    IN p_fee_plan_json jsonb DEFAULT NULL::jsonb,
    IN p_enquiry_id integer DEFAULT NULL::integer,
    -- ── list/filter ──
    IN p_page_number integer DEFAULT 1,
    IN p_page_size integer DEFAULT 10,
    IN p_search text DEFAULT NULL::text,
    IN p_filter_class text DEFAULT NULL::text,
    IN p_filter_section text DEFAULT NULL::text,
    IN p_filter_gender text DEFAULT NULL::text,
    IN p_filter_year text DEFAULT NULL::text,
    IN p_filter_status text DEFAULT NULL::text,
    INOUT p_result refcursor DEFAULT 'admission_cursor'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_student_id    INTEGER;
    v_admission_no  TEXT;
    v_seq           INTEGER;
    v_year          VARCHAR(20);
    v_adm_date      DATE;
    v_approval      VARCHAR(20);
    v_dup           INTEGER;
    v_item          JSONB;
    v_month_start   DATE;
    v_month_end     DATE;
    v_m             DATE;
    v_i             INTEGER;
    v_sess_start    DATE;
    v_sess_end      DATE;
    v_charge_from   VARCHAR(20);
    v_freq          VARCHAR(30);
    v_step          INTEGER;
    v_period_end    DATE;
    v_sess_month    DATE;
    v_cycles        INTEGER;
    v_reg_balance   NUMERIC;
    v_reg_agreed    NUMERIC;
    v_roll          TEXT;
    v_dup_adm       TEXT;
BEGIN

    -- ── SaveAdmission ────────────────────────────────────────
    IF p_operation = 'SaveAdmission' THEN

        IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
            OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                'Invalid tenant/school context.' AS message, NULL::TEXT AS admission_no;
            RETURN;
        END IF;

        v_year     := COALESCE(p_academic_year, '');
        v_adm_date := COALESCE(p_admission_date, CURRENT_DATE);

        -- ── What a student record must have to be a student ──────────────────
        -- The screen asks for these and the controller re-checks them, but the
        -- proc is the last thing between a request and a real child's record, and
        -- it used to accept anything. Each refusal below was reproduced first: a
        -- student with a blank name, one sitting in a class that does not exist,
        -- one admitted in 2027, and one born after the day they joined.
        IF COALESCE(TRIM(p_student_name), '') = '' THEN
            OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                'Student name is required.' AS message, NULL::TEXT AS admission_no;
            RETURN;
        END IF;

        -- A student in a class that does not exist is an orphan: no class list
        -- shows them, no fee structure matches, and promotion cannot move them.
        IF COALESCE(TRIM(p_class_name), '') = '' OR NOT EXISTS (
               SELECT 1 FROM academic.academic_classes ac
               JOIN academic.academic_years ay
                 ON ay.academic_year_id = ac.academic_year_id
               WHERE ac.tenant_id = p_tenant_id AND ac.school_id = p_school_id
                 AND ac.class_name = TRIM(p_class_name)
                 AND ay.academic_year_name = v_year
                 AND COALESCE(ac.is_deleted, FALSE) = FALSE) THEN
            OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                format('%s is not a class in %s.', COALESCE(NULLIF(TRIM(p_class_name),''),'(blank)'), v_year) AS message,
                NULL::TEXT AS admission_no;
            RETURN;
        END IF;

        -- Nobody is admitted for a day that has not happened. A future date also
        -- lands the first instalment outside the session it belongs to.
        IF v_adm_date > CURRENT_DATE THEN
            OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                'Admission date cannot be in the future.' AS message, NULL::TEXT AS admission_no;
            RETURN;
        END IF;

        IF p_dob IS NOT NULL AND p_dob > CURRENT_DATE THEN
            OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                'Date of birth cannot be in the future.' AS message, NULL::TEXT AS admission_no;
            RETURN;
        END IF;

        IF p_dob IS NOT NULL AND p_dob > v_adm_date THEN
            OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                'Date of birth cannot be after the admission date.' AS message,
                NULL::TEXT AS admission_no;
            RETURN;
        END IF;

        -- Session window AND its billing policy, from the one row that owns both.
        -- The window drives session-end-aware billing (a mid-session joiner is
        -- billed only up to the session's end month). "Charge recurring fees
        -- from" is AdmissionMonth (default, real-world norm — pay only enrolled
        -- months) or SessionStart (the full session from April). It lives on the
        -- year, not the school, so a session cannot be re-billed by a setting
        -- someone changed months later — see fee_charge_from_per_year.sql.
        SELECT start_date, end_date,
               COALESCE(NULLIF(TRIM(charge_fees_from), ''), 'AdmissionMonth')
          INTO v_sess_start, v_sess_end, v_charge_from
        FROM academic.academic_years
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND academic_year_name = v_year
          AND COALESCE(is_deleted, FALSE) = FALSE
        LIMIT 1;

        -- No matching year row (a back-dated or free-typed session name).
        v_charge_from := COALESCE(v_charge_from, 'AdmissionMonth');

        -- The fee plan arrives from the admission form. A negative amount or the
        -- same head twice is refused before anything is written.
        IF core.fn_fee_plan_problem(p_fee_plan_json) IS NOT NULL THEN
            OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                core.fn_fee_plan_problem(p_fee_plan_json) AS message, NULL::TEXT AS admission_no;
            RETURN;
        END IF;

        -- An enquiry becomes ONE student. The row is locked so two clerks
        -- converting the same enquiry at once cannot both get through.
        IF p_enquiry_id IS NOT NULL AND p_enquiry_id > 0 THEN
            PERFORM 1 FROM core.enquiries
             WHERE enquiry_id = p_enquiry_id
               AND tenant_id = p_tenant_id AND school_id = p_school_id
               FOR UPDATE;
            IF EXISTS (SELECT 1 FROM core.enquiries e
                        JOIN core.students s ON s.student_id = e.admission_id
                       WHERE e.enquiry_id = p_enquiry_id
                         AND e.tenant_id = p_tenant_id AND e.school_id = p_school_id) THEN
                OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                    'This enquiry has already been admitted.' AS message, NULL::TEXT AS admission_no;
                RETURN;
            END IF;
        END IF;

        -- Two identical submits arriving together both passed the COUNT below
        -- before either inserted. A transaction-scoped advisory lock on the
        -- same name + dob + mobile makes the second one wait for the first and
        -- then see its row. Released automatically at commit / rollback.
        PERFORM pg_advisory_xact_lock(hashtext(
            'admission:' || p_tenant_id || ':' || p_school_id || ':' ||
            regexp_replace(LOWER(TRIM(COALESCE(p_student_name, ''))), '\s+', ' ', 'g') || ':' ||
            COALESCE(p_dob::text, '') || ':' || COALESCE(p_mobile, '')));

        -- Duplicate guard: same name + dob + mobile already admitted. Name is
        -- whitespace-collapsed + lower-cased so trivial typos ("Rahul  Kumar" vs
        -- "Rahul Kumar", different casing) no longer slip a duplicate through.
        SELECT COUNT(*) INTO v_dup
        FROM core.students
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND is_active = TRUE
          AND regexp_replace(LOWER(TRIM(student_name)), '\s+', ' ', 'g')
              = regexp_replace(LOWER(TRIM(COALESCE(p_student_name, ''))), '\s+', ' ', 'g')
          AND COALESCE(dob::date, DATE '1900-01-01') = COALESCE(p_dob, DATE '1900-01-01')
          AND COALESCE(mobile, '') = COALESCE(p_mobile, '');
        IF v_dup > 0 THEN
            OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                'A student with the same name, DOB and mobile already exists.' AS message,
                NULL::TEXT AS admission_no;
            RETURN;
        END IF;

        -- The same child who LEFT earlier in this session comes back: re-admit the
        -- old record (Students > Left Students > Re-admit) so their history, dues
        -- and admission number stay one record, instead of making a second student.
        SELECT admission_no INTO v_dup_adm
        FROM core.students
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND is_active = FALSE
          AND academic_year = v_year
          AND regexp_replace(LOWER(TRIM(student_name)), '\s+', ' ', 'g')
              = regexp_replace(LOWER(TRIM(COALESCE(p_student_name, ''))), '\s+', ' ', 'g')
          AND COALESCE(dob::date, DATE '1900-01-01') = COALESCE(p_dob, DATE '1900-01-01')
          AND COALESCE(mobile, '') = COALESCE(p_mobile, '')
        LIMIT 1;
        IF v_dup_adm IS NOT NULL THEN
            OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                'This child left earlier this session (' || v_dup_adm || '). Re-admit them from Students > Left Students instead of a new admission.' AS message,
                NULL::TEXT AS admission_no;
            RETURN;
        END IF;

        -- Aadhaar: 12 digits when filled (the same rule as Edit Student).
        IF NULLIF(TRIM(COALESCE(p_id_proof_no, '')), '') IS NOT NULL
           AND TRIM(p_id_proof_no) !~ '^[0-9]{12}$' THEN
            OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                'Aadhaar number must be 12 digits.' AS message, NULL::TEXT AS admission_no;
            RETURN;
        END IF;

        -- A roll number belongs to one child per class + section + session.
        -- (core.fn_session_rolls also counts children promoted out of it early)
        IF NULLIF(TRIM(COALESCE(p_roll_no, '')), '') IS NOT NULL AND EXISTS (
               SELECT 1 FROM core.fn_session_rolls(p_tenant_id, p_school_id, v_year, p_class_name, p_section) o
                WHERE LOWER(TRIM(o.roll_no)) = LOWER(TRIM(p_roll_no))) THEN
            OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                format('Roll no %s is already used in %s.', TRIM(p_roll_no),
                       TRIM(p_class_name) || COALESCE('-' || NULLIF(TRIM(p_section), ''), '')) AS message,
                NULL::TEXT AS admission_no;
            RETURN;
        END IF;

        -- No roll number typed: give the next one in the class + section
        -- (highest numeric roll + 1), so a new child is never "-" on the register,
        -- admit card or result sheet (QA BUG-074). It can be changed in Edit Student.
        v_roll := NULLIF(TRIM(COALESCE(p_roll_no, '')), '');
        IF v_roll IS NULL AND NULLIF(TRIM(COALESCE(p_section, '')), '') IS NOT NULL THEN
            SELECT (COALESCE(MAX(TRIM(o.roll_no)::int), 0) + 1)::text INTO v_roll
              FROM core.fn_session_rolls(p_tenant_id, p_school_id, v_year, p_class_name, p_section) o
             WHERE TRIM(o.roll_no) ~ '^[0-9]{1,6}$';
        END IF;

        -- Admission number: use supplied value or auto-generate per school+year
        IF p_admission_no IS NULL OR TRIM(p_admission_no) = '' THEN
            INSERT INTO core.admission_counters (tenant_id, school_id, academic_year, last_seq)
            VALUES (p_tenant_id, p_school_id, v_year, 1)
            ON CONFLICT (tenant_id, school_id, academic_year)
            DO UPDATE SET last_seq = core.admission_counters.last_seq + 1
            RETURNING last_seq INTO v_seq;

            -- LEFT(v_year, 4) took the first four characters of the session's
            -- NAME, so "FY 26-27" produced ADM-FY 2-0002. core.fn_receipt_year
            -- was written for exactly this when receipt numbers hit it; the
            -- admission number was left on the old expression. It reads the
            -- session's real start date, falls back to any four-digit year in the
            -- name, then to the admission date.
            v_admission_no := 'ADM-' ||
                core.fn_receipt_year(p_tenant_id, p_school_id, v_year, v_adm_date) ||
                '-' || LPAD(v_seq::TEXT, 4, '0');
        ELSE
            -- Normalise a typed number before it becomes this child's identity.
            -- TRIM alone was not enough: 'ADM-2026-0099' and 'adm-2026-0099'
            -- passed the collision check as different strings, so two students
            -- ended up holding the same admission number. Upper-case it and
            -- collapse any inner run of spaces, then compare the same way.
            v_admission_no := UPPER(REGEXP_REPLACE(TRIM(p_admission_no), '\s+', ' ', 'g'));

            -- Reject collision with an existing admission number. Compared on
            -- the normalised form so an old row typed in another case still
            -- counts as taken.
            IF EXISTS (SELECT 1 FROM core.students
                       WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                         AND UPPER(REGEXP_REPLACE(TRIM(admission_no), '\s+', ' ', 'g'))
                             = v_admission_no) THEN
                OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                    'Admission number already in use.' AS message,
                    v_admission_no AS admission_no;
                RETURN;
            END IF;
        END IF;

        -- Concession approval gate
        v_approval := CASE WHEN COALESCE(p_concession_amount, 0) > COALESCE(p_concession_cap, 100000)
                           THEN 'Pending Approval' ELSE 'Approved' END;

        INSERT INTO core.students (
            tenant_id, school_id,
            admission_no, roll_no, student_name, gender, dob,
            class_name, section, academic_year, admission_date,
            guardian_name, mother_name, mobile, alt_mobile, address,
            blood_group, religion, category, nationality, mother_tongue, id_proof_no,
            apaar_id, udise_student_id,
            prev_school_name, prev_board, prev_class, prev_tc_no,
            father_occupation, father_qualification, father_email,
            mother_occupation, mother_qualification, mother_email,
            annual_income, documents,
            pay_today_total, monthly_total, yearly_total, annual_total,
            concession_type, concession_value, concession_amount, concession_reason,
            enquiry_id, status, approval_status,
            created_by, updated_by
        ) VALUES (
            p_tenant_id, p_school_id,
            v_admission_no, v_roll, p_student_name, p_gender, p_dob,
            p_class_name, p_section, v_year, v_adm_date,
            p_guardian_name, p_mother_name, p_mobile, p_alt_mobile, p_address,
            p_blood_group, p_religion, p_category, p_nationality, p_mother_tongue, p_id_proof_no,
            p_apaar_id, p_udise_student_id,
            p_prev_school_name, p_prev_board, p_prev_class, p_prev_tc_no,
            p_father_occupation, p_father_qualification, p_father_email,
            p_mother_occupation, p_mother_qualification, p_mother_email,
            p_annual_income, p_documents,
            COALESCE(p_pay_today_total, 0), COALESCE(p_monthly_total, 0),
            COALESCE(p_yearly_total, 0), COALESCE(p_annual_total, 0),
            p_concession_type, COALESCE(p_concession_value, 0),
            COALESCE(p_concession_amount, 0), p_concession_reason,
            p_enquiry_id, 'Active', v_approval,
            p_action_user_id, p_action_user_id
        )
        RETURNING student_id INTO v_student_id;

        -- Open the student's first enrolment row (see student_enrolment.sql).
        -- core.students still carries class/section/year; this is the parallel
        -- per-session record that keeps the history once they are promoted.
        PERFORM core.fn_student_enrolment_open(
            p_tenant_id, p_school_id, v_student_id,
            v_year, p_class_name, p_section, v_roll, p_action_user_id);

        -- Freeze the fee plan + generate ledger rows. The month arithmetic
        -- (charge-from policy, quarter snapping, session end) moved to
        -- core.fn_plan_periods / core.fn_student_bill_plan in
        -- student_money_lifecycle.sql, so promotion and a class change bill a
        -- plan exactly the way admission does. The plan was validated above.
        PERFORM core.fn_student_bill_plan(
            p_tenant_id, p_school_id, p_action_user_id, v_student_id,
            v_year, v_adm_date, p_fee_plan_json);

        -- Carry an unpaid registration balance onto the student as a real due.
        -- A family can pay part of the registration fee (registration_fee_partial.sql)
        -- and the remainder is derived from the receipts against their enquiry. That
        -- works until the enquiry becomes a student: every screen that chases money
        -- reads core.student_ledger, which is keyed on student_id, so from that moment
        -- the balance would sit on a record nobody opens again and never be collected.
        -- It becomes an ordinary due here -- visible at the fee counter, in the due
        -- list, on reminders and in the reports -- in the same transaction as the
        -- admission, because a balance that can be lost between two calls is a bug
        -- this codebase has been bitten by before.
        --
        -- The agreed fee is frozen on the enquiry only by the FIRST receipt
        -- (sp_registration_fee_record). A family registered without paying anything
        -- therefore had 0 agreed, 0 - 0 = 0 was carried, and the whole fee vanished
        -- at admission (QA BUG-046). When nothing was agreed, a registered enquiry
        -- falls back to the fee the registration screen asks for -- the class-wise
        -- Registration-point amount from the Fee Structure, else the active
        -- Registration heads' default amounts (SchoolSettingsService.
        -- GetCollectionPointResolvedTotalAsync) -- but only while the school has
        -- the registration fee switched on. That amount is frozen on the enquiry so
        -- its "Fee Pending" badge clears once the carried due is paid.
        --
        -- Nothing sums an enquiry's balance into a student's dues, so this is not
        -- double counting.
        IF p_enquiry_id IS NOT NULL AND p_enquiry_id > 0 THEN
            SELECT COALESCE(e.registration_fee_amount, 0)
              INTO v_reg_agreed
            FROM core.enquiries e
            WHERE e.enquiry_id = p_enquiry_id
              AND e.tenant_id = p_tenant_id AND e.school_id = p_school_id;

            IF COALESCE(v_reg_agreed, 0) <= 0 THEN
                SELECT COALESCE(
                         (SELECT NULLIF(SUM(d.amount), 0)
                            FROM core.school_fee_structures s
                            JOIN core.school_fee_structure_details d ON d.fee_structure_id = s.fee_structure_id
                            JOIN core.school_fee_heads h             ON h.fee_head_id = d.fee_head_id
                           WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id
                             AND s.class_name = e.class_name AND s.academic_year = e.session
                             AND COALESCE(s.is_deleted, FALSE) = FALSE
                             AND COALESCE(d.is_deleted, FALSE) = FALSE
                             AND COALESCE(d.is_selected, FALSE)
                             AND h.collection_point = 'Registration'),
                         (SELECT SUM(h.default_amount)
                            FROM core.school_fee_heads h
                           WHERE h.tenant_id = p_tenant_id AND h.school_id = p_school_id
                             AND COALESCE(h.is_active, TRUE)
                             AND COALESCE(h.is_deleted, FALSE) = FALSE
                             AND h.collection_point = 'Registration'),
                         0)
                  INTO v_reg_agreed
                FROM core.enquiries e
                WHERE e.enquiry_id = p_enquiry_id
                  AND e.tenant_id = p_tenant_id AND e.school_id = p_school_id
                  AND COALESCE(TRIM(e.registration_number), '') <> ''
                  AND EXISTS (SELECT 1 FROM core.school_admission_workflow_settings w
                               WHERE w.tenant_id = p_tenant_id AND w.school_id = p_school_id
                                 AND COALESCE(w.is_deleted, FALSE) = FALSE
                                 AND COALESCE(w.enable_registration, FALSE)
                                 AND COALESCE(w.enable_registration_fee, FALSE));

                IF COALESCE(v_reg_agreed, 0) > 0 THEN
                    UPDATE core.enquiries
                       SET registration_fee_amount = ROUND(v_reg_agreed, 2)
                     WHERE enquiry_id = p_enquiry_id
                       AND tenant_id = p_tenant_id AND school_id = p_school_id
                       AND COALESCE(registration_fee_amount, 0) = 0;
                END IF;
            END IF;

            v_reg_balance := COALESCE(v_reg_agreed, 0)
                             - core.fn_registration_fee_settled(p_tenant_id, p_school_id, p_enquiry_id);

            IF COALESCE(v_reg_balance, 0) > 0.005 THEN
                INSERT INTO core.student_ledger (
                    tenant_id, school_id, student_id,
                    fee_head_name, frequency, installment_label,
                    due_date, amount_due, status, academic_year
                ) VALUES (
                    p_tenant_id, p_school_id, v_student_id,
                    core.fn_registration_fee_head_name(p_tenant_id, p_school_id),
                    'One Time', 'Registration',
                    v_adm_date, ROUND(v_reg_balance, 2), 'Pending', v_year
                );

                INSERT INTO core.admission_audit (tenant_id, school_id, student_id, action, detail, action_by)
                VALUES (p_tenant_id, p_school_id, v_student_id, 'RegistrationBalanceCarried',
                        'Unpaid registration balance ' || ROUND(v_reg_balance, 2)::TEXT ||
                        ' carried from enquiry ' || p_enquiry_id::TEXT, p_action_user_id);
            END IF;
        END IF;

        -- Audit
        INSERT INTO core.admission_audit (tenant_id, school_id, student_id, action, detail, action_by)
        VALUES (p_tenant_id, p_school_id, v_student_id, 'AdmissionCreated',
                'Admission ' || v_admission_no || ' created for ' || COALESCE(p_student_name,''),
                p_action_user_id);

        IF COALESCE(p_concession_amount, 0) > 0 THEN
            INSERT INTO core.admission_audit (tenant_id, school_id, student_id, action, detail, action_by)
            VALUES (p_tenant_id, p_school_id, v_student_id, 'ConcessionApplied',
                    'Concession ' || p_concession_amount::TEXT || ' (' ||
                    COALESCE(p_concession_reason, 'no reason') || ') status=' || v_approval,
                    p_action_user_id);
        END IF;

        -- Close the loop: link + confirm enquiry
        IF p_enquiry_id IS NOT NULL AND p_enquiry_id > 0 THEN
            UPDATE core.enquiries
            SET admission_id = v_student_id,
                status       = 'Admission Confirmed',
                updated_by   = p_action_user_id,
                updated_at   = NOW()
            WHERE enquiry_id = p_enquiry_id
              AND tenant_id  = p_tenant_id
              AND school_id  = p_school_id
              AND is_active  = TRUE;

            INSERT INTO core.enquiry_status_history (
                enquiry_id, tenant_id, school_id,
                status_from, status_to, change_note, changed_by
            )
            SELECT p_enquiry_id, p_tenant_id, p_school_id,
                   NULL, 'Admission Confirmed',
                   'Converted to admission ' || v_admission_no, p_action_user_id
            WHERE EXISTS (SELECT 1 FROM core.enquiries
                          WHERE enquiry_id = p_enquiry_id
                            AND tenant_id = p_tenant_id AND school_id = p_school_id);

            INSERT INTO core.admission_audit (tenant_id, school_id, student_id, action, detail, action_by)
            VALUES (p_tenant_id, p_school_id, v_student_id, 'ConvertedFromEnquiry',
                    'Linked from enquiry #' || p_enquiry_id::TEXT, p_action_user_id);

            -- Money the family already paid follows them onto the student record.
            -- A registration fee is taken before any student exists, so its
            -- receipt is booked against the enquiry with student_id NULL. Nothing
            -- pointed it at the student afterwards, and the fee history reads
            -- student_id only — so the amount they had paid was invisible on the
            -- child's record and could only be found by going back to the enquiry.
            --
            -- enquiry_id is deliberately left in place: the receipt really was
            -- taken against the enquiry, and that is where it came from. This adds
            -- the second half of a link that only ever existed one way, since the
            -- student row already carries the enquiry it came from.
            UPDATE core.fee_payments
               SET student_id = v_student_id
             WHERE tenant_id  = p_tenant_id
               AND school_id  = p_school_id
               AND enquiry_id = p_enquiry_id
               AND student_id IS NULL;
        END IF;

        OPEN p_result FOR
            SELECT v_student_id AS student_id, 1 AS success,
                   'Admission saved.' AS message, v_admission_no AS admission_no;
        RETURN;

    -- ── GetStudents (filtered + paginated) ───────────────────
    ELSIF p_operation = 'GetStudents' THEN
        OPEN p_result FOR
            WITH filtered AS (
                SELECT
                    s.student_id, s.admission_no, s.roll_no, s.student_name,
                    s.gender, s.dob,
                    -- When a session is asked for, report the class/section the
                    -- student held IN THAT SESSION, not their present one.
                    COALESCE(e.class_name,    s.class_name)    AS class_name,
                    COALESCE(e.section,       s.section)       AS section,
                    COALESCE(e.academic_year, s.academic_year) AS academic_year,
                    s.admission_date, s.guardian_name, s.mobile,
                    s.annual_total, s.status, s.approval_status, s.enquiry_id,
                    -- Concession settles a due as surely as cash does. Leaving
                    -- it out showed a fully settled student as owing / Partial.
                    COALESCE((
                        SELECT CASE
                            WHEN SUM(l.amount_due - l.amount_paid - l.concession) <= 0 THEN 'Paid'
                            WHEN SUM(l.amount_paid + l.concession) = 0 THEN 'Pending'
                            ELSE 'Partial' END
                        FROM core.student_ledger l
                        WHERE l.student_id = s.student_id
                    ), 'Pending') AS fee_status,
                    COALESCE((
                        SELECT SUM(l.amount_due - l.amount_paid - l.concession)
                        FROM core.student_ledger l
                        WHERE l.student_id = s.student_id
                    ), 0) AS fee_due
                FROM core.students s
                -- Per-session position (core.student_enrolment). students.academic_year
                -- only holds where a student is NOW, so filtering on it loses everyone
                -- who has since been promoted. Matches only when a session is asked
                -- for; otherwise e.* is NULL and the COALESCEs fall back to students.
                LEFT JOIN core.student_enrolment e
                       ON e.student_id    = s.student_id
                      AND e.academic_year = NULLIF(TRIM(COALESCE(p_filter_year, '')), '')
                WHERE s.tenant_id = p_tenant_id
                  AND s.school_id = p_school_id
                  AND s.is_active = TRUE
                  -- strpos, not LIKE: a typed % or _ is a character, not a
                  -- wildcard; inner runs of spaces are collapsed on both sides.
                  AND (
                      p_search IS NULL OR TRIM(p_search) = ''
                      OR strpos(regexp_replace(LOWER(s.student_name), '\s+', ' ', 'g'),
                                regexp_replace(LOWER(TRIM(p_search)), '\s+', ' ', 'g')) > 0
                      OR strpos(LOWER(s.admission_no), LOWER(TRIM(p_search))) > 0
                      OR strpos(regexp_replace(LOWER(COALESCE(s.guardian_name,'')), '\s+', ' ', 'g'),
                                regexp_replace(LOWER(TRIM(p_search)), '\s+', ' ', 'g')) > 0
                      OR strpos(COALESCE(s.mobile,''), TRIM(p_search)) > 0
                  )
                  -- Enrolled in the requested session at all.
                  AND (NULLIF(TRIM(COALESCE(p_filter_year, '')), '') IS NULL
                       OR e.enrolment_id IS NOT NULL)
                  -- "Active" in a given session means the session's own
                  -- enrolment is still open: a child already promoted, retained
                  -- into the next session or passed out has left that roster
                  -- (the Promotion page reloaded the moved children otherwise).
                  AND (NULLIF(TRIM(COALESCE(p_filter_year, '')), '') IS NULL
                       OR LOWER(COALESCE(TRIM(p_filter_status), '')) <> 'active'
                       OR e.status = 'Active')
                  -- Class/section are matched against that session's position.
                  AND (p_filter_class   IS NULL OR TRIM(p_filter_class)   = '' OR LOWER(COALESCE(e.class_name, s.class_name)) = LOWER(TRIM(p_filter_class)))
                  AND (p_filter_section IS NULL OR TRIM(p_filter_section) = '' OR LOWER(COALESCE(e.section, s.section, '')) = LOWER(TRIM(p_filter_section)))
                  AND (p_filter_gender  IS NULL OR TRIM(p_filter_gender)  = '' OR LOWER(COALESCE(s.gender,''))  = LOWER(TRIM(p_filter_gender)))
                  AND (p_filter_status  IS NULL OR TRIM(p_filter_status)  = '' OR LOWER(s.status) = LOWER(TRIM(p_filter_status)))
            )
            SELECT *, COUNT(*) OVER() AS total_count
            FROM filtered
            ORDER BY admission_date DESC, student_id DESC
            LIMIT  COALESCE(p_page_size,   10)
            OFFSET (COALESCE(p_page_number, 1) - 1) * COALESCE(p_page_size, 10);
        RETURN;

    -- ── GetStudentById ───────────────────────────────────────
    ELSIF p_operation = 'GetStudentById' THEN
        OPEN p_result FOR
            -- Leavers included: the Student Dashboard shows a left student
            -- read-only (fees, receipts, history). Edit Student refuses them
            -- in the controller by reading is_active.
            SELECT s.*
            FROM core.students s
            WHERE s.student_id = p_student_id
              AND s.tenant_id  = p_tenant_id
              AND s.school_id  = p_school_id;
        RETURN;

    -- ── DeleteStudent (soft) ─────────────────────────────────
    ELSIF p_operation = 'DeleteStudent' THEN
        UPDATE core.students
        SET is_active = FALSE, updated_by = p_action_user_id, updated_at = NOW()
        WHERE student_id = p_student_id
          AND tenant_id  = p_tenant_id
          AND school_id  = p_school_id;
        OPEN p_result FOR SELECT 1 AS success;
        RETURN;

    END IF;

    -- Fallback
    OPEN p_result FOR SELECT 0 AS student_id WHERE FALSE;

END;
$procedure$;

-- ============================================================================
-- The admission number the next save WOULD generate.
--
-- Read-only: it does not touch core.admission_counters. The admission form shows
-- it as a placeholder so the office knows what is coming, but it is a preview
-- and not a reservation — two clerks with the form open see the same number and
-- whoever saves first takes it. The number is only allocated inside
-- sp_admission_manage, under the counter's own ON CONFLICT.
--
-- Kept beside that generator deliberately: the two must agree on the format, and
-- they will not if they live apart. Both use core.fn_receipt_year, which reads
-- the session's real start year rather than the first four characters of its
-- name (that produced ADM-FY 2-0001).
-- ============================================================================
CREATE OR REPLACE PROCEDURE core.sp_next_admission_no(
    IN  p_tenant_id      integer,
    IN  p_school_id      integer,
    IN  p_action_user_id integer,
    IN  p_academic_year  varchar,
    INOUT p_result       refcursor DEFAULT 'next_adm_cursor'
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    OPEN p_result FOR
    SELECT 'ADM-'
        || core.fn_receipt_year(p_tenant_id, p_school_id, p_academic_year, CURRENT_DATE)
        || '-'
        || LPAD((COALESCE(c.last_seq, 0) + 1)::text, 4, '0') AS admission_no
    FROM (SELECT 1) x
    LEFT JOIN core.admission_counters c
           ON c.tenant_id     = p_tenant_id
          AND c.school_id     = p_school_id
          AND c.academic_year = COALESCE(TRIM(p_academic_year), '');
END;
$$;

-- ============================================================================
-- Edit an existing student.
--
-- WHY THIS EXISTS. core.sp_admission_manage's 'SaveAdmission' is INSERT-only —
-- it always creates a new student — so the Edit Student page had no way to save
-- and was left as a stub. This adds the missing update path.
--
-- WHAT IT DELIBERATELY DOES NOT TOUCH:
--
--   * paid or past instalments. A CLASS change is a money event, though: the
--     new class may cost more or less. When the new class has a fee structure
--     for the student's session, the old class's recurring instalments due
--     AFTER today are CLOSED (reason 'Moved from X to Y on <date>', never
--     deleted) and the new class's recurring heads are billed from next month
--     through core.fn_student_bill_plan -- the same billing admission uses.
--     When it has none, fees are left as they are and the message says so.
--     Every class / section change writes an admission_audit row.
--   * academic_year. The session only ever changes through promotion, and the
--     class must exist in the student's CURRENT session.
--
-- The student's enrolment row for the session follows a class/section change,
-- so lists filtered by session show the class the student is really in.
--
-- Depends on student_money_lifecycle.sql -- apply it first.
--   * admission_no. It is the school's permanent reference, printed on
--     receipts and the TC. Re-issuing one is not an edit.
--
-- Validation (2026-10-10): the edit path now refuses what admission refuses
-- -- a DOB in the future or after the admission date, a mobile that is not 10
-- digits, an Aadhaar that is not 12 digits, an unknown gender -- plus a second
-- active student with the same name + DOB + mobile and a roll number already
-- held in the same class + section + session. Each rule only fires when that
-- value is CHANGED, so an old row that predates a rule can still be edited.
-- Every changed field is written to admission_audit (old -> new, who, when).
--
-- Also here: core.sp_class_setup_sections, the sections a class HAS in a
-- session's setup (Edit Student and Promotion section dropdowns). The older
-- sp_class_active_sections lists only sections that already hold students, so
-- an empty section could never be picked; attendance still uses that one.
--
-- Target DB: PostgreSQL. Safe to re-run. Additive — a new operation on an
-- existing proc, so no signature change and nothing else is affected.
--
-- 2026-10-12: the rest of the admission form became editable (mother tongue,
-- APAAR / UDISE, previous board / class / TC, both parents' occupation /
-- qualification / email, annual income). Admission saved
-- them but nothing could change or even show them afterwards. They arrive
-- AFTER p_result and are written only when p_extended is TRUE: an app that does
-- not know them (the old build, during a deploy) passes nothing and the stored
-- values are kept, instead of every one of them being blanked. The old
-- signature is dropped first so exactly one overload exists.
-- ============================================================================

DROP PROCEDURE IF EXISTS core.sp_student_update(integer, integer, integer, integer,
    text, text, text, date, text, text, text, text, text, text, text, text, text, text, text, text, text, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_student_update(
    IN  p_tenant_id       integer,
    IN  p_school_id       integer,
    IN  p_action_user_id  integer,
    IN  p_student_id      integer,
    IN  p_student_name    text    DEFAULT NULL,
    IN  p_roll_no         text    DEFAULT NULL,
    IN  p_gender          text    DEFAULT NULL,
    IN  p_dob             date    DEFAULT NULL,
    IN  p_class_name      text    DEFAULT NULL,
    IN  p_section         text    DEFAULT NULL,
    IN  p_guardian_name   text    DEFAULT NULL,
    IN  p_mother_name     text    DEFAULT NULL,
    IN  p_mobile          text    DEFAULT NULL,
    IN  p_alt_mobile      text    DEFAULT NULL,
    IN  p_address         text    DEFAULT NULL,
    IN  p_blood_group     text    DEFAULT NULL,
    IN  p_religion        text    DEFAULT NULL,
    IN  p_category        text    DEFAULT NULL,
    IN  p_nationality     text    DEFAULT NULL,
    IN  p_id_proof_no     text    DEFAULT NULL,
    IN  p_prev_school     text    DEFAULT NULL,
    INOUT p_result        refcursor DEFAULT 'student_update_cursor'::refcursor,
    IN  p_extended        boolean DEFAULT FALSE,
    IN  p_mother_tongue   text    DEFAULT NULL,
    IN  p_apaar_id        text    DEFAULT NULL,
    IN  p_udise_student_id text   DEFAULT NULL,
    IN  p_prev_board      text    DEFAULT NULL,
    IN  p_prev_class      text    DEFAULT NULL,
    IN  p_prev_tc_no      text    DEFAULT NULL,
    IN  p_father_occupation    text DEFAULT NULL,
    IN  p_father_qualification text DEFAULT NULL,
    IN  p_father_email         text DEFAULT NULL,
    IN  p_mother_occupation    text DEFAULT NULL,
    IN  p_mother_qualification text DEFAULT NULL,
    IN  p_mother_email         text DEFAULT NULL,
    IN  p_annual_income   numeric DEFAULT NULL)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_name   text := NULLIF(TRIM(COALESCE(p_student_name, '')), '');
    v_cls    text := NULLIF(TRIM(COALESCE(p_class_name, '')), '');
    v_sec    text := NULLIF(TRIM(COALESCE(p_section, '')), '');
    s        core.students%ROWTYPE;
    v_class_id   integer;
    v_class_moved boolean;
    v_moved   boolean;
    v_plan    jsonb;
    v_from    date := (DATE_TRUNC('month', CURRENT_DATE) + INTERVAL '1 month')::date;
    v_reason  varchar(200);
    v_closed  numeric(12,2) := 0;
    v_billed  integer := 0;
    v_note    text := '';
    v_prepaid numeric(12,2);
    v_last_id integer;   -- highest ledger id before the new class is billed
    v_running integer;   -- new lines dropped for a cycle already running
    r         record;
    v_roll    text := NULLIF(TRIM(COALESCE(p_roll_no, '')), '');
    v_gender  text := NULLIF(TRIM(COALESCE(p_gender, '')), '');
    v_mobile  text := NULLIF(TRIM(COALESCE(p_mobile, '')), '');
    v_alt     text := NULLIF(TRIM(COALESCE(p_alt_mobile, '')), '');
    v_idp     text := NULLIF(TRIM(COALESCE(p_id_proof_no, '')), '');
    v_dob     text;
    v_changes text[] := '{}';
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR COALESCE(p_student_id, 0) <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    IF v_name IS NULL THEN
        RAISE EXCEPTION 'Student name is required.';
    END IF;

    -- The row must be this school's. Scoped here as well as in the UPDATE so the
    -- caller gets "not found" rather than a silent no-op.
    SELECT * INTO s
    FROM core.students
    WHERE student_id = p_student_id
      AND tenant_id  = p_tenant_id
      AND school_id  = p_school_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Student not found.';
    END IF;

    v_cls := COALESCE(v_cls, s.class_name);

    -- The class must exist in the student's OWN session. Checking "any class
    -- this school ever had" let a student sit in a class that only exists in
    -- another session, where no roster or fee structure for this one finds them.
    SELECT ac.academic_class_id INTO v_class_id
    FROM academic.academic_classes ac
    JOIN academic.academic_years ay ON ay.academic_year_id = ac.academic_year_id
    WHERE ac.tenant_id = p_tenant_id AND ac.school_id = p_school_id
      AND ac.class_name = v_cls
      AND ay.academic_year_name = s.academic_year
      AND COALESCE(ac.is_deleted, FALSE) = FALSE
    ORDER BY ac.display_order, ac.academic_class_id
    LIMIT 1;

    IF v_class_id IS NULL THEN
        RAISE EXCEPTION 'Class % is not set up for session %.', v_cls, s.academic_year;
    END IF;

    -- A section must be one that class has (when the class has sections at all).
    IF v_sec IS NOT NULL
       AND EXISTS (SELECT 1 FROM academic.academic_class_sections
                    WHERE academic_class_id = v_class_id AND COALESCE(is_deleted, FALSE) = FALSE)
       AND NOT EXISTS (SELECT 1 FROM academic.academic_class_sections
                        WHERE academic_class_id = v_class_id AND section_name = v_sec
                          AND COALESCE(is_deleted, FALSE) = FALSE) THEN
        RAISE EXCEPTION 'Section % does not exist in class %.', v_sec, v_cls;
    END IF;

    v_class_moved := v_cls <> COALESCE(s.class_name, '');
    v_moved       := v_class_moved OR COALESCE(v_sec, '') <> COALESCE(s.section, '');
    v_dob         := COALESCE(p_dob::text, s.dob);

    -- ── Same rules as admission (sp_admission_manage / AdmissionController) ──
    -- Each fires only when the value changes, so legacy rows stay editable.
    IF v_dob IS DISTINCT FROM s.dob THEN
        IF v_dob::date > CURRENT_DATE THEN
            RAISE EXCEPTION 'Date of birth cannot be in the future.';
        END IF;
        IF s.admission_date IS NOT NULL AND v_dob::date > s.admission_date::date THEN
            RAISE EXCEPTION 'Date of birth cannot be after the admission date (%).', s.admission_date;
        END IF;
    END IF;

    IF v_mobile IS DISTINCT FROM s.mobile AND v_mobile IS NOT NULL AND v_mobile !~ '^[0-9]{10}$' THEN
        RAISE EXCEPTION 'Mobile number must be 10 digits.';
    END IF;
    IF v_alt IS DISTINCT FROM s.alt_mobile AND v_alt IS NOT NULL AND v_alt !~ '^[0-9]{10}$' THEN
        RAISE EXCEPTION 'Alternate mobile must be 10 digits.';
    END IF;
    IF v_idp IS DISTINCT FROM s.id_proof_no AND v_idp IS NOT NULL AND v_idp !~ '^[0-9]{12}$' THEN
        RAISE EXCEPTION 'Aadhaar number must be 12 digits.';
    END IF;

    -- The extended fields (see header). Same "only when changed" rule.
    IF p_extended THEN
        IF NULLIF(TRIM(COALESCE(p_apaar_id, '')), '') IS DISTINCT FROM s.apaar_id
           AND NULLIF(TRIM(COALESCE(p_apaar_id, '')), '') !~ '^[0-9]{12}$' THEN
            RAISE EXCEPTION 'APAAR ID must be 12 digits.';
        END IF;
        IF NULLIF(TRIM(COALESCE(p_father_email, '')), '') IS DISTINCT FROM s.father_email
           AND NULLIF(TRIM(COALESCE(p_father_email, '')), '') !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' THEN
            RAISE EXCEPTION 'Father email is not a valid email address.';
        END IF;
        IF NULLIF(TRIM(COALESCE(p_mother_email, '')), '') IS DISTINCT FROM s.mother_email
           AND NULLIF(TRIM(COALESCE(p_mother_email, '')), '') !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' THEN
            RAISE EXCEPTION 'Mother email is not a valid email address.';
        END IF;
        IF p_annual_income IS NOT NULL AND p_annual_income < 0 THEN
            RAISE EXCEPTION 'Annual income cannot be negative.';
        END IF;
    END IF;

    -- Gender drives the Male / Female counts; store the canonical spelling.
    IF v_gender IS NOT NULL THEN
        v_gender := CASE lower(v_gender) WHEN 'male' THEN 'Male' WHEN 'female' THEN 'Female'
                                         WHEN 'other' THEN 'Other' ELSE v_gender END;
        IF v_gender IS DISTINCT FROM s.gender AND v_gender NOT IN ('Male', 'Female', 'Other') THEN
            RAISE EXCEPTION 'Gender must be Male, Female or Other.';
        END IF;
    END IF;

    -- Editing one child into another's identity: same rule as admission's
    -- duplicate guard (name whitespace/case-insensitive + DOB + mobile).
    IF (v_name IS DISTINCT FROM s.student_name OR v_dob IS DISTINCT FROM s.dob
        OR v_mobile IS DISTINCT FROM s.mobile)
       AND EXISTS (SELECT 1 FROM core.students o
                    WHERE o.tenant_id = p_tenant_id AND o.school_id = p_school_id
                      AND o.is_active AND o.student_id <> p_student_id
                      AND regexp_replace(LOWER(TRIM(o.student_name)), '\s+', ' ', 'g')
                          = regexp_replace(LOWER(v_name), '\s+', ' ', 'g')
                      AND COALESCE(o.dob, '') = COALESCE(v_dob, '')
                      AND COALESCE(o.mobile, '') = COALESCE(v_mobile, '')) THEN
        RAISE EXCEPTION 'Another student with the same name, date of birth and mobile already exists.';
    END IF;

    -- A roll number belongs to one child per class + section + session: the
    -- attendance register and the ID card sheet are keyed on it.
    IF v_roll IS NOT NULL
       AND (v_roll IS DISTINCT FROM s.roll_no OR v_moved)
       AND EXISTS (SELECT 1 FROM core.fn_session_rolls(p_tenant_id, p_school_id, s.academic_year, v_cls, v_sec) o
                    WHERE o.student_id <> p_student_id
                      AND LOWER(TRIM(o.roll_no)) = LOWER(v_roll)) THEN
        RAISE EXCEPTION 'Roll no % is already used in %.', v_roll, v_cls || COALESCE('-' || v_sec, '');
    END IF;

    -- What changed, for the audit row written below (old -> new).
    IF v_name   IS DISTINCT FROM s.student_name THEN v_changes := v_changes || ('Name: ' || COALESCE(s.student_name, '-') || ' -> ' || v_name); END IF;
    IF v_roll   IS DISTINCT FROM s.roll_no      THEN v_changes := v_changes || ('Roll: ' || COALESCE(s.roll_no, '-') || ' -> ' || COALESCE(v_roll, '-')); END IF;
    IF v_gender IS DISTINCT FROM s.gender       THEN v_changes := v_changes || ('Gender: ' || COALESCE(s.gender, '-') || ' -> ' || COALESCE(v_gender, '-')); END IF;
    IF v_dob    IS DISTINCT FROM s.dob          THEN v_changes := v_changes || ('DOB: ' || COALESCE(s.dob, '-') || ' -> ' || COALESCE(v_dob, '-')); END IF;
    IF NULLIF(TRIM(COALESCE(p_guardian_name, '')), '') IS DISTINCT FROM s.guardian_name THEN
        v_changes := v_changes || ('Guardian: ' || COALESCE(s.guardian_name, '-') || ' -> ' || COALESCE(NULLIF(TRIM(p_guardian_name), ''), '-')); END IF;
    IF NULLIF(TRIM(COALESCE(p_mother_name, '')), '') IS DISTINCT FROM s.mother_name THEN
        v_changes := v_changes || ('Mother: ' || COALESCE(s.mother_name, '-') || ' -> ' || COALESCE(NULLIF(TRIM(p_mother_name), ''), '-')); END IF;
    IF v_mobile IS DISTINCT FROM s.mobile       THEN v_changes := v_changes || ('Mobile: ' || COALESCE(s.mobile, '-') || ' -> ' || COALESCE(v_mobile, '-')); END IF;
    IF v_alt    IS DISTINCT FROM s.alt_mobile   THEN v_changes := v_changes || ('Alt mobile: ' || COALESCE(s.alt_mobile, '-') || ' -> ' || COALESCE(v_alt, '-')); END IF;
    IF NULLIF(TRIM(COALESCE(p_address, '')), '') IS DISTINCT FROM s.address THEN v_changes := v_changes || 'Address changed'::text; END IF;
    -- The Aadhaar number itself is not copied into the audit text.
    IF v_idp    IS DISTINCT FROM s.id_proof_no  THEN v_changes := v_changes || 'Aadhaar changed'::text; END IF;
    IF NULLIF(TRIM(COALESCE(p_blood_group, '')), '') IS DISTINCT FROM s.blood_group THEN
        v_changes := v_changes || ('Blood group: ' || COALESCE(s.blood_group, '-') || ' -> ' || COALESCE(NULLIF(TRIM(p_blood_group), ''), '-')); END IF;
    IF NULLIF(TRIM(COALESCE(p_religion, '')), '') IS DISTINCT FROM s.religion
       OR NULLIF(TRIM(COALESCE(p_category, '')), '') IS DISTINCT FROM s.category
       OR NULLIF(TRIM(COALESCE(p_nationality, '')), '') IS DISTINCT FROM s.nationality
       OR NULLIF(TRIM(COALESCE(p_prev_school, '')), '') IS DISTINCT FROM s.prev_school_name THEN
        v_changes := v_changes || 'Religion / category / nationality / previous school changed'::text; END IF;
    IF p_extended THEN
        IF NULLIF(TRIM(COALESCE(p_mother_tongue, '')), '') IS DISTINCT FROM s.mother_tongue
           OR NULLIF(TRIM(COALESCE(p_apaar_id, '')), '') IS DISTINCT FROM s.apaar_id
           OR NULLIF(TRIM(COALESCE(p_udise_student_id, '')), '') IS DISTINCT FROM s.udise_student_id THEN
            v_changes := v_changes || 'Mother tongue / APAAR / UDISE changed'::text; END IF;
        IF NULLIF(TRIM(COALESCE(p_prev_board, '')), '') IS DISTINCT FROM s.prev_board
           OR NULLIF(TRIM(COALESCE(p_prev_class, '')), '') IS DISTINCT FROM s.prev_class
           OR NULLIF(TRIM(COALESCE(p_prev_tc_no, '')), '') IS DISTINCT FROM s.prev_tc_no THEN
            v_changes := v_changes || 'Previous board / class / TC changed'::text; END IF;
        IF NULLIF(TRIM(COALESCE(p_father_occupation, '')), '') IS DISTINCT FROM s.father_occupation
           OR NULLIF(TRIM(COALESCE(p_father_qualification, '')), '') IS DISTINCT FROM s.father_qualification
           OR NULLIF(TRIM(COALESCE(p_father_email, '')), '') IS DISTINCT FROM s.father_email
           OR NULLIF(TRIM(COALESCE(p_mother_occupation, '')), '') IS DISTINCT FROM s.mother_occupation
           OR NULLIF(TRIM(COALESCE(p_mother_qualification, '')), '') IS DISTINCT FROM s.mother_qualification
           OR NULLIF(TRIM(COALESCE(p_mother_email, '')), '') IS DISTINCT FROM s.mother_email
           OR p_annual_income IS DISTINCT FROM s.annual_income THEN
            v_changes := v_changes || 'Parent occupation / qualification / email / income changed'::text; END IF;
    END IF;

    UPDATE core.students
    SET student_name   = v_name,
        roll_no        = v_roll,
        gender         = v_gender,
        dob            = v_dob,
        class_name     = v_cls,
        section        = v_sec,
        guardian_name  = NULLIF(TRIM(COALESCE(p_guardian_name, '')), ''),
        mother_name    = NULLIF(TRIM(COALESCE(p_mother_name, '')), ''),
        mobile         = v_mobile,
        alt_mobile     = v_alt,
        address        = NULLIF(TRIM(COALESCE(p_address, '')), ''),
        blood_group    = NULLIF(TRIM(COALESCE(p_blood_group, '')), ''),
        religion       = NULLIF(TRIM(COALESCE(p_religion, '')), ''),
        category       = NULLIF(TRIM(COALESCE(p_category, '')), ''),
        nationality    = NULLIF(TRIM(COALESCE(p_nationality, '')), ''),
        id_proof_no    = v_idp,
        prev_school_name = NULLIF(TRIM(COALESCE(p_prev_school, '')), ''),
        mother_tongue        = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_mother_tongue, '')), '') ELSE mother_tongue END,
        apaar_id             = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_apaar_id, '')), '') ELSE apaar_id END,
        udise_student_id     = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_udise_student_id, '')), '') ELSE udise_student_id END,
        prev_board           = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_prev_board, '')), '') ELSE prev_board END,
        prev_class           = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_prev_class, '')), '') ELSE prev_class END,
        prev_tc_no           = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_prev_tc_no, '')), '') ELSE prev_tc_no END,
        father_occupation    = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_father_occupation, '')), '') ELSE father_occupation END,
        father_qualification = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_father_qualification, '')), '') ELSE father_qualification END,
        father_email         = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_father_email, '')), '') ELSE father_email END,
        mother_occupation    = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_mother_occupation, '')), '') ELSE mother_occupation END,
        mother_qualification = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_mother_qualification, '')), '') ELSE mother_qualification END,
        mother_email         = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_mother_email, '')), '') ELSE mother_email END,
        annual_income        = CASE WHEN p_extended THEN p_annual_income ELSE annual_income END,
        updated_by     = p_action_user_id,
        updated_at     = NOW()
    WHERE student_id = p_student_id
      AND tenant_id  = p_tenant_id
      AND school_id  = p_school_id;

    IF v_moved OR v_roll IS DISTINCT FROM s.roll_no THEN
        -- The per-session record follows the move and the roll number (see
        -- student_enrolment.sql): Enrolment History and the next promotion read it.
        UPDATE core.student_enrolment
        SET class_name        = v_cls,
            academic_class_id = v_class_id,
            section           = v_sec,
            roll_no           = v_roll,
            updated_by        = p_action_user_id,
            updated_at        = now()
        WHERE student_id = p_student_id AND academic_year = s.academic_year;
    END IF;

    IF array_length(v_changes, 1) > 0 THEN
        INSERT INTO core.admission_audit (tenant_id, school_id, student_id, action, detail, action_by)
        VALUES (p_tenant_id, p_school_id, p_student_id, 'StudentEdited',
                array_to_string(v_changes, '; '), p_action_user_id);
    END IF;

    IF v_class_moved AND s.is_active THEN
        -- Only the cycle heads (monthly / quarterly / half-yearly) follow the
        -- class: one-time and yearly charges were already billed for the year.
        SELECT jsonb_agg(e) INTO v_plan
        FROM jsonb_array_elements(core.fn_class_fee_plan(p_tenant_id, p_school_id, v_cls, s.academic_year)) e
        WHERE lower(e->>'frequency') IN ('monthly', 'quarterly', 'half yearly');

        -- Fees already PAID for later months of the old class: closing nothing and
        -- billing the new class for the same months would charge the parent twice.
        SELECT COALESCE(SUM(amount_paid), 0) INTO v_prepaid
          FROM core.student_ledger
         WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
           AND fee_head_name <> 'Transport Fee'
           AND lower(frequency) IN ('monthly', 'quarterly', 'half yearly')
           AND (academic_year = s.academic_year OR academic_year IS NULL)
           AND due_date IS NOT NULL AND due_date::date >= v_from AND amount_paid > 0;
        IF v_plan IS NOT NULL AND v_prepaid > 0 THEN
            RAISE EXCEPTION 'Rs % is already paid for months after this one in %. Cancel those receipts (or refund) before moving the class, so the new class is not billed for paid months.',
                to_char(v_prepaid, 'FM99,99,99,990.00'), s.class_name;
        END IF;

        IF v_plan IS NULL THEN
            v_note := ' No fee structure for ' || v_cls || ' in ' || s.academic_year || ': fees were not changed.';
        ELSE
            v_reason := 'Moved from ' || COALESCE(s.class_name, '?') || ' to ' || v_cls ||
                        ' on ' || to_char(CURRENT_DATE, 'YYYY-MM-DD');
            FOR r IN
                SELECT ledger_id FROM core.student_ledger
                WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
                  AND fee_head_name <> 'Transport Fee'
                  AND lower(frequency) IN ('monthly', 'quarterly', 'half yearly')
                  AND (academic_year = s.academic_year OR academic_year IS NULL)
                  AND due_date IS NOT NULL AND due_date::date > CURRENT_DATE
                  AND amount_due - amount_paid - concession > 0
            LOOP
                v_closed := v_closed + core.fn_ledger_close(r.ledger_id, v_reason, 'ClassChange', p_action_user_id);
            END LOOP;

            -- The new class's plan is the one in force for the rest of the session.
            UPDATE core.student_fee_plan SET is_current = FALSE
            WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
              AND is_current AND (academic_year = s.academic_year OR academic_year IS NULL);

            SELECT COALESCE(MAX(ledger_id), 0) INTO v_last_id FROM core.student_ledger;

            v_billed := core.fn_student_bill_plan(p_tenant_id, p_school_id, p_action_user_id,
                            p_student_id, s.academic_year, v_from, v_plan, TRUE, v_from);

            -- A quarter or half-year that is already running stays with the old class
            -- (its line is still open), so the new class's line for that same cycle is
            -- taken off again -- it was just made here, nothing is paid on it. Without
            -- this the running quarter was charged twice.
            DELETE FROM core.student_ledger
             WHERE student_id = p_student_id AND ledger_id > v_last_id
               AND lower(frequency) IN ('quarterly', 'half yearly')
               AND installment_label ~ '^[A-Z][a-z]{2} [0-9]{4}'
               AND to_date(left(installment_label, 8), 'Mon YYYY') < v_from;
            GET DIAGNOSTICS v_running = ROW_COUNT;
            v_billed := v_billed - v_running;

            v_note := ' Fees: ' || to_char(v_closed, 'FM99999990.00') || ' of ' || s.class_name ||
                      ' instalments closed, ' || v_billed || ' ' || v_cls || ' instalment(s) billed from ' ||
                      to_char(v_from, 'Mon YYYY') || '.';
        END IF;

        INSERT INTO core.admission_audit (tenant_id, school_id, student_id, action, detail, action_by)
        VALUES (p_tenant_id, p_school_id, p_student_id, 'ClassChanged',
                COALESCE(s.class_name, '?') || COALESCE('-' || s.section, '') || ' -> ' ||
                v_cls || COALESCE('-' || v_sec, '') || '.' || v_note,
                p_action_user_id);
    ELSIF v_moved THEN
        INSERT INTO core.admission_audit (tenant_id, school_id, student_id, action, detail, action_by)
        VALUES (p_tenant_id, p_school_id, p_student_id, 'SectionChanged',
                v_cls || COALESCE('-' || s.section, '') || ' -> ' || v_cls || COALESCE('-' || v_sec, ''),
                p_action_user_id);
    END IF;

    OPEN p_result FOR
    SELECT TRUE AS success, 'Student updated successfully.' || v_note AS message, p_student_id AS student_id;
END;
$procedure$;


-- ── Sections a class HAS in a session's setup ───────────────────────────────
-- NULL session = the current one. Read from academic_class_sections, not from
-- students, so an empty section (a new 5-C) can be picked.
CREATE OR REPLACE PROCEDURE core.sp_class_setup_sections(
    IN    p_tenant_id     integer,
    IN    p_school_id     integer,
    IN    p_class         varchar,
    IN    p_academic_year varchar DEFAULT NULL,
    INOUT p_result        refcursor DEFAULT 'class_setup_sections_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        OPEN p_result FOR SELECT WHERE FALSE;
        RETURN;
    END IF;

    OPEN p_result FOR
    SELECT DISTINCT TRIM(cs.section_name) AS section, MIN(cs.display_order) AS display_order
    FROM academic.academic_class_sections cs
    JOIN academic.academic_classes ac ON ac.academic_class_id = cs.academic_class_id
    JOIN academic.academic_years   ay ON ay.academic_year_id  = ac.academic_year_id
    WHERE ac.tenant_id = p_tenant_id AND ac.school_id = p_school_id
      AND LOWER(ac.class_name) = LOWER(TRIM(COALESCE(p_class, '')))
      AND COALESCE(ac.is_deleted, FALSE) = FALSE
      AND COALESCE(cs.is_deleted, FALSE) = FALSE
      AND COALESCE(ay.is_deleted, FALSE) = FALSE
      AND (   (NULLIF(TRIM(COALESCE(p_academic_year, '')), '') IS NULL AND COALESCE(ay.is_current, FALSE))
           OR ay.academic_year_name = TRIM(p_academic_year))
    GROUP BY TRIM(cs.section_name)
    ORDER BY 2, 1;
END;
$procedure$;

-- ============================================================================
-- Student data checks (Students › Data Checks).
--
-- Dirty records spoil every list and report (ID cards, admit cards, report
-- cards, attendance registers), so this page counts the active students of the
-- current session that fail each check and lists them for fixing. Read-only,
-- except AssignRolls, which numbers a section's students:
--     p_mode 'missing'  give the next free numbers to students without one
--     p_mode 'all'      renumber the whole section 1..n in name order
-- Like Edit Student, a roll change is written to core.students AND to the
-- session's core.student_enrolment row, with an admission_audit entry.
--
--   checks (key -> what is wrong)
--     no_roll, dup_roll, no_adm, dup_adm, no_dob, no_gender, no_guardian,
--     bad_mobile, no_section, no_photo, no_apaar
-- Re-runnable.
-- ============================================================================

CREATE OR REPLACE PROCEDURE core.sp_student_data_checks(
    IN    p_operation      varchar,          -- Summary | List | AssignRolls
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_check          varchar DEFAULT NULL,   -- List
    IN    p_class          varchar DEFAULT NULL,   -- AssignRolls
    IN    p_section        varchar DEFAULT NULL,
    IN    p_mode           varchar DEFAULT 'missing',
    INOUT p_result         refcursor DEFAULT 'data_checks_cursor')
LANGUAGE plpgsql
AS $$
DECLARE
    v_year  varchar;
    v_next  integer;
    v_count integer := 0;
    r       record;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    SELECT y.academic_year_name INTO v_year
      FROM academic.academic_years y
     WHERE y.tenant_id = p_tenant_id AND y.school_id = p_school_id
       AND COALESCE(y.is_current, FALSE) AND NOT COALESCE(y.is_deleted, FALSE)
     LIMIT 1;

    -- the active students of the session, with every check worked out once
    CREATE TEMP TABLE IF NOT EXISTS tmp_dc (student_id int, public_id uuid, student_name varchar, admission_no varchar,
        class_name varchar, section varchar, roll_no varchar, issue varchar, detail varchar) ON COMMIT DROP;
    TRUNCATE tmp_dc;

    IF p_operation IN ('Summary', 'List') THEN
        INSERT INTO tmp_dc
        SELECT s.student_id, s.public_id, s.student_name, s.admission_no, s.class_name, s.section, s.roll_no, x.issue, x.detail
          FROM core.students s
          CROSS JOIN LATERAL (VALUES
            ('no_roll',     NULLIF(trim(COALESCE(s.roll_no, '')), '') IS NULL, NULL::varchar),
            ('dup_roll',    NULLIF(trim(COALESCE(s.roll_no, '')), '') IS NOT NULL AND EXISTS (
                               SELECT 1 FROM core.fn_session_rolls(s.tenant_id, s.school_id, s.academic_year, s.class_name, s.section) o
                                WHERE o.student_id <> s.student_id
                                  AND lower(trim(o.roll_no)) = lower(trim(s.roll_no))), 'Roll ' || s.roll_no),
            ('no_adm',      NULLIF(trim(COALESCE(s.admission_no, '')), '') IS NULL, NULL),
            ('dup_adm',     NULLIF(trim(COALESCE(s.admission_no, '')), '') IS NOT NULL AND EXISTS (
                               SELECT 1 FROM core.students o
                                WHERE o.tenant_id = s.tenant_id AND o.school_id = s.school_id AND o.student_id <> s.student_id
                                  AND lower(trim(o.admission_no)) = lower(trim(s.admission_no))), s.admission_no),
            ('no_dob',      NULLIF(trim(COALESCE(s.dob, '')), '') IS NULL, NULL),
            ('no_gender',   NULLIF(trim(COALESCE(s.gender, '')), '') IS NULL, NULL),
            ('no_guardian', NULLIF(trim(COALESCE(s.guardian_name, '')), '') IS NULL, NULL),
            ('bad_mobile',  length(regexp_replace(COALESCE(s.mobile, ''), '\D', '', 'g')) <> 10,
                            COALESCE(NULLIF(s.mobile, ''), 'none')),
            ('no_section',  NULLIF(trim(COALESCE(s.section, '')), '') IS NULL OR NOT EXISTS (
                               SELECT 1 FROM academic.academic_class_sections sec
                                 JOIN academic.academic_classes c ON c.academic_class_id = sec.academic_class_id
                                 JOIN academic.academic_years y ON y.academic_year_id = c.academic_year_id
                                WHERE sec.tenant_id = s.tenant_id AND sec.school_id = s.school_id
                                  AND c.class_name = s.class_name AND lower(sec.section_name) = lower(COALESCE(s.section, ''))
                                  AND y.academic_year_name = s.academic_year AND NOT COALESCE(sec.is_deleted, FALSE)),
                            COALESCE(s.class_name, '?') || ' – ' || COALESCE(NULLIF(s.section, ''), 'no section')),
            ('no_photo',    NULLIF(trim(COALESCE(s.photo_url, '')), '') IS NULL, NULL),
            ('no_apaar',    NULLIF(trim(COALESCE(s.apaar_id, '')), '') IS NULL, NULL)
          ) AS x(issue, failed, detail)
         WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id AND COALESCE(s.is_active, TRUE)
           AND s.academic_year = v_year AND x.failed;
    END IF;

    -- ── Summary: one row per check, in the order the page shows them
    IF p_operation = 'Summary' THEN
        OPEN p_result FOR
        SELECT k.issue, k.label, k.hint, k.severity, k.ord,
               (SELECT COUNT(*) FROM tmp_dc t WHERE t.issue = k.issue)::int AS students,
               (SELECT COUNT(*) FROM core.students s WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id
                   AND COALESCE(s.is_active, TRUE) AND s.academic_year = v_year)::int AS total
          FROM (VALUES
            ('no_roll',     'No roll number',          'Attendance registers, admit cards and report cards sort by roll number.', 'fix',  1),
            ('dup_roll',    'Duplicate roll number',   'Two students of the same section share a roll number.',                  'fix',  2),
            ('no_adm',      'No admission number',     'Receipts, TC and ID cards need it.',                                      'fix',  3),
            ('dup_adm',     'Duplicate admission number', 'An admission number must be unique in the school.',                    'fix',  4),
            ('no_section',  'No valid section',        'The class or section is not set up for this session.',                   'fix',  5),
            ('bad_mobile',  'Mobile missing or not 10 digits', 'Reminders and WhatsApp cannot reach the family.',                'fix',  6),
            ('no_guardian', 'No father / guardian name', 'Certificates and report cards print it.',                              'fix',  7),
            ('no_dob',      'No date of birth',        'Certificates, ID cards and the TC print it.',                            'fix',  8),
            ('no_gender',   'No gender',               'Certificates use it for "son / daughter".',                              'fix',  9),
            ('no_photo',    'No photo',                'ID cards, admit cards and report cards show a blank box.',               'info', 10),
            ('no_apaar',    'No APAAR ID',             'Needed for UDISE+ / board registrations.',                               'info', 11)
          ) AS k(issue, label, hint, severity, ord)
         ORDER BY k.ord;
        RETURN;
    END IF;

    -- ── List: the students failing one check
    IF p_operation = 'List' THEN
        OPEN p_result FOR
        SELECT t.student_id, t.public_id, t.student_name, t.admission_no, t.class_name, t.section, t.roll_no, t.detail
          FROM tmp_dc t
          LEFT JOIN academic.academic_classes c ON c.tenant_id = p_tenant_id AND c.school_id = p_school_id
                                               AND c.class_name = t.class_name AND NOT COALESCE(c.is_deleted, FALSE)
         WHERE t.issue = p_check
         GROUP BY t.student_id, t.public_id, t.student_name, t.admission_no, t.class_name, t.section, t.roll_no, t.detail
         ORDER BY MIN(c.display_order) NULLS LAST, t.class_name, t.section,
                  NULLIF(regexp_replace(COALESCE(t.roll_no, ''), '\D', '', 'g'), '')::int NULLS LAST, t.student_name;
        RETURN;
    END IF;

    -- ── AssignRolls: number one section
    IF p_operation = 'AssignRolls' THEN
        IF NULLIF(trim(p_class), '') IS NULL THEN RAISE EXCEPTION 'Choose a class.'; END IF;
        IF COALESCE(p_mode, '') NOT IN ('missing', 'all') THEN RAISE EXCEPTION 'Choose how to number.'; END IF;

        -- 'missing' continues after the highest number already used in the section
        SELECT COALESCE(MAX(NULLIF(regexp_replace(COALESCE(s.roll_no, ''), '\D', '', 'g'), '')::int), 0)
          INTO v_next
          FROM core.fn_session_rolls(p_tenant_id, p_school_id, v_year, p_class, p_section) s;
        -- 'all' renumbers from 1, after the rolls of children already promoted out
        -- of this class this session (they keep theirs on its sheets)
        IF p_mode = 'all' THEN
            SELECT COALESCE(MAX(NULLIF(regexp_replace(COALESCE(o.roll_no, ''), '\D', '', 'g'), '')::int), 0)
              INTO v_next
              FROM core.fn_session_rolls(p_tenant_id, p_school_id, v_year, p_class, p_section) o
             WHERE NOT EXISTS (SELECT 1 FROM core.students st
                                WHERE st.student_id = o.student_id AND st.academic_year = v_year
                                  AND st.class_name = trim(p_class)
                                  AND lower(COALESCE(st.section, '')) = lower(COALESCE(trim(p_section), '')));
        END IF;

        FOR r IN
            SELECT s.student_id, s.roll_no
              FROM core.students s
             WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id AND COALESCE(s.is_active, TRUE)
               AND s.academic_year = v_year AND s.class_name = trim(p_class)
               AND lower(COALESCE(s.section, '')) = lower(COALESCE(trim(p_section), ''))
               AND (p_mode = 'all' OR NULLIF(trim(COALESCE(s.roll_no, '')), '') IS NULL)
             ORDER BY lower(s.student_name), s.student_id
        LOOP
            v_next := v_next + 1;
            CONTINUE WHEN COALESCE(r.roll_no, '') = v_next::text;
            UPDATE core.students SET roll_no = v_next::text, updated_by = p_action_user_id, updated_at = now()
             WHERE student_id = r.student_id;
            UPDATE core.student_enrolment SET roll_no = v_next::text, updated_by = p_action_user_id, updated_at = now()
             WHERE student_id = r.student_id AND academic_year = v_year;
            INSERT INTO core.admission_audit (tenant_id, school_id, student_id, action, detail, action_by)
            VALUES (p_tenant_id, p_school_id, r.student_id, 'StudentEdited',
                    'Roll: ' || COALESCE(NULLIF(r.roll_no, ''), '-') || ' -> ' || v_next || ' (Data Checks: assign roll numbers)', p_action_user_id);
            v_count := v_count + 1;
        END LOOP;

        OPEN p_result FOR SELECT (CASE WHEN v_count = 0 THEN 'Nothing to change: every student already has that number.'
                                       ELSE 'Roll numbers set for ' || v_count || ' student(s).' END)::varchar AS message;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation.';
END;
$$;

-- ============================================================================
-- Fee Dashboard (Fee › Fee Dashboard). Read-only.
--
-- Money in uses core.fn_fee_money_lines (the Day Close / Collection Register
-- rule: a cancellation counts on the day it is made); "Advance" (paid from the
-- wallet) and "To wallet" lines are left out, so collected = money received.
-- Dues come from core.student_ledger:
--     billed      = amount_due - concession
--     outstanding = amount_due - amount_paid - concession   (closed rows read 0)
-- A row with no due date counts as due. "This session" = the current academic
-- year; dues of older sessions still owed are "Old dues".
--
-- Cursors:
--   summary   one row of headline figures
--   months    per due month of the session: billed, paid
--   daily     last 30 days of money in
--   modes     this month's money in by mode
--   staff     this month's money in by the staff member who took it, by mode
--   classes   per class / section (with class teacher): billed due, paid, overdue, students owing
--   matrix    class x fee head: billed due, paid
--   heads     per fee head: collected (session), overdue, not yet due
--   families  families (siblings share the guardian's mobile) owing the most, with their habit
--   given     money given away: concessions, written off, counter discount and voids, by staff
--   problems  billing checks (no price set, class without a fee structure, students never billed)
-- Re-runnable.
-- ============================================================================

CREATE OR REPLACE PROCEDURE core.sp_fee_dashboard(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    INOUT p_summary        refcursor DEFAULT 'fd_summary',
    INOUT p_months         refcursor DEFAULT 'fd_months',
    INOUT p_daily          refcursor DEFAULT 'fd_daily',
    INOUT p_modes          refcursor DEFAULT 'fd_modes',
    INOUT p_staff          refcursor DEFAULT 'fd_staff',
    INOUT p_classes        refcursor DEFAULT 'fd_classes',
    INOUT p_matrix         refcursor DEFAULT 'fd_matrix',
    INOUT p_heads          refcursor DEFAULT 'fd_heads',
    INOUT p_families       refcursor DEFAULT 'fd_families',
    INOUT p_given          refcursor DEFAULT 'fd_given',
    INOUT p_problems       refcursor DEFAULT 'fd_problems')
LANGUAGE plpgsql
AS $$
DECLARE
    v_year    varchar;
    v_today   date := CURRENT_DATE;
    v_month1  date := date_trunc('month', CURRENT_DATE)::date;
    v_prev1   date := (date_trunc('month', CURRENT_DATE) - interval '1 month')::date;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    SELECT y.academic_year_name INTO v_year
      FROM academic.academic_years y
     WHERE y.tenant_id = p_tenant_id AND y.school_id = p_school_id
       AND COALESCE(y.is_current, FALSE) AND NOT COALESCE(y.is_deleted, FALSE)
     LIMIT 1;

    -- every ledger line, with what is billed / paid / owed and who owes it
    CREATE TEMP TABLE IF NOT EXISTS tmp_fd (
        ledger_id int, student_id int, class_name varchar, section varchar, fee_head varchar,
        due_on date, billed numeric, paid numeric, owed numeric, in_session boolean, active boolean,
        family varchar, guardian varchar, student_name varchar) ON COMMIT DROP;
    TRUNCATE tmp_fd;
    INSERT INTO tmp_fd
    -- each line under the class the child had in THAT line's session
    -- (core.student_enrolment), not the present one after an early promotion
    SELECT l.ledger_id, l.student_id, COALESCE(e.class_name, s.class_name), COALESCE(e.section, s.section, ''), l.fee_head_name,
           NULLIF(l.due_date, '')::date,
           l.amount_due - l.concession, l.amount_paid,
           GREATEST(l.amount_due - l.amount_paid - l.concession, 0),
           lower(COALESCE(NULLIF(trim(l.academic_year), ''), s.academic_year)) = lower(COALESCE(v_year, '')),
           COALESCE(s.is_active, TRUE),
           COALESCE(NULLIF(regexp_replace(COALESCE(s.mobile, ''), '\D', '', 'g'), ''), 'S' || s.student_id),
           COALESCE(NULLIF(trim(s.guardian_name), ''), s.student_name), s.student_name
      FROM core.student_ledger l
      JOIN core.students s ON s.student_id = l.student_id AND s.tenant_id = p_tenant_id AND s.school_id = p_school_id
      LEFT JOIN core.student_enrolment e
             ON e.student_id = l.student_id
            AND e.academic_year = COALESCE(NULLIF(trim(l.academic_year), ''), s.academic_year)
     WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id;

    -- money in, last 90 days and this month (fn_fee_money_lines rule)
    CREATE TEMP TABLE IF NOT EXISTS tmp_fd_money (payment_id int, user_id int, line_date date, mode varchar, amount numeric) ON COMMIT DROP;
    TRUNCATE tmp_fd_money;
    INSERT INTO tmp_fd_money
    SELECT m.payment_id, m.user_id, m.line_date, m.mode, m.amount
      FROM core.fn_fee_money_lines(p_tenant_id, p_school_id, LEAST(v_prev1, v_today - 30), v_today) m
     WHERE m.mode NOT IN ('Advance', 'To wallet');

    -- family habit, from when each family paid its lines (fee_payment_details -> payment date)
    CREATE TEMP TABLE IF NOT EXISTS tmp_fd_habit (family varchar PRIMARY KEY, habit varchar) ON COMMIT DROP;
    TRUNCATE tmp_fd_habit;
    INSERT INTO tmp_fd_habit
    SELECT f.family,
           CASE WHEN f.oldest_overdue > 60 THEN 'Habitual defaulter'
                WHEN f.paid_lines >= 2 AND f.late_lines * 2 > f.paid_lines THEN 'Pays late'
                WHEN f.paid_lines >= 2 THEN 'Pays on time'
                ELSE 'Too new to tell' END
      FROM (
        SELECT t.family,
               MAX(CASE WHEN t.owed > 0 AND t.due_on IS NOT NULL AND t.due_on <= v_today THEN v_today - t.due_on ELSE 0 END) AS oldest_overdue,
               COUNT(DISTINCT d.detail_id) FILTER (WHERE d.detail_id IS NOT NULL)                                       AS paid_lines,
               COUNT(DISTINCT d.detail_id) FILTER (WHERE p.payment_date::date > t.due_on + 15)                           AS late_lines
          FROM tmp_fd t
          LEFT JOIN core.fee_payment_details d ON d.ledger_id = t.ledger_id
          LEFT JOIN core.fee_payments p ON p.payment_id = d.payment_id AND NOT COALESCE(p.is_cancelled, FALSE)
         GROUP BY t.family) f;

    -- ── summary
    OPEN p_summary FOR
    SELECT v_year AS session,
           (SELECT COALESCE(SUM(billed), 0) FROM tmp_fd WHERE in_session)                                               AS billed_session,
           (SELECT COALESCE(SUM(billed), 0) FROM tmp_fd WHERE in_session AND COALESCE(due_on, v_today) <= v_today)      AS billed_due,
           (SELECT COALESCE(SUM(paid), 0)   FROM tmp_fd WHERE in_session AND COALESCE(due_on, v_today) <= v_today)      AS paid_due,
           (SELECT COALESCE(SUM(paid), 0)   FROM tmp_fd WHERE in_session)                                               AS paid_session,
           (SELECT COALESCE(SUM(owed), 0)   FROM tmp_fd WHERE COALESCE(due_on, v_today) <= v_today)                     AS overdue,
           (SELECT COUNT(DISTINCT family)   FROM tmp_fd WHERE owed > 0 AND COALESCE(due_on, v_today) <= v_today)        AS overdue_families,
           (SELECT COALESCE(SUM(owed), 0)   FROM tmp_fd WHERE due_on > v_today)                                         AS not_yet_due,
           (SELECT COALESCE(SUM(owed), 0)   FROM tmp_fd WHERE due_on > v_today AND due_on <= v_today + 10)              AS due_next_10,
           (SELECT COUNT(DISTINCT family)   FROM tmp_fd WHERE owed > 0 AND due_on > v_today AND due_on <= v_today + 10) AS due_next_10_families,
           (SELECT COALESCE(SUM(owed), 0)   FROM tmp_fd WHERE owed > 0 AND (NOT active OR v_today - COALESCE(due_on, v_today) > 180)) AS likely_lost,
           (SELECT COALESCE(SUM(owed), 0)   FROM tmp_fd WHERE owed > 0 AND active AND v_today - COALESCE(due_on, v_today) BETWEEN 91 AND 180) AS doubtful,
           (SELECT COALESCE(SUM(owed), 0)   FROM tmp_fd WHERE owed > 0 AND active AND v_today - COALESCE(due_on, v_today) BETWEEN 31 AND 90)  AS at_risk,
           (SELECT COALESCE(SUM(owed), 0)   FROM tmp_fd WHERE owed > 0 AND active AND v_today - COALESCE(due_on, v_today) <= 30)              AS safe,
           (SELECT COALESCE(SUM(owed), 0)   FROM tmp_fd WHERE owed > 0 AND COALESCE(due_on, v_today) <= v_today AND v_today - COALESCE(due_on, v_today) <= 30) AS age_0_30,
           (SELECT COALESCE(SUM(owed), 0)   FROM tmp_fd WHERE owed > 0 AND v_today - due_on BETWEEN 31 AND 60)          AS age_31_60,
           (SELECT COALESCE(SUM(owed), 0)   FROM tmp_fd WHERE owed > 0 AND v_today - due_on BETWEEN 61 AND 90)          AS age_61_90,
           (SELECT COALESCE(SUM(owed), 0)   FROM tmp_fd WHERE owed > 0 AND v_today - due_on > 90)                        AS age_90_plus,
           (SELECT COALESCE(SUM(amount), 0) FROM tmp_fd_money WHERE line_date >= v_month1)                              AS collected_month,
           (SELECT COUNT(DISTINCT payment_id) FROM tmp_fd_money WHERE line_date >= v_month1 AND amount > 0)              AS receipts_month,
           (SELECT COALESCE(SUM(amount), 0) FROM tmp_fd_money WHERE line_date >= v_prev1 AND line_date < v_month1)       AS collected_prev_month,
           (SELECT COALESCE(SUM(amount), 0) FROM tmp_fd_money WHERE line_date = v_today)                                AS collected_today,
           (SELECT COUNT(*) FROM tmp_fd_habit WHERE habit = 'Pays on time')       AS fam_on_time,
           (SELECT COUNT(*) FROM tmp_fd_habit WHERE habit = 'Pays late')          AS fam_late,
           (SELECT COUNT(*) FROM tmp_fd_habit WHERE habit = 'Habitual defaulter') AS fam_defaulter,
           (SELECT COUNT(*) FROM tmp_fd_habit WHERE habit = 'Too new to tell')    AS fam_new;

    -- ── months of the session (by due month)
    OPEN p_months FOR
    SELECT to_char(date_trunc('month', COALESCE(due_on, v_today)), 'YYYY-MM') AS month,
           SUM(billed) AS billed, SUM(paid) AS paid, SUM(owed) AS owed
      FROM tmp_fd WHERE in_session
     GROUP BY 1 ORDER BY 1;

    -- ── last 30 days of money in
    OPEN p_daily FOR
    SELECT to_char(d, 'YYYY-MM-DD') AS day,
           COALESCE((SELECT SUM(m.amount) FROM tmp_fd_money m WHERE m.line_date = d::date), 0) AS amount
      FROM generate_series(v_today - 29, v_today, interval '1 day') d
     ORDER BY d;

    -- ── this month by mode
    OPEN p_modes FOR
    SELECT mode, SUM(amount) AS amount FROM tmp_fd_money WHERE line_date >= v_month1
     GROUP BY mode HAVING SUM(amount) <> 0 ORDER BY SUM(amount) DESC;

    -- ── this month by staff member and mode
    OPEN p_staff FOR
    SELECT core.fn_user_display_name(user_id) AS staff, mode, SUM(amount) AS amount
      FROM tmp_fd_money WHERE line_date >= v_month1
     GROUP BY user_id, mode HAVING SUM(amount) <> 0 ORDER BY 1, 2;

    -- ── classes / sections with the class teacher (session dues that are due)
    OPEN p_classes FOR
    SELECT t.class_name, t.section,
           (SELECT st.full_name FROM academic.academic_class_sections sec
              JOIN academic.academic_classes c ON c.academic_class_id = sec.academic_class_id
              JOIN academic.academic_years y ON y.academic_year_id = c.academic_year_id
              JOIN core.staff st ON st.staff_id = sec.class_teacher_staff_id
             WHERE sec.tenant_id = p_tenant_id AND sec.school_id = p_school_id
               AND c.class_name = t.class_name AND lower(sec.section_name) = lower(t.section)
               AND lower(y.academic_year_name) = lower(COALESCE(v_year, ''))
             LIMIT 1) AS class_teacher,
           SUM(t.billed) FILTER (WHERE t.in_session AND COALESCE(t.due_on, v_today) <= v_today) AS billed_due,
           SUM(t.paid)   FILTER (WHERE t.in_session AND COALESCE(t.due_on, v_today) <= v_today) AS paid_due,
           SUM(t.owed)   FILTER (WHERE COALESCE(t.due_on, v_today) <= v_today)                  AS overdue,
           COUNT(DISTINCT t.student_id) FILTER (WHERE t.owed > 0 AND COALESCE(t.due_on, v_today) <= v_today) AS students_owing,
           COUNT(DISTINCT t.student_id) FILTER (WHERE t.active) AS students
      FROM tmp_fd t
     -- students who have left stay in their class's money, so class totals add up to
     -- the school total (QA BUG-105); only the head count is of current students
     GROUP BY t.class_name, t.section
     -- the school's class order (Nursery, Class 1, Class 2 ...), not alphabetical
     ORDER BY (SELECT MIN(c.display_order) FROM academic.academic_classes c
                WHERE c.tenant_id = p_tenant_id AND c.school_id = p_school_id
                  AND c.class_name = t.class_name AND NOT COALESCE(c.is_deleted, FALSE)) NULLS LAST, t.class_name, t.section;

    -- ── class x fee head (session dues that are due)
    OPEN p_matrix FOR
    SELECT t.class_name, t.fee_head, SUM(t.billed) AS billed_due, SUM(t.paid) AS paid_due
      FROM tmp_fd t
     WHERE t.in_session AND COALESCE(t.due_on, v_today) <= v_today
     GROUP BY t.class_name, t.fee_head
    HAVING SUM(t.billed) > 0
     ORDER BY (SELECT MIN(c.display_order) FROM academic.academic_classes c
                WHERE c.tenant_id = p_tenant_id AND c.school_id = p_school_id
                  AND c.class_name = t.class_name AND NOT COALESCE(c.is_deleted, FALSE)) NULLS LAST, t.class_name, t.fee_head;

    -- ── fee heads (older sessions' unpaid lines are "Old dues")
    OPEN p_heads FOR
    SELECT CASE WHEN in_session THEN fee_head ELSE 'Old dues' END AS fee_head,
           SUM(paid) FILTER (WHERE in_session)                                AS collected,
           SUM(owed) FILTER (WHERE COALESCE(due_on, v_today) <= v_today)      AS overdue,
           SUM(owed) FILTER (WHERE due_on > v_today)                          AS not_yet_due
      FROM tmp_fd
     GROUP BY 1
     ORDER BY COALESCE(SUM(owed) FILTER (WHERE COALESCE(due_on, v_today) <= v_today), 0) DESC;

    -- ── families owing the most (overdue), with their habit
    OPEN p_families FOR
    SELECT t.family, MAX(t.guardian) AS guardian,
           string_agg(DISTINCT t.student_name || ' (' || t.class_name || COALESCE(NULLIF('-' || t.section, '-'), '') || ')', ', ') AS children,
           SUM(t.owed) FILTER (WHERE COALESCE(t.due_on, v_today) <= v_today) AS overdue,
           SUM(t.paid) AS paid,
           MAX(CASE WHEN t.owed > 0 AND COALESCE(t.due_on, v_today) <= v_today THEN v_today - COALESCE(t.due_on, v_today) END) AS oldest_days,
           h.habit
      FROM tmp_fd t
      LEFT JOIN tmp_fd_habit h ON h.family = t.family
     GROUP BY t.family, h.habit
    HAVING SUM(t.owed) FILTER (WHERE COALESCE(t.due_on, v_today) <= v_today) > 0
     ORDER BY 4 DESC
     LIMIT 25;

    -- ── money given away this session
    OPEN p_given FOR
    SELECT 'Concession'::varchar AS kind, NULL::varchar AS staff,
           COALESCE((SELECT SUM(l.concession) FROM core.student_ledger l JOIN tmp_fd t ON t.ledger_id = l.ledger_id WHERE t.in_session), 0) AS amount,
           NULL::int AS cnt
    UNION ALL
    SELECT 'Written off', NULL,
           COALESCE((SELECT SUM(l.closed_amount) FROM core.student_ledger l JOIN tmp_fd t ON t.ledger_id = l.ledger_id
                      WHERE t.in_session AND l.close_source = 'YearEnd'), 0), NULL
    UNION ALL
    SELECT 'Counter discount', core.fn_user_display_name(p.created_by), SUM(p.discount_amount), COUNT(*)::int
      FROM core.fee_payments p
     WHERE p.tenant_id = p_tenant_id AND p.school_id = p_school_id AND NOT COALESCE(p.is_cancelled, FALSE)
       AND COALESCE(p.discount_amount, 0) > 0 AND p.payment_date >= to_char(v_today - 365, 'YYYY-MM-DD')
     GROUP BY p.created_by
    UNION ALL
    SELECT 'Voided receipt', core.fn_user_display_name(COALESCE(p.cancelled_by, p.created_by)), SUM(p.amount), COUNT(*)::int
      FROM core.fee_payments p
     WHERE p.tenant_id = p_tenant_id AND p.school_id = p_school_id AND COALESCE(p.is_cancelled, FALSE)
       AND COALESCE(p.cancelled_at::date, p.payment_date::date) >= v_today - 365
     GROUP BY COALESCE(p.cancelled_by, p.created_by);

    -- ── billing checks
    OPEN p_problems FOR
    SELECT 'No price set'::varchar AS kind,
           fs.class_name || ': ' || string_agg(d.fee_head_name, ', ' ORDER BY d.fee_head_name) AS detail,
           COUNT(*)::int AS cnt
      FROM core.school_fee_structures fs
      JOIN core.school_fee_structure_details d ON d.fee_structure_id = fs.fee_structure_id
     WHERE fs.tenant_id = p_tenant_id AND fs.school_id = p_school_id
       AND NOT COALESCE(fs.is_deleted, FALSE) AND COALESCE(fs.is_active, TRUE)
       AND lower(fs.academic_year) = lower(COALESCE(v_year, ''))
       AND COALESCE(d.is_selected, TRUE) AND NOT COALESCE(d.is_deleted, FALSE) AND COALESCE(d.amount, 0) = 0
     GROUP BY fs.class_name
    UNION ALL
    SELECT 'No fee structure', c.class_name, (SELECT COUNT(*) FROM core.students s
                                              WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id AND COALESCE(s.is_active, TRUE)
                                                AND s.class_name = c.class_name AND lower(s.academic_year) = lower(COALESCE(v_year, '')))::int
      FROM academic.academic_classes c
      JOIN academic.academic_years y ON y.academic_year_id = c.academic_year_id
     WHERE c.tenant_id = p_tenant_id AND c.school_id = p_school_id AND NOT COALESCE(c.is_deleted, FALSE)
       AND lower(y.academic_year_name) = lower(COALESCE(v_year, ''))
       AND EXISTS (SELECT 1 FROM core.students s WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id
                     AND COALESCE(s.is_active, TRUE) AND s.class_name = c.class_name AND lower(s.academic_year) = lower(COALESCE(v_year, '')))
       AND NOT EXISTS (SELECT 1 FROM core.school_fee_structures fs
                        WHERE fs.tenant_id = p_tenant_id AND fs.school_id = p_school_id AND fs.class_name = c.class_name
                          AND lower(fs.academic_year) = lower(COALESCE(v_year, '')) AND NOT COALESCE(fs.is_deleted, FALSE))
    UNION ALL
    SELECT 'Never billed', string_agg(s.student_name || ' (' || s.class_name || ')', ', ' ORDER BY s.student_name), COUNT(*)::int
      FROM core.students s
     WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id AND COALESCE(s.is_active, TRUE)
       AND lower(s.academic_year) = lower(COALESCE(v_year, ''))
       AND NOT EXISTS (SELECT 1 FROM tmp_fd t WHERE t.student_id = s.student_id AND t.in_session)
    HAVING COUNT(*) > 0;
END;
$$;

-- ============================================================================
-- Fee REPORTS — ERP → Fee → Reports
--
--   1. Collection Register : receipts and cancellations in a date range, with
--      totals by TRUE payment mode and by fee head. School-wide (all cashiers),
--      optionally for one class / section.
--   2. Defaulters / Outstanding : who owes money that has FALLEN DUE, with
--      aging, plus registration fees part-paid before admission.
--
-- Rules shared with Day Close and the Dashboard (see fee_day_close.sql):
--   * money is read through core.fn_fee_money_lines (tenders, not the header);
--   * a receipt stays on the day it was issued, and a cancellation is a
--     negative line on the day it was cancelled -- so a past range never
--     changes when an old receipt is cancelled.
--
-- Apply AFTER fee_day_close.sql (it defines fn_fee_money_lines).
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── 1. Collection register (receipts + mode + head summaries) ───────────────
-- Grew p_class / p_section: drop the old signature so one overload exists.
DROP PROCEDURE IF EXISTS core.sp_fee_collection_register(integer, integer, integer, date, date, refcursor, refcursor, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_fee_collection_register(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_from           date,
    IN    p_to             date,
    IN    p_class          varchar DEFAULT NULL,
    IN    p_section        varchar DEFAULT NULL,
    INOUT p_receipts       refcursor DEFAULT 'receipts_cursor'::refcursor,
    INOUT p_modes          refcursor DEFAULT 'modes_cursor'::refcursor,
    INOUT p_heads          refcursor DEFAULT 'heads_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_from    date;
    v_to      date;
    v_class   varchar := NULLIF(trim(p_class), '');
    v_section varchar := NULLIF(trim(p_section), '');
    v_reghead varchar;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;
    -- A blank range is the month to date -- the same default as the refund
    -- register, because the page nets one against the other.
    v_from := COALESCE(p_from, date_trunc('month', CURRENT_DATE)::date);
    v_to   := COALESCE(p_to,   CURRENT_DATE);
    -- The school's own name for its registration head, not a hard-coded label.
    v_reghead := core.fn_registration_fee_head_name(p_tenant_id, p_school_id);

    -- The events in range: each receipt on its own day (+), each cancellation
    -- on the day it was cancelled (-). Filtered by the payer's class/section.
    CREATE TEMP TABLE IF NOT EXISTS tmp_reg_ev
        (payment_id integer, sgn integer, line_date date, entry varchar) ON COMMIT DROP;
    TRUNCATE tmp_reg_ev;
    INSERT INTO tmp_reg_ev
    SELECT x.payment_id, x.sgn, x.line_date, x.entry
    FROM (
        SELECT p.payment_id, 1 AS sgn, p.payment_date::date AS line_date, 'Receipt'::varchar AS entry
        FROM core.fee_payments p
        WHERE p.tenant_id = p_tenant_id AND p.school_id = p_school_id
          AND p.payment_date BETWEEN to_char(v_from, 'YYYY-MM-DD') AND to_char(v_to, 'YYYY-MM-DD')
        UNION ALL
        SELECT p.payment_id, -1, COALESCE(p.cancelled_at::date, p.payment_date::date), 'Cancellation'
        FROM core.fee_payments p
        WHERE p.tenant_id = p_tenant_id AND p.school_id = p_school_id
          AND COALESCE(p.is_cancelled, FALSE)
          AND COALESCE(p.cancelled_at::date, p.payment_date::date) BETWEEN v_from AND v_to
    ) x
    JOIN core.fee_payments p ON p.payment_id = x.payment_id
    LEFT JOIN core.students  s ON s.student_id = p.student_id
    LEFT JOIN core.enquiries e ON e.enquiry_id = p.enquiry_id
    WHERE (v_class   IS NULL OR COALESCE(s.class_name, e.class_name) = v_class)
      AND (v_section IS NULL OR lower(COALESCE(s.section, '')) = lower(v_section));

    OPEN p_receipts FOR
    -- A payment belongs to a STUDENT or an ENQUIRY (registration fee taken before
    -- the student exists); name and class come from whichever applies.
    SELECT ev.entry,
           p.receipt_no,
           p.payment_date,
           ev.line_date,
           ev.sgn * p.amount                                      AS amount,
           -- The real split, e.g. "Cash 1200.00 + UPI 800.00", never "Mixed".
           COALESCE((SELECT string_agg(t.mode || ' ' || to_char(t.amount, 'FM999999990.00'), ' + ' ORDER BY t.tender_id)
                       FROM core.fee_payment_tenders t WHERE t.payment_id = p.payment_id),
                    p.payment_mode)                               AS payment_mode,
           COALESCE(NULLIF(TRIM(p.payment_type), ''), 'Fee')      AS payment_type,
           COALESCE(s.student_name, e.student_name, '—')          AS student_name,
           COALESCE(s.admission_no,
                    CASE WHEN e.enquiry_id IS NOT NULL
                         THEN COALESCE(NULLIF(e.registration_number, ''), 'Registration')
                    END,
                    '—')                                          AS admission_no,
           COALESCE(s.class_name, e.class_name)                   AS class_name,
           s.section,
           p.reference_no,
           COALESCE(p.concession_total, 0) + COALESCE(p.discount_amount, 0) AS discount_total,
           COALESCE(
               (SELECT string_agg(DISTINCT d.fee_head_name, ', ' ORDER BY d.fee_head_name)
                FROM core.fee_payment_details d
                WHERE d.payment_id = p.payment_id),
               CASE WHEN p.payment_type = 'Registration' THEN v_reghead END,
               '—')                                               AS fee_heads,
           COALESCE(p.is_cancelled, FALSE)                        AS is_cancelled,
           p.cancelled_at,
           p.cancel_reason,
           core.fn_user_display_name(CASE WHEN ev.sgn = 1 THEN p.created_by
                                          ELSE COALESCE(p.cancelled_by, p.created_by) END) AS cashier_name
    FROM tmp_reg_ev ev
    JOIN core.fee_payments p   ON p.payment_id  = ev.payment_id
    LEFT JOIN core.students  s ON s.student_id  = p.student_id
    LEFT JOIN core.enquiries e ON e.enquiry_id  = p.enquiry_id
    ORDER BY ev.line_date, p.payment_id, ev.sgn DESC;

    -- By TRUE mode (tender lines). 'To wallet' takes an overpaid surplus back
    -- out so the panel sums to the receipts total.
    OPEN p_modes FOR
    SELECT ml.mode AS payment_mode, COUNT(DISTINCT ml.payment_id) AS cnt, SUM(ml.amount) AS amount
    FROM core.fn_fee_money_lines(p_tenant_id, p_school_id, v_from, v_to) ml
    WHERE EXISTS (SELECT 1 FROM tmp_reg_ev ev
                  WHERE ev.payment_id = ml.payment_id AND ev.entry = ml.entry)
    GROUP BY ml.mode
    HAVING SUM(ml.amount) <> 0
    ORDER BY ml.mode;

    -- Head-wise split. Receipt lines (+) and cancelled lines (-). A registration
    -- fee has no detail lines, so the whole receipt is its registration head.
    OPEN p_heads FOR
    SELECT COALESCE(d.fee_head_name,
                    CASE WHEN p.payment_type = 'Registration' THEN v_reghead ELSE 'Other' END) AS fee_head_name,
           COUNT(DISTINCT ev.payment_id)::int                                                AS cnt,
           SUM(ev.sgn * COALESCE(d.amount, p.amount))                                        AS amount
    FROM tmp_reg_ev ev
    JOIN core.fee_payments p ON p.payment_id = ev.payment_id
    LEFT JOIN core.fee_payment_details d ON d.payment_id = ev.payment_id
    GROUP BY 1
    HAVING SUM(ev.sgn * COALESCE(d.amount, p.amount)) <> 0
    ORDER BY SUM(ev.sgn * COALESCE(d.amount, p.amount)) DESC;
END;
$procedure$;

-- ── 2. Defaulters / outstanding with aging ──────────────────────────────────
-- What is OWED is what has fallen due (due_date on or before today; a charge
-- with no date counts as due). Instalments not yet due are shown in their own
-- "Not due" column for planning, but they are not a debt: a family that has
-- paid everything due so far is not a defaulter.
--
-- One rule for students who have left: if they still owe money that fell due,
-- they are listed (status says so), here and on the Fee Due list alike.
--
-- A registration fee part-paid before admission has no ledger yet; its balance
-- is listed as its own row (entry = 'Registration', student_id NULL).
--
-- Session filter (p_academic_year; NULL or blank = all sessions). The session
-- a ledger row belongs to is the first of:
--   1. student_ledger.academic_year (written by fn_student_bill_plan since
--      2026-10-10, see student_money_lifecycle.sql);
--   2. the school's session whose start..end dates contain the row's due date;
--   3. the student's own session (core.students.academic_year);
--   4. the current session.
-- Rows billed before the column existed are blank in (1), so (2)/(3) place
-- them; anything still unplaced counts in the current session, which is the
-- report's default, so an old due is never dropped from the report.
-- A registration row belongs to its enquiry's session (core.enquiries.session),
-- else the current session.
-- Grew p_academic_year: drop the old signature so one overload exists.
DROP PROCEDURE IF EXISTS core.sp_fee_defaulters_get(integer, integer, integer, varchar, varchar, refcursor);
DROP PROCEDURE IF EXISTS core.sp_fee_defaulters_get(integer, integer, integer, varchar, varchar, varchar, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_fee_defaulters_get(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_class          varchar,
    IN    p_section        varchar,
    INOUT p_result         refcursor DEFAULT 'result_cursor'::refcursor,
    -- Last, so the older positional calls (..., p_section, cursor) still bind.
    IN    p_academic_year  varchar DEFAULT NULL
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_class   varchar := NULLIF(trim(p_class), '');
    v_section varchar := NULLIF(trim(p_section), '');
    v_year    varchar := lower(NULLIF(trim(p_academic_year), ''));
    v_current varchar;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;

    SELECT y.academic_year_name INTO v_current
    FROM academic.academic_years y
    WHERE y.tenant_id = p_tenant_id AND y.school_id = p_school_id
      AND y.is_current AND COALESCE(y.is_deleted, FALSE) = FALSE
    ORDER BY y.start_date DESC
    LIMIT 1;

    OPEN p_result FOR
    WITH dues AS (
        SELECT sl.student_id,
               (sl.amount_due - sl.amount_paid - COALESCE(sl.concession, 0)) AS outstanding,
               sl.due_date::date AS due_on,
               (sl.due_date IS NULL OR sl.due_date::date <= CURRENT_DATE)    AS is_due
        FROM core.student_ledger sl
        JOIN core.students s0 ON s0.student_id = sl.student_id
        LEFT JOIN LATERAL (
            SELECT y.academic_year_name
            FROM academic.academic_years y
            WHERE y.tenant_id = p_tenant_id AND y.school_id = p_school_id
              AND COALESCE(y.is_deleted, FALSE) = FALSE
              AND left(sl.due_date, 10) BETWEEN y.start_date AND y.end_date
            ORDER BY y.start_date
            LIMIT 1
        ) ys ON v_year IS NOT NULL
        WHERE sl.tenant_id = p_tenant_id AND sl.school_id = p_school_id
          AND sl.amount_due > sl.amount_paid + COALESCE(sl.concession, 0)
          AND (v_year IS NULL
               OR lower(COALESCE(NULLIF(trim(sl.academic_year), ''),
                                 ys.academic_year_name,
                                 NULLIF(trim(s0.academic_year), ''),
                                 v_current)) = v_year)
    ),
    students AS (
        SELECT 'Student'::varchar AS entry,
               s.student_id,
               s.student_name,
               s.admission_no,
               COALESCE(e.class_name, s.class_name) AS class_name,
               COALESCE(e.section, s.section)       AS section,
               COALESCE(NULLIF(trim(e.roll_no), ''), s.roll_no) AS roll_no,
               CASE WHEN COALESCE(s.is_active, TRUE) THEN 'Active'
                    ELSE COALESCE(NULLIF(trim(s.status), ''), 'Left') END                          AS student_status,
               COALESCE(SUM(d.outstanding) FILTER (WHERE d.is_due), 0)                             AS total_outstanding,
               COALESCE(SUM(d.outstanding) FILTER (WHERE NOT d.is_due), 0)                         AS not_due,
               COALESCE(SUM(d.outstanding) FILTER (WHERE d.is_due AND (d.due_on IS NULL OR CURRENT_DATE - d.due_on <= 30)), 0) AS d0_30,
               COALESCE(SUM(d.outstanding) FILTER (WHERE d.is_due AND CURRENT_DATE - d.due_on BETWEEN 31 AND 60), 0)          AS d31_60,
               COALESCE(SUM(d.outstanding) FILTER (WHERE d.is_due AND CURRENT_DATE - d.due_on > 60), 0)                      AS d60_plus
        FROM dues d
        JOIN core.students s ON s.student_id = d.student_id
                            AND s.tenant_id = p_tenant_id AND s.school_id = p_school_id
        -- with a session chosen, the class they had IN that session (a child
        -- promoted early still owes this year's fees as a member of the old class)
        LEFT JOIN core.student_enrolment e ON e.student_id = s.student_id AND v_year IS NOT NULL
                                          AND lower(e.academic_year) = v_year
        WHERE (v_class   IS NULL OR COALESCE(e.class_name, s.class_name) = v_class)
          AND (v_section IS NULL OR lower(COALESCE(e.section, s.section, '')) = lower(v_section))
        GROUP BY s.student_id, s.student_name, s.admission_no, e.class_name, e.section, e.roll_no,
                 s.class_name, s.section, s.roll_no, s.is_active, s.status
        HAVING COALESCE(SUM(d.outstanding) FILTER (WHERE d.is_due), 0) > 0
    ),
    registrations AS (
        -- Not admitted yet, fee agreed, not fully settled.
        SELECT 'Registration'::varchar AS entry,
               NULL::integer AS student_id,
               e.student_name,
               COALESCE(NULLIF(e.registration_number, ''), 'Registration') AS admission_no,
               e.class_name,
               NULL::varchar AS section,
               NULL::varchar AS roll_no,
               'Registered'::varchar AS student_status,
               b.balance AS total_outstanding,
               0::numeric AS not_due,
               CASE WHEN COALESCE(CURRENT_DATE - b.since, 0) <= 30 THEN b.balance ELSE 0 END AS d0_30,
               CASE WHEN CURRENT_DATE - b.since BETWEEN 31 AND 60 THEN b.balance ELSE 0 END  AS d31_60,
               CASE WHEN CURRENT_DATE - b.since > 60 THEN b.balance ELSE 0 END               AS d60_plus
        FROM core.enquiries e
        CROSS JOIN LATERAL (
            SELECT e.registration_fee_amount
                     - core.fn_registration_fee_settled(p_tenant_id, p_school_id, e.enquiry_id) AS balance,
                   CASE WHEN e.registration_date ~ '^\d{4}-\d{2}-\d{2}'
                        THEN left(e.registration_date, 10)::date
                        ELSE e.created_at::date END AS since
        ) b
        WHERE e.tenant_id = p_tenant_id AND e.school_id = p_school_id
          AND COALESCE(e.is_active, TRUE)
          AND e.admission_id IS NULL
          AND COALESCE(e.registration_fee_amount, 0) > 0
          AND b.balance > 0.005
          AND v_section IS NULL
          AND (v_class IS NULL OR e.class_name = v_class)
          AND (v_year IS NULL
               OR lower(COALESCE(NULLIF(trim(e.session), ''), v_current)) = v_year)
    )
    SELECT * FROM students
    UNION ALL
    SELECT * FROM registrations
    ORDER BY total_outstanding DESC, student_name;
END;
$procedure$;

-- ============================================================================
-- Homework.
--
-- A teacher gives homework to one class section for one subject, with a due
-- date. In class the teacher ticks who did it (Done / Not done / Late). Parents
-- have no login, so the day's homework of a section goes home as a WhatsApp
-- message or a printed homework diary (built in the app from 'List').
--
--   academic.homework         one row per piece of homework
--   academic.homework_status  one row per student once the teacher checks it
--
-- Students belong to a section by text (students.class_name / section /
-- academic_year), the same way attendance and fees match them.
--
-- Who may give homework: anyone the app says can manage academics
-- (p_can_manage), or a teacher for a class + subject they teach on the live
-- timetable, or any subject of the section they are class teacher of
-- (operation 'MyClasses' lists exactly those, QA BUG-098). A teacher edits /
-- deletes / checks only their own homework unless p_can_manage.
-- Re-runnable.
-- ============================================================================

CREATE TABLE IF NOT EXISTS academic.homework (
    homework_id               integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id                 integer      NOT NULL,
    school_id                 integer      NOT NULL,
    academic_class_section_id integer      NOT NULL,
    subject_id                integer      NOT NULL,
    staff_id                  integer,                  -- who gave it (NULL when an admin without a staff record did)
    title                     varchar(200) NOT NULL,
    details                   text,
    assigned_on               date         NOT NULL DEFAULT CURRENT_DATE,
    due_on                    date         NOT NULL,
    is_deleted                boolean      NOT NULL DEFAULT FALSE,
    created_by                integer      NOT NULL,
    created_at                timestamptz  NOT NULL DEFAULT now(),
    updated_by                integer,
    updated_at                timestamptz
);
CREATE INDEX IF NOT EXISTS ix_homework_section ON academic.homework (tenant_id, school_id, academic_class_section_id, assigned_on DESC);

CREATE TABLE IF NOT EXISTS academic.homework_status (
    homework_id  integer     NOT NULL REFERENCES academic.homework (homework_id),
    student_id   integer     NOT NULL,
    status       varchar(10) NOT NULL CHECK (status IN ('Done', 'NotDone', 'Late')),
    checked_by   integer     NOT NULL,
    checked_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (homework_id, student_id)
);


CREATE OR REPLACE PROCEDURE academic.sp_homework_manage(
    IN    p_operation      varchar,          -- List | Save | Delete | Students | Check | Student | MyClasses
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_can_manage     boolean   DEFAULT FALSE,
    IN    p_id             integer   DEFAULT NULL,   -- homework id
    IN    p_section_id     integer   DEFAULT NULL,   -- List filter / Save
    IN    p_subject_id     integer   DEFAULT NULL,
    IN    p_title          varchar   DEFAULT NULL,
    IN    p_details        text      DEFAULT NULL,
    IN    p_assigned_on    date      DEFAULT NULL,   -- Save; List: from
    IN    p_due_on         date      DEFAULT NULL,   -- Save; List: to
    IN    p_mine           boolean   DEFAULT FALSE,  -- List: only my homework
    IN    p_student_ids    integer[] DEFAULT NULL,   -- Check
    IN    p_statuses       varchar[] DEFAULT NULL,
    IN    p_student_id     integer   DEFAULT NULL,   -- Student
    INOUT p_result         refcursor DEFAULT 'homework_cursor')
LANGUAGE plpgsql
AS $$
DECLARE
    v_me     integer;       -- the caller's staff id
    v_type   varchar;
    v_owner  integer;
    v_id     integer;
    v_count  integer := 0;
    i        integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    SELECT s.staff_id, s.staff_type INTO v_me, v_type
      FROM core.staff s
     WHERE s.user_id = p_action_user_id AND s.tenant_id = p_tenant_id AND s.school_id = p_school_id
       AND NOT COALESCE(s.is_deleted, FALSE) AND COALESCE(s.is_active, TRUE)
     LIMIT 1;

    -- ── List: homework with section, subject, teacher and how many were checked
    IF p_operation = 'List' THEN
        OPEN p_result FOR
        SELECT h.homework_id, h.academic_class_section_id AS section_id,
               c.class_name || ' – ' || sec.section_name AS section_label,
               -- who gave it: the teacher, or the admin's name when no staff record (QA BUG-113)
               h.subject_id, sj.subject_name, h.staff_id, COALESCE(st.full_name, core.fn_user_display_name(h.created_by)) AS teacher_name,
               h.title, h.details, to_char(h.assigned_on, 'YYYY-MM-DD') AS assigned_on,
               to_char(h.due_on, 'YYYY-MM-DD') AS due_on,
               (h.staff_id IS NOT DISTINCT FROM v_me OR p_can_manage) AS can_edit,
               -- late work is still done work
               (SELECT COUNT(*) FROM academic.homework_status x WHERE x.homework_id = h.homework_id AND x.status IN ('Done', 'Late')) AS done_count,
               (SELECT COUNT(*) FROM academic.homework_status x WHERE x.homework_id = h.homework_id AND x.status = 'NotDone')          AS not_done_count,
               -- the section's roll for its session (core.student_enrolment): a child
               -- promoted early still belongs to it until the session ends
               (SELECT COUNT(*) FROM core.student_enrolment e
                 WHERE e.tenant_id = h.tenant_id AND e.school_id = h.school_id
                   AND e.academic_year = y.academic_year_name AND COALESCE(e.status, '') NOT IN ('Left', 'PassedOut')
                   AND e.class_name = c.class_name AND lower(COALESCE(e.section, '')) = lower(sec.section_name)) AS student_count
          FROM academic.homework h
          JOIN academic.academic_class_sections sec ON sec.academic_class_section_id = h.academic_class_section_id
          JOIN academic.academic_classes c ON c.academic_class_id = sec.academic_class_id
          JOIN academic.academic_years y ON y.academic_year_id = c.academic_year_id
          JOIN academic.school_subjects sj ON sj.subject_id = h.subject_id
          LEFT JOIN core.staff st ON st.staff_id = h.staff_id
         WHERE h.tenant_id = p_tenant_id AND h.school_id = p_school_id AND NOT h.is_deleted
           AND (p_section_id IS NULL OR h.academic_class_section_id = p_section_id)
           AND (p_assigned_on IS NULL OR h.assigned_on >= p_assigned_on)
           AND (p_due_on IS NULL OR h.assigned_on <= p_due_on)
           AND (NOT COALESCE(p_mine, FALSE) OR h.staff_id = v_me)
         ORDER BY h.assigned_on DESC, c.display_order, sec.section_name, sj.subject_name
         LIMIT 500;
        RETURN;
    END IF;

    -- ── MyClasses: what the caller may give homework for. subject_id NULL = any
    --    subject of that section (they are its class teacher).
    IF p_operation = 'MyClasses' THEN
        OPEN p_result FOR
        SELECT DISTINCT t.academic_class_section_id AS section_id, t.subject_id
          FROM academic.timetable t
          JOIN academic.academic_years y ON y.academic_year_id = t.academic_year_id AND COALESCE(y.is_current, FALSE)
         WHERE t.tenant_id = p_tenant_id AND t.school_id = p_school_id AND t.staff_id = v_me AND v_me IS NOT NULL
        UNION
        SELECT sec.academic_class_section_id, NULL::int
          FROM academic.academic_class_sections sec
          JOIN academic.academic_years y ON y.academic_year_id = sec.academic_year_id AND COALESCE(y.is_current, FALSE)
         WHERE sec.tenant_id = p_tenant_id AND sec.school_id = p_school_id
           AND sec.class_teacher_staff_id = v_me AND v_me IS NOT NULL AND NOT COALESCE(sec.is_deleted, FALSE);
        RETURN;
    END IF;

    -- ── Student: one student's homework of the last 30 days, with their status
    IF p_operation = 'Student' THEN
        OPEN p_result FOR
        SELECT h.homework_id, sj.subject_name, h.title, h.details,
               to_char(h.assigned_on, 'YYYY-MM-DD') AS assigned_on, to_char(h.due_on, 'YYYY-MM-DD') AS due_on,
               st.full_name AS teacher_name, x.status
          FROM core.students s
          -- the class they are in for the session in progress (a child promoted
          -- early still gets the old class's homework; one admitted for next
          -- session gets none yet)
          JOIN core.student_enrolment e ON e.student_id = s.student_id
                                       AND e.academic_year = core.fn_session_on(p_tenant_id, p_school_id, CURRENT_DATE)
          JOIN academic.academic_classes c ON c.tenant_id = s.tenant_id AND c.school_id = s.school_id AND c.class_name = e.class_name
          JOIN academic.academic_years y ON y.academic_year_id = c.academic_year_id AND y.academic_year_name = e.academic_year
          JOIN academic.academic_class_sections sec ON sec.academic_class_id = c.academic_class_id
                                                   AND lower(sec.section_name) = lower(COALESCE(e.section, ''))
          JOIN academic.homework h ON h.academic_class_section_id = sec.academic_class_section_id AND NOT h.is_deleted
          JOIN academic.school_subjects sj ON sj.subject_id = h.subject_id
          LEFT JOIN core.staff st ON st.staff_id = h.staff_id
          LEFT JOIN academic.homework_status x ON x.homework_id = h.homework_id AND x.student_id = s.student_id
         WHERE s.student_id = p_student_id AND s.tenant_id = p_tenant_id AND s.school_id = p_school_id
           AND h.assigned_on >= CURRENT_DATE - 30
         ORDER BY h.assigned_on DESC, sj.subject_name;
        RETURN;
    END IF;

    -- everything below changes or opens one piece of homework
    IF p_operation IN ('Delete', 'Students', 'Check') OR (p_operation = 'Save' AND p_id IS NOT NULL) THEN
        SELECT h.staff_id INTO v_owner FROM academic.homework h
         WHERE h.homework_id = p_id AND h.tenant_id = p_tenant_id AND h.school_id = p_school_id AND NOT h.is_deleted;
        IF NOT FOUND THEN RAISE EXCEPTION 'Homework not found.'; END IF;
        IF p_operation <> 'Students' AND NOT p_can_manage AND v_owner IS DISTINCT FROM v_me THEN
            RAISE EXCEPTION 'Only the teacher who gave this homework can change it.';
        END IF;
    END IF;

    -- ── Students: the section's students with their status for one piece of homework
    IF p_operation = 'Students' THEN
        OPEN p_result FOR
        SELECT s.student_id, s.student_name, COALESCE(NULLIF(TRIM(e.roll_no), ''), s.roll_no) AS roll_no, s.admission_no, x.status
          FROM academic.homework h
          JOIN academic.academic_class_sections sec ON sec.academic_class_section_id = h.academic_class_section_id
          JOIN academic.academic_classes c ON c.academic_class_id = sec.academic_class_id
          JOIN academic.academic_years y ON y.academic_year_id = c.academic_year_id
          -- the section's roll for its session (see List)
          JOIN core.student_enrolment e ON e.tenant_id = h.tenant_id AND e.school_id = h.school_id
                                       AND e.academic_year = y.academic_year_name
                                       AND COALESCE(e.status, '') NOT IN ('Left', 'PassedOut')
                                       AND e.class_name = c.class_name AND lower(COALESCE(e.section, '')) = lower(sec.section_name)
          JOIN core.students s ON s.student_id = e.student_id
          LEFT JOIN academic.homework_status x ON x.homework_id = h.homework_id AND x.student_id = s.student_id
         WHERE h.homework_id = p_id
         ORDER BY NULLIF(regexp_replace(COALESCE(NULLIF(TRIM(e.roll_no), ''), s.roll_no, ''), '\D', '', 'g'), '')::int NULLS LAST, s.student_name;
        RETURN;
    END IF;

    -- ── Save: new (p_id null) or edit
    IF p_operation = 'Save' THEN
        IF p_id IS NULL AND NOT p_can_manage AND COALESCE(v_type, '') <> 'Teaching' THEN
            RAISE EXCEPTION 'Only teachers can give homework.';
        END IF;
        -- a teacher: only a class + subject they teach, or their own class
        IF NOT p_can_manage AND NOT EXISTS (
                SELECT 1 FROM academic.timetable t
                  JOIN academic.academic_years y ON y.academic_year_id = t.academic_year_id AND COALESCE(y.is_current, FALSE)
                 WHERE t.tenant_id = p_tenant_id AND t.school_id = p_school_id AND t.staff_id = v_me
                   AND t.academic_class_section_id = p_section_id AND t.subject_id = p_subject_id)
           AND NOT EXISTS (
                SELECT 1 FROM academic.academic_class_sections sec
                 WHERE sec.academic_class_section_id = p_section_id AND sec.tenant_id = p_tenant_id
                   AND sec.school_id = p_school_id AND sec.class_teacher_staff_id = v_me) THEN
            RAISE EXCEPTION 'You can give homework only for the classes and subjects you teach (see My Timetable).';
        END IF;
        IF NULLIF(trim(p_title), '') IS NULL THEN RAISE EXCEPTION 'Write what the homework is.'; END IF;
        IF p_due_on IS NULL THEN RAISE EXCEPTION 'Choose the due date.'; END IF;
        IF p_due_on < COALESCE(p_assigned_on, CURRENT_DATE) THEN RAISE EXCEPTION 'The due date cannot be before the day it is given.'; END IF;
        IF NOT EXISTS (SELECT 1 FROM academic.academic_class_sections
                        WHERE academic_class_section_id = p_section_id AND tenant_id = p_tenant_id AND school_id = p_school_id) THEN
            RAISE EXCEPTION 'Choose a class.';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM academic.school_subjects
                        WHERE subject_id = p_subject_id AND tenant_id = p_tenant_id AND school_id = p_school_id) THEN
            RAISE EXCEPTION 'Choose a subject.';
        END IF;

        IF p_id IS NULL THEN
            INSERT INTO academic.homework (tenant_id, school_id, academic_class_section_id, subject_id, staff_id,
                                           title, details, assigned_on, due_on, created_by)
            VALUES (p_tenant_id, p_school_id, p_section_id, p_subject_id, v_me, trim(p_title), NULLIF(trim(p_details), ''),
                    COALESCE(p_assigned_on, CURRENT_DATE), p_due_on, p_action_user_id)
            RETURNING homework_id INTO v_id;
        ELSE
            UPDATE academic.homework
               SET academic_class_section_id = p_section_id, subject_id = p_subject_id,
                   title = trim(p_title), details = NULLIF(trim(p_details), ''),
                   assigned_on = COALESCE(p_assigned_on, assigned_on), due_on = p_due_on,
                   updated_by = p_action_user_id, updated_at = now()
             WHERE homework_id = p_id
            RETURNING homework_id INTO v_id;
        END IF;
        OPEN p_result FOR SELECT v_id AS homework_id,
               (CASE WHEN p_id IS NULL THEN 'Homework given.' ELSE 'Homework updated.' END)::varchar AS message;
        RETURN;
    END IF;

    -- ── Delete (soft)
    IF p_operation = 'Delete' THEN
        UPDATE academic.homework SET is_deleted = TRUE, updated_by = p_action_user_id, updated_at = now()
         WHERE homework_id = p_id;
        OPEN p_result FOR SELECT 'Homework deleted.'::varchar AS message;
        RETURN;
    END IF;

    -- ── Check: save who did it. A blank status clears that student's mark.
    IF p_operation = 'Check' THEN
        IF COALESCE(array_length(p_student_ids, 1), 0) = 0 THEN RAISE EXCEPTION 'Nothing to save.'; END IF;
        FOR i IN 1 .. array_length(p_student_ids, 1) LOOP
            IF NULLIF(trim(p_statuses[i]), '') IS NULL THEN
                DELETE FROM academic.homework_status WHERE homework_id = p_id AND student_id = p_student_ids[i];
                CONTINUE;
            END IF;
            IF p_statuses[i] NOT IN ('Done', 'NotDone', 'Late') THEN
                RAISE EXCEPTION 'Unknown status %.', p_statuses[i];
            END IF;
            -- only a child of that homework's section and session
            IF NOT EXISTS (SELECT 1 FROM academic.homework h
                             JOIN academic.academic_class_sections sec ON sec.academic_class_section_id = h.academic_class_section_id
                             JOIN academic.academic_classes c ON c.academic_class_id = sec.academic_class_id
                             JOIN academic.academic_years y ON y.academic_year_id = c.academic_year_id
                             JOIN core.student_enrolment e ON e.student_id = p_student_ids[i]
                                                          AND e.tenant_id = p_tenant_id AND e.school_id = p_school_id
                                                          AND e.academic_year = y.academic_year_name
                                                          AND e.class_name = c.class_name
                                                          AND lower(COALESCE(e.section, '')) = lower(sec.section_name)
                            WHERE h.homework_id = p_id) THEN
                RAISE EXCEPTION 'That student is not in this homework''s class.';
            END IF;
            INSERT INTO academic.homework_status (homework_id, student_id, status, checked_by)
            VALUES (p_id, p_student_ids[i], p_statuses[i], p_action_user_id)
            ON CONFLICT (homework_id, student_id)
            DO UPDATE SET status = EXCLUDED.status, checked_by = EXCLUDED.checked_by, checked_at = now();
            v_count := v_count + 1;
        END LOOP;
        OPEN p_result FOR SELECT ('Saved for ' || v_count || ' student(s).')::varchar AS message;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation.';
END;
$$;

