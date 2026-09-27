-- ============================================================================
-- SUPERSEDED. This file contains an EARLIER revision of
-- core.sp_fee_payment_collect. The live definition is in fee_payment_tenders.sql
-- (it takes p_tenders and p_advance_used, which this one does not).
--
-- Re-running this file would CREATE OR REPLACE the proc with the older shape and
-- silently drop split-tender payments and advance adjustment. Kept only for the
-- history of how the fee flow was built up.
-- ============================================================================

-- ============================================================================
-- Fee Collection — full counter flow (ERP → Fee → Manage Fee)
--
-- Makes the Fee Collection counter a complete, correct flow:
--   1. Per-item payment: the cashier ticks specific dues and pays each (full or
--      partial), optionally granting a concession (discount/waiver) per item.
--   2. The payment is allocated to EXACTLY the ledger rows the cashier picked
--      (no more silent oldest-first allocation that disagreed with the receipt).
--   3. Every receipt stores its line items, so receipts can be re-printed and a
--      student's payment history can be listed.
--
-- New objects:
--   • core.student_ledger.concession        (column)  — waiver granted on a due
--   • core.fee_payments.concession_total     (column)  — total waiver on a receipt
--   • core.fee_payment_details               (table)   — receipt line items
--   • core.sp_fee_payment_collect            (proc)    — item-based collection
--   • core.sp_fee_payment_history_get        (proc)    — receipts for a student
--   • core.sp_fee_receipt_get                (proc)    — one receipt + its lines
--   • core.sp_student_dues_get               (proc)    — now nets off concession
--
-- The old core.sp_fee_payment_record (lump-sum, oldest-first) is left untouched;
-- the admission "collect at admission" flow still uses it.
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── 1. Concession columns ───────────────────────────────────────────────────
ALTER TABLE core.student_ledger
    ADD COLUMN IF NOT EXISTS concession numeric(12,2) NOT NULL DEFAULT 0;

ALTER TABLE core.fee_payments
    ADD COLUMN IF NOT EXISTS concession_total numeric(12,2) NOT NULL DEFAULT 0;

-- ── 2. Receipt line items ───────────────────────────────────────────────────
-- One row per due that a receipt paid towards. Lets us re-print a receipt and
-- show exactly what each payment covered.
CREATE TABLE IF NOT EXISTS core.fee_payment_details
(
    detail_id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    payment_id        integer       NOT NULL REFERENCES core.fee_payments(payment_id) ON DELETE CASCADE,
    ledger_id         integer       NOT NULL,
    fee_head_name     varchar(100)  NOT NULL,
    installment_label varchar(40),
    amount            numeric(12,2) NOT NULL DEFAULT 0,   -- cash collected for this line
    concession        numeric(12,2) NOT NULL DEFAULT 0    -- waiver granted on this line
);

CREATE INDEX IF NOT EXISTS idx_fee_payment_details_payment
    ON core.fee_payment_details(payment_id);

-- ── 3. Student dues — outstanding now nets off concession ───────────────────
CREATE OR REPLACE PROCEDURE core.sp_student_dues_get(
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
    SELECT
        ledger_id,
        fee_head_name,
        frequency,
        installment_label,
        due_date,
        amount_due,
        amount_paid,
        concession,
        (amount_due - amount_paid - concession) AS outstanding
    FROM core.student_ledger
    WHERE tenant_id  = p_tenant_id
      AND school_id  = p_school_id
      AND student_id = p_student_id
      AND amount_due > amount_paid + concession
    ORDER BY due_date NULLS LAST, ledger_id;
END;
$procedure$;

-- ── The collect procedure is not defined here any more ─────────────────────
--  core.sp_fee_payment_collect used to be re-created at this point, with
--  whatever this migration added. It is now owned by ONE file, **fee_advance.sql**,
--  which carries the full signature (tenders AND advance) that the application
--  actually calls.
--
--  Five files defined this procedure. It collects money, and two versions of it
--  were live at once -- a 16-arg without p_advance_used and a 17-arg with it --
--  because each file created its own signature and none dropped the last. A
--  caller that omitted one parameter got "procedure is not unique" rather than a
--  payment. Re-running an older file also reverted whatever the newer ones had
--  added, silently.
--
--  What this file still owns: the tables and the read procedures above -- it is where the fee ledger and payment tables come from.
