-- ============================================================================
-- Remove fee amounts from Admission Workflow Settings
--  Fee amounts (registration fee, security deposit) are now master data defined
--  as Fee Heads (School Settings → Fee Head, Collection Point = Registration /
--  Admission). The workflow settings keep only process toggles. This proc drops
--  the two amount parameters and stops writing the amount columns.
--
--  The registration_fee_amount / security_fee_amount columns are intentionally
--  LEFT IN PLACE (unused) to avoid a destructive migration; a later cleanup may
--  drop them once nothing reads them.
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- Drop the previous 14-arg signature (with the two numeric amount params).
DROP PROCEDURE IF EXISTS core.sp_school_admin_admission_workflow_manage(
    varchar, integer, integer, integer, boolean, boolean, boolean, numeric,
    boolean, varchar, boolean, boolean, numeric, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_school_admin_admission_workflow_manage(
    IN    p_operation                              varchar,
    IN    p_tenant_id                              integer,
    IN    p_school_id                              integer,
    IN    p_action_user_id                         integer,
    IN    p_enable_registration                    boolean   DEFAULT NULL,
    IN    p_registration_required_before_admission boolean   DEFAULT NULL,
    IN    p_enable_registration_fee                boolean   DEFAULT NULL,
    IN    p_auto_generate_registration_number      boolean   DEFAULT NULL,
    IN    p_registration_number_prefix             varchar   DEFAULT NULL,
    IN    p_collect_fee_at_admission               boolean   DEFAULT NULL,
    IN    p_enable_security_fee                    boolean   DEFAULT NULL,
    INOUT p_result                                 refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_enable_reg  boolean;
    v_required    boolean;
    v_enable_fee  boolean;
    v_auto_num    boolean;
    v_prefix      varchar(20);
    v_collect     boolean;
    v_enable_sec  boolean;
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
            enable_security_fee
        FROM core.school_admission_workflow_settings
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND COALESCE(is_deleted, FALSE) = FALSE
        LIMIT 1;

    ELSIF p_operation = 'SaveAdmissionWorkflow' THEN
        v_enable_reg := COALESCE(p_enable_registration, FALSE);
        v_required   := v_enable_reg AND COALESCE(p_registration_required_before_admission, FALSE);
        v_enable_fee := v_enable_reg AND COALESCE(p_enable_registration_fee, FALSE);
        v_auto_num   := COALESCE(p_auto_generate_registration_number, TRUE);
        v_prefix     := COALESCE(NULLIF(trim(p_registration_number_prefix), ''), 'REG-');
        v_collect    := COALESCE(p_collect_fee_at_admission, FALSE);
        v_enable_sec := COALESCE(p_enable_security_fee, FALSE);

        INSERT INTO core.school_admission_workflow_settings
        (
            tenant_id, school_id,
            enable_registration, registration_required_before_admission,
            enable_registration_fee,
            auto_generate_registration_number, registration_number_prefix,
            collect_fee_at_admission,
            enable_security_fee,
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
            is_deleted = FALSE, is_active = TRUE,
            updated_by = p_action_user_id, updated_at = NOW();

        OPEN p_result FOR SELECT TRUE AS success, 'Saved successfully.' AS message;
    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;
