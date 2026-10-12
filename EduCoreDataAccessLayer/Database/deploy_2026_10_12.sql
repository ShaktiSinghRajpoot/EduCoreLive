-- Bundle 2026-10-12: QA report fixes (High, Medium, Low). Run with:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_12.sql
-- Run BEFORE pushing the app: the new app calls sp_fee_day_close_list and the
-- GetMarkScope operation. No signatures change, so the running app keeps working.
-- Each proc is copied from the local DB (pg_get_functiondef); the source scripts are
-- fee_day_close.sql, student_master_fields.sql, fee_concession_cancel_report.sql,
-- sp_staff_manage.sql, enquiry_crm_manage.sql, exam_marks.sql, school_calendar.sql.

-- ===== core.sp_fee_day_close_list =====
CREATE OR REPLACE PROCEDURE core.sp_fee_day_close_list(IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_date date, INOUT p_result refcursor DEFAULT 'result_cursor'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_iso varchar(10);
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;
    v_iso := to_char(COALESCE(p_date, CURRENT_DATE), 'YYYY-MM-DD');

    OPEN p_result FOR
    SELECT dc.cashier_id,
           core.fn_user_display_name(dc.cashier_id)  AS cashier_name,
           dc.closed_at, dc.total_collected, dc.expected_cash, dc.counted_cash, dc.difference,
           (dc.reopened_at IS NULL)                  AS is_closed,
           dc.reopened_at,
           core.fn_user_display_name(dc.reopened_by) AS reopened_by_name,
           dc.reopen_reason
    FROM core.fee_day_close dc
    WHERE dc.tenant_id = p_tenant_id AND dc.school_id = p_school_id
      AND dc.close_date = v_iso
    ORDER BY (dc.reopened_at IS NULL) DESC, dc.closed_at DESC;
END;
$procedure$

;

-- ===== core.sp_admission_manage =====
CREATE OR REPLACE PROCEDURE core.sp_admission_manage(IN p_operation text, IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_student_id integer DEFAULT NULL::integer, IN p_admission_no text DEFAULT NULL::text, IN p_roll_no text DEFAULT NULL::text, IN p_student_name text DEFAULT NULL::text, IN p_gender text DEFAULT NULL::text, IN p_dob date DEFAULT NULL::date, IN p_class_name text DEFAULT NULL::text, IN p_section text DEFAULT NULL::text, IN p_academic_year text DEFAULT NULL::text, IN p_admission_date date DEFAULT NULL::date, IN p_guardian_name text DEFAULT NULL::text, IN p_mother_name text DEFAULT NULL::text, IN p_mobile text DEFAULT NULL::text, IN p_alt_mobile text DEFAULT NULL::text, IN p_address text DEFAULT NULL::text, IN p_blood_group text DEFAULT NULL::text, IN p_religion text DEFAULT NULL::text, IN p_category text DEFAULT NULL::text, IN p_nationality text DEFAULT NULL::text, IN p_mother_tongue text DEFAULT NULL::text, IN p_id_proof_no text DEFAULT NULL::text, IN p_apaar_id text DEFAULT NULL::text, IN p_udise_student_id text DEFAULT NULL::text, IN p_prev_school_name text DEFAULT NULL::text, IN p_prev_board text DEFAULT NULL::text, IN p_prev_class text DEFAULT NULL::text, IN p_prev_tc_no text DEFAULT NULL::text, IN p_father_occupation text DEFAULT NULL::text, IN p_father_qualification text DEFAULT NULL::text, IN p_father_email text DEFAULT NULL::text, IN p_mother_occupation text DEFAULT NULL::text, IN p_mother_qualification text DEFAULT NULL::text, IN p_mother_email text DEFAULT NULL::text, IN p_annual_income numeric DEFAULT NULL::numeric, IN p_documents jsonb DEFAULT NULL::jsonb, IN p_pay_today_total numeric DEFAULT 0, IN p_monthly_total numeric DEFAULT 0, IN p_yearly_total numeric DEFAULT 0, IN p_annual_total numeric DEFAULT 0, IN p_concession_type text DEFAULT NULL::text, IN p_concession_value numeric DEFAULT 0, IN p_concession_amount numeric DEFAULT 0, IN p_concession_reason text DEFAULT NULL::text, IN p_concession_cap numeric DEFAULT 100000, IN p_fee_plan_json jsonb DEFAULT NULL::jsonb, IN p_enquiry_id integer DEFAULT NULL::integer, IN p_page_number integer DEFAULT 1, IN p_page_size integer DEFAULT 10, IN p_search text DEFAULT NULL::text, IN p_filter_class text DEFAULT NULL::text, IN p_filter_section text DEFAULT NULL::text, IN p_filter_gender text DEFAULT NULL::text, IN p_filter_year text DEFAULT NULL::text, IN p_filter_status text DEFAULT NULL::text, INOUT p_result refcursor DEFAULT 'admission_cursor'::refcursor)
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
            v_admission_no, p_roll_no, p_student_name, p_gender, p_dob,
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
            v_year, p_class_name, p_section, p_roll_no, p_action_user_id);

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
$procedure$

;

-- ===== core.sp_fee_concession_cancel_register =====
CREATE OR REPLACE PROCEDURE core.sp_fee_concession_cancel_register(IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_from date, IN p_to date, INOUT p_concessions refcursor DEFAULT 'concessions_cursor'::refcursor, INOUT p_cancels refcursor DEFAULT 'cancels_cursor'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_from date := COALESCE(p_from, date_trunc('month', CURRENT_DATE)::date);
    v_to   date := COALESCE(p_to,   CURRENT_DATE);
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;

    OPEN p_concessions FOR
    SELECT p.receipt_no, p.payment_date, p.concession_total,
           COALESCE(p.concession_total, 0) + COALESCE(p.discount_amount, 0) AS concession_amount,
           COALESCE(NULLIF(TRIM(p.payment_type), ''), 'Fee') AS payment_type,
           p.discount_type, p.discount_value, p.discount_reason,
           p.discount_approved_by,   -- picked by the cashier; given_by_name is who entered it
           COALESCE(p.is_cancelled, FALSE) AS is_cancelled,
           core.fn_user_display_name(p.created_by) AS given_by_name,
           COALESCE(s.student_name, e.student_name, '—') AS student_name,
           COALESCE(s.admission_no,
                    CASE WHEN e.enquiry_id IS NOT NULL
                         THEN COALESCE(NULLIF(e.registration_number, ''), 'Registration') END,
                    '—') AS admission_no
    FROM core.fee_payments p
    LEFT JOIN core.students  s ON s.student_id = p.student_id
    LEFT JOIN core.enquiries e ON e.enquiry_id = p.enquiry_id
    WHERE p.tenant_id = p_tenant_id AND p.school_id = p_school_id
      AND COALESCE(p.concession_total, 0) + COALESCE(p.discount_amount, 0) > 0
      AND p.payment_date BETWEEN to_char(v_from, 'YYYY-MM-DD') AND to_char(v_to, 'YYYY-MM-DD')
    ORDER BY p.payment_date, p.payment_id;

    OPEN p_cancels FOR
    SELECT p.receipt_no, p.payment_date, p.amount,
           p.cancel_reason, p.cancel_authorized_by, p.cancelled_at,
           p.cancelled_by,
           core.fn_user_display_name(p.cancelled_by) AS cancelled_by_name,
           core.fn_user_display_name(p.created_by)   AS collected_by_name,
           COALESCE(s.student_name, e.student_name, '—') AS student_name,
           COALESCE(s.admission_no,
                    CASE WHEN e.enquiry_id IS NOT NULL
                         THEN COALESCE(NULLIF(e.registration_number, ''), 'Registration') END,
                    '—') AS admission_no
    FROM core.fee_payments p
    LEFT JOIN core.students  s ON s.student_id = p.student_id
    LEFT JOIN core.enquiries e ON e.enquiry_id = p.enquiry_id
    WHERE p.tenant_id = p_tenant_id AND p.school_id = p_school_id
      AND p.is_cancelled = TRUE
      AND p.cancelled_at::date BETWEEN v_from AND v_to
    ORDER BY p.cancelled_at DESC;
END;
$procedure$

;

-- ===== core.sp_staff_manage =====
CREATE OR REPLACE PROCEDURE core.sp_staff_manage(IN p_operation text, IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_staff_id integer, IN p_employee_code text, IN p_full_name text, IN p_gender text, IN p_dob date, IN p_mobile text, IN p_alt_mobile text, IN p_email text, IN p_blood_group text, IN p_address text, IN p_staff_type text, IN p_department text, IN p_designation text, IN p_joining_date date, IN p_qualification text, IN p_experience_years integer, IN p_status text, IN p_monthly_salary numeric, IN p_bank_account_no text, IN p_ifsc_code text, IN p_pan text, IN p_aadhaar text, IN p_create_login boolean, IN p_password_hash text, IN p_role_ids integer[], IN p_search text, IN p_status_filter text, INOUT p_result refcursor DEFAULT 'staff_cursor'::refcursor, IN p_last_working_date date DEFAULT NULL::date)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_staff_id    integer;
    v_user_id     integer;
    v_staff_type  text;
    v_old_roles   text;
    v_new_roles   text;
    v_admin_role  integer;
    v_had_admin   boolean;
    v_gets_admin  boolean;
    v_old_status  text;
    v_new_status  text;
    v_join        date;
    v_lwd         date;
    v_going_off   boolean := FALSE;
    v_coming_back boolean := FALSE;
BEGIN
    -- Multi-tenancy guard (tenant 1 = platform; real schools are tenant > 1).
    IF p_tenant_id IS NULL OR p_tenant_id <= 1 OR p_school_id IS NULL OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid tenant/school scope.';
    END IF;

    -- ---------------------------------------------------------------- LIST
    IF p_operation = 'LIST' THEN
        OPEN p_result FOR
        SELECT s.staff_id, s.public_id, s.employee_code, s.full_name, s.gender, s.dob,
               s.mobile, s.alt_mobile, s.email, s.blood_group, s.address,
               s.staff_type, s.department, s.designation, s.joining_date,
               s.qualification, s.experience_years, s.status,
               s.monthly_salary, s.bank_account_no, s.ifsc_code, s.pan, s.aadhaar,
               s.user_id, s.status_changed_at, s.last_working_date
        FROM   core.staff s
        WHERE  s.tenant_id = p_tenant_id
          AND  s.school_id = p_school_id
          AND  s.is_deleted = FALSE
          AND  (p_status_filter IS NULL OR p_status_filter = '' OR s.status = p_status_filter)
          AND  (p_search IS NULL OR p_search = ''
                OR s.full_name    ILIKE '%' || p_search || '%'
                OR s.employee_code ILIKE '%' || p_search || '%'
                OR s.designation  ILIKE '%' || p_search || '%')
        ORDER BY s.full_name;
        RETURN;
    END IF;

    -- ----------------------------------------------------------------- GET
    IF p_operation = 'GET' THEN
        OPEN p_result FOR
        SELECT s.staff_id, s.public_id, s.employee_code, s.full_name, s.gender, s.dob,
               s.mobile, s.alt_mobile, s.email, s.blood_group, s.address,
               s.staff_type, s.department, s.designation, s.joining_date,
               s.qualification, s.experience_years, s.status,
               s.monthly_salary, s.bank_account_no, s.ifsc_code, s.pan, s.aadhaar,
               s.user_id, s.status_changed_at, s.last_working_date
        FROM   core.staff s
        WHERE  s.tenant_id = p_tenant_id
          AND  s.school_id = p_school_id
          AND  s.staff_id  = p_staff_id
          AND  s.is_deleted = FALSE;
        RETURN;
    END IF;

    -- Every write below works on one staff row of THIS school. Find it first, so
    -- nothing (a login, a role) is created for a row that is not ours.
    IF p_operation IN ('UPDATE', 'DELETE', 'REACTIVATE') THEN
        SELECT user_id, status, NULLIF(joining_date, '')::date
          INTO v_user_id, v_old_status, v_join
        FROM core.staff
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND staff_id = p_staff_id AND is_deleted = FALSE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Staff member not found.';
        END IF;
    END IF;

    -- -------------------------------------------------------------- DELETE
    IF p_operation = 'DELETE' THEN
        IF v_old_status = 'Inactive' THEN
            RAISE EXCEPTION 'This staff member is already inactive.';
        END IF;

        v_lwd := COALESCE(p_last_working_date, CURRENT_DATE);
        IF v_lwd > CURRENT_DATE THEN
            RAISE EXCEPTION 'The last working day cannot be in the future. Deactivate on or after that day.';
        END IF;
        -- Someone hired for a future date who never joined: no working days at
        -- all, so no last working day (payroll then never pays them).
        IF p_last_working_date IS NULL AND v_join IS NOT NULL AND v_join > CURRENT_DATE THEN
            v_lwd := NULL;
        END IF;
        IF v_join IS NOT NULL AND v_lwd < v_join THEN
            RAISE EXCEPTION 'The last working day cannot be before the joining date (%).', to_char(v_join, 'DD Mon YYYY');
        END IF;

        UPDATE core.staff
        SET    status = 'Inactive', is_active = FALSE,
               status_changed_at = now(),
               last_working_date = to_char(v_lwd, 'YYYY-MM-DD'),
               updated_by = p_action_user_id, updated_at = now()
        WHERE  tenant_id = p_tenant_id AND school_id = p_school_id AND staff_id = p_staff_id;

        CALL core.sp_staff_login_switch(p_tenant_id, p_school_id, p_action_user_id, p_staff_id, v_user_id, FALSE);

        OPEN p_result FOR SELECT p_staff_id AS staff_id;
        RETURN;
    END IF;

    -- ---------------------------------------------------------- REACTIVATE
    -- Meant for a mistaken deactivation. A re-hire after a real gap should also
    -- get a new joining date on the Edit form, or payroll would see the gap as
    -- employed time.
    IF p_operation = 'REACTIVATE' THEN
        UPDATE core.staff
        SET    status = 'Active', is_active = TRUE,
               status_changed_at = now(),
               last_working_date = NULL,
               updated_by = p_action_user_id, updated_at = now()
        WHERE  tenant_id = p_tenant_id AND school_id = p_school_id AND staff_id = p_staff_id;

        CALL core.sp_staff_login_switch(p_tenant_id, p_school_id, p_action_user_id, p_staff_id, v_user_id, TRUE);

        OPEN p_result FOR SELECT p_staff_id AS staff_id;
        RETURN;
    END IF;

    -- ============================ INSERT / UPDATE ========================
    IF p_operation IN ('INSERT', 'UPDATE') THEN

        IF p_full_name IS NULL OR TRIM(p_full_name) = '' THEN
            RAISE EXCEPTION 'Staff full name is required.';
        END IF;

        -- Payroll pays a salary only for the statuses it knows; any other word
        -- would silently drop the person from payroll.
        v_new_status := COALESCE(NULLIF(TRIM(p_status), ''), v_old_status, 'Active');
        IF v_new_status NOT IN ('Active', 'On Leave', 'Inactive') THEN
            RAISE EXCEPTION 'Status must be Active, On Leave or Inactive.';
        END IF;
        IF p_operation = 'INSERT' AND v_new_status = 'Inactive' THEN
            RAISE EXCEPTION 'A new staff member starts Active or On Leave.';
        END IF;

        IF p_monthly_salary IS NOT NULL AND p_monthly_salary < 0 THEN
            RAISE EXCEPTION 'Monthly salary cannot be negative.';
        END IF;

        -- Employee code unique per school (when supplied), ignoring case and spaces.
        IF p_employee_code IS NOT NULL AND TRIM(p_employee_code) <> ''
           AND EXISTS (
                SELECT 1 FROM core.staff
                WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                  AND is_deleted = FALSE
                  AND UPPER(TRIM(employee_code)) = UPPER(TRIM(p_employee_code))
                  AND (p_operation = 'INSERT' OR staff_id <> p_staff_id)
           ) THEN
            RAISE EXCEPTION 'Employee code already exists.';
        END IF;

        -- Mobile and email unique among this school's current staff (not the row
        -- being edited, not deleted or Inactive people, so a re-hire still works).
        -- Mobile compares the last 10 digits, the same rule as the login phone.
        IF p_mobile IS NOT NULL AND TRIM(p_mobile) <> ''
           AND EXISTS (
                SELECT 1 FROM core.staff
                WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                  AND is_deleted = FALSE AND status <> 'Inactive'
                  AND RIGHT(regexp_replace(mobile, '\D', '', 'g'), 10)
                      = RIGHT(regexp_replace(p_mobile, '\D', '', 'g'), 10)
                  AND (p_operation = 'INSERT' OR staff_id <> p_staff_id)
           ) THEN
            RAISE EXCEPTION 'A staff member with this mobile already exists.';
        END IF;

        IF p_email IS NOT NULL AND TRIM(p_email) <> ''
           AND EXISTS (
                SELECT 1 FROM core.staff
                WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                  AND is_deleted = FALSE AND status <> 'Inactive'
                  AND LOWER(TRIM(email)) = LOWER(TRIM(p_email))
                  AND (p_operation = 'INSERT' OR staff_id <> p_staff_id)
           ) THEN
            RAISE EXCEPTION 'A staff member with this email already exists.';
        END IF;

        -- Staff Type is DERIVED from the chosen Designation (single source of
        -- truth) so it can never contradict the title, even if the form is
        -- bypassed. Falls back to whatever the caller sent if the designation
        -- has no bucket set.
        IF p_designation IS NOT NULL AND TRIM(p_designation) <> '' THEN
            SELECT staff_type INTO v_staff_type
            FROM   config.designations
            WHERE  tenant_id = p_tenant_id AND is_deleted = FALSE
              AND  LOWER(TRIM(name)) = LOWER(TRIM(p_designation))
            LIMIT 1;
        END IF;
        v_staff_type := COALESCE(v_staff_type, NULLIF(TRIM(p_staff_type), ''));
        IF v_staff_type IS NOT NULL AND v_staff_type NOT IN ('Teaching', 'Non-Teaching', 'Transport', 'Support') THEN
            RAISE EXCEPTION 'Invalid staff type.';
        END IF;

        -- Status flips through the Edit form behave exactly like Deactivate /
        -- Reactivate (see the header).
        IF p_operation = 'UPDATE' THEN
            v_going_off   := v_new_status = 'Inactive' AND v_old_status <> 'Inactive';
            v_coming_back := v_old_status = 'Inactive' AND v_new_status <> 'Inactive';
        END IF;

        -- The last working day is set when someone goes Inactive, and can be
        -- corrected later while they stay Inactive.
        IF v_new_status = 'Inactive' AND (v_going_off OR p_last_working_date IS NOT NULL) THEN
            v_lwd := COALESCE(p_last_working_date, CURRENT_DATE);
            IF v_lwd > CURRENT_DATE THEN
                RAISE EXCEPTION 'The last working day cannot be in the future. Deactivate on or after that day.';
            END IF;
            IF p_last_working_date IS NULL AND COALESCE(p_joining_date, v_join) > CURRENT_DATE THEN
                v_lwd := NULL;   -- never joined (see DELETE)
            END IF;
            IF COALESCE(p_joining_date, v_join) IS NOT NULL AND v_lwd < COALESCE(p_joining_date, v_join) THEN
                RAISE EXCEPTION 'The last working day cannot be before the joining date.';
            END IF;
        END IF;

        -- Optionally create a login user (only when none is linked yet).
        IF COALESCE(p_create_login, FALSE) = TRUE
           AND v_user_id IS NULL
           AND p_email IS NOT NULL AND TRIM(p_email) <> ''
           AND p_password_hash IS NOT NULL AND TRIM(p_password_hash) <> '' THEN

            -- Shared guard (Database/user_email_unique.sql) so this can't drift from
            -- the uq_user_email_active index. The old inline check missed is_deleted.
            IF core.fn_user_email_taken(p_email) THEN
                RAISE EXCEPTION 'A login with this email already exists.';
            END IF;

            -- Same rule as uq_user_phone_active (last 10 digits), so '+91 98390 73643'
            -- gets this message instead of a raw constraint error.
            IF p_mobile IS NOT NULL AND TRIM(p_mobile) <> ''
               AND core.fn_user_phone_taken(p_mobile) THEN
                RAISE EXCEPTION 'A login with this phone already exists.';
            END IF;

            INSERT INTO core.users
                (tenant_id, school_id, email, password_hash, must_change_password, is_active, created_by, created_at)
            VALUES
                (p_tenant_id, p_school_id, LOWER(TRIM(p_email)), p_password_hash, TRUE, TRUE, p_action_user_id, NOW())
            RETURNING user_id INTO v_user_id;

            INSERT INTO core.user_profiles
                (tenant_id, user_id, school_id, full_name, phone, designation, is_active, created_by, created_at)
            VALUES
                (p_tenant_id, v_user_id, p_school_id, TRIM(p_full_name),
                 NULLIF(TRIM(p_mobile), ''), NULLIF(TRIM(p_designation), ''), TRUE, p_action_user_id, NOW());

        END IF;

        -- Reset the password of an EXISTING login when a new hash is supplied (admin
        -- "reset password" on the edit form). Force a self-reset on next sign-in.
        IF p_operation = 'UPDATE'
           AND COALESCE(p_create_login, FALSE) = FALSE
           AND v_user_id IS NOT NULL
           AND p_password_hash IS NOT NULL AND TRIM(p_password_hash) <> '' THEN
            UPDATE core.users
            SET    password_hash = p_password_hash,
                   must_change_password = TRUE,
                   password_changed_at = now(),   -- ends the person's open sessions
                   updated_by = p_action_user_id,
                   updated_at = now()
            WHERE  user_id = v_user_id AND tenant_id = p_tenant_id;

            PERFORM core.fn_admin_audit(p_tenant_id, p_school_id, p_action_user_id, 'PASSWORD_RESET_BY_ADMIN',
                'Staff', 'core.users', v_user_id, format('Password reset for staff %s', p_staff_id));
        END IF;

        -- Assign / sync the login's role(s). A user's effective permissions are the
        -- UNION of all their roles. Runs for a freshly-created OR an existing login,
        -- so the People edit form is the single place to manage a person's access.
        IF v_user_id IS NOT NULL AND p_role_ids IS NOT NULL THEN
            -- Every id must be a live role of THIS tenant (and never the platform role).
            IF EXISTS (SELECT 1 FROM unnest(p_role_ids) AS rid
                       WHERE NOT EXISTS (SELECT 1 FROM config.roles r
                                         WHERE r.role_id = rid AND r.tenant_id = p_tenant_id
                                           AND r.is_deleted = FALSE AND r.role_code <> 'SUPER_ADMIN')) THEN
                RAISE EXCEPTION 'Role not found.';
            END IF;

            SELECT string_agg(r.role_code, ', ' ORDER BY r.role_code) INTO v_old_roles
            FROM core.user_roles ur JOIN config.roles r ON r.role_id = ur.role_id
            WHERE ur.tenant_id = p_tenant_id AND ur.user_id = v_user_id
              AND ur.is_deleted = FALSE AND ur.is_active = TRUE;
            SELECT string_agg(r.role_code, ', ' ORDER BY r.role_code) INTO v_new_roles
            FROM config.roles r WHERE r.role_id = ANY (p_role_ids);

            IF v_old_roles IS DISTINCT FROM v_new_roles THEN
                IF v_user_id = p_action_user_id THEN
                    RAISE EXCEPTION 'You cannot change your own roles. Ask another School Admin.';
                END IF;

                SELECT role_id INTO v_admin_role FROM config.roles
                WHERE tenant_id = p_tenant_id AND role_code = 'SCHOOL_ADMIN' AND is_deleted = FALSE
                ORDER BY role_id LIMIT 1;
                v_had_admin  := COALESCE(v_old_roles, '') ~ '(^|, )SCHOOL_ADMIN(,|$)';
                v_gets_admin := v_admin_role = ANY (p_role_ids);

                IF v_had_admin IS DISTINCT FROM v_gets_admin
                   AND NOT core.fn_user_is_school_admin(p_tenant_id, p_action_user_id) THEN
                    RAISE EXCEPTION 'Only a School Admin can grant or remove the School Admin role.';
                END IF;
                IF v_had_admin AND NOT v_gets_admin
                   AND core.fn_is_last_school_admin(p_school_id, v_user_id) THEN
                    RAISE EXCEPTION 'This is the last active School Admin of the school. Make someone else a School Admin first.';
                END IF;

                PERFORM core.fn_admin_audit(p_tenant_id, p_school_id, p_action_user_id, 'USER_ROLES_CHANGE',
                    'Staff', 'core.user_roles', v_user_id,
                    format('Roles: [%s] -> [%s]', COALESCE(v_old_roles, ''), COALESCE(v_new_roles, '')));
            END IF;

            -- drop roles no longer selected
            UPDATE core.user_roles
            SET is_deleted = TRUE, is_active = FALSE, is_primary = FALSE,
                updated_by = p_action_user_id, updated_at = now()
            WHERE tenant_id = p_tenant_id AND user_id = v_user_id AND is_deleted = FALSE
              AND NOT (role_id = ANY (p_role_ids));

            -- revive previously-removed roles that are selected again
            UPDATE core.user_roles
            SET is_deleted = FALSE, is_active = TRUE, school_id = p_school_id,
                updated_by = p_action_user_id, updated_at = now()
            WHERE tenant_id = p_tenant_id AND user_id = v_user_id AND is_deleted = TRUE
              AND role_id = ANY (p_role_ids);

            -- insert brand-new selections
            INSERT INTO core.user_roles
                (tenant_id, user_id, role_id, school_id, is_primary, is_active, created_by, created_at)
            SELECT p_tenant_id, v_user_id, rid, p_school_id, FALSE, TRUE, p_action_user_id, now()
            FROM   unnest(p_role_ids) AS rid
            WHERE  NOT EXISTS (
                SELECT 1 FROM core.user_roles ur
                WHERE ur.tenant_id = p_tenant_id AND ur.user_id = v_user_id AND ur.role_id = rid);

            -- keep exactly one primary among the active roles (lowest role_id)
            UPDATE core.user_roles SET is_primary = FALSE
            WHERE tenant_id = p_tenant_id AND user_id = v_user_id AND is_deleted = FALSE AND is_primary = TRUE;
            UPDATE core.user_roles SET is_primary = TRUE
            WHERE user_role_id = (
                SELECT user_role_id FROM core.user_roles
                WHERE tenant_id = p_tenant_id AND user_id = v_user_id AND is_deleted = FALSE AND is_active = TRUE
                ORDER BY role_id LIMIT 1);
        END IF;

        IF p_operation = 'INSERT' THEN
            INSERT INTO core.staff
                (tenant_id, school_id, employee_code, full_name, gender, dob,
                 mobile, alt_mobile, email, blood_group, address,
                 staff_type, department, designation, joining_date, qualification,
                 experience_years, status, monthly_salary, bank_account_no, ifsc_code,
                 pan, aadhaar, user_id, created_by, updated_by)
            VALUES
                (p_tenant_id, p_school_id, NULLIF(TRIM(p_employee_code), ''), TRIM(p_full_name), p_gender, p_dob,
                 NULLIF(TRIM(p_mobile), ''), NULLIF(TRIM(p_alt_mobile), ''), NULLIF(TRIM(p_email), ''), p_blood_group, p_address,
                 v_staff_type, p_department, p_designation, p_joining_date, p_qualification,
                 p_experience_years, v_new_status, p_monthly_salary, p_bank_account_no, p_ifsc_code,
                 p_pan, p_aadhaar, v_user_id, p_action_user_id, p_action_user_id)
            RETURNING staff_id INTO v_staff_id;
        ELSE
            UPDATE core.staff
            SET employee_code   = NULLIF(TRIM(p_employee_code), ''),
                full_name       = TRIM(p_full_name),
                gender          = p_gender,
                dob             = p_dob,
                mobile          = NULLIF(TRIM(p_mobile), ''),
                alt_mobile      = NULLIF(TRIM(p_alt_mobile), ''),
                email           = NULLIF(TRIM(p_email), ''),
                blood_group     = p_blood_group,
                address         = p_address,
                staff_type      = v_staff_type,
                department      = p_department,
                designation     = p_designation,
                joining_date    = p_joining_date,
                qualification   = p_qualification,
                experience_years = p_experience_years,
                status          = v_new_status,
                -- is_active always follows the status, whichever screen set it.
                is_active       = (v_new_status <> 'Inactive'),
                status_changed_at = CASE WHEN v_going_off OR v_coming_back THEN now()
                                         ELSE status_changed_at END,
                last_working_date = CASE WHEN v_lwd IS NOT NULL THEN to_char(v_lwd, 'YYYY-MM-DD')
                                         WHEN v_coming_back THEN NULL
                                         ELSE last_working_date END,
                monthly_salary  = p_monthly_salary,
                bank_account_no = p_bank_account_no,
                ifsc_code       = p_ifsc_code,
                pan             = p_pan,
                aadhaar         = p_aadhaar,
                user_id         = COALESCE(v_user_id, user_id),
                updated_by      = p_action_user_id,
                updated_at      = now()
            WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND staff_id = p_staff_id
            RETURNING staff_id INTO v_staff_id;

            IF v_going_off THEN
                CALL core.sp_staff_login_switch(p_tenant_id, p_school_id, p_action_user_id, p_staff_id, v_user_id, FALSE);
            ELSIF v_coming_back THEN
                CALL core.sp_staff_login_switch(p_tenant_id, p_school_id, p_action_user_id, p_staff_id, v_user_id, TRUE);
            END IF;
        END IF;

        OPEN p_result FOR SELECT v_staff_id AS staff_id;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation: %', p_operation;
END;
$procedure$

;

-- ===== core.sp_enquiry_crm_manage =====
CREATE OR REPLACE PROCEDURE core.sp_enquiry_crm_manage(IN p_operation text, IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_enquiry_id integer DEFAULT NULL::integer, IN p_student_name text DEFAULT NULL::text, IN p_gender text DEFAULT NULL::text, IN p_dob date DEFAULT NULL::date, IN p_class_name text DEFAULT NULL::text, IN p_session text DEFAULT NULL::text, IN p_interested_stream text DEFAULT NULL::text, IN p_parent_name text DEFAULT NULL::text, IN p_father_name text DEFAULT NULL::text, IN p_father_mobile text DEFAULT NULL::text, IN p_mother_name text DEFAULT NULL::text, IN p_mother_mobile text DEFAULT NULL::text, IN p_mobile text DEFAULT NULL::text, IN p_alt_mobile text DEFAULT NULL::text, IN p_city text DEFAULT NULL::text, IN p_area_locality text DEFAULT NULL::text, IN p_lead_source text DEFAULT NULL::text, IN p_referrer_name text DEFAULT NULL::text, IN p_referrer_mobile text DEFAULT NULL::text, IN p_priority text DEFAULT NULL::text, IN p_status text DEFAULT NULL::text, IN p_assigned_to_id integer DEFAULT NULL::integer, IN p_lost_reason text DEFAULT NULL::text, IN p_lost_to_school text DEFAULT NULL::text, IN p_next_followup_date date DEFAULT NULL::date, IN p_notes text DEFAULT NULL::text, IN p_estimated_fee numeric DEFAULT NULL::numeric, IN p_registration_number text DEFAULT NULL::text, IN p_registration_date date DEFAULT NULL::date, IN p_registration_fee_paid boolean DEFAULT false, IN p_parent_email text DEFAULT NULL::text, IN p_current_class text DEFAULT NULL::text, IN p_current_school text DEFAULT NULL::text, IN p_transport_required boolean DEFAULT false, IN p_whatsapp_number text DEFAULT NULL::text, IN p_page_number integer DEFAULT 1, IN p_page_size integer DEFAULT 10, IN p_search text DEFAULT NULL::text, IN p_filter_session text DEFAULT NULL::text, IN p_filter_priority text DEFAULT NULL::text, IN p_filter_class text DEFAULT NULL::text, IN p_filter_source text DEFAULT NULL::text, IN p_filter_pipeline text DEFAULT NULL::text, IN p_filter_assigned_to integer DEFAULT NULL::integer, IN p_filter_overdue boolean DEFAULT false, IN p_filter_today boolean DEFAULT false, IN p_sort_column text DEFAULT NULL::text, IN p_sort_dir text DEFAULT 'asc'::text, INOUT p_result refcursor DEFAULT 'enquiry_cursor'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_sort_col       TEXT;
    v_sort_asc       BOOLEAN;
    v_enquiry_id     INTEGER;
    v_status_before  VARCHAR(60);
    v_admission_id   INTEGER;
    v_today          DATE := CURRENT_DATE;
    v_same_mobile    INTEGER := 0;
BEGIN

    -- ── GetEnquiries (filtered + paginated) ──────────────────
    IF p_operation = 'GetEnquiries' THEN
        v_sort_col := LOWER(TRIM(COALESCE(p_sort_column, '')));
        v_sort_asc := LOWER(TRIM(COALESCE(p_sort_dir, 'asc'))) <> 'desc';

        OPEN p_result FOR
            WITH filtered AS (
                SELECT
                    e.enquiry_id,
                    e.student_name,
                    e.gender,
                    e.dob,
                    e.class_name,
                    e.session,
                    e.interested_stream,
                    COALESCE(e.father_name, e.parent_name) AS parent_name,
                    e.father_name,
                    e.father_mobile,
                    e.mother_name,
                    e.mother_mobile,
                    e.mobile,
                    e.alt_mobile,
                    e.city,
                    e.area_locality,
                    e.lead_source,
                    e.referrer_name,
                    e.priority,
                    e.status,
                    e.assigned_to_id,
                    e.lost_reason,
                    e.enquiry_date,
                    e.next_followup_date,
                    e.notes,
                    e.estimated_fee,
                    e.registration_number,
                    -- Derived from the money, not the stored flag (see
                    -- core.fn_registration_fee_is_paid in registration_fee_partial.sql).
                    COALESCE(core.fn_registration_fee_is_paid(e.tenant_id, e.school_id, e.enquiry_id), FALSE)
                                                                  AS registration_fee_paid,
                    -- Any registration receipt at all (live or cancelled): such an
                    -- enquiry is part of the money trail and cannot be deleted.
                    EXISTS (SELECT 1 FROM core.fee_payments fp
                             WHERE fp.tenant_id = e.tenant_id AND fp.school_id = e.school_id
                               AND fp.enquiry_id = e.enquiry_id)  AS has_fee_receipts,
                    e.admission_id,
                    e.parent_email,
                    e.current_class,
                    e.current_school,
                    e.transport_required,
                    e.whatsapp_number,
                    e.created_at,
                    e.updated_at,
                    (v_today - e.enquiry_date::date)              AS days_since_enquiry,
                    (SELECT COUNT(*)::INTEGER
                       FROM core.enquiry_followups f
                      WHERE f.enquiry_id = e.enquiry_id)   AS followup_count,
                    CASE
                        WHEN e.next_followup_date::date < v_today
                             AND e.status NOT IN ('Admission Confirmed','Not Interested','Dropped')
                        THEN TRUE ELSE FALSE
                    END AS is_overdue,
                    CASE
                        WHEN e.next_followup_date::date = v_today THEN TRUE ELSE FALSE
                    END AS is_today
                FROM core.enquiries e
                WHERE e.tenant_id = p_tenant_id
                  AND e.school_id = p_school_id
                  AND e.is_active = TRUE
                  AND (
                      p_search IS NULL OR TRIM(p_search) = ''
                      OR LOWER(e.student_name) LIKE '%' || LOWER(TRIM(p_search)) || '%'
                      OR LOWER(COALESCE(e.father_name, e.parent_name, ''))
                                               LIKE '%' || LOWER(TRIM(p_search)) || '%'
                      OR e.mobile              LIKE '%' || TRIM(p_search) || '%'
                      OR COALESCE(e.father_mobile,'') LIKE '%' || TRIM(p_search) || '%'
                  )
                  AND (p_filter_session    IS NULL OR TRIM(p_filter_session)  = '' OR LOWER(e.session)     = LOWER(TRIM(p_filter_session)))
                  AND (p_filter_priority   IS NULL OR TRIM(p_filter_priority) = '' OR LOWER(e.priority)    = LOWER(TRIM(p_filter_priority)))
                  AND (p_filter_class      IS NULL OR TRIM(p_filter_class)    = '' OR LOWER(e.class_name)  = LOWER(TRIM(p_filter_class)))
                  AND (p_filter_source     IS NULL OR TRIM(p_filter_source)   = '' OR LOWER(e.lead_source) = LOWER(TRIM(p_filter_source)))
                  AND (p_filter_assigned_to IS NULL OR e.assigned_to_id = p_filter_assigned_to)
                  AND (
                      p_filter_pipeline IS NULL OR TRIM(p_filter_pipeline) = '' OR p_filter_pipeline = 'all'
                      OR (p_filter_pipeline = 'new'           AND e.status = 'New')
                      OR (p_filter_pipeline = 'followup'      AND e.status = 'Follow-up Pending')
                      OR (p_filter_pipeline = 'interested'    AND e.status = 'Interested')
                      OR (p_filter_pipeline = 'campusvisit'   AND e.status = 'Campus Visit Scheduled')
                      OR (p_filter_pipeline = 'registered'    AND e.status = 'Registration Done')
                      OR (p_filter_pipeline = 'admitted'      AND e.status = 'Admission Confirmed')
                      OR (p_filter_pipeline = 'notinterested' AND e.status IN ('Not Interested','Dropped'))
                  )
                  AND (
                      NOT COALESCE(p_filter_overdue, FALSE) OR
                      (e.next_followup_date::date < v_today AND e.status NOT IN ('Admission Confirmed','Not Interested','Dropped'))
                  )
                  AND (NOT COALESCE(p_filter_today, FALSE) OR e.next_followup_date::date = v_today)
            )
            SELECT *, COUNT(*) OVER() AS total_count
            FROM filtered
            ORDER BY
                -- Whitelisted, injection-safe sort (no dynamic SQL).
                CASE WHEN v_sort_col = 'name'    AND v_sort_asc     THEN student_name       END ASC,
                CASE WHEN v_sort_col = 'name'    AND NOT v_sort_asc THEN student_name       END DESC,
                CASE WHEN v_sort_col = 'class'   AND v_sort_asc     THEN class_name         END ASC,
                CASE WHEN v_sort_col = 'class'   AND NOT v_sort_asc THEN class_name         END DESC,
                CASE WHEN v_sort_col = 'status'  AND v_sort_asc     THEN status             END ASC,
                CASE WHEN v_sort_col = 'status'  AND NOT v_sort_asc THEN status             END DESC,
                CASE WHEN v_sort_col = 'source'  AND v_sort_asc     THEN lead_source        END ASC,
                CASE WHEN v_sort_col = 'source'  AND NOT v_sort_asc THEN lead_source        END DESC,
                CASE WHEN v_sort_col = 'nextfu'  AND v_sort_asc     THEN next_followup_date END ASC,
                CASE WHEN v_sort_col = 'nextfu'  AND NOT v_sort_asc THEN next_followup_date END DESC,
                CASE WHEN v_sort_col = 'age'     AND v_sort_asc     THEN created_at         END ASC,
                CASE WHEN v_sort_col = 'age'     AND NOT v_sort_asc THEN created_at         END DESC,
                -- Default / tie-breaker: newest enquiry first. enquiry_id keeps the
                -- order stable across pages when two rows share a created_at.
                created_at DESC, enquiry_id DESC
            LIMIT  COALESCE(p_page_size,   10)
            OFFSET (COALESCE(p_page_number, 1) - 1) * COALESCE(p_page_size, 10);
        RETURN;

    -- ── GetKpiStats ───────────────────────────────────────────
    ELSIF p_operation = 'GetKpiStats' THEN
        OPEN p_result FOR
            SELECT
                COUNT(*) AS total_leads,
                COUNT(*) FILTER (WHERE next_followup_date::date = v_today) AS due_today,
                COUNT(*) FILTER (WHERE next_followup_date::date < v_today
                                   AND status NOT IN ('Admission Confirmed','Not Interested','Dropped')) AS overdue_count,
                COUNT(*) FILTER (WHERE status = 'Campus Visit Scheduled') AS campus_visits,
                COUNT(*) FILTER (WHERE status = 'Admission Confirmed') AS admitted,
                COUNT(*) FILTER (WHERE status = 'New') AS cnt_new,
                COUNT(*) FILTER (WHERE status = 'Follow-up Pending') AS cnt_followup,
                COUNT(*) FILTER (WHERE status = 'Interested') AS cnt_interested,
                COUNT(*) FILTER (WHERE status = 'Campus Visit Scheduled')AS cnt_campusvisit,
                COUNT(*) FILTER (WHERE status = 'Registration Done') AS cnt_registered,
                COUNT(*) FILTER (WHERE status IN ('Not Interested','Dropped')) AS cnt_not_interested,
                CASE WHEN COUNT(*) = 0 THEN 0::NUMERIC
                     ELSE ROUND(COUNT(*) FILTER (WHERE status = 'Admission Confirmed') * 100.0 / COUNT(*), 1)
                END AS conversion_rate
            FROM core.enquiries
            WHERE tenant_id = p_tenant_id
              AND school_id = p_school_id
              AND is_active = TRUE;
        RETURN;

    -- ── GetEnquiryById ────────────────────────────────────────
    ELSIF p_operation = 'GetEnquiryById' THEN
        OPEN p_result FOR
            SELECT
                e.*,
                COALESCE(e.father_name, e.parent_name) AS derived_parent_name,
                -- e.* carries the stored flag; screens use this derived one.
                COALESCE(core.fn_registration_fee_is_paid(e.tenant_id, e.school_id, e.enquiry_id), FALSE)
                                                       AS fee_paid_derived,
                EXISTS (SELECT 1 FROM core.fee_payments fp
                         WHERE fp.tenant_id = e.tenant_id AND fp.school_id = e.school_id
                           AND fp.enquiry_id = e.enquiry_id) AS has_fee_receipts,
                (v_today - e.enquiry_date::date)              AS days_since_enquiry,
                (SELECT COUNT(*)::INTEGER FROM core.enquiry_followups f
                  WHERE f.enquiry_id = e.enquiry_id)   AS followup_count,
                FALSE AS is_overdue,
                FALSE AS is_today,
                0     AS total_count
            FROM core.enquiries e
            WHERE e.enquiry_id = p_enquiry_id
              AND e.tenant_id  = p_tenant_id
              AND e.school_id  = p_school_id
              AND e.is_active  = TRUE;
        RETURN;

    -- ── SaveEnquiry ───────────────────────────────────────────
    ELSIF p_operation = 'SaveEnquiry' THEN
        IF p_enquiry_id IS NULL OR p_enquiry_id = 0 THEN
            INSERT INTO core.enquiries (
                tenant_id, school_id,
                student_name, gender, dob,
                class_name, session, interested_stream,
                parent_name, father_name, father_mobile,
                mother_name, mother_mobile,
                mobile, alt_mobile,
                city, area_locality,
                lead_source, referrer_name, referrer_mobile,
                priority, status, assigned_to_id,
                enquiry_date, next_followup_date, notes,
                parent_email, current_class, current_school,
                transport_required, whatsapp_number,
                created_by, updated_by
            ) VALUES (
                p_tenant_id, p_school_id,
                p_student_name, p_gender, p_dob,
                p_class_name, p_session, p_interested_stream,
                COALESCE(p_father_name, p_parent_name),
                p_father_name, p_father_mobile,
                p_mother_name, p_mother_mobile,
                p_mobile, p_alt_mobile,
                p_city, p_area_locality,
                COALESCE(p_lead_source, 'Walk-in'),
                p_referrer_name, p_referrer_mobile,
                COALESCE(p_priority, 'Warm'),
                COALESCE(p_status, 'New'),
                p_assigned_to_id,
                v_today, p_next_followup_date, p_notes,
                p_parent_email, p_current_class, p_current_school,
                COALESCE(p_transport_required, FALSE), p_whatsapp_number,
                p_action_user_id, p_action_user_id
            )
            RETURNING enquiry_id INTO v_enquiry_id;

            INSERT INTO core.enquiry_status_history (
                enquiry_id, tenant_id, school_id,
                status_from, status_to, change_note, changed_by
            ) VALUES (
                v_enquiry_id, p_tenant_id, p_school_id,
                NULL, COALESCE(p_status, 'New'), 'Enquiry created', p_action_user_id
            );

            -- Siblings share a parent mobile, so a match is never blocked -- it is
            -- returned so the page can warn "possible duplicate". Counts other open
            -- enquiries (admitted ones are counted as the student) and active students.
            IF NULLIF(TRIM(p_mobile), '') IS NOT NULL THEN
                SELECT (SELECT COUNT(*) FROM core.enquiries e
                         WHERE e.tenant_id = p_tenant_id AND e.school_id = p_school_id
                           AND e.is_active = TRUE AND e.admission_id IS NULL
                           AND e.enquiry_id <> v_enquiry_id
                           AND TRIM(p_mobile) IN (TRIM(e.mobile), TRIM(e.father_mobile), TRIM(e.mother_mobile)))
                     + (SELECT COUNT(*) FROM core.students s
                         WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id
                           AND s.is_active = TRUE
                           AND TRIM(p_mobile) IN (TRIM(s.mobile), TRIM(s.alt_mobile)))
                  INTO v_same_mobile;
            END IF;
        ELSE
            SELECT status INTO v_status_before
            FROM core.enquiries
            WHERE enquiry_id = p_enquiry_id
              AND tenant_id  = p_tenant_id
              AND school_id  = p_school_id
              AND is_active  = TRUE;

            UPDATE core.enquiries SET
                student_name          = COALESCE(p_student_name,        student_name),
                gender                = COALESCE(p_gender,              gender),
                dob                   = COALESCE(p_dob::text,                 dob),
                class_name            = COALESCE(p_class_name,          class_name),
                session               = COALESCE(p_session,             session),
                interested_stream     = p_interested_stream,
                parent_name           = COALESCE(p_father_name, p_parent_name, parent_name),
                father_name           = COALESCE(p_father_name,         father_name),
                father_mobile         = COALESCE(p_father_mobile,       father_mobile),
                mother_name           = p_mother_name,
                mother_mobile         = p_mother_mobile,
                mobile                = COALESCE(p_mobile,              mobile),
                alt_mobile            = p_alt_mobile,
                city                  = p_city,
                area_locality         = p_area_locality,
                lead_source           = COALESCE(p_lead_source,         lead_source),
                referrer_name         = p_referrer_name,
                referrer_mobile       = p_referrer_mobile,
                priority              = COALESCE(p_priority,            priority),
                status                = COALESCE(p_status,              status),
                assigned_to_id        = p_assigned_to_id,
                -- lost_reason means "why this enquiry is lost RIGHT NOW". Keeping the
                -- old value when a lead is revived left an Interested — or eventually
                -- Admitted — enquiry still carrying "too far", which any why-we-lose-leads
                -- report would count. The full trail lives in enquiry_status_history;
                -- this column tracks the current state.
                lost_reason           = CASE WHEN p_status IN ('Not Interested','Dropped')
                                             THEN COALESCE(p_lost_reason, lost_reason)
                                             WHEN p_status IS NOT NULL THEN NULL
                                             ELSE lost_reason END,
                next_followup_date    = p_next_followup_date,
                notes                 = p_notes,
                estimated_fee         = p_estimated_fee,
                registration_number   = COALESCE(p_registration_number, registration_number),
                registration_date     = COALESCE(p_registration_date::text,   registration_date),
                -- registration_fee_paid is NOT written here: an edit form must never
                -- be able to mark a fee paid. It follows the receipts.
                parent_email          = p_parent_email,
                current_class         = p_current_class,
                current_school        = p_current_school,
                transport_required    = COALESCE(p_transport_required,  transport_required),
                whatsapp_number       = p_whatsapp_number,
                updated_by            = p_action_user_id,
                updated_at            = NOW()
            WHERE enquiry_id = p_enquiry_id
              AND tenant_id  = p_tenant_id
              AND school_id  = p_school_id
              AND is_active  = TRUE
            RETURNING enquiry_id INTO v_enquiry_id;

            IF p_status IS NOT NULL AND p_status IS DISTINCT FROM v_status_before THEN
                INSERT INTO core.enquiry_status_history (
                    enquiry_id, tenant_id, school_id,
                    status_from, status_to, change_note, changed_by
                ) VALUES (
                    v_enquiry_id, p_tenant_id, p_school_id,
                    v_status_before, p_status, p_notes, p_action_user_id
                );
            END IF;
        END IF;

        OPEN p_result FOR SELECT COALESCE(v_enquiry_id, 0) AS enquiry_id,
                                 v_same_mobile AS same_mobile_count;
        RETURN;

    -- ── UpdateStatus ──────────────────────────────────────────
    ELSIF p_operation = 'UpdateStatus' THEN
        SELECT status INTO v_status_before
        FROM core.enquiries
        WHERE enquiry_id = p_enquiry_id
          AND tenant_id  = p_tenant_id
          AND school_id  = p_school_id
          AND is_active  = TRUE;

        IF v_status_before = 'Admission Confirmed' THEN
            OPEN p_result FOR
                SELECT 0 AS success, 'Status cannot be changed after Admission Confirmed.' AS message;
            RETURN;
        END IF;

        UPDATE core.enquiries SET
            status      = p_status,
            -- Same rule as SaveEnquiry: a revived lead stops being "lost for" anything.
            lost_reason = CASE WHEN p_status IN ('Not Interested','Dropped')
                               THEN COALESCE(p_lost_reason, lost_reason)
                               ELSE NULL END,
            updated_by  = p_action_user_id,
            updated_at  = NOW()
        WHERE enquiry_id = p_enquiry_id
          AND tenant_id  = p_tenant_id
          AND school_id  = p_school_id
          AND is_active  = TRUE;

        IF p_status IS DISTINCT FROM v_status_before THEN
            INSERT INTO core.enquiry_status_history (
                enquiry_id, tenant_id, school_id,
                status_from, status_to, change_note, changed_by
            ) VALUES (
                p_enquiry_id, p_tenant_id, p_school_id,
                v_status_before, p_status, p_notes, p_action_user_id
            );
        END IF;

        OPEN p_result FOR SELECT 1 AS success, 'Status updated.' AS message;
        RETURN;

    -- ── DeleteEnquiry ─────────────────────────────────────────
    -- A soft delete (is_active = FALSE). Refused when the enquiry is part of the
    -- money trail: once admitted, or once any registration receipt exists, the
    -- row is what the receipts, the Registrations list and the student's record
    -- point back to -- deleting it hid the only place a receipt could be
    -- reprinted. Withdraw the registration instead. The delete itself is written
    -- to the status history, so who removed a lead, and when, is on record.
    ELSIF p_operation = 'DeleteEnquiry' THEN
        SELECT status, admission_id INTO v_status_before, v_admission_id
        FROM core.enquiries
        WHERE enquiry_id = p_enquiry_id
          AND tenant_id  = p_tenant_id
          AND school_id  = p_school_id
          AND is_active  = TRUE
        FOR UPDATE;

        IF NOT FOUND THEN
            OPEN p_result FOR SELECT 0 AS success, 'Enquiry not found.' AS message;
            RETURN;
        END IF;

        IF v_admission_id IS NOT NULL THEN
            OPEN p_result FOR SELECT 0 AS success,
                'This enquiry is already admitted and cannot be deleted.' AS message;
            RETURN;
        END IF;

        IF EXISTS (SELECT 1 FROM core.fee_payments
                    WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                      AND enquiry_id = p_enquiry_id) THEN
            OPEN p_result FOR SELECT 0 AS success,
                'A registration fee receipt exists for this enquiry, so it cannot be deleted. Cancel the registration instead.' AS message;
            RETURN;
        END IF;

        UPDATE core.enquiries SET
            is_active  = FALSE,
            updated_by = p_action_user_id,
            updated_at = NOW()
        WHERE enquiry_id = p_enquiry_id
          AND tenant_id  = p_tenant_id
          AND school_id  = p_school_id;

        INSERT INTO core.enquiry_status_history (
            enquiry_id, tenant_id, school_id,
            status_from, status_to, change_note, changed_by
        ) VALUES (
            p_enquiry_id, p_tenant_id, p_school_id,
            v_status_before, 'Deleted', 'Enquiry deleted', p_action_user_id
        );

        OPEN p_result FOR SELECT 1 AS success, 'Enquiry deleted.' AS message;
        RETURN;

    END IF;

    -- Fallback: no operation matched
    OPEN p_result FOR SELECT 0 AS enquiry_id WHERE FALSE;

END;
$procedure$

;

-- ===== academic.sp_school_admin_exam_marks_manage =====
CREATE OR REPLACE PROCEDURE academic.sp_school_admin_exam_marks_manage(IN p_operation character varying, IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_exam_id integer DEFAULT NULL::integer, IN p_academic_class_id integer DEFAULT NULL::integer, IN p_subject_id integer DEFAULT NULL::integer, IN p_section character varying DEFAULT NULL::character varying, IN p_items text DEFAULT NULL::text, IN p_finalize boolean DEFAULT false, INOUT p_result refcursor DEFAULT 'exam_marks_cursor'::refcursor, INOUT p_result2 refcursor DEFAULT 'exam_marks_cursor2'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_section text;
    v_year_id integer;
    v_max     numeric;
    v_pass    numeric;
    v_final   boolean;
    v_items   jsonb;
    v_item    jsonb;
    v_sid     integer;
    v_marks   numeric;
    v_absent  boolean;
    v_name    text;
    v_enrol   integer;
    v_saved   integer := 0;
    v_added   integer := 0;
    v_blank   integer := 0;
    v_status  text;
    v_results text;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    v_section := COALESCE(TRIM(p_section), '');

    -- Every operation works on one exam; resolve its academic year once.
    IF COALESCE(p_exam_id, 0) > 0 THEN
        SELECT academic_year_id, status, results_status INTO v_year_id, v_status, v_results
        FROM academic.exams
        WHERE exam_id   = p_exam_id
          AND tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND NOT is_deleted;

        IF v_year_id IS NULL THEN
            RAISE EXCEPTION 'That exam was not found.';
        END IF;
    END IF;

    -- Operations from GetClassSetup down all need a class that is on the exam.
    IF p_operation IN ('GetClassSetup', 'GetSheet', 'SaveMarks', 'ReopenSheet') THEN
        IF COALESCE(p_academic_class_id, 0) <= 0 THEN
            RAISE EXCEPTION 'Pick a class first.';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM academic.exam_subjects
                       WHERE exam_id = p_exam_id
                         AND academic_class_id = p_academic_class_id) THEN
            RAISE EXCEPTION 'That class is not part of this exam.';
        END IF;
    END IF;

    IF p_operation = 'GetExamClasses' THEN

        -- The classes this exam covers — the Class dropdown.
        OPEN p_result FOR
        SELECT es.academic_class_id,
               c.class_name,
               COUNT(*)::int AS subject_count
        FROM academic.exam_subjects es
        JOIN academic.academic_classes c ON c.academic_class_id = es.academic_class_id
        WHERE es.exam_id   = p_exam_id
          AND es.tenant_id = p_tenant_id
          AND es.school_id = p_school_id
        GROUP BY es.academic_class_id, c.class_name, c.display_order
        ORDER BY c.display_order, c.class_name;

        OPEN p_result2 FOR SELECT 1 WHERE FALSE;

    ELSIF p_operation = 'GetClassSetup' THEN

        -- That class's datesheet — the Subject dropdown and its marks scale.
        OPEN p_result FOR
        SELECT es.subject_id, s.subject_name, es.exam_date, es.start_time, es.end_time,
               es.max_marks, es.pass_marks
        FROM academic.exam_subjects es
        JOIN academic.school_subjects s ON s.subject_id = es.subject_id
        WHERE es.exam_id           = p_exam_id
          AND es.academic_class_id = p_academic_class_id
          AND es.tenant_id         = p_tenant_id
          AND es.school_id         = p_school_id
        ORDER BY es.display_order, s.subject_name;

        -- Sections that actually have students enrolled in this class that year,
        -- narrowed to the exam's chosen sections when it targets specific ones.
        -- No exam_class_sections rows for this (exam, class) = the whole class.
        OPEN p_result2 FOR
        SELECT COALESCE(TRIM(e.section), '') AS section, COUNT(*)::int AS student_count
        FROM core.student_enrolment e
        WHERE e.tenant_id = p_tenant_id
          AND e.school_id = p_school_id
          AND e.academic_year_id  = v_year_id
          AND e.academic_class_id = p_academic_class_id
          AND COALESCE(e.status, '') <> 'Left'
          AND (NOT EXISTS (SELECT 1 FROM academic.exam_class_sections x
                           WHERE x.exam_id = p_exam_id
                             AND x.academic_class_id = p_academic_class_id)
               OR EXISTS (SELECT 1 FROM academic.exam_class_sections x
                          WHERE x.exam_id = p_exam_id
                            AND x.academic_class_id = p_academic_class_id
                            AND x.section = COALESCE(TRIM(e.section), '')))
        GROUP BY COALESCE(TRIM(e.section), '')
        ORDER BY 1;

    ELSIF p_operation = 'GetSheet' THEN

        SELECT es.max_marks, es.pass_marks INTO v_max, v_pass
        FROM academic.exam_subjects es
        WHERE es.exam_id = p_exam_id
          AND es.academic_class_id = p_academic_class_id
          AND es.subject_id = p_subject_id;

        IF v_max IS NULL THEN
            RAISE EXCEPTION 'That subject is not on this class''s datesheet.';
        END IF;

        OPEN p_result FOR
        SELECT
            r.out_student_id   AS student_id,
            r.out_roll_no      AS roll_no,
            r.out_student_name AS student_name,
            r.out_gender       AS gender,
            m.marks_obtained,
            COALESCE(m.is_absent, FALSE) AS is_absent,
            (m.exam_mark_id IS NOT NULL) AS has_mark
        FROM academic.fn_exam_sheet_roster(p_tenant_id, p_school_id, v_year_id, p_academic_class_id, v_section) r
        LEFT JOIN academic.exam_marks m
               ON m.exam_id    = p_exam_id
              AND m.subject_id = p_subject_id
              AND m.student_id = r.out_student_id;

        OPEN p_result2 FOR
        SELECT
            v_max  AS max_marks,
            v_pass AS pass_marks,
            (SELECT es.exam_date FROM academic.exam_subjects es
             WHERE es.exam_id = p_exam_id
               AND es.academic_class_id = p_academic_class_id
               AND es.subject_id = p_subject_id) AS exam_date,
            (SELECT es.start_time FROM academic.exam_subjects es
             WHERE es.exam_id = p_exam_id
               AND es.academic_class_id = p_academic_class_id
               AND es.subject_id = p_subject_id) AS start_time,
            (SELECT es.end_time FROM academic.exam_subjects es
             WHERE es.exam_id = p_exam_id
               AND es.academic_class_id = p_academic_class_id
               AND es.subject_id = p_subject_id) AS end_time,
            (SELECT s.subject_name FROM academic.school_subjects s
             WHERE s.subject_id = p_subject_id) AS subject_name,
            COALESCE(sh.is_finalized, FALSE) AS is_finalized,
            sh.finalized_at,
            (v_results = 'Published') AS results_published
        FROM (SELECT 1) x
        LEFT JOIN academic.exam_mark_sheets sh
               ON sh.exam_id           = p_exam_id
              AND sh.academic_class_id = p_academic_class_id
              AND sh.subject_id        = p_subject_id
              AND sh.section           = v_section;

    ELSIF p_operation = 'SaveMarks' THEN

        SELECT es.max_marks, es.pass_marks INTO v_max, v_pass
        FROM academic.exam_subjects es
        WHERE es.exam_id = p_exam_id
          AND es.academic_class_id = p_academic_class_id
          AND es.subject_id = p_subject_id;

        IF v_max IS NULL THEN
            RAISE EXCEPTION 'That subject is not on this class''s datesheet.';
        END IF;

        SELECT COALESCE(is_finalized, FALSE) INTO v_final
        FROM academic.exam_mark_sheets
        WHERE exam_id           = p_exam_id
          AND academic_class_id = p_academic_class_id
          AND subject_id        = p_subject_id
          AND section           = v_section;

        -- Published results are a record parents have seen; they change only
        -- after someone unpublishes them (with a reason, logged).
        IF v_results = 'Published' THEN
            RAISE EXCEPTION 'The results of this exam are published, so its marks are locked. Unpublish the results first.';
        END IF;

        IF COALESCE(v_final, FALSE) THEN
            RAISE EXCEPTION 'These marks are finalized. Ask a school admin to reopen the sheet.';
        END IF;

        -- A draft datesheet is still being built; the Marks Entry page hides
        -- drafts, and the server holds the same line.
        IF v_status IS DISTINCT FROM 'Published' THEN
            RAISE EXCEPTION 'This exam is still a draft. Publish it before entering marks.';
        END IF;

        -- An exam that targets specific sections of this class takes marks only
        -- for those sections (no exam_class_sections rows = the whole class).
        IF EXISTS (SELECT 1 FROM academic.exam_class_sections x
                   WHERE x.exam_id = p_exam_id AND x.academic_class_id = p_academic_class_id)
           AND NOT EXISTS (SELECT 1 FROM academic.exam_class_sections x
                           WHERE x.exam_id = p_exam_id AND x.academic_class_id = p_academic_class_id
                             AND LOWER(x.section) = LOWER(v_section)) THEN
            RAISE EXCEPTION 'This exam is not held for section % of this class.',
                CASE WHEN v_section = '' THEN '(none)' ELSE v_section END;
        END IF;

        v_items := COALESCE(NULLIF(p_items, ''), '[]')::jsonb;

        FOR v_item IN SELECT value FROM jsonb_array_elements(v_items)
        LOOP
            v_sid := NULLIF(v_item->>'studentId', '')::int;
            CONTINUE WHEN v_sid IS NULL;

            v_absent := COALESCE((v_item->>'absent')::boolean, FALSE);
            v_marks  := CASE WHEN v_absent THEN NULL
                             ELSE NULLIF(v_item->>'marks', '')::numeric END;

            -- Only students actually on this sheet's roster.
            SELECT r.out_student_name, r.out_enrolment_id INTO v_name, v_enrol
            FROM academic.fn_exam_sheet_roster(p_tenant_id, p_school_id, v_year_id, p_academic_class_id, v_section) r
            WHERE r.out_student_id = v_sid;

            IF v_name IS NULL THEN
                RAISE EXCEPTION 'A student on this sheet is not enrolled in this class and section.';
            END IF;

            IF v_marks IS NOT NULL AND (v_marks < 0 OR v_marks > v_max) THEN
                RAISE EXCEPTION 'Marks for % must be between 0 and %.', v_name, v_max;
            END IF;

            INSERT INTO academic.exam_marks
                (tenant_id, school_id, exam_id, academic_class_id, subject_id, student_id,
                 enrolment_id, section, marks_obtained, is_absent, created_by, created_at)
            VALUES
                (p_tenant_id, p_school_id, p_exam_id, p_academic_class_id, p_subject_id, v_sid,
                 v_enrol, v_section, v_marks, v_absent, p_action_user_id, now())
            ON CONFLICT ON CONSTRAINT uq_exam_marks
            DO UPDATE SET marks_obtained    = EXCLUDED.marks_obtained,
                          is_absent         = EXCLUDED.is_absent,
                          enrolment_id      = EXCLUDED.enrolment_id,
                          academic_class_id = EXCLUDED.academic_class_id,
                          section           = EXCLUDED.section,
                          updated_by        = p_action_user_id,
                          updated_at        = now()
            -- An unchanged mark is not rewritten, so updated_by keeps meaning
            -- "who last changed it" and the history trigger stays quiet.
            WHERE academic.exam_marks.marks_obtained    IS DISTINCT FROM EXCLUDED.marks_obtained
               OR academic.exam_marks.is_absent         IS DISTINCT FROM EXCLUDED.is_absent
               OR academic.exam_marks.enrolment_id      IS DISTINCT FROM EXCLUDED.enrolment_id
               OR academic.exam_marks.academic_class_id IS DISTINCT FROM EXCLUDED.academic_class_id
               OR academic.exam_marks.section           IS DISTINCT FROM EXCLUDED.section;

            v_saved := v_saved + 1;
        END LOOP;

        IF p_finalize THEN
            -- Anyone still without a row is recorded Absent, which is exactly what
            -- the finalize dialog warns the teacher about.
            INSERT INTO academic.exam_marks
                (tenant_id, school_id, exam_id, academic_class_id, subject_id, student_id,
                 enrolment_id, section, marks_obtained, is_absent, created_by, created_at)
            SELECT p_tenant_id, p_school_id, p_exam_id, p_academic_class_id, p_subject_id,
                   r.out_student_id, r.out_enrolment_id, v_section, NULL, TRUE,
                   p_action_user_id, now()
            FROM academic.fn_exam_sheet_roster(p_tenant_id, p_school_id, v_year_id, p_academic_class_id, v_section) r
            WHERE NOT EXISTS (SELECT 1 FROM academic.exam_marks m
                              WHERE m.exam_id    = p_exam_id
                                AND m.subject_id = p_subject_id
                                AND m.student_id = r.out_student_id);

            GET DIAGNOSTICS v_added = ROW_COUNT;

            -- A blank that was saved as a draft (or a mark cleared later) is just
            -- as unmarked: it is recorded Absent too.
            UPDATE academic.exam_marks m
               SET is_absent  = TRUE,
                   updated_by = p_action_user_id,
                   updated_at = now()
             WHERE m.exam_id    = p_exam_id
               AND m.subject_id = p_subject_id
               AND m.marks_obtained IS NULL
               AND NOT m.is_absent
               AND m.student_id IN (SELECT r.out_student_id
                                    FROM academic.fn_exam_sheet_roster(p_tenant_id, p_school_id, v_year_id,
                                                                       p_academic_class_id, v_section) r);

            GET DIAGNOSTICS v_blank = ROW_COUNT;
            v_added := v_added + v_blank;

            INSERT INTO academic.exam_mark_sheets
                (tenant_id, school_id, exam_id, academic_class_id, subject_id, section,
                 is_finalized, finalized_by, finalized_at)
            VALUES
                (p_tenant_id, p_school_id, p_exam_id, p_academic_class_id, p_subject_id, v_section,
                 TRUE, p_action_user_id, now())
            ON CONFLICT ON CONSTRAINT uq_exam_mark_sheets
            DO UPDATE SET is_finalized = TRUE,
                          finalized_by = p_action_user_id,
                          finalized_at = now();
        END IF;

        OPEN p_result FOR
        SELECT TRUE AS success,
               v_saved AS saved,
               v_added AS marked_absent,
               p_finalize AS is_finalized,
               CASE WHEN p_finalize
                    THEN 'Marks finalized and locked.'
                    ELSE 'Marks saved as draft.' END AS message;

        OPEN p_result2 FOR SELECT 1 WHERE FALSE;

    ELSIF p_operation = 'GetMarkScope' THEN

        -- The sheets of this exam the calling user teaches (2026-10-12):
        -- every subject of a section they are class teacher of, plus each
        -- subject the timetable gives them in a section. A teacher with only
        -- exams.marks is limited to these; the caller skips this for school
        -- admins and exams.manage (the proc cannot see roles).
        -- Sections are per session, so joining on the exam's class id keeps
        -- this to the exam's own academic year.
        OPEN p_result FOR
        SELECT DISTINCT es.academic_class_id,
               sec.section_name AS section,
               es.subject_id
        FROM academic.exam_subjects es
        JOIN academic.academic_class_sections sec
             ON sec.academic_class_id = es.academic_class_id
            AND sec.tenant_id = p_tenant_id
            AND sec.school_id = p_school_id
            AND COALESCE(sec.is_deleted, FALSE) = FALSE
        JOIN core.staff st
             ON st.tenant_id = p_tenant_id
            AND st.school_id = p_school_id
            AND st.user_id   = p_action_user_id
            -- A teacher who has left must not keep entering marks.
            AND COALESCE(st.is_active, TRUE)   = TRUE
            AND COALESCE(st.is_deleted, FALSE) = FALSE
        WHERE es.exam_id   = p_exam_id
          AND es.tenant_id = p_tenant_id
          AND es.school_id = p_school_id
          AND (sec.class_teacher_staff_id = st.staff_id
               OR EXISTS (SELECT 1 FROM academic.timetable t
                          WHERE t.academic_class_section_id = sec.academic_class_section_id
                            AND t.subject_id = es.subject_id
                            AND t.staff_id   = st.staff_id
                            AND t.tenant_id  = p_tenant_id
                            AND t.school_id  = p_school_id));

        OPEN p_result2 FOR SELECT 1 WHERE FALSE;

    ELSIF p_operation = 'ReopenSheet' THEN

        -- Admin-only; the caller enforces that (the proc cannot see roles).
        IF COALESCE(p_subject_id, 0) <= 0 THEN
            RAISE EXCEPTION 'Pick a subject first.';
        END IF;
        IF v_results = 'Published' THEN
            RAISE EXCEPTION 'The results of this exam are published. Unpublish the results before reopening a sheet.';
        END IF;

        UPDATE academic.exam_mark_sheets
           SET is_finalized = FALSE,
               reopened_by  = p_action_user_id,
               reopened_at  = now()
         WHERE exam_id           = p_exam_id
           AND academic_class_id = p_academic_class_id
           AND subject_id        = p_subject_id
           AND section           = v_section
           AND tenant_id        = p_tenant_id
           AND school_id        = p_school_id
           AND is_finalized;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'That sheet is not finalized.';
        END IF;

        OPEN p_result FOR SELECT TRUE AS success, 'Sheet reopened for editing.' AS message;
        OPEN p_result2 FOR SELECT 1 WHERE FALSE;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$

;

-- ===== academic.sp_school_admin_calendar_manage =====
CREATE OR REPLACE PROCEDURE academic.sp_school_admin_calendar_manage(IN p_operation character varying, IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_calendar_id integer DEFAULT NULL::integer, IN p_date date DEFAULT NULL::date, IN p_to_date date DEFAULT NULL::date, IN p_day_type character varying DEFAULT NULL::character varying, IN p_title character varying DEFAULT NULL::character varying, IN p_half_day_end time without time zone DEFAULT NULL::time without time zone, IN p_weekly_off character varying DEFAULT NULL::character varying, INOUT p_result refcursor DEFAULT 'calendar_cursor'::refcursor, INOUT p_result2 refcursor DEFAULT 'calendar_cursor2'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_type       text;
    v_title      text;
    v_offs       smallint[];
    v_dow        smallint;
    v_entry      academic.school_calendar%ROWTYPE;
    v_day_type   text;
    v_day_title  text;
    v_is_working boolean;
    v_half_end   time;
    v_to         date;
    v_day        date;
    v_created    integer := 0;
    v_had_entry  integer := 0;
    v_off_days   integer := 0;
    v_open_days  integer := 0;
    v_had_list   text := '';
    v_first      time;
    v_last       time;
    v_n          integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    -- ---------------------------------------------------------------- read --
    IF p_operation = 'GetCalendar' THEN

        OPEN p_result FOR
        SELECT
            calendar_id,
            to_char(calendar_date::date, 'YYYY-MM-DD')     AS calendar_date,
            day_type,
            title,
            to_char(half_day_end, 'HH24:MI')         AS half_day_end
        FROM academic.school_calendar
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND calendar_date::date >= COALESCE(p_date,    date_trunc('year', CURRENT_DATE)::date)
          AND calendar_date::date <= COALESCE(p_to_date, (date_trunc('year', CURRENT_DATE) + interval '1 year - 1 day')::date)
        ORDER BY calendar_date;

        OPEN p_result2 FOR
        SELECT COALESCE(
            (SELECT array_to_string(weekly_off_days, ',')
             FROM academic.school_calendar_settings
             WHERE tenant_id = p_tenant_id AND school_id = p_school_id),
            '0') AS weekly_off_days;

    ELSIF p_operation = 'GetDayStatus' THEN

        -- Resolve one date the way the bell should see it.
        v_dow := EXTRACT(DOW FROM COALESCE(p_date, CURRENT_DATE))::smallint;   -- 0 = Sunday

        SELECT COALESCE(weekly_off_days, '{0}') INTO v_offs
        FROM academic.school_calendar_settings
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id;
        IF v_offs IS NULL THEN
            v_offs := '{0}';                       -- unconfigured school: Sunday off
        END IF;

        SELECT * INTO v_entry
        FROM academic.school_calendar
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND calendar_date::date = COALESCE(p_date, CURRENT_DATE);

        IF FOUND THEN
            -- A dated entry overrides the weekly pattern in both directions.
            v_day_type  := v_entry.day_type;
            v_day_title := v_entry.title;
            v_half_end  := v_entry.half_day_end;
            v_is_working := v_entry.day_type <> 'holiday';
            IF v_entry.day_type = 'working' THEN
                v_day_type := 'working';
            END IF;
        ELSIF v_dow = ANY (v_offs) THEN
            v_day_type   := 'weekly_off';
            v_day_title  := trim(to_char(COALESCE(p_date, CURRENT_DATE), 'Day'));
            v_is_working := FALSE;
        ELSE
            v_day_type   := 'working';
            v_day_title  := '';
            v_is_working := TRUE;
        END IF;

        OPEN p_result FOR
        SELECT
            to_char(COALESCE(p_date, CURRENT_DATE), 'YYYY-MM-DD') AS calendar_date,
            v_dow                          AS day_of_week,
            v_day_type                     AS day_type,
            COALESCE(v_day_title, '')      AS title,
            to_char(v_half_end, 'HH24:MI') AS half_day_end,
            v_is_working                   AS is_working;

        OPEN p_result2 FOR SELECT array_to_string(v_offs, ',') AS weekly_off_days;

    -- --------------------------------------------------------------- write --
    ELSIF p_operation IN ('SaveEntry', 'SaveRange') THEN

        -- SaveEntry writes one date (and replaces what was there). SaveRange
        -- writes every date from p_date to p_to_date as its own entry, and leaves
        -- a date that already has an entry alone, so a range never silently
        -- overwrites a half day or a working Saturday someone set by hand.
        IF p_date IS NULL THEN
            RAISE EXCEPTION 'Pick a date first.';
        END IF;

        v_to := CASE WHEN p_operation = 'SaveRange' THEN COALESCE(p_to_date, p_date) ELSE p_date END;
        IF v_to < p_date THEN
            RAISE EXCEPTION 'The range ends before it starts.';
        END IF;
        IF v_to - p_date > 366 THEN
            RAISE EXCEPTION 'A range can cover at most one year.';
        END IF;

        v_type  := lower(trim(COALESCE(p_day_type, 'holiday')));
        IF v_type NOT IN ('holiday', 'half_day', 'working') THEN
            RAISE EXCEPTION 'Unknown day type "%".', v_type;
        END IF;

        v_title := trim(COALESCE(p_title, ''));
        IF v_title = '' THEN
            v_title := CASE v_type
                         WHEN 'holiday'  THEN 'Holiday'
                         WHEN 'half_day' THEN 'Half Day'
                         ELSE 'Working Day'
                       END;
        END IF;

        IF v_type = 'half_day' AND p_half_day_end IS NULL THEN
            RAISE EXCEPTION 'A half day needs a closing time.';
        END IF;

        SELECT COALESCE(weekly_off_days, '{0}') INTO v_offs
        FROM academic.school_calendar_settings
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id;
        IF v_offs IS NULL THEN
            v_offs := '{0}';
        END IF;

        v_day := p_date;
        WHILE v_day <= v_to LOOP

            IF p_operation = 'SaveRange' AND EXISTS (
                   SELECT 1 FROM academic.school_calendar
                   WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                     AND calendar_date::date = v_day) THEN
                v_had_entry := v_had_entry + 1;
                IF v_had_entry <= 10 THEN
                    v_had_list := v_had_list || CASE WHEN v_had_list = '' THEN '' ELSE ', ' END
                                  || to_char(v_day, 'FMDD Mon');
                END IF;

            -- A closed day needs no holiday, and a half day on one would turn it
            -- into a working day. A working-day range is the way to open them.
            ELSIF p_operation = 'SaveRange' AND v_type <> 'working'
                  AND EXTRACT(DOW FROM v_day)::smallint = ANY (v_offs) THEN
                v_off_days := v_off_days + 1;

            -- A working-day override only means something on a weekly off; on a
            -- normal weekday it changes nothing, so refuse it (one date) or skip
            -- that day (a range).
            ELSIF v_type = 'working'
                  AND NOT (EXTRACT(DOW FROM v_day)::smallint = ANY (v_offs)) THEN
                IF p_operation = 'SaveEntry' THEN
                    RAISE EXCEPTION '% is already a working day. A working-day override is only for a weekly off.',
                        to_char(v_day, 'FMDay, FMDD Mon');
                END IF;
                v_open_days := v_open_days + 1;

            ELSE
                -- The closing time has to fall inside that day's bell schedule, or
                -- the bell either never rings (before the first period) or the
                -- half day changes nothing. A short Saturday has its own hours.
                IF v_type = 'half_day' THEN
                    SELECT MIN(start_time), MAX(end_time) INTO v_first, v_last
                    FROM academic.fn_day_periods(p_tenant_id, p_school_id, EXTRACT(DOW FROM v_day)::smallint);
                    IF v_first IS NOT NULL AND (p_half_day_end <= v_first OR p_half_day_end >= v_last) THEN
                        RAISE EXCEPTION 'A half day must close during the school day (between % and % on %).',
                            to_char(v_first, 'HH24:MI'), to_char(v_last, 'HH24:MI'), to_char(v_day, 'FMDay, FMDD Mon');
                    END IF;
                END IF;

                INSERT INTO academic.school_calendar
                    (tenant_id, school_id, calendar_date, day_type, title, half_day_end, created_by, created_at)
                VALUES
                    (p_tenant_id, p_school_id, v_day, v_type, v_title,
                     CASE WHEN v_type = 'half_day' THEN p_half_day_end ELSE NULL END,
                     p_action_user_id, now())
                ON CONFLICT (tenant_id, school_id, calendar_date) DO UPDATE
                    SET day_type     = EXCLUDED.day_type,
                        title        = EXCLUDED.title,
                        half_day_end = EXCLUDED.half_day_end,
                        updated_by   = p_action_user_id,
                        updated_at   = now();
                v_created := v_created + 1;
            END IF;

            v_day := v_day + 1;
        END LOOP;

        IF p_operation = 'SaveEntry' THEN
            OPEN p_result FOR SELECT TRUE AS success, 'Calendar updated.' AS message;
        ELSE
            IF v_created = 0 THEN
                RAISE EXCEPTION 'Nothing was added: every day from % to % already has an entry or %.',
                    to_char(p_date, 'FMDD Mon YYYY'), to_char(v_to, 'FMDD Mon YYYY'),
                    CASE WHEN v_type = 'working' THEN 'is already a working day' ELSE 'is a weekly off' END;
            END IF;

            OPEN p_result FOR
            SELECT TRUE AS success,
                   v_created   AS created,
                   v_had_entry AS skipped_existing,
                   v_off_days  AS skipped_weekly_off,
                   v_created || CASE WHEN v_created = 1 THEN ' day' ELSE ' days' END || ' marked.'
                   || CASE WHEN v_had_entry > 0
                           THEN ' Skipped ' || v_had_entry || ' that already had an entry (' || v_had_list
                                || CASE WHEN v_had_entry > 10 THEN ', ...' ELSE '' END || ').'
                           ELSE '' END
                   || CASE WHEN v_off_days > 0
                           THEN ' Skipped ' || v_off_days || ' weekly off' || CASE WHEN v_off_days = 1 THEN '' ELSE 's' END || '.'
                           ELSE '' END
                   || CASE WHEN v_open_days > 0
                           THEN ' Skipped ' || v_open_days || ' day' || CASE WHEN v_open_days = 1 THEN '' ELSE 's' END
                                || ' that ' || CASE WHEN v_open_days = 1 THEN 'is' ELSE 'are' END || ' already a working day.'
                           ELSE '' END AS message;
        END IF;
        OPEN p_result2 FOR SELECT 1 WHERE FALSE;

    ELSIF p_operation = 'DeleteRange' THEN

        IF p_date IS NULL OR p_to_date IS NULL THEN
            RAISE EXCEPTION 'Pick the first and last date of the range.';
        END IF;
        IF p_to_date < p_date THEN
            RAISE EXCEPTION 'The range ends before it starts.';
        END IF;

        DELETE FROM academic.school_calendar
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND calendar_date::date BETWEEN p_date AND p_to_date;
        GET DIAGNOSTICS v_n = ROW_COUNT;

        IF v_n = 0 THEN
            RAISE EXCEPTION 'There are no calendar entries from % to %.',
                to_char(p_date, 'FMDD Mon YYYY'), to_char(p_to_date, 'FMDD Mon YYYY');
        END IF;

        OPEN p_result FOR
        SELECT TRUE AS success, v_n AS removed,
               v_n || CASE WHEN v_n = 1 THEN ' entry' ELSE ' entries' END || ' removed.' AS message;
        OPEN p_result2 FOR SELECT 1 WHERE FALSE;

    ELSIF p_operation = 'DeleteEntry' THEN

        DELETE FROM academic.school_calendar
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND (   (p_calendar_id IS NOT NULL AND calendar_id   = p_calendar_id)
               OR (p_calendar_id IS NULL     AND calendar_date::date = p_date));

        IF NOT FOUND THEN
            RAISE EXCEPTION 'That calendar entry was not found.';
        END IF;

        OPEN p_result FOR SELECT TRUE AS success, 'Entry removed.' AS message;
        OPEN p_result2 FOR SELECT 1 WHERE FALSE;

    ELSIF p_operation = 'SaveWeeklyOff' THEN

        -- csv of 0..6; empty string is allowed (a school that never closes weekly).
        SELECT COALESCE(array_agg(d::smallint ORDER BY d::smallint), '{}')
          INTO v_offs
        FROM (
            SELECT DISTINCT trim(x) AS d
            FROM regexp_split_to_table(COALESCE(p_weekly_off, ''), ',') x
            WHERE trim(x) ~ '^[0-6]$'
        ) s;

        INSERT INTO academic.school_calendar_settings
            (tenant_id, school_id, weekly_off_days, updated_by, updated_at)
        VALUES
            (p_tenant_id, p_school_id, v_offs, p_action_user_id, now())
        ON CONFLICT (tenant_id, school_id) DO UPDATE
            SET weekly_off_days = EXCLUDED.weekly_off_days,
                updated_by      = p_action_user_id,
                updated_at      = now();

        OPEN p_result FOR SELECT TRUE AS success, 'Weekly offs saved.' AS message;
        OPEN p_result2 FOR SELECT 1 WHERE FALSE;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$

;
