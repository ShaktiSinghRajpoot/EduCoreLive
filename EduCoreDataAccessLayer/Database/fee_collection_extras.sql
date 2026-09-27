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
-- Fee Collection — ad-hoc extra charges + payer-agnostic receipt
--
--   1. Receipt lines can now be "extra charges" not tied to a ledger due
--      (e.g. a late fine or a lost-book charge typed at the counter).
--      core.fee_payment_details.ledger_id becomes nullable and gains line_type.
--   2. core.sp_fee_payment_collect accepts an extra-charges array and records
--      each as a detail line (no ledger update), adding it to the receipt total.
--   3. core.sp_fee_receipt_get works for BOTH student-keyed (admission / manage
--      fee) and enquiry-keyed (registration) receipts, so one receipt component
--      serves every flow.
--
-- Target DB: PostgreSQL (educore). Safe to re-run. Builds on fee_collection_full_flow.sql.
-- ============================================================================

-- ── 1. Extra-charge support on receipt lines ────────────────────────────────
ALTER TABLE core.fee_payment_details
    ALTER COLUMN ledger_id DROP NOT NULL;

ALTER TABLE core.fee_payment_details
    ADD COLUMN IF NOT EXISTS line_type varchar(20) NOT NULL DEFAULT 'Due';   -- 'Due' | 'Extra'

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
--  What this file still owns: the nullable ledger_id and the line_type column on core.fee_payment_details.
