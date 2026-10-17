-- Bundle 2026-10-17i: Promotion's fee flag and hold-back count only dues already fallen due (GetStudents fee_due_now);
-- the dues list returns carried_from (Year-End carried dues are marked on Collect Fees / profile). Run with:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_17i.sql
-- Sources: student_dues_refundable.sql, student_master_fields.sql, student_promotion.sql

-- ===== student_dues_refundable.sql =====
-- ============================================================================
-- core.sp_student_dues_get -- the fee counter's list of open dues.
--
-- Supersedes the copies in student_dues.sql (old: ignores concession) and
-- fee_collection_full_flow.sql. Same columns as the live version, plus
-- is_refundable so the counter can tag a refundable deposit and keep a
-- discount off it (the collect proc refuses a concession on one anyway).
--
-- Needs core.fn_ledger_head_refundable (fee_refund.sql).
-- Target DB: PostgreSQL. Safe to re-run.
-- ============================================================================

CREATE OR REPLACE PROCEDURE core.sp_student_dues_get(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_student_id     integer,
    INOUT p_result         refcursor DEFAULT 'result_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR p_student_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;

    OPEN p_result FOR
    SELECT
        ledger_id,
        fee_head_name,
        frequency,
        installment_label,
        due_date,
        amount_due,
        amount_paid,
        concession,
        (amount_due - amount_paid - concession) AS outstanding,
        core.fn_ledger_head_refundable(ledger_id) AS is_refundable,
        academic_year,           -- the student profile splits dues by session
        carried_from             -- set when Year-End moved the due here from an older session
    FROM core.student_ledger
    WHERE tenant_id  = p_tenant_id
      AND school_id  = p_school_id
      AND student_id = p_student_id
      AND amount_due > amount_paid + concession
    ORDER BY due_date NULLS LAST, ledger_id;
END;
$procedure$;

-- ===== student_master_fields.sql =====
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
        -- (core.fn_session_rolls also counts children promoted out of it early)
        IF NULLIF(TRIM(COALESCE(p_roll_no, '')), '') IS NOT NULL AND EXISTS (
               SELECT 1 FROM core.fn_session_rolls(p_tenant_id, p_school_id, v_year, p_class_name, p_section) o
                WHERE LOWER(TRIM(o.roll_no)) = LOWER(TRIM(p_roll_no))) THEN
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
              FROM core.fn_session_rolls(p_tenant_id, p_school_id, v_year, p_class_name, p_section) o
             WHERE TRIM(o.roll_no) ~ '^[0-9]{1,6}$';
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
                    ), 0) AS fee_due,
                    -- only what has fallen due (due date today or earlier): months still
                    -- ahead and next session's fees are not owed yet (Promotion's flag)
                    COALESCE((
                        SELECT SUM(l.amount_due - l.amount_paid - l.concession)
                        FROM core.student_ledger l
                        WHERE l.student_id = s.student_id
                          AND (l.due_date IS NULL OR l.due_date::date <= CURRENT_DATE)
                    ), 0) AS fee_due_now
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

-- ===== student_promotion.sql =====
-- ============================================================================
-- Bulk student promotion — moving a class into the next academic session.
--
-- core.students holds ONE row per student: class_name, section and
-- academic_year live on that row, and there is no per-year enrolment table.
-- The unique (tenant_id, school_id, admission_no) constraint also forbids a
-- second row for the same student in a new year. So promotion is an in-place
-- UPDATE of the student row, exactly like the exit flow: the student_id never
-- changes, so the fee ledger, receipts and TC register keep pointing at it.
--
-- History is kept separately in core.student_promotion_history, because the
-- student row itself remembers nothing about the class it came from.
--
--   core.student_promotion_history  one row per student per promotion run
--   core.sp_class_ladder            classes in real teaching order
--   core.sp_student_promote         the promotion itself
--
-- outcome values:
--   Promote   moved up to the next class in the ladder, new session
--   Retain    stays in the same class, new session
--   PassOut   completed the final class -> inactive, TC-eligible
--
-- PREREQUISITE: the target session must already have its classes and sections
-- (see academic_session_rollover.sql). Classes are per-session rows, so a new
-- session is empty until the structure is copied forward, and promoting into an
-- empty session would write students onto classes that do not exist.
--
-- MONEY: Promote / Retain bill the target class's recurring fee structure for
-- the new session (once per student per session) and re-bill a kept bus route;
-- PassOut closes later dues like an exit. Depends on student_money_lifecycle.sql,
-- transport_module.sql and student_exit.sql -- apply those first.
-- ============================================================================

-- ── history ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS core.student_promotion_history (
    promotion_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     integer      NOT NULL,
    school_id     integer      NOT NULL,
    student_id    integer      NOT NULL REFERENCES core.students(student_id) ON DELETE CASCADE,
    from_year     varchar(20)  NOT NULL,
    from_class    varchar(50)  NOT NULL,
    from_section  varchar(20),
    to_year       varchar(20)  NOT NULL,
    to_class      varchar(50),
    to_section    varchar(20),
    outcome       varchar(20)  NOT NULL,
    dues_carried  numeric(12,2) NOT NULL DEFAULT 0,
    promoted_by   integer      NOT NULL DEFAULT 0,
    promoted_at   timestamptz  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_student_promotion_history_student
    ON core.student_promotion_history (student_id);
CREATE INDEX IF NOT EXISTS idx_student_promotion_history_year
    ON core.student_promotion_history (tenant_id, school_id, to_year);

COMMENT ON TABLE core.student_promotion_history IS
    'Audit trail of promotions. The student row is updated in place, so this is the only record of which class a student came from.';
COMMENT ON COLUMN core.student_promotion_history.dues_carried IS
    'Outstanding balance at the moment of promotion. The ledger is not year-scoped, so the dues simply follow the student; this is the snapshot.';


-- ── the class ladder ───────────────────────────────────────────────────────
-- config.sp_dropdown_common returns classes newest-id-first, which is NOT
-- teaching order — using it to work out "the next class" walks DOWN the
-- school. display_order is the column meant for this, so promotion (and the
-- page's "next class" preview) reads the ladder from here instead.
--
-- Classes are per-session rows, so the ladder MUST be scoped to one session.
-- Unscoped it returns every session's classes concatenated, which reads as
-- "1st, 1st, 2nd, 2nd, ..." the moment a second session has structure.
-- p_academic_year_name is optional; NULL means the current session.
DROP PROCEDURE IF EXISTS core.sp_class_ladder(integer, integer, integer, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_class_ladder(
    IN  p_tenant_id         integer,
    IN  p_school_id         integer,
    IN  p_action_user_id    integer,
    IN  p_academic_year_name character varying DEFAULT NULL,
    INOUT p_result          refcursor DEFAULT 'class_ladder_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_year varchar := NULLIF(TRIM(COALESCE(p_academic_year_name, '')), '');
    v_year_id integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        OPEN p_result FOR SELECT WHERE FALSE;
        RETURN;
    END IF;

    SELECT academic_year_id INTO v_year_id
    FROM   academic.academic_years
    WHERE  tenant_id = p_tenant_id
      AND  school_id = p_school_id
      AND  COALESCE(is_deleted, FALSE) = FALSE
      AND  (   (v_year IS NOT NULL AND academic_year_name = v_year)
            OR (v_year IS NULL     AND COALESCE(is_current, FALSE) = TRUE))
    LIMIT 1;

    IF v_year_id IS NULL THEN
        OPEN p_result FOR SELECT WHERE FALSE;
        RETURN;
    END IF;

    -- display_order comes back too: the Promotion page needs it to work out the
    -- next class exactly the way this proc's caller does (order from the SOURCE
    -- session, then the first higher class in the TARGET). Names alone are not
    -- enough once the two sessions hold different classes. Additive column —
    -- existing consumers read by name, so they are unaffected.
    OPEN p_result FOR
    SELECT class_name, display_order
    FROM academic.academic_classes
    WHERE tenant_id = p_tenant_id
      AND school_id = p_school_id
      AND academic_year_id = v_year_id
      AND COALESCE(is_deleted, FALSE) = FALSE
      AND COALESCE(is_active,  TRUE)  = TRUE
    ORDER BY display_order, academic_class_id;
    RETURN;
END;
$procedure$;


-- ── promote ────────────────────────────────────────────────────────────────
-- p_students is [{"studentId":1,"outcome":"promote"}, ...]. The target class
-- is NOT taken from the browser: it is derived here from the ladder above, so
-- a stale page cannot write the wrong class.
--
-- A student who cannot be promoted is skipped and reported, not fatal — one
-- student on a stale page should not roll back the whole class.
CREATE OR REPLACE PROCEDURE core.sp_student_promote(
    IN  p_tenant_id      integer,
    IN  p_school_id      integer,
    IN  p_action_user_id integer,
    IN  p_source_year    varchar,
    IN  p_target_year    varchar,
    IN  p_target_section varchar DEFAULT NULL,   -- NULL / 'keep' = keep the student's section
    IN  p_carry_dues     boolean DEFAULT TRUE,
    IN  p_students       jsonb   DEFAULT '[]'::jsonb,
    INOUT p_result       refcursor DEFAULT 'student_promote_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    r             record;
    v_src         varchar := TRIM(COALESCE(p_source_year, ''));
    v_tgt         varchar := TRIM(COALESCE(p_target_year, ''));
    v_sec         varchar := NULLIF(TRIM(COALESCE(p_target_section, '')), '');
    v_src_year_id integer;
    v_tgt_year_id integer;
    v_tgt_classes integer := 0;
    v_cur_order   integer;
    v_pick_order  integer;   -- display_order of an explicitly chosen target class
    v_outcome     varchar;
    v_next        varchar;
    v_to_class    varchar;
    v_to_section  varchar;
    v_dues        numeric(12,2);
    v_due_now     numeric(12,2);
    v_promoted    integer := 0;
    v_retained    integer := 0;
    v_passed      integer := 0;
    v_skipped     text[]  := '{}';
    v_tgt_start   date;
    v_plan        jsonb;
    v_billed      integer := 0;
    v_roll        varchar;   -- the roll number in the new class (see below)
    v_unbilled    text[]  := '{}';
    v_route       integer;
    v_stop        integer;
    v_bus         refcursor;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    IF v_src = '' OR v_tgt = '' THEN
        RAISE EXCEPTION 'Choose both the current and the new academic session.';
    END IF;

    IF LOWER(v_src) = LOWER(v_tgt) THEN
        RAISE EXCEPTION 'The new session must be different from the current session.';
    END IF;

    SELECT academic_year_id, start_date::date INTO v_tgt_year_id, v_tgt_start
    FROM   academic.academic_years
    WHERE  tenant_id = p_tenant_id
      AND  school_id = p_school_id
      AND  academic_year_name = v_tgt
      AND  COALESCE(is_deleted, FALSE) = FALSE
      AND  COALESCE(is_active,  TRUE)  = TRUE;

    IF v_tgt_year_id IS NULL THEN
        RAISE EXCEPTION 'Academic session % is not set up for this school.', v_tgt;
    END IF;

    -- The session EXISTING is not enough. Classes and sections are per-session
    -- rows, so a freshly created session is empty, and promoting into it writes
    -- students into a class that does not exist anywhere in the setup — they
    -- then vanish from every class-filtered page. Stop before that happens.
    SELECT COUNT(*) INTO v_tgt_classes
    FROM   academic.academic_classes
    WHERE  tenant_id = p_tenant_id
      AND  school_id = p_school_id
      AND  academic_year_id = v_tgt_year_id
      AND  COALESCE(is_deleted, FALSE) = FALSE
      AND  COALESCE(is_active,  TRUE)  = TRUE;

    IF v_tgt_classes = 0 THEN
        RAISE EXCEPTION 'Session % has no classes or sections yet. Open Settings > Classes & Sections, pick %, and copy the structure from the previous session before promoting.', v_tgt, v_tgt;
    END IF;

    -- Optional: used only to read the student's current position on the ladder.
    SELECT academic_year_id INTO v_src_year_id
    FROM   academic.academic_years
    WHERE  tenant_id = p_tenant_id
      AND  school_id = p_school_id
      AND  academic_year_name = v_src
      AND  COALESCE(is_deleted, FALSE) = FALSE;

    IF p_students IS NULL OR jsonb_array_length(p_students) = 0 THEN
        RAISE EXCEPTION 'No students were selected.';
    END IF;

    -- 'keep' is the page's own token for "leave the section alone".
    IF v_sec IS NOT NULL AND LOWER(v_sec) = 'keep' THEN
        v_sec := NULL;
    END IF;

    FOR r IN
        -- Column names are quoted so they match the camelCase JSON keys exactly —
        -- unquoted identifiers fold to lowercase and would never match "studentId".
        SELECT x."studentId"                             AS student_id,
               LOWER(TRIM(COALESCE(x.outcome, '')))       AS outcome,
               NULLIF(TRIM(COALESCE(x."toClass", '')), '') AS to_class
        FROM jsonb_to_recordset(p_students) AS x("studentId" integer, outcome text, "toClass" text)
    LOOP
        DECLARE
            s core.students%ROWTYPE;
        BEGIN
            SELECT * INTO s
            FROM core.students
            WHERE student_id = r.student_id
              AND tenant_id  = p_tenant_id
              AND school_id  = p_school_id
            FOR UPDATE;

            IF NOT FOUND THEN
                v_skipped := v_skipped || ('#' || COALESCE(r.student_id::text, '?') || ' (not found)');
                CONTINUE;
            END IF;

            IF NOT s.is_active THEN
                v_skipped := v_skipped || (s.student_name || ' (already left)');
                CONTINUE;
            END IF;

            -- Guards a double submit: after a successful run the student sits
            -- on the target year, so a repeat finds nothing to move.
            IF TRIM(COALESCE(s.academic_year, '')) <> v_src THEN
                v_skipped := v_skipped || (s.student_name || ' (not in ' || v_src || ')');
                CONTINUE;
            END IF;

            v_outcome := CASE r.outcome
                            WHEN 'promote' THEN 'Promote'
                            WHEN 'retain'  THEN 'Retain'
                            WHEN 'passout' THEN 'PassOut'
                            ELSE NULL
                         END;
            IF v_outcome IS NULL THEN
                v_skipped := v_skipped || (s.student_name || ' (unknown outcome)');
                CONTINUE;
            END IF;

            SELECT COALESCE(SUM(l.amount_due - l.amount_paid - COALESCE(l.concession, 0)), 0)
            INTO v_dues
            FROM core.student_ledger l
            WHERE l.student_id = s.student_id;
            v_dues := GREATEST(v_dues, 0);

            -- What has fallen due by today. Holding a child back is about fees
            -- they owe now, not the months still ahead of the session.
            SELECT COALESCE(SUM(l.amount_due - l.amount_paid - COALESCE(l.concession, 0)), 0)
            INTO v_due_now
            FROM core.student_ledger l
            WHERE l.student_id = s.student_id
              AND (l.due_date IS NULL OR l.due_date::date <= CURRENT_DATE);

            -- The ledger is not year-scoped, so dues follow the student no
            -- matter what. Unticking the box therefore means "do not take the
            -- dues into the new session" -> those students must settle first.
            IF NOT p_carry_dues AND v_due_now > 0 AND v_outcome <> 'PassOut' THEN
                v_skipped := v_skipped || (s.student_name || ' (pending dues)');
                CONTINUE;
            END IF;

            -- 1. Work out where the student is going.
            IF v_outcome = 'Promote' THEN
                -- The student's rung on the ladder, read from the session they
                -- are leaving; fall back to the new session in case the old one
                -- was edited after they were admitted.
                SELECT display_order INTO v_cur_order
                FROM   academic.academic_classes
                WHERE  tenant_id = p_tenant_id
                  AND  school_id = p_school_id
                  AND  academic_year_id = COALESCE(v_src_year_id, v_tgt_year_id)
                  AND  class_name = s.class_name
                  AND  COALESCE(is_deleted, FALSE) = FALSE
                ORDER BY display_order, academic_class_id
                LIMIT 1;

                IF v_cur_order IS NULL THEN
                    SELECT display_order INTO v_cur_order
                    FROM   academic.academic_classes
                    WHERE  tenant_id = p_tenant_id
                      AND  school_id = p_school_id
                      AND  academic_year_id = v_tgt_year_id
                      AND  class_name = s.class_name
                      AND  COALESCE(is_deleted, FALSE) = FALSE
                    ORDER BY display_order, academic_class_id
                    LIMIT 1;
                END IF;

                IF v_cur_order IS NULL THEN
                    v_skipped := v_skipped || (s.student_name || ' (class ' || s.class_name || ' is not in the session setup)');
                    CONTINUE;
                END IF;

                IF r.to_class IS NOT NULL THEN
                    -- The office asked for a specific class (a double promotion,
                    -- 1st -> 3rd). Still has to be a real class in the TARGET
                    -- session, and still has to be ABOVE where they are now: this
                    -- operation only ever moves students up. Moving someone down
                    -- is a correction, and belongs on the student's own page where
                    -- it is one deliberate act rather than a bulk one.
                    SELECT display_order INTO v_pick_order
                    FROM   academic.academic_classes
                    WHERE  tenant_id = p_tenant_id
                      AND  school_id = p_school_id
                      AND  academic_year_id = v_tgt_year_id
                      AND  class_name = r.to_class
                      AND  COALESCE(is_deleted, FALSE) = FALSE
                      AND  COALESCE(is_active,  TRUE)  = TRUE
                    ORDER BY display_order, academic_class_id
                    LIMIT 1;

                    IF v_pick_order IS NULL THEN
                        v_skipped := v_skipped ||
                            (s.student_name || ' (chosen class ' || r.to_class || ' is not set up in ' || v_tgt || ')');
                        CONTINUE;
                    END IF;

                    IF v_pick_order <= v_cur_order THEN
                        v_skipped := v_skipped ||
                            (s.student_name || ' (' || r.to_class || ' is not above ' || s.class_name || ')');
                        CONTINUE;
                    END IF;

                    v_next := r.to_class;
                ELSE
                    -- Default: the next rung up. Read from the TARGET session, so a
                    -- student can only ever be moved into a class that exists there.
                    SELECT class_name INTO v_next
                    FROM   academic.academic_classes
                    WHERE  tenant_id = p_tenant_id
                      AND  school_id = p_school_id
                      AND  academic_year_id = v_tgt_year_id
                      AND  COALESCE(is_deleted, FALSE) = FALSE
                      AND  COALESCE(is_active,  TRUE)  = TRUE
                      AND  display_order > v_cur_order
                    ORDER BY display_order, academic_class_id
                    LIMIT 1;
                END IF;

                IF v_next IS NULL THEN
                    v_skipped := v_skipped || (s.student_name || ' (already in the final class — mark Pass Out)');
                    CONTINUE;
                END IF;

                v_to_class := v_next;

            ELSIF v_outcome = 'Retain' THEN
                v_to_class := s.class_name;

            ELSE
                v_to_class := NULL;   -- PassOut leaves the school; no class needed
            END IF;

            -- 2. A student may only land on a class + section that really exists
            --    in the target session. Carrying the old section forward blindly
            --    is how students used to end up in a section their new class has
            --    never had (1st-C -> 2nd-C, where 2nd only ever had A and B).
            IF v_outcome <> 'PassOut' THEN
                v_to_section := COALESCE(v_sec, s.section);

                IF NOT EXISTS (
                    SELECT 1
                    FROM   academic.academic_classes ac
                    WHERE  ac.tenant_id = p_tenant_id
                      AND  ac.school_id = p_school_id
                      AND  ac.academic_year_id = v_tgt_year_id
                      AND  ac.class_name = v_to_class
                      AND  COALESCE(ac.is_deleted, FALSE) = FALSE
                      AND  COALESCE(ac.is_active,  TRUE)  = TRUE
                ) THEN
                    v_skipped := v_skipped || (s.student_name || ' (' || v_to_class || ' is not set up in ' || v_tgt || ')');
                    CONTINUE;
                END IF;

                IF v_to_section IS NULL OR NOT EXISTS (
                    SELECT 1
                    FROM   academic.academic_class_sections acs
                    JOIN   academic.academic_classes ac
                           ON ac.academic_class_id = acs.academic_class_id
                    WHERE  ac.tenant_id = p_tenant_id
                      AND  ac.school_id = p_school_id
                      AND  ac.academic_year_id = v_tgt_year_id
                      AND  ac.class_name   = v_to_class
                      AND  acs.section_name = v_to_section
                      AND  COALESCE(ac.is_deleted,  FALSE) = FALSE
                      AND  COALESCE(acs.is_deleted, FALSE) = FALSE
                      AND  COALESCE(acs.is_active,  TRUE)  = TRUE
                ) THEN
                    v_skipped := v_skipped ||
                        (s.student_name || ' (section ' || COALESCE(v_to_section, '—') ||
                         ' does not exist in ' || v_to_class || ' for ' || v_tgt || ')');
                    CONTINUE;
                END IF;
            ELSE
                v_to_section := NULL;
            END IF;

            -- 3. Commit the move.
            --
            --    Two records are kept in step here: core.students carries the
            --    student's PRESENT position (overwritten), and
            --    core.student_enrolment gains a row per session so the position
            --    they are leaving is not lost. See student_enrolment.sql.
            -- Roll number in the new class: keep it, unless the student has none or
            -- someone already in that class-section uses it -- then the next free
            -- number (highest + 1). Renumbering a whole class is Students › Data Checks.
            v_roll := NULLIF(TRIM(COALESCE(s.roll_no, '')), '');
            IF v_outcome IN ('Promote', 'Retain') AND (v_roll IS NULL OR EXISTS (
                   SELECT 1 FROM core.students o
                    WHERE o.tenant_id = p_tenant_id AND o.school_id = p_school_id AND o.is_active
                      AND o.student_id <> s.student_id AND o.academic_year = v_tgt
                      AND o.class_name = v_to_class AND COALESCE(o.section, '') = COALESCE(v_to_section, '')
                      AND lower(TRIM(o.roll_no)) = lower(v_roll))) THEN
                -- counts those already moved in AND classmates of this run still to come,
                -- so a missing roll goes after everyone else's instead of taking roll 1
                SELECT (COALESCE(MAX(TRIM(x.roll_no)::int), 0) + 1)::text INTO v_roll
                  FROM (SELECT o.roll_no FROM core.students o
                         WHERE o.tenant_id = p_tenant_id AND o.school_id = p_school_id AND o.is_active
                           AND o.student_id <> s.student_id AND o.academic_year = v_tgt
                           AND o.class_name = v_to_class AND COALESCE(o.section, '') = COALESCE(v_to_section, '')
                        UNION ALL
                        SELECT o.roll_no FROM core.students o
                         WHERE o.student_id IN (SELECT (j->>'studentId')::int FROM jsonb_array_elements(p_students) j)
                           AND o.student_id <> s.student_id AND o.academic_year = s.academic_year
                           AND o.class_name = s.class_name AND COALESCE(o.section, '') = COALESCE(s.section, '')) x
                 WHERE TRIM(x.roll_no) ~ '^[0-9]{1,6}$';
            END IF;

            IF v_outcome = 'Promote' THEN
                UPDATE core.students
                SET class_name    = v_to_class,
                    roll_no       = v_roll,
                    section       = v_to_section,
                    academic_year = v_tgt,
                    updated_by    = p_action_user_id,
                    updated_at    = now()
                WHERE student_id = s.student_id;

                PERFORM core.fn_student_enrolment_close(
                    s.student_id, s.academic_year, 'Promoted', p_action_user_id);
                PERFORM core.fn_student_enrolment_open(
                    p_tenant_id, p_school_id, s.student_id,
                    v_tgt, v_to_class, v_to_section, v_roll, p_action_user_id);

                v_promoted := v_promoted + 1;

            ELSIF v_outcome = 'Retain' THEN
                UPDATE core.students
                SET section       = v_to_section,
                    roll_no       = v_roll,
                    academic_year = v_tgt,
                    updated_by    = p_action_user_id,
                    updated_at    = now()
                WHERE student_id = s.student_id;

                PERFORM core.fn_student_enrolment_close(
                    s.student_id, s.academic_year, 'Retained', p_action_user_id);
                PERFORM core.fn_student_enrolment_open(
                    p_tenant_id, p_school_id, s.student_id,
                    v_tgt, v_to_class, v_to_section, v_roll, p_action_user_id);

                v_retained := v_retained + 1;

            ELSE  -- PassOut: same shape as sp_student_exit, so they show up in
                  -- the Inactive list and stay eligible for a TC.
                UPDATE core.students
                SET status           = 'Passout',
                    is_active        = FALSE,
                    date_of_leaving  = CURRENT_DATE,
                    exit_recorded_by = p_action_user_id,
                    exit_recorded_at = now(),
                    updated_by       = p_action_user_id,
                    updated_at       = now()
                WHERE student_id = s.student_id;

                -- No new session opens; the last one just ends.
                PERFORM core.fn_student_enrolment_close(
                    s.student_id, s.academic_year, 'PassedOut', p_action_user_id);

                -- Same money rule as a manual exit: anything due after today
                -- is closed with a reason and the bus ends.
                PERFORM core.fn_student_leave_money(
                    p_tenant_id, p_school_id, s.student_id, CURRENT_DATE, p_action_user_id);

                v_passed := v_passed + 1;
            END IF;

            -- 4. Bill the new session (Promote and Retain).
            --
            --    The class's recurring fee structure for the TARGET session is
            --    billed exactly the way admission bills a plan
            --    (core.fn_student_bill_plan), from the session start. The
            --    admission fee and deposit are not charged again. Billing is
            --    once per student per session, so a repeated run never adds a
            --    second plan. Before this, promotion created no dues at all
            --    for the new year. Old unpaid dues are untouched: they carry.
            IF v_outcome IN ('Promote', 'Retain') THEN
                v_plan := core.fn_class_fee_plan(p_tenant_id, p_school_id, v_to_class, v_tgt);
                IF v_plan IS NULL THEN
                    v_unbilled := v_unbilled || (s.student_name || ' (' || v_to_class || ')');
                ELSIF core.fn_student_bill_plan(p_tenant_id, p_school_id, p_action_user_id,
                          s.student_id, v_tgt, COALESCE(v_tgt_start, CURRENT_DATE), v_plan) > 0 THEN
                    v_billed := v_billed + 1;
                END IF;

                -- A student who keeps a bus route is billed for it in the new
                -- session too, at the stop's current fare.
                v_route := NULL;
                SELECT route_id, stop_id INTO v_route, v_stop
                FROM core.student_transport
                WHERE student_id = s.student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
                  AND is_active = TRUE AND COALESCE(is_deleted, FALSE) = FALSE
                ORDER BY assignment_id DESC
                LIMIT 1;

                -- (not when the school's Transport module is off)
                IF v_route IS NOT NULL AND core.fn_module_on(p_tenant_id, p_school_id, 'transport') THEN
                    v_bus := 'promote_bus_' || s.student_id;
                    CALL core.sp_transport_assign_manage('SaveAssignment', p_tenant_id, p_school_id,
                         p_action_user_id, s.student_id, v_route, v_stop, v_tgt,
                         COALESCE(v_tgt_start, CURRENT_DATE), 12, v_bus);
                    CLOSE v_bus;
                END IF;
            END IF;

            INSERT INTO core.student_promotion_history (
                tenant_id, school_id, student_id,
                from_year, from_class, from_section,
                to_year, to_class, to_section,
                outcome, dues_carried, promoted_by)
            VALUES (
                p_tenant_id, p_school_id, s.student_id,
                s.academic_year, s.class_name, s.section,
                CASE WHEN v_outcome = 'PassOut' THEN s.academic_year ELSE v_tgt END,
                v_to_class, v_to_section,
                v_outcome, v_dues, p_action_user_id);
        END;
    END LOOP;

    IF v_promoted + v_retained + v_passed = 0 THEN
        RAISE EXCEPTION 'Nothing was promoted. %',
            COALESCE(NULLIF(array_to_string(v_skipped, '; '), ''), 'No matching students in ' || v_src || '.');
    END IF;

    OPEN p_result FOR
    SELECT TRUE                                   AS success,
           v_promoted                             AS promoted,
           v_retained                             AS retained,
           v_passed                               AS passed_out,
           COALESCE(array_length(v_skipped, 1), 0) AS skipped,
           array_to_string(v_skipped, '; ')       AS skipped_detail,
           v_promoted || ' promoted, ' || v_retained || ' retained, ' ||
           v_passed   || ' passed out. ' ||
           v_billed   || ' billed for ' || v_tgt || '.' ||
           CASE WHEN array_length(v_unbilled, 1) > 0
                THEN ' Not billed — no fee structure for ' || v_tgt || ': ' ||
                     array_to_string(v_unbilled, ', ') || '.'
                ELSE '' END                       AS message,
           v_billed                               AS billed;
    RETURN;
END;
$procedure$;
