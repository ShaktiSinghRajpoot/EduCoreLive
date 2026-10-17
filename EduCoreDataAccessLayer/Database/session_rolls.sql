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
