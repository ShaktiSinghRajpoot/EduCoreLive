# Test cases: Super Admin — schools

Scope: the platform super admin's school module. That covers the 3-step Create wizard (new or existing
tenant, with or without the school admin), Edit, status as the login gate, the school list, CheckEmail,
Close + Purge + Archive, and what a super admin (tenant 1, school 0) sees in the shell.

SQL suite: `EduCoreDataAccessLayer/Database/tests/superadmin_schools_tests.sql`
**First run (2026-10-11, LOCAL): RESULT: 73 passed, 18 failed (91 checks).** Each check is named after
the correct behaviour, so every FAIL is a bug or an open decision. After the run the local DB still had
0 schools, 1 tenant, 2 users and the school-code counter at 21, so nothing leaked.

**After the fixes (2026-10-11, LOCAL): RESULT: 92 passed, 0 failed.** All 12 bugs were fixed with the
recommended defaults (D9 now uses a plain 10-digit duplicate, and D9b checks that a "+91"-formatted
admin phone gets a clear format message). Where a row below still says BUG-n, read it as fixed:
roles seeded on every save (BUG-1), Schools menu + dashboard redirect for tenant 1 (BUG-2), tenant
code slug + unique against deleted tenants (BUG-3/4), pincode / phone / status / board-state checks
in the proc (BUG-5/6), "School not found." on a missing school and the DELETE branch removed
(BUG-7/10), list search escapes % and _, "active" = allows_login, tenant code returned and searched
(BUG-8/9/11), and the controller logs and shows the proc's own message (BUG-12).

This catalog **extends** `platform_access_security.md` (sections AUTH, SEC, SA). That catalog already
covers sign-in, the school gate per status, sessions/stamps, school-user access to SuperAdmin URLs, the
purge list, archive secrets and audit rows, and none of those rows are repeated here. Its SQL suite needs
tenants 23-25, which were wiped on 2026-10-11. This suite builds its own tenants and schools inside the
transaction, so it runs on an empty database.

Stack read:
- Web: `Areas/SuperAdmin/Controllers/SchoolsController.cs`, `Views/Schools/{Create,SchoolList}.cshtml`, `Controllers/AccountController.cs` (Login, ChooseRole, ContinueAs, IsValidSaasScope, RedirectByRole), `Program.cs` (policies, tenant middleware), `Helpers/SessionValidator.cs`, `Views/Shared/Sections/Menu/_VerticalMenu.cshtml`, `Controllers/DashboardsController.cs`, `Services/Notifications/NotificationService.cs`.
- Data: `Repository/SuperAdmin/SchoolService.cs`, `Models/SchoolManageModel.cs`, `Services/PermissionService.cs`.
- Live procs (`pg_get_functiondef`): `core.sp_school_manage`, `core.sp_school_list`, `config.sp_school_dropdowns`, `core.sp_school_purge`, `core.sp_school_archive`, `config.fn_apply_builtin_role_defaults`, `core.fn_user_email_taken`, `core.fn_user_phone_taken`, `core.sp_user_email_check`, `core.sp_login_management`, `core.sp_session_check`.
- **Moving target:** another engineer deployed `institution_categories.sql` to local during this run. That adds `p_institution_category_id` to `sp_school_manage` and a 12th cursor to `sp_school_dropdowns`, and it retires school types 1-6. The suite uses school type 8 and passes 12 cursors. Institution categories themselves were **not** tested.

---

## The real-world scenario

1. **A trust with one school.** The super admin picks *New tenant* "ZZ Alpha Group" with code `  ZZ-Alpha `, creates "ZZ Alpha Public School" and lets the system generate the admin's password. The tenant gets the code `zz-alpha` and the school gets SCH22. The four built-in roles are created, and Teacher, Accountant and Receptionist get their default permissions. The admin can sign in by email or mobile and is forced to change the password (A1-A11).
2. **The same trust opens a junior wing.** It goes on the existing tenant and gets SCH23. No roles are duplicated, the defaults are applied again, and its admin lands only in the junior school (B1-B4).
3. **A school signs up before it has named an admin.** "ZZ Beta Vidyalaya" is created on a new tenant with *Create School Admin now* switched off. **No roles are seeded and no permission defaults are applied** (C1, C2). A week later the super admin adds the admin from Edit. The login row is created but **without any role**, so the admin gets "Invalid email/mobile number or password" forever (C5, C6). Trying again is refused with "This email is already registered" (C6b), and from the UI the school can never get a working admin. → **BUG-1**
4. **Typos and duplicates.** A reused tenant code or email, a duplicate school name or registration number on the same tenant, the super admin's own email, and a phone typed as `+91 91000-00001`: each is refused with a plain message (D1-D10). Some weaker inputs slip past the proc because only the form checks them: pincode `012345`, contact phone `12`, status id 999, a short admin phone (D13-D15, D21). → BUG-3..6
5. **State Board.** A UP Board school whose address is in Bihar is refused (E3). Switching the board to CBSE clears the stale board state (E7).
6. **The school maintains its own profile.** It uploads a logo and picks a Thermal receipt and the Board TC format. Later the super admin edits the school name, and none of that is wiped (F1-F3).
7. **Suspension and reopening.** Each status opens or closes sign-in exactly as `allows_login` says. A Suspended school's open session dies, and every change is audited (G1-G5).
8. **Closing for good.** The school must be Closed first and the name typed. Once purged, no row with its school_id remains anywhere, the sibling school and the tenant roles survive, and the same name, email and phone can be onboarded again (I1-I12).
9. **The super admin's own shell.** After login they land on the school list, but the sidebar has **no link back to Schools**. "Dashboard" and the logo both open an empty school dashboard (tenant 1 has no school). → **BUG-2**

---

## A. Create: new tenant + school + admin

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| SAS-A1 | New tenant | mode=new, code `'  ZZ-Alpha '` | Tenant row, code `zz-alpha`, active | Proc | SQL A1 | PASS |
| SAS-A2 | Running school code | counter at 21 | SCH22 | Proc | SQL A2 | PASS |
| SAS-A3 | Child rows | INSERT | 1 profile, 1 primary address, 1 primary contact, 1 settings row | Proc | SQL A3 | PASS |
| SAS-A4 | Admin email normalised | `'  ZZ.Alpha.Admin@Example.invalid '` | Stored trimmed + lower-case | Proc | SQL A4 | PASS |
| SAS-A5 | Admin role | INSERT with admin | Primary SCHOOL_ADMIN, must_change_password | Proc | SQL A5 | PASS |
| SAS-A6 | Built-in roles seeded | new tenant | SCHOOL_ADMIN, TEACHER, ACCOUNTANT, RECEPTIONIST | Proc | SQL A6 | PASS |
| SAS-A7 | Role defaults | new school | Teacher / Accountant / Receptionist have default grants | Proc | SQL A7 | PASS |
| SAS-A8 | Admin can sign in | email | Gate open, forced reset | Proc | SQL A8 | PASS |
| SAS-A9 | …by mobile | `9100000001` | Same user | Proc | SQL A9 | PASS |
| SAS-A10 | Audit | create | SCHOOL_CREATE + SCHOOL_ADMIN_CREATE on tenant 1 | Proc | SQL A10 | PASS |
| SAS-A11 | Wizard toggles | enable_email on | Stored in school_settings | Proc | SQL A11 | PASS |
| SAS-A12 | Temp password | auto-generate | 16 chars, CSPRNG, BCrypt-hashed before the proc | Controller | static SchoolsController.cs:161-169, 240-255 | PASS |
| SAS-A13 | Email delivery fails | SMTP/Brevo down | School still created; credentials shown in a persistent alert on the list | Controller | static: `NotificationService.SendAsync` never throws (NotificationService.cs:8, 34-39); fallback SchoolsController.cs:217-226, SchoolList.cshtml:68-76 | PASS |
| SAS-A14 | Re-render after a proc error | duplicate email on Save | Password not echoed back (hash must not be resubmitted) | UI | static Create.cshtml:365 `type="password"` (tag helper renders no value) | PASS |

## B. Create: second school on an existing tenant

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| SAS-B1 | Roles not duplicated | 2nd school, tenant 28 | Still 4 roles | Proc | SQL B1 | PASS |
| SAS-B2 | Next code | — | SCH23 | Proc | SQL B2 | PASS |
| SAS-B3 | Role defaults for the 2nd school | — | 3 roles granted for the new school_id | Proc | SQL B3 | PASS |
| SAS-B4 | 2nd admin's scope | sign in | Lands in the 2nd school only | Proc | SQL B4 | PASS |

## C. Create without an admin, add the admin later

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| SAS-C1 | **New tenant, admin switch off** | Create, *Create School Admin now* unticked | The 4 built-in roles exist | Proc | SQL C1 (got 0) | **BUG-1** |
| SAS-C2 | **…role defaults** | same | Teacher/Accountant/Receptionist defaults applied | Proc | SQL C2 (0 grants) | **BUG-1** |
| SAS-C3 | Add the admin on Edit | Edit → tick, name, email, password | Saves | Proc | SQL C3 | PASS |
| SAS-C4 | …login row | — | 1 active user | Proc | SQL C4 | PASS |
| SAS-C5 | **…has the SCHOOL_ADMIN role** | — | 1 user_roles row | Proc | SQL C5 (0: no SCHOOL_ADMIN role on the tenant, the INSERT … SELECT inserts nothing, silently) | **BUG-1** |
| SAS-C6 | **…can sign in** | GET_LOGIN_USER | Row for the admin | Proc | SQL C6 (no row → "Invalid email/mobile number or password") | **BUG-1** |
| SAS-C6b | **Second attempt repairs it** | Edit again with the same email | Saves | Proc | SQL C6b ("This email is already registered": the role-less login holds the email) | **BUG-1** |
| SAS-C7 | **2nd admin-less school on that tenant** | Create on tenant from C1 | Defaults applied | Proc | SQL C7 (0) | **BUG-1** |

## D. Validation and duplicates

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| SAS-D1 | Tenant code reused | `' zz-ALPHA '` | "Tenant code already exists." | Proc | SQL D1 | PASS |
| SAS-D2 | Tenant email reused | other case | "Tenant email already exists." | Proc | SQL D2 | PASS |
| SAS-D3 | **Code of a soft-deleted tenant** | `ZZ-Gone` (deleted tenant holds `zz-gone`) | Friendly refusal | Proc | SQL D3: raw `23505 tenants_tenant_code_key` (check filters `is_deleted = FALSE`, index does not) | **BUG-3** (low) |
| SAS-D4 | **Tenant code format** | `'zz has spaces/!'` | Refused (slug only) | Model/Proc | SQL D4: accepted; model has only StringLength(50) | **BUG-4** / DECISION D-B |
| SAS-D5 | Duplicate school name, same tenant | `'  zz alpha PUBLIC school '` | Refused | Proc | SQL D5 | PASS |
| SAS-D6 | Same name, other tenant | — | Allowed | Proc | SQL D6 | PASS (DECISION D-A) |
| SAS-D7 | Duplicate registration no. | `' zz-reg-1 '` | Refused | Proc | SQL D7 | PASS |
| SAS-D8 | Admin email = super admin's | `SUPERADMIN@educore.com` | "already registered" | Proc | SQL D8 | PASS |
| SAS-D9 | Admin phone reused, formatted | `+91 91000-00001` | "Admin phone already exists." | Proc | SQL D9 | PASS |
| SAS-D10 | Blank admin email | `'  '` | Refused | Proc | SQL D10 | PASS |
| SAS-D11 | 5-digit pincode | `27400` | Refused | Proc + model | SQL D11 | PASS |
| SAS-D12 | Letters in pincode | `abcdef` | Refused | Proc + model | SQL D12 | PASS |
| SAS-D13 | **Pincode starting with 0** | `012345` | Refused (model: `^[1-9][0-9]{5}$`) | Proc | SQL D13: proc accepts (`^[0-9]{6}$`) | **BUG-5** (low, defence in depth) |
| SAS-D14 | **Contact phone `12`** | — | Refused (model: `^[6-9][0-9]{9}$`) | Proc | SQL D14: proc only checks non-blank | **BUG-5** (low) |
| SAS-D15 | **Unknown status id** | 999 | Refused | Proc | SQL D15: accepted; `core.schools.status_id` has no FK → school with no status, login blocked with an empty message, missing from every status filter | **BUG-6** (low) |
| SAS-D16 | Unknown board id | 999 | Refused | Proc | SQL D16 | PASS |
| SAS-D17 | Tenant 1 as owner | existing tenant = 1 | Plain message | Proc | SQL D17; dropdown hides it (H7) | PASS |
| SAS-D18 | Non-existent tenant | 987654 | Refused | Proc | SQL D18 | PASS |
| SAS-D19 | No tenant option | mode NULL | Refused | Proc + controller | SQL D19; SchoolsController.cs:440-443 | PASS |
| SAS-D20 | Failed creates burn no code | 15 refused creates | Counter = created schools only | Proc | SQL D20 | PASS |
| SAS-D21 | **Short admin phone** | `12345` twice | Refused up front, or a friendly duplicate message | Proc | SQL D21: 2nd create → raw `23505 uq_user_phone_active` (`fn_user_phone_taken` skips < 10 digits, the index does not) | **BUG-5** (low) |
| SAS-D22 | Server-side validation exists | crafted POST without JS | Model attributes enforce phone/pincode/city/password ≥ 8 | Model | static SchoolManageModel.cs:72-144 | PASS |
| SAS-D23 | **Error text shown to the super admin** | any proc refusal | Plain message, logged | Controller | static SchoolsController.cs:177-182, 327-332: `ex.Message` of a PostgresException is `"P0001: …"` (or raw constraint text, see D3/D21); nothing is logged | **BUG-12** (low) |

## E. Board needs a state

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| SAS-E1 | State Board, no state | board 3 | Refused | Proc + controller | SQL E1; SchoolsController.cs:348-361 | PASS |
| SAS-E2 | Madrasah, no state | board 12 | Refused | Proc | SQL E2 | PASS |
| SAS-E3 | UP Board school in Bihar | board_state 26, state_id 4 | Refused | Proc | SQL E3 | PASS |
| SAS-E4 | **UP Board, address state id missing** | board_state 26, state_id NULL, state text "Bihar" | Refused | Proc | SQL E4: accepted, the mismatch check needs `p_state_id` (sp_school_manage.sql:319). The form requires StateId, so it is reachable only by a crafted POST | **BUG-5** (low) |
| SAS-E5 | CBSE + a posted board state | — | Stored NULL | Proc | SQL E5 | PASS |
| SAS-E6 | UP Board in UP | — | Stored 26 | Proc | SQL E6 | PASS |
| SAS-E7 | Edit State Board → CBSE | — | Board state cleared | Proc | SQL E7 | PASS |

## F. Edit keeps what the form does not post

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| SAS-F1 | School-owned profile fields | logo, header image, description set by the school; super admin renames | Kept | Proc | SQL F1 (proc upsert does not touch them) | PASS |
| SAS-F2 | School-owned settings | receipt/TC/ID-card format, backdate days, year, date format | Kept | Proc/UI | SQL F2; Create.cshtml:84-99 round-trips the hidden fields | PASS |
| SAS-F3 | Blank password on Edit | — | Hash, stamp and reset flag unchanged | Proc | SQL F3 | PASS |
| SAS-F4 | Admin email → another user's | — | Refused | Proc | SQL F4 | PASS |
| SAS-F5 | Admin phone → another user's | — | Refused | Proc | SQL F5 | PASS |
| SAS-F6 | Rename to a sibling's name | same tenant | Refused | Proc | SQL F6 | PASS |
| SAS-F7 | Admin email case | `ZZ.Alpha.NEW@…` | Stored lower-case | Proc | SQL F7 | PASS |
| SAS-F8 | Password reset by super admin | new hash | must_change + new stamp | Proc | SQL F8 | PASS |
| SAS-F9 | **Edit a school that is gone** | stale tab, purged id | "School not found." | Proc | SQL F9: "Tenant id is required." (tenant lookup runs before the existence check, sp_school_manage.sql:472) | **BUG-7** (low) |
| SAS-F10 | Clear admin phone | — | Stored NULL | Proc | SQL F10 | PASS |
| SAS-F11 | Tenant cannot change | — | School stays on its tenant | Proc/UI | SQL F11; Create.cshtml:107-120 read-only | PASS |

## G. Status = login gate

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| SAS-G1 | Every status | Active, Inactive, Pending, Under Review, Suspended, Closed set via Edit | Login allowed iff `allows_login` | Proc | SQL G1 (6/6) | PASS |
| SAS-G2 | Open session, school suspended | sp_session_check | school_ok = false | Proc | SQL G2 | PASS |
| SAS-G3 | Status changes audited | 6 changes | 6 SCHOOL_STATUS rows on tenant 1 | Proc | SQL G3 | PASS |
| SAS-G4 | Re-activate | Suspended → Active | Gate re-opens | Proc | SQL G4 | PASS |
| SAS-G5 | Super admin never gated | user 1, school 0 | ok | Proc | SQL G5 | PASS |

## H. School list, dropdowns, CheckEmail

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| SAS-H1 | Search by name | `ZZ Alpha` | Finds them | Proc | SQL H1 | PASS |
| SAS-H2 | **Search by tenant code** | `zz-alpha` | Finds the tenant's schools | Proc/Service | SQL H2 (0 rows); sp_school_list returns no tenant_code, and SchoolService.cs:66 maps `TenantCode = row["tenant_name"]` | **BUG-11** (low) |
| SAS-H3 | **Search "%"** | `%` | Only names containing % | Proc | SQL H3: matches every school (sp_school_list.sql:88-92, `ILIKE '%'‖p_search‖'%'` unescaped; `_` too) | **BUG-8** (low) |
| SAS-H4 | **"Active" counter** | 1 Active + 1 Under Review (both can sign in) | active = 2 | Proc | SQL H4: 1 (sp_school_list.sql:49 counts `st.name = 'Active'` by display name) | **BUG-9** / DECISION D-D |
| SAS-H5 | Tenant caller | LIST as tenant 28 | Own schools only | Proc | SQL H5 | PASS |
| SAS-H6 | Cross-tenant GET | the other test tenant GETs tenant 28's school | Nothing | Proc | SQL H6 | PASS |
| SAS-H7 | Tenant dropdown | — | No tenant 1; new tenant listed | Proc | SQL H7 | PASS |
| SAS-H8 | CheckEmail, used | `' ZZ.Alpha.NEW@…'` | taken | Proc | SQL H8 | PASS |
| SAS-H9 | CheckEmail on Edit | exclude the admin | free | Proc | SQL H9 | PASS |
| SAS-H10 | Paging guard | `page=0`, `pageSize=-5` | Clamped to 1 / 10 | Controller/Proc | static SchoolsController.cs:42-43; sp_school_list | PASS |

## I. Purge and archive

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| SAS-I1 | Active school | purge | Refused | Proc | SQL I1 | PASS |
| SAS-I2 | Partial name | `ZZ Purge Me` | Refused | Proc | SQL I2 | PASS |
| SAS-I3 | Non-platform caller | tenant 28 | Refused | Proc | SQL I3 | PASS |
| SAS-I4 | Archive content | — | School rows, admin email, no password_hash | Proc | SQL I4 (28 rows) | PASS |
| SAS-I5 | Archive of a missing id | — | Empty, purge then says "School not found." and the file is deleted | Proc/Controller | SQL I5; SchoolsController.cs:402-410 | PASS |
| SAS-I6 | Closed + typed name | stray spaces | Purged | Proc | SQL I6 | PASS |
| SAS-I7 | No orphans | every table in **any** schema with a school_id | 0 rows | Proc | SQL I7 | PASS |
| SAS-I8 | Admin login gone | — | 0 users, 0 profiles | Proc | SQL I8 | PASS |
| SAS-I9 | Siblings + tenant roles survive | — | 2 schools, 4 roles | Proc | SQL I9 | PASS |
| SAS-I10 | Sibling admin still signs in | — | Yes | Proc | SQL I10 | PASS |
| SAS-I11 | Purge audited | — | SCHOOL_PURGE on tenant 1 | Proc | SQL I11 | PASS |
| SAS-I12 | Re-onboard after purge | same name/email/phone | Allowed | Proc | SQL I12 | PASS |
| SAS-I13 | Purge UI | — | Button only for Closed; typed-name modal; antiforgery | UI | static SchoolList.cshtml:212-214, 336-383; SchoolsController.cs:375 | PASS |

## J. Access and the super admin shell

| ID | Scenario | Steps / input | Expected | Layer | How verified | Result |
|---|---|---|---|---|---|---|
| SAS-J1 | School tenant INSERTs a school | p_tenant_id = 28 | Refused | Proc | SQL J1 | PASS |
| SAS-J2 | School tenant changes its own status | UPDATE as 28 | Refused | Proc | SQL J2 | PASS |
| SAS-J3 | **Leftover DELETE op** | `sp_school_manage('DELETE')` | Removed (the controller action was removed because it strands schools) | Proc | SQL J3: still soft-deletes (sp_school_manage.sql:238) | **BUG-10** (low) |
| SAS-J4 | SUPER_ADMIN only for tenant 1 | school role coded SUPER_ADMIN | Impossible | Controller/Proc | static AccountController.cs:309 (`TenantId == 1 && SchoolId == 0`); sp_role_manage reserves the code | PASS |
| SAS-J5 | School admin types `/SuperAdmin/Schools/Create` | — | 403 | Controller | static SchoolsController.cs:17 `[Authorize(Roles = SUPER_ADMIN)]` | PASS |
| SAS-J6 | Super admin types an ERP URL | `/ERP/Fee/ManageFee` as tenant 1 | Refused / empty, no crash | Service | static PermissionService.cs:68 (tenant ≤ 1 → no access); services guard tenant > 1 | PASS |
| SAS-J7 | **Super admin sidebar** | log in as super admin, use the menu | A "Schools" entry (list, new school) | UI | static _VerticalMenu.cshtml: no SuperAdmin link at all. Dashboard (:145-147) and the brand logo open `Dashboards/Index`, which is empty for tenant 1 (DashboardService returns nothing for tenant ≤ 1). The only way back is the login redirect or typing the URL | **BUG-2** (med) |
| SAS-J8 | Super admin ERP menu groups | tenant 1, school 0 | None shown (no dead links) | UI | static: `isAdmin` is false for tenant 1, so every `Can()` is false | PASS |
| SAS-J9 | ChooseRole for a multi-role super admin | — | Picks SUPER_ADMIN → SchoolList | Controller | static AccountController.cs:243-299, 333 | PASS |

---

## Bugs found (by severity)

**High**
1. **BUG-1 (C1-C7). A school created without its admin can never get a working admin, and its built-in roles get no permissions.** `core.sp_school_manage` seeds the tenant's four roles only inside the `INSERT AND p_create_school_admin` block (sp_school_manage.sql:906), so `fn_apply_builtin_role_defaults` (:960) finds no roles. Adding the admin later from Edit (:1037-1060) inserts the user and profile, but the `user_roles INSERT … SELECT … WHERE role_code = 'SCHOOL_ADMIN'` matches nothing and succeeds silently. The admin then hits "Invalid email/mobile number or password", and a retry is blocked by "email already registered". This is reachable from the UI: the Create wizard has the *Create School Admin now* switch. **Fix:** move the role-seeding INSERT out of the admin block so it runs on every INSERT (before `fn_apply_builtin_role_defaults`). Call the same seeding in the UPDATE create-admin path. After assigning the role, `RAISE` if no row was inserted, so a role-less login is rolled back.

**Medium**
2. **BUG-2 (J7). The super admin has no navigation to Schools.** `_VerticalMenu.cshtml` has no SuperAdmin entries, and Dashboard plus the logo lead to an empty tenant-1 dashboard. **Fix:** when the role is SUPER_ADMIN, render a "Schools" item (School List, New School) and make `DashboardsController.Index` redirect a tenant-1 user to `SuperAdmin/Schools/SchoolList`.

**Low**
3. **BUG-3 (D3).** The tenant-code check filters `is_deleted = FALSE` (sp_school_manage.sql:416), but `tenants_tenant_code_key` covers deleted rows → raw 23505. **Fix:** drop the `is_deleted` filter from that EXISTS.
4. **BUG-4 (D4).** The tenant code accepts spaces and symbols. **Fix:** `[RegularExpression("^[a-z0-9-]{2,50}$")]` on `TenantCode` plus the same check in the proc (see D-B).
5. **BUG-5 (D13, D14, D21, E4).** The proc's validation is weaker than the form's: pincode `^[0-9]{6}$` vs `^[1-9]…` (:295), contact/admin phone with no format check (:329), a sub-10-digit admin phone → raw `uq_user_phone_active`, and the board-state mismatch skipped when `p_state_id` is NULL (:319). **Fix:** mirror the model's regexes in the proc and require `p_state_id` when the board requires a state.
6. **BUG-6 (D15).** Any `p_status_id` is accepted (`core.schools.status_id` has no FK). **Fix:** add an FK to `config.school_statuses`, or an EXISTS check next to "Status is required." (:274).
7. **BUG-7 (F9).** Editing a missing school says "Tenant id is required." **Fix:** in the UPDATE branch, raise "School not found." when the tenant lookup finds no row.
8. **BUG-8 (H3).** List search does not escape `%`/`_`. **Fix:** escape them (`replace(replace(p_search,'%','\%'),'_','\_')`) or use `position()`.
9. **BUG-9 (H4).** `active_count` counts the display name 'Active' (sp_school_list.sql:49), so Under Review schools (which can sign in) show as inactive. **Fix:** count `st.allows_login` (or `status_code = 'ACTIVE'`; see D-D).
10. **BUG-10 (J3).** The `DELETE` branch is still in `sp_school_manage` (:238). It hides a school from both the list and Edit. **Fix:** remove it.
11. **BUG-11 (H2).** `SchoolService.cs:66` maps `TenantCode` from `tenant_name`, and `sp_school_list` neither returns nor searches `tenant_code`. **Fix:** select `t.tenant_code`, map it, and add it to the search.
12. **BUG-12 (D23).** `SchoolsController` shows `ex.Message` (`"P0001: …"`, or raw constraint text) and logs nothing, against the CLAUDE.md logging convention. **Fix:** inject `ILogger`, catch `PostgresException` → show `MessageText` and log a Warning with its SqlState; any other exception → log an Error and show a generic message.

## Needs a business decision

- **D-A Same school name on two tenants.** Allowed today (SAS-D6). Recommended default: keep it allowed, since two unrelated trusts can both run a "St. Mary's School".
- **D-B Tenant code format.** Recommended default: a lower-case slug `[a-z0-9-]`, 2-50 chars, immutable after creation.
- **D-C School without an admin.** Should Create even allow it? Recommended default: keep the option (sales onboard before the principal is known), but fix BUG-1 so roles and defaults always exist.
- **D-D What the list's "Active" counter means.** Recommended default: "can sign in" (`allows_login`), so Under Review counts as active.
- **D-E Primary school Closed, another role's school active** (AUTH-18 follow-up). The login gate uses the primary role's school, so such a user cannot reach the active school at all. Recommended default: leave as is until cross-school roles exist in the UI.
- Purging a tenant's last school keeps the tenant and its roles. That was already decided (platform_access_security D-7: keep).
