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
-- Who may give homework: a Teaching staff member, or anyone the app says can
-- manage academics (p_can_manage). A teacher edits / deletes / checks only
-- their own homework unless p_can_manage.
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
    IN    p_operation      varchar,          -- List | Save | Delete | Students | Check | Student
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
               h.subject_id, sj.subject_name, h.staff_id, st.full_name AS teacher_name,
               h.title, h.details, to_char(h.assigned_on, 'YYYY-MM-DD') AS assigned_on,
               to_char(h.due_on, 'YYYY-MM-DD') AS due_on,
               (h.staff_id IS NOT DISTINCT FROM v_me OR p_can_manage) AS can_edit,
               (SELECT COUNT(*) FROM academic.homework_status x WHERE x.homework_id = h.homework_id AND x.status = 'Done')    AS done_count,
               (SELECT COUNT(*) FROM academic.homework_status x WHERE x.homework_id = h.homework_id AND x.status <> 'Done')   AS not_done_count,
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
