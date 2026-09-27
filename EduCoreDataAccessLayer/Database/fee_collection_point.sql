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

-- ── 2. The procedure moved ─────────────────────────────────────────────────
--  core.sp_school_admin_fee_head_manage used to be defined here, with the two
--  new parameters this migration added. It is now owned by
--  **fee_head_identity.sql**, which rewrote it to protect the fee head name:
--  case-insensitive uniqueness, a rename that carries into the ledger, and
--  validation of the amount, billing cycle and collection point.
--
--  The definition was deleted from this file rather than left sitting here,
--  because a re-run would have silently reverted all of that -- this repo
--  already has seven files racing to define the admission workflow procedure,
--  and that is how they drift. The columns and the backfill above are still
--  this file's job and are still safe to re-run.
