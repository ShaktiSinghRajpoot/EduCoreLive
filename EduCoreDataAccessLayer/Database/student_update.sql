-- ============================================================================
-- Edit an existing student.
--
-- WHY THIS EXISTS. core.sp_admission_manage's 'SaveAdmission' is INSERT-only —
-- it always creates a new student — so the Edit Student page had no way to save
-- and was left as a stub. This adds the missing update path.
--
-- WHAT IT DELIBERATELY DOES NOT TOUCH:
--
--   * paid or past instalments. A CLASS change is a money event, though: the
--     new class may cost more or less. When the new class has a fee structure
--     for the student's session, the old class's recurring instalments due
--     AFTER today are CLOSED (reason 'Moved from X to Y on <date>', never
--     deleted) and the new class's recurring heads are billed from next month
--     through core.fn_student_bill_plan -- the same billing admission uses.
--     When it has none, fees are left as they are and the message says so.
--     Every class / section change writes an admission_audit row.
--   * academic_year. The session only ever changes through promotion, and the
--     class must exist in the student's CURRENT session.
--
-- The student's enrolment row for the session follows a class/section change,
-- so lists filtered by session show the class the student is really in.
--
-- Depends on student_money_lifecycle.sql -- apply it first.
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
    v_name   text := NULLIF(TRIM(COALESCE(p_student_name, '')), '');
    v_cls    text := NULLIF(TRIM(COALESCE(p_class_name, '')), '');
    v_sec    text := NULLIF(TRIM(COALESCE(p_section, '')), '');
    s        core.students%ROWTYPE;
    v_class_id   integer;
    v_class_moved boolean;
    v_moved   boolean;
    v_plan    jsonb;
    v_from    date := (DATE_TRUNC('month', CURRENT_DATE) + INTERVAL '1 month')::date;
    v_reason  varchar(200);
    v_closed  numeric(12,2) := 0;
    v_billed  integer := 0;
    v_note    text := '';
    r         record;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR COALESCE(p_student_id, 0) <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    IF v_name IS NULL THEN
        RAISE EXCEPTION 'Student name is required.';
    END IF;

    -- The row must be this school's. Scoped here as well as in the UPDATE so the
    -- caller gets "not found" rather than a silent no-op.
    SELECT * INTO s
    FROM core.students
    WHERE student_id = p_student_id
      AND tenant_id  = p_tenant_id
      AND school_id  = p_school_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Student not found.';
    END IF;

    v_cls := COALESCE(v_cls, s.class_name);

    -- The class must exist in the student's OWN session. Checking "any class
    -- this school ever had" let a student sit in a class that only exists in
    -- another session, where no roster or fee structure for this one finds them.
    SELECT ac.academic_class_id INTO v_class_id
    FROM academic.academic_classes ac
    JOIN academic.academic_years ay ON ay.academic_year_id = ac.academic_year_id
    WHERE ac.tenant_id = p_tenant_id AND ac.school_id = p_school_id
      AND ac.class_name = v_cls
      AND ay.academic_year_name = s.academic_year
      AND COALESCE(ac.is_deleted, FALSE) = FALSE
    ORDER BY ac.display_order, ac.academic_class_id
    LIMIT 1;

    IF v_class_id IS NULL THEN
        RAISE EXCEPTION 'Class % is not set up for session %.', v_cls, s.academic_year;
    END IF;

    -- A section must be one that class has (when the class has sections at all).
    IF v_sec IS NOT NULL
       AND EXISTS (SELECT 1 FROM academic.academic_class_sections
                    WHERE academic_class_id = v_class_id AND COALESCE(is_deleted, FALSE) = FALSE)
       AND NOT EXISTS (SELECT 1 FROM academic.academic_class_sections
                        WHERE academic_class_id = v_class_id AND section_name = v_sec
                          AND COALESCE(is_deleted, FALSE) = FALSE) THEN
        RAISE EXCEPTION 'Section % does not exist in class %.', v_sec, v_cls;
    END IF;

    v_class_moved := v_cls <> COALESCE(s.class_name, '');
    v_moved       := v_class_moved OR COALESCE(v_sec, '') <> COALESCE(s.section, '');

    UPDATE core.students
    SET student_name   = v_name,
        roll_no        = NULLIF(TRIM(COALESCE(p_roll_no, '')), ''),
        gender         = NULLIF(TRIM(COALESCE(p_gender, '')), ''),
        dob            = COALESCE(p_dob::text, dob),
        class_name     = v_cls,
        section        = v_sec,
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

    IF v_moved THEN
        -- The per-session record follows the move (see student_enrolment.sql).
        UPDATE core.student_enrolment
        SET class_name        = v_cls,
            academic_class_id = v_class_id,
            section           = v_sec,
            updated_by        = p_action_user_id,
            updated_at        = now()
        WHERE student_id = p_student_id AND academic_year = s.academic_year;
    END IF;

    IF v_class_moved AND s.is_active THEN
        -- Only the cycle heads (monthly / quarterly / half-yearly) follow the
        -- class: one-time and yearly charges were already billed for the year.
        SELECT jsonb_agg(e) INTO v_plan
        FROM jsonb_array_elements(core.fn_class_fee_plan(p_tenant_id, p_school_id, v_cls, s.academic_year)) e
        WHERE lower(e->>'frequency') IN ('monthly', 'quarterly', 'half yearly');

        IF v_plan IS NULL THEN
            v_note := ' No fee structure for ' || v_cls || ' in ' || s.academic_year || ': fees were not changed.';
        ELSE
            v_reason := 'Moved from ' || COALESCE(s.class_name, '?') || ' to ' || v_cls ||
                        ' on ' || to_char(CURRENT_DATE, 'YYYY-MM-DD');
            FOR r IN
                SELECT ledger_id FROM core.student_ledger
                WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
                  AND fee_head_name <> 'Transport Fee'
                  AND lower(frequency) IN ('monthly', 'quarterly', 'half yearly')
                  AND (academic_year = s.academic_year OR academic_year IS NULL)
                  AND due_date IS NOT NULL AND due_date::date > CURRENT_DATE
                  AND amount_due - amount_paid - concession > 0
            LOOP
                v_closed := v_closed + core.fn_ledger_close(r.ledger_id, v_reason, 'ClassChange', p_action_user_id);
            END LOOP;

            -- The new class's plan is the one in force for the rest of the session.
            UPDATE core.student_fee_plan SET is_current = FALSE
            WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
              AND is_current AND (academic_year = s.academic_year OR academic_year IS NULL);

            v_billed := core.fn_student_bill_plan(p_tenant_id, p_school_id, p_action_user_id,
                            p_student_id, s.academic_year, v_from, v_plan, TRUE, v_from);

            v_note := ' Fees: ' || to_char(v_closed, 'FM99999990.00') || ' of ' || s.class_name ||
                      ' instalments closed, ' || v_billed || ' ' || v_cls || ' instalment(s) billed from ' ||
                      to_char(v_from, 'Mon YYYY') || '.';
        END IF;

        INSERT INTO core.admission_audit (tenant_id, school_id, student_id, action, detail, action_by)
        VALUES (p_tenant_id, p_school_id, p_student_id, 'ClassChanged',
                COALESCE(s.class_name, '?') || COALESCE('-' || s.section, '') || ' -> ' ||
                v_cls || COALESCE('-' || v_sec, '') || '.' || v_note,
                p_action_user_id);
    ELSIF v_moved THEN
        INSERT INTO core.admission_audit (tenant_id, school_id, student_id, action, detail, action_by)
        VALUES (p_tenant_id, p_school_id, p_student_id, 'SectionChanged',
                v_cls || COALESCE('-' || s.section, '') || ' -> ' || v_cls || COALESCE('-' || v_sec, ''),
                p_action_user_id);
    END IF;

    OPEN p_result FOR
    SELECT TRUE AS success, 'Student updated successfully.' || v_note AS message, p_student_id AS student_id;
END;
$procedure$;
