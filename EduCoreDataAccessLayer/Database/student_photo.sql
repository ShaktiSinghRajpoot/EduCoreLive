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
    v_old  varchar;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    -- The previous file is returned so the controller can delete it from disk
    -- once the new one is saved; replaced photos used to pile up.
    SELECT student_name, photo_url INTO v_name, v_old
    FROM core.students
    WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Student not found.';
    END IF;

    UPDATE core.students
    SET photo_url  = NULLIF(TRIM(p_photo_url), ''),
        updated_by = p_action_user_id,
        updated_at = now()
    WHERE student_id = p_student_id;

    -- Who changed the photo and when shows on the student's History card.
    INSERT INTO core.admission_audit (tenant_id, school_id, student_id, action, detail, action_by)
    VALUES (p_tenant_id, p_school_id, p_student_id, 'PhotoChanged',
            CASE WHEN NULLIF(TRIM(p_photo_url), '') IS NULL THEN 'Photo removed'
                 WHEN v_old IS NULL THEN 'Photo added'
                 ELSE 'Photo replaced' END,
            p_action_user_id);

    OPEN p_result FOR
    SELECT TRUE AS success,
           'Photo updated for ' || v_name || '.' AS message,
           NULLIF(TRIM(p_photo_url), '') AS photo_url,
           v_old AS old_photo_url;
END;
$procedure$;
