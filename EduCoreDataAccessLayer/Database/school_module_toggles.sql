-- ============================================================================
-- Per-school MODULE TOGGLES — extend the transport switch to the other optional
-- modules, so a small school is not shown menus it will never use.
--
-- The side menu was cut from 79 items to 45 by deleting placeholder screens; this
-- goes further and lets each school hide modules it does not run. Same mechanism
-- as the existing enable_transport flag (transport_enable_setting.sql), same
-- table, same proc, same settings page — one place a school manages modules.
--
--   enable_exams      Examinations menu (Exam Schedule / Datesheet / Marks Entry)
--   enable_inventory  Inventory menu (Items & Stock / Purchase Entry)
--   enable_payroll    Payroll & Salary and Leave Management under Staff
--
-- All default TRUE so existing schools see no change. The flags only hide UI;
-- nothing already recorded is touched.
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

ALTER TABLE core.school_admission_workflow_settings
    ADD COLUMN IF NOT EXISTS enable_exams     boolean NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS enable_inventory boolean NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS enable_payroll   boolean NOT NULL DEFAULT TRUE;

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
--  What this file still owns: the enable_exams / enable_inventory / enable_payroll columns.
