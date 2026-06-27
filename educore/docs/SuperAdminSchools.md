# SuperAdmin — School Management

Reference for the **SuperAdmin → Schools** module: what it does, how it is wired, the
stored procedures behind it, and the things that have bitten us (so they don't again).

> Audience: developers working on EduCore. Assumes the general architecture in the root
> `CLAUDE.md` (ASP.NET Core 9 MVC, PostgreSQL stored procs via `PgExec`, no ORM).

---

## 1. What it is

The platform **super admin** (role `SUPER_ADMIN`, **tenant 1**, no school) onboards and manages
schools across every tenant. The module provides:

| Feature | Route | Notes |
|---------|-------|-------|
| **School list** | `GET /SuperAdmin/Schools/SchoolList` | Server-side search + filters + pagination + counts |
| **Create school** | `GET/POST /SuperAdmin/Schools/Create` | 4-step wizard; optionally creates the first School Admin + emails credentials |
| **Edit school** | `GET/POST /SuperAdmin/Schools/Edit/{id}` | Reuses the wizard, pre-filled (incl. the existing admin) |
| **Disable school** | `POST /SuperAdmin/Schools/Delete/{id}` | Soft delete (`is_active=false, is_deleted=true`) |

After login a `SUPER_ADMIN` lands here (`HomeController.Dashboard` / `AccountController.RedirectByRole`).

---

## 2. Access / security

- Controller is `[Authorize(Roles = AppRoles.SuperAdmin)]` (`SUPER_ADMIN`). Policy `SuperAdminOnly`
  in `Program.cs` keys on role + tenant claim.
- A super admin is **tenant 1 with school 0** (`IsValidSaasScope` in `AccountController`).
- **Tenant scoping rule used throughout the procs:** `p_tenant_id = 1` means "platform — see/act on
  all tenants"; any other tenant id is restricted to its own rows. (This is why the list, edit,
  delete all special-case `= 1`.)

---

## 3. The Create wizard (4 steps)

Trimmed to the essentials a super admin needs at provisioning. Optional/branding fields are left
for the School Admin to complete later in their own **Basic Profile** screen.

1. **Organization & School** — tenant (pick existing / create new) + School Name, Display, Status, Board, Type
2. **Address & Contact** — Address line 1, City, State, Pincode + Contact name, Phone, Email
3. **School Admin** — create the first login (name, email, phone, password)
4. **Review & Save**

Required fields are marked with a **red `*`**. Required set (enforced by the proc + model
`[Required]`): tenant choice, school name, status, board, type, address line 1, city, state,
pincode, contact name, phone; admin name + email when creating an admin.

**Fields not in the wizard but preserved:** website, ownership, medium, established year,
registration/affiliation no., address line 2, district, designation, alternate phone, academic
year, date/time formats, comms toggles. They are rendered as **hidden inputs** so editing a school
never wipes values the School Admin may have set.

---

## 4. Credential delivery (new School Admin)

When the wizard creates a School Admin:

1. Controller generates a strong temp password (or uses the typed one) and **BCrypt-hashes it**
   before storing (login uses `BCrypt.Verify`, so a raw/blank value can never log in).
2. A **welcome email** with login URL + temp password is sent via `IEmailService`.
3. **Fallback:** if email is disabled/misconfigured/fails, the credentials are shown once to the
   super admin in an on-screen alert so the admin is never silently locked out.

### Email config
- Service: `educore/Services/EmailService.cs` (System.Net.Mail — no extra package), bound to
  `EmailSettings` from the **`Email`** config section, registered singleton in `Program.cs`.
- `appsettings.json` keeps the section **secret-free** (`Enabled=false`, empty creds).
- Real creds go in **`appsettings.Development.json`** (must be git-ignored) or `Email__*` env vars.
- **Gmail:** requires a 16-char **App Password** (2-Step Verification on) — a normal account
  password is rejected. Host `smtp.gmail.com`, port `587`, `UseSsl=true` (STARTTLS).

> Edit mode: the password field is an optional **"Reset Password"** — blank keeps the current
> password; a new value is hashed and saved. Editing does **not** re-send a welcome email.

---

## 5. Architecture / files

```
educore/
  Areas/SuperAdmin/
    SchoolsController.cs                     # all actions + password gen/hash + email orchestration
    Views/
      _ViewImports.cshtml                    # REQUIRED: enables tag helpers (asp-*) for the area
      Schools/SchoolList.cshtml              # list: filters, pagination, counts, edit/disable
      Schools/Create.cshtml                  # the 4-step wizard (also used for Edit)
  Services/
    EmailSettings.cs / IEmailService.cs / EmailService.cs
EduCoreDataAccessLayer/
  Models/SchoolManageModel.cs               # wizard model (incl. AdminUserId)
  Services/Contract/SuperAdmin/ISchoolService.cs
  Services/Repository/SuperAdmin/SchoolService.cs
  Database/
    sp_school_manage.sql                    # INSERT / UPDATE / GET / DELETE (single school)
    sp_school_list.sql                      # paginated, filtered list
```

Request flow is the standard one: **Controller → ISchoolService → PgExec → stored proc → map rows**.

---

## 6. Stored procedures

### `core.sp_school_manage` — single-school CRUD
One proc, switched on `p_operation`. **Operation codes are full words:** `INSERT`, `UPDATE`,
`GET`, `DELETE`, `LIST` (legacy single letters `I/U/G/D/L` are gone — keep C# and proc in sync).

- **INSERT** — resolves/creates the tenant, inserts school + profile + address + contact + settings;
  if `p_create_school_admin`, **seeds the tenant's standard roles if missing**, creates the user +
  profile, and assigns **SCHOOL_ADMIN by role code** (not a hardcoded id).
- **UPDATE** — for a platform actor (tenant 1) resolves the school's own tenant; upserts the same
  child rows; updates the existing admin (name/email/phone, password only if a new hash is passed),
  or creates one if none exists and a password is given.
- **GET** — returns the school + profile + address + contact + settings **and the primary
  SCHOOL_ADMIN** (`admin_user_id/full_name/email/phone`) for edit pre-fill.
- **DELETE** — soft delete.

### `core.sp_school_list` — list screen
Params (positional — `PgExec` uses `CommandType.StoredProcedure`, so **order matters**):
`p_tenant_id, p_action_user_id, p_search, p_city, p_state, p_status_id, p_board_id,
p_school_type_id, p_from_date, p_to_date, p_page_no, p_page_size, p_result`.
Returns the page of rows plus `total_count` and `active_count` as `COUNT(*) OVER()` window columns
(computed over the full filtered set, before `LIMIT`).

> **Editing a proc:** `pg_get_functiondef` is dumped into `Database/*.sql`, edited, and re-applied
> with `psql -f`. Update the `.sql` **and** the consuming C# together.

---

## 7. Roles & multi-tenancy (important)

- **Roles are per-tenant** rows in `config.roles` (`role_id` is an **identity** column — never insert
  it explicitly). The login lookup joins `config.roles ON role_id = ur.role_id AND tenant_id =
  user.tenant_id`, so **every tenant must have its own role rows** or its users can't log in.
- `sp_school_manage` **seeds the standard staff roles** (`SCHOOL_ADMIN`, `TEACHER`, `ACCOUNTANT`,
  `RECEPTIONIST`) for a tenant on first admin creation, and assigns SCHOOL_ADMIN **by code**.
- Login (`core.sp_login_management` / `GET_LOGIN_USER`) requires the user to have an **active,
  primary** `user_roles` row whose role exists for the user's tenant. A new admin gets
  `is_primary = TRUE` (column default).

---

## 8. Things that have actually bitten us

- **Tag helpers dead in the area.** Areas need their **own `_ViewImports.cshtml`**
  (`@addTagHelper *`). Without it, `asp-action`/`asp-controller`/`asp-items` render with **empty
  href / empty selects** → "New School"/Edit/filters silently do nothing. Already added — don't remove.
- **404 on Edit / "School not found" on save / Disable doing nothing** = a proc tenant-scope check
  using `p_tenant_id = 0` instead of `= 1`. Super admin is tenant **1**. All branches now use `= 1`.
- **"Wrong password" right after creating an admin** was *not* the password — it was a missing/
  mismatched role (the tenant had no `SCHOOL_ADMIN` row, or a hardcoded `role_id` pointed at the
  wrong role). Fixed by per-tenant seeding + assign-by-code.
- **Admin password never worked** originally because the service stored `model.Password` raw as
  `p_password_hash`. It is now BCrypt-hashed in the controller before saving.
- **Disabled schools don't open in Edit** — `GET` only returns `is_active = TRUE` schools (expected).
- **C# changes need an app restart** (compiled). Views are runtime-compiled in Development, but
  `_ViewImports.cshtml` and controller/service changes require a restart.

---

## 9. Local dev quick checks (psql)

```bash
# psql isn't on PATH; password is 'root'
export PGPASSWORD=root
PSQL="/c/Program Files/PostgreSQL/16/bin/psql.exe"

# list as super admin (tenant 1 = all)
"$PSQL" -U postgres -d educore -c "BEGIN; CALL core.sp_school_list(1,1,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1,10,'c'); FETCH ALL IN \"c\"; COMMIT;"

# get one school (incl. admin) as super admin
"$PSQL" -U postgres -d educore -x -c "BEGIN; CALL core.sp_school_manage('GET',1,1,p_school_id:=10,p_result:='c'); FETCH ALL IN \"c\"; COMMIT;"
```

Test data: real schools are tenant > 1 (e.g. tenant 7); tenant 2 is the seeded demo tenant.

---

## 10. Known limitations / possible next steps

- **Roles are duplicated per tenant.** Fine if schools never define custom roles; if they won't,
  a global standard-role set (and a login-join change) would remove the duplication.
- Edit does not manage **multiple** admins per school — it edits the single primary `SCHOOL_ADMIN`.
- No **tenant management** screen yet (tenants are created only as a side effect of school create).
- No platform **dashboard** (counts/health) — the list is the landing page.
- Email is **best-effort** (no retry/queue); failures fall back to on-screen credentials.
```
