-- =====================================================================
-- The class-sections a user teaches in the session in progress:
-- a period in the timetable, or class teacher of the section.
--
-- Used to decide whose parent phone numbers / address a teacher may see:
-- a teacher sees them for the classes they teach, other students' are
-- masked (ClassTeacherService.GetTaughtSectionsAsync, Helpers/ContactAccess.cs).
-- A user with no staff record (or who teaches nothing) gets no rows.
-- =====================================================================
CREATE OR REPLACE PROCEDURE core.sp_my_class_sections(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    INOUT p_result         refcursor DEFAULT 'my_sections_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_me integer;   -- the caller's staff id
BEGIN
    IF p_tenant_id IS NULL OR p_tenant_id <= 1 OR p_school_id IS NULL OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid tenant/school scope.';
    END IF;

    SELECT s.staff_id INTO v_me
      FROM core.staff s
     WHERE s.user_id = p_action_user_id AND s.tenant_id = p_tenant_id AND s.school_id = p_school_id
       AND NOT COALESCE(s.is_deleted, FALSE) AND COALESCE(s.is_active, TRUE)
     LIMIT 1;

    OPEN p_result FOR
    SELECT DISTINCT c.class_name, sec.section_name
      FROM academic.academic_class_sections sec
      JOIN academic.academic_classes c ON c.academic_class_id = sec.academic_class_id
      JOIN academic.academic_years y ON y.academic_year_id = sec.academic_year_id AND COALESCE(y.is_current, FALSE)
     WHERE sec.tenant_id = p_tenant_id AND sec.school_id = p_school_id
       AND NOT COALESCE(sec.is_deleted, FALSE)
       AND v_me IS NOT NULL
       AND (sec.class_teacher_staff_id = v_me
            OR EXISTS (SELECT 1 FROM academic.timetable t
                        WHERE t.tenant_id = p_tenant_id AND t.school_id = p_school_id
                          AND t.academic_class_section_id = sec.academic_class_section_id
                          AND t.staff_id = v_me));
END;
$procedure$;
