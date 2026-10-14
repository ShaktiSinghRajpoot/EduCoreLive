-- Bundle 2026-10-14r: QA round 3, batch 4 (roll no on admission, TC auto-fill, acting class teacher, leave approval warnings). Run with:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_14r.sql
-- Sources (re-runnable): student_master_fields.sql, transfer_certificate.sql, class_teacher_acting.sql, staff_leave.sql

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


-- ============================================================================
-- Transfer Certificate (TC) — issue, register and reprint.
--
-- A TC is a LEGAL document. Once issued it must reprint identically forever, so
-- its content is FROZEN into core.tc_register at issue time — never recomputed
-- from the (mutable) student row afterwards. A reprint is stamped DUPLICATE.
--
-- Sits on top of the student-exit flow (student_exit.sql): a TC can only be
-- issued for a student who has already left (is_active = FALSE). Dues MUST be
-- clear — that is the real gate (exit only *reported* dues; the TC blocks on them).
--
--   core.tc_counters    per-school / per-year gap-free number series
--   core.tc_register    the frozen certificate (one issued TC per row)
--   core.sp_tc_manage   Issue | Print | Get | List | Void
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── default TC print format (next to receipt_format) ────────────────────────
-- Two templates, not two paper sizes:
--   Basic  the everyday private-school TC (the common set of particulars).
--   Board  adds the fields CBSE / ICSE / State boards require (exam & result,
--          subjects, attendance, fees-paid-upto, activities, date of application…).
ALTER TABLE core.school_settings
    ADD COLUMN IF NOT EXISTS tc_format varchar(20) NOT NULL DEFAULT 'Basic';

ALTER TABLE core.school_settings DROP CONSTRAINT IF EXISTS chk_school_settings_tc_format;
-- Migrate any earlier value before re-adding the (stricter) constraint.
UPDATE core.school_settings SET tc_format = 'Basic'
    WHERE tc_format NOT IN ('Basic', 'Board') OR tc_format IS NULL;
ALTER TABLE core.school_settings ALTER COLUMN tc_format SET DEFAULT 'Basic';
ALTER TABLE core.school_settings
    ADD CONSTRAINT chk_school_settings_tc_format
    CHECK (tc_format IN ('Basic', 'Board'));


-- ── read/write the default TC format (mirrors sp_school_receipt_format_manage) ──
CREATE OR REPLACE PROCEDURE core.sp_school_tc_format_manage(
    IN    p_operation      varchar,          -- 'Get' | 'Save'
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_tc_format      varchar   DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'tc_format_cursor'::refcursor
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
        v_format := CASE WHEN p_tc_format IN ('Basic', 'Board')
                         THEN p_tc_format ELSE 'Basic' END;

        INSERT INTO core.school_settings (tenant_id, school_id, tc_format, created_by, created_at, is_deleted, is_active)
        VALUES (p_tenant_id, p_school_id, v_format, p_action_user_id, NOW(), FALSE, TRUE)
        ON CONFLICT (tenant_id, school_id) DO UPDATE
            SET tc_format  = EXCLUDED.tc_format,
                updated_by = p_action_user_id,
                updated_at = NOW();

        OPEN p_result FOR SELECT TRUE AS success, v_format AS tc_format;

    ELSE   -- Get
        OPEN p_result FOR
        SELECT COALESCE(NULLIF(TRIM(s.tc_format), ''), 'Basic') AS tc_format
        FROM core.school_settings s
        WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id
          AND COALESCE(s.is_deleted, FALSE) = FALSE
        LIMIT 1;
    END IF;
END;
$procedure$;


-- ── number series: TC-<year>-<seq>, gap-free per school (mirrors receipt_counters)
CREATE TABLE IF NOT EXISTS core.tc_counters (
    tenant_id integer NOT NULL,
    school_id integer NOT NULL,
    fin_year  varchar(4) NOT NULL,
    last_seq  integer NOT NULL DEFAULT 0,
    PRIMARY KEY (tenant_id, school_id, fin_year)
);


-- ── the frozen certificate ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS core.tc_register (
    tc_id        serial PRIMARY KEY,
    tenant_id    integer NOT NULL,
    school_id    integer NOT NULL,
    student_id   integer NOT NULL,
    tc_no        varchar(40) NOT NULL,
    format       varchar(20) NOT NULL DEFAULT 'Basic',
    issue_date   date NOT NULL DEFAULT CURRENT_DATE,

    -- Frozen snapshot of the student as they were on the day the TC was issued.
    admission_no   varchar(50),
    student_name   varchar(150),
    gender         varchar(20),
    dob            date,
    father_name    varchar(150),
    mother_name    varchar(150),
    class_name     varchar(50),
    section        varchar(20),
    academic_year  varchar(20),
    admission_date date,
    date_of_leaving date,
    religion       varchar(50),
    category       varchar(50),
    nationality    varchar(50),
    address        text,
    udise_no       varchar(30),        -- snapshot of the student's UDISE / PEN id

    -- Entered on the issue form (also part of the legal record).
    reason_for_leaving varchar(300),
    conduct            varchar(50),    -- Good | Satisfactory | Excellent ...
    result             varchar(100),   -- e.g. "Promoted to Class VI" / "Passed"
    remarks            varchar(500),
    outstanding_at_issue numeric(12,2) NOT NULL DEFAULT 0,

    -- Board-format extras (CBSE/ICSE/State). Optional; only the Board template
    -- prints them, but they are frozen like everything else once entered.
    exam_result      varchar(150),     -- last exam taken + result, e.g. "Annual 2025-26, Passed"
    failed_status    varchar(30),      -- No | Once | Twice (whether failed before)
    subjects_studied varchar(300),
    fees_paid_upto   varchar(50),      -- month up to which fees are paid
    working_days     integer,          -- total working days in the session
    days_present     integer,          -- days the student was present
    activities       varchar(300),     -- games / NCC / Scouts-Guides / co-curricular
    application_date date,             -- date the parent applied for the certificate

    -- Reprint tracking: the first print is the original, every later one DUPLICATE.
    print_count  integer NOT NULL DEFAULT 0,

    is_void      boolean NOT NULL DEFAULT FALSE,
    void_reason  varchar(300),
    voided_by    integer,
    voided_at    timestamptz,

    issued_by    integer,
    issued_at    timestamptz NOT NULL DEFAULT now()
);

-- One live TC number per school; a voided one frees nothing (numbers never reused).
CREATE UNIQUE INDEX IF NOT EXISTS ux_tc_register_no
    ON core.tc_register (tenant_id, school_id, tc_no);

-- A student can hold only ONE live (non-void) TC. Re-issuing needs the old one voided.
CREATE UNIQUE INDEX IF NOT EXISTS ux_tc_register_student_live
    ON core.tc_register (tenant_id, school_id, student_id)
    WHERE is_void = FALSE;

-- Board-format columns for a tc_register that already exists (idempotent).
ALTER TABLE core.tc_register
    ADD COLUMN IF NOT EXISTS udise_no         varchar(30),
    ADD COLUMN IF NOT EXISTS exam_result      varchar(150),
    ADD COLUMN IF NOT EXISTS failed_status    varchar(30),
    ADD COLUMN IF NOT EXISTS subjects_studied varchar(300),
    ADD COLUMN IF NOT EXISTS fees_paid_upto   varchar(50),
    ADD COLUMN IF NOT EXISTS working_days     integer,
    ADD COLUMN IF NOT EXISTS days_present     integer,
    ADD COLUMN IF NOT EXISTS activities       varchar(300),
    ADD COLUMN IF NOT EXISTS application_date date;


-- ── issue / print / read / list / void ──────────────────────────────────────
-- Drop the earlier (pre-Board) 15-arg signature so only one overload survives —
-- CREATE OR REPLACE keeps a differing arg list as a separate overload otherwise.
DROP PROCEDURE IF EXISTS core.sp_tc_manage(
    varchar, integer, integer, integer, integer, integer,
    varchar, varchar, varchar, varchar, varchar,
    text, integer, integer, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_tc_manage(
    IN    p_operation      varchar,     -- 'Issue' | 'Print' | 'Get' | 'List' | 'Void'
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_tc_id          integer DEFAULT NULL,
    IN    p_student_id     integer DEFAULT NULL,
    IN    p_format         varchar DEFAULT NULL,   -- Issue: chosen format (Basic | Board)
    IN    p_conduct        varchar DEFAULT NULL,
    IN    p_result         varchar DEFAULT NULL,
    IN    p_reason         varchar DEFAULT NULL,
    IN    p_remarks        varchar DEFAULT NULL,
    -- Board-format extras (all optional; ignored by the Basic template)
    IN    p_exam_result    varchar DEFAULT NULL,
    IN    p_failed_status  varchar DEFAULT NULL,
    IN    p_subjects       varchar DEFAULT NULL,
    IN    p_fees_paid_upto varchar DEFAULT NULL,
    IN    p_working_days   integer DEFAULT NULL,
    IN    p_days_present   integer DEFAULT NULL,
    IN    p_activities     varchar DEFAULT NULL,
    IN    p_application_date date  DEFAULT NULL,
    IN    p_search         text    DEFAULT NULL,    -- List
    IN    p_page_no        integer DEFAULT 1,
    IN    p_page_size      integer DEFAULT 10,
    INOUT p_result_cur     refcursor DEFAULT 'tc_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    s        core.students%ROWTYPE;
    v_dues   numeric(12,2);
    v_year   varchar(4);
    v_seq    integer;
    v_tc_no  varchar(40);
    v_new_id integer;
    v_public uuid;
    v_fmt    varchar(20);
    v_offset integer;
    v_was_printed boolean;
    v_wallet numeric(12,2);
    v_work   integer;
    v_pres   integer;
    v_upto   varchar(50);
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    -- ───────────────────────────── Issue ─────────────────────────────
    IF p_operation = 'Issue' THEN
        SELECT * INTO s
        FROM core.students
        WHERE student_id = p_student_id
          AND tenant_id  = p_tenant_id
          AND school_id  = p_school_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Student not found.';
        END IF;

        -- A TC is only for a student who has actually left, and only for the
        -- reasons that warrant one (a plain withdrawal does not get a TC).
        IF s.is_active THEN
            RAISE EXCEPTION 'Mark % as left before issuing a Transfer Certificate.', s.student_name;
        END IF;
        IF s.status NOT IN ('Transfer', 'Passout', 'Struck Off') THEN
            RAISE EXCEPTION 'A Transfer Certificate is not issued for status "%".', s.status;
        END IF;

        -- The gate: dues must be clear. Unlike exit (which only reported them),
        -- the TC is withheld until the account is settled.
        SELECT COALESCE(SUM(l.amount_due - l.amount_paid - COALESCE(l.concession, 0)), 0)
        INTO v_dues
        FROM core.student_ledger l
        WHERE l.student_id = p_student_id;

        IF v_dues > 0 THEN
            -- RAISE has no printf specifiers; format the amount ourselves.
            RAISE EXCEPTION 'Clear the pending dues of % before issuing the certificate.',
                to_char(v_dues, 'FM99,99,99,990.00');
        END IF;

        -- Money the school still holds for the family blocks the TC too. An
        -- advance balance (overpayment / prepaid) has to be refunded first,
        -- with a voucher, or it would simply stay with the school after the
        -- child has gone.
        SELECT COALESCE(balance, 0) INTO v_wallet
        FROM core.student_advance
        WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id;

        IF COALESCE(v_wallet, 0) > 0 THEN
            RAISE EXCEPTION 'Refund the advance balance of % to the family before issuing the certificate.',
                to_char(v_wallet, 'FM99,99,99,990.00');
        END IF;

        -- One live TC per student. If a valid one already exists, re-open it
        -- rather than minting a second number (reprint is the correct path).
        IF EXISTS (SELECT 1 FROM core.tc_register
                   WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                     AND student_id = p_student_id AND is_void = FALSE) THEN
            RAISE EXCEPTION 'A Transfer Certificate has already been issued for %. Use reprint.', s.student_name;
        END IF;

        -- The Board particulars are printed on a legal document, so they have
        -- to make sense: no negative days, never more days present than
        -- working days, and nobody applies for a TC after it was issued.
        IF COALESCE(p_working_days, 0) < 0 OR COALESCE(p_days_present, 0) < 0 THEN
            RAISE EXCEPTION 'Working days and days present cannot be negative.';
        END IF;
        IF p_working_days IS NOT NULL AND p_days_present IS NOT NULL
           AND p_days_present > p_working_days THEN
            RAISE EXCEPTION 'Days present (%) cannot be more than working days (%).',
                p_days_present, p_working_days;
        END IF;
        IF p_application_date IS NOT NULL AND p_application_date > CURRENT_DATE THEN
            RAISE EXCEPTION 'The date of application cannot be after the date of issue.';
        END IF;

        -- Left blank on the form, these come from the school's own records
        -- (QA BUG-085): working days = days the register of the student's section
        -- was taken this session, days present = their Present / Late days, and
        -- fees paid up to = the last fee line paid before the first unpaid one.
        v_work := p_working_days;
        IF v_work IS NULL THEN
            SELECT NULLIF(COUNT(DISTINCT a.attendance_date), 0)::int INTO v_work
              FROM core.student_attendance a
             WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
               AND a.academic_year = s.academic_year AND a.class_name = s.class_name
               AND COALESCE(a.section, '') = COALESCE(s.section, '');
        END IF;
        v_pres := p_days_present;
        IF v_pres IS NULL AND v_work IS NOT NULL THEN
            SELECT COUNT(*)::int INTO v_pres
              FROM core.student_attendance a
             WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
               AND a.student_id = p_student_id AND a.academic_year = s.academic_year
               AND a.status IN ('Present', 'Late');
        END IF;
        v_upto := NULLIF(TRIM(p_fees_paid_upto), '');
        IF v_upto IS NULL THEN
            SELECT l.installment_label INTO v_upto
              FROM core.student_ledger l
             WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
               AND l.student_id = p_student_id AND l.academic_year = s.academic_year
               AND l.amount_paid + COALESCE(l.concession, 0) >= l.amount_due
               AND l.due_date < COALESCE(
                     (SELECT MIN(u.due_date) FROM core.student_ledger u
                       WHERE u.tenant_id = p_tenant_id AND u.school_id = p_school_id
                         AND u.student_id = p_student_id AND u.academic_year = s.academic_year
                         AND u.amount_paid + COALESCE(u.concession, 0) + COALESCE(u.closed_amount, 0) < u.amount_due),
                     '9999-12-31')
             ORDER BY l.due_date DESC, l.ledger_id DESC
             LIMIT 1;
        END IF;

        v_fmt  := CASE WHEN p_format IN ('Basic', 'Board') THEN p_format ELSE 'Basic' END;
        -- The series restarts on 1 January (calendar year), not at the session
        -- start. Kept on purpose: the school confirmed it (2026-10-10).
        v_year := to_char(CURRENT_DATE, 'YYYY');

        -- Gap-free number, atomic per (school, year).
        INSERT INTO core.tc_counters (tenant_id, school_id, fin_year, last_seq)
        VALUES (p_tenant_id, p_school_id, v_year, 1)
        ON CONFLICT (tenant_id, school_id, fin_year)
        DO UPDATE SET last_seq = core.tc_counters.last_seq + 1
        RETURNING last_seq INTO v_seq;

        v_tc_no := 'TC-' || v_year || '-' || lpad(v_seq::text, 4, '0');

        INSERT INTO core.tc_register (
            tenant_id, school_id, student_id, tc_no, format, issue_date,
            admission_no, student_name, gender, dob, father_name, mother_name,
            class_name, section, academic_year, admission_date, date_of_leaving,
            religion, category, nationality, address, udise_no,
            reason_for_leaving, conduct, result, remarks, outstanding_at_issue,
            exam_result, failed_status, subjects_studied, fees_paid_upto,
            working_days, days_present, activities, application_date,
            issued_by, issued_at)
        VALUES (
            p_tenant_id, p_school_id, p_student_id, v_tc_no, v_fmt, CURRENT_DATE,
            s.admission_no, s.student_name, s.gender, s.dob, s.guardian_name, s.mother_name,
            s.class_name, s.section, s.academic_year, s.admission_date, s.date_of_leaving,
            s.religion, s.category, s.nationality, s.address, s.udise_student_id,
            NULLIF(TRIM(COALESCE(p_reason, s.leaving_reason)), ''),
            NULLIF(TRIM(p_conduct), ''), NULLIF(TRIM(p_result), ''),
            NULLIF(TRIM(p_remarks), ''), 0,
            NULLIF(TRIM(p_exam_result), ''), NULLIF(TRIM(p_failed_status), ''),
            NULLIF(TRIM(p_subjects), ''), v_upto,
            v_work, v_pres, NULLIF(TRIM(p_activities), ''), p_application_date,
            p_action_user_id, now())
        RETURNING tc_id, public_id INTO v_new_id, v_public;

        OPEN p_result_cur FOR
        SELECT TRUE AS success,
               'Transfer Certificate ' || v_tc_no || ' issued for ' || s.student_name || '.' AS message,
               v_new_id AS tc_id, v_tc_no AS tc_no,
               -- The page opens Tc/Print by this uuid (the int id is not routable).
               v_public AS public_id;
        RETURN;
    END IF;

    -- ─────────────────────────── Print / Get ──────────────────────────
    -- Print marks the certificate printed: the first Print is the original,
    -- every later one comes back with was_duplicate = TRUE so the page can
    -- stamp DUPLICATE. The page calls it only from an explicit POST when the
    -- user presses Print (TcController.MarkPrinted) -- opening or refreshing the
    -- page uses Get, which never marks anything.
    -- A VOIDED certificate is never printed: it would come out looking valid.
    IF p_operation IN ('Print', 'Get') THEN
        IF p_operation = 'Print' THEN
            SELECT (print_count > 0) INTO v_was_printed
            FROM core.tc_register
            WHERE tc_id = p_tc_id AND tenant_id = p_tenant_id AND school_id = p_school_id;

            IF NOT FOUND THEN
                RAISE EXCEPTION 'Certificate not found.';
            END IF;

            IF EXISTS (SELECT 1 FROM core.tc_register
                        WHERE tc_id = p_tc_id AND is_void) THEN
                RAISE EXCEPTION 'This certificate was voided and cannot be printed.';
            END IF;

            UPDATE core.tc_register
            SET print_count = print_count + 1
            WHERE tc_id = p_tc_id AND tenant_id = p_tenant_id AND school_id = p_school_id;
        END IF;

        OPEN p_result_cur FOR
        SELECT r.*,
               CASE WHEN p_operation = 'Print' THEN v_was_printed
                    ELSE (r.print_count > 0) END AS was_duplicate
        FROM core.tc_register r
        WHERE r.tc_id = p_tc_id
          AND r.tenant_id = p_tenant_id AND r.school_id = p_school_id;
        RETURN;
    END IF;

    -- ───────────────────────────── List ──────────────────────────────
    IF p_operation = 'List' THEN
        v_offset := (GREATEST(COALESCE(p_page_no, 1), 1) - 1) * COALESCE(p_page_size, 10);

        OPEN p_result_cur FOR
        WITH filtered AS (
            SELECT r.tc_id, r.public_id, r.tc_no, r.format, r.issue_date, r.student_id,
                   r.admission_no, r.student_name, r.class_name, r.section,
                   r.academic_year, r.date_of_leaving, r.is_void, r.print_count,
                   -- Why, who and when a number was retired, for the Register.
                   r.void_reason, r.voided_at, u.email AS voided_by_name
            FROM core.tc_register r
            LEFT JOIN core.users u ON u.user_id = r.voided_by
            WHERE r.tenant_id = p_tenant_id AND r.school_id = p_school_id
              -- strpos, not LIKE: a typed % or _ is a character, not a wildcard.
              AND (p_search IS NULL OR TRIM(p_search) = ''
                   OR strpos(LOWER(r.student_name), LOWER(TRIM(p_search))) > 0
                   OR strpos(LOWER(r.tc_no), LOWER(TRIM(p_search))) > 0
                   OR strpos(LOWER(COALESCE(r.admission_no, '')), LOWER(TRIM(p_search))) > 0)
        )
        SELECT tc_id, public_id, tc_no, format, issue_date, student_id, admission_no,
               student_name, class_name, section, academic_year, date_of_leaving,
               is_void, print_count, void_reason, voided_at, voided_by_name,
               COUNT(*) OVER() AS total_count
        FROM filtered
        ORDER BY tc_id DESC
        LIMIT COALESCE(p_page_size, 10) OFFSET v_offset;
        RETURN;
    END IF;

    -- ───────────────────────────── Void ──────────────────────────────
    -- A mistaken TC is voided, not deleted — the number is retired for audit and
    -- the student becomes eligible for a fresh issue.
    IF p_operation = 'Void' THEN
        -- A retired certificate number must say why it was retired.
        IF COALESCE(TRIM(p_reason), '') = '' THEN
            RAISE EXCEPTION 'A reason is required to void a certificate.';
        END IF;

        UPDATE core.tc_register
        SET is_void = TRUE, void_reason = NULLIF(TRIM(p_reason), ''),
            voided_by = p_action_user_id, voided_at = now()
        WHERE tc_id = p_tc_id AND tenant_id = p_tenant_id AND school_id = p_school_id
          AND is_void = FALSE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Certificate not found or already void.';
        END IF;

        OPEN p_result_cur FOR SELECT TRUE AS success, 'Certificate voided.' AS message;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation %.', p_operation;
END;
$procedure$;


-- ============================================================================
-- Acting class teacher (QA BUG-114)
--
-- Only the class teacher (or an admin) may take a section's attendance. When the
-- class teacher is away that day (approved leave, or marked Absent / On leave in
-- Staff Attendance), a teacher who takes a period in that section that day --
-- by the timetable or as the substitute -- may take the register instead. Nobody
-- has to set anything up: approving the leave and covering the periods is enough.
--
-- core.sp_class_teacher_acting(..., p_class, p_section, p_date)
--   one row: is_acting, class_teacher (name), away_reason
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

CREATE OR REPLACE PROCEDURE core.sp_class_teacher_acting(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_class          varchar,
    IN    p_section        varchar,
    IN    p_date           date,
    INOUT p_result         refcursor DEFAULT 'acting_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_section  integer;
    v_teacher  integer;
    v_me       integer;
    v_away     varchar;
    v_dow      integer := EXTRACT(ISODOW FROM COALESCE(p_date, CURRENT_DATE))::int;
    v_acting   boolean := FALSE;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    -- The section of the session that contains the date, and its class teacher.
    SELECT sec.academic_class_section_id, sec.class_teacher_staff_id
      INTO v_section, v_teacher
      FROM academic.academic_class_sections sec
      JOIN academic.academic_classes c ON c.academic_class_id = sec.academic_class_id
      JOIN academic.academic_years y   ON y.academic_year_id  = sec.academic_year_id
     WHERE sec.tenant_id = p_tenant_id AND sec.school_id = p_school_id
       AND NOT COALESCE(sec.is_deleted, FALSE)
       AND c.class_name = p_class AND sec.section_name = COALESCE(p_section, '')
       AND COALESCE(p_date, CURRENT_DATE) BETWEEN y.start_date::date AND y.end_date::date
     LIMIT 1;

    -- The signed-in user's staff record.
    SELECT s.staff_id INTO v_me
      FROM core.staff s
     WHERE s.user_id = p_action_user_id AND s.tenant_id = p_tenant_id AND s.school_id = p_school_id
       AND NOT COALESCE(s.is_deleted, FALSE)
     LIMIT 1;

    IF v_section IS NOT NULL AND v_teacher IS NOT NULL AND v_me IS NOT NULL AND v_me <> v_teacher THEN
        v_away := core.fn_staff_away(p_tenant_id, p_school_id, v_teacher, COALESCE(p_date, CURRENT_DATE));
        IF v_away IS NOT NULL THEN
            v_acting := EXISTS (
                    SELECT 1 FROM academic.timetable t
                     WHERE t.tenant_id = p_tenant_id AND t.school_id = p_school_id
                       AND t.academic_class_section_id = v_section
                       AND t.day_of_week = v_dow AND t.staff_id = v_me)
                OR EXISTS (
                    SELECT 1 FROM academic.timetable_substitutions x
                     WHERE x.tenant_id = p_tenant_id AND x.school_id = p_school_id
                       AND x.academic_class_section_id = v_section
                       AND x.sub_date = COALESCE(p_date, CURRENT_DATE)
                       AND x.substitute_staff_id = v_me);
        END IF;
    END IF;

    OPEN p_result FOR
    SELECT v_acting AS is_acting,
           (SELECT s.full_name FROM core.staff s WHERE s.staff_id = v_teacher) AS class_teacher,
           v_away AS away_reason;
END;
$procedure$;


-- ============================================================================
-- Staff leave: apply, approve, reject, cancel; balance and day-count previews.
--
-- The page existed with no backend at all — Apply/Approve/Reject just set a
-- TempData message and changed nothing. This is the real thing.
--
-- DESIGN NOTES
--
--   * Days are counted on the SCHOOL CALENDAR (core.fn_school_working_days):
--     the school's weekly off days and declared holidays are not leave days, a
--     Sunday declared a working day is, and a half school day counts 0.5. Payroll
--     uses the same function for the month's working days and for Loss of Pay,
--     so the leave screen and the payslip can never disagree. (Until Oct 2026
--     this counted "every day except Sunday", ignoring the School Calendar.)
--
--   * Leave types are a fixed list: Casual, Sick, Earned, Maternity, Comp-off,
--     Unpaid. 'Unpaid' is what payroll charges as Loss of Pay; every other type
--     is paid leave. An unknown word used to be accepted and silently paid.
--
--   * Paid types have a yearly entitlement (core.fn_leave_entitlement — the same
--     figures the Leave page shows): Casual 12, Sick 10, Earned 15, Maternity 90
--     days per calendar year. Pending + approved days count against it, so two
--     pending requests cannot together exceed it. Anything beyond is applied as
--     Unpaid (LOP). Comp-off and Unpaid are not capped (there is no comp-off
--     ledger to cap against).
--
--   * Overlap is refused. Two live requests covering the same day would be
--     counted twice by payroll, and it almost always means a duplicate entry.
--
--   * Refused as well: leave for an inactive staff member, leave before the
--     joining date or after the last working day.
--
--   * A half day (p_half_day) is one full working day counted as 0.5.
--
--   * A decided request cannot be decided again — approve/reject record who and
--     when, and overwriting that would lose the history.
--
--   * CANCEL withdraws a request without pretending it was refused: a pending
--     request always; an approved one only before it starts and only if no
--     salary covering those dates has been paid. Who, when and why are kept in
--     cancelled_by / cancelled_at / cancel_reason; the original decision stays.
--
-- p_half_day is the LAST parameter (after p_result) so existing positional
-- callers keep working.
--
-- Target DB: PostgreSQL. Safe to re-run.
-- ============================================================================

CREATE TABLE IF NOT EXISTS core.staff_leave (
    leave_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       integer NOT NULL,
    school_id       integer NOT NULL,
    staff_id        integer NOT NULL,

    leave_type      varchar(30) NOT NULL,
    from_date       date NOT NULL,
    to_date         date NOT NULL,
    days            numeric(5,1) NOT NULL,       -- school working days (0.5 = half day)
    reason          text,

    status          varchar(20) NOT NULL DEFAULT 'Pending',
    decision_remark text,

    applied_by      integer NOT NULL DEFAULT 0,
    applied_at      timestamptz NOT NULL DEFAULT now(),
    decided_by      integer,
    decided_at      timestamptz,

    CONSTRAINT chk_staff_leave_status CHECK (status IN ('Pending', 'Approved', 'Rejected', 'Cancelled')),
    CONSTRAINT chk_staff_leave_dates  CHECK (to_date >= from_date)
);

CREATE INDEX IF NOT EXISTS ix_staff_leave_staff
    ON core.staff_leave (tenant_id, school_id, staff_id, from_date);
CREATE INDEX IF NOT EXISTS ix_staff_leave_status
    ON core.staff_leave (tenant_id, school_id, status);

-- Oct 2026: half days, cancellation trail.
DO $mig$
BEGIN
    IF (SELECT data_type FROM information_schema.columns
        WHERE table_schema = 'core' AND table_name = 'staff_leave' AND column_name = 'days') = 'integer' THEN
        ALTER TABLE core.staff_leave ALTER COLUMN days TYPE numeric(5,1);
    END IF;
END $mig$;

ALTER TABLE core.staff_leave ADD COLUMN IF NOT EXISTS half_day      boolean NOT NULL DEFAULT FALSE;
ALTER TABLE core.staff_leave ADD COLUMN IF NOT EXISTS cancelled_by  integer;
ALTER TABLE core.staff_leave ADD COLUMN IF NOT EXISTS cancelled_at  timestamptz;
ALTER TABLE core.staff_leave ADD COLUMN IF NOT EXISTS cancel_reason text;

ALTER TABLE core.staff_leave DROP CONSTRAINT IF EXISTS chk_staff_leave_status;
ALTER TABLE core.staff_leave ADD CONSTRAINT chk_staff_leave_status
    CHECK (status IN ('Pending', 'Approved', 'Rejected', 'Cancelled'));


-- Every day except Sunday. Kept for older callers; leave and payroll now use
-- core.fn_school_working_days below.
CREATE OR REPLACE FUNCTION core.fn_working_days(p_from date, p_to date)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT COUNT(*)::int
    FROM generate_series(p_from, p_to, INTERVAL '1 day') AS g(d)
    WHERE EXTRACT(DOW FROM g.d) <> 0;
$fn$;


-- School working days between two dates, on THIS school's calendar
-- (academic.fn_school_day_type: declared day first, then the weekly off days).
-- working = 1, half_day = 0.5, weekly_off / holiday = 0. ONE definition, used by
-- leave apply, the leave preview, and payroll (month days, pro-rata, LOP).
CREATE OR REPLACE FUNCTION core.fn_school_working_days(
    p_tenant_id integer, p_school_id integer, p_from date, p_to date)
RETURNS numeric
LANGUAGE sql
STABLE
AS $fn$
    SELECT COALESCE(SUM(CASE academic.fn_school_day_type(p_tenant_id, p_school_id, g.d::date)
                            WHEN 'working'  THEN 1
                            WHEN 'half_day' THEN 0.5
                            ELSE 0 END), 0)::numeric
    FROM generate_series(p_from, p_to, INTERVAL '1 day') AS g(d);
$fn$;


-- Yearly entitlement of a paid leave type, in days. NULL = not capped.
-- The Leave page shows the same figures.
CREATE OR REPLACE FUNCTION core.fn_leave_entitlement(p_leave_type text)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT CASE p_leave_type
               WHEN 'Casual'    THEN 12
               WHEN 'Sick'      THEN 10
               WHEN 'Earned'    THEN 15
               WHEN 'Maternity' THEN 90
               ELSE NULL END::numeric;
$fn$;


-- The signature grew a trailing p_half_day; drop the old one so a 13-argument
-- call is not ambiguous between two overloads.
DROP PROCEDURE IF EXISTS core.sp_staff_leave_manage(
    text, integer, integer, integer, integer, integer, text, date, date, text, text, text, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_staff_leave_manage(
    IN    p_operation      text,          -- LIST | APPLY | DECIDE | CANCEL | BALANCE | DAYS
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_leave_id       integer DEFAULT NULL,
    IN    p_staff_id       integer DEFAULT NULL,
    IN    p_leave_type     text    DEFAULT NULL,
    IN    p_from_date      date    DEFAULT NULL,   -- BALANCE: any date in the year wanted
    IN    p_to_date        date    DEFAULT NULL,
    IN    p_reason         text    DEFAULT NULL,
    IN    p_status         text    DEFAULT NULL,   -- DECIDE: Approved | Rejected
    IN    p_remark         text    DEFAULT NULL,   -- DECIDE remark / CANCEL reason
    INOUT p_result         refcursor DEFAULT 'leave_cursor'::refcursor,
    IN    p_half_day       boolean DEFAULT FALSE)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    c_types  CONSTANT text[] := ARRAY['Casual', 'Sick', 'Earned', 'Maternity', 'Comp-off', 'Unpaid'];
    v_days   numeric;
    v_id     integer;
    v_status text;
    v_type   text;
    v_cap    numeric;
    v_used   numeric;
    v_year   integer;
    v_join   date;
    v_lwd    date;
    v_from   date;
    v_to     date;
    v_staff  integer;
    v_note   text := '';
    v_list   text;
    v_n      integer;
    v_name   text;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    -- ── LIST ────────────────────────────────────────────────────────────────
    IF p_operation = 'LIST' THEN
        OPEN p_result FOR
        SELECT l.leave_id, l.staff_id, s.full_name, s.employee_code, s.designation,
               l.leave_type, l.from_date, l.to_date, l.days, l.half_day, l.reason,
               l.status, l.decision_remark, l.applied_at, l.decided_at,
               l.cancel_reason, l.cancelled_at,
               -- "on leave today" for the page KPI, decided here so every caller
               -- agrees on what today means.
               (l.status = 'Approved'
                AND CURRENT_DATE BETWEEN l.from_date::date AND l.to_date::date) AS on_leave_today
        FROM core.staff_leave l
        JOIN core.staff s ON s.staff_id = l.staff_id
        WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
          AND (p_staff_id IS NULL OR l.staff_id = p_staff_id)
          AND (p_status IS NULL OR TRIM(p_status) = '' OR l.status = p_status)
        ORDER BY l.applied_at DESC, l.leave_id DESC;
        RETURN;
    END IF;

    -- ── DAYS: what APPLY would count, for the form's preview ────────────────
    IF p_operation = 'DAYS' THEN
        v_days := 0;
        IF p_from_date IS NOT NULL AND p_to_date IS NOT NULL AND p_to_date >= p_from_date THEN
            v_days := core.fn_school_working_days(p_tenant_id, p_school_id, p_from_date, p_to_date);
            IF COALESCE(p_half_day, FALSE) THEN
                v_days := CASE WHEN p_from_date = p_to_date AND v_days = 1 THEN 0.5 ELSE 0 END;
            END IF;
        END IF;
        OPEN p_result FOR
        SELECT TRUE AS success, NULL::integer AS leave_id, v_days AS days,
               trim_scale(v_days) || ' working day(s)' AS message;
        RETURN;
    END IF;

    -- ── BALANCE: entitlement, taken, pending, left — per type, for one year ─
    IF p_operation = 'BALANCE' THEN
        IF NOT EXISTS (SELECT 1 FROM core.staff
                       WHERE staff_id = p_staff_id AND tenant_id = p_tenant_id
                         AND school_id = p_school_id AND is_deleted = FALSE) THEN
            RAISE EXCEPTION 'Staff member not found.';
        END IF;
        v_year := EXTRACT(YEAR FROM COALESCE(p_from_date, CURRENT_DATE))::int;

        OPEN p_result FOR
        SELECT t.leave_type,
               core.fn_leave_entitlement(t.leave_type) AS entitled,
               COALESCE(SUM(l.days) FILTER (WHERE l.status = 'Approved'), 0) AS taken,
               COALESCE(SUM(l.days) FILTER (WHERE l.status = 'Pending'), 0)  AS pending,
               core.fn_leave_entitlement(t.leave_type)
                 - COALESCE(SUM(l.days) FILTER (WHERE l.status IN ('Approved', 'Pending')), 0) AS remaining,
               v_year AS year
        FROM unnest(c_types) WITH ORDINALITY AS t(leave_type, ord)
        LEFT JOIN core.staff_leave l
               ON l.tenant_id = p_tenant_id AND l.school_id = p_school_id
              AND l.staff_id = p_staff_id AND l.leave_type = t.leave_type
              AND l.status IN ('Approved', 'Pending')
              AND EXTRACT(YEAR FROM l.from_date::date) = v_year
        GROUP BY t.leave_type, t.ord
        ORDER BY t.ord;
        RETURN;
    END IF;

    -- ── APPLY ───────────────────────────────────────────────────────────────
    IF p_operation = 'APPLY' THEN
        IF COALESCE(p_staff_id, 0) <= 0 THEN
            RAISE EXCEPTION 'Choose the staff member.';
        END IF;
        IF p_leave_type IS NULL OR TRIM(p_leave_type) = '' THEN
            RAISE EXCEPTION 'Choose the leave type.';
        END IF;
        -- Stored in its canonical spelling, so payroll's 'Unpaid' check and the
        -- balance totals always match.
        SELECT t INTO v_type FROM unnest(c_types) AS t WHERE LOWER(t) = LOWER(TRIM(p_leave_type));
        IF v_type IS NULL THEN
            RAISE EXCEPTION 'Unknown leave type "%". Choose Casual, Sick, Earned, Maternity, Comp-off or Unpaid.', TRIM(p_leave_type);
        END IF;
        IF p_from_date IS NULL OR p_to_date IS NULL THEN
            RAISE EXCEPTION 'Choose both the from and to dates.';
        END IF;
        IF p_to_date < p_from_date THEN
            RAISE EXCEPTION 'The to date cannot be before the from date.';
        END IF;

        SELECT status, NULLIF(joining_date, '')::date, NULLIF(last_working_date, '')::date
          INTO v_status, v_join, v_lwd
        FROM core.staff
        WHERE staff_id = p_staff_id AND tenant_id = p_tenant_id
          AND school_id = p_school_id AND is_deleted = FALSE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Staff member not found.';
        END IF;
        IF v_status = 'Inactive' THEN
            RAISE EXCEPTION 'This staff member is inactive. Leave can only be recorded for current staff.';
        END IF;
        IF v_join IS NOT NULL AND p_from_date < v_join THEN
            RAISE EXCEPTION 'Leave cannot start before the joining date (%).', to_char(v_join, 'DD Mon YYYY');
        END IF;
        IF v_lwd IS NOT NULL AND p_to_date > v_lwd THEN
            RAISE EXCEPTION 'Leave cannot run past the last working day (%).', to_char(v_lwd, 'DD Mon YYYY');
        END IF;

        v_days := core.fn_school_working_days(p_tenant_id, p_school_id, p_from_date, p_to_date);

        IF COALESCE(p_half_day, FALSE) THEN
            IF p_from_date <> p_to_date THEN
                RAISE EXCEPTION 'A half-day leave is for a single date.';
            END IF;
            IF v_days <> 1 THEN
                RAISE EXCEPTION 'A half-day leave must be on a full working day.';
            END IF;
            v_days := 0.5;
        END IF;

        -- A range of only holidays / weekly offs is nothing to approve.
        IF v_days = 0 THEN
            RAISE EXCEPTION 'That range has no working days in it (weekly offs and school holidays are not counted).';
        END IF;

        -- Overlapping a live request is almost always a duplicate, and payroll
        -- would charge the days twice.
        IF EXISTS (
            SELECT 1 FROM core.staff_leave
            WHERE tenant_id = p_tenant_id AND school_id = p_school_id
              AND staff_id  = p_staff_id
              AND status IN ('Pending', 'Approved')
              AND from_date::date <= p_to_date AND to_date::date >= p_from_date
        ) THEN
            RAISE EXCEPTION 'This staff member already has a pending or approved leave overlapping those dates.';
        END IF;

        -- Yearly entitlement of a paid type: pending + approved count against it.
        v_cap := core.fn_leave_entitlement(v_type);
        IF v_cap IS NOT NULL THEN
            v_year := EXTRACT(YEAR FROM p_from_date)::int;
            SELECT COALESCE(SUM(days), 0) INTO v_used
            FROM core.staff_leave
            WHERE tenant_id = p_tenant_id AND school_id = p_school_id
              AND staff_id = p_staff_id AND leave_type = v_type
              AND status IN ('Pending', 'Approved')
              AND EXTRACT(YEAR FROM from_date::date) = v_year;

            IF v_used + v_days > v_cap THEN
                RAISE EXCEPTION 'Only % day(s) of % leave left for % (% asked for). Apply the rest as Unpaid leave.',
                    trim_scale(GREATEST(v_cap - v_used, 0)), v_type, v_year, trim_scale(v_days);
            END IF;
        END IF;

        INSERT INTO core.staff_leave (
            tenant_id, school_id, staff_id, leave_type, from_date, to_date,
            days, half_day, reason, status, applied_by)
        VALUES (
            p_tenant_id, p_school_id, p_staff_id, v_type, p_from_date, p_to_date,
            v_days, COALESCE(p_half_day, FALSE), NULLIF(TRIM(COALESCE(p_reason, '')), ''), 'Pending', p_action_user_id)
        RETURNING leave_id INTO v_id;

        OPEN p_result FOR
        SELECT TRUE AS success, v_id AS leave_id, v_days AS days,
               'Leave applied for ' || trim_scale(v_days) || ' working day(s).' AS message;
        RETURN;
    END IF;

    -- ── DECIDE ──────────────────────────────────────────────────────────────
    IF p_operation = 'DECIDE' THEN
        IF p_status IS NULL OR p_status NOT IN ('Approved', 'Rejected') THEN
            RAISE EXCEPTION 'A leave request can only be approved or rejected.';
        END IF;

        SELECT status INTO v_status
        FROM core.staff_leave
        WHERE leave_id = p_leave_id AND tenant_id = p_tenant_id AND school_id = p_school_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Leave request not found.';
        END IF;

        -- Deciding twice would overwrite who decided it and when.
        IF v_status <> 'Pending' THEN
            RAISE EXCEPTION 'This request was already %.', LOWER(v_status);
        END IF;

        UPDATE core.staff_leave
        SET status          = p_status,
            decision_remark = NULLIF(TRIM(COALESCE(p_remark, '')), ''),
            decided_by      = p_action_user_id,
            decided_at      = now()
        WHERE leave_id = p_leave_id AND tenant_id = p_tenant_id AND school_id = p_school_id;

        -- What the approval leaves to arrange, said in the same message (QA BUG-115,
        -- BUG-090): the class charge, the periods to cover, and salary already paid.
        IF p_status = 'Approved' THEN
            SELECT l.from_date::date, l.to_date::date, l.staff_id, l.leave_type, s.full_name
              INTO v_from, v_to, v_staff, v_type, v_name
              FROM core.staff_leave l JOIN core.staff s ON s.staff_id = l.staff_id
             WHERE l.leave_id = p_leave_id;

            SELECT string_agg(DISTINCT c.class_name || '-' || sec.section_name, ', ') INTO v_list
              FROM academic.academic_class_sections sec
              JOIN academic.academic_classes c ON c.academic_class_id = sec.academic_class_id
              JOIN academic.academic_years y   ON y.academic_year_id  = sec.academic_year_id
             WHERE sec.tenant_id = p_tenant_id AND sec.school_id = p_school_id
               AND sec.class_teacher_staff_id = v_staff AND NOT COALESCE(sec.is_deleted, FALSE)
               AND v_from <= y.end_date::date AND v_to >= y.start_date::date;
            IF v_list IS NOT NULL THEN
                v_note := v_note || ' ' || v_name || ' is class teacher of ' || v_list
                       || ': a teacher with a period there that day can take the register.';
            END IF;

            SELECT COUNT(*) INTO v_n
              FROM generate_series(v_from, v_to, interval '1 day') d(day)
              JOIN academic.timetable t
                ON t.tenant_id = p_tenant_id AND t.school_id = p_school_id AND t.staff_id = v_staff
               AND t.day_of_week = EXTRACT(ISODOW FROM d.day)::int
              JOIN academic.academic_years y ON y.academic_year_id = t.academic_year_id
                                            AND d.day::date BETWEEN y.start_date::date AND y.end_date::date;
            IF v_n > 0 THEN
                v_note := v_note || ' ' || v_n || ' timetable period(s) need a substitute -- Staff Attendance > Substitutes.';
            END IF;

            IF LOWER(v_type) = 'unpaid' AND EXISTS (
                   SELECT 1 FROM core.staff_payroll p
                    WHERE p.tenant_id = p_tenant_id AND p.school_id = p_school_id
                      AND p.staff_id = v_staff AND p.status = 'Paid'
                      AND make_date(p.pay_year, p.pay_month, 1)
                          BETWEEN DATE_TRUNC('month', v_from)::date AND v_to) THEN
                v_note := v_note || ' Salary for that month is already paid, so this unpaid leave is not deducted:'
                       || ' add a deduction in Payroll > Adjustments of the next unpaid month.';
            END IF;
        END IF;

        OPEN p_result FOR
        SELECT TRUE AS success, p_leave_id AS leave_id, 0::numeric AS days,
               'Leave ' || LOWER(p_status) || '.' || v_note AS message;
        RETURN;
    END IF;

    -- ── CANCEL ──────────────────────────────────────────────────────────────
    IF p_operation = 'CANCEL' THEN
        SELECT status, from_date::date, to_date::date, staff_id
          INTO v_status, v_from, v_to, v_staff
        FROM core.staff_leave
        WHERE leave_id = p_leave_id AND tenant_id = p_tenant_id AND school_id = p_school_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Leave request not found.';
        END IF;
        IF NULLIF(TRIM(COALESCE(p_remark, '')), '') IS NULL THEN
            RAISE EXCEPTION 'Give a reason for cancelling.';
        END IF;

        IF v_status = 'Approved' THEN
            IF v_from <= CURRENT_DATE THEN
                RAISE EXCEPTION 'This leave has already started, so it cannot be cancelled.';
            END IF;
            IF EXISTS (SELECT 1 FROM core.staff_payroll p
                       WHERE p.tenant_id = p_tenant_id AND p.school_id = p_school_id
                         AND p.staff_id = v_staff AND p.status = 'Paid'
                         AND make_date(p.pay_year, p.pay_month, 1)
                             BETWEEN DATE_TRUNC('month', v_from)::date AND v_to) THEN
                RAISE EXCEPTION 'Salary for that month is already paid, so this leave cannot be cancelled. Record a payroll adjustment instead.';
            END IF;
        ELSIF v_status <> 'Pending' THEN
            RAISE EXCEPTION 'Only a pending or approved request can be cancelled. This one was %.', LOWER(v_status);
        END IF;

        UPDATE core.staff_leave
        SET status        = 'Cancelled',
            cancelled_by  = p_action_user_id,
            cancelled_at  = now(),
            cancel_reason = TRIM(p_remark)
        WHERE leave_id = p_leave_id AND tenant_id = p_tenant_id AND school_id = p_school_id;

        OPEN p_result FOR
        SELECT TRUE AS success, p_leave_id AS leave_id, 0::numeric AS days,
               'Leave cancelled.' AS message;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation %.', p_operation;
END;
$procedure$;


