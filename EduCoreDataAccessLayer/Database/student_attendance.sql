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

    OPEN p_result FOR
    SELECT DISTINCT TRIM(s.section) AS section
    FROM core.students s
    WHERE s.tenant_id = p_tenant_id
      AND s.school_id = p_school_id
      AND s.is_active = TRUE
      AND COALESCE(TRIM(s.section), '') <> ''
      AND (p_class IS NULL OR TRIM(p_class) = '' OR LOWER(s.class_name) = LOWER(TRIM(p_class)))
    ORDER BY 1;
END;
$procedure$;


-- ── the roster for a class/section on a date, with any marks already made ─────
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
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        OPEN p_result FOR SELECT WHERE FALSE;
        RETURN;
    END IF;

    OPEN p_result FOR
    SELECT
        s.student_id, s.roll_no, s.admission_no, s.student_name,
        s.guardian_name, s.mobile,     -- for the absentee WhatsApp notification
        a.status  AS status,           -- NULL when not yet marked
        a.remarks AS remarks,
        (a.attendance_id IS NOT NULL) AS is_marked
    FROM core.students s
    LEFT JOIN core.student_attendance a
           ON a.student_id      = s.student_id
          AND a.tenant_id       = s.tenant_id
          AND a.school_id       = s.school_id
          AND a.attendance_date = p_date
    WHERE s.tenant_id = p_tenant_id
      AND s.school_id = p_school_id
      AND s.is_active = TRUE
      -- A student can't be on a register before they were admitted.
      AND (s.admission_date IS NULL OR s.admission_date <= p_date)
      AND (p_class   IS NULL OR TRIM(p_class)   = '' OR LOWER(s.class_name)          = LOWER(TRIM(p_class)))
      AND (p_section IS NULL OR TRIM(p_section) = '' OR LOWER(COALESCE(s.section,'')) = LOWER(TRIM(p_section)))
    ORDER BY
        CASE WHEN s.roll_no ~ '^[0-9]+$' THEN lpad(s.roll_no, 6, '0') ELSE NULL END NULLS LAST,
        s.student_name;
END;
$procedure$;


-- ── save (upsert) the whole class's marks for a date ─────────────────────────
-- p_items is a JSON array: [{ "studentId": 1, "status": "Present", "remarks": "" }, ...]
-- The class/section/year snapshot is taken from each student's current row.
CREATE OR REPLACE PROCEDURE core.sp_attendance_save(
    IN    p_tenant_id integer,
    IN    p_school_id integer,
    IN    p_action_user_id integer,
    IN    p_date      date,
    IN    p_items     jsonb,
    INOUT p_result    refcursor DEFAULT 'attendance_save_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_saved         integer := 0;
    v_backdate_days integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Attendance date is required.';
    END IF;
    IF p_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'Attendance cannot be marked for a future date.';
    END IF;

    -- D: Sundays are non-working days — no register. (Saturdays are left open,
    -- since many schools work them.)
    IF EXTRACT(DOW FROM p_date) = 0 THEN
        RAISE EXCEPTION 'Attendance is not marked on Sundays.';
    END IF;

    -- B: older days are locked. The window is per-school (default 7 days).
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

    IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'No students to save.';
    END IF;

    INSERT INTO core.student_attendance AS a
        (tenant_id, school_id, student_id, attendance_date, status, remarks,
         academic_year, class_name, section, marked_by, marked_at)
    SELECT
        p_tenant_id, p_school_id, s.student_id, p_date,
        TRIM(i.status),
        NULLIF(TRIM(i.remarks), ''),
        s.academic_year, s.class_name, s.section,
        p_action_user_id, now()
    -- Column names are quoted so they match the camelCase JSON keys exactly —
    -- unquoted identifiers fold to lowercase and would never match "studentId".
    FROM jsonb_to_recordset(p_items) AS i("studentId" integer, status text, remarks text)
    JOIN core.students s
      ON s.student_id = i."studentId"
     AND s.tenant_id  = p_tenant_id
     AND s.school_id  = p_school_id
    WHERE TRIM(i.status) IN ('Present', 'Absent', 'Late', 'Leave')
      -- C: never record attendance before a student's admission date.
      AND (s.admission_date IS NULL OR s.admission_date <= p_date)
    ON CONFLICT (tenant_id, school_id, student_id, attendance_date) DO UPDATE
        SET status     = EXCLUDED.status,
            remarks    = EXCLUDED.remarks,
            updated_by = p_action_user_id,
            updated_at = now();

    GET DIAGNOSTICS v_saved = ROW_COUNT;

    OPEN p_result FOR
    SELECT TRUE AS success,
           'Attendance saved for ' || v_saved || ' student(s).' AS message,
           v_saved AS saved;
END;
$procedure$;
