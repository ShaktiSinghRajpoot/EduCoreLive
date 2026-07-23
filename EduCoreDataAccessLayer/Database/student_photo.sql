-- ============================================================================
-- Student photo — stored path + a tiny setter.
--
-- The image file itself lives under wwwroot/uploads/students/... (saved by the
-- controller, same pattern as the school logo); the students row only keeps the
-- URL. Used by the Student Directory avatar and the ID card.
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

ALTER TABLE core.students
    ADD COLUMN IF NOT EXISTS photo_url varchar(300);

COMMENT ON COLUMN core.students.photo_url IS
    'Relative URL of the student''s photo under /uploads/students. NULL = no photo.';


-- ── set (or clear) a student's photo ────────────────────────────────────────
CREATE OR REPLACE PROCEDURE core.sp_student_set_photo(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_student_id     integer,
    IN    p_photo_url      varchar,
    INOUT p_result         refcursor DEFAULT 'student_photo_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_name varchar;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    UPDATE core.students
    SET photo_url  = NULLIF(TRIM(p_photo_url), ''),
        updated_by = p_action_user_id,
        updated_at = now()
    WHERE student_id = p_student_id
      AND tenant_id  = p_tenant_id
      AND school_id  = p_school_id
    RETURNING student_name INTO v_name;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Student not found.';
    END IF;

    OPEN p_result FOR
    SELECT TRUE AS success,
           'Photo updated for ' || v_name || '.' AS message,
           NULLIF(TRIM(p_photo_url), '') AS photo_url;
END;
$procedure$;
