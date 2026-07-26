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
2. **Address & Contact** — Address line 1, State/District/City, Pincode + Contact name, Phone, Email
3. **School Admin** — create the first login (name, email, phone, password)
4. **Review & Save**

> On **Edit** the tenant is read-only: `sp_school_manage` resolves the tenant from the school
> row on UPDATE and ignores whatever is posted, so an editable dropdown there was a lie.

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

## 5a. School code — SCH1, SCH2, SCH3 …

`core.schools.school_code` is a **gap-free running sequence**, drawn from
`core.school_code_counters` (`Database/school_code_sequence.sql`).

It got there in three steps, and the middle one is the interesting bit:

| | Generator | Problem |
|---|---|---|
| 1 | `'SCH' \|\| YYYYMMDDHH24MISS` | Only unique to the **second** — two schools created in the same second on one tenant collided on `uq_school_code (tenant_id, school_code)` and the second save died with a raw constraint error |
| 2 | `'SCH' \|\| LPAD(school_id,5)` | Collision-proof, but `school_id` is an identity column and **advances on rolled-back inserts**, so codes jumped (SCH00019 → SCH00024) |
| 3 | **counter row** | Sequential *and* gap-free |

**Why a counter row and not a `SEQUENCE`:** `nextval()` does not roll back, so a failed save burns
a number and leaves a hole — the exact thing being fixed. `UPDATE … RETURNING` on a counter row
rolls back with the transaction, and its row lock makes concurrent creates queue rather than race.
Same pattern the codebase already uses for receipt / admission / registration / TC numbers
(`core.*_counters`).

Codes are **global**, not per tenant: a super admin works across tenants, and one `SCH7` that means
exactly one school beats a `SCH7` in every tenant.

> **Caveat — text sorting.** Unpadded numbers sort as text: `SCH1, SCH10, SCH11, SCH2, …`.
> Harmless today: the live list (`sp_school_list`) orders by `school_id DESC`, and the only proc
> that can sort by code, `sp_school_list1`, is **not called from any C#**. If a sort-by-code column
> is ever added, order by `NULLIF(regexp_replace(school_code,'\D','','g'),'')::int` instead.

Existing schools were renumbered to `SCH1..SCH13` in creation order. Safe because `school_code` is
display-only — it appears in `sp_school_list` / `sp_school_list1` /
`sp_school_admin_basic_profile_manage` as a selected column, an `ILIKE` search target and a sort
key, **never as a lookup key**, and no C# generates or matches on it.

---

## 5b. Admin email uniqueness — one rule, one guard

Creating a school admin with an email held by a **deactivated** user used to fail with a raw
Postgres error instead of a message:

```
ERROR: duplicate key value violates unique constraint "uq_user_email"
```

`sp_school_manage` checked `is_active = TRUE` (so it never saw the deactivated row and allowed
the save), while `uq_user_email (tenant_id, email)` covered **every** row including deactivated
and soft-deleted ones. The guard and the constraint disagreed — guard passed, INSERT exploded.

**The invariant the app actually relies on.** Both `sp_login_management` and `sp_password_reset`
resolve a user by email with **no tenant filter**:

```sql
WHERE LOWER(u.email) = LOWER(p_email) AND u.is_deleted = FALSE AND u.is_active = TRUE
```

So: *an email identifies at most one active, non-deleted user — globally.* `uq_user_email` was
both **too weak** (two tenants could hold the same live email, making login ambiguous — it picked
one via `ORDER BY role_code`) and **too strong** (a deactivated user burned that email for its
tenant forever).

`Database/user_email_unique.sql`:
- drops `uq_user_email`,
- adds `uq_user_email_active` — `UNIQUE (LOWER(TRIM(email))) WHERE is_active AND NOT is_deleted`,
  case- and whitespace-insensitive, matching the login predicate exactly,
- adds **`core.fn_user_email_taken(email, exclude_user_id)`** — the one guard, so the app-side
  check can never drift from the index again.

All three procs that create a login now call it, replacing three *different* inline rules:

| Proc | Old check | Was wrong because |
|---|---|---|
| `sp_school_manage` | global, `is_active` only | missed `is_deleted` → raw constraint error |
| `sp_staff_manage` | global, `is_active` only | same |
| `sp_school_user_management` | **tenant + school scoped**, `is_deleted` only | an email live in another tenant passed, then hit the index |

> Verified before running: 0 duplicate emails among active users, 0 deactivated/soft-deleted users,
> 0 emails differing only by case. Nothing used `ON CONFLICT (tenant_id, email)`.
> After: deactivated user's email is reusable; a cross-tenant duplicate is refused with
> *"This email is already registered to another user."*; different casing is still caught;
> editing an admin and keeping their own email does not complain; and a direct duplicate INSERT
> is still blocked by the index as a safety net.

### Live availability in the wizard

`GET /SuperAdmin/Schools/CheckEmail?email=…&userId=…` → `{ ok, message }`. The wizard calls it on
**blur** of Admin Email and shows *Available* / the reason inline, so a clash surfaces at step 3
instead of after filling all four steps and pressing Save. `validateStep` also refuses to advance
while the address is known-taken.

- Goes through `ISchoolService.IsEmailTakenAsync` → `core.sp_user_email_check` → the **same**
  `fn_user_email_taken`, so the hint and the save can never disagree.
- Convenience only: a failed lookup never blocks the user — the proc and the index still enforce.
- `userId` excludes the admin being edited (the wizard passes `Model.AdminUserId`, `0` on Create),
  so re-saving an admin with their own address doesn't flag.
- An "does this email exist?" endpoint is an **enumeration vector**, so it sits behind the
  controller's `[Authorize(Roles = SuperAdmin)]` — anonymous callers get a 302 to login.

---

## 6a. Board — which State Board?

"State Board" was a single row in `config.boards`, so a school could say it follows a state board
but never **which state's**. MSBSHSE, UP Board and RBSE differ in syllabus, exam pattern, result
format and TC rules — nothing board-specific was possible while that was missing.

`Database/board_state.sql` keeps `config.boards` as board **types** (a short dropdown) and adds
**`core.school_profiles.board_state_id`** → `config.states` (the master `geo_master.sql` seeded).
The alternative — 36 per-state board rows — meant a 43-item dropdown and a second copy of the
state list in the database.

- **Which boards need a state is data**: `config.boards.requires_state`. Currently `State Board`
  and `Madrasah Board`. Flag a new board in SQL and the wizard follows — **never** hardcode
  `board_id = 3`, and branch on `board_code` (added here), not `name`.
- The wizard reveals the **State Board** picker only for flagged boards, and clears it on switch
  away. The proc does the same (`CASE WHEN ... requires_state THEN p_board_state_id ELSE NULL`),
  so State Board → CBSE can never leave a stale state behind.
- Validated in **three** places: client JS, `ValidateBoardStateAsync` in the controller (turns a
  proc `RAISE` into a field-level error), and the proc itself.
- **`sp_school_list` renders `State Board (Uttar Pradesh)`** — the plain label is useless on a
  list spanning states. The review step matches.
- **Backfill**: existing State Board schools took their board state from their own address state,
  which is right in the overwhelming majority of cases and far better than NULL.

### Cambridge duplicate — merged

`Database/board_cambridge_merge.sql` folded `Cambridge (IGCSE)` (10) into `Cambridge` (5) and
renamed the survivor **"Cambridge International (CAIE / IGCSE)"**.

They were never two boards: the board is Cambridge Assessment International Education, and IGCSE
is one qualification level inside it (Cambridge Upper Secondary), alongside Primary, Lower
Secondary and AS/A Level. Two rows split the same schools into two buckets and made the board
filter on the school list undercount. IGCSE stays in the name so the merge doesn't read as
"IGCSE support was removed".

- Rows are resolved by **`board_code`**, not id — ids differ per environment.
- **Soft delete**, not `DELETE`: the retired row still resolves for any historical join, while
  every board join in the app filters `is_deleted = FALSE`, so it vanishes from dropdowns and
  filters at once.
- **Idempotent** — a second run reports "already merged" and updates 0 rows.
- The migration also **renumbers `display_order` to a gap-free 1..n** (retiring IGCSE left
  1,2,3,4,5,7,8). It renumbers by *current* order, so it preserves the sequence rather than
  imposing one, is partitioned by tenant, and is self-healing — safe to re-run after any future
  board is added or retired.
- Checked before running: 0 schools on either row, no FK constraints on `config.boards`,
  `core.school_profiles.board_id` is the only referencing column, and `core.students.prev_board`
  is free text and empty. Active boards: **8 → 7**.

---

## 6b. Address geography (app-wide, not just this module)

State and City used to be free-text boxes here, which is how `core.school_addresses` ended up
holding `UP`, `uttarpradesh`, `Uttar Pradesh`, `delhi`, `Haryanafff` and `TEST` — breaking the
state filter on the list screen and any state-wise report.

They now bind to a **platform geography master** — `config.countries` / `config.states` /
`config.districts`, seeded by **`Database/geo_master.sql`** (16 countries, 36 states + UTs,
769 districts).

- **Not tenant-scoped, on purpose.** "Maharashtra" is identical for every tenant, so these tables
  have no `tenant_id` and `GeoService` caches on **global** keys — the one deliberate exception to
  the tenant-scoped-cache-key rule in `CLAUDE.md`. Don't "fix" it.
- **District, not city.** ~800 districts stay maintainable; ~4,000 towns don't. City remains free
  text with the district list as typeahead suggestions, so an unlisted town can still be entered.
- **Reuse anywhere** (student / staff / enquiry / transport addresses):
  ```cshtml
  @await Html.PartialAsync("_StateDistrictCity", new GeoPickerModel { StateId = ..., City = ... })
  <script src="~/js/geo-cascade.js"></script>   @* once per page *@
  ```
  Field names, which levels to show, and `InstanceId` (for two pickers on one page) are all
  options on `GeoPickerModel`. Cascading options come from `GeoController` (`/Geo/States`,
  `/Geo/Districts`) via `IGeoService` → `config.sp_geo_lookup`.
- **Adoption is additive.** `school_addresses` keeps its `city`/`state` varchar columns (every
  existing proc, filter and report reads them) and gained nullable `country_id`/`state_id`/
  `district_id`. A save writes **both**. Rows whose old text mapped cleanly were backfilled;
  the rest kept their text and show a "please re-select the state" hint on Edit.
  Find them with: `SELECT school_address_id, state, city FROM core.school_addresses WHERE state_id IS NULL;`

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
