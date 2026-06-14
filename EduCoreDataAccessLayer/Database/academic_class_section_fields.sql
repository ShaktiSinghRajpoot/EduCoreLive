-- ============================================================================
-- Classes & Sections: richer per-class / per-section attributes
--   classes  : stream, coordinator
--   sections : capacity, room_no
-- Strength (live student count) is derived from core.students, not stored.
-- Also adds a guard: a class/section that still has enrolled students cannot
-- be removed from the academic setup.
-- ============================================================================

ALTER TABLE academic.academic_classes
    ADD COLUMN IF NOT EXISTS stream      varchar(50),
    ADD COLUMN IF NOT EXISTS coordinator varchar(150);

ALTER TABLE academic.academic_class_sections
    ADD COLUMN IF NOT EXISTS capacity int,
    ADD COLUMN IF NOT EXISTS room_no  varchar(50);

CREATE OR REPLACE PROCEDURE academic.sp_school_admin_academic_setup_manage(
    IN p_operation          character varying,
    IN p_tenant_id          integer,
    IN p_school_id          integer,
    IN p_action_user_id     integer,
    IN p_academic_year_id   integer   DEFAULT NULL::integer,
    IN p_academic_year_name character varying DEFAULT NULL::character varying,
    IN p_setup_json         text      DEFAULT NULL::text,
    INOUT p_result          refcursor DEFAULT 'result_cursor'::refcursor)
  LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_academic_year_id   integer;
    v_academic_year_name text;
    v_academic_class_id  integer;

    v_setup_json   jsonb;
    v_class_item   jsonb;
    v_section_item jsonb;

    v_class_name   text;
    v_section_name text;

    v_class_order   integer;
    v_section_order integer;

    v_stream      text;
    v_coordinator text;
    v_capacity    integer;
    v_room_no     text;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    IF p_operation = 'GetAcademicSetup' THEN

        OPEN p_result FOR
        SELECT
            ay.academic_year_id,
            p_tenant_id AS tenant_id,
            p_school_id AS school_id,
            ay.start_date,
            ay.end_date,
            ay.is_current,
            ac.academic_class_id,
            ac.class_name,
            ac.display_order AS class_display_order,
            ac.stream,
            ac.coordinator,
            acs.academic_class_section_id,
            acs.section_name,
            acs.display_order AS section_display_order,
            acs.capacity,
            acs.room_no,
            COALESCE((
                SELECT COUNT(*)
                FROM core.students st
                WHERE st.tenant_id = p_tenant_id
                  AND st.school_id = p_school_id
                  AND st.academic_year = ay.academic_year_name
                  AND st.class_name = ac.class_name
                  AND st.section = acs.section_name
                  AND COALESCE(st.is_active, TRUE) = TRUE
            ), 0) AS strength
        FROM academic.academic_years ay
        LEFT JOIN academic.academic_classes ac
            ON ac.academic_year_id = ay.academic_year_id
           AND ac.tenant_id = p_tenant_id
           AND ac.school_id = p_school_id
           AND COALESCE(ac.is_deleted, FALSE) = FALSE
        LEFT JOIN academic.academic_class_sections acs
            ON acs.academic_class_id = ac.academic_class_id
           AND acs.academic_year_id = ay.academic_year_id
           AND acs.tenant_id = p_tenant_id
           AND acs.school_id = p_school_id
           AND COALESCE(acs.is_deleted, FALSE) = FALSE
        WHERE ay.academic_year_id = p_academic_year_id
          AND COALESCE(ay.is_deleted, FALSE) = FALSE
          AND COALESCE(ay.is_active, TRUE) = TRUE
        ORDER BY
            ac.display_order,
            ac.class_name,
            acs.display_order,
            acs.section_name;

    ELSIF p_operation = 'SaveAcademicSetup' THEN

        IF p_academic_year_id IS NULL OR p_academic_year_id <= 0 THEN
            RAISE EXCEPTION 'Please select academic year.';
        END IF;

        v_academic_year_id := p_academic_year_id;
        v_setup_json := COALESCE(NULLIF(p_setup_json, ''), '[]')::jsonb;

        SELECT academic_year_name INTO v_academic_year_name
        FROM academic.academic_years
        WHERE academic_year_id = v_academic_year_id;

        -- Guard: refuse to drop a class/section that still has enrolled students.
        IF EXISTS (
            SELECT 1
            FROM academic.academic_classes ac
            JOIN academic.academic_class_sections acs
              ON acs.academic_class_id = ac.academic_class_id
             AND COALESCE(acs.is_deleted, FALSE) = FALSE
            WHERE ac.tenant_id = p_tenant_id
              AND ac.school_id = p_school_id
              AND ac.academic_year_id = v_academic_year_id
              AND COALESCE(ac.is_deleted, FALSE) = FALSE
              AND EXISTS (
                  SELECT 1 FROM core.students st
                  WHERE st.tenant_id = p_tenant_id
                    AND st.school_id = p_school_id
                    AND st.academic_year = v_academic_year_name
                    AND st.class_name = ac.class_name
                    AND st.section = acs.section_name
                    AND COALESCE(st.is_active, TRUE) = TRUE
              )
              AND NOT EXISTS (
                  SELECT 1
                  FROM jsonb_array_elements(v_setup_json) ci
                  CROSS JOIN jsonb_array_elements(
                      COALESCE(ci -> 'Sections', ci -> 'sections', '[]'::jsonb)) si
                  WHERE trim(COALESCE(ci ->> 'ClassName', ci ->> 'className', '')) = ac.class_name
                    AND trim(
                          CASE WHEN jsonb_typeof(si) = 'object'
                               THEN COALESCE(si ->> 'SectionName', si ->> 'sectionName', '')
                               ELSE trim(BOTH '"' FROM si::text)
                          END
                        ) = acs.section_name
              )
        ) THEN
            RAISE EXCEPTION 'Cannot remove a class or section that still has enrolled students. Move or promote those students first.';
        END IF;

        UPDATE academic.academic_class_sections
        SET is_deleted = TRUE, is_active = FALSE,
            deleted_by = p_action_user_id, deleted_at = NOW(),
            updated_by = p_action_user_id, updated_at = NOW()
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND academic_year_id = v_academic_year_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

        UPDATE academic.academic_classes
        SET is_deleted = TRUE, is_active = FALSE,
            deleted_by = p_action_user_id, deleted_at = NOW(),
            updated_by = p_action_user_id, updated_at = NOW()
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND academic_year_id = v_academic_year_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

        v_class_order := 0;

        FOR v_class_item IN
            SELECT value FROM jsonb_array_elements(v_setup_json)
        LOOP
            v_class_name := trim(COALESCE(v_class_item ->> 'ClassName', v_class_item ->> 'className', ''));

            IF v_class_name <> '' THEN
                v_class_order := v_class_order + 1;
                v_stream      := NULLIF(trim(COALESCE(v_class_item ->> 'stream',      v_class_item ->> 'Stream',      '')), '');
                v_coordinator := NULLIF(trim(COALESCE(v_class_item ->> 'coordinator', v_class_item ->> 'Coordinator', '')), '');

                INSERT INTO academic.academic_classes
                    (tenant_id, school_id, academic_year_id, class_name, display_order,
                     stream, coordinator, created_by, created_at, is_deleted, is_active)
                VALUES
                    (p_tenant_id, p_school_id, v_academic_year_id, v_class_name,
                     COALESCE(NULLIF(v_class_item ->> 'displayOrder', '')::int, v_class_order),
                     v_stream, v_coordinator, p_action_user_id, NOW(), FALSE, TRUE)
                RETURNING academic_class_id INTO v_academic_class_id;

                v_section_order := 0;

                FOR v_section_item IN
                    SELECT value FROM jsonb_array_elements(
                        COALESCE(v_class_item -> 'Sections', v_class_item -> 'sections', '[]'::jsonb))
                LOOP
                    IF jsonb_typeof(v_section_item) = 'object' THEN
                        v_section_name := trim(COALESCE(v_section_item ->> 'sectionName', v_section_item ->> 'SectionName', ''));
                        v_capacity     := NULLIF(v_section_item ->> 'capacity', '')::int;
                        v_room_no      := NULLIF(trim(COALESCE(v_section_item ->> 'roomNo', '')), '');
                    ELSE
                        v_section_name := trim(trim(BOTH '"' FROM v_section_item::text));
                        v_capacity     := NULL;
                        v_room_no      := NULL;
                    END IF;

                    IF v_section_name <> '' THEN
                        v_section_order := v_section_order + 1;

                        INSERT INTO academic.academic_class_sections
                            (tenant_id, school_id, academic_year_id, academic_class_id, section_name,
                             display_order, capacity, room_no, created_by, created_at, is_deleted, is_active)
                        VALUES
                            (p_tenant_id, p_school_id, v_academic_year_id, v_academic_class_id, v_section_name,
                             v_section_order, v_capacity, v_room_no, p_action_user_id, NOW(), FALSE, TRUE);
                    END IF;
                END LOOP;
            END IF;
        END LOOP;

        OPEN p_result FOR
        SELECT
            TRUE AS success,
            'Saved successfully.' AS message,
            v_academic_year_id AS academic_year_id;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;
