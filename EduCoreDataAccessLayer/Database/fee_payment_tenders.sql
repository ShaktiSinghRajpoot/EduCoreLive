-- ============================================================================
-- NOTE ON core.sp_fee_payment_collect IN THIS FILE.
-- This defines the 16-parameter overload (no p_advance_used). fee_advance.sql
-- later added a 17-parameter one, and BOTH now exist in the database — the app
-- calls the 17-param version. Any change to the collect logic has to be made in
-- both, or the two drift apart. The other procs in this file (day close,
-- collection register) are the live definitions.
-- ============================================================================

-- ============================================================================
-- Fee Collection — SPLIT TENDER (multiple payment modes on one receipt)
--
-- A receipt can now be paid with several modes (e.g. ₹5000 Cash + ₹5000 UPI).
-- Each mode+amount is stored in core.fee_payment_tenders. The receipt header
-- keeps a single payment_mode = the lone mode, or 'Mixed' when split.
--
-- core.v_fee_tender_lines expands every receipt into one row per mode (receipts
-- with no tender rows fall back to their header mode/amount), so Day Close and
-- the Collection Register break down by the TRUE mode, not 'Mixed'.
--
-- sp_fee_payment_collect is drop-then-recreated (adds p_tenders) → one overload.
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── 1. Tender rows ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS core.fee_payment_tenders
(
    tender_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    payment_id  integer       NOT NULL REFERENCES core.fee_payments(payment_id) ON DELETE CASCADE,
    mode        varchar(30)   NOT NULL,
    amount      numeric(12,2) NOT NULL,
    reference   varchar(60),
    created_at  timestamptz   NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_fee_payment_tenders_payment ON core.fee_payment_tenders(payment_id);

-- ── 2. Mode-line view (one row per mode per receipt) ────────────────────────
CREATE OR REPLACE VIEW core.v_fee_tender_lines AS
SELECT p.payment_id,
       p.tenant_id,
       p.school_id,
       p.created_by,
       p.payment_date,
       p.is_cancelled,
       COALESCE(t.mode,   p.payment_mode) AS mode,
       COALESCE(t.amount, p.amount)       AS amount
FROM core.fee_payments p
LEFT JOIN core.fee_payment_tenders t ON t.payment_id = p.payment_id;

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
--  What this file still owns: the fee_payment_tenders table and the view over it. Its copy of the procedure was the 16-arg one -- the stale overload that had to be dropped.
