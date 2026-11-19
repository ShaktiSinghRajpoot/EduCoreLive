# Parent module (Phase 1: view only)

Parents log in with the mobile number saved on their child's record and a one-time
code, and see their own children. Nothing a parent does changes school data.

SQL: `EduCoreDataAccessLayer/Database/parent_module.sql` (idempotent).

## Switching it on for a school

1. **Super Admin**: Schools > Modules > tick **Parent App** > Save. (Off by default,
   also off in the Basic / Standard / Full presets.)
2. **School Admin**: Settings > Modules & Workflow > **Parent App** on, and tick the
   screens parents should see (Fees, Receipts, Results, Homework, Timetable, Notices).
3. Parents open `/parent/login` (linked from the staff login page and the website).

Taking Parent App away (either level) refuses that school's parents at their next
request. Links, blocks and logs are kept; giving it back restores access.

## Config

`ParentLogin:StaticOtp` (env var `ParentLogin__StaticOtp`). Empty in the committed
`appsettings.json`.

- **Set**: that code works for every mobile linked to a child; no code is sent. For
  use until an SMS / WhatsApp provider is wired. Do not commit a value.
- **Empty**: a random 6-digit code is sent through `INotificationService`
  (SMS + WhatsApp). While those channels are disabled the code is only written to the
  app log (`[SMS disabled] would send ...`).

## How it works

- **Login** (`Areas/Parent/Controllers/ParentAccountController.cs`): mobile > "Send
  code" > code page. The reply is the same whether or not the number is on a record.
  The code is stored hashed with the mobile (`core.parent_login_codes`), valid 10
  minutes; 5 wrong codes lock the mobile for 15 minutes. Both forms use the `otp` rate
  limiter (5 per 5 minutes per IP, shared with Forgot Password) and show "Too many
  attempts, try again in N minutes".
- **Cookie**: its own scheme `Parent` (cookie `EduCore.Parent`, 30 days sliding),
  policy `ParentOnly` (`Helpers/ParentAuth.cs`, `Program.cs`). The staff scheme is the
  default, so on a staff page a parent is simply not signed in. A person who is also
  staff uses the two logins separately.
- **Which children**: `core.sp_parent_children(mobile)`: students whose Mobile or
  Alternate mobile is the number (last 10 digits), in a school whose Parent App is given
  and on and that can sign in, not blocked for that mobile, and either active or left
  within the last 12 months (left = only Home, Receipts, Results). Read again on every
  parent request (`ParentController.OnActionExecutionAsync`), so a changed number, a
  block or a module taken away works at once. An empty list signs the parent out.
- **Child check**: every page takes `c` (student id) and looks it up in that list:
  not found = 404 page. All reads use the child's own tenant and school ids.
- **Screens** (`Areas/Parent/Models/ParentPageModels.cs`, `ParentScreens.Refusal`):
  the same rule hides a tab and refuses its URL (403 page).

  | Screen | Needs | Data |
  |---|---|---|
  | Home | - | child card (class, roll, class teacher, photo via `/parent/photo`) |
  | Attendance | Attendance module | `core.sp_attendance_student` + school calendar |
  | Fees | Fees module + "Fees" | `core.sp_student_dues_get` (same as Collect Fees, old sessions included) |
  | Receipts | Fees module + "Receipts" | payment history; re-print page; no canceller, no reason |
  | Results | Exams module + "Results" | `core.sp_exam_result_student` (published results only) |
  | Homework, Timetable | Academics module + switch | the child's own section |
  | Notices | "Notices" | `core.sp_parent_notices` (Everyone / Parents / the child's class) + calendar |

- **Staff side**: Student profile > **Parent Access** card (the record's mobiles, last
  parent login, Block / Unblock for this child only; `students.manage` to change).
  Students > **Parent Logins** (School Admin): by class, logged in / never, and the latest
  logins and receipt / report-card views (`core.parent_access_log`).

## Not in Phase 1

Online payment, leave requests, messages to the teacher, contact changes, app
notifications, bus location. The Choose Role page does not offer "Parent".
