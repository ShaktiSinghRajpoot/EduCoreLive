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
| New Admission | ✅ | ✅ all 10 starred fields re-checked server-side; proc refuses blank name, unknown class, impossible dates | ✅ | ✅ | ✅ 18 |
| Inactive / Left | ✅ | ✅ exit status must be one of four, already-left refused | ✅ | ✅ | ✅ |
| Promote Students | ✅ | ✅ session, ladder, dues, per-student target class | ✅ | ✅ | ✅ 17 |

## Fees

| Page | Real | Guards | Scope | CSRF | Tests |
|---|---|---|---|---|---|
| Collect Fee | ✅ | ✅ over-payment, negative, empty selection all refused | ✅ | ✅ | ✅ 28 + 98 |
| Fee Due Reminders | ✅ | ✅ | ✅ | ✅ | — |
| Day Close | ✅ | ✅ | ✅ | ✅ | — |
| Fee Reports | ✅ | read-only | ✅ | n/a | — |
| Fee Heads / Structure | ✅ | ✅ blank name **fixed**, upsert by name, cascade delete | ✅ | ✅ | ✅ 26 |

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
| Leave Management | ✅ | ✅ overlap refused, decided-once, Sundays not counted | ✅ | ✅ | ✅ 29 |
| Payroll | ✅ | ✅ paid month not re-run, paid twice refused | ✅ | ✅ | ✅ |

## Transport, documents

| Page | Real | Guards | Scope | CSRF | Tests |
|---|---|---|---|---|---|
| Routes / Vehicles / Assign | ✅ | ✅ blank name, unknown stop, one active assignment | ✅ | ✅ | ✅ 31 |
| TC Register / Print | ✅ | ✅ must have left, dues clear, one live TC | ✅ | ✅ | ✅ |
| ID Cards | ✅ | read-only, excludes students who left | ✅ | n/a | ✅ |

## Store

| Page | Real | Guards | Scope | CSRF | Tests |
|---|---|---|---|---|---|
| Inventory Items | ✅ | ✅ name, SKU, stock floor at zero, delete needs empty | ✅ | ✅ | ✅ 49 |
| Purchase Entry | ✅ | ✅ future date, empty lines, duplicate invoice, cancel-once | ✅ | ✅ | ✅ |

## Settings

| Page | Real | Guards | Scope | CSRF | Tests |
|---|---|---|---|---|---|
| Basic Profile | ✅ | ✅ (the only page with full `asp-validation` markup) | ✅ | ✅ | — |
| Academic Years | ✅ | ✅ blank name, end-before-start, duplicate name | ✅ | ✅ | ✅ 26 |
| Classes & Sections | ✅ | ✅ a class with enrolled students cannot be removed | ✅ | ✅ | ✅ |
| Period Structure | ✅ | ✅ | ✅ | ✅ **fixed** | — |
| Subjects / Calendar / Timetable | ✅ | ✅ | ✅ | ✅ | ✅ |
| Fee Heads / Structure | ✅ | ✅ | ✅ | ✅ | ✅ |
| Staff Masters | ✅ | ✅ | ✅ | ✅ | — |
| Roles & Permissions | ✅ | ✅ built-ins protected, in-use role kept, soft revoke | ✅ | ✅ | ✅ 23 |
| Documents / Smart Bell | ✅ | ✅ | ✅ | ✅ | — |
| Admission Workflow | ✅ | ✅ | ✅ | ✅ | ✅ 23 + 28 |

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
| **Staff attendance** | Does not exist. The dead link to it has been removed from `StaffProfile`; this is also why payroll derives Loss of Pay from unpaid leave rather than from absences. |

---

## TODO

Open items, roughly in the order they are worth doing.

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
- [x] **New Admission page hardened** — the ten starred fields are now all
      re-checked in the controller (seven were not), the proc refuses a blank
      name, a class that does not exist and impossible dates, and pressing Save
      with something missing now scrolls to the field and names it instead of
      appearing to do nothing.
- [x] **Student photo at admission** — drop target beside the name, with preview,
      drag-and-drop and the same limits the server applies.
- [x] **Roll No removed from admission** — it is assigned per class after
      admissions close, so at admission it was always blank or a guess.
- [x] **Admission numbers said `ADM-FY 2-0001`** — the generator took the first
      four characters of the session NAME. Now uses `core.fn_receipt_year`, the
      helper written when receipt numbers hit the same bug.
- [x] **Workflow billing suite** — 28 checks proving `charge_fees_from` really
      drives the money, and recording which workflow settings the database
      enforces (one) versus which the application enforces (the rest).
- [x] **Cancelling a receipt now reverses the advance wallet** — it used to
      reverse the ledger and leave the wallet untouched, which lost real money in
      both directions. Found by the money-trail suite; no live data was affected.
- [x] **Money trail suite** — 98 checks following one student from enquiry to
      Transfer Certificate, re-proving five equations after every step.
- [x] **Three broken links fixed** — the dashboard's "New Admission" button and
      quick tile both pointed at `Admission/ManageAdmission`, an action whose view
      does not exist, so the main landing page's most obvious button returned a
      500. They now go to `Admission/Create`. `Account/Error404` had the same
      shape and no caller. The dead `Attendance/StaffAttendance` link is gone
      from the staff profile. The whole app now has zero dead links and zero
      actions returning a view that does not exist — the scan is below.
- [x] **Payment Verification removed** — the page showed a hardcoded array and
      only made sense behind a payment gateway, which is not being built. The
      controller, view, stylesheet and menu entry are gone; nothing else
      referenced it and it had no permission key of its own.
- [x] **Inventory module built** — items, suppliers, purchases and a stock
      movement ledger, replacing two shells that saved nothing and showed a
      hardcoded catalog. 49 checks.
- [x] **The two unmigrated fee heads are migrated** — school 33 "Annually
      Function" and school 34 "Admission Fee" were `One Time` heads still marked
      `collection_point = 'Recurring'`, so they were offered as scheduled
      instalments instead of at the admission desk. Both are now `'Admission'`,
      and nothing on Railway is left unmigrated. No ledger row changed: neither
      `sp_admission_manage` nor `core.student_ledger` reads `collection_point`.
- [x] **Fee head names are now required** — `sp_school_admin_fee_head_manage`
      was the only settings proc with no name guard, so an empty string and a
      whitespace string both created invisible fee heads that reach student
      ledgers and print as blank receipt lines. The name is now trimmed and
      refused when empty.
- [x] **Settings and Roles suites** — 26 and 23 checks.
- [x] **Promotion and Leave/Payroll suites** — 17 and 29 checks. Nothing to fix
      in either; both modules hold up.
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

Dead links, and actions returning a view that does not exist:

```bash
python - <<'EOF'
import os, re, io
actions, views = set(), set()
for root, _, names in os.walk("educore"):
    r = root.replace("\\","/")
    if "/bin/" in r or "/obj/" in r: continue
    for n in names:
        if n.endswith(".cshtml"): views.add((os.path.basename(root).lower(), n[:-7].lower()))
        if n.endswith("Controller.cs") and "Controllers" in r:
            c = n[:-len("Controller.cs")]
            s = io.open(os.path.join(root,n), encoding="utf-8-sig", errors="replace").read()
            for m in re.finditer(r'public\s+(?:async\s+)?(?:Task<)?IActionResult>?\s+(\w+)\s*\(', s):
                actions.add((c.lower(), m.group(1).lower()))
for root, _, names in os.walk("educore"):
    r = root.replace("\\","/")
    if "/bin/" in r or "/obj/" in r: continue
    for n in [x for x in names if x.endswith(".cshtml")]:
        s = re.sub(r'//.*', '', io.open(os.path.join(root,n), encoding="utf-8-sig", errors="replace").read())
        for m in re.finditer(r'asp-controller="(\w+)"\s+asp-action="(\w+)"', s):
            if (m.group(1).lower(), m.group(2).lower()) not in actions: print("dead:", n, m.group(1), m.group(2))
        for m in re.finditer(r'["']/(?:ERP|SuperAdmin)/(\w+)/(\w+)', s):
            c, a = m.group(1).lower(), m.group(2).lower()
            if (c,a) not in actions and any(cc==c for cc,_ in actions): print("dead:", n, c, a)
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
