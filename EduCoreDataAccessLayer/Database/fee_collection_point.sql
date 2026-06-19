-- ============================================================================
-- Fee Collection Point
--  Adds a lifecycle "collection point" and a refundable flag to fee heads, so
--  every charge knows WHEN it is first due (Registration / Admission / Recurring)
--  independent of its billing cycle (frequency). This makes Fee Head + Fee
--  Structure the single source of truth for registration fees, admission fees
--  and refundable deposits — which previously lived as raw amounts on the
--  admission workflow settings.
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── 1. Fee head columns ─────────────────────────────────────────────────────
ALTER TABLE core.school_fee_heads
    ADD COLUMN IF NOT EXISTS collection_point varchar(20) NOT NULL DEFAULT 'Recurring',
    ADD COLUMN IF NOT EXISTS is_refundable    boolean     NOT NULL DEFAULT FALSE;

-- ── 1a. Backfill: One-Time heads were previously treated as due-at-admission. ─
--  Preserve that behaviour by defaulting existing one-time heads to the Admission
--  collection point. Admins can re-point any that are really registration fees.
--  Guarded to 'Recurring' so it only seeds heads that still have the column default.
UPDATE core.school_fee_heads
   SET collection_point = 'Admission'
 WHERE frequency = 'One Time'
   AND collection_point = 'Recurring';

-- ── 2. Replace the fee head manage proc (adds the two new params) ───────────
--  Drop the existing 12-arg signature first (CREATE OR REPLACE would create a
--  second overload and make calls ambiguous).
DROP PROCEDURE IF EXISTS core.sp_school_admin_fee_head_manage(
    varchar, integer, integer, integer, integer, varchar, varchar, numeric,
    varchar, varchar, integer, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_school_admin_fee_head_manage(
    IN    p_operation        varchar,
    IN    p_tenant_id        integer,
    IN    p_school_id        integer,
    IN    p_action_user_id   integer,
    IN    p_fee_head_id      integer   DEFAULT 0,
    IN    p_fee_head_name    varchar   DEFAULT NULL,
    IN    p_frequency        varchar   DEFAULT NULL,
    IN    p_default_amount   numeric   DEFAULT 0,
    IN    p_fee_type         varchar   DEFAULT NULL,
    IN    p_fee_group        varchar   DEFAULT 'Academic',
    IN    p_collection_point varchar   DEFAULT 'Recurring',
    IN    p_is_refundable    boolean   DEFAULT FALSE,
    IN    p_display_order    integer   DEFAULT 0,
    INOUT p_result           refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    IF p_operation = 'GetFeeHead' THEN

        OPEN p_result FOR
        SELECT
            fee_head_id,
            tenant_id,
            school_id,
            fee_head_name,
            frequency,
            COALESCE(default_amount, 0) AS default_amount,
            fee_type,
            fee_group,
            COALESCE(collection_point, 'Recurring') AS collection_point,
            COALESCE(is_refundable, FALSE) AS is_refundable,
            COALESCE(display_order, 0) AS display_order,
            COALESCE(is_active, TRUE) AS is_active
        FROM core.school_fee_heads
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND COALESCE(is_deleted, FALSE) = FALSE
        ORDER BY display_order, fee_head_name;

    ELSIF p_operation = 'GetFeeHeadById' THEN

        OPEN p_result FOR
        SELECT
            fee_head_id,
            tenant_id,
            school_id,
            fee_head_name,
            frequency,
            COALESCE(default_amount, 0) AS default_amount,
            fee_type,
            fee_group,
            COALESCE(collection_point, 'Recurring') AS collection_point,
            COALESCE(is_refundable, FALSE) AS is_refundable,
            COALESCE(display_order, 0) AS display_order,
            COALESCE(is_active, TRUE) AS is_active
        FROM core.school_fee_heads
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND fee_head_id = p_fee_head_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

    ELSIF p_operation = 'SaveFeeHead' THEN

        IF p_fee_head_id > 0 THEN

            UPDATE core.school_fee_heads
            SET
                fee_head_name    = p_fee_head_name,
                frequency        = p_frequency,
                default_amount   = COALESCE(p_default_amount, 0),
                fee_type         = p_fee_type,
                fee_group        = COALESCE(p_fee_group, 'Academic'),
                collection_point = COALESCE(p_collection_point, 'Recurring'),
                is_refundable    = COALESCE(p_is_refundable, FALSE),
                display_order    = COALESCE(p_display_order, 0),
                updated_by       = p_action_user_id,
                updated_at       = NOW()
            WHERE tenant_id = p_tenant_id
              AND school_id = p_school_id
              AND fee_head_id = p_fee_head_id
              AND COALESCE(is_deleted, FALSE) = FALSE;

        ELSE

            INSERT INTO core.school_fee_heads
            (
                tenant_id,
                school_id,
                fee_head_name,
                frequency,
                default_amount,
                fee_type,
                fee_group,
                collection_point,
                is_refundable,
                display_order,
                is_active,
                is_deleted,
                created_by,
                created_at
            )
            VALUES
            (
                p_tenant_id,
                p_school_id,
                p_fee_head_name,
                p_frequency,
                COALESCE(p_default_amount, 0),
                p_fee_type,
                COALESCE(p_fee_group, 'Academic'),
                COALESCE(p_collection_point, 'Recurring'),
                COALESCE(p_is_refundable, FALSE),
                COALESCE(p_display_order, 0),
                TRUE,
                FALSE,
                p_action_user_id,
                NOW()
            )
            ON CONFLICT (tenant_id, school_id, fee_head_name)
            DO UPDATE SET
                frequency        = EXCLUDED.frequency,
                default_amount   = EXCLUDED.default_amount,
                fee_type         = EXCLUDED.fee_type,
                fee_group        = EXCLUDED.fee_group,
                collection_point = EXCLUDED.collection_point,
                is_refundable    = EXCLUDED.is_refundable,
                display_order    = EXCLUDED.display_order,
                is_active        = TRUE,
                is_deleted       = FALSE,
                updated_by       = p_action_user_id,
                updated_at       = NOW();

        END IF;

        OPEN p_result FOR
        SELECT
            TRUE AS success,
            'Fee head saved successfully.' AS message;

    ELSIF p_operation = 'DeleteFeeHead' THEN

        UPDATE core.school_fee_heads
        SET
            is_deleted = TRUE,
            is_active = FALSE,
            updated_by = p_action_user_id,
            updated_at = NOW()
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND fee_head_id = p_fee_head_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

        OPEN p_result FOR
        SELECT
            TRUE AS success,
            'Fee head deleted successfully.' AS message;

    ELSIF p_operation = 'ToggleFeeHeadStatus' THEN

        UPDATE core.school_fee_heads
        SET
            is_active = NOT COALESCE(is_active, TRUE),
            updated_by = p_action_user_id,
            updated_at = NOW()
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND fee_head_id = p_fee_head_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

        OPEN p_result FOR
        SELECT
            TRUE AS success,
            'Fee head status updated successfully.' AS message;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;

END;
$procedure$;
