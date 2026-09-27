-- ============================================================================
-- "Charge recurring fees from" moves from the school to the academic year.
--
-- WHY: the setting decides how a student's WHOLE session is billed, but it
-- lived as one row per school, overwritten in place. Change it in August and
-- the students admitted in April had been billed under a rule that no longer
-- existed anywhere -- two children in the same class billed differently, with
-- nothing left to show why. Their ledgers are frozen at admission
-- (student_master_fields.sql), so the old rule cannot even be re-derived.
--
-- Per year, the value sits beside the session it governs: last year's policy
-- can no longer be rewritten by this year's change, and the save can refuse to
-- move the goalposts once a session already has admissions.
--
-- Safe to re-run. The backfill only happens the first time, so a year set
-- deliberately afterwards is never pulled back to the school's old value.
-- ============================================================================

-- ── 1. The column, and the school's current value copied onto every year ────
DO $migrate$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'academic'
                      AND table_name   = 'academic_years'
                      AND column_name  = 'charge_fees_from') THEN

        ALTER TABLE academic.academic_years
            ADD COLUMN charge_fees_from varchar(20) NOT NULL DEFAULT 'AdmissionMonth';

        -- Every existing year inherits what its school was already using, so no
        -- school's billing changes on the day this runs.
        IF EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'core'
                      AND table_name   = 'school_admission_workflow_settings'
                      AND column_name  = 'charge_fees_from') THEN
            UPDATE academic.academic_years ay
               SET charge_fees_from =
                   COALESCE(NULLIF(TRIM(w.charge_fees_from), ''), 'AdmissionMonth')
              FROM core.school_admission_workflow_settings w
             WHERE w.tenant_id = ay.tenant_id
               AND w.school_id = ay.school_id;
        END IF;
    END IF;
END
$migrate$;

-- Only the two values the page offers ever reach the column.
ALTER TABLE academic.academic_years
    DROP CONSTRAINT IF EXISTS chk_academic_years_charge_fees_from;
ALTER TABLE academic.academic_years
    ADD CONSTRAINT chk_academic_years_charge_fees_from
    CHECK (charge_fees_from IN ('AdmissionMonth', 'SessionStart'));


-- ── 2. Academic year proc: carries the setting, and guards it ───────────────
-- Adding a parameter is a NEW signature, so the old overload has to go or the
-- call fails with "procedure is not unique".
DROP PROCEDURE IF EXISTS academic.sp_school_admin_academic_year_manage(
    character varying, integer, integer, integer,
    integer, character varying, date, date, boolean, refcursor);

CREATE OR REPLACE PROCEDURE academic.sp_school_admin_academic_year_manage(
    IN p_operation          character varying,
    IN p_tenant_id          integer,
    IN p_school_id          integer,
    IN p_action_user_id     integer,
    IN p_academic_year_id   integer   DEFAULT NULL::integer,
    IN p_academic_year_name character varying DEFAULT NULL::character varying,
    IN p_start_date         date      DEFAULT NULL::date,
    IN p_end_date           date      DEFAULT NULL::date,
    IN p_is_current         boolean   DEFAULT FALSE,
    IN p_charge_fees_from   character varying DEFAULT NULL::character varying,
    INOUT p_result          refcursor DEFAULT 'result_cursor'::refcursor)
  LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_id            integer;
    v_name          text;
    v_year_name     text;
    v_class_count   integer;
    v_student_count integer;
    v_charge_from   varchar(20);
    v_old_charge    varchar(20);
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    IF p_operation = 'GetAcademicYears' THEN

        OPEN p_result FOR
        SELECT
            ay.academic_year_id,
            ay.academic_year_name,
            ay.start_date,
            ay.end_date,
            COALESCE(ay.is_current, FALSE) AS is_current,
            COALESCE(NULLIF(TRIM(ay.charge_fees_from), ''), 'AdmissionMonth') AS charge_fees_from,
            (SELECT COUNT(*) FROM academic.academic_classes ac
              WHERE ac.tenant_id = p_tenant_id
                AND ac.school_id = p_school_id
                AND ac.academic_year_id = ay.academic_year_id
                AND COALESCE(ac.is_deleted, FALSE) = FALSE) AS class_count,
            (SELECT COUNT(*) FROM core.students st
              WHERE st.tenant_id = p_tenant_id
                AND st.school_id = p_school_id
                AND st.academic_year = ay.academic_year_name
                AND COALESCE(st.is_active, TRUE) = TRUE) AS student_count
        FROM academic.academic_years ay
        WHERE ay.tenant_id = p_tenant_id
          AND ay.school_id = p_school_id
          AND COALESCE(ay.is_deleted, FALSE) = FALSE
        ORDER BY ay.start_date DESC NULLS LAST, ay.academic_year_name DESC;

    ELSIF p_operation = 'SaveAcademicYear' THEN

        v_name := trim(COALESCE(p_academic_year_name, ''));
        IF v_name = '' THEN
            RAISE EXCEPTION 'Academic year name is required.';
        END IF;

        IF p_start_date IS NOT NULL AND p_end_date IS NOT NULL AND p_end_date < p_start_date THEN
            RAISE EXCEPTION 'End date cannot be before start date.';
        END IF;

        IF EXISTS (
            SELECT 1 FROM academic.academic_years
            WHERE tenant_id = p_tenant_id
              AND school_id = p_school_id
              AND COALESCE(is_deleted, FALSE) = FALSE
              AND lower(academic_year_name) = lower(v_name)
              AND academic_year_id <> COALESCE(p_academic_year_id, 0)
        ) THEN
            RAISE EXCEPTION 'An academic year named "%" already exists.', v_name;
        END IF;

        -- Anything but the one other value means the default.
        v_charge_from := CASE WHEN p_charge_fees_from = 'SessionStart'
                              THEN 'SessionStart' ELSE 'AdmissionMonth' END;

        -- The guard this move exists for. A student's fee ledger is generated
        -- once, at admission, from this setting -- and then frozen. Changing it
        -- afterwards cannot reach those rows, so the session would be billed one
        -- way and labelled another. Refuse while the value would actually differ;
        -- renaming the year or fixing its dates stays possible.
        IF p_academic_year_id IS NOT NULL AND p_academic_year_id > 0 THEN
            SELECT academic_year_name,
                   COALESCE(NULLIF(TRIM(charge_fees_from), ''), 'AdmissionMonth')
              INTO v_year_name, v_old_charge
            FROM academic.academic_years
            WHERE tenant_id = p_tenant_id
              AND school_id = p_school_id
              AND academic_year_id = p_academic_year_id
              AND COALESCE(is_deleted, FALSE) = FALSE;

            IF v_old_charge IS DISTINCT FROM v_charge_from THEN
                -- Count under the name the students were admitted against, which
                -- is the OLD name when this save is also a rename.
                SELECT COUNT(*) INTO v_student_count
                FROM core.students
                WHERE tenant_id = p_tenant_id
                  AND school_id = p_school_id
                  AND academic_year = v_year_name
                  AND COALESCE(is_active, TRUE) = TRUE;

                IF v_student_count > 0 THEN
                    RAISE EXCEPTION
                        'Cannot change when fees are charged from for %: % student(s) are already admitted in this session, and their fee plans were generated under the current setting.',
                        v_year_name, v_student_count;
                END IF;
            END IF;
        END IF;

        -- Only one current year per school.
        IF COALESCE(p_is_current, FALSE) THEN
            UPDATE academic.academic_years
            SET is_current = FALSE, updated_by = p_action_user_id, updated_at = NOW()
            WHERE tenant_id = p_tenant_id
              AND school_id = p_school_id
              AND COALESCE(is_deleted, FALSE) = FALSE;
        END IF;

        IF p_academic_year_id IS NULL OR p_academic_year_id <= 0 THEN
            INSERT INTO academic.academic_years
                (tenant_id, school_id, academic_year_name, start_date, end_date, is_current,
                 charge_fees_from, created_by, created_at, is_deleted, is_active)
            VALUES
                (p_tenant_id, p_school_id, v_name, p_start_date, p_end_date, COALESCE(p_is_current, FALSE),
                 v_charge_from, p_action_user_id, NOW(), FALSE, TRUE)
            RETURNING academic_year_id INTO v_id;
        ELSE
            UPDATE academic.academic_years
            SET academic_year_name = v_name,
                start_date       = p_start_date,
                end_date         = p_end_date,
                is_current       = COALESCE(p_is_current, is_current),
                charge_fees_from = v_charge_from,
                updated_by       = p_action_user_id,
                updated_at       = NOW()
            WHERE tenant_id = p_tenant_id
              AND school_id = p_school_id
              AND academic_year_id = p_academic_year_id
              AND COALESCE(is_deleted, FALSE) = FALSE
            RETURNING academic_year_id INTO v_id;
        END IF;

        OPEN p_result FOR
        SELECT TRUE AS success, 'Saved successfully.' AS message, v_id AS academic_year_id;

    ELSIF p_operation = 'SetCurrentAcademicYear' THEN

        IF p_academic_year_id IS NULL OR p_academic_year_id <= 0 THEN
            RAISE EXCEPTION 'Select an academic year.';
        END IF;

        UPDATE academic.academic_years
        SET is_current = FALSE, updated_by = p_action_user_id, updated_at = NOW()
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

        UPDATE academic.academic_years
        SET is_current = TRUE, updated_by = p_action_user_id, updated_at = NOW()
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND academic_year_id = p_academic_year_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

        OPEN p_result FOR
        SELECT TRUE AS success, 'Current academic year updated.' AS message, p_academic_year_id AS academic_year_id;

    ELSIF p_operation = 'DeleteAcademicYear' THEN

        IF p_academic_year_id IS NULL OR p_academic_year_id <= 0 THEN
            RAISE EXCEPTION 'Select an academic year.';
        END IF;

        SELECT academic_year_name INTO v_year_name
        FROM academic.academic_years
        WHERE academic_year_id = p_academic_year_id
          AND tenant_id = p_tenant_id
          AND school_id = p_school_id;

        SELECT COUNT(*) INTO v_class_count
        FROM academic.academic_classes
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND academic_year_id = p_academic_year_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

        SELECT COUNT(*) INTO v_student_count
        FROM core.students
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND academic_year = v_year_name
          AND COALESCE(is_active, TRUE) = TRUE;

        IF v_class_count > 0 OR v_student_count > 0 THEN
            RAISE EXCEPTION 'Cannot delete this year: it has % class(es) and % student(s). Remove those first.',
                v_class_count, v_student_count;
        END IF;

        UPDATE academic.academic_years
        SET is_deleted = TRUE, is_active = FALSE, is_current = FALSE,
            deleted_by = p_action_user_id, deleted_at = NOW(),
            updated_by = p_action_user_id, updated_at = NOW()
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND academic_year_id = p_academic_year_id;

        OPEN p_result FOR
        SELECT TRUE AS success, 'Academic year deleted.' AS message, p_academic_year_id AS academic_year_id;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;


-- ── 3. Workflow proc: the setting is no longer its business ─────────────────
-- Dropping a parameter is again a new signature, so the old overload goes.
DROP PROCEDURE IF EXISTS core.sp_school_admin_admission_workflow_manage(
    character varying, integer, integer, integer,
    boolean, boolean, boolean, boolean, character varying,
    boolean, boolean, boolean, boolean, boolean, boolean,
    character varying, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_school_admin_admission_workflow_manage(
    IN p_operation                              character varying,
    IN p_tenant_id                              integer,
    IN p_school_id                              integer,
    IN p_action_user_id                         integer,
    IN p_enable_registration                    boolean DEFAULT NULL::boolean,
    IN p_registration_required_before_admission boolean DEFAULT NULL::boolean,
    IN p_enable_registration_fee                boolean DEFAULT NULL::boolean,
    IN p_auto_generate_registration_number      boolean DEFAULT NULL::boolean,
    IN p_registration_number_prefix             character varying DEFAULT NULL::character varying,
    IN p_collect_fee_at_admission               boolean DEFAULT NULL::boolean,
    IN p_enable_security_fee                    boolean DEFAULT NULL::boolean,
    IN p_enable_transport                       boolean DEFAULT NULL::boolean,
    IN p_enable_exams                           boolean DEFAULT NULL::boolean,
    IN p_enable_inventory                       boolean DEFAULT NULL::boolean,
    IN p_enable_payroll                         boolean DEFAULT NULL::boolean,
    INOUT p_result                              refcursor DEFAULT 'result_cursor'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_enable_reg   boolean;
    v_required     boolean;
    v_enable_fee   boolean;
    v_auto_num     boolean;
    v_prefix       varchar(20);
    v_collect      boolean;
    v_enable_sec   boolean;
    v_enable_trans boolean;
    v_enable_exam  boolean;
    v_enable_inv   boolean;
    v_enable_pay   boolean;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    IF p_operation = 'GetAdmissionWorkflow' THEN
        OPEN p_result FOR
        SELECT
            enable_registration,
            registration_required_before_admission,
            enable_registration_fee,
            auto_generate_registration_number,
            registration_number_prefix,
            collect_fee_at_admission,
            enable_security_fee,
            enable_transport,
            enable_exams,
            enable_inventory,
            enable_payroll
        FROM core.school_admission_workflow_settings
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND COALESCE(is_deleted, FALSE) = FALSE
        LIMIT 1;

    ELSIF p_operation = 'SaveAdmissionWorkflow' THEN
        v_enable_reg   := COALESCE(p_enable_registration, FALSE);
        v_required     := v_enable_reg AND COALESCE(p_registration_required_before_admission, FALSE);
        v_enable_fee   := v_enable_reg AND COALESCE(p_enable_registration_fee, FALSE);
        v_auto_num     := COALESCE(p_auto_generate_registration_number, TRUE);
        v_prefix       := COALESCE(NULLIF(trim(p_registration_number_prefix), ''), 'REG-');
        v_collect      := COALESCE(p_collect_fee_at_admission, FALSE);
        v_enable_sec   := COALESCE(p_enable_security_fee, FALSE);
        v_enable_trans := COALESCE(p_enable_transport, TRUE);
        v_enable_exam  := COALESCE(p_enable_exams, TRUE);
        v_enable_inv   := COALESCE(p_enable_inventory, TRUE);
        v_enable_pay   := COALESCE(p_enable_payroll, TRUE);

        INSERT INTO core.school_admission_workflow_settings
        (
            tenant_id, school_id,
            enable_registration, registration_required_before_admission,
            enable_registration_fee,
            auto_generate_registration_number, registration_number_prefix,
            collect_fee_at_admission,
            enable_security_fee,
            enable_transport,
            enable_exams,
            enable_inventory,
            enable_payroll,
            created_by, created_at, is_deleted, is_active
        )
        VALUES
        (
            p_tenant_id, p_school_id,
            v_enable_reg, v_required,
            v_enable_fee,
            v_auto_num, v_prefix,
            v_collect,
            v_enable_sec,
            v_enable_trans,
            v_enable_exam,
            v_enable_inv,
            v_enable_pay,
            p_action_user_id, NOW(), FALSE, TRUE
        )
        ON CONFLICT (tenant_id, school_id) DO UPDATE
        SET enable_registration                    = EXCLUDED.enable_registration,
            registration_required_before_admission = EXCLUDED.registration_required_before_admission,
            enable_registration_fee                = EXCLUDED.enable_registration_fee,
            auto_generate_registration_number      = EXCLUDED.auto_generate_registration_number,
            registration_number_prefix             = EXCLUDED.registration_number_prefix,
            collect_fee_at_admission               = EXCLUDED.collect_fee_at_admission,
            enable_security_fee                    = EXCLUDED.enable_security_fee,
            enable_transport                       = EXCLUDED.enable_transport,
            enable_exams                           = EXCLUDED.enable_exams,
            enable_inventory                       = EXCLUDED.enable_inventory,
            enable_payroll                         = EXCLUDED.enable_payroll,
            is_deleted = FALSE, is_active = TRUE,
            updated_by = p_action_user_id, updated_at = NOW();

        OPEN p_result FOR SELECT TRUE AS success, 'Saved successfully.' AS message;
    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;


-- ── 4. The old column goes ──────────────────────────────────────────────────
-- Left behind it would be a second copy of the answer that nothing maintains,
-- which is exactly how registration_fee_amount / security_fee_amount still sit
-- on this table reading 0.00 long after the amounts moved to Fee Heads.
-- Step 1 has already copied the value onto every year.
ALTER TABLE core.school_admission_workflow_settings
    DROP COLUMN IF EXISTS charge_fees_from;
