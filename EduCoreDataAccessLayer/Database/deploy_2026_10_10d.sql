-- ============================================================================
-- Deploy bundle D for 2026-10-10: new features. Run AFTER bundles A, B and C
-- (all live). Every script is re-runnable and drops the old signature of any
-- proc whose parameters changed.
--
--     psql "<connection>" -v ON_ERROR_STOP=1 -f deploy_2026_10_10d.sql
--
-- Do NOT re-run hotfix_2026_10_10.sql afterwards (older exam/calendar/transport
-- procs).
-- ============================================================================

\set ON_ERROR_STOP on

-- 1. Exam results: grade scale, publish step, rank, result sheet
\ir exam_results_publish.sql
\ir exam_marks.sql
\ir exam_result_student.sql
\ir exam_schedule.sql

-- 2. Inventory: locations, transfers, returns to supplier, suppliers
--    (also fixes the purchase list/save/cancel cursor bug)
\ir inventory.sql

-- 3. Payroll permission, Defaulters session filter, remove logo, landline
\ir payroll_permissions.sql
\ir fee_reports.sql
\ir sp_school_admin_basic_profile_manage.sql

-- 4. Per-weekday bell schedules, timetable per day, calendar date ranges
\ir period_structure.sql
\ir timetable.sql
\ir school_calendar.sql

-- 5. Purge covers the new tables
\ir school_purge.sql
