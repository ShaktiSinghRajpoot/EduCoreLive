-- ============================================================================
-- Deploy bundle B for 2026-10-10: second test-and-fix pass (login / roles /
-- super admin, attendance / exams / timetable / calendar, students / transport /
-- TC / ID card, inventory). Run AFTER deploy_2026_10_10.sql and
-- hotfix_2026_10_10.sql (both already live). Every script is re-runnable.
--
--     psql "<connection>" -v ON_ERROR_STOP=1 -f deploy_2026_10_10b.sql
--
-- Do NOT re-run hotfix_2026_10_10.sql after this: it holds older copies of the
-- exam, calendar and transport procs and would undo this bundle's fixes.
--
-- Note: access_security_hardening.sql switches OFF the login of every staff
-- member already marked Inactive (it never touches a school's last admin).
-- ============================================================================

\set ON_ERROR_STOP on

-- 1. Edit history tables first (school_purge.sql deletes from them)
\ir academics_edit_history.sql

-- 2. Login, roles, super admin
\ir access_security_hardening.sql
\ir change_password.sql
\ir forgot_password.sql
\ir sp_rbac_manage.sql
\ir sp_staff_manage.sql
\ir sp_school_manage.sql
\ir school_purge.sql
\ir fee_permissions_split.sql
\ir class_teacher_session_compat.sql

-- 3. Attendance, exams, timetable, calendar
\ir school_calendar.sql
\ir student_attendance.sql
\ir attendance_student.sql
\ir attendance_report.sql
\ir exam_marks.sql
\ir exam_result_student.sql
\ir exam_schedule.sql
\ir timetable.sql

-- 4. Inventory
\ir inventory.sql

-- 5. Students, transport, TC, ID card
\ir transport_module.sql
\ir transfer_certificate.sql
\ir student_update.sql
\ir student_photo.sql
\ir student_list.sql
\ir student_master_fields.sql
\ir student_exit.sql
