# Test cases: Platform, access and security

Scope: sign-in, multi-role, password reset / change, cookies and rate limit, dynamic RBAC
(roles, permission matrix, user-role assignment, permission cache), the SuperAdmin school
module (create / edit / status / admin user / school code / purge / archive), module toggles,
and the Dashboards / Geo / Home controllers.

SQL suite: `EduCoreDataAccessLayer/Database/tests/platform_access_security_tests.sql`
First run: **RESULT: 79 passed, 23 failed**. **After the fixes (2026-10-10): RESULT: 123 passed, 0 failed.** Every BUG row below is now FIXED (see "Fix status" at the end). The Result column keeps the original finding. Every one of the 23 is a `BUG` check named after the correct behaviour. No test was weakened to make it pass. After the run the local DB row counts matched exactly (roles, users, schools, login_attempts, reset tokens, user_roles, role_permissions, school code counter, activity log, sessions, active staff), so nothing leaked.

Stack read:
- Web: `educore/Controllers/AccountController.cs`, `educore/Program.cs` (auth, cookie, policies, rate limiter, middleware), `educore/Helpers/HasPermissionAttribute.cs`, `educore/Helpers/RequiresModuleAttribute.cs`, `educore/Areas/ERP/Controllers/RolesController.cs` + `Views/Roles/{Index,Permissions}.cshtml`, `educore/Areas/SuperAdmin/Controllers/SchoolsController.cs`, `educore/Controllers/{Dashboards,Geo,Home}Controller.cs`, plus the role-sync part of `ERP/StaffController.cs`.
- Data: `Services/PermissionService.cs`, `Services/LoginService.cs`, `Repository/ERP/RbacService.cs`, `Repository/SuperAdmin/SchoolService.cs`, `Infrastructure/AppCache.cs` (10-minute TTL).
- Live procs, read with `pg_get_functiondef`: `core.sp_login_management`, `core.sp_password_reset`, `config.sp_role_manage`, `config.sp_role_permissions_{get,save,resolve}`, `config.sp_permission_catalog`, `core.sp_user_roles_resolve`, `core.sp_staff_manage` (role sync), `core.sp_school_manage`, `core.sp_school_list`, `core.sp_school_purge`, `core.sp_school_archive`, `core.fn_user_email_taken`, `core.fn_user_phone_taken`, `core.sp_school_admin_admission_workflow_manage`, `core.sp_dashboard_summary`, `config.sp_geo_lookup`.
- **`core.sp_school_user_management` is not deployed.** The script `sp_school_user_management.sql` exists, but the proc is not in the DB and no C# calls it. `RbacService` still has dead wrappers for `sp_user_role_list` and `sp_user_role_assign`.
- Table facts that matter:
  - `config.role_permissions` and `core.user_roles` have **no foreign keys** (only PKs, plus `uq_user_roles_tenant_user_role`).
  - Roles are **tenant-wide** (`sp_role_manage` filters by `tenant_id` only). The seeded roles have `school_id NULL`. Tenant 25 runs two schools (35, 36) on the same four roles.
  - `uq_user_phone_active` compares the **last 10 digits**. The procs' phone guards compare `TRIM(phone)` text.
  - `admin_activity_logs` is written only by `sp_school_purge`.

---

## The real-world scenario

1. **Onboarding.** The platform super admin opens *New School* and creates "ZZ Onboarded School" on tenant 25. The school gets **SCH22**, the next number with no gap. Its admin gets a temporary password, is a primary SCHOOL_ADMIN, and is forced to reset on first login (G1-G3). A second school is created **without** an admin. Later the admin is added from *Edit* with a typed password, but that admin is **not** forced to reset (SA-12).
2. **The admin logs in.** Sign-in by email works in any case and with stray spaces. Sign-in by mobile works as `+91 98390-73643` (A1-A2). After 5 attempts the login form returns 429. That limit is per IP. On Railway the "IP" is very likely the proxy, which would make it a limit for the whole site (SEC-10).
3. **Roles.** The admin creates **Cashier**, ticking Fees View + Collect but not Cancel or Refund (E1), and **Librarian**. A Librarian-only user then **cannot sign in at all**: "User tenant or school mapping is invalid" (AUTH-12). A curious admin also names a role "Super Admin". It silently gets the platform's reserved code `SUPER_ADMIN`, disappears from the role list, and makes anyone holding it a full admin (RBAC-01/02).
4. **A teacher pushes.** The teacher is refused `/ERP/Roles` (403) and refused Fee Collect. On the dashboard, though, the teacher still sees this month's collection and the **top fee defaulters** list (SEC-12).
5. **Somebody leaves.** The accountant resigns and is marked *Inactive* on People. Their login keeps working: the login lookup still finds them, and their open session keeps every permission (SEC-06, SEC-02). Five such inactive staff already hold live logins in the local data. One of them (staff 20, user 42) is a **SCHOOL_ADMIN** (SEC-07).
6. **Password reset.** Someone types random emails into *Forgot password*. Every unknown email answers "code expired", while real emails answer "incorrect code". That tells the attacker which emails are real accounts (AUTH-37). Resetting with the mobile number in `+91 …` format finds nobody, although login accepts that format (AUTH-43).
7. **Suspension.** The platform suspends the school. New logins are blocked with a clear page (A6, G14). Anyone already signed in keeps working: no per-request check exists (SEC-04). Nothing records who suspended the school (SA-15).
8. **Closing for good.** The school is set to Closed and purged. A brand-new, empty school purges cleanly (H6-H10). A real school that ran exams **cannot** be purged: it fails on a foreign-key error because 15 newer tables are missing from the purge list (SA-26/27). Each failed attempt still leaves the full plaintext archive, **password hashes included**, in `App_Data/school-archives` (SA-25).

---

## A. Sign-in, multi-role, session (AUTH)

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| AUTH-01 | Email login, case/space | `'  CAANMOL03@GMAIL.COM '` | Finds user 39 | Proc | SQL A1 | PASS |
| AUTH-02 | Phone login, formatted | `+91 98390-73643` | Same user | Proc | SQL A2 | PASS |
| AUTH-03 | Unknown identifier | random email | No row, generic "Invalid email/mobile number or password" | Proc/Controller | SQL A3; static AccountController.cs:106-112 | PASS |
| AUTH-04 | Short digit fragment | 6 digits of a phone | No match | Proc | SQL A3b | PASS |
| AUTH-05 | Wrong password | correct email, bad password | Same generic message as unknown (no enumeration); attempt logged | Controller | static AccountController.cs:122-130 | PASS |
| AUTH-06 | Deactivated user | `users.is_active=false` | Not found → generic message (the "not active" branch at :114 is unreachable, so no enumeration) | Proc | SQL A4 | PASS |
| AUTH-07 | Soft-deleted user | `is_deleted=true` | Not found | Proc | SQL A5 | PASS |
| AUTH-08 | Each school status | Active, Under Review, Pending, Inactive, Suspended, Closed | Gate follows `school_statuses.allows_login`, with its message | Proc | SQL A6 ×6 | PASS |
| AUTH-09 | Disabled school, status Active | `schools.is_active=false` | Blocked, "closed" message | Proc | SQL A7 | PASS |
| AUTH-10 | School gate after the password check | Suspended school, wrong password | Generic message; only a correct password reveals "suspended" | Controller | static AccountController.cs:132-149 | PASS |
| AUTH-11 | Super admin passes the gate | tenant 1, school 0 | allows=true | Proc | SQL A8 | PASS |
| AUTH-12 | **User whose role is a custom role** | Librarian-only user signs in | Signs in to the dashboard | Controller | SQL A11 + "BUG AUTH-12"; static AccountController.cs:284-301 (`_ => false`) | **BUG** |
| AUTH-13 | Only role removed | user_roles soft-deleted | Cannot sign in ("role not assigned") | Proc | SQL A9 | PASS |
| AUTH-14 | Multi-role picker | user 42 (4 roles) | Lists all 4 live roles, primary first | Proc | SQL A10 | PASS |
| AUTH-15 | ContinueAs with a role not held | POST `roleCode=SCHOOL_ADMIN` for a teacher | "Invalid role selected" | Controller | static AccountController.cs:233-241 | PASS |
| AUTH-16 | ContinueAs without a pending login | POST directly | Redirect to Login (protected session token) | Controller | static AccountController.cs:227-231, 412-428 | PASS |
| AUTH-17 | SwitchRole to a role not held | POST `roleId=<admin role>` | Ignored, focus unchanged | Controller/Service | static AccountController.cs:66-71; PermissionService.cs:72-73 | PASS |
| AUTH-18 | Picker role in a suspended school | Primary role in school A, second role in suspended school B | B is blocked or hidden | Proc/Controller | static: gate uses the primary role's school only (sp_login_management GET_LOGIN_USER); GET_USER_ROLES has no gate; ContinueAs does not re-check. Latent: no UI makes cross-school roles today | RISK (low) |
| AUTH-19 | Open redirect on returnUrl | `returnUrl=https://evil` | Ignored → role landing | Controller | static AccountController.cs:191-192, 73-74 (`Url.IsLocalUrl`) | PASS |
| AUTH-20 | Login attempt is audited | wrong password; phone; unknown email | Row per attempt, attributed to the user | Proc | SQL B1-B3 | PASS |
| AUTH-21 | **Attempt carries the client IP** | any failed login | `login_attempts.ip_address` set | Service | SQL "BUG AUTH-21" (145 of 145 live rows have no IP); static LoginService.cs:90-101 | **BUG** |
| AUTH-22 | Session row on sign-in | success | `user_sessions` row for the school, `last_login_at` stamped | Proc | SQL B4 | PASS |
| AUTH-23 | Forced first-login reset | `must_change_password=true` | Every URL except ChangePassword, Logout, AccessDenied and Error bounces to ChangePassword | Config | static Program.cs:328-348 | PASS |
| AUTH-24 | Logout | POST with token | Cookie and session cleared | Controller | static AccountController.cs:629-637 | PASS |
| AUTH-25 | Cookie with tenant 0 / missing | tampered or old cookie | Signed out | Config | static Program.cs:306-321 | PASS |
| AUTH-26 | Remember-me survives password change | RememberMe login, then change password | Cookie stays persistent for 7 days | Controller | static AccountController.cs:615-627 re-signs with no AuthenticationProperties → becomes a session cookie | BUG (low) |

## B. Password reset and change (AUTH)

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| AUTH-30 | Known email | REQUEST | One code, SHA-256 stored, 10-minute expiry | Proc | SQL C1, C2 | PASS |
| AUTH-31 | Unknown email | REQUEST | No token, no contact row; UI still goes to Verify | Proc/Controller | SQL C3; static AccountController.cs:459-461 | PASS |
| AUTH-32 | Second request | REQUEST twice | Only the newest code is live | Proc | SQL C4, C5 | PASS |
| AUTH-33 | Wrong code | RESET_WITH_OTP | INVALID, attempts+1 | Proc | SQL C6 | PASS |
| AUTH-34 | Brute force | 5 wrong guesses, then the right one | LOCKED, code burned | Proc | SQL C8, C8b | PASS |
| AUTH-35 | Right code | RESET_WITH_OTP | Password set, forced reset cleared, token used | Proc | SQL C9 | PASS |
| AUTH-36 | Replay a used code | same code again | Refused | Proc | SQL C10 | PASS |
| AUTH-37 | **Enumeration via Verify** | unknown email + any code, compared with real email + wrong code | Same answer for both | Proc/Controller | SQL "BUG AUTH-37" (EXPIRED vs INVALID); static AccountController.cs:512-526 | **BUG** |
| AUTH-38 | Expired code | right code after 10 minutes | EXPIRED | Proc | SQL C11 | PASS |
| AUTH-39 | Deactivated user | REQUEST | No code | Proc | SQL C12 | PASS |
| AUTH-40 | OTP generator | — | CSPRNG, 6 digits | Controller | static AccountController.cs:531-532 | PASS |
| AUTH-41 | OTP / Verify throttled | many POSTs | Shares the 5/5-min login limiter | Controller | static AccountController.cs:450, 491 | PASS |
| AUTH-42 | OTP hash at rest | DB read | Unsalted SHA-256 of 6 digits, trivially reversible, but only for 10 minutes | Proc | static | NOTE |
| AUTH-43 | **Reset by formatted phone** | `+91 98390 73643` | Finds the user, as login does | Proc | SQL "BUG AUTH-43"; sp_password_reset REQUEST uses `up.phone = p_identifier` | **BUG** (low) |
| AUTH-44 | Change password, wrong current | normal change | "Current password is incorrect" | Controller | static AccountController.cs:585-589 | PASS |
| AUTH-45 | New = old | — | Refused | Controller | static :591-595 | PASS |
| AUTH-46 | Change password stores hash and clears the force flag | CHANGE_PASSWORD | Done | Proc | SQL B5 | PASS |
| AUTH-47 | Deactivated user changes password | CHANGE_PASSWORD | Refused | Proc | SQL B6 | PASS |
| AUTH-48 | Other sessions after reset/change | stolen cookie, then victim resets | Stolen cookie dies | Config | static: no security stamp / OnValidatePrincipal; cookie lives up to 8h sliding / 7 days | BUG (medium) |
| AUTH-49 | Password length vs BCrypt | 100-char password | Whole password counts | Controller | static: StringLength(100) but BCrypt uses only 72 bytes | NOTE |

## C. Roles and permission matrix (RBAC)

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| RBAC-01 | **Role named "Super Admin"** | create in school 34 | Gets a non-reserved code (or refused) | Proc | SQL "BUG RBAC-01" (got `SUPER_ADMIN`) | **BUG** |
| RBAC-02 | **…and is visible** | Roles list | Listed | Proc | SQL "BUG RBAC-02" (LIST hides `SUPER_ADMIN`) | **BUG** |
| RBAC-03 | …and a holder gets admin bypass | assign it to a teacher | No bypass | Service | static PermissionService.cs:113-115 (`IsAdminCode` includes SUPER_ADMIN) | **BUG** (part of RBAC-01) |
| RBAC-04 | "School_Admin" lookalike | create | Code `SCHOOL_ADMIN_2`, no bypass | Proc | SQL D3 | PASS |
| RBAC-05 | Padded / cased duplicate name | `'   zz librarian  '` | Refused | Proc | SQL D4 | PASS |
| RBAC-06 | Other tenant reads / renames our role | GET, UPDATE as tenant 23 | Nothing / refused | Proc | SQL D5, D6 | PASS |
| RBAC-07 | Two schools of one tenant | LIST from 35 and 36 | Same list (tenant-wide by design) | Proc | SQL D7 | PASS (see decision D-1) |
| RBAC-08 | Role whose users were all removed | DELETE | Allowed | Proc | SQL D8 | PASS |
| RBAC-09 | Cashier: view + collect only | matrix save | Resolves to exactly fees.view, fees.collect | Proc | SQL E1 | PASS |
| RBAC-10 | fees.manage ≠ collect/cancel/refund | matrix save | Extras not implied | Proc/Service | SQL E2; static PermissionService.cs:151-158 | PASS |
| RBAC-11 | Matrix: an extra auto-ticks View | tick Collect | View ticked | UI-JS | static Permissions.cshtml (`.cb-extra` handler) | PASS |
| RBAC-12 | Revoke is attributable | untick | `updated_by` = actor on the soft-deleted grant | Proc | SQL E3 | PASS (last change only) |
| RBAC-13 | Catalog permission switched off | `is_active=false` | Not resolved | Proc | SQL E5 | PASS |
| RBAC-14 | **Permission id not in catalog** | POST `permissionIds=999999` | Refused | Proc | SQL "BUG RBAC-14" (stored, no FK) | **BUG** (low) |
| RBAC-15 | Other tenant resolves our role id | resolve as tenant 23 | Nothing | Proc | SQL E6 | PASS |
| RBAC-16 | Platform scope reads grants | tenant 1 | Refused | Proc | SQL E7 | PASS |
| RBAC-17 | Roles page gated | teacher opens `/ERP/Roles` | 403 | Controller | static RolesController.cs:11 | PASS |
| RBAC-18 | Antiforgery on Save / Delete / SavePermissions | POST without token | 400 | Controller/UI | static RolesController.cs:32,55,73; Index.cshtml:85,106; Permissions.cshtml:33 | PASS |
| RBAC-19 | XSS in role name | name `');alert(1)//` | Encoded | UI | static Index.cshtml:77 (JavaScriptEncoder inside an attribute) | PASS |
| RBAC-20 | Matrix edit is live | revoke while the user is logged in | Next request refused | Service | static RolesController.cs:82 InvalidateRole. But the key is per (tenant, **school**): another school of the same tenant keeps stale grants for up to 10 minutes (PermissionService.cs:136-137) | PASS / RISK (multi-school tenants) |
| RBAC-21 | **Role id from another tenant on People** | `p_role_ids` includes tenant 23's role 45 | Refused | Proc | SQL "BUG RBAC-21" | **BUG** |
| RBAC-22 | **…locks the person out** | same save | Login still works | Proc | SQL "BUG RBAC-22": the foreign id is lowest, becomes primary, and the login join drops the user | **BUG** |
| RBAC-23 | Duplicate login email (case) on People | other case | Friendly refusal | Proc | SQL F11 | PASS |
| RBAC-24 | **Duplicate phone, other format, on People** | `+91 98390 73643` | Friendly refusal | Proc | SQL F10 + "BUG RBAC-24" (raw `uq_user_phone_active` error) | **BUG** (low) |
| RBAC-25 | Role change on People invalidates cache | change roles | Live next request | Controller | static StaffController.cs:193-194 uses the **form-posted** `model.UserId`; the proc uses the DB's. A missing or tampered field leaves the cache stale for 10 minutes | BUG (low) |
| RBAC-26 | Staff-manager grants themself admin | user with staff.manage (not admin) ticks SCHOOL_ADMIN on their own People row | ? | Proc | static sp_staff_manage has no actor check | DECISION D-2 |
| RBAC-27 | Removing the last school admin | untick SCHOOL_ADMIN on the only admin with a staff row | ? | Proc | static: no guard (the provisioning admin has no staff row, so usually survives) | DECISION D-3 |

## D. Access after the fact, and the shell (SEC)

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| SEC-01 | User resolves to their role | — | ACCOUNTANT | Proc | SQL F1 | PASS |
| SEC-02 | **Deactivated user, open session** | deactivate, keep cookie | Permissions gone | Proc/Service | SQL "BUG SEC-02" (`sp_user_roles_resolve` ignores `users.is_active`) | **BUG** |
| SEC-03 | **Deleted user, open session** | `is_deleted` | Permissions gone | Proc | SQL "BUG SEC-03" | **BUG** |
| SEC-04 | **School suspended mid-session** | suspend, keep cookie | Kicked out / refused | Proc/Config | SQL "BUG SEC-04"; static: no per-request check in Program.cs | **BUG** |
| SEC-05 | Cross-tenant role resolve | tenant 23 + our user | Nothing | Proc | SQL F5 | PASS |
| SEC-06 | **Staff marked Inactive keeps login** | People → deactivate | Login disabled | Proc | SQL "BUG SEC-06" (`sp_staff_manage DELETE` touches only `core.staff`) | **BUG** |
| SEC-07 | **Inactive staff with live logins (data)** | — | 0 | Data | SQL "BUG SEC-07": 5 found, incl. staff 20 → user 42 = SCHOOL_ADMIN | **BUG** |
| SEC-08 | Antiforgery on every POST in scope | — | Present | Controller | static scan: every `[HttpPost]` in Account, Roles and Schools has `[ValidateAntiForgeryToken]` (only read-only `Staff/GetDesignations` lacks it) | PASS |
| SEC-09 | Cookie flags | — | HttpOnly, SameSite=Lax, Secure when RequireHttps | Config | static Program.cs:60-86 | PASS (but see SEC-11) |
| SEC-10 | **Rate limit partition behind a proxy** | Railway | Per real client IP | Config | static Program.cs:116-126 + 236-241: `UseForwardedHeaders` keeps the default KnownProxies (loopback only), so X-Forwarded-For is ignored and every client shares the proxy IP. The limiter also counts **successful** logins | **BUG** (verify on Railway) |
| SEC-11 | Secure cookie in production | Railway serves HTTPS at the edge | Secure cookie + HSTS | Config | appsettings.json `RequireHttps:false`. Turning it on without trusting the proxy (SEC-10) would make UseHttpsRedirection loop | DECISION D-4 |
| SEC-12 | **Dashboard for a non-finance role** | teacher opens `/Dashboards` | No money / defaulters | Controller/UI | static DashboardsController.cs:8 (`[Authorize]` only); Views/Dashboards/Index.cshtml:176-280 has no `Can()` | BUG / DECISION D-5 |
| SEC-13 | Dashboard, mismatched tenant/school | tenant 23 + school 34 | Nothing from 34 | Proc | SQL J1 | PASS |
| SEC-14 | Geo endpoints | unknown activity; hostile id | Refused, not executed | Proc | SQL J2, J3 | PASS |
| SEC-15 | Home/Dashboard for a teacher | GET `/Home/Dashboard` | Dashboard | Controller | static HomeController.cs:84-93 sends any non-admin to Login while signed in (not linked anywhere) | NOTE |
| SEC-16 | Security headers | — | XFO DENY, nosniff, Referrer-Policy | Config | static Program.cs:259-266 (no CSP) | PASS / NOTE |
| SEC-17 | Session fixation | — | New session id at login | Config | static: session not regenerated, but auth is a separate cookie; Logout clears | NOTE |
| SEC-18 | Module off → route blocked | Exams/Inventory/Payroll/Leave/Transport off; type the URL | Redirect / JSON refusal | Controller | static `[RequiresModule]` on Exam, Inventory, Leave, Payroll, Transport controllers | PASS |
| SEC-19 | Module off → stored | Save exams=false, payroll=false | Stored, school-scoped; platform refused | Proc | SQL I1-I3 | PASS |
| SEC-20 | Transport off, admission still bills a bus | crafted / stale admission POST with a route | No assignment | Controller | static AdmissionController.cs:447 (no EnableTransport check) | BUG (low) |
| SEC-21 | Exams off, report card still reads results | Student profile | Hidden | Controller | static StudentController.cs:310 | NOTE (read-only) |

## E. Super admin: schools, purge, archive (SA)

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| SA-01 | Controller gate | school admin opens `/SuperAdmin/Schools/*` | 403 | Controller | static SchoolsController.cs:17; SUPER_ADMIN role claim only for tenant 1 (AccountController.cs:288) | PASS |
| SA-02 | Onboard → next code, gap-free | INSERT | SCH22 after 21 | Proc | SQL G1 | PASS |
| SA-03 | New admin | INSERT | Primary SCHOOL_ADMIN, forced reset, can log in | Proc | SQL G2, G3 | PASS |
| SA-04 | Temp password | — | CSPRNG 16 chars, BCrypt-hashed, shown once if mail fails | Controller | static SchoolsController.cs:155-172, 186-239 | PASS |
| SA-05 | Admin email taken (case) | INSERT | Friendly refusal | Proc | SQL G4 | PASS |
| SA-06 | **Admin phone taken (format)** | INSERT | Friendly refusal | Proc | SQL G5 + "BUG SA-06" (raw constraint error) | **BUG** (low) |
| SA-07 | **School user creates a school** | `sp_school_manage INSERT` with tenant 24 → tenant 23 | Refused (as purge does) | Proc | SQL "BUG SA-07" | **BUG** (defence in depth) |
| SA-08 | **School user changes own status** | UPDATE tenant 24 / school 34 status | Refused | Proc | SQL "BUG SA-08" | **BUG** (defence in depth) |
| SA-09 | Other tenant edits / reads our school | UPDATE / GET as tenant 23 | Refused / nothing | Proc | SQL G9, G10 | PASS |
| SA-10 | Tenant's school list | LIST as tenant 23 | Only its school | Proc | SQL G11 | PASS |
| SA-11 | CheckEmail enumeration | anonymous GET | 302 to login | Controller | static SchoolsController.cs:103 (class-level Authorize) | PASS |
| SA-12 | **Admin created on Edit** | school without admin → Edit with typed password | Forced reset | Proc | SQL "BUG SA-12" (UPDATE create path omits `must_change_password`) | **BUG** |
| SA-13 | Super admin resets admin password | Edit with password | Single-use | Proc | SQL G13 | PASS |
| SA-14 | Suspend on Edit | status 7 | Admin blocked at login | Proc | SQL G14 | PASS |
| SA-15 | **Who changed school status** | suspend | Audit row with actor and time | Proc | SQL "BUG SA-15" (only `schools.updated_by`, no history) | **BUG** / DECISION D-6 |
| SA-16 | School codes unique | live data | No duplicates | Data | SQL G16 | PASS |
| SA-17 | Purge by school user | tenant 24 | Refused | Proc | SQL H1 | PASS |
| SA-18 | Purge an Active school | — | Refused | Proc | SQL H2 | PASS |
| SA-19 | Confirmation name | wrong case | Refused | Proc | SQL H3 | PASS |
| SA-20 | Archive by school user | tenant 24 | Refused | Proc | SQL H4 | PASS |
| SA-21 | Purge a clean Closed school | — | School gone | Proc | SQL H6 | PASS |
| SA-22 | …its admin login gone | — | 0 users | Proc | SQL H7 | PASS |
| SA-23 | …tenant roles and sibling schools survive | tenant 25 | Roles 4/4, admins 40/41 active | Proc | SQL H8, H9 | PASS |
| SA-24 | Purge audited | — | admin_activity_logs row on tenant 1 | Proc | SQL H10 | PASS |
| SA-25 | **Archive contents** | archive school 34 | No password hashes / reset codes in a file on disk | Proc/Controller | SQL "BUG SA-25"; static SchoolsController.cs:383-397 writes the file **before** the purge, so it is kept even when the purge fails | **BUG** |
| SA-26 | **Purge a real Closed school** | school 33 (exams, inventory, enrolment) | Purged | Proc | SQL "BUG SA-26": `fk_exam_subjects_class` violation, everything rolled back | **BUG** |
| SA-27 | **Purge list complete** | — | Every school_id table deleted | Proc | SQL "BUG SA-27": 15 missing — academic.exams, exam_subjects, exam_class_sections, exam_marks, exam_mark_sheets; core.inventory_items, inventory_purchases, inventory_purchase_items, inventory_stock_ledger, inventory_suppliers, staff_leave, staff_payroll, student_enrolment, student_promotion_history, fee_day_close_log | **BUG** |
| SA-28 | Purge of a tenant's only school | — | ? | Proc | static: `core.tenants` row and tenant roles (`school_id NULL`) are kept | DECISION D-7 |
| SA-29 | Leftover `DELETE` op in sp_school_manage | — | Removed with the controller action | Proc | static sp_school_manage DELETE branch, any tenant for its own school; no C# calls it | NOTE |

---

## Bugs found (by severity)

**High**
1. **AUTH-12. Users whose role is a custom role cannot sign in.** `AccountController.IsValidSaasScope` (AccountController.cs:284-301) accepts only the five built-in codes and TENANT_ADMIN. Any role created on the Roles page (Librarian, Cashier…) falls to `_ => false`, and the user sees "User tenant or school mapping is invalid." This is the whole point of dynamic RBAC. **Fix:** in AccountController, treat any non-SUPER_ADMIN/TENANT_ADMIN code as a school role (tenant > 1, school > 0).
2. **SEC-06 / SEC-07. Deactivating a staff member leaves their login live.** `core.sp_staff_manage` 'DELETE' only updates `core.staff`. In the local data, 5 inactive staff still hold working logins, one of them a SCHOOL_ADMIN (staff 20 → user 42). **Fix:** `sp_staff_manage.sql` DELETE (and REACTIVATE) should also set `core.users.is_active`. StaffController should then call `InvalidateUser`.
3. **SEC-02 / SEC-03 / SEC-04 / AUTH-48. A cookie outlives the account, the school and a password change.** No per-request check of the user, the school status or a security stamp exists. `core.sp_user_roles_resolve` (which every `[HasPermission]` uses) ignores `users.is_active` / `is_deleted` and school status. A sacked user, a suspended school or a victim who reset their password stays signed in for 8h sliding (indefinitely while active) or 7 days with remember-me. **Fix:** in `sp_rbac_manage.sql`, make `sp_user_roles_resolve` join `core.users` (active, not deleted) and `core.schools` + `school_statuses.allows_login`. Also add a cookie `OnValidatePrincipal` (Program.cs) that re-checks user/school, or the password `updated_at`, every few minutes.
4. **SA-26 / SA-27. Purge is broken for any school that used exams, inventory, payroll, leave, enrolment or promotion.** It dies on a foreign key and rolls back. 15 school-scoped tables are missing from `core.sp_school_purge`. **Fix:** `school_purge.sql`. Add the 15 tables in FK order: exam_marks → exam_mark_sheets → exam_class_sections → exam_subjects → exams before academic_classes; inventory children before parents; staff_leave and staff_payroll before staff; student_enrolment and student_promotion_history before students; fee_day_close_log.

**Medium**
5. **RBAC-01/02/03. A school can create a hidden, all-powerful role.** Naming a role "Super Admin" generates `role_code = SUPER_ADMIN`, because the de-dupe only looks inside the tenant. LIST hides that code, and `PermissionService.IsAdminCode` gives its holders full bypass. Anyone with `rbac.manage` + `staff.manage` can mint invisible admins. **Fix:** `sp_rbac_manage.sql`. Reserve the built-in codes (SUPER_ADMIN, TENANT_ADMIN, SCHOOL_ADMIN…) in the INSERT code generator.
6. **AUTH-37. Password-reset enumeration.** An unknown account answers EXPIRED ("Your code has expired"), while a known account with a wrong code answers INVALID ("Incorrect code"). **Fix:** in `forgot_password.sql` (`sp_password_reset`), return INVALID when `p_user_id` matches no live token for a user that does not exist. Alternatively, make AccountController.VerifyOtp show one message for INVALID and EXPIRED.
7. **SEC-10. The login rate limit is very likely global on Railway.** `UseForwardedHeaders` keeps the default KnownProxies, so X-Forwarded-For is ignored and every client partitions on the proxy IP. That means 5 sign-ins (successful ones count too) per 5 minutes for the **whole site**, shared with Forgot/Verify OTP. Anyone can lock everyone out. Even with real IPs, one school office behind NAT gets 5 logins per 5 minutes. **Fix:** Program.cs. Clear `KnownNetworks`/`KnownProxies` (or set Railway's range), and count only failed attempts or raise the limit. Verify on Railway before changing.
8. **RBAC-21/22. People form accepts role ids of other tenants.** There is no FK and no check. The foreign id becomes the primary role (lowest id wins), and the login join then drops the person entirely: a lockout. **Fix:** `sp_staff_manage.sql`. Keep only `p_role_ids` that exist in `config.roles` for `p_tenant_id`.
9. **SA-12. An admin created from Edit is not forced to reset** the password the super admin typed. The INSERT path sets it, the UPDATE "no admin yet" path does not. **Fix:** `sp_school_manage.sql`. Add `must_change_password = TRUE` to that INSERT.
10. **SA-25. Purge archive is a plaintext dump with password hashes and reset tokens,** kept in `App_Data/school-archives` even when the purge then fails, which is every time today (bug 4). **Fix:** `sp_school_archive`. Exclude `password_hash`, `token_hash`, `user_sessions`, `password_reset_tokens`. SchoolsController.cs:383-399 should write the file only after the purge succeeds, or delete it on failure.
11. **SA-15. No audit trail for school status, role or permission changes.** Only `updated_by/updated_at` survive, which is the last change only. `admin_activity_logs` is written by purge alone. See D-6.
12. **SEC-12. The dashboard shows fee collections and the defaulters list to every signed-in role.** See D-5.

**Low**
13. **SA-07 / SA-08.** `sp_school_manage` INSERT/UPDATE do not require `p_tenant_id = 1`. A tenant-24 call created a school in tenant 23 and changed its own status (the login gate). Only the controller's `[Authorize]` stands in the way. **Fix:** `sp_school_manage.sql`. Add the same guard as purge.
14. **SA-06 / RBAC-24.** The phone guards in `sp_school_manage` and `sp_staff_manage` compare `TRIM(phone)`, but the index compares the last 10 digits. A formatted duplicate gets the raw "duplicate key … uq_user_phone_active". **Fix:** use `core.fn_user_phone_taken` in both procs.
15. **AUTH-43.** Reset by phone requires the exact stored text. **Fix:** `sp_password_reset` REQUEST should use the same digits-only match as login.
16. **AUTH-21.** Login attempts never store the IP. `LoginService.SaveLoginAttemptAsync` does not pass it. **Fix:** LoginService.cs:90-101 should pass `RemoteIpAddress` and the user agent (after SEC-10 so it is the real IP).
17. **RBAC-14.** Any integer can be stored as a permission id. **Fix:** `sp_role_permissions_save` should filter through `config.permissions`, or add FKs.
18. **RBAC-25.** StaffController.cs:193-194 invalidates the role cache using the form-posted `UserId`. It should use the user id the proc resolved.
19. **AUTH-26.** Changing a password turns a remember-me cookie into a session cookie (AccountController.cs:624).
20. **SEC-20.** Admission assigns transport and bills bus fees even with the Transport module off (AdmissionController.cs:447).

## Needs a business decision (not an obvious fix)

- **D-1 Roles per tenant or per school.** Tenant 25's two schools share one role list and one matrix. Either school's admin can rename, delete or re-permission a role the other school uses. Cache invalidation is per school, so the other school sees the change up to 10 minutes late (RBAC-20). The documentation says per-tenant. Is that what multi-school owners want?
- **D-2 Who may hand out SCHOOL_ADMIN.** Any role with `staff.manage` can tick SCHOOL_ADMIN on any login, including their own, and become a full admin. Restrict it to admins?
- **D-3 Last admin.** Nothing stops removing SCHOOL_ADMIN from the last admin that has a People row. Should there be a guard, and should the platform get a "reset school admin" action?
- **D-4 HTTPS in production.** `Security:RequireHttps` is false, so cookies are not `Secure` on Railway. Turning it on needs the forwarded-headers fix (SEC-10) first, or HTTPS redirection loops.
- **D-5 Dashboard per role.** Should the money cards and the top-defaulters list need `fees.view` (and birthdays need `students.view`)?
- **D-6 Audit trail.** What must be recorded (school status, role/matrix edits, role assignment, password resets by admins), and for how long?
- **D-7 Purging a tenant's only school.** Keep the empty tenant and its roles, or remove them too?
- **Lockout policy.** Today only the per-IP limiter protects an account. Is a per-account lockout (e.g. 10 failures → 15 minutes) wanted, given the trade-off that anyone could then lock a known user out?


---

## Fix status (2026-10-10)

The owner chose these defaults: D-1 roles stay per tenant, D-2 and D-3 as listed, D-4 forwarded headers fixed with RequireHttps still false, D-5 the dashboard money cards need fees.view, D-6 everything is audited and kept forever, D-7 the tenant is kept when its last school is purged, and no per-account lockout.

| Bug | Fix | Where | Suite check |
|---|---|---|---|
| AUTH-12 | Every code except SUPER_ADMIN / TENANT_ADMIN is a school role | AccountController.IsValidSaasScope | A12 |
| SEC-02/03/04, AUTH-48, AUTH-18 | Cookie re-checked once a minute: user active, school allows login, password stamp. Roles for access come from `sp_user_roles_effective` | Helpers/SessionValidator.cs, Program.cs (OnValidatePrincipal), access_security_hardening.sql, sp_rbac_manage.sql, PermissionService | F2-F4, L1-L7, C9b |
| SEC-06 / SEC-07 | DELETE switches the login off; REACTIVATE switches it back on; existing data fixed | sp_staff_manage.sql, access_security_hardening.sql | F6, F7, F7b, F7c |
| SA-26 / SA-27 | 15 + 2 tables added to the purge | school_purge.sql | H11, H12 |
| RBAC-01/02/03 | Reserved codes are never generated | sp_rbac_manage.sql | D1, D2 |
| AUTH-37 | An unknown user answers INVALID | forgot_password.sql | C7 |
| SEC-10 / D-4 | Proxy trusted: real client IP, ForwardLimit 1 | Program.cs | static |
| RBAC-21/22 | Role ids must belong to the tenant | sp_staff_manage.sql | F8, F9 |
| SA-12 | Admin created on Edit gets must_change_password | sp_school_manage.sql | G12 |
| SA-25 | Archive strips hashes and skips reset tokens; the file is deleted if the purge fails | school_purge.sql, SchoolsController.Purge | H5 |
| SA-15 / D-6 | `core.fn_admin_audit` rows for roles, matrix, user roles, activation, admin resets, school create/status/admin | all proc scripts above | D9, E3b, F7b, F14b, G3b, G12b, G13b, G15 |
| SEC-12 / D-5 | Finance figures emptied server-side and hidden without fees.view | DashboardsController, DashboardSummary.ShowFinance, Views/Dashboards/Index.cshtml | static |
| SA-07 / SA-08 | INSERT/UPDATE/DELETE need p_tenant_id = 1 | sp_school_manage.sql | G7, G8 |
| SA-06 / RBAC-24 | `fn_user_phone_taken` | sp_school_manage.sql, sp_staff_manage.sql | G5b, F10b |
| AUTH-43 | Digits-only phone match | forgot_password.sql | C13 |
| AUTH-21 | IP + user agent passed | LoginService, AccountController | B3b |
| RBAC-14 | Unknown permission refused | sp_rbac_manage.sql | E4 |
| RBAC-25 | Cache dropped for the database's user id (+ session cache) | StaffController | static |
| AUTH-26 | Re-sign keeps the cookie properties | AccountController.RefreshClaimsAfterPasswordChange | static |
| RBAC-20 / D-1 | Role key cache is per tenant | PermissionService.RoleKeysKey | static |
| D-2 / D-3 | Only admins grant SCHOOL_ADMIN; no self role change or self deactivation; the last admin is protected | sp_staff_manage.sql | F12-F17 |
| SEC-20 | Not mine: transport with the module off belongs to the students agent | — | — |
