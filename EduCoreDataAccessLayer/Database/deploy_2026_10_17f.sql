-- Bundle 2026-10-17f: fn_session_on -- a past date in no session is no session (it fell back to the current one). Run with:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_17f.sql
-- Sources: student_attendance.sql

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
-- The session whose start..end contains the date. When none does:
--   * a date from the current session's start on (the school runs past 31 March
--     before the next session is set up), or a current session with no dates:
--     the current session;
--   * an earlier date (before the school's first session, or in a gap): NULL --
--     no session, so no register, no class list, nothing counted. It used to fall
--     back to the current session, so a 2024 register could list today's children.
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
            AND y.is_current
            AND (NULLIF(y.start_date, '') IS NULL OR p_date >= y.start_date::date)
          LIMIT 1));
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
