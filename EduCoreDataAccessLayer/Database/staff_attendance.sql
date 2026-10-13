-- ============================================================================
-- Staff attendance + substitute teachers.
--
-- 1. core.staff_attendance: one row per staff member per day
--    (Present | Absent | HalfDay | Late | Leave). Approved leave from
--    core.staff_leave shows as "Leave" on the register even when nobody marked
--    the day, and the marking page pre-selects it.
--
-- 2. academic.timetable_substitutions: when a teacher is absent or on leave,
--    each of their periods that day can be given to a free teacher. A
--    substitute must be present, not on leave and not already teaching (or
--    covering) that period. The live timetable is never changed; a
--    substitution belongs to one date only.
--
-- Weekday numbers follow academic.timetable: 1 = Monday ... 7 = Sunday (ISODOW).
-- Marking needs staff.manage, substitutions academics.manage (checked in the app).
-- Re-runnable.
-- ============================================================================

CREATE TABLE IF NOT EXISTS core.staff_attendance (
    attendance_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id      integer      NOT NULL,
    school_id      integer      NOT NULL,
    staff_id       integer      NOT NULL,
    att_date       date         NOT NULL,
    status         varchar(10)  NOT NULL,
    remark         varchar(200),
    marked_by      integer      NOT NULL,
    marked_at      timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT uq_staff_attendance UNIQUE (tenant_id, school_id, staff_id, att_date),
    CONSTRAINT ck_staff_attendance_status CHECK (status IN ('Present', 'Absent', 'HalfDay', 'Late', 'Leave'))
);

CREATE TABLE IF NOT EXISTS academic.timetable_substitutions (
    substitution_id           integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id                 integer      NOT NULL,
    school_id                 integer      NOT NULL,
    sub_date                  date         NOT NULL,
    academic_class_section_id integer      NOT NULL,
    period_seq                smallint     NOT NULL,
    original_staff_id         integer,
    substitute_staff_id       integer      NOT NULL,
    subject_id                integer,
    created_by                integer      NOT NULL,
    created_at                timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT uq_timetable_substitution UNIQUE (tenant_id, school_id, sub_date, academic_class_section_id, period_seq)
);


-- Why a staff member is away on a date: their attendance mark, else approved
-- leave. NULL when they are expected at work. Half a day counts as away only
-- when marked HalfDay (we do not know which half).
CREATE OR REPLACE FUNCTION core.fn_staff_away(p_tenant_id integer, p_school_id integer, p_staff_id integer, p_date date)
RETURNS varchar
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(
        (SELECT CASE a.status WHEN 'Absent' THEN 'Absent' WHEN 'Leave' THEN 'On leave' WHEN 'HalfDay' THEN 'Half day' END
           FROM core.staff_attendance a
          WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
            AND a.staff_id = p_staff_id AND a.att_date = p_date),
        (SELECT 'On leave (' || l.leave_type || ')'
           FROM core.staff_leave l
          WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id AND l.staff_id = p_staff_id
            AND l.status = 'Approved' AND p_date::text BETWEEN l.from_date AND l.to_date
            AND NOT EXISTS (SELECT 1 FROM core.staff_attendance a
                             WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
                               AND a.staff_id = p_staff_id AND a.att_date = p_date)
          LIMIT 1));
$$;


-- ── Staff attendance ────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE core.sp_staff_attendance_manage(
    IN    p_operation      varchar,          -- Day | Save | Month
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_date           date    DEFAULT NULL,   -- Day / Save
    IN    p_month          varchar DEFAULT NULL,   -- Month: 'YYYY-MM'
    IN    p_staff_ids      integer[] DEFAULT NULL, -- Save: parallel arrays
    IN    p_statuses       varchar[] DEFAULT NULL,
    IN    p_remarks        varchar[] DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'staff_att_cursor',
    INOUT p_result2        refcursor DEFAULT 'staff_att_cursor2')
LANGUAGE plpgsql
AS $$
DECLARE
    v_from  date;
    v_to    date;
    v_count integer := 0;
    i       integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    -- ── Day: every working staff member with the saved mark and any approved leave
    IF p_operation = 'Day' THEN
        IF p_date IS NULL THEN RAISE EXCEPTION 'Choose a date.'; END IF;
        OPEN p_result FOR
        SELECT s.staff_id, s.full_name, s.employee_code, s.designation, s.staff_type,
               a.status, a.remark, a.marked_at,
               (SELECT l.leave_type || CASE WHEN l.half_day THEN ' (half day)' ELSE '' END
                  FROM core.staff_leave l
                 WHERE l.tenant_id = s.tenant_id AND l.school_id = s.school_id AND l.staff_id = s.staff_id
                   AND l.status = 'Approved' AND p_date::text BETWEEN l.from_date AND l.to_date
                 LIMIT 1) AS leave_type
          FROM core.staff s
          LEFT JOIN core.staff_attendance a ON a.tenant_id = s.tenant_id AND a.school_id = s.school_id
                                           AND a.staff_id = s.staff_id AND a.att_date = p_date
         WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id
           AND NOT COALESCE(s.is_deleted, FALSE) AND COALESCE(s.is_active, TRUE)
           AND COALESCE(s.status, 'Active') = 'Active'
           AND (NULLIF(s.joining_date, '') IS NULL OR s.joining_date <= p_date::text)
         ORDER BY s.staff_type DESC NULLS LAST, s.full_name;

        -- holiday / Sunday note for the date
        OPEN p_result2 FOR
        SELECT (SELECT c.day_type || COALESCE(': ' || c.title, '') FROM academic.school_calendar c
                 WHERE c.tenant_id = p_tenant_id AND c.school_id = p_school_id AND c.calendar_date = p_date::text
                 LIMIT 1) AS calendar_note,
               EXTRACT(ISODOW FROM p_date)::int AS dow;
        RETURN;
    END IF;

    -- ── Save: upsert the marks of one day
    IF p_operation = 'Save' THEN
        IF p_date IS NULL THEN RAISE EXCEPTION 'Choose a date.'; END IF;
        IF p_date > CURRENT_DATE THEN RAISE EXCEPTION 'Attendance cannot be marked for a future date.'; END IF;
        IF COALESCE(array_length(p_staff_ids, 1), 0) = 0 THEN RAISE EXCEPTION 'Nothing to save.'; END IF;

        FOR i IN 1 .. array_length(p_staff_ids, 1) LOOP
            CONTINUE WHEN NULLIF(trim(p_statuses[i]), '') IS NULL;   -- left blank: not marked
            IF p_statuses[i] NOT IN ('Present', 'Absent', 'HalfDay', 'Late', 'Leave') THEN
                RAISE EXCEPTION 'Unknown status %.', p_statuses[i];
            END IF;
            IF NOT EXISTS (SELECT 1 FROM core.staff WHERE staff_id = p_staff_ids[i]
                            AND tenant_id = p_tenant_id AND school_id = p_school_id) THEN
                RAISE EXCEPTION 'Staff member not found.';
            END IF;
            INSERT INTO core.staff_attendance (tenant_id, school_id, staff_id, att_date, status, remark, marked_by)
            VALUES (p_tenant_id, p_school_id, p_staff_ids[i], p_date, p_statuses[i],
                    NULLIF(trim(p_remarks[i]), ''), p_action_user_id)
            ON CONFLICT (tenant_id, school_id, staff_id, att_date)
            DO UPDATE SET status = EXCLUDED.status, remark = EXCLUDED.remark,
                          marked_by = EXCLUDED.marked_by, marked_at = now();
            v_count := v_count + 1;
        END LOOP;

        IF v_count = 0 THEN RAISE EXCEPTION 'Mark at least one staff member.'; END IF;
        OPEN p_result FOR SELECT ('Saved attendance for ' || v_count || ' staff.')::varchar AS message;
        OPEN p_result2 FOR SELECT 1 AS done;
        RETURN;
    END IF;

    -- ── Month: register. Cursor 1 = staff, cursor 2 = one row per marked / leave day
    IF p_operation = 'Month' THEN
        BEGIN
            v_from := to_date(p_month || '-01', 'YYYY-MM-DD');
        EXCEPTION WHEN OTHERS THEN
            RAISE EXCEPTION 'Choose a month.';
        END;
        v_to := (v_from + interval '1 month - 1 day')::date;

        OPEN p_result FOR
        SELECT s.staff_id, s.full_name, s.designation, s.staff_type
          FROM core.staff s
         WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id
           AND NOT COALESCE(s.is_deleted, FALSE) AND COALESCE(s.is_active, TRUE)
           AND COALESCE(s.status, 'Active') = 'Active'
         ORDER BY s.staff_type DESC NULLS LAST, s.full_name;

        OPEN p_result2 FOR
        SELECT a.staff_id, EXTRACT(DAY FROM a.att_date)::int AS day, a.status
          FROM core.staff_attendance a
         WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id AND a.att_date BETWEEN v_from AND v_to
        UNION ALL
        -- approved leave on days nobody marked
        SELECT l.staff_id, EXTRACT(DAY FROM d)::int, 'Leave'
          FROM core.staff_leave l
          CROSS JOIN LATERAL generate_series(GREATEST(l.from_date::date, v_from), LEAST(l.to_date::date, v_to), interval '1 day') d
         WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id AND l.status = 'Approved'
           AND l.from_date <= v_to::text AND l.to_date >= v_from::text
           AND NOT EXISTS (SELECT 1 FROM core.staff_attendance a
                            WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
                              AND a.staff_id = l.staff_id AND a.att_date = d::date);
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation.';
END;
$$;


-- ── Substitutions ───────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE academic.sp_substitution_manage(
    IN    p_operation       varchar,          -- Day | Assign | Remove | Mine
    IN    p_tenant_id       integer,
    IN    p_school_id       integer,
    IN    p_action_user_id  integer,
    IN    p_date            date    DEFAULT NULL,
    IN    p_section_id      integer DEFAULT NULL,
    IN    p_period_seq      smallint DEFAULT NULL,
    IN    p_substitute_id   integer DEFAULT NULL,
    INOUT p_result          refcursor DEFAULT 'subst_cursor',
    INOUT p_result2         refcursor DEFAULT 'subst_cursor2')
LANGUAGE plpgsql
AS $$
DECLARE
    v_year  integer;
    v_dow   integer := EXTRACT(ISODOW FROM p_date)::int;
    v_orig  integer;
    v_subj  integer;
    v_away  varchar;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    SELECT ay.academic_year_id INTO v_year
      FROM academic.academic_years ay
     WHERE ay.tenant_id = p_tenant_id AND ay.school_id = p_school_id
       AND COALESCE(ay.is_current, FALSE) AND NOT COALESCE(ay.is_deleted, FALSE)
     LIMIT 1;

    -- ── Mine: a teacher's substitutions from today on
    IF p_operation = 'Mine' THEN
        OPEN p_result FOR
        SELECT to_char(x.sub_date, 'YYYY-MM-DD') AS sub_date, to_char(x.sub_date, 'Dy, DD Mon') AS day_label,
               x.period_seq,
               (SELECT ps.label FROM academic.period_structure ps
                 WHERE ps.tenant_id = x.tenant_id AND ps.school_id = x.school_id AND ps.seq = x.period_seq
                   AND (ps.day_of_week = EXTRACT(ISODOW FROM x.sub_date) OR ps.day_of_week IS NULL)
                 ORDER BY ps.day_of_week NULLS LAST LIMIT 1) AS period_label,
               c.class_name || ' – ' || sec.section_name AS section_label,
               sj.subject_name, os.full_name AS original_name
          FROM academic.timetable_substitutions x
          JOIN core.staff me ON me.staff_id = x.substitute_staff_id AND me.user_id = p_action_user_id
          JOIN academic.academic_class_sections sec ON sec.academic_class_section_id = x.academic_class_section_id
          JOIN academic.academic_classes c ON c.academic_class_id = sec.academic_class_id
          LEFT JOIN academic.school_subjects sj ON sj.subject_id = x.subject_id
          LEFT JOIN core.staff os ON os.staff_id = x.original_staff_id
         WHERE x.tenant_id = p_tenant_id AND x.school_id = p_school_id AND x.sub_date >= CURRENT_DATE
         ORDER BY x.sub_date, x.period_seq;
        OPEN p_result2 FOR SELECT 1 AS done;
        RETURN;
    END IF;

    IF p_date IS NULL THEN RAISE EXCEPTION 'Choose a date.'; END IF;

    -- ── Day: periods of away teachers (cursor 1) and every teacher's busy periods (cursor 2)
    IF p_operation = 'Day' THEN
        OPEN p_result FOR
        SELECT t.academic_class_section_id AS section_id, t.period_seq,
               (SELECT ps.label FROM academic.period_structure ps
                 WHERE ps.tenant_id = t.tenant_id AND ps.school_id = t.school_id AND ps.seq = t.period_seq
                   AND (ps.day_of_week = v_dow OR ps.day_of_week IS NULL)
                 ORDER BY ps.day_of_week NULLS LAST LIMIT 1) AS period_label,
               c.class_name || ' – ' || sec.section_name AS section_label,
               sj.subject_name, t.staff_id, st.full_name AS teacher_name,
               core.fn_staff_away(p_tenant_id, p_school_id, t.staff_id, p_date) AS away_reason,
               x.substitute_staff_id, sub.full_name AS substitute_name
          FROM academic.timetable t
          JOIN core.staff st ON st.staff_id = t.staff_id
          JOIN academic.academic_class_sections sec ON sec.academic_class_section_id = t.academic_class_section_id
          JOIN academic.academic_classes c ON c.academic_class_id = sec.academic_class_id
          JOIN academic.school_subjects sj ON sj.subject_id = t.subject_id
          LEFT JOIN academic.timetable_substitutions x
                 ON x.tenant_id = t.tenant_id AND x.school_id = t.school_id AND x.sub_date = p_date
                AND x.academic_class_section_id = t.academic_class_section_id AND x.period_seq = t.period_seq
          LEFT JOIN core.staff sub ON sub.staff_id = x.substitute_staff_id
         WHERE t.tenant_id = p_tenant_id AND t.school_id = p_school_id AND t.academic_year_id = v_year
           AND t.day_of_week = v_dow
           AND core.fn_staff_away(p_tenant_id, p_school_id, t.staff_id, p_date) IS NOT NULL
         ORDER BY t.period_seq, c.class_name, sec.section_name;

        OPEN p_result2 FOR
        SELECT s.staff_id, s.full_name,
               core.fn_staff_away(p_tenant_id, p_school_id, s.staff_id, p_date) AS away_reason,
               ARRAY(SELECT t.period_seq FROM academic.timetable t
                      WHERE t.tenant_id = p_tenant_id AND t.school_id = p_school_id AND t.academic_year_id = v_year
                        AND t.day_of_week = v_dow AND t.staff_id = s.staff_id
                     UNION
                     SELECT x.period_seq FROM academic.timetable_substitutions x
                      WHERE x.tenant_id = p_tenant_id AND x.school_id = p_school_id
                        AND x.sub_date = p_date AND x.substitute_staff_id = s.staff_id)::int[] AS busy
          FROM core.staff s
         WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id
           AND NOT COALESCE(s.is_deleted, FALSE) AND COALESCE(s.is_active, TRUE)
           AND COALESCE(s.status, 'Active') = 'Active' AND s.staff_type = 'Teaching'
         ORDER BY s.full_name;
        RETURN;
    END IF;

    -- ── Assign: give one period to a free teacher
    IF p_operation = 'Assign' THEN
        SELECT t.staff_id, t.subject_id INTO v_orig, v_subj
          FROM academic.timetable t
         WHERE t.tenant_id = p_tenant_id AND t.school_id = p_school_id AND t.academic_year_id = v_year
           AND t.academic_class_section_id = p_section_id AND t.day_of_week = v_dow AND t.period_seq = p_period_seq;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'There is no class in that period on this day.';
        END IF;
        IF p_substitute_id = v_orig THEN
            RAISE EXCEPTION 'Pick a different teacher.';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM core.staff WHERE staff_id = p_substitute_id
                        AND tenant_id = p_tenant_id AND school_id = p_school_id
                        AND COALESCE(is_active, TRUE) AND NOT COALESCE(is_deleted, FALSE)) THEN
            RAISE EXCEPTION 'Teacher not found.';
        END IF;
        v_away := core.fn_staff_away(p_tenant_id, p_school_id, p_substitute_id, p_date);
        IF v_away IS NOT NULL THEN
            RAISE EXCEPTION 'That teacher is away on this day (%).', v_away;
        END IF;
        IF EXISTS (SELECT 1 FROM academic.timetable t
                    WHERE t.tenant_id = p_tenant_id AND t.school_id = p_school_id AND t.academic_year_id = v_year
                      AND t.day_of_week = v_dow AND t.period_seq = p_period_seq AND t.staff_id = p_substitute_id)
           OR EXISTS (SELECT 1 FROM academic.timetable_substitutions x
                       WHERE x.tenant_id = p_tenant_id AND x.school_id = p_school_id AND x.sub_date = p_date
                         AND x.period_seq = p_period_seq AND x.substitute_staff_id = p_substitute_id
                         AND x.academic_class_section_id <> p_section_id) THEN
            RAISE EXCEPTION 'That teacher already has a class in this period.';
        END IF;

        INSERT INTO academic.timetable_substitutions (tenant_id, school_id, sub_date, academic_class_section_id,
                                                      period_seq, original_staff_id, substitute_staff_id, subject_id, created_by)
        VALUES (p_tenant_id, p_school_id, p_date, p_section_id, p_period_seq, v_orig, p_substitute_id, v_subj, p_action_user_id)
        ON CONFLICT (tenant_id, school_id, sub_date, academic_class_section_id, period_seq)
        DO UPDATE SET substitute_staff_id = EXCLUDED.substitute_staff_id, original_staff_id = EXCLUDED.original_staff_id,
                      subject_id = EXCLUDED.subject_id, created_by = EXCLUDED.created_by, created_at = now();

        OPEN p_result FOR SELECT 'Substitute assigned.'::varchar AS message;
        OPEN p_result2 FOR SELECT 1 AS done;
        RETURN;
    END IF;

    -- ── Remove
    IF p_operation = 'Remove' THEN
        DELETE FROM academic.timetable_substitutions
         WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND sub_date = p_date
           AND academic_class_section_id = p_section_id AND period_seq = p_period_seq;
        IF NOT FOUND THEN RAISE EXCEPTION 'No substitute was set for that period.'; END IF;
        OPEN p_result FOR SELECT 'Substitute removed.'::varchar AS message;
        OPEN p_result2 FOR SELECT 1 AS done;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation.';
END;
$$;
