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
-- Validation (2026-10-10): the edit path now refuses what admission refuses
-- -- a DOB in the future or after the admission date, a mobile that is not 10
-- digits, an Aadhaar that is not 12 digits, an unknown gender -- plus a second
-- active student with the same name + DOB + mobile and a roll number already
-- held in the same class + section + session. Each rule only fires when that
-- value is CHANGED, so an old row that predates a rule can still be edited.
-- Every changed field is written to admission_audit (old -> new, who, when).
--
-- Also here: core.sp_class_setup_sections, the sections a class HAS in a
-- session's setup (Edit Student and Promotion section dropdowns). The older
-- sp_class_active_sections lists only sections that already hold students, so
-- an empty section could never be picked; attendance still uses that one.
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
$procedure$;


-- ── Sections a class HAS in a session's setup ───────────────────────────────
-- NULL session = the current one. Read from academic_class_sections, not from
-- students, so an empty section (a new 5-C) can be picked.
CREATE OR REPLACE PROCEDURE core.sp_class_setup_sections(
    IN    p_tenant_id     integer,
    IN    p_school_id     integer,
    IN    p_class         varchar,
    IN    p_academic_year varchar DEFAULT NULL,
    INOUT p_result        refcursor DEFAULT 'class_setup_sections_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        OPEN p_result FOR SELECT WHERE FALSE;
        RETURN;
    END IF;

    OPEN p_result FOR
    SELECT DISTINCT TRIM(cs.section_name) AS section, MIN(cs.display_order) AS display_order
    FROM academic.academic_class_sections cs
    JOIN academic.academic_classes ac ON ac.academic_class_id = cs.academic_class_id
    JOIN academic.academic_years   ay ON ay.academic_year_id  = ac.academic_year_id
    WHERE ac.tenant_id = p_tenant_id AND ac.school_id = p_school_id
      AND LOWER(ac.class_name) = LOWER(TRIM(COALESCE(p_class, '')))
      AND COALESCE(ac.is_deleted, FALSE) = FALSE
      AND COALESCE(cs.is_deleted, FALSE) = FALSE
      AND COALESCE(ay.is_deleted, FALSE) = FALSE
      AND (   (NULLIF(TRIM(COALESCE(p_academic_year, '')), '') IS NULL AND COALESCE(ay.is_current, FALSE))
           OR ay.academic_year_name = TRIM(p_academic_year))
    GROUP BY TRIM(cs.section_name)
    ORDER BY 2, 1;
END;
$procedure$;
