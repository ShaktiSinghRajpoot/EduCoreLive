-- Bundle 2026-10-14l: QA round 3, batch 1 (year-end, homework, substitutes, notices, attendance overview, fee dashboard). Run with:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_14l.sql
-- Sources (all re-runnable): fee_year_end.sql, homework.sql, staff_attendance.sql, announcements.sql, attendance_overview.sql, fee_dashboard.sql

-- ============================================================================
-- Year-End Fee Closure (Fee › Year-End).
--
-- Before a session is closed, the school goes through every fee line still
-- unpaid in that session and decides, line by line or a whole student at once:
--   Carry     -> the due MOVES into the next session: its academic_year becomes
--                the next session and carried_from keeps where it came from.
--                So it leaves this session's defaulters and appears in the
--                next one's. The next session must exist (School Setup › Sessions).
--   Write off -> the unpaid part is CLOSED with core.fn_ledger_close (source
--                'YearEnd', reason required), exactly as Exit closes dues, so
--                every report that reads amount_due - amount_paid - concession
--                shows 0 for it without being changed. The app allows it only to
--                fees.writeoff (school admin / principal), not to a cashier.
--   Undo      -> a write-off is put back with core.fn_ledger_reopen; a carried
--                line goes back to the session it came from.
-- Only lines that are already DUE (due date today or earlier) can be carried or
-- written off: next month's fee is not a year-end matter (QA BUG-091).
--
-- Needs student_money_lifecycle.sql (fn_ledger_close / fn_ledger_reopen).
-- Re-runnable.
-- ============================================================================

ALTER TABLE core.student_ledger
    ADD COLUMN IF NOT EXISTS carried_by   integer,
    ADD COLUMN IF NOT EXISTS carried_at   timestamptz,
    ADD COLUMN IF NOT EXISTS carried_from varchar(20);

-- The first version only marked a line "carried" without moving it. Those marks
-- meant nothing to any report, so they are cleared: the lines are open again.
UPDATE core.student_ledger SET carried_at = NULL, carried_by = NULL
 WHERE carried_at IS NOT NULL AND carried_from IS NULL;

-- Writing dues off is a decision for the head of school, not the fee counter.
INSERT INTO config.permissions (permission_key, module_group, display_name, sort_order)
VALUES ('fees.writeoff', 'Finance', 'Fees & Collection — Write off dues (year-end)', 78)
ON CONFLICT (permission_key) DO NOTHING;


CREATE OR REPLACE PROCEDURE core.sp_fee_year_end_manage(
    IN    p_operation      varchar,    -- List | Carry | WriteOff | Undo | CarryAll
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_academic_year  varchar,
    IN    p_ledger_id      integer DEFAULT NULL,   -- one line ...
    IN    p_student_id     integer DEFAULT NULL,   -- ... or every open line of one student
    IN    p_reason         varchar DEFAULT NULL,   -- required for WriteOff
    INOUT p_result         refcursor DEFAULT 'year_end_cursor')
LANGUAGE plpgsql
AS $$
DECLARE
    v_year   varchar := lower(NULLIF(trim(p_academic_year), ''));
    v_reason varchar := NULLIF(trim(p_reason), '');
    v_next   varchar;            -- the session after v_year, where carried dues go
    v_count  integer := 0;
    v_amount numeric(12,2) := 0;
    r        record;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;
    IF v_year IS NULL THEN
        RAISE EXCEPTION 'Choose a session.';
    END IF;

    SELECT n.academic_year_name INTO v_next
      FROM academic.academic_years n
      JOIN academic.academic_years cur ON cur.tenant_id = n.tenant_id AND cur.school_id = n.school_id
                                      AND lower(cur.academic_year_name) = v_year AND NOT COALESCE(cur.is_deleted, FALSE)
     WHERE n.tenant_id = p_tenant_id AND n.school_id = p_school_id AND NOT COALESCE(n.is_deleted, FALSE)
       AND n.start_date > cur.start_date
     ORDER BY n.start_date
     LIMIT 1;

    -- ── List: the session's open lines, its write-offs, and what it carried forward
    IF p_operation = 'List' THEN
        OPEN p_result FOR
        SELECT l.ledger_id, l.student_id, s.student_name, s.admission_no, s.class_name, s.section,
               s.guardian_name, s.mobile,
               l.fee_head_name, l.installment_label, l.due_date,
               CASE WHEN l.close_source = 'YearEnd' THEN l.closed_amount
                    ELSE l.amount_due - l.amount_paid - l.concession END   AS amount,
               CASE WHEN l.close_source = 'YearEnd'          THEN 'WrittenOff'
                    WHEN lower(l.carried_from) = v_year      THEN 'Carried'
                    ELSE 'Open' END                                         AS state,
               (NULLIF(l.due_date, '')::date > CURRENT_DATE)               AS not_due,
               CASE WHEN l.close_source = 'YearEnd' THEN l.close_reason
                    WHEN lower(l.carried_from) = v_year THEN 'Moved to ' || l.academic_year END AS reason,
               COALESCE(CASE WHEN l.close_source = 'YearEnd' THEN l.closed_at END, l.carried_at) AS decided_at,
               v_next AS next_session
          FROM core.student_ledger l
          JOIN core.students s ON s.student_id = l.student_id
                              AND s.tenant_id = p_tenant_id AND s.school_id = p_school_id
         WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
           AND (   (lower(COALESCE(NULLIF(trim(l.academic_year), ''), s.academic_year)) = v_year
                    AND (l.amount_due > l.amount_paid + l.concession
                         OR (l.close_source = 'YearEnd' AND l.closed_amount > 0)))
                OR (lower(l.carried_from) = v_year AND l.amount_due > l.amount_paid + l.concession))
         ORDER BY s.class_name, s.section, s.student_name, l.student_id, l.due_date NULLS LAST, l.ledger_id;
        RETURN;
    END IF;

    IF p_operation NOT IN ('Carry', 'WriteOff', 'Undo', 'CarryAll') THEN
        RAISE EXCEPTION 'Unknown operation.';
    END IF;
    IF p_operation = 'WriteOff' AND v_reason IS NULL THEN
        RAISE EXCEPTION 'Give a reason for the write-off.';
    END IF;
    IF p_operation IN ('Carry', 'WriteOff') AND p_ledger_id IS NULL AND p_student_id IS NULL THEN
        RAISE EXCEPTION 'Choose a fee line or a student.';
    END IF;
    IF p_operation = 'Undo' AND p_ledger_id IS NULL THEN
        RAISE EXCEPTION 'Choose a fee line.';
    END IF;
    IF p_operation IN ('Carry', 'CarryAll') AND v_next IS NULL THEN
        RAISE EXCEPTION 'Create the next session first (School Setup › Sessions): carried dues move into it.';
    END IF;

    -- The lines this call acts on, always inside this school: the session's own
    -- lines, and for Undo also the lines it carried into the next session.
    FOR r IN
        SELECT l.ledger_id, l.carried_from, l.close_source, l.closed_amount,
               l.amount_due - l.amount_paid - l.concession AS open_amount,
               COALESCE(NULLIF(l.due_date, '')::date, CURRENT_DATE) <= CURRENT_DATE AS is_due,
               lower(COALESCE(NULLIF(trim(l.academic_year), ''), s.academic_year)) = v_year AS in_session
          FROM core.student_ledger l
          JOIN core.students s ON s.student_id = l.student_id
         WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
           AND (lower(COALESCE(NULLIF(trim(l.academic_year), ''), s.academic_year)) = v_year
                OR (p_operation = 'Undo' AND lower(l.carried_from) = v_year))
           AND (p_ledger_id  IS NULL OR l.ledger_id  = p_ledger_id)
           AND (p_student_id IS NULL OR l.student_id = p_student_id)
         ORDER BY l.ledger_id
           FOR UPDATE OF l
    LOOP
        IF p_operation = 'Undo' THEN
            IF r.close_source = 'YearEnd' AND r.closed_amount > 0 THEN
                v_amount := v_amount + core.fn_ledger_reopen(r.ledger_id);
                v_count  := v_count + 1;
            ELSIF lower(r.carried_from) = v_year THEN
                UPDATE core.student_ledger
                   SET academic_year = carried_from, carried_from = NULL, carried_at = NULL, carried_by = NULL, updated_at = now()
                 WHERE ledger_id = r.ledger_id;
                v_amount := v_amount + r.open_amount;
                v_count  := v_count + 1;
            END IF;

        ELSIF r.open_amount > 0 AND r.in_session THEN
            IF NOT r.is_due THEN
                -- one line asked for by name gets a reason; a student / CarryAll just skips it
                IF p_ledger_id IS NOT NULL THEN
                    RAISE EXCEPTION 'This fee is not due yet. Only dues of past and current months can be carried or written off.';
                END IF;
                CONTINUE;
            END IF;
            IF p_operation = 'WriteOff' THEN
                v_amount := v_amount + core.fn_ledger_close(r.ledger_id, v_reason, 'YearEnd', p_action_user_id);
                v_count  := v_count + 1;
            ELSE   -- Carry / CarryAll: move into the next session
                UPDATE core.student_ledger
                   SET carried_from = COALESCE(NULLIF(trim(academic_year), ''), (SELECT s2.academic_year FROM core.students s2 WHERE s2.student_id = student_ledger.student_id)),
                       academic_year = v_next, carried_at = now(), carried_by = p_action_user_id, updated_at = now()
                 WHERE ledger_id = r.ledger_id;
                v_amount := v_amount + r.open_amount;
                v_count  := v_count + 1;
            END IF;
        END IF;
    END LOOP;

    IF v_count = 0 THEN
        RAISE EXCEPTION 'Nothing to change: the line is already settled, decided or not due yet.';
    END IF;

    OPEN p_result FOR
    SELECT v_count AS lines, v_amount AS amount,
           CASE p_operation
                WHEN 'WriteOff' THEN 'Written off'
                WHEN 'Undo'     THEN 'Undone'
                ELSE 'Carried to ' || v_next END
           || ': ' || v_count || ' line(s), Rs ' || to_char(v_amount, 'FM99,99,99,990.00') AS message;
END;
$$;


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
               (SELECT COUNT(*) FROM core.students s
                 WHERE s.tenant_id = h.tenant_id AND s.school_id = h.school_id AND COALESCE(s.is_active, TRUE)
                   AND s.class_name = c.class_name AND lower(COALESCE(s.section, '')) = lower(sec.section_name)
                   AND s.academic_year = y.academic_year_name) AS student_count
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
          JOIN academic.academic_classes c ON c.tenant_id = s.tenant_id AND c.school_id = s.school_id AND c.class_name = s.class_name
          JOIN academic.academic_years y ON y.academic_year_id = c.academic_year_id AND y.academic_year_name = s.academic_year
          JOIN academic.academic_class_sections sec ON sec.academic_class_id = c.academic_class_id
                                                   AND lower(sec.section_name) = lower(COALESCE(s.section, ''))
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
        SELECT s.student_id, s.student_name, s.roll_no, s.admission_no, x.status
          FROM academic.homework h
          JOIN academic.academic_class_sections sec ON sec.academic_class_section_id = h.academic_class_section_id
          JOIN academic.academic_classes c ON c.academic_class_id = sec.academic_class_id
          JOIN academic.academic_years y ON y.academic_year_id = c.academic_year_id
          JOIN core.students s ON s.tenant_id = h.tenant_id AND s.school_id = h.school_id AND COALESCE(s.is_active, TRUE)
                              AND s.class_name = c.class_name AND lower(COALESCE(s.section, '')) = lower(sec.section_name)
                              AND s.academic_year = y.academic_year_name
          LEFT JOIN academic.homework_status x ON x.homework_id = h.homework_id AND x.student_id = s.student_id
         WHERE h.homework_id = p_id
         ORDER BY NULLIF(regexp_replace(COALESCE(s.roll_no, ''), '\D', '', 'g'), '')::int NULLS LAST, s.student_name;
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
            IF NOT EXISTS (SELECT 1 FROM core.students WHERE student_id = p_student_ids[i]
                            AND tenant_id = p_tenant_id AND school_id = p_school_id) THEN
                RAISE EXCEPTION 'Student not found.';
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
           -- only staff working here on that date (QA BUG-101: a joiner was offered before joining)
           AND (NULLIF(s.joining_date, '') IS NULL OR s.joining_date <= p_date::text)
           AND (NULLIF(s.last_working_date, '') IS NULL OR s.last_working_date >= p_date::text)
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
        IF EXISTS (SELECT 1 FROM core.staff WHERE staff_id = p_substitute_id
                    AND (NULLIF(joining_date, '') > p_date::text OR NULLIF(last_working_date, '') < p_date::text)) THEN
            RAISE EXCEPTION 'That teacher does not work here on this date.';
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


-- ============================================================================
-- Announcements / Notice Board.
--
-- A school posts a notice (title, message, category, who it is for). Every
-- school user sees the live notices on the Notice Board and in the navbar
-- bell; opening the board marks them read, so the poster sees "Seen by".
-- Parents have no login, so a notice reaches them as a printed circular or a
-- WhatsApp share from the page (the audience is printed on the circular).
--
--   audience: Everyone | Staff | Parents | Classes (then class_names lists them)
--   show_until: after this date the notice leaves the board (kept for the poster)
--
-- Posting needs the new permission notices.manage (School Admin bypasses).
-- Re-runnable.
-- ============================================================================

CREATE TABLE IF NOT EXISTS core.announcements (
    announcement_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id        integer      NOT NULL,
    school_id        integer      NOT NULL,
    title            varchar(200) NOT NULL,
    body             text         NOT NULL,
    category         varchar(20)  NOT NULL DEFAULT 'General',
    audience         varchar(20)  NOT NULL DEFAULT 'Everyone',
    class_names      varchar(500),
    is_pinned        boolean      NOT NULL DEFAULT FALSE,
    show_until       date,
    is_deleted       boolean      NOT NULL DEFAULT FALSE,
    created_by       integer      NOT NULL,
    created_at       timestamptz  NOT NULL DEFAULT now(),
    updated_by       integer,
    updated_at       timestamptz
);
CREATE INDEX IF NOT EXISTS ix_announcements_school ON core.announcements (tenant_id, school_id, created_at DESC);

CREATE TABLE IF NOT EXISTS core.announcement_reads (
    announcement_id  integer     NOT NULL REFERENCES core.announcements (announcement_id),
    user_id          integer     NOT NULL,
    read_at          timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (announcement_id, user_id)
);

INSERT INTO config.permissions (permission_key, module_group, display_name, sort_order)
VALUES ('notices.manage', 'Administration', 'Announcements — Post and manage notices', 143)
ON CONFLICT (permission_key) DO NOTHING;


CREATE OR REPLACE PROCEDURE core.sp_announcement_manage(
    IN    p_operation      varchar,    -- Board | List | Save | Delete | Read | SeenBy
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_id             integer DEFAULT NULL,
    IN    p_title          varchar DEFAULT NULL,
    IN    p_body           text    DEFAULT NULL,
    IN    p_category       varchar DEFAULT NULL,
    IN    p_audience       varchar DEFAULT NULL,
    IN    p_class_names    varchar DEFAULT NULL,
    IN    p_is_pinned      boolean DEFAULT FALSE,
    IN    p_show_until     date    DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'announcement_cursor')
LANGUAGE plpgsql
AS $$
DECLARE
    v_id       integer;
    v_audience varchar := COALESCE(NULLIF(trim(p_audience), ''), 'Everyone');
    v_classes  varchar := NULLIF(trim(p_class_names), '');
    v_staff    integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    -- How many people can read a notice: the school's active logins.
    SELECT COUNT(*) INTO v_staff FROM core.users
     WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND is_active AND NOT is_deleted;

    -- ── Board: live notices for the signed-in user, pinned first
    IF p_operation = 'Board' THEN
        OPEN p_result FOR
        SELECT a.announcement_id, a.title, a.body, a.category, a.audience, a.class_names,
               a.is_pinned, to_char(a.show_until, 'YYYY-MM-DD') AS show_until, a.created_at,
               COALESCE(st.full_name, core.fn_user_display_name(u.user_id)) AS posted_by,
               (r.user_id IS NOT NULL) AS is_read,
               (SELECT COUNT(*) FROM core.announcement_reads x WHERE x.announcement_id = a.announcement_id) AS seen_count,
               v_staff AS staff_count
          FROM core.announcements a
          LEFT JOIN core.users u  ON u.user_id = a.created_by
          LEFT JOIN LATERAL (SELECT s.full_name FROM core.staff s
                              WHERE s.user_id = a.created_by AND s.tenant_id = a.tenant_id LIMIT 1) st ON TRUE
          LEFT JOIN core.announcement_reads r ON r.announcement_id = a.announcement_id AND r.user_id = p_action_user_id
         WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id AND NOT a.is_deleted
           AND (a.show_until IS NULL OR a.show_until >= CURRENT_DATE)
         ORDER BY a.is_pinned DESC, a.created_at DESC
         LIMIT 100;
        RETURN;
    END IF;

    -- ── List: every notice incl. expired ones (manage view)
    IF p_operation = 'List' THEN
        OPEN p_result FOR
        SELECT a.announcement_id, a.title, a.body, a.category, a.audience, a.class_names,
               a.is_pinned, to_char(a.show_until, 'YYYY-MM-DD') AS show_until, a.created_at,
               COALESCE(st.full_name, core.fn_user_display_name(u.user_id)) AS posted_by,
               (r.user_id IS NOT NULL) AS is_read,
               (SELECT COUNT(*) FROM core.announcement_reads x WHERE x.announcement_id = a.announcement_id) AS seen_count,
               v_staff AS staff_count
          FROM core.announcements a
          LEFT JOIN core.users u  ON u.user_id = a.created_by
          LEFT JOIN LATERAL (SELECT s.full_name FROM core.staff s
                              WHERE s.user_id = a.created_by AND s.tenant_id = a.tenant_id LIMIT 1) st ON TRUE
          LEFT JOIN core.announcement_reads r ON r.announcement_id = a.announcement_id AND r.user_id = p_action_user_id
         WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id AND NOT a.is_deleted
         ORDER BY a.is_pinned DESC, a.created_at DESC
         LIMIT 300;
        RETURN;
    END IF;

    -- ── SeenBy: who opened one notice
    IF p_operation = 'SeenBy' THEN
        OPEN p_result FOR
        SELECT COALESCE(st.full_name, core.fn_user_display_name(u.user_id)) AS name, r.read_at
          FROM core.announcement_reads r
          JOIN core.announcements a ON a.announcement_id = r.announcement_id
                                   AND a.tenant_id = p_tenant_id AND a.school_id = p_school_id
          JOIN core.users u ON u.user_id = r.user_id
          LEFT JOIN LATERAL (SELECT s.full_name FROM core.staff s
                              WHERE s.user_id = r.user_id AND s.tenant_id = p_tenant_id LIMIT 1) st ON TRUE
         WHERE r.announcement_id = p_id
         ORDER BY r.read_at DESC;
        RETURN;
    END IF;

    -- ── Read: mark one notice (p_id) or every live notice as read by this user
    IF p_operation = 'Read' THEN
        INSERT INTO core.announcement_reads (announcement_id, user_id)
        SELECT a.announcement_id, p_action_user_id
          FROM core.announcements a
         WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id AND NOT a.is_deleted
           AND (p_id IS NULL OR a.announcement_id = p_id)
        ON CONFLICT DO NOTHING;
        OPEN p_result FOR SELECT 'Marked as read.'::varchar AS message;
        RETURN;
    END IF;

    -- ── Save: new (p_id null) or edit
    IF p_operation = 'Save' THEN
        IF NULLIF(trim(p_title), '') IS NULL OR NULLIF(trim(p_body), '') IS NULL THEN
            RAISE EXCEPTION 'Title and message are required.';
        END IF;
        IF v_audience NOT IN ('Everyone', 'Staff', 'Parents', 'Classes') THEN
            RAISE EXCEPTION 'Choose who the notice is for.';
        END IF;
        IF v_audience = 'Classes' AND v_classes IS NULL THEN
            RAISE EXCEPTION 'Pick at least one class.';
        END IF;
        IF v_audience <> 'Classes' THEN
            v_classes := NULL;
        END IF;
        -- a notice cannot be posted already expired (QA BUG-102); an old notice may keep its old date
        IF p_show_until IS NOT NULL AND p_show_until < CURRENT_DATE
           AND (p_id IS NULL OR p_show_until IS DISTINCT FROM (SELECT show_until FROM core.announcements WHERE announcement_id = p_id)) THEN
            RAISE EXCEPTION 'The "show until" date cannot be in the past.';
        END IF;

        IF p_id IS NULL THEN
            INSERT INTO core.announcements (tenant_id, school_id, title, body, category, audience, class_names,
                                            is_pinned, show_until, created_by)
            VALUES (p_tenant_id, p_school_id, trim(p_title), trim(p_body), COALESCE(NULLIF(trim(p_category), ''), 'General'),
                    v_audience, v_classes, COALESCE(p_is_pinned, FALSE), p_show_until, p_action_user_id)
            RETURNING announcement_id INTO v_id;
            -- the poster has obviously read it
            INSERT INTO core.announcement_reads (announcement_id, user_id) VALUES (v_id, p_action_user_id);
        ELSE
            UPDATE core.announcements
               SET title = trim(p_title), body = trim(p_body),
                   category = COALESCE(NULLIF(trim(p_category), ''), 'General'),
                   audience = v_audience, class_names = v_classes,
                   is_pinned = COALESCE(p_is_pinned, FALSE), show_until = p_show_until,
                   updated_by = p_action_user_id, updated_at = now()
             WHERE announcement_id = p_id AND tenant_id = p_tenant_id AND school_id = p_school_id AND NOT is_deleted
            RETURNING announcement_id INTO v_id;
            IF v_id IS NULL THEN
                RAISE EXCEPTION 'Notice not found.';
            END IF;
        END IF;
        OPEN p_result FOR SELECT v_id AS announcement_id,
               (CASE WHEN p_id IS NULL THEN 'Notice posted.' ELSE 'Notice updated.' END)::varchar AS message;
        RETURN;
    END IF;

    -- ── Delete (soft)
    IF p_operation = 'Delete' THEN
        UPDATE core.announcements SET is_deleted = TRUE, updated_by = p_action_user_id, updated_at = now()
         WHERE announcement_id = p_id AND tenant_id = p_tenant_id AND school_id = p_school_id AND NOT is_deleted
        RETURNING announcement_id INTO v_id;
        IF v_id IS NULL THEN
            RAISE EXCEPTION 'Notice not found.';
        END IF;
        OPEN p_result FOR SELECT 'Notice deleted.'::varchar AS message;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation.';
END;
$$;


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
               (SELECT COUNT(*) FROM core.students s
                 WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id AND COALESCE(s.is_active, TRUE)
                   AND s.class_name = c.class_name AND lower(COALESCE(s.section, '')) = lower(sec.section_name)
                   AND s.academic_year = v_year)::int AS students,
               sec.class_teacher_staff_id, st.full_name,
               -- the day the section's first (active) student was admitted
               COALESCE((SELECT MIN(NULLIF(s.admission_date, '')::date) FROM core.students s
                          WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id AND COALESCE(s.is_active, TRUE)
                            AND s.class_name = c.class_name AND lower(COALESCE(s.section, '')) = lower(sec.section_name)
                            AND s.academic_year = v_year), v_start) AS start_on
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
    SELECT l.ledger_id, l.student_id, s.class_name, COALESCE(s.section, ''), l.fee_head_name,
           NULLIF(l.due_date, '')::date,
           l.amount_due - l.concession, l.amount_paid,
           GREATEST(l.amount_due - l.amount_paid - l.concession, 0),
           lower(COALESCE(NULLIF(trim(l.academic_year), ''), s.academic_year)) = lower(COALESCE(v_year, '')),
           COALESCE(s.is_active, TRUE),
           COALESCE(NULLIF(regexp_replace(COALESCE(s.mobile, ''), '\D', '', 'g'), ''), 'S' || s.student_id),
           COALESCE(NULLIF(trim(s.guardian_name), ''), s.student_name), s.student_name
      FROM core.student_ledger l
      JOIN core.students s ON s.student_id = l.student_id AND s.tenant_id = p_tenant_id AND s.school_id = p_school_id
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


