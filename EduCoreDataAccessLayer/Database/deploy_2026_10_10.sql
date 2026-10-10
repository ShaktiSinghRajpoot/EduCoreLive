-- ============================================================================
-- Deploy bundle for the 2026-10-10 test-and-fix pass (School Settings pages +
-- enquiry / registration / admission / fee money trail). Runs every changed
-- script in dependency order. Each script is re-runnable.
--
-- Run from this folder (psql resolves \ir relative to this file):
--     psql "<connection>" -v ON_ERROR_STOP=1 -f deploy_2026_10_10.sql
--
-- On Railway: take a dashboard backup first. fee_head_identity.sql rewrites
-- existing billing-cycle spellings, registration_fee_partial.sql re-syncs the
-- registration paid flag, and fee_money_guards.sql adds CHECK constraints
-- (it verifies the data first and stops if a row would fail).
-- ============================================================================

\set ON_ERROR_STOP on

-- 1. Scope + permissions
\ir school_scope_fk.sql
\ir fee_permissions_split.sql

-- 2. School Settings pages
\ir sp_school_admin_basic_profile_manage.sql
\ir subject_management.sql
\ir class_teacher_session_compat.sql
\ir period_structure.sql
\ir academic_year_class_section_fixes.sql
\ir fee_head_identity.sql
\ir fee_structure_manage.sql
\ir fee_head_list.sql
\ir fee_head_cascade_delete.sql

-- 3. Student money lifecycle (adds ledger columns the fee procs read)
\ir student_money_lifecycle.sql
\ir student_master_fields.sql
\ir transport_module.sql
\ir student_exit.sql
\ir student_promotion.sql
\ir student_update.sql
\ir transfer_certificate.sql
\ir student_list.sql

-- 4. Enquiry / registration
\ir enquiry_registration.sql
\ir registration_fee_partial.sql
\ir registration_manage.sql
\ir enquiry_crm_manage.sql

-- 5. Collection, refund, cancel, guards
\ir fee_refund.sql
\ir fee_advance.sql
\ir fee_receipt_cancel.sql
\ir fee_money_guards.sql
\ir student_dues_refundable.sql

-- 6. Day close and reports (fee_day_close.sql first: the others use its functions)
\ir fee_day_close.sql
\ir fee_reports.sql
\ir dashboard_summary.sql
\ir fee_due_list.sql
\ir fee_concession_cancel_report.sql
\ir fee_refund_register.sql
\ir fee_reminder_log.sql
