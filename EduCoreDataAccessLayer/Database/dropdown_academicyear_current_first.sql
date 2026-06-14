-- ============================================================================
-- Make the shared AcademicYear dropdown default to the CURRENT session:
--   * current year is ordered first
--   * an "IsSelected" flag is returned so the select can pre-select it
-- Other dropdown activities are unchanged.
-- ============================================================================

CREATE OR REPLACE PROCEDURE config.sp_dropdown_common(
    IN p_activity character varying,
    IN p_param1 character varying DEFAULT NULL::character varying,
    IN p_param2 character varying DEFAULT NULL::character varying,
    INOUT p_result refcursor DEFAULT 'result_cursor'::refcursor)
  LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_activity = 'AcademicYear' THEN

        OPEN p_result FOR
        SELECT
            academic_year_name AS "Name",
            academic_year_id::text AS "Code",
            COALESCE(is_current, FALSE) AS "IsSelected"
        FROM academic.academic_years
        WHERE COALESCE(is_deleted, FALSE) = FALSE
          AND COALESCE(is_active, TRUE) = TRUE
        ORDER BY COALESCE(is_current, FALSE) DESC, academic_year_id DESC;

      elseIF p_activity = 'Class' THEN
        OPEN p_result FOR
        SELECT
            class_name AS "Name",
            academic_class_id::text AS "Code"
        FROM academic.academic_classes
        WHERE COALESCE(is_deleted, FALSE) = FALSE
          AND COALESCE(is_active, TRUE) = TRUE
        ORDER BY academic_class_id DESC;

    ELSE

        OPEN p_result FOR
        SELECT
            ''::text AS "Name",
            ''::text AS "Code"
        WHERE FALSE;

    END IF;
END;
$procedure$;
