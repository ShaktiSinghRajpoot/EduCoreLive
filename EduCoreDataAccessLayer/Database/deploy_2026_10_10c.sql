-- ============================================================================
-- Deploy bundle C for 2026-10-10: staff, leave and payroll test-and-fix pass.
-- Run AFTER deploy_2026_10_10b.sql (already live). Every script is re-runnable
-- and drops the old signature of any proc whose parameters changed.
--
--     psql "<connection>" -v ON_ERROR_STOP=1 -f deploy_2026_10_10c.sql
--
-- Do NOT re-run deploy_2026_10_10b.sql afterwards without this bundle after
-- it: B holds the previous sp_staff_manage.
-- ============================================================================

\set ON_ERROR_STOP on

-- 1. Staff records and masters
\ir sp_staff_manage.sql
\ir staff_list.sql
\ir staff_masters_manage.sql

-- 2. Leave and payroll
\ir staff_leave.sql
\ir staff_payroll.sql

-- 3. Purge covers the new payroll tables
\ir school_purge.sql
