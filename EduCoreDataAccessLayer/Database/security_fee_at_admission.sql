-- ============================================================================
-- Security Deposit at Admission
--  Adds a per-school configurable one-time security deposit to the Admission
--  Workflow settings. When enabled, the admission form adds it to the due-now
--  charges and it flows into the student fee plan + ledger like any one-time fee.
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── 1. Workflow setting columns ─────────────────────────────────────────────
ALTER TABLE core.school_admission_workflow_settings
    ADD COLUMN IF NOT EXISTS enable_security_fee boolean        NOT NULL DEFAULT FALSE;

-- security_fee_amount was added here too. It is deliberately NOT re-added: the
-- amount moved to a Fee Head, and workflow_drop_dead_amount_columns.sql dropped
-- the column. Leaving the ADD here put it back every time this file ran, which
-- is the same "an old migration undoes a newer one" problem as the procedure
-- below, one layer down.

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
--  What this file still owns: the enable_security_fee column and its backfill.
