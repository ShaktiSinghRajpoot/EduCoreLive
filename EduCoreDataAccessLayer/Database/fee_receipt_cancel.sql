-- ============================================================================
-- Fee receipt CANCEL (void) — ERP → Fee → Manage Fee → Payment History
--
-- Cancelling a receipt must REVERSE exactly what was applied: for every receipt
-- line that hit a ledger row, give back the cash and the concession so the due
-- re-opens, and mirror the advance wallet. The receipt itself is never deleted —
-- it is marked Cancelled (reason, authoriser, cancelled_by, cancelled_at) for
-- the audit trail, and still re-prints as a CANCELLED copy. Extras (ledger_id
-- NULL) have no due to reverse and drop out of the live balance with the receipt.
--
-- A cancel is refused when reversing it would rewrite money that has already
-- moved on:
--   • a line's ledger row has been REFUNDED (the cash already went back out;
--     reversing would leave the row "refunded" more than it was paid);
--   • the advance this receipt CREDITED has since been spent (reversing would
--     drive the wallet negative). Cancel the receipts that used it first.
--
-- A REGISTRATION receipt has no ledger lines. Cancelling one recomputes the
-- enquiry's registration_fee_paid from its live receipts, and -- if the enquiry
-- has already become a student -- raises a due on the student's ledger for the
-- reversed amount, so it is chased instead of silently forgotten.
--
-- Old receipts can be cancelled on a later day; the reversal belongs to the
-- day it was cancelled (cancelled_at), which is how day close reads it. So a
-- cashier who has already closed TODAY cannot cancel until an admin re-opens it.
--
-- Needs core.fn_user_display_name (fee_advance.sql) and core.fn_fee_day_closed
-- (fee_day_close.sql).
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
    v_payment_id   integer;
    v_amount       numeric(12,2);
    v_student_id   integer;
    v_enquiry_id   integer;
    v_type         varchar(20);
    v_adv_credit   numeric(12,2);
    v_adv_used     numeric(12,2);
    v_balance      numeric(12,2);
    v_refunded     varchar(200);
    v_extra_msg    text := '';
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR p_receipt_no IS NULL THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;
    IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
        RAISE EXCEPTION 'A reason is required to cancel a receipt.';
    END IF;

    -- The reversal belongs to TODAY for the cashier doing it. If that cashier
    -- has already closed today, cancelling now would change a closed day.
    IF core.fn_fee_day_closed(p_tenant_id, p_school_id, p_action_user_id, CURRENT_DATE) THEN
        RAISE EXCEPTION 'Today is already closed for this counter. Ask an admin to re-open the day first.';
    END IF;

    -- Lock the receipt so two cashiers can't cancel/collect it at once.
    SELECT payment_id, amount, student_id, enquiry_id, payment_type,
           COALESCE(advance_credit, 0), COALESCE(advance_used, 0)
      INTO v_payment_id, v_amount, v_student_id, v_enquiry_id, v_type, v_adv_credit, v_adv_used
    FROM core.fee_payments
    WHERE tenant_id = p_tenant_id AND school_id = p_school_id
      AND receipt_no = p_receipt_no
      AND is_cancelled = FALSE
    FOR UPDATE;

    IF NOT FOUND THEN
        OPEN p_result FOR SELECT FALSE AS success, 'Receipt not found or already cancelled.' AS message, p_receipt_no AS receipt_no;
        RETURN;
    END IF;

    -- A Transfer Certificate says the account is settled. Cancelling a receipt now
    -- would make money due on a child who has gone; void the TC first.
    IF v_student_id IS NOT NULL AND EXISTS (
           SELECT 1 FROM core.tc_register t
            WHERE t.tenant_id = p_tenant_id AND t.school_id = p_school_id
              AND t.student_id = v_student_id AND t.is_void = FALSE) THEN
        RAISE EXCEPTION 'A Transfer Certificate has been issued for this student. Void it before cancelling a receipt.';
    END IF;

    -- Lock the ledger rows this receipt touched, and refuse if any of their
    -- money has already been refunded.
    SELECT string_agg(DISTINCT sl.fee_head_name || COALESCE(' ' || sl.installment_label, ''), ', ')
      INTO v_refunded
      FROM core.student_ledger sl
      JOIN core.fee_payment_details d ON d.ledger_id = sl.ledger_id
     WHERE d.payment_id = v_payment_id
       AND sl.tenant_id = p_tenant_id AND sl.school_id = p_school_id
       AND sl.refund_amount > 0;
    PERFORM 1 FROM core.student_ledger sl
      JOIN core.fee_payment_details d ON d.ledger_id = sl.ledger_id
     WHERE d.payment_id = v_payment_id
       AND sl.tenant_id = p_tenant_id AND sl.school_id = p_school_id
       FOR UPDATE OF sl;
    IF v_refunded IS NOT NULL THEN
        RAISE EXCEPTION 'This receipt cannot be cancelled: money on % has already been refunded.', v_refunded;
    END IF;

    -- The credit this receipt put in the wallet must still be there to take back.
    IF v_student_id IS NOT NULL AND (v_adv_credit <> 0 OR v_adv_used <> 0) THEN
        SELECT COALESCE(balance, 0) INTO v_balance
          FROM core.student_advance
         WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND student_id = v_student_id
           FOR UPDATE;
        v_balance := COALESCE(v_balance, 0);
        IF v_balance - v_adv_credit + v_adv_used < -0.001 THEN
            RAISE EXCEPTION 'This receipt cannot be cancelled: the % advance it created has already been used (balance %). Cancel the receipts that used it first.',
                            to_char(v_adv_credit, 'FM999999990.00'), to_char(v_balance, 'FM999999990.00');
        END IF;
    END IF;

    -- Reverse every line that hit a real ledger row (extras have no ledger row).
    -- A line that was CLOSED (student left, class or bus changed) stays closed: the
    -- cancelled money joins the closed part instead of coming back as a due.
    UPDATE core.student_ledger sl
    SET amount_paid = sl.amount_paid - d.amount,
        concession  = sl.concession  - d.concession,
        amount_due  = CASE WHEN COALESCE(sl.closed_amount, 0) > 0
                           THEN sl.amount_due - d.amount - d.concession ELSE sl.amount_due END,
        closed_amount = CASE WHEN COALESCE(sl.closed_amount, 0) > 0
                             THEN sl.closed_amount + d.amount + d.concession ELSE sl.closed_amount END,
        status      = CASE
                        WHEN COALESCE(sl.closed_amount, 0) > 0 THEN sl.status
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

    -- Put the advance wallet back where it was: take the credit back out, put
    -- the used amount back in.
    IF v_student_id IS NOT NULL AND (v_adv_credit <> 0 OR v_adv_used <> 0) THEN
        UPDATE core.student_advance
           SET balance    = balance - v_adv_credit + v_adv_used,
               updated_at = NOW()
         WHERE tenant_id = p_tenant_id AND school_id = p_school_id
           AND student_id = v_student_id;
    END IF;

    -- Mark the receipt cancelled (kept on record for audit).
    UPDATE core.fee_payments
    SET is_cancelled         = TRUE,
        cancel_reason        = trim(p_reason),
        cancel_authorized_by = NULLIF(trim(p_authorized_by), ''),
        cancelled_by         = p_action_user_id,
        cancelled_at         = NOW()
    WHERE payment_id = v_payment_id;

    -- A registration receipt: keep the enquiry's paid flag true to its receipts,
    -- and if the family is already a student, put the money back on their account.
    IF v_type = 'Registration' THEN
        IF v_enquiry_id IS NOT NULL THEN
            UPDATE core.enquiries e
               SET registration_fee_paid =
                       (core.fn_registration_fee_settled(p_tenant_id, p_school_id, e.enquiry_id) > 0
                        AND COALESCE(e.registration_fee_amount, 0)
                            - core.fn_registration_fee_settled(p_tenant_id, p_school_id, e.enquiry_id) <= 0.005)
             WHERE e.enquiry_id = v_enquiry_id
               AND e.tenant_id = p_tenant_id AND e.school_id = p_school_id;
        END IF;

        IF v_student_id IS NOT NULL AND v_amount > 0 THEN
            INSERT INTO core.student_ledger
                (tenant_id, school_id, student_id, fee_head_name, frequency, installment_label,
                 due_date, amount_due, amount_paid, concession, status)
            VALUES
                (p_tenant_id, p_school_id, v_student_id,
                 core.fn_registration_fee_head_name(p_tenant_id, p_school_id), 'One Time',
                 left('Reversed ' || p_receipt_no, 40),
                 to_char(CURRENT_DATE, 'YYYY-MM-DD'), v_amount, 0, 0, 'Pending');
            v_extra_msg := ' ' || to_char(v_amount, 'FM999999990.00') || ' is now due on the student''s account.';
        END IF;
    END IF;

    OPEN p_result FOR
    SELECT TRUE AS success,
           'Receipt ' || p_receipt_no || ' cancelled. ' || to_char(v_amount, 'FM999999990.00') || ' reversed.' || v_extra_msg AS message,
           p_receipt_no AS receipt_no;
END;
$procedure$;

-- ── 3. History: every receipt, cancelled ones flagged, with who and when ────
-- Refund vouchers come from core.sp_fee_refund_history_get (fee_refund.sql),
-- so this cursor keeps one row per receipt.
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
           cancel_reason,
           payment_type,
           advance_used,
           advance_credit,
           created_by,
           core.fn_user_display_name(created_by)   AS collected_by,
           created_at,
           cancelled_by,
           core.fn_user_display_name(cancelled_by) AS cancelled_by_name,
           cancelled_at,
           cancel_authorized_by
    FROM core.fee_payments
    WHERE tenant_id = p_tenant_id
      AND school_id = p_school_id
      AND student_id = p_student_id
      AND is_active = TRUE
    ORDER BY payment_date DESC, payment_id DESC;
END;
$procedure$;
