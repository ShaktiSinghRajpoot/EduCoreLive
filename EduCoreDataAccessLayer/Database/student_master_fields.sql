-- ============================================================
--  Student master expansion — real-ERP admission record
--  Adds identity/demographics, previous school, full parent
--  details, and a documents checklist to core.students, and
--  extends core.sp_admission_manage (SaveAdmission) to persist
--  them. Parameters bind by name (Npgsql StoredProcedure), so
--  the new params are additive and safe for existing callers.
--
--  Depends on student_money_lifecycle.sql (fn_fee_plan_problem,
--  fn_student_bill_plan) -- apply that first.
-- ============================================================

-- ── 1. New columns (idempotent) ─────────────────────────────
ALTER TABLE core.students
    ADD COLUMN IF NOT EXISTS blood_group          varchar(5),
    ADD COLUMN IF NOT EXISTS religion             varchar(40),
    ADD COLUMN IF NOT EXISTS category             varchar(20),   -- General/OBC/SC/ST/EWS
    ADD COLUMN IF NOT EXISTS nationality          varchar(40),
    ADD COLUMN IF NOT EXISTS mother_tongue        varchar(40),
    ADD COLUMN IF NOT EXISTS id_proof_no          varchar(30),   -- Aadhaar / birth-cert no
    ADD COLUMN IF NOT EXISTS prev_school_name     varchar(150),
    ADD COLUMN IF NOT EXISTS prev_board           varchar(40),
    ADD COLUMN IF NOT EXISTS prev_class           varchar(40),
    ADD COLUMN IF NOT EXISTS prev_tc_no           varchar(50),
    ADD COLUMN IF NOT EXISTS father_occupation    varchar(80),
    ADD COLUMN IF NOT EXISTS father_qualification varchar(80),
    ADD COLUMN IF NOT EXISTS father_email         varchar(120),
    ADD COLUMN IF NOT EXISTS mother_occupation    varchar(80),
    ADD COLUMN IF NOT EXISTS mother_qualification varchar(80),
    ADD COLUMN IF NOT EXISTS mother_email         varchar(120),
    ADD COLUMN IF NOT EXISTS annual_income        numeric(12,2),
    ADD COLUMN IF NOT EXISTS documents            jsonb;         -- [{name,status}]

-- ── 2. Replace the admission proc with the extended signature ──
--  Widening the parameter list is a NEW signature, so CREATE OR REPLACE alone
--  would leave the OLD overload behind and calls fail with "procedure is not
--  unique". A hard-coded DROP-by-signature goes stale every time a param is
--  added (that is exactly what bit us), so instead drop ANY overload that
--  predates the current parameter set — identified by the absence of
--  p_apaar_id. After the CREATE below there is always exactly one.
DO $$
DECLARE r record;
BEGIN
    FOR r IN
        SELECT oid FROM pg_proc
        WHERE proname = 'sp_admission_manage'
          AND pg_get_function_identity_arguments(oid) NOT ILIKE '%p_apaar_id%'
    LOOP
        EXECUTE 'DROP PROCEDURE ' || r.oid::regprocedure;
    END LOOP;
END $$;

CREATE OR REPLACE PROCEDURE core.sp_admission_manage(
    IN p_operation text,
    IN p_tenant_id integer,
    IN p_school_id integer,
    IN p_action_user_id integer,
    IN p_student_id integer DEFAULT NULL::integer,
    IN p_admission_no text DEFAULT NULL::text,
    IN p_roll_no text DEFAULT NULL::text,
    IN p_student_name text DEFAULT NULL::text,
    IN p_gender text DEFAULT NULL::text,
    IN p_dob date DEFAULT NULL::date,
    IN p_class_name text DEFAULT NULL::text,
    IN p_section text DEFAULT NULL::text,
    IN p_academic_year text DEFAULT NULL::text,
    IN p_admission_date date DEFAULT NULL::date,
    IN p_guardian_name text DEFAULT NULL::text,
    IN p_mother_name text DEFAULT NULL::text,
    IN p_mobile text DEFAULT NULL::text,
    IN p_alt_mobile text DEFAULT NULL::text,
    IN p_address text DEFAULT NULL::text,
    -- ── new student-master fields ──
    IN p_blood_group text DEFAULT NULL::text,
    IN p_religion text DEFAULT NULL::text,
    IN p_category text DEFAULT NULL::text,
    IN p_nationality text DEFAULT NULL::text,
    IN p_mother_tongue text DEFAULT NULL::text,
    IN p_id_proof_no text DEFAULT NULL::text,
    IN p_apaar_id text DEFAULT NULL::text,
    IN p_udise_student_id text DEFAULT NULL::text,
    IN p_prev_school_name text DEFAULT NULL::text,
    IN p_prev_board text DEFAULT NULL::text,
    IN p_prev_class text DEFAULT NULL::text,
    IN p_prev_tc_no text DEFAULT NULL::text,
    IN p_father_occupation text DEFAULT NULL::text,
    IN p_father_qualification text DEFAULT NULL::text,
    IN p_father_email text DEFAULT NULL::text,
    IN p_mother_occupation text DEFAULT NULL::text,
    IN p_mother_qualification text DEFAULT NULL::text,
    IN p_mother_email text DEFAULT NULL::text,
    IN p_annual_income numeric DEFAULT NULL::numeric,
    IN p_documents jsonb DEFAULT NULL::jsonb,
    -- ── fee snapshot / concession ──
    IN p_pay_today_total numeric DEFAULT 0,
    IN p_monthly_total numeric DEFAULT 0,
    IN p_yearly_total numeric DEFAULT 0,
    IN p_annual_total numeric DEFAULT 0,
    IN p_concession_type text DEFAULT NULL::text,
    IN p_concession_value numeric DEFAULT 0,
    IN p_concession_amount numeric DEFAULT 0,
    IN p_concession_reason text DEFAULT NULL::text,
    IN p_concession_cap numeric DEFAULT 100000,
    IN p_fee_plan_json jsonb DEFAULT NULL::jsonb,
    IN p_enquiry_id integer DEFAULT NULL::integer,
    -- ── list/filter ──
    IN p_page_number integer DEFAULT 1,
    IN p_page_size integer DEFAULT 10,
    IN p_search text DEFAULT NULL::text,
    IN p_filter_class text DEFAULT NULL::text,
    IN p_filter_section text DEFAULT NULL::text,
    IN p_filter_gender text DEFAULT NULL::text,
    IN p_filter_year text DEFAULT NULL::text,
    IN p_filter_status text DEFAULT NULL::text,
    INOUT p_result refcursor DEFAULT 'admission_cursor'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_student_id    INTEGER;
    v_admission_no  TEXT;
    v_seq           INTEGER;
    v_year          VARCHAR(20);
    v_adm_date      DATE;
    v_approval      VARCHAR(20);
    v_dup           INTEGER;
    v_item          JSONB;
    v_month_start   DATE;
    v_month_end     DATE;
    v_m             DATE;
    v_i             INTEGER;
    v_sess_start    DATE;
    v_sess_end      DATE;
    v_charge_from   VARCHAR(20);
    v_freq          VARCHAR(30);
    v_step          INTEGER;
    v_period_end    DATE;
    v_sess_month    DATE;
    v_cycles        INTEGER;
    v_reg_balance   NUMERIC;
    v_reg_agreed    NUMERIC;
    v_roll          TEXT;
    v_dup_adm       TEXT;
BEGIN

    -- ── SaveAdmission ────────────────────────────────────────
    IF p_operation = 'SaveAdmission' THEN

        IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
            OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                'Invalid tenant/school context.' AS message, NULL::TEXT AS admission_no;
            RETURN;
        END IF;

        v_year     := COALESCE(p_academic_year, '');
        v_adm_date := COALESCE(p_admission_date, CURRENT_DATE);

        -- ── What a student record must have to be a student ──────────────────
        -- The screen asks for these and the controller re-checks them, but the
        -- proc is the last thing between a request and a real child's record, and
        -- it used to accept anything. Each refusal below was reproduced first: a
        -- student with a blank name, one sitting in a class that does not exist,
        -- one admitted in 2027, and one born after the day they joined.
        IF COALESCE(TRIM(p_student_name), '') = '' THEN
            OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                'Student name is required.' AS message, NULL::TEXT AS admission_no;
            RETURN;
        END IF;

        -- A student in a class that does not exist is an orphan: no class list
        -- shows them, no fee structure matches, and promotion cannot move them.
        IF COALESCE(TRIM(p_class_name), '') = '' OR NOT EXISTS (
               SELECT 1 FROM academic.academic_classes ac
               JOIN academic.academic_years ay
                 ON ay.academic_year_id = ac.academic_year_id
               WHERE ac.tenant_id = p_tenant_id AND ac.school_id = p_school_id
                 AND ac.class_name = TRIM(p_class_name)
                 AND ay.academic_year_name = v_year
                 AND COALESCE(ac.is_deleted, FALSE) = FALSE) THEN
            OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                format('%s is not a class in %s.', COALESCE(NULLIF(TRIM(p_class_name),''),'(blank)'), v_year) AS message,
                NULL::TEXT AS admission_no;
            RETURN;
        END IF;

        -- Nobody is admitted for a day that has not happened. A future date also
        -- lands the first instalment outside the session it belongs to.
        IF v_adm_date > CURRENT_DATE THEN
            OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                'Admission date cannot be in the future.' AS message, NULL::TEXT AS admission_no;
            RETURN;
        END IF;

        IF p_dob IS NOT NULL AND p_dob > CURRENT_DATE THEN
            OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                'Date of birth cannot be in the future.' AS message, NULL::TEXT AS admission_no;
            RETURN;
        END IF;

        IF p_dob IS NOT NULL AND p_dob > v_adm_date THEN
            OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                'Date of birth cannot be after the admission date.' AS message,
                NULL::TEXT AS admission_no;
            RETURN;
        END IF;

        -- Session window AND its billing policy, from the one row that owns both.
        -- The window drives session-end-aware billing (a mid-session joiner is
        -- billed only up to the session's end month). "Charge recurring fees
        -- from" is AdmissionMonth (default, real-world norm — pay only enrolled
        -- months) or SessionStart (the full session from April). It lives on the
        -- year, not the school, so a session cannot be re-billed by a setting
        -- someone changed months later — see fee_charge_from_per_year.sql.
        SELECT start_date, end_date,
               COALESCE(NULLIF(TRIM(charge_fees_from), ''), 'AdmissionMonth')
          INTO v_sess_start, v_sess_end, v_charge_from
        FROM academic.academic_years
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND academic_year_name = v_year
          AND COALESCE(is_deleted, FALSE) = FALSE
        LIMIT 1;

        -- No matching year row (a back-dated or free-typed session name).
        v_charge_from := COALESCE(v_charge_from, 'AdmissionMonth');

        -- The fee plan arrives from the admission form. A negative amount or the
        -- same head twice is refused before anything is written.
        IF core.fn_fee_plan_problem(p_fee_plan_json) IS NOT NULL THEN
            OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                core.fn_fee_plan_problem(p_fee_plan_json) AS message, NULL::TEXT AS admission_no;
            RETURN;
        END IF;

        -- An enquiry becomes ONE student. The row is locked so two clerks
        -- converting the same enquiry at once cannot both get through.
        IF p_enquiry_id IS NOT NULL AND p_enquiry_id > 0 THEN
            PERFORM 1 FROM core.enquiries
             WHERE enquiry_id = p_enquiry_id
               AND tenant_id = p_tenant_id AND school_id = p_school_id
               FOR UPDATE;
            IF EXISTS (SELECT 1 FROM core.enquiries e
                        JOIN core.students s ON s.student_id = e.admission_id
                       WHERE e.enquiry_id = p_enquiry_id
                         AND e.tenant_id = p_tenant_id AND e.school_id = p_school_id) THEN
                OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                    'This enquiry has already been admitted.' AS message, NULL::TEXT AS admission_no;
                RETURN;
            END IF;
        END IF;

        -- Two identical submits arriving together both passed the COUNT below
        -- before either inserted. A transaction-scoped advisory lock on the
        -- same name + dob + mobile makes the second one wait for the first and
        -- then see its row. Released automatically at commit / rollback.
        PERFORM pg_advisory_xact_lock(hashtext(
            'admission:' || p_tenant_id || ':' || p_school_id || ':' ||
            regexp_replace(LOWER(TRIM(COALESCE(p_student_name, ''))), '\s+', ' ', 'g') || ':' ||
            COALESCE(p_dob::text, '') || ':' || COALESCE(p_mobile, '')));

        -- Duplicate guard: same name + dob + mobile already admitted. Name is
        -- whitespace-collapsed + lower-cased so trivial typos ("Rahul  Kumar" vs
        -- "Rahul Kumar", different casing) no longer slip a duplicate through.
        SELECT COUNT(*) INTO v_dup
        FROM core.students
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND is_active = TRUE
          AND regexp_replace(LOWER(TRIM(student_name)), '\s+', ' ', 'g')
              = regexp_replace(LOWER(TRIM(COALESCE(p_student_name, ''))), '\s+', ' ', 'g')
          AND COALESCE(dob::date, DATE '1900-01-01') = COALESCE(p_dob, DATE '1900-01-01')
          AND COALESCE(mobile, '') = COALESCE(p_mobile, '');
        IF v_dup > 0 THEN
            OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                'A student with the same name, DOB and mobile already exists.' AS message,
                NULL::TEXT AS admission_no;
            RETURN;
        END IF;

        -- The same child who LEFT earlier in this session comes back: re-admit the
        -- old record (Students > Left Students > Re-admit) so their history, dues
        -- and admission number stay one record, instead of making a second student.
        SELECT admission_no INTO v_dup_adm
        FROM core.students
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND is_active = FALSE
          AND academic_year = v_year
          AND regexp_replace(LOWER(TRIM(student_name)), '\s+', ' ', 'g')
              = regexp_replace(LOWER(TRIM(COALESCE(p_student_name, ''))), '\s+', ' ', 'g')
          AND COALESCE(dob::date, DATE '1900-01-01') = COALESCE(p_dob, DATE '1900-01-01')
          AND COALESCE(mobile, '') = COALESCE(p_mobile, '')
        LIMIT 1;
        IF v_dup_adm IS NOT NULL THEN
            OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                'This child left earlier this session (' || v_dup_adm || '). Re-admit them from Students > Left Students instead of a new admission.' AS message,
                NULL::TEXT AS admission_no;
            RETURN;
        END IF;

        -- Aadhaar: 12 digits when filled (the same rule as Edit Student).
        IF NULLIF(TRIM(COALESCE(p_id_proof_no, '')), '') IS NOT NULL
           AND TRIM(p_id_proof_no) !~ '^[0-9]{12}$' THEN
            OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                'Aadhaar number must be 12 digits.' AS message, NULL::TEXT AS admission_no;
            RETURN;
        END IF;

        -- A roll number belongs to one child per class + section + session.
        IF NULLIF(TRIM(COALESCE(p_roll_no, '')), '') IS NOT NULL AND EXISTS (
               SELECT 1 FROM core.students o
                WHERE o.tenant_id = p_tenant_id AND o.school_id = p_school_id AND o.is_active
                  AND o.academic_year = v_year AND o.class_name = TRIM(p_class_name)
                  AND COALESCE(o.section, '') = COALESCE(TRIM(p_section), '')
                  AND LOWER(TRIM(o.roll_no)) = LOWER(TRIM(p_roll_no))) THEN
            OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                format('Roll no %s is already used in %s.', TRIM(p_roll_no),
                       TRIM(p_class_name) || COALESCE('-' || NULLIF(TRIM(p_section), ''), '')) AS message,
                NULL::TEXT AS admission_no;
            RETURN;
        END IF;

        -- No roll number typed: give the next one in the class + section
        -- (highest numeric roll + 1), so a new child is never "-" on the register,
        -- admit card or result sheet (QA BUG-074). It can be changed in Edit Student.
        v_roll := NULLIF(TRIM(COALESCE(p_roll_no, '')), '');
        IF v_roll IS NULL AND NULLIF(TRIM(COALESCE(p_section, '')), '') IS NOT NULL THEN
            SELECT (COALESCE(MAX(TRIM(o.roll_no)::int), 0) + 1)::text INTO v_roll
              FROM core.students o
             WHERE o.tenant_id = p_tenant_id AND o.school_id = p_school_id AND o.is_active
               AND o.academic_year = v_year AND o.class_name = TRIM(p_class_name)
               AND COALESCE(o.section, '') = TRIM(p_section)
               AND TRIM(o.roll_no) ~ '^[0-9]{1,6}$';
        END IF;

        -- Admission number: use supplied value or auto-generate per school+year
        IF p_admission_no IS NULL OR TRIM(p_admission_no) = '' THEN
            INSERT INTO core.admission_counters (tenant_id, school_id, academic_year, last_seq)
            VALUES (p_tenant_id, p_school_id, v_year, 1)
            ON CONFLICT (tenant_id, school_id, academic_year)
            DO UPDATE SET last_seq = core.admission_counters.last_seq + 1
            RETURNING last_seq INTO v_seq;

            -- LEFT(v_year, 4) took the first four characters of the session's
            -- NAME, so "FY 26-27" produced ADM-FY 2-0002. core.fn_receipt_year
            -- was written for exactly this when receipt numbers hit it; the
            -- admission number was left on the old expression. It reads the
            -- session's real start date, falls back to any four-digit year in the
            -- name, then to the admission date.
            v_admission_no := 'ADM-' ||
                core.fn_receipt_year(p_tenant_id, p_school_id, v_year, v_adm_date) ||
                '-' || LPAD(v_seq::TEXT, 4, '0');
        ELSE
            -- Normalise a typed number before it becomes this child's identity.
            -- TRIM alone was not enough: 'ADM-2026-0099' and 'adm-2026-0099'
            -- passed the collision check as different strings, so two students
            -- ended up holding the same admission number. Upper-case it and
            -- collapse any inner run of spaces, then compare the same way.
            v_admission_no := UPPER(REGEXP_REPLACE(TRIM(p_admission_no), '\s+', ' ', 'g'));

            -- Reject collision with an existing admission number. Compared on
            -- the normalised form so an old row typed in another case still
            -- counts as taken.
            IF EXISTS (SELECT 1 FROM core.students
                       WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                         AND UPPER(REGEXP_REPLACE(TRIM(admission_no), '\s+', ' ', 'g'))
                             = v_admission_no) THEN
                OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                    'Admission number already in use.' AS message,
                    v_admission_no AS admission_no;
                RETURN;
            END IF;
        END IF;

        -- Concession approval gate
        v_approval := CASE WHEN COALESCE(p_concession_amount, 0) > COALESCE(p_concession_cap, 100000)
                           THEN 'Pending Approval' ELSE 'Approved' END;

        INSERT INTO core.students (
            tenant_id, school_id,
            admission_no, roll_no, student_name, gender, dob,
            class_name, section, academic_year, admission_date,
            guardian_name, mother_name, mobile, alt_mobile, address,
            blood_group, religion, category, nationality, mother_tongue, id_proof_no,
            apaar_id, udise_student_id,
            prev_school_name, prev_board, prev_class, prev_tc_no,
            father_occupation, father_qualification, father_email,
            mother_occupation, mother_qualification, mother_email,
            annual_income, documents,
            pay_today_total, monthly_total, yearly_total, annual_total,
            concession_type, concession_value, concession_amount, concession_reason,
            enquiry_id, status, approval_status,
            created_by, updated_by
        ) VALUES (
            p_tenant_id, p_school_id,
            v_admission_no, v_roll, p_student_name, p_gender, p_dob,
            p_class_name, p_section, v_year, v_adm_date,
            p_guardian_name, p_mother_name, p_mobile, p_alt_mobile, p_address,
            p_blood_group, p_religion, p_category, p_nationality, p_mother_tongue, p_id_proof_no,
            p_apaar_id, p_udise_student_id,
            p_prev_school_name, p_prev_board, p_prev_class, p_prev_tc_no,
            p_father_occupation, p_father_qualification, p_father_email,
            p_mother_occupation, p_mother_qualification, p_mother_email,
            p_annual_income, p_documents,
            COALESCE(p_pay_today_total, 0), COALESCE(p_monthly_total, 0),
            COALESCE(p_yearly_total, 0), COALESCE(p_annual_total, 0),
            p_concession_type, COALESCE(p_concession_value, 0),
            COALESCE(p_concession_amount, 0), p_concession_reason,
            p_enquiry_id, 'Active', v_approval,
            p_action_user_id, p_action_user_id
        )
        RETURNING student_id INTO v_student_id;

        -- Open the student's first enrolment row (see student_enrolment.sql).
        -- core.students still carries class/section/year; this is the parallel
        -- per-session record that keeps the history once they are promoted.
        PERFORM core.fn_student_enrolment_open(
            p_tenant_id, p_school_id, v_student_id,
            v_year, p_class_name, p_section, v_roll, p_action_user_id);

        -- Freeze the fee plan + generate ledger rows. The month arithmetic
        -- (charge-from policy, quarter snapping, session end) moved to
        -- core.fn_plan_periods / core.fn_student_bill_plan in
        -- student_money_lifecycle.sql, so promotion and a class change bill a
        -- plan exactly the way admission does. The plan was validated above.
        PERFORM core.fn_student_bill_plan(
            p_tenant_id, p_school_id, p_action_user_id, v_student_id,
            v_year, v_adm_date, p_fee_plan_json);

        -- Carry an unpaid registration balance onto the student as a real due.
        -- A family can pay part of the registration fee (registration_fee_partial.sql)
        -- and the remainder is derived from the receipts against their enquiry. That
        -- works until the enquiry becomes a student: every screen that chases money
        -- reads core.student_ledger, which is keyed on student_id, so from that moment
        -- the balance would sit on a record nobody opens again and never be collected.
        -- It becomes an ordinary due here -- visible at the fee counter, in the due
        -- list, on reminders and in the reports -- in the same transaction as the
        -- admission, because a balance that can be lost between two calls is a bug
        -- this codebase has been bitten by before.
        --
        -- The agreed fee is frozen on the enquiry only by the FIRST receipt
        -- (sp_registration_fee_record). A family registered without paying anything
        -- therefore had 0 agreed, 0 - 0 = 0 was carried, and the whole fee vanished
        -- at admission (QA BUG-046). When nothing was agreed, a registered enquiry
        -- falls back to the fee the registration screen asks for -- the class-wise
        -- Registration-point amount from the Fee Structure, else the active
        -- Registration heads' default amounts (SchoolSettingsService.
        -- GetCollectionPointResolvedTotalAsync) -- but only while the school has
        -- the registration fee switched on. That amount is frozen on the enquiry so
        -- its "Fee Pending" badge clears once the carried due is paid.
        --
        -- Nothing sums an enquiry's balance into a student's dues, so this is not
        -- double counting.
        IF p_enquiry_id IS NOT NULL AND p_enquiry_id > 0 THEN
            SELECT COALESCE(e.registration_fee_amount, 0)
              INTO v_reg_agreed
            FROM core.enquiries e
            WHERE e.enquiry_id = p_enquiry_id
              AND e.tenant_id = p_tenant_id AND e.school_id = p_school_id;

            IF COALESCE(v_reg_agreed, 0) <= 0 THEN
                SELECT COALESCE(
                         (SELECT NULLIF(SUM(d.amount), 0)
                            FROM core.school_fee_structures s
                            JOIN core.school_fee_structure_details d ON d.fee_structure_id = s.fee_structure_id
                            JOIN core.school_fee_heads h             ON h.fee_head_id = d.fee_head_id
                           WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id
                             AND s.class_name = e.class_name AND s.academic_year = e.session
                             AND COALESCE(s.is_deleted, FALSE) = FALSE
                             AND COALESCE(d.is_deleted, FALSE) = FALSE
                             AND COALESCE(d.is_selected, FALSE)
                             AND h.collection_point = 'Registration'),
                         (SELECT SUM(h.default_amount)
                            FROM core.school_fee_heads h
                           WHERE h.tenant_id = p_tenant_id AND h.school_id = p_school_id
                             AND COALESCE(h.is_active, TRUE)
                             AND COALESCE(h.is_deleted, FALSE) = FALSE
                             AND h.collection_point = 'Registration'),
                         0)
                  INTO v_reg_agreed
                FROM core.enquiries e
                WHERE e.enquiry_id = p_enquiry_id
                  AND e.tenant_id = p_tenant_id AND e.school_id = p_school_id
                  AND COALESCE(TRIM(e.registration_number), '') <> ''
                  AND EXISTS (SELECT 1 FROM core.school_admission_workflow_settings w
                               WHERE w.tenant_id = p_tenant_id AND w.school_id = p_school_id
                                 AND COALESCE(w.is_deleted, FALSE) = FALSE
                                 AND COALESCE(w.enable_registration, FALSE)
                                 AND COALESCE(w.enable_registration_fee, FALSE));

                IF COALESCE(v_reg_agreed, 0) > 0 THEN
                    UPDATE core.enquiries
                       SET registration_fee_amount = ROUND(v_reg_agreed, 2)
                     WHERE enquiry_id = p_enquiry_id
                       AND tenant_id = p_tenant_id AND school_id = p_school_id
                       AND COALESCE(registration_fee_amount, 0) = 0;
                END IF;
            END IF;

            v_reg_balance := COALESCE(v_reg_agreed, 0)
                             - core.fn_registration_fee_settled(p_tenant_id, p_school_id, p_enquiry_id);

            IF COALESCE(v_reg_balance, 0) > 0.005 THEN
                INSERT INTO core.student_ledger (
                    tenant_id, school_id, student_id,
                    fee_head_name, frequency, installment_label,
                    due_date, amount_due, status, academic_year
                ) VALUES (
                    p_tenant_id, p_school_id, v_student_id,
                    core.fn_registration_fee_head_name(p_tenant_id, p_school_id),
                    'One Time', 'Registration',
                    v_adm_date, ROUND(v_reg_balance, 2), 'Pending', v_year
                );

                INSERT INTO core.admission_audit (tenant_id, school_id, student_id, action, detail, action_by)
                VALUES (p_tenant_id, p_school_id, v_student_id, 'RegistrationBalanceCarried',
                        'Unpaid registration balance ' || ROUND(v_reg_balance, 2)::TEXT ||
                        ' carried from enquiry ' || p_enquiry_id::TEXT, p_action_user_id);
            END IF;
        END IF;

        -- Audit
        INSERT INTO core.admission_audit (tenant_id, school_id, student_id, action, detail, action_by)
        VALUES (p_tenant_id, p_school_id, v_student_id, 'AdmissionCreated',
                'Admission ' || v_admission_no || ' created for ' || COALESCE(p_student_name,''),
                p_action_user_id);

        IF COALESCE(p_concession_amount, 0) > 0 THEN
            INSERT INTO core.admission_audit (tenant_id, school_id, student_id, action, detail, action_by)
            VALUES (p_tenant_id, p_school_id, v_student_id, 'ConcessionApplied',
                    'Concession ' || p_concession_amount::TEXT || ' (' ||
                    COALESCE(p_concession_reason, 'no reason') || ') status=' || v_approval,
                    p_action_user_id);
        END IF;

        -- Close the loop: link + confirm enquiry
        IF p_enquiry_id IS NOT NULL AND p_enquiry_id > 0 THEN
            UPDATE core.enquiries
            SET admission_id = v_student_id,
                status       = 'Admission Confirmed',
                updated_by   = p_action_user_id,
                updated_at   = NOW()
            WHERE enquiry_id = p_enquiry_id
              AND tenant_id  = p_tenant_id
              AND school_id  = p_school_id
              AND is_active  = TRUE;

            INSERT INTO core.enquiry_status_history (
                enquiry_id, tenant_id, school_id,
                status_from, status_to, change_note, changed_by
            )
            SELECT p_enquiry_id, p_tenant_id, p_school_id,
                   NULL, 'Admission Confirmed',
                   'Converted to admission ' || v_admission_no, p_action_user_id
            WHERE EXISTS (SELECT 1 FROM core.enquiries
                          WHERE enquiry_id = p_enquiry_id
                            AND tenant_id = p_tenant_id AND school_id = p_school_id);

            INSERT INTO core.admission_audit (tenant_id, school_id, student_id, action, detail, action_by)
            VALUES (p_tenant_id, p_school_id, v_student_id, 'ConvertedFromEnquiry',
                    'Linked from enquiry #' || p_enquiry_id::TEXT, p_action_user_id);

            -- Money the family already paid follows them onto the student record.
            -- A registration fee is taken before any student exists, so its
            -- receipt is booked against the enquiry with student_id NULL. Nothing
            -- pointed it at the student afterwards, and the fee history reads
            -- student_id only — so the amount they had paid was invisible on the
            -- child's record and could only be found by going back to the enquiry.
            --
            -- enquiry_id is deliberately left in place: the receipt really was
            -- taken against the enquiry, and that is where it came from. This adds
            -- the second half of a link that only ever existed one way, since the
            -- student row already carries the enquiry it came from.
            UPDATE core.fee_payments
               SET student_id = v_student_id
             WHERE tenant_id  = p_tenant_id
               AND school_id  = p_school_id
               AND enquiry_id = p_enquiry_id
               AND student_id IS NULL;
        END IF;

        OPEN p_result FOR
            SELECT v_student_id AS student_id, 1 AS success,
                   'Admission saved.' AS message, v_admission_no AS admission_no;
        RETURN;

    -- ── GetStudents (filtered + paginated) ───────────────────
    ELSIF p_operation = 'GetStudents' THEN
        OPEN p_result FOR
            WITH filtered AS (
                SELECT
                    s.student_id, s.admission_no, s.roll_no, s.student_name,
                    s.gender, s.dob,
                    -- When a session is asked for, report the class/section the
                    -- student held IN THAT SESSION, not their present one.
                    COALESCE(e.class_name,    s.class_name)    AS class_name,
                    COALESCE(e.section,       s.section)       AS section,
                    COALESCE(e.academic_year, s.academic_year) AS academic_year,
                    s.admission_date, s.guardian_name, s.mobile,
                    s.annual_total, s.status, s.approval_status, s.enquiry_id,
                    -- Concession settles a due as surely as cash does. Leaving
                    -- it out showed a fully settled student as owing / Partial.
                    COALESCE((
                        SELECT CASE
                            WHEN SUM(l.amount_due - l.amount_paid - l.concession) <= 0 THEN 'Paid'
                            WHEN SUM(l.amount_paid + l.concession) = 0 THEN 'Pending'
                            ELSE 'Partial' END
                        FROM core.student_ledger l
                        WHERE l.student_id = s.student_id
                    ), 'Pending') AS fee_status,
                    COALESCE((
                        SELECT SUM(l.amount_due - l.amount_paid - l.concession)
                        FROM core.student_ledger l
                        WHERE l.student_id = s.student_id
                    ), 0) AS fee_due
                FROM core.students s
                -- Per-session position (core.student_enrolment). students.academic_year
                -- only holds where a student is NOW, so filtering on it loses everyone
                -- who has since been promoted. Matches only when a session is asked
                -- for; otherwise e.* is NULL and the COALESCEs fall back to students.
                LEFT JOIN core.student_enrolment e
                       ON e.student_id    = s.student_id
                      AND e.academic_year = NULLIF(TRIM(COALESCE(p_filter_year, '')), '')
                WHERE s.tenant_id = p_tenant_id
                  AND s.school_id = p_school_id
                  AND s.is_active = TRUE
                  -- strpos, not LIKE: a typed % or _ is a character, not a
                  -- wildcard; inner runs of spaces are collapsed on both sides.
                  AND (
                      p_search IS NULL OR TRIM(p_search) = ''
                      OR strpos(regexp_replace(LOWER(s.student_name), '\s+', ' ', 'g'),
                                regexp_replace(LOWER(TRIM(p_search)), '\s+', ' ', 'g')) > 0
                      OR strpos(LOWER(s.admission_no), LOWER(TRIM(p_search))) > 0
                      OR strpos(regexp_replace(LOWER(COALESCE(s.guardian_name,'')), '\s+', ' ', 'g'),
                                regexp_replace(LOWER(TRIM(p_search)), '\s+', ' ', 'g')) > 0
                      OR strpos(COALESCE(s.mobile,''), TRIM(p_search)) > 0
                  )
                  -- Enrolled in the requested session at all.
                  AND (NULLIF(TRIM(COALESCE(p_filter_year, '')), '') IS NULL
                       OR e.enrolment_id IS NOT NULL)
                  -- "Active" in a given session means the session's own
                  -- enrolment is still open: a child already promoted, retained
                  -- into the next session or passed out has left that roster
                  -- (the Promotion page reloaded the moved children otherwise).
                  AND (NULLIF(TRIM(COALESCE(p_filter_year, '')), '') IS NULL
                       OR LOWER(COALESCE(TRIM(p_filter_status), '')) <> 'active'
                       OR e.status = 'Active')
                  -- Class/section are matched against that session's position.
                  AND (p_filter_class   IS NULL OR TRIM(p_filter_class)   = '' OR LOWER(COALESCE(e.class_name, s.class_name)) = LOWER(TRIM(p_filter_class)))
                  AND (p_filter_section IS NULL OR TRIM(p_filter_section) = '' OR LOWER(COALESCE(e.section, s.section, '')) = LOWER(TRIM(p_filter_section)))
                  AND (p_filter_gender  IS NULL OR TRIM(p_filter_gender)  = '' OR LOWER(COALESCE(s.gender,''))  = LOWER(TRIM(p_filter_gender)))
                  AND (p_filter_status  IS NULL OR TRIM(p_filter_status)  = '' OR LOWER(s.status) = LOWER(TRIM(p_filter_status)))
            )
            SELECT *, COUNT(*) OVER() AS total_count
            FROM filtered
            ORDER BY admission_date DESC, student_id DESC
            LIMIT  COALESCE(p_page_size,   10)
            OFFSET (COALESCE(p_page_number, 1) - 1) * COALESCE(p_page_size, 10);
        RETURN;

    -- ── GetStudentById ───────────────────────────────────────
    ELSIF p_operation = 'GetStudentById' THEN
        OPEN p_result FOR
            -- Leavers included: the Student Dashboard shows a left student
            -- read-only (fees, receipts, history). Edit Student refuses them
            -- in the controller by reading is_active.
            SELECT s.*
            FROM core.students s
            WHERE s.student_id = p_student_id
              AND s.tenant_id  = p_tenant_id
              AND s.school_id  = p_school_id;
        RETURN;

    -- ── DeleteStudent (soft) ─────────────────────────────────
    ELSIF p_operation = 'DeleteStudent' THEN
        UPDATE core.students
        SET is_active = FALSE, updated_by = p_action_user_id, updated_at = NOW()
        WHERE student_id = p_student_id
          AND tenant_id  = p_tenant_id
          AND school_id  = p_school_id;
        OPEN p_result FOR SELECT 1 AS success;
        RETURN;

    END IF;

    -- Fallback
    OPEN p_result FOR SELECT 0 AS student_id WHERE FALSE;

END;
$procedure$;

-- ============================================================================
-- The admission number the next save WOULD generate.
--
-- Read-only: it does not touch core.admission_counters. The admission form shows
-- it as a placeholder so the office knows what is coming, but it is a preview
-- and not a reservation — two clerks with the form open see the same number and
-- whoever saves first takes it. The number is only allocated inside
-- sp_admission_manage, under the counter's own ON CONFLICT.
--
-- Kept beside that generator deliberately: the two must agree on the format, and
-- they will not if they live apart. Both use core.fn_receipt_year, which reads
-- the session's real start year rather than the first four characters of its
-- name (that produced ADM-FY 2-0001).
-- ============================================================================
CREATE OR REPLACE PROCEDURE core.sp_next_admission_no(
    IN  p_tenant_id      integer,
    IN  p_school_id      integer,
    IN  p_action_user_id integer,
    IN  p_academic_year  varchar,
    INOUT p_result       refcursor DEFAULT 'next_adm_cursor'
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    OPEN p_result FOR
    SELECT 'ADM-'
        || core.fn_receipt_year(p_tenant_id, p_school_id, p_academic_year, CURRENT_DATE)
        || '-'
        || LPAD((COALESCE(c.last_seq, 0) + 1)::text, 4, '0') AS admission_no
    FROM (SELECT 1) x
    LEFT JOIN core.admission_counters c
           ON c.tenant_id     = p_tenant_id
          AND c.school_id     = p_school_id
          AND c.academic_year = COALESCE(TRIM(p_academic_year), '');
END;
$$;
