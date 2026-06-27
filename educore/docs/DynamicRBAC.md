# Dynamic RBAC — Roles & Permissions

Reference for EduCore's **dynamic role-based access control**: what it does, the data model,
the runtime enforcement path, the management UI, and how to extend it. Read this before adding a
new permission, gating a controller, or changing the menu.

> Audience: developers working on EduCore. Assumes the general architecture in the root
> `CLAUDE.md` (ASP.NET Core 9 MVC, PostgreSQL stored procs via `PgExec`, no ORM, claims-based
> multi-tenancy). Built June 2026 on branch `RemoveLMSThings`.

---

## 1. What it is (and why)

A school admin can **define roles**, tick **permissions** for each role in a matrix, assign roles
to users, and have those permissions actually drive:

1. **What appears in the sidebar** (a role only sees modules it can reach), and
2. **What a user can open / do** (controllers return **403** when the role lacks the permission).

### The problem it replaced
Roles already lived in `config.roles` and the Staff "give login" screen could assign them, **but
their meaning was hardcoded** — `Program.cs` policies used `RequireRole("SCHOOL_ADMIN")`, the menu
was a static list, and the `AppRoles` constants in `Common.cs` were the only thing a role *did*.
Critically, `config.role_permissions` referenced a `permission_id` table **that did not exist** —
there was no permission catalog. This feature adds that catalog and wires the whole loop.

### Design decisions (fixed)
- **Granularity:** two permissions per feature — `<feature>.view` and `<feature>.manage`.
  *Manage* implies create/edit/delete **and** implies *view*.
- **Admin bypass:** `SUPER_ADMIN` and `SCHOOL_ADMIN` implicitly hold **every** permission — they
  can never lock themselves out. Only other/custom roles are governed by the matrix.
- **Catalog is global; grants are tenant-scoped.** The list of *capabilities* is the same for every
  school (defined by developers); *which role holds which capability* is per-tenant data.
- **A user may hold MULTIPLE roles; permissions are the UNION of all of them** ("add them up", no
  role-switching). If *any* of a user's roles is an admin role, the user is an admin.
- **Role-based only — no per-person permission overrides.** A person's access = the sum of their
  role(s). To change access, change/assign roles.
- **People & access live on ONE page.** Adding an employee, giving them a login, and assigning
  role(s) all happen on the **Staff (People)** screen. "Roles & Permissions" is a separate, rarely-
  visited config screen that *defines* what each role can do. There is no standalone "Users" page.

---

## 2. Data model

```
config.permissions        (GLOBAL catalog — the capability list; no tenant_id)
        ▲
        │ permission_id
        │
config.role_permissions   (tenant-scoped: which role is granted which permission)
        │ role_id
        ▼
config.roles              (tenant+school-scoped roles; has role_code, role_name)
        ▲
        │ role_id
        │
core.user_roles           (which user has which role; one primary role per user)
        │ user_id
        ▼
core.users / core.user_profiles
```

### `config.permissions` (created by `Database/rbac.sql`)
| Column | Notes |
|--------|-------|
| `permission_id` | identity PK |
| `permission_key` | unique, e.g. `students.manage` |
| `module_group` | for matrix grouping (`Academic`, `Finance`, `People`, `Administration`) |
| `display_name` | e.g. `Students — Manage` |
| `sort_order`, `is_active` | ordering / soft-disable |

**26 seeded permissions** = `view`+`manage` for each feature, except `rbac` (manage-only) and
`reports` (view-only):

```
enquiry  registration  students  academics  attendance  exams        (Academic)
fees                                                                  (Finance)
staff  transport  inventory                                          (People)
settings  admission_workflow  reports  rbac                          (Administration)
```

`Database/rbac.sql` is **idempotent** (CREATE TABLE IF NOT EXISTS + `ON CONFLICT (permission_key)
DO NOTHING`). It also **deletes the 4 stray `config.role_permissions` rows** that were platform
(tenant 1) test data pointing at the pre-existing non-catalog ids.

### `config.roles` (already existed)
Tenant+school scoped. `role_code` is auto-generated from the role name on insert (UPPER, non-alnum
→ `_`, de-duped within the tenant). The five **built-in** codes — `SUPER_ADMIN`, `SCHOOL_ADMIN`,
`TEACHER`, `ACCOUNTANT`, `RECEPTIONIST` — **cannot be renamed or deleted** (enforced in the proc).

---

## 3. Stored procedures (`Database/sp_rbac_manage.sql`)

All follow the project convention: **positional params** (`CommandType.StoredProcedure`),
`INOUT … refcursor` outputs, and a `tenant > 1 AND school > 0` guard.

| Proc | Purpose |
|------|---------|
| `config.sp_role_manage` | `LIST` / `GET` / `INSERT` / `UPDATE` / `DELETE`(soft) roles. Auto-codes new roles; blocks rename/delete of built-ins; blocks delete if users are assigned. LIST returns `is_builtin`, `user_count`, `permission_count`. |
| `config.sp_permission_catalog` | The global catalog (matrix source). |
| `config.sp_role_permissions_get` | The granted `permission_id`s for one role (drives matrix checkboxes). |
| `config.sp_role_permissions_save` | Replace a role's grants from an `integer[]`: soft-delete removed, revive previously-removed, insert new. |
| `config.sp_role_permissions_resolve` | The granted **permission KEYS** for one role — used by the runtime resolver. |
| `core.sp_user_roles_resolve` | All active roles (id + code) for a **user** — used to union their permissions and detect an admin role, and to pre-check the People edit form. |

Multi-role assignment is handled by **`core.sp_staff_manage`** (the People form): giving or editing a
login takes a `p_role_ids integer[]` and syncs `core.user_roles` (insert new / revive / soft-delete
removed, keeping exactly one primary). The older `sp_user_role_list` / `sp_user_role_assign` procs are
no longer used by the UI (the standalone Users page was removed).

---

## 4. Runtime enforcement (C#)

### 4.1 The claim
On login, `AccountController.UserAuthorization` (the single sign-in path for both single- and
multi-role users) adds the role id claim:

```csharp
new Claim(Common.SK_RoleId, user.RoleId.ToString())   // "_roleid"
```

Permissions are resolved **per user** (`_userid`), not per the selected role, so the `_roleid` /
`role_code` claims now only drive the post-login landing/redirect — not access.

### 4.2 `IPermissionService` / `PermissionService`
`EduCoreDataAccessLayer/Services/PermissionService.cs` (registered **Scoped** in `Program.cs`):

```csharp
Task<bool> HasPermissionAsync(t, s, userId, key);
Task<(bool IsAdmin, HashSet<string> Keys)> GetUserAccessAsync(t, s, userId);   // for the menu
void InvalidateRole(t, s, roleId);
void InvalidateUser(t, s, userId);
```

- **Union by user:** `GetUserAccessAsync` loads the user's roles, and if any is an admin role returns
  `IsAdmin = true` (full bypass); otherwise it returns the **union** of every role's permission keys.
- **Two small caches (so invalidation stays correct):**
  - the user's role list → `AppCache.Key("uroles:u{userId}", t, s)` — dropped when their roles change
    (`InvalidateUser`, called by the People save).
  - each role's key set → `AppCache.Key("rperms:r{roleId}", t, s)` — dropped when that role's matrix
    is saved (`InvalidateRole`, called by `RolesController.SavePermissions`).
  The per-request union over a handful of roles is cheap, so the final set isn't cached — which means
  a **matrix edit is live immediately for every user with that role**.
- **`manage` ⇒ `view`:** loading a role's keys also adds `x.view` for every `x.manage`.

### 4.3 The `[HasPermission]` attribute
`educore/Helpers/HasPermissionAttribute.cs` — a `TypeFilterAttribute` wrapping an
`IAsyncAuthorizationFilter` that pulls `IPermissionService` from DI, reads the claims, and:

- unauthenticated → `ChallengeResult` (redirect to login);
- authenticated but lacking the permission → **403** (`StatusCodeResult(403)`).

```csharp
[HasPermission("students.manage")]
public IActionResult EditStudent(...) { ... }
```

**Filters AND together:** a controller-level `[HasPermission("x.view")]` + an action-level
`[HasPermission("x.manage")]` means the action needs *both* — and since manage⇒view, that resolves
to "needs manage". This is the pattern used on POST actions.

---

## 5. Where it's enforced (controller tagging)

Single-feature controllers carry a controller-level `.view` gate and a `.manage` gate on each
`[HttpPost]`:

| Controller(s) | Feature |
|---------------|---------|
| `ERP/Student`, `ERP/Admission` | `students` |
| `ERP/Attendance` | `attendance` |
| `ERP/Exam` | `exams` |
| `ERP/Staff`, `ERP/Leave`, `ERP/Payroll` | `staff` |
| `Admin/Enquiry` | `enquiry` |
| `Admin/Registration` | `registration` |
| `Admin/Transport` | `transport` |
| `Admin/AdmissionWorkflow` | `admission_workflow` |
| `Admin/PaymentVerification`, `Admin/FeeDueReminders` | `fees` (view) |
| `Admin/Roles` | `rbac.manage` |

**Mixed-feature controllers are tagged per action** (no controller-level gate):

- **`Admin/SchoolSettings`** — `BasicProfile`/`AcademicYears` → `settings`; `FeeHead`/`FeeStructure`
  → `fees`; `ClassSection`/`Subjects`/`Timetable`/`PeriodStructure`/`AssignClassTeacher` →
  `academics`; `EnquiryCRM` → `enquiry`. GETs use `.view`, mutations use `.manage`.
- **`ERP/Fee`** — controller-level `fees.view` + `fees.manage` on `Collect`/`CancelReceipt`/
  `Refund`/`CloseDay`.

**Intentionally NOT gated:** `Dashboards`, `Home`, `Account` (any logged-in user needs them) and
the **SuperAdmin** area (platform-level; super admin is bypassed anyway).

### Inventory caveat
The `InventoryItem` / `PurchaseEntry` stub pages physically live inside `ERP/FeeController`, so they
are gated by `fees.view`, and the sidebar's Inventory group uses `Can("fees.view")`. The
`inventory.view` / `inventory.manage` catalog permissions exist but are **reserved** for a future
dedicated Inventory module — ticking them does nothing until that module is split out.

---

## 6. Dynamic sidebar (`Views/Shared/Sections/Menu/_VerticalMenu.cshtml`)

The menu injects `IPermissionService`, calls `GetUserAccessAsync(t, s, userId)` once per render
(union of the user's roles + admin flag), and defines a local `Can(key)` helper (returns `true` for
admins). Each submenu item, group, and section header is wrapped in `@if (...)` using group booleans
(`gStudents`, `gFees`, `secAcademic`, …). Net effect:

- **Admins:** unchanged — they see everything.
- **Custom roles:** only the modules they're granted; empty groups and their section headers vanish.

Placeholder-only modules with no real screens yet (Accounting, Library, Hostel, Communication,
Certificates, Billing) are gated to `isAdmin`. The old "Users & Roles" placeholder is now a real
link to `Admin/Roles/Index`, gated by `rbac.manage`.

---

## 7. Management UI

There are **two** screens (the standalone Users page was removed — people + access live on the
People form):

| Screen | Route | What |
|--------|-------|------|
| **People (Staff)** | `ERP/Staff/StaffList` → Add/Edit | Add/edit any employee. The **App Access** card: toggle login on/off; when on, set a temporary password (new login) and tick **one or more roles** (mobile-friendly checkboxes). Editing a person who already has a login shows their current roles pre-ticked and lets you change them. This is where users are created and roles assigned. |
| **Roles & Permissions** | `Admin/Roles/Index` | Define roles (create/rename/delete, custom only) and, per role, the **permission matrix** (`/Permissions/{id}`): module-grouped **View / Manage** grid; *Manage* auto-ticks *View*; select-all/clear; Save writes grants and invalidates that role's cache. |

Backing services: role/matrix screens use `IRbacService` / `RbacService`; the People form uses
`IStaffService` / `StaffService` (its `core.sp_staff_manage` now takes `p_role_ids integer[]`). Both
under `EduCoreDataAccessLayer/Services/...`, mirroring each other (DataSet/DataRow,
`PostgresException` → Warning). Models: `RbacModels.cs` and `StaffModel.cs` (`RoleIds : List<int>`).

The Roles screen is protected by `[HasPermission("rbac.manage")]`; the People screen by
`[HasPermission("staff.view")]` (+ `staff.manage` on saves) — i.e. admins, plus any role granted
those permissions.

---

## 8. Operational notes (important)

- **When changes take effect (both are immediate — next page load, no re-login):**
  - Editing a role's **permission matrix** → `InvalidateRole` drops that role's cached keys, so every
    user holding it sees the change on their next request.
  - Changing a **person's role(s)** on the People form → `InvalidateUser` drops their cached role
    list, so their access updates on their next request. (The login-time `role_code` claim only
    affects the landing redirect, not access, so it doesn't matter that it's stale.)
- **Adding a brand-new role** drops you straight into its (empty) permission matrix.
- A role that is **assigned to users cannot be deleted** — reassign those users first.
- Permission changes never require an app restart; only new C# binaries do.

---

## 9. How to extend

### Gate a new (or existing) controller
1. `using educore.Helpers;`
2. Add `[HasPermission("<feature>.view")]` on the controller (single-feature) **or** per action
   (mixed-feature).
3. Add `[HasPermission("<feature>.manage")]` on each mutating `[HttpPost]`.

### Add a new feature permission
1. Add a row (or `view`+`manage` pair) to the seed in `Database/rbac.sql` and re-run it (idempotent).
2. Use the new key in `[HasPermission(...)]` and, if it has a menu entry, in `_VerticalMenu.cshtml`.
3. No C# model change is needed — the catalog is data-driven and the matrix renders it automatically.

### Make a role behave specially in code
Permission checks are data-driven, but a few flows still branch on **role** (login redirect,
`Program.cs` `RequireRole` policies, `AppRoles` constants). Those are intentionally left in place;
extend them only if a new role needs hardcoded behavior beyond permissions.

---

## 10. Apply / verify

```bash
# 1. apply the SQL (psql; PGPASSWORD=root; db educore)
psql -U postgres -h localhost -d educore -f EduCoreDataAccessLayer/Database/rbac.sql
psql -U postgres -h localhost -d educore -f EduCoreDataAccessLayer/Database/sp_rbac_manage.sql

# 2. build + restart the app (new binaries)
dotnet build educore/educore.csproj
```

**End-to-end smoke test:**
1. Log in as **School Admin** (test data: tenant 2 / school 1) → menu unchanged (bypass).
2. **Settings → Users & Roles** → create "Librarian"; in its matrix grant **Students → View** and
   **Fees → View**; Save.
3. Go to **Staff (People)** → add/edit a person → **App Access**: turn login on, set a password, and
   tick **Librarian** (you can tick several). Save. Log in as that user → sidebar shows only Students
   + Fees (read); POSTing an edit or opening `/Admin/Roles` → **403**.
4. Edit the person, tick a second role (e.g. Accountant) → Save → they now have the **union** of both
   (next page load, no re-login). Edit Librarian's matrix, Save → change is live immediately. Confirm
   built-in roles can't be deleted.

---

## 11. Files

**Database**
- `EduCoreDataAccessLayer/Database/rbac.sql` — catalog table + seed + cleanup
- `EduCoreDataAccessLayer/Database/sp_rbac_manage.sql` — role/matrix procs + `core.sp_user_roles_resolve`
- `EduCoreDataAccessLayer/Database/sp_staff_manage.sql` — People form; `p_role_ids integer[]` + role-sync

**Data layer**
- `EduCoreDataAccessLayer/Models/RbacModels.cs`; `Models/StaffModel.cs` (`RoleIds : List<int>`)
- `EduCoreDataAccessLayer/Services/Contract/Admin/IRbacService.cs` + `Repository/Admin/RbacService.cs`
- `EduCoreDataAccessLayer/Services/Repository/Admin/StaffService.cs` — passes the role array, loads current roles on edit
- `EduCoreDataAccessLayer/Services/PermissionService.cs` (`IPermissionService` — union by user)
- `EduCoreDataAccessLayer/Helpers/Common.cs` — `SK_RoleId` claim key

**Web**
- `educore/Helpers/HasPermissionAttribute.cs` (resolves by `_userid`)
- `educore/Areas/Admin/Controllers/RolesController.cs` (Users controller removed)
- `educore/Areas/Admin/Views/Roles/{Index,Permissions}.cshtml` (Users view removed)
- `educore/Areas/ERP/Controllers/StaffController.cs` + `Areas/ERP/Views/Staff/{AddStaff,EditStaff}.cshtml` — App Access + multi-role
- `educore/Controllers/AccountController.cs` — adds the `_roleid` claim (landing only)
- `educore/Program.cs` — registers `IRbacService`, `IPermissionService`
- `educore/Views/Shared/Sections/Menu/_VerticalMenu.cshtml` — permission-gated menu
- `[HasPermission]` applied across the Admin/ERP feature controllers (see §5)

---

## 12. Known limitations / deferred

- `inventory.*` permissions are inert until Inventory becomes its own module (see §5).
- `Program.cs` `RequireRole` policies and `AppRoles` constants remain hardcoded (untouched, so
  nothing regresses). Note these legacy policies key on the single login-time `role_code`, so a
  multi-role user who selects a non-admin role at login won't satisfy `SchoolAdminOnly` for that
  session — but dynamic `[HasPermission]` gating (union by user) is unaffected.
- **People** only lists employees (`core.staff`). A login with no staff row — e.g. the very first
  School Admin created at school provisioning — won't appear there; manage such accounts via SQL or a
  future dedicated screen.
- Per-person permission overrides are not supported (role-based only, by design).
