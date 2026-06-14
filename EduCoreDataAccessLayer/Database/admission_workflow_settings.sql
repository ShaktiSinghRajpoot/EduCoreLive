-- ============================================================================
-- Admission Workflow Settings
-- Per-school configuration that drives the Enquiry -> Admission journey.
-- Lets one SaaS instance serve both "registration" schools and
-- "direct admission" schools by toggling the optional Registration stage.
--
-- Target DB: PostgreSQL (educore)
-- Safe to re-run (idempotent).
-- ============================================================================

-- ── Table ───────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS core.school_admission_workflow_settings
(
    school_admission_workflow_id            integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id                               integer NOT NULL,
    school_id                               integer NOT NULL,

    enable_registration                     boolean       NOT NULL DEFAULT FALSE,
    registration_required_before_admission  boolean       NOT NULL DEFAULT FALSE,
    enable_registration_fee                 boolean       NOT NULL DEFAULT FALSE,
    registration_fee_amount                 numeric(12,2) NOT NULL DEFAULT 0,
    auto_generate_registration_number       boolean       NOT NULL DEFAULT TRUE,
    registration_number_prefix              varchar(20)   NOT NULL DEFAULT 'REG-',

    created_by                              integer   NOT NULL,
    created_at                              timestamp without time zone NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_by                              integer,
    updated_at                              timestamp without time zone,
    deleted_by                              integer,
    deleted_at                              timestamp without time zone,
    is_deleted                              boolean   NOT NULL DEFAULT FALSE,
    is_active                               boolean   NOT NULL DEFAULT TRUE,

    CONSTRAINT chk_school_admission_workflow_scope CHECK ((tenant_id > 1) AND (school_id > 0)),
    CONSTRAINT uq_school_admission_workflow UNIQUE (tenant_id, school_id)
);

-- ── Stored procedure ────────────────────────────────────────────────────────
-- Plain typed parameters (no JSON). One proc handles read + upsert via p_operation.
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
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    -- ── Read ────────────────────────────────────────────────────────────────
    IF p_operation = 'GetAdmissionWorkflow' THEN

        OPEN p_result FOR
        SELECT
            enable_registration,
            registration_required_before_admission,
            enable_registration_fee,
            registration_fee_amount,
            auto_generate_registration_number,
            registration_number_prefix
        FROM core.school_admission_workflow_settings
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND COALESCE(is_deleted, FALSE) = FALSE
        LIMIT 1;

    -- ── Upsert ──────────────────────────────────────────────────────────────
    ELSIF p_operation = 'SaveAdmissionWorkflow' THEN

        -- Dependent flags collapse to FALSE when their parent toggle is off,
        -- mirroring the server-side normalisation in the controller.
        v_enable_reg := COALESCE(p_enable_registration, FALSE);
        v_required   := v_enable_reg AND COALESCE(p_registration_required_before_admission, FALSE);
        v_enable_fee := v_enable_reg AND COALESCE(p_enable_registration_fee, FALSE);
        v_fee_amount := CASE WHEN v_enable_fee THEN COALESCE(p_registration_fee_amount, 0) ELSE 0 END;
        v_auto_num   := COALESCE(p_auto_generate_registration_number, TRUE);
        v_prefix     := COALESCE(NULLIF(trim(p_registration_number_prefix), ''), 'REG-');

        IF v_fee_amount < 0 THEN
            RAISE EXCEPTION 'Registration fee amount cannot be negative.';
        END IF;

        INSERT INTO core.school_admission_workflow_settings
        (
            tenant_id, school_id,
            enable_registration, registration_required_before_admission,
            enable_registration_fee, registration_fee_amount,
            auto_generate_registration_number, registration_number_prefix,
            created_by, created_at, is_deleted, is_active
        )
        VALUES
        (
            p_tenant_id, p_school_id,
            v_enable_reg, v_required,
            v_enable_fee, v_fee_amount,
            v_auto_num, v_prefix,
            p_action_user_id, NOW(), FALSE, TRUE
        )
        ON CONFLICT (tenant_id, school_id) DO UPDATE
        SET enable_registration                    = EXCLUDED.enable_registration,
            registration_required_before_admission = EXCLUDED.registration_required_before_admission,
            enable_registration_fee                = EXCLUDED.enable_registration_fee,
            registration_fee_amount                = EXCLUDED.registration_fee_amount,
            auto_generate_registration_number      = EXCLUDED.auto_generate_registration_number,
            registration_number_prefix             = EXCLUDED.registration_number_prefix,
            is_deleted = FALSE,
            is_active  = TRUE,
            updated_by = p_action_user_id,
            updated_at = NOW();

        OPEN p_result FOR
        SELECT TRUE AS success, 'Saved successfully.' AS message;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;
