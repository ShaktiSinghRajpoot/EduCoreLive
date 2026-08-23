-- ============================================================================
-- Per-school MODULE TOGGLES — extend the transport switch to the other optional
-- modules, so a small school is not shown menus it will never use.
--
-- The side menu was cut from 79 items to 45 by deleting placeholder screens; this
-- goes further and lets each school hide modules it does not run. Same mechanism
-- as the existing enable_transport flag (transport_enable_setting.sql), same
-- table, same proc, same settings page — one place a school manages modules.
--
--   enable_exams      Examinations menu (Exam Schedule / Datesheet / Marks Entry)
--   enable_inventory  Inventory menu (Items & Stock / Purchase Entry)
--   enable_payroll    Payroll & Salary and Leave Management under Staff
--
-- All default TRUE so existing schools see no change. The flags only hide UI;
-- nothing already recorded is touched.
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

ALTER TABLE core.school_admission_workflow_settings
    ADD COLUMN IF NOT EXISTS enable_exams     boolean NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS enable_inventory boolean NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS enable_payroll   boolean NOT NULL DEFAULT TRUE;

-- The proc gains three parameters, so CREATE OR REPLACE below would add a second
-- overload instead of replacing this one.
DROP PROCEDURE IF EXISTS core.sp_school_admin_admission_workflow_manage(
    character varying, integer, integer, integer,
    boolean, boolean, boolean, boolean, character varying,
    boolean, boolean, boolean, character varying, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_school_admin_admission_workflow_manage(IN p_operation character varying, IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_enable_registration boolean DEFAULT NULL::boolean, IN p_registration_required_before_admission boolean DEFAULT NULL::boolean, IN p_enable_registration_fee boolean DEFAULT NULL::boolean, IN p_auto_generate_registration_number boolean DEFAULT NULL::boolean, IN p_registration_number_prefix character varying DEFAULT NULL::character varying, IN p_collect_fee_at_admission boolean DEFAULT NULL::boolean, IN p_enable_security_fee boolean DEFAULT NULL::boolean, IN p_enable_transport boolean DEFAULT NULL::boolean, IN p_enable_exams boolean DEFAULT NULL::boolean, IN p_enable_inventory boolean DEFAULT NULL::boolean, IN p_enable_payroll boolean DEFAULT NULL::boolean, IN p_charge_fees_from character varying DEFAULT NULL::character varying, INOUT p_result refcursor DEFAULT 'result_cursor'::refcursor)
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
    v_charge_from  varchar(20);
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
            enable_payroll,
            COALESCE(NULLIF(TRIM(charge_fees_from), ''), 'AdmissionMonth') AS charge_fees_from
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
        v_charge_from  := CASE WHEN p_charge_fees_from = 'SessionStart' THEN 'SessionStart' ELSE 'AdmissionMonth' END;

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
            charge_fees_from,
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
            v_charge_from,
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
            charge_fees_from                       = EXCLUDED.charge_fees_from,
            is_deleted = FALSE, is_active = TRUE,
            updated_by = p_action_user_id, updated_at = NOW();

        OPEN p_result FOR SELECT TRUE AS success, 'Saved successfully.' AS message;
    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$
