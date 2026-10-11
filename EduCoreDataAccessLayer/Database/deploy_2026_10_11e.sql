-- ============================================================================
-- Deploy bundle E (2026-10-11): live bus tracking. Run AFTER bundles A-D.
-- Re-runnable.   psql "<connection>" -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_11e.sql
-- ============================================================================

\set ON_ERROR_STOP on

\ir transport_live_tracking.sql
\ir school_purge.sql
