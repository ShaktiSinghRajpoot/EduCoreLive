-- ============================================================================
-- Per-school FEE RECEIPT FORMAT.
--
-- Real school ERPs let each school pick how a receipt prints, because the paper
-- and printer differ:
--   A4      — full page with letterhead + full fee-head breakdown (office copy,
--             parent record). One receipt per sheet.
--   A5      — half page, compact. Two fit on an A4 sheet; the usual "counter"
--             print for day-to-day collection.
--   Thermal — 80mm roll (POS printer at the fee counter). Narrow, no letterhead
--             graphics, monospaced totals.
--
-- Stored next to the other display/format preferences (date_format, time_format,
-- currency) in core.school_settings, which the basic-profile proc already writes.
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

ALTER TABLE core.school_settings
    ADD COLUMN IF NOT EXISTS receipt_format varchar(10) NOT NULL DEFAULT 'A4';

-- Guard against typos from any caller: only the three supported formats.
ALTER TABLE core.school_settings DROP CONSTRAINT IF EXISTS chk_school_settings_receipt_format;
ALTER TABLE core.school_settings
    ADD CONSTRAINT chk_school_settings_receipt_format
    CHECK (receipt_format IN ('A4', 'A5', 'Thermal'));

-- ── Read/write the format on its own ────────────────────────────────────────
-- Kept separate from the (large) basic-profile proc so the receipt setting can be
-- changed from the Fee area without touching the school profile save path.
CREATE OR REPLACE PROCEDURE core.sp_school_receipt_format_manage(
    IN    p_operation      varchar,          -- 'Get' | 'Save'
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_receipt_format varchar   DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'receipt_format_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_format varchar(10);
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    IF p_operation = 'Save' THEN
        v_format := CASE WHEN p_receipt_format IN ('A4', 'A5', 'Thermal')
                         THEN p_receipt_format ELSE 'A4' END;

        INSERT INTO core.school_settings (tenant_id, school_id, receipt_format, created_by, created_at, is_deleted, is_active)
        VALUES (p_tenant_id, p_school_id, v_format, p_action_user_id, NOW(), FALSE, TRUE)
        ON CONFLICT (tenant_id, school_id) DO UPDATE
            SET receipt_format = EXCLUDED.receipt_format,
                updated_by     = p_action_user_id,
                updated_at     = NOW();

        OPEN p_result FOR SELECT TRUE AS success, v_format AS receipt_format;

    ELSE   -- Get
        OPEN p_result FOR
        SELECT COALESCE(NULLIF(TRIM(s.receipt_format), ''), 'A4') AS receipt_format
        FROM core.school_settings s
        WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id
          AND COALESCE(s.is_deleted, FALSE) = FALSE
        LIMIT 1;
    END IF;
END;
$procedure$;
