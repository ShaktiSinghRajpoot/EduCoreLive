-- ============================================================================
-- Collect Fee at Admission
--  1. Adds the "collect_fee_at_admission" workflow setting.
--  2. Adds a payments/receipts layer (fee_payments + receipt_counters) and a
--     proc that records a payment, issues a receipt number, and allocates the
--     amount across the student's outstanding ledger dues (oldest first).
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── 1. Workflow setting column ──────────────────────────────────────────────
ALTER TABLE core.school_admission_workflow_settings
    ADD COLUMN IF NOT EXISTS collect_fee_at_admission boolean NOT NULL DEFAULT FALSE;

-- ── The procedure is not defined here any more ─────────────────────────────
--  core.sp_school_admin_admission_workflow_manage used to be re-created at this
--  point, with whatever parameters this migration added. It is now owned by ONE
--  file, **fee_charge_from_per_year.sql**, and only that file defines it.
--
--  Eight files used to define this procedure. Each one was correct on the day it
--  was written and every one of them says "safe to re-run", so running an older
--  one reverted everything the newer ones had added -- silently, with no error.
--  That is not hypothetical: fee_collection_point.sql was still holding a stale
--  copy of the fee head procedure hours after it had been rewritten, and would
--  have undone the whole of it.
--
--  What this file still owns: the collect_fee_at_admission column.
