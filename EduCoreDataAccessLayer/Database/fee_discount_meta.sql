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
-- Fee Collection — persist the DISCOUNT metadata (type + value + reason)
--
-- The counter applies ONE discount per receipt (flat ₹ or %, with a reason) and
-- spreads it across the picked dues as per-line concession. The concession
-- AMOUNT was already stored (fee_payments.concession_total + per-line). This
-- adds the missing "why": discount_type / discount_value / discount_reason on
-- the receipt header, written by sp_fee_payment_collect and returned by
-- sp_fee_receipt_get so it can print on the receipt.
--
-- The collect proc is DROP-then-CREATE (3 new params) so exactly ONE overload
-- remains. Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── 1. Discount metadata on the receipt header ──────────────────────────────
ALTER TABLE core.fee_payments
    ADD COLUMN IF NOT EXISTS discount_type   varchar(10),               -- 'Flat' | 'Percent'
    ADD COLUMN IF NOT EXISTS discount_value  numeric(12,2) NOT NULL DEFAULT 0,  -- entered value (₹ or %)
    ADD COLUMN IF NOT EXISTS discount_reason varchar(250);

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
--  What this file still owns: the discount_type / discount_value / discount_reason columns on core.fee_payments.
