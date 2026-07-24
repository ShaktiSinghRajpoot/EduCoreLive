-- ============================================================================
-- Class teacher — who owns each class-section (the person who takes attendance).
--
-- The class teacher is a section-level role, stored on the section master
-- (academic.academic_class_sections.class_teacher_staff_id → core.staff).
-- A teacher CAN own more than one section (surfaced as a "conflict" warning,
-- not blocked). Admins/principals are not limited to a section.
--
-- Backs the Assign Class Teacher page, and gates who may mark attendance.
--
--   core.sp_class_teacher_manage   Grid | Teachers | Assign
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

ALTER TABLE academic.academic_class_sections
    ADD COLUMN IF NOT EXISTS class_teacher_staff_id integer;


-- Drop the earlier 6-arg signature so only one overload survives.
DROP PROCEDURE IF EXISTS core.sp_class_teacher_manage(
    varchar, integer, integer, integer, integer, integer, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_class_teacher_manage(
    IN    p_operation      varchar,     -- 'Grid' | 'Teachers' | 'Assign' | 'IsTeacher'
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_section_id     integer DEFAULT NULL,   -- Assign: the section
    IN    p_staff_id       integer DEFAULT NULL,   -- Assign: teacher (0/NULL = clear)
    IN    p_class          varchar DEFAULT NULL,   -- IsTeacher: class name
    IN    p_section        varchar DEFAULT NULL,   -- IsTeacher: section name
    INOUT p_result         refcursor DEFAULT 'class_teacher_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_year integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    -- The school's current academic year (fall back to the latest set up).
    SELECT academic_year_id INTO v_year
    FROM core.school_settings
    WHERE tenant_id = p_tenant_id AND school_id = p_school_id
      AND COALESCE(is_deleted, FALSE) = FALSE
    LIMIT 1;

    IF v_year IS NULL THEN
        SELECT MAX(academic_year_id) INTO v_year
        FROM academic.academic_classes
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND COALESCE(is_deleted, FALSE) = FALSE;
    END IF;

    -- ── Teacher pool: active staff who can be class teachers ──
    IF p_operation = 'Teachers' THEN
        OPEN p_result FOR
        SELECT st.staff_id, st.full_name
        FROM core.staff st
        WHERE st.tenant_id = p_tenant_id AND st.school_id = p_school_id
          AND COALESCE(st.is_deleted, FALSE) = FALSE
          AND COALESCE(st.is_active, TRUE)   = TRUE
        ORDER BY st.full_name;
        RETURN;
    END IF;

    -- ── Assign / clear a section's class teacher ──
    IF p_operation = 'Assign' THEN
        UPDATE academic.academic_class_sections
        SET class_teacher_staff_id = NULLIF(p_staff_id, 0),
            updated_by = p_action_user_id,
            updated_at = now()
        WHERE academic_class_section_id = p_section_id
          AND tenant_id = p_tenant_id AND school_id = p_school_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Section not found.';
        END IF;

        OPEN p_result FOR
        SELECT TRUE AS success,
               CASE WHEN NULLIF(p_staff_id, 0) IS NULL THEN 'Class teacher cleared.'
                    ELSE 'Class teacher assigned.' END AS message;
        RETURN;
    END IF;

    -- ── Is this user the class teacher of a class-section? (attendance gate) ──
    IF p_operation = 'IsTeacher' THEN
        OPEN p_result FOR
        SELECT EXISTS (
            SELECT 1
            FROM academic.academic_class_sections sec
            JOIN academic.academic_classes c ON c.academic_class_id = sec.academic_class_id
            JOIN core.staff st ON st.staff_id = sec.class_teacher_staff_id
                              AND st.tenant_id = sec.tenant_id AND st.school_id = sec.school_id
            WHERE sec.tenant_id = p_tenant_id AND sec.school_id = p_school_id
              AND sec.academic_year_id = v_year
              AND LOWER(c.class_name)   = LOWER(TRIM(p_class))
              AND LOWER(sec.section_name) = LOWER(TRIM(p_section))
              AND st.user_id = p_action_user_id
              AND COALESCE(sec.is_deleted, FALSE) = FALSE
        ) AS is_teacher;
        RETURN;
    END IF;

    -- ── Grid: every class-section for the current year + its teacher + load ──
    OPEN p_result FOR
    SELECT
        sec.academic_class_section_id AS section_id,
        c.class_name,
        c.display_order               AS class_rank,
        sec.section_name,
        sec.room_no,
        sec.class_teacher_staff_id    AS teacher_id,
        st.full_name                  AS teacher_name,
        COALESCE((
            SELECT COUNT(*) FROM academic.academic_class_sections x
            WHERE x.tenant_id = sec.tenant_id AND x.school_id = sec.school_id
              AND x.academic_year_id = sec.academic_year_id
              AND x.class_teacher_staff_id = sec.class_teacher_staff_id
              AND COALESCE(x.is_deleted, FALSE) = FALSE
        ), 0) AS teacher_load
    FROM academic.academic_class_sections sec
    JOIN academic.academic_classes c
      ON c.academic_class_id = sec.academic_class_id
    LEFT JOIN core.staff st
      ON st.staff_id = sec.class_teacher_staff_id
     AND st.tenant_id = sec.tenant_id AND st.school_id = sec.school_id
    WHERE sec.tenant_id = p_tenant_id AND sec.school_id = p_school_id
      AND sec.academic_year_id = v_year
      AND COALESCE(sec.is_deleted, FALSE) = FALSE
      AND COALESCE(c.is_deleted, FALSE)   = FALSE
    ORDER BY c.display_order, c.class_name, sec.section_name;
END;
$procedure$;
