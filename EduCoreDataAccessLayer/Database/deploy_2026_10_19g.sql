-- Bundle 2026-10-19g: four more sellable modules (Attendance, Academics, Fees, Accounts) -- allow_/enable_ switches. Run with:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_19g.sql
-- Sources: sellable_modules.sql

-- ============================================================================
-- Four more modules a school can be sold separately (19 Oct 2026):
-- Attendance, Academics (timetable, homework), Fees, Accounts (expenses, cash book).
--
-- Same two levels as Transport / Exams / Inventory / Payroll
-- (superadmin_modules_login_as.sql):
--   allow_*   the Super Admin GAVE the module to the school
--   enable_*  the school switched a given module on (Workflow page)
-- A module is on only when both are true. Everything defaults to TRUE, so every
-- existing school keeps every page it has today.
--
-- "Payroll" is shown as "Staff" on the screens; the columns keep their old names.
--
-- This file replaces the three routines below as they were in
-- superadmin_modules_login_as.sql / school_module_toggles.sql. The procedures get
-- new parameters, so the old ones are dropped first (otherwise two versions would
-- exist and a call by name would be ambiguous).
--
-- A new parameter left out (NULL) keeps the stored value, so an older screen that
-- does not send it cannot switch a module back on by accident.
--
-- Re-runnable.
-- ============================================================================

ALTER TABLE core.school_admission_workflow_settings ADD COLUMN IF NOT EXISTS allow_attendance  boolean NOT NULL DEFAULT TRUE;
ALTER TABLE core.school_admission_workflow_settings ADD COLUMN IF NOT EXISTS allow_academics   boolean NOT NULL DEFAULT TRUE;
ALTER TABLE core.school_admission_workflow_settings ADD COLUMN IF NOT EXISTS allow_fees        boolean NOT NULL DEFAULT TRUE;
ALTER TABLE core.school_admission_workflow_settings ADD COLUMN IF NOT EXISTS allow_accounts    boolean NOT NULL DEFAULT TRUE;
ALTER TABLE core.school_admission_workflow_settings ADD COLUMN IF NOT EXISTS enable_attendance boolean NOT NULL DEFAULT TRUE;
ALTER TABLE core.school_admission_workflow_settings ADD COLUMN IF NOT EXISTS enable_academics  boolean NOT NULL DEFAULT TRUE;
ALTER TABLE core.school_admission_workflow_settings ADD COLUMN IF NOT EXISTS enable_fees       boolean NOT NULL DEFAULT TRUE;
ALTER TABLE core.school_admission_workflow_settings ADD COLUMN IF NOT EXISTS enable_accounts   boolean NOT NULL DEFAULT TRUE;


-- ── Is a module on for this school? (given AND switched on; no row = on) ─────
CREATE OR REPLACE FUNCTION core.fn_module_on(p_tenant_id integer, p_school_id integer, p_module text)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
    SELECT COALESCE((SELECT CASE lower(p_module)
                              WHEN 'transport'  THEN w.enable_transport  AND w.allow_transport
                              WHEN 'exams'      THEN w.enable_exams      AND w.allow_exams
                              WHEN 'inventory'  THEN w.enable_inventory  AND w.allow_inventory
                              WHEN 'payroll'    THEN w.enable_payroll    AND w.allow_payroll
                              WHEN 'staff'      THEN w.enable_payroll    AND w.allow_payroll
                              WHEN 'attendance' THEN w.enable_attendance AND w.allow_attendance
                              WHEN 'academics'  THEN w.enable_academics  AND w.allow_academics
                              WHEN 'fees'       THEN w.enable_fees       AND w.allow_fees
                              WHEN 'accounts'   THEN w.enable_accounts   AND w.allow_accounts
                              ELSE TRUE END
                       FROM core.school_admission_workflow_settings w
                      WHERE w.tenant_id = p_tenant_id AND w.school_id = p_school_id
                        AND NOT COALESCE(w.is_deleted, FALSE)
                      LIMIT 1), TRUE);
$function$;


-- ── Super Admin: which modules a school was given ───────────────────────────
DROP PROCEDURE IF EXISTS core.sp_superadmin_school_modules(text, integer, integer, boolean, boolean, boolean, boolean, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_superadmin_school_modules(
    IN p_operation text, IN p_action_user_id integer, IN p_school_id integer,
    IN p_allow_transport  boolean DEFAULT NULL, IN p_allow_exams    boolean DEFAULT NULL,
    IN p_allow_inventory  boolean DEFAULT NULL, IN p_allow_payroll  boolean DEFAULT NULL,
    IN p_allow_attendance boolean DEFAULT NULL, IN p_allow_academics boolean DEFAULT NULL,
    IN p_allow_fees       boolean DEFAULT NULL, IN p_allow_accounts boolean DEFAULT NULL,
    INOUT p_result refcursor DEFAULT 'modules_cursor'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_tenant integer;
    v_name   text;
    v_riders integer;
    v_dues   numeric;
BEGIN
    IF NOT core.fn_is_super_admin(p_action_user_id) THEN
        RAISE EXCEPTION 'Only the Super Admin can change the modules of a school.';
    END IF;

    SELECT tenant_id, school_name INTO v_tenant, v_name
      FROM core.schools WHERE school_id = p_school_id AND NOT COALESCE(is_deleted, FALSE);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'School not found.';
    END IF;

    IF p_operation = 'Save' THEN
        -- Transport cannot be taken away while children still ride or owe bus
        -- fees: those dues would disappear from the fee counter.
        IF NOT COALESCE(p_allow_transport, TRUE) THEN
            SELECT COUNT(*) INTO v_riders
              FROM core.student_transport a
              JOIN core.students st ON st.student_id = a.student_id AND st.is_active
             WHERE a.tenant_id = v_tenant AND a.school_id = p_school_id
               AND a.is_active AND NOT COALESCE(a.is_deleted, FALSE);
            SELECT COALESCE(SUM(amount_due - amount_paid - COALESCE(concession, 0)), 0) INTO v_dues
              FROM core.student_ledger
             WHERE tenant_id = v_tenant AND school_id = p_school_id
               AND fee_head_name = 'Transport Fee'
               AND amount_due - amount_paid - COALESCE(concession, 0) > 0;
            IF v_riders > 0 OR v_dues > 0 THEN
                RAISE EXCEPTION '% still has % student(s) on buses and Rs % of bus fees unpaid. The school must end those bus assignments first, then Transport can be taken away.',
                    v_name, v_riders, to_char(v_dues, 'FM99,99,99,990.00');
            END IF;
        END IF;

        INSERT INTO core.school_admission_workflow_settings
            (tenant_id, school_id, allow_transport, allow_exams, allow_inventory, allow_payroll,
             allow_attendance, allow_academics, allow_fees, allow_accounts, created_by)
        VALUES (v_tenant, p_school_id,
                COALESCE(p_allow_transport, TRUE), COALESCE(p_allow_exams, TRUE),
                COALESCE(p_allow_inventory, TRUE), COALESCE(p_allow_payroll, TRUE),
                COALESCE(p_allow_attendance, TRUE), COALESCE(p_allow_academics, TRUE),
                COALESCE(p_allow_fees, TRUE), COALESCE(p_allow_accounts, TRUE), p_action_user_id)
        ON CONFLICT (tenant_id, school_id) DO UPDATE
        SET allow_transport  = EXCLUDED.allow_transport,
            allow_exams      = EXCLUDED.allow_exams,
            allow_inventory  = EXCLUDED.allow_inventory,
            allow_payroll    = EXCLUDED.allow_payroll,
            allow_attendance = COALESCE(p_allow_attendance, school_admission_workflow_settings.allow_attendance),
            allow_academics  = COALESCE(p_allow_academics,  school_admission_workflow_settings.allow_academics),
            allow_fees       = COALESCE(p_allow_fees,       school_admission_workflow_settings.allow_fees),
            allow_accounts   = COALESCE(p_allow_accounts,   school_admission_workflow_settings.allow_accounts),
            updated_by = p_action_user_id, updated_at = now();
    ELSIF p_operation <> 'Get' THEN
        RAISE EXCEPTION 'Unknown operation %.', p_operation;
    END IF;

    OPEN p_result FOR
    SELECT p_school_id AS school_id, v_name AS school_name,
           COALESCE(w.allow_transport,  TRUE) AS allow_transport,
           COALESCE(w.allow_exams,      TRUE) AS allow_exams,
           COALESCE(w.allow_inventory,  TRUE) AS allow_inventory,
           COALESCE(w.allow_payroll,    TRUE) AS allow_payroll,
           COALESCE(w.allow_attendance, TRUE) AS allow_attendance,
           COALESCE(w.allow_academics,  TRUE) AS allow_academics,
           COALESCE(w.allow_fees,       TRUE) AS allow_fees,
           COALESCE(w.allow_accounts,   TRUE) AS allow_accounts,
           CASE WHEN p_operation = 'Save' THEN 'Modules saved for ' || v_name || '.' ELSE '' END AS message
      FROM (SELECT 1) one
      LEFT JOIN core.school_admission_workflow_settings w
             ON w.tenant_id = v_tenant AND w.school_id = p_school_id AND NOT COALESCE(w.is_deleted, FALSE);
END;
$procedure$;


-- ── School: Workflow settings, incl. which given modules are switched on ─────
DROP PROCEDURE IF EXISTS core.sp_school_admin_admission_workflow_manage(character varying, integer, integer, integer, boolean, boolean, boolean, boolean, character varying, boolean, boolean, boolean, boolean, boolean, boolean, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_school_admin_admission_workflow_manage(
    IN p_operation character varying, IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer,
    IN p_enable_registration boolean DEFAULT NULL, IN p_registration_required_before_admission boolean DEFAULT NULL,
    IN p_enable_registration_fee boolean DEFAULT NULL, IN p_auto_generate_registration_number boolean DEFAULT NULL,
    IN p_registration_number_prefix character varying DEFAULT NULL, IN p_collect_fee_at_admission boolean DEFAULT NULL,
    IN p_enable_security_fee boolean DEFAULT NULL,
    IN p_enable_transport  boolean DEFAULT NULL, IN p_enable_exams      boolean DEFAULT NULL,
    IN p_enable_inventory  boolean DEFAULT NULL, IN p_enable_payroll    boolean DEFAULT NULL,
    IN p_enable_attendance boolean DEFAULT NULL, IN p_enable_academics  boolean DEFAULT NULL,
    IN p_enable_fees       boolean DEFAULT NULL, IN p_enable_accounts   boolean DEFAULT NULL,
    INOUT p_result refcursor DEFAULT 'result_cursor'::refcursor)
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
            -- a module is on only when the Super Admin gave it AND the school switched it on
            enable_transport  AND allow_transport  AS enable_transport,
            enable_exams      AND allow_exams      AS enable_exams,
            enable_inventory  AND allow_inventory  AS enable_inventory,
            enable_payroll    AND allow_payroll    AS enable_payroll,
            enable_attendance AND allow_attendance AS enable_attendance,
            enable_academics  AND allow_academics  AS enable_academics,
            enable_fees       AND allow_fees       AS enable_fees,
            enable_accounts   AND allow_accounts   AS enable_accounts,
            allow_transport, allow_exams, allow_inventory, allow_payroll,
            allow_attendance, allow_academics, allow_fees, allow_accounts
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

        -- Transport cannot be switched off while children still ride or owe bus
        -- fees: those dues would stay on the fee counter with no module behind them.
        IF NOT v_enable_trans AND core.fn_module_on(p_tenant_id, p_school_id, 'transport') THEN
            IF EXISTS (SELECT 1 FROM core.student_transport a
                         JOIN core.students st ON st.student_id = a.student_id AND st.is_active
                        WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
                          AND a.is_active AND NOT COALESCE(a.is_deleted, FALSE))
               OR EXISTS (SELECT 1 FROM core.student_ledger
                           WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                             AND fee_head_name = 'Transport Fee'
                             AND amount_due - amount_paid - COALESCE(concession, 0) > 0) THEN
                RAISE EXCEPTION 'Transport cannot be turned off while students are on buses or owe bus fees. End their bus assignments (Transport > Assign Transport) first.';
            END IF;
        END IF;

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
            enable_attendance,
            enable_academics,
            enable_fees,
            enable_accounts,
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
            COALESCE(p_enable_attendance, TRUE),
            COALESCE(p_enable_academics, TRUE),
            COALESCE(p_enable_fees, TRUE),
            COALESCE(p_enable_accounts, TRUE),
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
            -- a module the Super Admin has not given keeps its stored switch
            enable_transport = CASE WHEN school_admission_workflow_settings.allow_transport
                                    THEN EXCLUDED.enable_transport ELSE school_admission_workflow_settings.enable_transport END,
            enable_exams     = CASE WHEN school_admission_workflow_settings.allow_exams
                                    THEN EXCLUDED.enable_exams ELSE school_admission_workflow_settings.enable_exams END,
            enable_inventory = CASE WHEN school_admission_workflow_settings.allow_inventory
                                    THEN EXCLUDED.enable_inventory ELSE school_admission_workflow_settings.enable_inventory END,
            enable_payroll   = CASE WHEN school_admission_workflow_settings.allow_payroll
                                    THEN EXCLUDED.enable_payroll ELSE school_admission_workflow_settings.enable_payroll END,
            -- the newer modules: not sent (NULL) or not given = keep the stored switch
            enable_attendance = CASE WHEN school_admission_workflow_settings.allow_attendance AND p_enable_attendance IS NOT NULL
                                     THEN p_enable_attendance ELSE school_admission_workflow_settings.enable_attendance END,
            enable_academics  = CASE WHEN school_admission_workflow_settings.allow_academics AND p_enable_academics IS NOT NULL
                                     THEN p_enable_academics ELSE school_admission_workflow_settings.enable_academics END,
            enable_fees       = CASE WHEN school_admission_workflow_settings.allow_fees AND p_enable_fees IS NOT NULL
                                     THEN p_enable_fees ELSE school_admission_workflow_settings.enable_fees END,
            enable_accounts   = CASE WHEN school_admission_workflow_settings.allow_accounts AND p_enable_accounts IS NOT NULL
                                     THEN p_enable_accounts ELSE school_admission_workflow_settings.enable_accounts END,
            is_deleted = FALSE, is_active = TRUE,
            updated_by = p_action_user_id, updated_at = NOW();

        OPEN p_result FOR SELECT TRUE AS success, 'Saved successfully.' AS message;
    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;
