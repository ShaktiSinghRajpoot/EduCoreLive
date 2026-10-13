-- Bundle 2026-10-13: Student Dashboard / Edit Student. Run with:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_13.sql
-- core.sp_student_update gains the extended admission fields after p_result,
-- written only when p_extended = TRUE, so the running app keeps working and
-- keeps the stored values. Source: student_update.sql.

DROP PROCEDURE IF EXISTS core.sp_student_update(integer, integer, integer, integer,
    text, text, text, date, text, text, text, text, text, text, text, text, text, text, text, text, text, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_student_update(IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_student_id integer, IN p_student_name text DEFAULT NULL::text, IN p_roll_no text DEFAULT NULL::text, IN p_gender text DEFAULT NULL::text, IN p_dob date DEFAULT NULL::date, IN p_class_name text DEFAULT NULL::text, IN p_section text DEFAULT NULL::text, IN p_guardian_name text DEFAULT NULL::text, IN p_mother_name text DEFAULT NULL::text, IN p_mobile text DEFAULT NULL::text, IN p_alt_mobile text DEFAULT NULL::text, IN p_address text DEFAULT NULL::text, IN p_blood_group text DEFAULT NULL::text, IN p_religion text DEFAULT NULL::text, IN p_category text DEFAULT NULL::text, IN p_nationality text DEFAULT NULL::text, IN p_id_proof_no text DEFAULT NULL::text, IN p_prev_school text DEFAULT NULL::text, INOUT p_result refcursor DEFAULT 'student_update_cursor'::refcursor, IN p_extended boolean DEFAULT false, IN p_mother_tongue text DEFAULT NULL::text, IN p_apaar_id text DEFAULT NULL::text, IN p_udise_student_id text DEFAULT NULL::text, IN p_prev_board text DEFAULT NULL::text, IN p_prev_class text DEFAULT NULL::text, IN p_prev_tc_no text DEFAULT NULL::text, IN p_father_occupation text DEFAULT NULL::text, IN p_father_qualification text DEFAULT NULL::text, IN p_father_email text DEFAULT NULL::text, IN p_mother_occupation text DEFAULT NULL::text, IN p_mother_qualification text DEFAULT NULL::text, IN p_mother_email text DEFAULT NULL::text, IN p_annual_income numeric DEFAULT NULL::numeric)
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
    v_roll    text := NULLIF(TRIM(COALESCE(p_roll_no, '')), '');
    v_gender  text := NULLIF(TRIM(COALESCE(p_gender, '')), '');
    v_mobile  text := NULLIF(TRIM(COALESCE(p_mobile, '')), '');
    v_alt     text := NULLIF(TRIM(COALESCE(p_alt_mobile, '')), '');
    v_idp     text := NULLIF(TRIM(COALESCE(p_id_proof_no, '')), '');
    v_dob     text;
    v_changes text[] := '{}';
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
    v_dob         := COALESCE(p_dob::text, s.dob);

    -- ── Same rules as admission (sp_admission_manage / AdmissionController) ──
    -- Each fires only when the value changes, so legacy rows stay editable.
    IF v_dob IS DISTINCT FROM s.dob THEN
        IF v_dob::date > CURRENT_DATE THEN
            RAISE EXCEPTION 'Date of birth cannot be in the future.';
        END IF;
        IF s.admission_date IS NOT NULL AND v_dob::date > s.admission_date::date THEN
            RAISE EXCEPTION 'Date of birth cannot be after the admission date (%).', s.admission_date;
        END IF;
    END IF;

    IF v_mobile IS DISTINCT FROM s.mobile AND v_mobile IS NOT NULL AND v_mobile !~ '^[0-9]{10}$' THEN
        RAISE EXCEPTION 'Mobile number must be 10 digits.';
    END IF;
    IF v_alt IS DISTINCT FROM s.alt_mobile AND v_alt IS NOT NULL AND v_alt !~ '^[0-9]{10}$' THEN
        RAISE EXCEPTION 'Alternate mobile must be 10 digits.';
    END IF;
    IF v_idp IS DISTINCT FROM s.id_proof_no AND v_idp IS NOT NULL AND v_idp !~ '^[0-9]{12}$' THEN
        RAISE EXCEPTION 'Aadhaar number must be 12 digits.';
    END IF;

    -- The extended fields (see header). Same "only when changed" rule.
    IF p_extended THEN
        IF NULLIF(TRIM(COALESCE(p_apaar_id, '')), '') IS DISTINCT FROM s.apaar_id
           AND NULLIF(TRIM(COALESCE(p_apaar_id, '')), '') !~ '^[0-9]{12}$' THEN
            RAISE EXCEPTION 'APAAR ID must be 12 digits.';
        END IF;
        IF NULLIF(TRIM(COALESCE(p_father_email, '')), '') IS DISTINCT FROM s.father_email
           AND NULLIF(TRIM(COALESCE(p_father_email, '')), '') !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' THEN
            RAISE EXCEPTION 'Father email is not a valid email address.';
        END IF;
        IF NULLIF(TRIM(COALESCE(p_mother_email, '')), '') IS DISTINCT FROM s.mother_email
           AND NULLIF(TRIM(COALESCE(p_mother_email, '')), '') !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' THEN
            RAISE EXCEPTION 'Mother email is not a valid email address.';
        END IF;
        IF p_annual_income IS NOT NULL AND p_annual_income < 0 THEN
            RAISE EXCEPTION 'Annual income cannot be negative.';
        END IF;
    END IF;

    -- Gender drives the Male / Female counts; store the canonical spelling.
    IF v_gender IS NOT NULL THEN
        v_gender := CASE lower(v_gender) WHEN 'male' THEN 'Male' WHEN 'female' THEN 'Female'
                                         WHEN 'other' THEN 'Other' ELSE v_gender END;
        IF v_gender IS DISTINCT FROM s.gender AND v_gender NOT IN ('Male', 'Female', 'Other') THEN
            RAISE EXCEPTION 'Gender must be Male, Female or Other.';
        END IF;
    END IF;

    -- Editing one child into another's identity: same rule as admission's
    -- duplicate guard (name whitespace/case-insensitive + DOB + mobile).
    IF (v_name IS DISTINCT FROM s.student_name OR v_dob IS DISTINCT FROM s.dob
        OR v_mobile IS DISTINCT FROM s.mobile)
       AND EXISTS (SELECT 1 FROM core.students o
                    WHERE o.tenant_id = p_tenant_id AND o.school_id = p_school_id
                      AND o.is_active AND o.student_id <> p_student_id
                      AND regexp_replace(LOWER(TRIM(o.student_name)), '\s+', ' ', 'g')
                          = regexp_replace(LOWER(v_name), '\s+', ' ', 'g')
                      AND COALESCE(o.dob, '') = COALESCE(v_dob, '')
                      AND COALESCE(o.mobile, '') = COALESCE(v_mobile, '')) THEN
        RAISE EXCEPTION 'Another student with the same name, date of birth and mobile already exists.';
    END IF;

    -- A roll number belongs to one child per class + section + session: the
    -- attendance register and the ID card sheet are keyed on it.
    IF v_roll IS NOT NULL
       AND (v_roll IS DISTINCT FROM s.roll_no OR v_moved)
       AND EXISTS (SELECT 1 FROM core.students o
                    WHERE o.tenant_id = p_tenant_id AND o.school_id = p_school_id
                      AND o.is_active AND o.student_id <> p_student_id
                      AND o.academic_year = s.academic_year
                      AND o.class_name = v_cls
                      AND COALESCE(o.section, '') = COALESCE(v_sec, '')
                      AND LOWER(TRIM(o.roll_no)) = LOWER(v_roll)) THEN
        RAISE EXCEPTION 'Roll no % is already used in %.', v_roll, v_cls || COALESCE('-' || v_sec, '');
    END IF;

    -- What changed, for the audit row written below (old -> new).
    IF v_name   IS DISTINCT FROM s.student_name THEN v_changes := v_changes || ('Name: ' || COALESCE(s.student_name, '-') || ' -> ' || v_name); END IF;
    IF v_roll   IS DISTINCT FROM s.roll_no      THEN v_changes := v_changes || ('Roll: ' || COALESCE(s.roll_no, '-') || ' -> ' || COALESCE(v_roll, '-')); END IF;
    IF v_gender IS DISTINCT FROM s.gender       THEN v_changes := v_changes || ('Gender: ' || COALESCE(s.gender, '-') || ' -> ' || COALESCE(v_gender, '-')); END IF;
    IF v_dob    IS DISTINCT FROM s.dob          THEN v_changes := v_changes || ('DOB: ' || COALESCE(s.dob, '-') || ' -> ' || COALESCE(v_dob, '-')); END IF;
    IF NULLIF(TRIM(COALESCE(p_guardian_name, '')), '') IS DISTINCT FROM s.guardian_name THEN
        v_changes := v_changes || ('Guardian: ' || COALESCE(s.guardian_name, '-') || ' -> ' || COALESCE(NULLIF(TRIM(p_guardian_name), ''), '-')); END IF;
    IF NULLIF(TRIM(COALESCE(p_mother_name, '')), '') IS DISTINCT FROM s.mother_name THEN
        v_changes := v_changes || ('Mother: ' || COALESCE(s.mother_name, '-') || ' -> ' || COALESCE(NULLIF(TRIM(p_mother_name), ''), '-')); END IF;
    IF v_mobile IS DISTINCT FROM s.mobile       THEN v_changes := v_changes || ('Mobile: ' || COALESCE(s.mobile, '-') || ' -> ' || COALESCE(v_mobile, '-')); END IF;
    IF v_alt    IS DISTINCT FROM s.alt_mobile   THEN v_changes := v_changes || ('Alt mobile: ' || COALESCE(s.alt_mobile, '-') || ' -> ' || COALESCE(v_alt, '-')); END IF;
    IF NULLIF(TRIM(COALESCE(p_address, '')), '') IS DISTINCT FROM s.address THEN v_changes := v_changes || 'Address changed'::text; END IF;
    -- The Aadhaar number itself is not copied into the audit text.
    IF v_idp    IS DISTINCT FROM s.id_proof_no  THEN v_changes := v_changes || 'Aadhaar changed'::text; END IF;
    IF NULLIF(TRIM(COALESCE(p_blood_group, '')), '') IS DISTINCT FROM s.blood_group THEN
        v_changes := v_changes || ('Blood group: ' || COALESCE(s.blood_group, '-') || ' -> ' || COALESCE(NULLIF(TRIM(p_blood_group), ''), '-')); END IF;
    IF NULLIF(TRIM(COALESCE(p_religion, '')), '') IS DISTINCT FROM s.religion
       OR NULLIF(TRIM(COALESCE(p_category, '')), '') IS DISTINCT FROM s.category
       OR NULLIF(TRIM(COALESCE(p_nationality, '')), '') IS DISTINCT FROM s.nationality
       OR NULLIF(TRIM(COALESCE(p_prev_school, '')), '') IS DISTINCT FROM s.prev_school_name THEN
        v_changes := v_changes || 'Religion / category / nationality / previous school changed'::text; END IF;
    IF p_extended THEN
        IF NULLIF(TRIM(COALESCE(p_mother_tongue, '')), '') IS DISTINCT FROM s.mother_tongue
           OR NULLIF(TRIM(COALESCE(p_apaar_id, '')), '') IS DISTINCT FROM s.apaar_id
           OR NULLIF(TRIM(COALESCE(p_udise_student_id, '')), '') IS DISTINCT FROM s.udise_student_id THEN
            v_changes := v_changes || 'Mother tongue / APAAR / UDISE changed'::text; END IF;
        IF NULLIF(TRIM(COALESCE(p_prev_board, '')), '') IS DISTINCT FROM s.prev_board
           OR NULLIF(TRIM(COALESCE(p_prev_class, '')), '') IS DISTINCT FROM s.prev_class
           OR NULLIF(TRIM(COALESCE(p_prev_tc_no, '')), '') IS DISTINCT FROM s.prev_tc_no THEN
            v_changes := v_changes || 'Previous board / class / TC changed'::text; END IF;
        IF NULLIF(TRIM(COALESCE(p_father_occupation, '')), '') IS DISTINCT FROM s.father_occupation
           OR NULLIF(TRIM(COALESCE(p_father_qualification, '')), '') IS DISTINCT FROM s.father_qualification
           OR NULLIF(TRIM(COALESCE(p_father_email, '')), '') IS DISTINCT FROM s.father_email
           OR NULLIF(TRIM(COALESCE(p_mother_occupation, '')), '') IS DISTINCT FROM s.mother_occupation
           OR NULLIF(TRIM(COALESCE(p_mother_qualification, '')), '') IS DISTINCT FROM s.mother_qualification
           OR NULLIF(TRIM(COALESCE(p_mother_email, '')), '') IS DISTINCT FROM s.mother_email
           OR p_annual_income IS DISTINCT FROM s.annual_income THEN
            v_changes := v_changes || 'Parent occupation / qualification / email / income changed'::text; END IF;
    END IF;

    UPDATE core.students
    SET student_name   = v_name,
        roll_no        = v_roll,
        gender         = v_gender,
        dob            = v_dob,
        class_name     = v_cls,
        section        = v_sec,
        guardian_name  = NULLIF(TRIM(COALESCE(p_guardian_name, '')), ''),
        mother_name    = NULLIF(TRIM(COALESCE(p_mother_name, '')), ''),
        mobile         = v_mobile,
        alt_mobile     = v_alt,
        address        = NULLIF(TRIM(COALESCE(p_address, '')), ''),
        blood_group    = NULLIF(TRIM(COALESCE(p_blood_group, '')), ''),
        religion       = NULLIF(TRIM(COALESCE(p_religion, '')), ''),
        category       = NULLIF(TRIM(COALESCE(p_category, '')), ''),
        nationality    = NULLIF(TRIM(COALESCE(p_nationality, '')), ''),
        id_proof_no    = v_idp,
        prev_school_name = NULLIF(TRIM(COALESCE(p_prev_school, '')), ''),
        mother_tongue        = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_mother_tongue, '')), '') ELSE mother_tongue END,
        apaar_id             = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_apaar_id, '')), '') ELSE apaar_id END,
        udise_student_id     = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_udise_student_id, '')), '') ELSE udise_student_id END,
        prev_board           = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_prev_board, '')), '') ELSE prev_board END,
        prev_class           = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_prev_class, '')), '') ELSE prev_class END,
        prev_tc_no           = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_prev_tc_no, '')), '') ELSE prev_tc_no END,
        father_occupation    = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_father_occupation, '')), '') ELSE father_occupation END,
        father_qualification = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_father_qualification, '')), '') ELSE father_qualification END,
        father_email         = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_father_email, '')), '') ELSE father_email END,
        mother_occupation    = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_mother_occupation, '')), '') ELSE mother_occupation END,
        mother_qualification = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_mother_qualification, '')), '') ELSE mother_qualification END,
        mother_email         = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_mother_email, '')), '') ELSE mother_email END,
        annual_income        = CASE WHEN p_extended THEN p_annual_income ELSE annual_income END,
        updated_by     = p_action_user_id,
        updated_at     = NOW()
    WHERE student_id = p_student_id
      AND tenant_id  = p_tenant_id
      AND school_id  = p_school_id;

    IF v_moved OR v_roll IS DISTINCT FROM s.roll_no THEN
        -- The per-session record follows the move and the roll number (see
        -- student_enrolment.sql): Enrolment History and the next promotion read it.
        UPDATE core.student_enrolment
        SET class_name        = v_cls,
            academic_class_id = v_class_id,
            section           = v_sec,
            roll_no           = v_roll,
            updated_by        = p_action_user_id,
            updated_at        = now()
        WHERE student_id = p_student_id AND academic_year = s.academic_year;
    END IF;

    IF array_length(v_changes, 1) > 0 THEN
        INSERT INTO core.admission_audit (tenant_id, school_id, student_id, action, detail, action_by)
        VALUES (p_tenant_id, p_school_id, p_student_id, 'StudentEdited',
                array_to_string(v_changes, '; '), p_action_user_id);
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
$procedure$

;
