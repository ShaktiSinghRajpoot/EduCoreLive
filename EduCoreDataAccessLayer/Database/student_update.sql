-- ============================================================================
-- Edit an existing student.
--
-- WHY THIS EXISTS. core.sp_admission_manage's 'SaveAdmission' is INSERT-only —
-- it always creates a new student — so the Edit Student page had no way to save
-- and was left as a stub. This adds the missing update path.
--
-- WHAT IT DELIBERATELY DOES NOT TOUCH:
--
--   * the fee plan and core.student_ledger. Changing what a student owes is a
--     money operation and belongs in the fee module, where it leaves a
--     concession/adjustment trail. Silently regenerating the ledger from an edit
--     screen would wipe paid installments.
--   * academic_year, and class/section on their own. Moving a student between
--     classes mid-session has consequences (roster, attendance, the promotion
--     ladder), so it is allowed here but recorded via updated_by/updated_at —
--     and the session itself only ever changes through promotion.
--   * admission_no. It is the school's permanent reference, printed on
--     receipts and the TC. Re-issuing one is not an edit.
--
-- Target DB: PostgreSQL. Safe to re-run. Additive — a new operation on an
-- existing proc, so no signature change and nothing else is affected.
-- ============================================================================

CREATE OR REPLACE PROCEDURE core.sp_student_update(
    IN  p_tenant_id       integer,
    IN  p_school_id       integer,
    IN  p_action_user_id  integer,
    IN  p_student_id      integer,
    IN  p_student_name    text    DEFAULT NULL,
    IN  p_roll_no         text    DEFAULT NULL,
    IN  p_gender          text    DEFAULT NULL,
    IN  p_dob             date    DEFAULT NULL,
    IN  p_class_name      text    DEFAULT NULL,
    IN  p_section         text    DEFAULT NULL,
    IN  p_guardian_name   text    DEFAULT NULL,
    IN  p_mother_name     text    DEFAULT NULL,
    IN  p_mobile          text    DEFAULT NULL,
    IN  p_alt_mobile      text    DEFAULT NULL,
    IN  p_address         text    DEFAULT NULL,
    IN  p_blood_group     text    DEFAULT NULL,
    IN  p_religion        text    DEFAULT NULL,
    IN  p_category        text    DEFAULT NULL,
    IN  p_nationality     text    DEFAULT NULL,
    IN  p_id_proof_no     text    DEFAULT NULL,
    IN  p_prev_school     text    DEFAULT NULL,
    INOUT p_result        refcursor DEFAULT 'student_update_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_name text := NULLIF(TRIM(COALESCE(p_student_name, '')), '');
    v_cls  text := NULLIF(TRIM(COALESCE(p_class_name, '')), '');
    v_found boolean;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR COALESCE(p_student_id, 0) <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    IF v_name IS NULL THEN
        RAISE EXCEPTION 'Student name is required.';
    END IF;

    -- The row must be this school's. Scoped here as well as in the UPDATE so the
    -- caller gets "not found" rather than a silent no-op.
    SELECT TRUE INTO v_found
    FROM core.students
    WHERE student_id = p_student_id
      AND tenant_id  = p_tenant_id
      AND school_id  = p_school_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Student not found.';
    END IF;

    -- A class must exist in the school's setup, or the student lands on a class
    -- that no roster, timetable or promotion ladder knows about.
    IF v_cls IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academic.academic_classes
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND class_name = v_cls
          AND COALESCE(is_deleted, FALSE) = FALSE
    ) THEN
        RAISE EXCEPTION 'Class % is not set up for this school.', v_cls;
    END IF;

    UPDATE core.students
    SET student_name   = v_name,
        roll_no        = NULLIF(TRIM(COALESCE(p_roll_no, '')), ''),
        gender         = NULLIF(TRIM(COALESCE(p_gender, '')), ''),
        dob            = COALESCE(p_dob::text, dob),
        class_name     = COALESCE(v_cls, class_name),
        section        = NULLIF(TRIM(COALESCE(p_section, '')), ''),
        guardian_name  = NULLIF(TRIM(COALESCE(p_guardian_name, '')), ''),
        mother_name    = NULLIF(TRIM(COALESCE(p_mother_name, '')), ''),
        mobile         = NULLIF(TRIM(COALESCE(p_mobile, '')), ''),
        alt_mobile     = NULLIF(TRIM(COALESCE(p_alt_mobile, '')), ''),
        address        = NULLIF(TRIM(COALESCE(p_address, '')), ''),
        blood_group    = NULLIF(TRIM(COALESCE(p_blood_group, '')), ''),
        religion       = NULLIF(TRIM(COALESCE(p_religion, '')), ''),
        category       = NULLIF(TRIM(COALESCE(p_category, '')), ''),
        nationality    = NULLIF(TRIM(COALESCE(p_nationality, '')), ''),
        id_proof_no    = NULLIF(TRIM(COALESCE(p_id_proof_no, '')), ''),
        prev_school_name = NULLIF(TRIM(COALESCE(p_prev_school, '')), ''),
        updated_by     = p_action_user_id,
        updated_at     = NOW()
    WHERE student_id = p_student_id
      AND tenant_id  = p_tenant_id
      AND school_id  = p_school_id;

    OPEN p_result FOR
    SELECT TRUE AS success, 'Student updated successfully.' AS message, p_student_id AS student_id;
END;
$procedure$;
