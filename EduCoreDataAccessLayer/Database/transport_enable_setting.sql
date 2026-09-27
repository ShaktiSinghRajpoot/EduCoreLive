-- ============================================================================
-- Enable Transport module per school
--  Adds a per-school on/off switch to the Admission Workflow settings. When OFF,
--  the school sees no Transport UI at all — the Transport side-menu (Routes /
--  Vehicles / Assign) and the "School Transport" panel on the admission form are
--  hidden. A school that does not run buses simply turns this off.
--
--  Default is TRUE so existing schools keep their current behaviour (transport
--  visible). The flag only hides UI; it never touches already-billed transport
--  dues in the ledger.
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── 1. Workflow setting column ──────────────────────────────────────────────
ALTER TABLE core.school_admission_workflow_settings
    ADD COLUMN IF NOT EXISTS enable_transport boolean NOT NULL DEFAULT TRUE;

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
--  What this file still owns: the enable_transport column.
