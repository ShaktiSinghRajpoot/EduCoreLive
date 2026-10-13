-- ============================================================================
-- Timetable "School view": every live period of a session in one call.
--
-- WHY: the Timetable page loads one section (or one teacher) at a time. The
-- School view shows a whole day for every section at once, so it needs all of
-- them together; asking section by section would be one call per section.
--
-- Read only. Rows come from academic.timetable (the live timetable); pending
-- teacher requests are read separately (sp_timetable_request_manage 'Pending').
--
-- Target DB: PostgreSQL. Safe to re-run.
-- ============================================================================

CREATE OR REPLACE PROCEDURE academic.sp_timetable_school_view(
    IN    p_tenant_id        integer,
    IN    p_school_id        integer,
    IN    p_action_user_id   integer,
    IN    p_academic_year_id integer DEFAULT NULL,
    INOUT p_result           refcursor DEFAULT 'school_view_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_year integer := p_academic_year_id;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    -- No session given: the current one.
    IF COALESCE(v_year, 0) = 0 THEN
        SELECT ay.academic_year_id INTO v_year
        FROM academic.academic_years ay
        WHERE ay.tenant_id = p_tenant_id AND ay.school_id = p_school_id
          AND COALESCE(ay.is_current, FALSE) AND NOT COALESCE(ay.is_deleted, FALSE)
        LIMIT 1;
    END IF;

    OPEN p_result FOR
    SELECT t.academic_class_section_id AS section_id,
           t.day_of_week, t.period_seq,
           t.subject_id, s.subject_name,
           t.staff_id, COALESCE(st.full_name, '') AS staff_name
    FROM academic.timetable t
    JOIN academic.school_subjects s ON s.subject_id = t.subject_id
    LEFT JOIN core.staff st ON st.staff_id = t.staff_id
    WHERE t.tenant_id = p_tenant_id AND t.school_id = p_school_id
      AND t.academic_year_id = v_year;
END;
$procedure$;
