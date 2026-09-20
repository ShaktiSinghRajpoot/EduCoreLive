# Page checklist

Every page in the app, what state it is in, and what is left to do.

Audited 25 Aug 2026 against the live procs (not the `.sql` files — those drift;
see SCALING-AND-FIXES for why). Re-run the audit commands at the bottom to
refresh it.

**What each column means**

| Column | Meaning |
|---|---|
| **Real** | The page reads and writes real data. "mock" = the page invents what it shows. |
| **Guards** | The server refuses bad input — not the browser. `required` in HTML is not a guard. |
| **Scope** | Every read and write is filtered by tenant + school from the signed-in user's claims. |
| **CSRF** | Every mutating POST carries `[ValidateAntiForgeryToken]`. |
| **Tests** | Covered by a suite in `Database/tests/`. |

---

## Students & admissions

| Page | Real | Guards | Scope | CSRF | Tests |
|---|---|---|---|---|---|
| Student Directory | ✅ | ✅ | ✅ | ✅ | ✅ |
| Student Dashboard | ✅ | ✅ | ✅ | n/a | ✅ |
| Edit Student | ✅ | ✅ unknown class refused, another school's id is "not found" | ✅ | ✅ | ✅ |
| New Admission | ✅ | ✅ duplicate admission no, concession cap, fee plan | ✅ | ✅ | ✅ 28 |
| Inactive / Left | ✅ | ✅ exit status must be one of four, already-left refused | ✅ | ✅ | ✅ |
| Promote Students | ✅ | ✅ session, ladder, dues, per-student target class | ✅ | ✅ | — |

## Fees

| Page | Real | Guards | Scope | CSRF | Tests |
|---|---|---|---|---|---|
| Collect Fee | ✅ | ✅ over-payment, negative, empty selection all refused | ✅ | ✅ | ✅ 28 |
| Fee Due Reminders | ✅ | ✅ | ✅ | ✅ | — |
| Day Close | ✅ | ✅ | ✅ | ✅ | — |
| Fee Reports | ✅ | read-only | ✅ | n/a | — |
| Fee Heads / Structure | ✅ | ✅ blank name refused, cascade delete guarded | ✅ | ✅ | — |

## Enquiry & registration

| Page | Real | Guards | Scope | CSRF | Tests |
|---|---|---|---|---|---|
| Enquiry CRM | ✅ | ✅ status final after Admission Confirmed | ✅ | ✅ | ✅ 30 |
| Registration | ✅ | ✅ one number per enquiry, already-admitted refused | ✅ | ✅ | ✅ |

## Attendance & exams

| Page | Real | Guards | Scope | CSRF | Tests |
|---|---|---|---|---|---|
| Student Attendance | ✅ | ✅ future date, Sunday, back-date lock, empty register | ✅ | ✅ | ✅ 28 |
| Attendance Report | ✅ | read-only | ✅ | n/a | ✅ |
| Create Exam / Datesheet | ✅ | ✅ | ✅ | ✅ | ✅ |
| Marks Entry | ✅ | ✅ range check, finalise lock, reopen | ✅ | ✅ | ✅ |

## Staff

| Page | Real | Guards | Scope | CSRF | Tests |
|---|---|---|---|---|---|
| Staff Directory / Profile | ✅ | ✅ | ✅ | ✅ | — |
| Add / Edit Staff | ✅ | ✅ | ✅ | ✅ | — |
| Inactive Staff | ✅ | ✅ confirm on both directions, deactivated-on date | ✅ | ✅ | — |
| Leave Management | ✅ | ✅ overlap refused, decided-once, Sundays not counted | ✅ | ✅ | — |
| Payroll | ✅ | ✅ paid month not re-run, paid twice refused | ✅ | ✅ | — |

## Transport, documents

| Page | Real | Guards | Scope | CSRF | Tests |
|---|---|---|---|---|---|
| Routes / Vehicles / Assign | ✅ | ✅ blank name, unknown stop, one active assignment | ✅ | ✅ | ✅ 31 |
| TC Register / Print | ✅ | ✅ must have left, dues clear, one live TC | ✅ | ✅ | ✅ |
| ID Cards | ✅ | read-only, excludes students who left | ✅ | n/a | ✅ |

## Settings

| Page | Real | Guards | Scope | CSRF | Tests |
|---|---|---|---|---|---|
| Basic Profile | ✅ | ✅ (the only page with full `asp-validation` markup) | ✅ | ✅ | — |
| Academic Years | ✅ | ✅ blank name, end-before-start, duplicate name | ✅ | ✅ **fixed** | — |
| Classes & Sections | ✅ | ✅ | ✅ | ✅ **fixed** | — |
| Period Structure | ✅ | ✅ | ✅ | ✅ **fixed** | — |
| Subjects / Calendar / Timetable | ✅ | ✅ | ✅ | ✅ | — |
| Fee Heads / Structure | ✅ | ✅ | ✅ | ✅ | — |
| Staff Masters | ✅ | ✅ | ✅ | ✅ | — |
| Roles & Permissions | ✅ | ✅ | ✅ | ✅ | — |
| Documents / Smart Bell | ✅ | ✅ | ✅ | ✅ | — |
| Admission Workflow | ✅ | ✅ | ✅ | ✅ | ✅ 23 |

## Account

| Page | Real | Guards | Scope | CSRF | Tests |
|---|---|---|---|---|---|
| Login | ✅ | ✅ rate-limited 5/5min per IP, BCrypt, school-status gate | n/a | ✅ | — |
| Choose Role | ✅ | ✅ role must be one the user holds | ✅ | ✅ | — |
| Forgot / Verify OTP | ✅ | ✅ rate-limited, attempt lock, expiry, anti-enumeration | n/a | ✅ | — |
| Change Password | ✅ | ✅ forced first-login reset is enforced in middleware | ✅ | ✅ | — |

## Still not real

| Page | State |
|---|---|
| **Inventory** (Items, Purchase Entry) | Shell. 0 service calls. Needs a whole module: items, stock, suppliers, purchases. |
| **Payment Verification** | Shell. The view holds a hardcoded C# array. Needs a table for online payments awaiting verification — and a decision first: payment-gateway integration, or manual UPI/NEFT reference checking? |
| **Staff attendance** | Does not exist. `StaffProfile` links to `Attendance/StaffAttendance`, which is not an action — a dead link. This is also why payroll derives Loss of Pay from unpaid leave rather than from absences. |

---

## TODO

Open items, roughly in the order they are worth doing.

- [ ] **Payment Verification** — decide gateway vs manual, then build it. Until
      then the menu item leads to invented data.
- [ ] **Inventory** — a module-sized piece of work.
- [ ] **Staff attendance register** — would let payroll compute LOP from actual
      absences, and would fix the dead link on the staff profile.
- [ ] **Salary structure** — `core.staff` holds one `monthly_salary`. A payslip
      with basic/HRA/DA and statutory deductions needs a component table and a
      statutory-rate table. Do not hardcode tax slabs in the page; they are
      wrong for most schools and stale after any budget.
- [ ] **Exam grading scale** — there is no grade configuration, which is why the
      result screens show marks and pass/fail but no letter grade.
- [ ] **Class rank** — needs a class-wide comparison the dashboard does not
      currently fetch.
- [ ] Test suites for **Promotion**, **Leave/Payroll**, **Settings** and
      **Roles** — the four areas with real guards but no suite yet.
- [ ] **Module flags and partial saves** — `sp_school_admin_admission_workflow_manage`
      reads each module flag as `COALESCE(p_enable_x, TRUE)`, so a save that omits
      one switches it back ON. Not reachable today (the form posts all five and
      the service sends plain bools), but a future quick-toggle endpoint would
      trip on it. Pinned by check B7.
- [ ] **Two dead model properties** — `RegistrationFeeAmount` and
      `SecurityFeeAmount` exist on `AdmissionWorkflowModel` and as columns, but no
      view field sets them, no proc parameter accepts them and nothing reads them.
      The registration amount is typed at collection time and the security amount
      comes from the fee head. Remove, or wire up.

### Done in this pass

- [x] **CSRF on five settings mutations** — `SaveClassSection`,
      `SaveAcademicYear`, `SetCurrentAcademicYear`, `DeleteAcademicYear`,
      `SavePeriodStructure` had no `[ValidateAntiForgeryToken]`. Two of the three
      views were already sending the token, so the attribute was all that was
      missing; the Academic Years page was not sending one at all and now does.
- [x] **Registrations menu item now honours its own flag** — four of the five
      module toggles hid their menu section; `enable_registration` was read by the
      Registration *page* but ignored by the menu, so a school that switched
      registration off still saw the item. Now gated like the other four.
- [x] **Three dead procedures dropped** — `core.sp_admission_manage1` (an
      orphaned copy of the admission proc, predating the back-dating fix),
      `config.sp_role_permission_management` and `core.sp_school_user_management`
      (creates logins, no scope guard). Nothing called any of them; the live
      paths are `sp_role_manage` + `sp_role_permissions_save`, both properly
      scoped. `RolePermissionService` and its contract and DTO went with them.

---

## Re-running the audit

Missing antiforgery or permission gate on any POST:

```bash
python - <<'EOF'
import os, re, io
for root, _, names in os.walk("educore"):
    r = root.replace("\\","/")
    if "/bin/" in r or "/obj/" in r or "Controllers" not in r: continue
    for n in sorted(names):
        if not n.endswith("Controller.cs"): continue
        s = io.open(os.path.join(root,n), encoding="utf-8-sig", errors="replace").read()
        head = s.split("public class")[0]
        cls = "[HasPermission" in head or "[Authorize" in head
        for m in re.finditer(r'((?:\s*\[[^\]]+\]\s*)*)\s*public\s+(?:async\s+)?(?:Task<)?IActionResult>?\s+(\w+)\s*\(', s):
            a, name = m.group(1), m.group(2)
            if "[HttpPost]" not in a: continue
            if "ValidateAntiForgeryToken" not in a: print("no CSRF :", n, name)
            if "[HasPermission" not in a and "[Authorize" not in a and not cls: print("no gate :", n, name)
EOF
```

Mutating procs with no validation or no tenant scope:

```sql
WITH p AS (
  SELECT n.nspname||'.'||pr.proname AS nm, pg_get_functiondef(pr.oid) AS def
  FROM pg_proc pr JOIN pg_namespace n ON n.oid=pr.pronamespace
  WHERE n.nspname IN ('core','academic','config') AND pr.prokind='p')
SELECT nm,
  (SELECT count(*) FROM regexp_matches(def,'RAISE EXCEPTION','g')) AS raises,
  position('tenant_id' in def) > 0 AS scoped
FROM p
WHERE position('INSERT INTO' in def) > 0 OR position('UPDATE ' in def) > 0
ORDER BY raises, nm;
```

A zero in `raises` is not automatically a bug — several procs report a refusal as
`success = false` with a message instead of raising, which is the better shape for
"already cancelled" or "already decided". Read the proc before believing the
number.
