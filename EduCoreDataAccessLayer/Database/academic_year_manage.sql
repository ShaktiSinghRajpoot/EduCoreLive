-- ============================================================================
-- Academic Year / Session management
--   List / Save (create+update) / Set-current / Delete (soft) for
--   academic.academic_years, scoped per tenant + school.
--   Delete is guarded: a year that already has classes or students cannot
--   be removed.
-- ============================================================================

CREATE OR REPLACE PROCEDURE academic.sp_school_admin_academic_year_manage(
    IN p_operation          character varying,
    IN p_tenant_id          integer,
    IN p_school_id          integer,
    IN p_action_user_id     integer,
    IN p_academic_year_id   integer   DEFAULT NULL::integer,
    IN p_academic_year_name character varying DEFAULT NULL::character varying,
    IN p_start_date         date      DEFAULT NULL::date,
    IN p_end_date           date      DEFAULT NULL::date,
    IN p_is_current         boolean   DEFAULT FALSE,
    INOUT p_result          refcursor DEFAULT 'result_cursor'::refcursor)
  LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_id            integer;
    v_name          text;
    v_year_name     text;
    v_class_count   integer;
    v_student_count integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    IF p_operation = 'GetAcademicYears' THEN

        OPEN p_result FOR
        SELECT
            ay.academic_year_id,
            ay.academic_year_name,
            ay.start_date,
            ay.end_date,
            COALESCE(ay.is_current, FALSE) AS is_current,
            (SELECT COUNT(*) FROM academic.academic_classes ac
              WHERE ac.tenant_id = p_tenant_id
                AND ac.school_id = p_school_id
                AND ac.academic_year_id = ay.academic_year_id
                AND COALESCE(ac.is_deleted, FALSE) = FALSE) AS class_count,
            (SELECT COUNT(*) FROM core.students st
              WHERE st.tenant_id = p_tenant_id
                AND st.school_id = p_school_id
                AND st.academic_year = ay.academic_year_name
                AND COALESCE(st.is_active, TRUE) = TRUE) AS student_count
        FROM academic.academic_years ay
        WHERE ay.tenant_id = p_tenant_id
          AND ay.school_id = p_school_id
          AND COALESCE(ay.is_deleted, FALSE) = FALSE
        ORDER BY ay.start_date DESC NULLS LAST, ay.academic_year_name DESC;

    ELSIF p_operation = 'SaveAcademicYear' THEN

        v_name := trim(COALESCE(p_academic_year_name, ''));
        IF v_name = '' THEN
            RAISE EXCEPTION 'Academic year name is required.';
        END IF;

        IF p_start_date IS NOT NULL AND p_end_date IS NOT NULL AND p_end_date < p_start_date THEN
            RAISE EXCEPTION 'End date cannot be before start date.';
        END IF;

        IF EXISTS (
            SELECT 1 FROM academic.academic_years
            WHERE tenant_id = p_tenant_id
              AND school_id = p_school_id
              AND COALESCE(is_deleted, FALSE) = FALSE
              AND lower(academic_year_name) = lower(v_name)
              AND academic_year_id <> COALESCE(p_academic_year_id, 0)
        ) THEN
            RAISE EXCEPTION 'An academic year named "%" already exists.', v_name;
        END IF;

        -- Only one current year per school.
        IF COALESCE(p_is_current, FALSE) THEN
            UPDATE academic.academic_years
            SET is_current = FALSE, updated_by = p_action_user_id, updated_at = NOW()
            WHERE tenant_id = p_tenant_id
              AND school_id = p_school_id
              AND COALESCE(is_deleted, FALSE) = FALSE;
        END IF;

        IF p_academic_year_id IS NULL OR p_academic_year_id <= 0 THEN
            INSERT INTO academic.academic_years
                (tenant_id, school_id, academic_year_name, start_date, end_date, is_current,
                 created_by, created_at, is_deleted, is_active)
            VALUES
                (p_tenant_id, p_school_id, v_name, p_start_date, p_end_date, COALESCE(p_is_current, FALSE),
                 p_action_user_id, NOW(), FALSE, TRUE)
            RETURNING academic_year_id INTO v_id;
        ELSE
            UPDATE academic.academic_years
            SET academic_year_name = v_name,
                start_date = p_start_date,
                end_date   = p_end_date,
                is_current = COALESCE(p_is_current, is_current),
                updated_by = p_action_user_id,
                updated_at = NOW()
            WHERE tenant_id = p_tenant_id
              AND school_id = p_school_id
              AND academic_year_id = p_academic_year_id
              AND COALESCE(is_deleted, FALSE) = FALSE
            RETURNING academic_year_id INTO v_id;
        END IF;

        OPEN p_result FOR
        SELECT TRUE AS success, 'Saved successfully.' AS message, v_id AS academic_year_id;

    ELSIF p_operation = 'SetCurrentAcademicYear' THEN

        IF p_academic_year_id IS NULL OR p_academic_year_id <= 0 THEN
            RAISE EXCEPTION 'Select an academic year.';
        END IF;

        UPDATE academic.academic_years
        SET is_current = FALSE, updated_by = p_action_user_id, updated_at = NOW()
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

        UPDATE academic.academic_years
        SET is_current = TRUE, updated_by = p_action_user_id, updated_at = NOW()
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND academic_year_id = p_academic_year_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

        OPEN p_result FOR
        SELECT TRUE AS success, 'Current academic year updated.' AS message, p_academic_year_id AS academic_year_id;

    ELSIF p_operation = 'DeleteAcademicYear' THEN

        IF p_academic_year_id IS NULL OR p_academic_year_id <= 0 THEN
            RAISE EXCEPTION 'Select an academic year.';
        END IF;

        SELECT academic_year_name INTO v_year_name
        FROM academic.academic_years
        WHERE academic_year_id = p_academic_year_id
          AND tenant_id = p_tenant_id
          AND school_id = p_school_id;

        SELECT COUNT(*) INTO v_class_count
        FROM academic.academic_classes
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND academic_year_id = p_academic_year_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

        SELECT COUNT(*) INTO v_student_count
        FROM core.students
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND academic_year = v_year_name
          AND COALESCE(is_active, TRUE) = TRUE;

        IF v_class_count > 0 OR v_student_count > 0 THEN
            RAISE EXCEPTION 'Cannot delete this year: it has % class(es) and % student(s). Remove those first.',
                v_class_count, v_student_count;
        END IF;

        UPDATE academic.academic_years
        SET is_deleted = TRUE, is_active = FALSE, is_current = FALSE,
            deleted_by = p_action_user_id, deleted_at = NOW(),
            updated_by = p_action_user_id, updated_at = NOW()
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND academic_year_id = p_academic_year_id;

        OPEN p_result FOR
        SELECT TRUE AS success, 'Academic year deleted.' AS message, p_academic_year_id AS academic_year_id;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;
