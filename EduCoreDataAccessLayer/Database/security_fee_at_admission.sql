-- ============================================================================
-- Security Deposit at Admission
--  Adds a per-school configurable one-time security deposit to the Admission
--  Workflow settings. When enabled, the admission form adds it to the due-now
--  charges and it flows into the student fee plan + ledger like any one-time fee.
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── 1. Workflow setting columns ─────────────────────────────────────────────
ALTER TABLE core.school_admission_workflow_settings
    ADD COLUMN IF NOT EXISTS enable_security_fee boolean        NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS security_fee_amount numeric(12,2)  NOT NULL DEFAULT 0;

-- ── 2. Replace the workflow manage proc (adds the new params) ───────────────
--  Drop the existing 11-arg signature first (CREATE OR REPLACE would create a
--  second overload and make calls ambiguous).
DROP PROCEDURE IF EXISTS core.sp_school_admin_admission_workflow_manage(
    varchar, integer, integer, integer, boolean, boolean, boolean, numeric,
    boolean, varchar, boolean, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_school_admin_admission_workflow_manage(
    IN    p_operation                              varchar,
    IN    p_tenant_id                              integer,
    IN    p_school_id                              integer,
    IN    p_action_user_id                         integer,
    IN    p_enable_registration                    boolean       DEFAULT NULL,
    IN    p_registration_required_before_admission boolean       DEFAULT NULL,
    IN    p_enable_registration_fee                boolean       DEFAULT NULL,
    IN    p_registration_fee_amount                numeric       DEFAULT NULL,
    IN    p_auto_generate_registration_number      boolean       DEFAULT NULL,
    IN    p_registration_number_prefix             varchar       DEFAULT NULL,
    IN    p_collect_fee_at_admission               boolean       DEFAULT NULL,
    IN    p_enable_security_fee                     boolean       DEFAULT NULL,
    IN    p_security_fee_amount                     numeric       DEFAULT NULL,
    INOUT p_result                                 refcursor     DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_enable_reg  boolean;
    v_required    boolean;
    v_enable_fee  boolean;
    v_fee_amount  numeric(12,2);
    v_auto_num    boolean;
    v_prefix      varchar(20);
    v_collect     boolean;
    v_enable_sec  boolean;
    v_sec_amount  numeric(12,2);
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
            registration_fee_amount,
            auto_generate_registration_number,
            registration_number_prefix,
            collect_fee_at_admission,
            enable_security_fee,
            security_fee_amount
        FROM core.school_admission_workflow_settings
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND COALESCE(is_deleted, FALSE) = FALSE
        LIMIT 1;

    ELSIF p_operation = 'SaveAdmissionWorkflow' THEN
        v_enable_reg := COALESCE(p_enable_registration, FALSE);
        v_required   := v_enable_reg AND COALESCE(p_registration_required_before_admission, FALSE);
        v_enable_fee := v_enable_reg AND COALESCE(p_enable_registration_fee, FALSE);
        v_fee_amount := CASE WHEN v_enable_fee THEN COALESCE(p_registration_fee_amount, 0) ELSE 0 END;
        v_auto_num   := COALESCE(p_auto_generate_registration_number, TRUE);
        v_prefix     := COALESCE(NULLIF(trim(p_registration_number_prefix), ''), 'REG-');
        v_collect    := COALESCE(p_collect_fee_at_admission, FALSE);
        v_enable_sec := COALESCE(p_enable_security_fee, FALSE);
        v_sec_amount := CASE WHEN v_enable_sec THEN COALESCE(p_security_fee_amount, 0) ELSE 0 END;

        IF v_fee_amount < 0 THEN
            RAISE EXCEPTION 'Registration fee amount cannot be negative.';
        END IF;
        IF v_sec_amount < 0 THEN
            RAISE EXCEPTION 'Security deposit amount cannot be negative.';
        END IF;

        INSERT INTO core.school_admission_workflow_settings
        (
            tenant_id, school_id,
            enable_registration, registration_required_before_admission,
            enable_registration_fee, registration_fee_amount,
            auto_generate_registration_number, registration_number_prefix,
            collect_fee_at_admission,
            enable_security_fee, security_fee_amount,
            created_by, created_at, is_deleted, is_active
        )
        VALUES
        (
            p_tenant_id, p_school_id,
            v_enable_reg, v_required,
            v_enable_fee, v_fee_amount,
            v_auto_num, v_prefix,
            v_collect,
            v_enable_sec, v_sec_amount,
            p_action_user_id, NOW(), FALSE, TRUE
        )
        ON CONFLICT (tenant_id, school_id) DO UPDATE
        SET enable_registration                    = EXCLUDED.enable_registration,
            registration_required_before_admission = EXCLUDED.registration_required_before_admission,
            enable_registration_fee                = EXCLUDED.enable_registration_fee,
            registration_fee_amount                = EXCLUDED.registration_fee_amount,
            auto_generate_registration_number      = EXCLUDED.auto_generate_registration_number,
            registration_number_prefix             = EXCLUDED.registration_number_prefix,
            collect_fee_at_admission               = EXCLUDED.collect_fee_at_admission,
            enable_security_fee                    = EXCLUDED.enable_security_fee,
            security_fee_amount                    = EXCLUDED.security_fee_amount,
            is_deleted = FALSE, is_active = TRUE,
            updated_by = p_action_user_id, updated_at = NOW();

        OPEN p_result FOR SELECT TRUE AS success, 'Saved successfully.' AS message;
    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;
