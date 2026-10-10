# Test cases: HR, leave and payroll

Scope: staff create / edit / deactivate / reactivate (with logins), the staff masters
(departments, designations), leave (apply, approve, reject, cancel, balance, School
Calendar day count, half days) and payroll (run, pro-rata, LOP, adjustments, mark paid,
the money trail).

SQL suite: `EduCoreDataAccessLayer/Database/tests/hr_leave_payroll_tests.sql` (runs in one
transaction, rolls back). Fixed calendar: July 2025 = 27 working days (Mon-Sat), so a salary
of 27000 is exactly 1000 a day.

- First run: **RESULT: 73 passed, 32 failed** (every failure a `BUG <id>` check).
- **After the fixes (2026-10-10): RESULT: 149 passed, 0 failed.** The `BUG` prefixes are
  gone; no check was weakened. Four checks were made stricter than the original
  (PAY-03 now needs *no* payslip, PAY-04 needs net 17000 for 17 days, PAY-17 checks the
  stored values instead of the column names, PAY-18 records real adjustments instead of
  looking for a table name) and 44 checks were added.
- `leave_payroll_tests.sql`: 29 / 0 (MARK_PAID now passes a mode + reference; working
  days come from the School Calendar function).
- Row counts of `core.staff`, `staff_leave`, `staff_payroll`, the two new payroll tables,
  `config.designations`, `config.departments`, `core.users`, `academic.school_calendar`
  were identical before and after running every suite: nothing leaked.

Stack read (live definitions confirmed with `pg_get_functiondef`):
- Web: `Areas/ERP/Controllers/{Staff,Leave,Payroll}Controller.cs`, the StaffMasters region of
  `SchoolSettingsController.cs`, `Views/Staff/*`, `Views/Leave/LeaveManagement.cshtml`,
  `Views/Payroll/PayrollManagement.cshtml`, `Views/SchoolSettings/StaffMasters.cshtml`.
- Data: `Services/Repository/ERP/StaffService.cs`, `StaffLeaveService.cs` (holds both the leave
  and the payroll service), models `StaffModel.cs`, `ERP/StaffLeaveModel.cs`, `ERP/StaffPayrollModel.cs`.
- Procs: `core.sp_staff_manage`, `core.sp_staff_list`, `config.sp_staff_masters_manage`,
  `config.sp_staff_dropdowns`, `core.sp_staff_leave_manage`, `core.sp_staff_payroll_manage`,
  `core.fn_working_days`, `academic.fn_school_day_type`; new: `core.sp_staff_login_switch`,
  `core.fn_school_working_days`, `core.fn_leave_entitlement`, `core.fn_staff_payslip_build`,
  `core.sp_staff_payroll_adjust`, `core.fn_payroll_user_name`.

---

## The real-world scenario

1. **Hire a teacher mid-month.** Priya joins on Tue 15 Jul 2025 as "TGT Teacher", salary
   27000. Staff type comes from the designation (STF-03), her code `EMP-21` cannot be reused
   as `emp-21` (STF-05), a negative salary or an invented status is refused (STF-06/07). She
   gets a login that must change its password (STF-09).
2. **Salary structure.** There is ONE `monthly_salary` per person; no component / statutory
   table exists, so the payslip shows salary, days, LOP, adjustments and net — never invented
   EPF/ESI/TDS. Each payslip snapshots the salary it used (`monthly_salary` column).
3. **Leave.** Priya cannot apply for 1-2 Jul (before joining, LV-11). In August she asks for
   Casual leave 1-15 Aug = 13 working days: refused, 12/yr is the cap (LV-09); 1-14 Aug (12)
   is accepted and the 13th day goes in as Unpaid (LV-09b/c/d). A request over a holiday
   or the school's weekly off counts only working days (LV-02/03); an exam Sunday declared a
   working day counts (LV-04). A half day counts 0.5 (LV-12b). She changes her mind about a
   pending request and cancels it with a reason (LV-01), which frees the dates (LV-01c). An
   approved leave that already started cannot be cancelled (LV-01d); one in the future can,
   and the approval stays on record (LV-01f).
4. **Monthly payroll.** July is run: Priya is paid 15 of 27 days = 15000 (PAY-02); a colleague
   with 5 unpaid days nets 22000 (PAY-01); someone on unpaid leave all month nets exactly 0
   (PAY-06); a September joiner gets nothing for July (PAY-03); a teacher on long leave
   ("On Leave") still gets a payslip (PAY-05). August cannot be run while it is in the future
   (PAY-16).
5. **Adjustments.** Priya gets 2000 arrears (Addition) and a 5000 festival advance in cash
   (Advance), both with reasons; the draft updates at once (PAY-18/18b). A 20000 deduction that
   would push her below zero is refused (PAY-18e). The arrears were entered twice: voided with
   a reason, still on record (PAY-18j).
6. **Mark paid.** The accountant pays the July slip by bank transfer with UTR `UTR-ZZ-0001`
   (PAY-17); without a mode or reference it is refused (PAY-17b/c). The trail shows GENERATED,
   ADJUSTMENT_ADDED, REGENERATED, ADJUSTMENT_VOIDED, PAID with who / when / net (PAY-19).
7. **Regenerate after payment.** A salary raise and a late unpaid day for July are entered
   after July was paid. Re-running July leaves the paid slip byte-for-byte unchanged (PAY-11)
   and the run message says one paid slip now differs (PAY-11c). Even a direct `UPDATE` is
   refused by a trigger (PAY-11d). The correction is recorded as a 1000 Deduction in August
   (PAY-18g/h, PAY-19c).
8. **Resignation and final settlement.** A teacher's last working day is Sat 19 Jul; she is
   deactivated (with that date) before the run. Her login goes off (STF-23), she leaves both
   teacher pools (STF-22), and July pays 17 of 27 days = 17000 (PAY-04); August pays nothing
   (PAY-07b). Any leave encashment or recovery is an Addition / Deduction on that last month.
   Her paid slips remain listed after she leaves (PAY-12): resigned staff keep their history,
   read-only.

---

## Business decisions (safest default, applied)

| # | Decision |
|---|---|
| D1 | A **paid payslip is never rewritten**: RUN skips it and reports when today's figures would differ; a trigger refuses any UPDATE; corrections go as an **adjustment in an unpaid month** with reason, who, when. |
| D2 | **Pro-rata by school working days**, not calendar days: `gross = salary × days employed ÷ school working days`. This is the same day unit LOP already used, so a joiner who also takes LOP is charged consistently. (The brief suggested calendar days; working days were kept because the suite's PAY-02 and the LOP rule already use them. One-line change in `fn_staff_payslip_build` if the school prefers calendar days.) |
| D3 | Amounts are worked from the salary, not from a rounded per-day rate, so an all-LOP month nets exactly 0. |
| D4 | **Working days follow the School Calendar** (weekly offs, declared holidays, declared working days; a half school day = 0.5) for leave AND payroll. |
| D5 | Leave types are a fixed list (Casual, Sick, Earned, Maternity, Comp-off, Unpaid). Yearly caps per **calendar year**: Casual 12, Sick 10, Earned 15, Maternity 90; **pending + approved** count. Beyond the cap: apply as Unpaid. Comp-off and Unpaid are uncapped (no comp-off ledger exists). A request spanning two years counts in the year it starts. |
| D6 | Leave can't overlap a pending/approved request, start before joining, run past the last working day, or be filed for an inactive person. |
| D7 | Cancel: pending always; approved only before it starts and only if no paid payslip covers it. A reason is required. The original approval stays. |
| D8 | Employee code unique per school **ignoring case and spaces** (proc check + unique index). |
| D9 | Edit-form "Inactive" = Deactivate (login off, pools, last working day); back to Active = Reactivate. A new staff member cannot be created Inactive. |
| D10 | Last working day: default today; never in the future; never before joining. Someone deactivated before their (future) joining date gets no last working day and is never paid. |
| D11 | Deactivating someone already inactive is refused (it would overwrite the first date). Reactivation clears the last working day (meant for mistakes; a rehire should also get a new joining date). |
| D12 | Payroll cannot be run (or adjusted) for a future month; the current month is allowed. |
| D13 | Mark Paid needs a mode (Cash / Bank Transfer / Cheque / UPI) and a reference unless Cash. |
| D14 | Advance = money handed over early for a month, recorded with its mode/reference and deducted from that month. A deduction that would take a draft below zero is refused; if leave approved later does it, RUN holds net at 0 and says so. |
| D15 | Renaming a department/designation renames it on the staff rows; changing a designation's staff type changes it for its staff (the staff form derives it from the designation). A deleted master row gives its name up so the name can be re-added. |
| D16 | Payroll writes stay on `staff.manage` (there is no payroll-specific permission in the catalog yet — see Open items). |

---

## A. Staff create / edit (STF)

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| STF-01 | Blank name | INSERT name `'   '` | Refused | Proc | SQL STF-01 | PASS |
| STF-02 | Create a teacher | INSERT valid row | staff_id returned | Proc | SQL STF-02 | PASS |
| STF-03 | Type from designation | send "Support" for designation Teacher | stored Teaching | Proc | SQL STF-03 | PASS |
| STF-04/04b | Duplicate code, padded duplicate | `ZZHR-001`, `'  ZZHR-001 '` | Refused | Proc | SQL STF-04, 04b | PASS |
| STF-05 | Code differing only by case | `zzhr-001` | Refused | Proc | SQL STF-05; `sp_staff_manage.sql:328`, index `uq_staff_employee_code_ci` | FAIL → **FIXED** |
| STF-06 | Negative salary | -5000 | Refused | Proc | SQL STF-06; `sp_staff_manage.sql:319` | FAIL → **FIXED** |
| STF-07 | Unknown status word | "Resigned-ish" | Refused | Proc | SQL STF-07; `sp_staff_manage.sql:312` | FAIL → **FIXED** |
| STF-07b | New staff created Inactive | INSERT status Inactive | Refused | Proc + UI | SQL STF-07b; static `Views/Staff/AddStaff.cshtml:138` (option removed) | NEW, PASS |
| STF-08/08b | Edit keeps public id, records editor | UPDATE | same uuid, updated_by | Proc | SQL | PASS |
| STF-09..09d | Login created | email mixed case, role | lower-case email, must change password, one primary role | Proc | SQL | PASS |
| STF-10/11 | Duplicate login email / phone | | Refused | Proc | SQL | PASS |
| STF-12 | Roles of another tenant / SUPER_ADMIN | role ids 1, 45 | Refused | Proc | SQL STF-12 | PASS (fixed earlier today) |
| STF-13 | Another school edits our staff | UPDATE as 23/33 | No change | Proc | SQL | PASS |
| STF-14 | Out-of-scope edit with "create login" | UPDATE as 23/33 + login | No orphan login | Proc | SQL STF-14; `sp_staff_manage.sql:247` (scope check first) | FAIL → **FIXED** |
| STF-15/16/16b | Read / public id scope | GET, fn_public_id_to_id | Nothing across schools | Proc | SQL | PASS |
| STF-17..17c | List by mobile, scope, platform | sp_staff_list | Correct rows only | Proc | SQL | PASS |
| STF-30 | Edit Staff save | Edit form POST | Saves and opens profile | UI | static `Views/Staff/EditStaff.cshtml:43` — a hidden int `id` input bound before the route uuid (form > route), failed Guid parse, and redirected every save to the list without saving | FAIL (static) → **FIXED** |
| STF-31 | Designation name XSS in the cascade | name with `<img onerror>` | Shown as text | UI-JS | static `EditStaff.cshtml:294`, `AddStaff.cshtml:245` (`.html` → `.text`) | FAIL (static) → **FIXED** |
| STF-32 | Staff type rendered raw | stored type with HTML | Encoded | UI | static `Views/Staff/StaffList.cshtml:139` (Html.Raw removed); proc whitelist `sp_staff_manage.sql:347` | FAIL (static) → **FIXED** |
| STF-33 | Deactivated designation on edit | person's designation inactive in masters | Kept on the form | UI-JS | static `EditStaff.cshtml:300` | FAIL (static) → **FIXED** |
| STF-34 | Errors from service | unexpected exception on deactivate | Logged at Error, friendly message | Service | static `StaffService.cs` RunActionAsync | **FIXED** |

## B. Status changes and the teacher pools (STF)

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| STF-20/20b | Active teacher offered | class-teacher / timetable pools | In both | Proc | SQL | PASS |
| STF-21/21b | Deactivate | DELETE | Inactive, is_active false, stamped | Proc | SQL | PASS |
| STF-21c | Last working day recorded | DELETE (no date) | = today | Proc | SQL STF-21c | NEW, PASS |
| STF-21d | Deactivate twice | DELETE again | Refused, first date kept | Proc | SQL STF-21d; `sp_staff_manage.sql:254` | NEW, PASS |
| STF-22/22b | Leaves the pools | | Gone from both | Proc | SQL | PASS |
| STF-23 | Login switched off | | users.is_active false | Proc | SQL STF-23 | PASS (fixed earlier today) |
| STF-24/24b | Reactivate | REACTIVATE | Active, login back on, last working day cleared | Proc | SQL | PASS |
| STF-25 | Another school deactivates | DELETE as 23/33 | Refused | Proc | SQL | PASS |
| STF-26 | Edit-form Inactive | UPDATE status Inactive | is_active false + stamped + login off | Proc | SQL STF-26; `sp_staff_manage.sql:533`, `:551` | FAIL → **FIXED** |
| STF-27/27b | …leaves both pools | | Gone | Proc | SQL | FAIL → **FIXED** |
| STF-27c/27d | Edit-form back to Active | UPDATE status Active | Reactivated, back in pool | Proc | SQL | NEW, PASS |
| STF-28/28b | Cleaner not offered | | In neither pool | Proc | SQL | PASS |
| STF-29 | Last working day can be held | column | core.staff.last_working_date | Proc | SQL STF-29; `sp_staff_manage.sql` ALTER at top | FAIL → **FIXED** |
| STF-29b/29c | Last working day in the future / before joining | DELETE with date | Refused | Proc | SQL | NEW, PASS |
| STF-35 | Deactivate from the profile | Profile → date → Deactivate | Date posted; errors shown on the profile | UI + Controller | static `Views/Staff/StaffProfile.cshtml:63`, `Controllers/StaffController.cs:96` | **FIXED** (was: no date at all) |
| STF-36 | Inactive badge colour | profile of inactive staff | Red / amber badge | UI | static `StaffProfile.cshtml:13` (both branches were "b-active") | **FIXED** |
| STF-37 | HR snapshot | profile | Real leave figures | UI + Controller | static `StaffController.cs:172`, `StaffProfile.cshtml:178` (was a permanent "—") | **FIXED** |
| STF-38 | Inactive list | Staff/Inactive | Shows last working day | UI | static `Views/Staff/Inactive.cshtml:85` | **FIXED** |
| STF-39 | Not-yet-joined staff deactivated | joining date in future | Allowed, no last working day | Proc | `sp_staff_manage.sql:261`; covered by platform suite (staff joining 2028) | **FIXED** |

## C. Staff masters (SM)

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| SM-01..07b | Blank / invalid type / default type / duplicates / delete in-use | | Refused / defaults | Proc | SQL | PASS |
| SM-08 | Edit keeps sort order | page sends no sortOrder (0) | sort_order kept | Proc | SQL SM-08; `staff_masters_manage.sql:213` | FAIL → **FIXED** |
| SM-08b | Edit keeps default role | page sends no defaultRoleId | kept | Proc | `staff_masters_manage.sql:212` | static, **FIXED** |
| SM-09 | Rename an in-use designation | | Staff renamed too | Proc | SQL SM-09; `staff_masters_manage.sql:221` | FAIL → **FIXED** |
| SM-09b | …then delete it | | Refused (still in use) | Proc | SQL | FAIL → **FIXED** |
| SM-10/10b | Rename a department | | Staff + designation defaults follow | Proc | SQL; `staff_masters_manage.sql:136` | FAIL → **FIXED** |
| SM-11/12 | Another tenant renames our department | | Unchanged, told "not found" | Proc | SQL; `staff_masters_manage.sql:118` | SM-12 FAIL → **FIXED** |
| SM-13 | Another tenant deletes | | Unchanged | Proc | SQL | PASS |
| SM-13b | Staff type change follows to staff | | staff_type updated | Proc | SQL | NEW, PASS |
| SM-14 | Delete unused | | Soft-deleted | Proc | SQL | PASS |
| SM-14b/14c | Re-add a deleted name | | Accepted | Proc | SQL; `staff_masters_manage.sql:124`, `:205` | FAIL → **FIXED** |
| SM-15/15b | Dropdowns | | Inactive designation and foreign roles hidden | Proc | SQL | PASS |
| SM-16 | Platform scope | tenant 1 | Refused | Proc | SQL | PASS |
| SM-17 | Staff type on the designation modal | Edit "Music Teacher" in "Music" | Type selectable (was guessed from the department name by regex) | UI-JS | static `Views/SchoolSettings/StaffMasters.cshtml:119`, `:202` | **FIXED** |
| SM-18 | Double-click / failure on save | | Busy button, failure toast | UI-JS | static `StaffMasters.cshtml:161` (`send`) | **FIXED** |

## D. Leave (LV)

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| LV-01 | Cancel a pending request | CANCEL + reason | Cancelled | Proc | SQL LV-01; `staff_leave.sql:380` | FAIL → **FIXED** |
| LV-01b..f | Who/when/why kept; dates freed; started approved refused; reason required; future approved cancellable | | as named | Proc | SQL | NEW, PASS |
| LV-02 | Holiday not a leave day | Mon-Wed, Tue holiday | 2 | Proc | SQL; `staff_leave.sql:114` (fn_school_working_days) | FAIL → **FIXED** |
| LV-03 | Weekly off not a leave day | 5-day week, Fri-Sat | 1 | Proc | SQL | FAIL → **FIXED** |
| LV-04 | Declared working Sunday | | 1 | Proc | SQL | FAIL → **FIXED** |
| LV-05..07 | Remark/time; overlap; re-apply after reject | | | Proc | SQL | PASS |
| LV-08 | Unknown type "LOP" | | Refused | Proc | SQL; `staff_leave.sql:260` | FAIL → **FIXED** |
| LV-09 | Casual beyond 12/yr | 13 days | Refused | Proc | SQL; `staff_leave.sql:328` | FAIL → **FIXED** |
| LV-09b..e | Exactly 12 ok; pending counts; rest as Unpaid (canonical spelling); BALANCE figures | | | Proc | SQL | NEW, PASS |
| LV-10 | Deactivated staff | | Refused | Proc | SQL; `staff_leave.sql:278` | FAIL → **FIXED** |
| LV-11 | Before joining | | Refused | Proc | SQL; `staff_leave.sql:281` | FAIL → **FIXED** |
| LV-12 | Half day can be recorded | | days numeric | Proc | SQL | FAIL → **FIXED** |
| LV-12b..d | Half day = 0.5; two-date half day refused; preview = apply count | | | Proc | SQL | NEW, PASS |
| LV-13..16 | NULL decision; other school decides; list scope; on-leave-today | | | Proc | SQL | PASS |
| LV-17 | Back-dated leave in the form | pick last week | Allowed | UI-JS | static: `$('#lvFrom').attr('min', todayIso())` removed from `Views/Leave/LeaveManagement.cshtml` — sick leave already taken could not be recorded, so its LOP never reached payroll; `todayIso()` was also UTC (wrong date before 05:30 IST); page now uses the school's `TODAY` (`:188`) | FAIL (static) → **FIXED** |
| LV-18 | Duration preview | Mon-Sun with a holiday | Server count | UI-JS | static `LeaveManagement.cshtml:360` (was a Sundays-only browser count) | **FIXED** |
| LV-19 | Balance in the modal | pick staff | "Left in 2026: Casual 12/12…" | UI-JS + Controller | static `LeaveController.cs:80`, page `loadBalance` | **NEW** |
| LV-20 | "On Leave" staff in the picker | | Listed | Controller | static `LeaveController.cs:32` (was Active only) | **FIXED** |
| LV-21 | Cancel button, Cancelled tab | | Reason via EC.prompt | UI-JS | static `LeaveManagement.cshtml:212`, `:299` | **NEW** |
| LV-22 | List load failure | | EC.listEmpty, no endless spinner | UI-JS | static `LeaveManagement.cshtml:350` | **FIXED** |
| LV-23 | "Approved This Month" KPI | | Only this month's | UI-JS | static `LeaveManagement.cshtml:218` (counted all time) | **FIXED** |
| LV-24 | Service logs refusals | | Warning with SqlState | Service | static `StaffLeaveService.cs` RunAsync | **FIXED** |

## E. Payroll (PAY)

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| PAY-00/01..01e | LOP split across months; amount; net; who/when; Draft | | 5 days, 5000, 22000 | Proc | SQL | PASS |
| PAY-02 | Joiner 15 Jul | | 15000 (15/27) | Proc | SQL; `staff_payroll.sql:310` | FAIL → **FIXED** |
| PAY-03 | Joins in September | | No July payslip | Proc | SQL (stricter) | FAIL → **FIXED** |
| PAY-04 | Leaver, last day 19 Jul, deactivated before run | | 1 slip, 17 days, 17000 | Proc | SQL (stricter); `staff_payroll.sql:269` | FAIL → **FIXED** |
| PAY-04b | Half-day LOP | 0.5 unpaid | 500 | Proc | SQL | NEW, PASS |
| PAY-05 | "On Leave" status | | Gets a payslip | Proc | SQL | FAIL → **FIXED** |
| PAY-06 | All-LOP month | 30000, every day unpaid | Net exactly 0 | Proc | SQL; `staff_payroll.sql:312` | FAIL → **FIXED** |
| PAY-07/07b | August LOP; no slip after last day | | 2; none | Proc | SQL | PASS / NEW |
| PAY-08 | Deactivated after the run | | July draft kept | Proc | SQL | PASS |
| PAY-09/10 | Other school pays; paid who/when | | | Proc | SQL | PASS |
| PAY-11/11b | Re-run after payment | raise + late LOP | Paid slip unchanged, one slip | Proc | SQL | PASS |
| PAY-11c | …run reports the difference | | message "paid payslip(s) differ" | Proc | SQL; `staff_payroll.sql:508` | NEW, PASS |
| PAY-11d/11e | Direct UPDATE of a paid slip / of the trail | | Refused by trigger | DB | SQL; `staff_payroll.sql:126`, `:195` | NEW, PASS |
| PAY-12..15 | Listed after leaving; dept filter; scope; month 13 | | | Proc | SQL | PASS |
| PAY-16 | Future month | | Refused | Proc | SQL; `staff_payroll.sql:472` | FAIL → **FIXED** |
| PAY-17 | Payment records mode + reference | | stored | Proc | SQL (stricter); `staff_payroll.sql:536` | FAIL → **FIXED** |
| PAY-17b..d | No reference / no mode refused; PAID row in trail | | | Proc | SQL | NEW, PASS |
| PAY-18 | Advance / deduction recordable | Addition 2000 | draft 17000 | Proc | SQL (real adjustment); `staff_payroll.sql:585` | FAIL → **FIXED** |
| PAY-18b..j | Advance deducted; advance trail; advance needs mode; over-deduction refused; reason required; paid month refused; next month accepted; before joining refused; void keeps record | | | Proc | SQL | NEW, PASS |
| PAY-19..19d | Full trail order; void in paid month refused; carried correction; idle re-run writes nothing | | | Proc | SQL | NEW, PASS |
| PAY-20 | Other school adjusts our staff | | Refused | Proc | SQL | NEW, PASS |
| PAY-21 | Department filter | | School's own departments | UI + Controller | static `PayrollController.cs:40`, `PayrollManagement.cshtml:52` (was hardcoded "Teaching / Support Staff…") | **FIXED** |
| PAY-22 | Money shown in rupees and paise | | EC.money | UI-JS | static `PayrollManagement.cshtml:263` (was `Math.round` rupees) | **FIXED** |
| PAY-23 | Mark Paid UI | | Mode + reference, EC.confirm | UI-JS | static `PayrollManagement.cshtml:142`, `:341` | **FIXED** |
| PAY-24 | Payslip money trail + adjustments UI | | History list, add/void with reason | UI-JS + Controller | static `PayrollManagement.cshtml:315`, `:422`, `:445`; `PayrollController.cs:83`, `:137`, `:149` | **NEW** |
| PAY-25 | False payslip note | | No claim about staff attendance | UI | static: note claimed LOP came from "Staff Attendance (absent + ½ half-day)", which does not exist | **FIXED** |
| PAY-26 | Service logs refusals | | Warning with SqlState / Error otherwise | Service | static `StaffLeaveService.cs` (StaffPayrollService.ExecAsync) | **FIXED** |
| PAY-27 | Purge covers the new tables | | adjustments + history deleted with the school | Proc | platform suite H12; `school_purge.sql` | **FIXED** |

## F. Leakage

| ID | Scenario | Expected | How verified | Result |
|---|---|---|---|---|
| LEAK-01..03 | Staff / payslips / leave stay in their school | 0 | SQL | PASS |

---

## Money trail map (payroll)

| Event | Where it is written | Who | When | How much | Which month | Can it change later? |
|---|---|---|---|---|---|---|
| Salary rate | `core.staff.monthly_salary` (+ snapshot `staff_payroll.monthly_salary`) | `staff.updated_by` | `updated_at` | rate | — | Rate yes; snapshot on a paid slip no |
| Generate draft | `staff_payroll` row + history `GENERATED` | `generated_by`, `action_by` | `generated_at`, `action_at` | gross, LOP, additions, deductions, net | pay_month/pay_year | Draft yes (each change → history `REGENERATED` with the old figures) |
| Draft removed (not employed) | history `DRAFT_REMOVED` (figures kept) | action_by | action_at | old figures | month | No |
| Addition / Deduction | `staff_payroll_adjustment` + history `ADJUSTMENT_ADDED` | created_by | created_at | amount, reason | month | Never edited; void only while unpaid |
| Advance | same, kind Advance, with payment_mode / reference | created_by | created_at | amount | month it is deducted from | as above |
| Void adjustment | `is_void`, `voided_by/at`, `void_reason` + history `ADJUSTMENT_VOIDED` | voided_by | voided_at | — | month | No |
| Paid | `staff_payroll.status/paid_by/paid_at/payment_mode/payment_reference` + history `PAID` | paid_by | paid_at | net_pay | month | **Never** (trigger) |
| Correction after payment | Adjustment in the next unpaid month (RUN reports the paid slip that differs) | created_by | created_at | difference | next month | as adjustment |
| Unpaid leave (LOP source) | `staff_leave` Approved / Unpaid, `decided_by/at`; cancel keeps `cancelled_by/at/reason` | decided_by | decided_at | days (0.5 steps) | dates | Cancel only before it starts and not in a paid month |

History rows are append-only (trigger `trg_staff_payroll_history_lock`) and are removed only
by the purge of their school.

---

## Fix status (every original BUG check)

All 32 fixed — see the Result column. Scripts, in apply order (each re-runnable, each ends
with `;`): `sp_staff_manage.sql` → `staff_list.sql` → `staff_masters_manage.sql` →
`staff_leave.sql` → `staff_payroll.sql` → `school_purge.sql`.

## Open items (not done, on purpose)

- No payroll-specific permission: running and paying salaries is `staff.manage`. Adding
  `payroll.manage` needs an RBAC catalog row and role grants.
- Leave entitlements are fixed in `core.fn_leave_entitlement`; there is no per-school leave
  policy screen, and no carry-forward / encashment ledger.
- No salary components or statutory deductions (EPF/ESI/PT/TDS): there is nothing configured
  to compute them from.
- The untracked bundle `Database/deploy_2026_10_10b_parts/part2.sql` holds the OLD
  `sp_staff_manage`. Running it after these scripts would create a second overload. Regenerate
  the bundle from the scripts before deploying.
