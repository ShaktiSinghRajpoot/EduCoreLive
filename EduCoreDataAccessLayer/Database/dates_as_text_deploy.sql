-- ============================================================================
-- Deploy the "dates as text" change to a database.
--
-- Run from THIS directory so the \i paths resolve:
--     psql "<connection string>" -v ON_ERROR_STOP=1 -f dates_as_text_deploy.sql
--
-- Order matters: the columns change type first, then every procedure that
-- touches one is reloaded with its ::date casts. Both halves are re-runnable,
-- so a failed run can simply be run again once the cause is fixed.
--
-- The application code for this change must ship WITH it, not before or after:
-- the services read these columns as text and send dates as ISO strings.
-- ============================================================================

\echo '== 1/2  schema: date columns -> varchar(10) =='
\i dates_as_text.sql

\echo '== 2/2  procedures: ::date casts =='
\i academic_session_rollover.sql
\i attendance_report.sql
\i attendance_student.sql
\i dashboard_summary.sql
\i enquiry_crm_manage.sql
\i fee_concession_cancel_report.sql
\i fee_day_close.sql
\i fee_due_list.sql
\i fee_payment_tenders.sql
\i fee_reports.sql
\i inventory.sql
\i school_calendar.sql
\i staff_leave.sql
\i staff_payroll.sql
\i student_attendance.sql
\i student_master_fields.sql
\i student_update.sql
\i transport_module.sql
\i enquiry_followup.sql

\echo '== done. Verify: =='
SELECT COUNT(*) AS date_columns_left
  FROM information_schema.columns
 WHERE table_schema IN ('core','academic','config') AND data_type = 'date';
