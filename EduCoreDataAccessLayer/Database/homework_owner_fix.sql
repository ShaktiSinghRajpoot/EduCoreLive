-- ============================================================================
-- Homework: only its own teacher (or a manager) changes it (19 Oct 2026, review).
--
-- "Is this my homework?" compared the homework's staff_id with the caller's,
-- NULL-safe. Homework given from an office login has no staff_id, and a caller
-- without a staff record has none either -- NULL matched NULL, so any such login
-- (a receptionist, an accountant) could edit, delete or check it. A caller with no
-- staff record now owns nothing; managers (academics.manage) still can.
--
-- Replaces academic.sp_homework_manage (last in deploy_2026_10_17b.sql).
-- ============================================================================

CREATE OR REPLACE PROCEDURE academic.sp_homework_manage(IN p_operation character varying, IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_can_manage boolean DEFAULT false, IN p_id integer DEFAULT NULL::integer, IN p_section_id integer DEFAULT NULL::integer, IN p_subject_id integer DEFAULT NULL::integer, IN p_title character varying DEFAULT NULL::character varying, IN p_details text DEFAULT NULL::text, IN p_assigned_on date DEFAULT NULL::date, IN p_due_on date DEFAULT NULL::date, IN p_mine boolean DEFAULT false, IN p_student_ids integer[] DEFAULT NULL::integer[], IN p_statuses character varying[] DEFAULT NULL::character varying[], IN p_student_id integer DEFAULT NULL::integer, INOUT p_result refcursor DEFAULT 'homework_cursor'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
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
               ((v_me IS NOT NULL AND h.staff_id = v_me) OR p_can_manage) AS can_edit,
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
        IF p_operation <> 'Students' AND NOT p_can_manage AND (v_me IS NULL OR v_owner IS DISTINCT FROM v_me) THEN
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
$procedure$;
