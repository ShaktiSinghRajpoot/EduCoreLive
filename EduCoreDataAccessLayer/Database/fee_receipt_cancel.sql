-- ============================================================================
-- Fee receipt CANCEL (void) — ERP → Fee → Manage Fee → Payment History
--
-- Cancelling a receipt must REVERSE exactly what core.sp_fee_payment_collect
-- applied: for every receipt line that hit a ledger row, give back the cash and
-- the concession so the due re-opens. The receipt itself is never deleted — it
-- is marked Cancelled (with reason + authoriser + who/when) for the audit trail,
-- and still re-prints (as a cancelled copy). Extras (ledger_id NULL) have no due
-- to reverse and are simply dropped from the live balance with the receipt.
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── 1. Cancellation columns on the receipt header ───────────────────────────
ALTER TABLE core.fee_payments
    ADD COLUMN IF NOT EXISTS is_cancelled         boolean      NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS cancel_reason        varchar(250),
    ADD COLUMN IF NOT EXISTS cancel_authorized_by varchar(80),
    ADD COLUMN IF NOT EXISTS cancelled_by         integer,
    ADD COLUMN IF NOT EXISTS cancelled_at         timestamptz;

-- ── 2. Cancel a receipt and reverse its ledger allocation ───────────────────
CREATE OR REPLACE PROCEDURE core.sp_fee_receipt_cancel(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_receipt_no     varchar,
    IN    p_reason         varchar,
    IN    p_authorized_by  varchar,
    INOUT p_result         refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_payment_id integer;
    v_amount     numeric(12,2);
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR p_receipt_no IS NULL THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;
    IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
        RAISE EXCEPTION 'A reason is required to cancel a receipt.';
    END IF;

    -- Lock the receipt so two cashiers can't cancel/collect it at once.
    SELECT payment_id, amount INTO v_payment_id, v_amount
    FROM core.fee_payments
    WHERE tenant_id = p_tenant_id AND school_id = p_school_id
      AND receipt_no = p_receipt_no
      AND is_cancelled = FALSE
    FOR UPDATE;

    IF NOT FOUND THEN
        OPEN p_result FOR SELECT FALSE AS success, 'Receipt not found or already cancelled.' AS message, p_receipt_no AS receipt_no;
        RETURN;
    END IF;

    -- Reverse every line that hit a real ledger row (extras have no ledger row).
    UPDATE core.student_ledger sl
    SET amount_paid = sl.amount_paid - d.amount,
        concession  = sl.concession  - d.concession,
        status      = CASE
                        WHEN (sl.amount_paid - d.amount) + (sl.concession - d.concession) <= 0 THEN 'Pending'
                        WHEN (sl.amount_paid - d.amount) + (sl.concession - d.concession) >= sl.amount_due THEN 'Paid'
                        ELSE 'Partial'
                      END,
        updated_at  = NOW()
    FROM core.fee_payment_details d
    WHERE d.payment_id = v_payment_id
      AND d.ledger_id IS NOT NULL
      AND sl.ledger_id = d.ledger_id
      AND sl.tenant_id = p_tenant_id
      AND sl.school_id = p_school_id;

    -- Mark the receipt cancelled (kept on record for audit).
    UPDATE core.fee_payments
    SET is_cancelled         = TRUE,
        cancel_reason        = trim(p_reason),
        cancel_authorized_by = NULLIF(trim(p_authorized_by), ''),
        cancelled_by         = p_action_user_id,
        cancelled_at         = NOW()
    WHERE payment_id = v_payment_id;

    OPEN p_result FOR
    SELECT TRUE AS success,
           'Receipt ' || p_receipt_no || ' cancelled. ' || to_char(v_amount, 'FM999999990.00') || ' reversed.' AS message,
           p_receipt_no AS receipt_no;
END;
$procedure$;

-- ── 3. History now shows cancelled receipts too (flagged) ───────────────────
CREATE OR REPLACE PROCEDURE core.sp_fee_payment_history_get(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_student_id     integer,
    INOUT p_result         refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR p_student_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;

    OPEN p_result FOR
    SELECT receipt_no,
           payment_date,
           amount,
           concession_total,
           payment_mode,
           reference_no,
           is_cancelled,
           cancel_reason
    FROM core.fee_payments
    WHERE tenant_id = p_tenant_id
      AND school_id = p_school_id
      AND student_id = p_student_id
      AND is_active = TRUE
    ORDER BY payment_date DESC, payment_id DESC;
END;
$procedure$;
