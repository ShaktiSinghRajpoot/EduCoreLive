-- Bundle 2026-10-16b: core.sp_class_teacher_of (read-only: the sections someone is class teacher of). Run with:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_16b.sql
-- Sources: class_teacher_of.sql

-- ============================================================================
-- Which sections is someone the class teacher of (current session)?
--
-- Shown to the teacher in the profile menu and on the dashboard ("Your class:
-- Class 3-A, 32 students, attendance not marked yet"), and to the office on the
-- staff profile. Read-only.
--
--   p_staff_id NULL -> the staff record of the signed-in user (p_action_user_id)
--   p_staff_id set  -> that staff member (staff profile page)
--
-- Re-runnable.
-- ============================================================================
CREATE OR REPLACE PROCEDURE core.sp_class_teacher_of(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_staff_id       integer DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'class_teacher_of_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_staff integer := p_staff_id;
    v_year  integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    IF v_staff IS NULL THEN
        SELECT staff_id INTO v_staff
          FROM core.staff
         WHERE user_id = p_action_user_id AND tenant_id = p_tenant_id AND school_id = p_school_id
           AND NOT COALESCE(is_deleted, FALSE) AND COALESCE(status, 'Active') <> 'Inactive'
         LIMIT 1;
    END IF;

    SELECT academic_year_id INTO v_year
      FROM academic.academic_years
     WHERE tenant_id = p_tenant_id AND school_id = p_school_id
       AND is_current AND NOT COALESCE(is_deleted, FALSE)
     LIMIT 1;

    OPEN p_result FOR
    SELECT sec.academic_class_section_id AS section_id,
           c.class_name,
           sec.section_name,
           y.academic_year_name,
           (SELECT COUNT(*) FROM core.students st
             WHERE st.tenant_id = p_tenant_id AND st.school_id = p_school_id AND st.is_active
               AND st.academic_year = y.academic_year_name
               AND st.class_name = c.class_name AND COALESCE(st.section, '') = COALESCE(sec.section_name, ''))::int AS students,
           EXISTS (SELECT 1 FROM core.student_attendance a
                    WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
                      AND a.academic_year = y.academic_year_name
                      AND a.class_name = c.class_name AND COALESCE(a.section, '') = COALESCE(sec.section_name, '')
                      AND a.attendance_date::date = CURRENT_DATE) AS marked_today
      FROM academic.academic_class_sections sec
      JOIN academic.academic_classes c ON c.academic_class_id = sec.academic_class_id
      JOIN academic.academic_years y   ON y.academic_year_id  = sec.academic_year_id
     WHERE sec.tenant_id = p_tenant_id AND sec.school_id = p_school_id
       AND v_staff IS NOT NULL AND sec.class_teacher_staff_id = v_staff
       AND sec.academic_year_id = v_year
       AND NOT COALESCE(sec.is_deleted, FALSE) AND NOT COALESCE(c.is_deleted, FALSE)
     ORDER BY c.display_order, c.class_name, sec.display_order, sec.section_name;
END;
$procedure$;
