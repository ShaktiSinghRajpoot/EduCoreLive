-- ============================================================================
-- Deploy bundle G (2026-10-11): exams.marks / fees.reopen permissions, the
-- updated built-in role defaults, and staff self-service (My Leave, My Payslip).
-- Run AFTER bundles A-F. Re-runnable.
--   psql "<connection>" -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_11g.sql
-- ============================================================================

\set ON_ERROR_STOP on

\ir permissions_exams_reopen.sql
\ir builtin_role_defaults.sql
\ir staff_self_service.sql
