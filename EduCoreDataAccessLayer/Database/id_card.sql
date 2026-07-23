-- ============================================================================
-- Student ID Card — print (single + class-wise bulk).
--
-- Unlike the TC, an ID card is NOT a frozen legal document: it is generated
-- on demand from the student's CURRENT data, so there is no register table.
-- This script only stores the school's chosen card format and provides the
-- read that feeds the print grid.
--
-- The card carries a photo box that stays blank until a student-photo upload
-- exists (schools commonly paste the photo physically for now).
--
--   core.school_settings.id_card_format         Portrait | Landscape
--   core.sp_school_id_card_format_manage         Get | Save the format
--   core.sp_id_card_students                      one class's active students
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── default ID-card format (next to receipt_format / tc_format) ──────────────
ALTER TABLE core.school_settings
    ADD COLUMN IF NOT EXISTS id_card_format varchar(20) NOT NULL DEFAULT 'Portrait';

ALTER TABLE core.school_settings DROP CONSTRAINT IF EXISTS chk_school_settings_id_card_format;
ALTER TABLE core.school_settings
    ADD CONSTRAINT chk_school_settings_id_card_format
    CHECK (id_card_format IN ('Portrait', 'Landscape'));


-- ── read/write the format (mirrors the receipt / tc format procs) ────────────
CREATE OR REPLACE PROCEDURE core.sp_school_id_card_format_manage(
    IN    p_operation      varchar,          -- 'Get' | 'Save'
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_format         varchar   DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'id_card_format_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_format varchar(20);
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    IF p_operation = 'Save' THEN
        v_format := CASE WHEN p_format IN ('Portrait', 'Landscape')
                         THEN p_format ELSE 'Portrait' END;

        INSERT INTO core.school_settings (tenant_id, school_id, id_card_format, created_by, created_at, is_deleted, is_active)
        VALUES (p_tenant_id, p_school_id, v_format, p_action_user_id, NOW(), FALSE, TRUE)
        ON CONFLICT (tenant_id, school_id) DO UPDATE
            SET id_card_format = EXCLUDED.id_card_format,
                updated_by     = p_action_user_id,
                updated_at     = NOW();

        OPEN p_result FOR SELECT TRUE AS success, v_format AS id_card_format;

    ELSE   -- Get
        OPEN p_result FOR
        SELECT COALESCE(NULLIF(TRIM(s.id_card_format), ''), 'Portrait') AS id_card_format
        FROM core.school_settings s
        WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id
          AND COALESCE(s.is_deleted, FALSE) = FALSE
        LIMIT 1;
    END IF;
END;
$procedure$;


-- ── the students on one class's ID-card sheet ────────────────────────────────
-- Class + academic year pick the batch; section is optional (blank = all
-- sections of that class). Only active students are carried onto cards.
-- p_student_id, when given, returns just that one student (single-card print).
DROP PROCEDURE IF EXISTS core.sp_id_card_students(
    integer, integer, integer, varchar, varchar, varchar, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_id_card_students(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_class          varchar DEFAULT NULL,
    IN    p_section        varchar DEFAULT NULL,
    IN    p_academic_year  varchar DEFAULT NULL,
    IN    p_student_id     integer DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'id_card_students_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        OPEN p_result FOR SELECT WHERE FALSE;
        RETURN;
    END IF;

    OPEN p_result FOR
    SELECT
        s.student_id, s.admission_no, s.roll_no, s.student_name,
        s.class_name, s.section, s.academic_year,
        s.dob, s.blood_group, s.gender,
        s.guardian_name, s.mobile, s.address, s.photo_url
    FROM core.students s
    WHERE s.tenant_id = p_tenant_id
      AND s.school_id = p_school_id
      AND s.is_active = TRUE
      AND (p_student_id IS NULL OR s.student_id = p_student_id)
      AND (p_class IS NULL OR TRIM(p_class) = '' OR LOWER(s.class_name) = LOWER(TRIM(p_class)))
      AND (p_section IS NULL OR TRIM(p_section) = '' OR LOWER(COALESCE(s.section, '')) = LOWER(TRIM(p_section)))
      AND (p_academic_year IS NULL OR TRIM(p_academic_year) = '' OR s.academic_year = TRIM(p_academic_year))
    ORDER BY
        -- Roll numbers are text; sort them numerically when they are numbers,
        -- then fall back to name so the sheet reads in register order.
        CASE WHEN s.roll_no ~ '^[0-9]+$' THEN lpad(s.roll_no, 6, '0') ELSE NULL END NULLS LAST,
        s.student_name;
END;
$procedure$;


-- ── the sections that actually have students in a class ──────────────────────
-- Feeds the ID-card chooser's Section dropdown, so it only lists sections that
-- have active students to print (no config setup needed).
CREATE OR REPLACE PROCEDURE core.sp_id_card_sections(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_class          varchar DEFAULT NULL,
    IN    p_academic_year  varchar DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'id_card_sections_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        OPEN p_result FOR SELECT WHERE FALSE;
        RETURN;
    END IF;

    OPEN p_result FOR
    SELECT DISTINCT TRIM(s.section) AS section
    FROM core.students s
    WHERE s.tenant_id = p_tenant_id
      AND s.school_id = p_school_id
      AND s.is_active = TRUE
      AND COALESCE(TRIM(s.section), '') <> ''
      AND (p_class IS NULL OR TRIM(p_class) = '' OR LOWER(s.class_name) = LOWER(TRIM(p_class)))
      AND (p_academic_year IS NULL OR TRIM(p_academic_year) = '' OR s.academic_year = TRIM(p_academic_year))
    ORDER BY 1;
END;
$procedure$;
