-- ============================================================================
-- Deploy bundle F (2026-10-11): default permissions for the built-in roles
-- (Teacher, Accountant, Receptionist) on every school where they have none,
-- and on every new school. Run AFTER bundles A-E. Re-runnable.
--   psql "<connection>" -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_11f.sql
-- ============================================================================

\set ON_ERROR_STOP on

\ir builtin_role_defaults.sql
\ir sp_school_manage.sql
