# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

EduCore is a multi-tenant **School ERP** built as an **ASP.NET Core 9 MVC** app. Two projects, one solution (`educore/educore.sln`):

- **`educore/`** — the web app (Controllers, Areas, Views, `Program.cs`, config).
- **`EduCoreDataAccessLayer/`** — the data/service layer (services, models, infrastructure, SQL scripts). Referenced by the web project.

There is **no ORM**. All persistence is **PostgreSQL stored procedures** invoked through a thin async data layer.

## Commands

```bash
# Build (run from repo root or educore/)
dotnet build educore/educore.csproj

# Run locally (Development env loads the local connection string — see below)
dotnet run --project educore/educore.csproj          # uses Properties/launchSettings.json (port 5055)

# Publish (as the Dockerfile does)
dotnet publish educore/educore.csproj -c Release -o out
```

There is **no test project** in this repo — do not invent test commands.

### Build/run gotchas (these have actually bitten us)
- **Locked DLLs:** if the app is running under Visual Studio, `bin\Debug\net9.0\*.dll` is locked and an in-place build fails with **MSB3027/MSB3021 (copy errors, not compile errors)**. To check compilation without stopping the app, build to a temp dir: `dotnet build educore/educore.csproj -p:OutDir="$env:TEMP\ec_build_check\"`. New binaries require an app restart.
- **`OutOfMemoryException` / `MSB3883` during build** = the machine is out of memory (this is an 8 GB dev box; VS + app + Postgres is tight), **not** a code error. Fix: `dotnet build-server shutdown`, close memory hogs, retry. The same memory pressure makes PostgreSQL fail to start (`error 1455` / "out of memory").

### Local prerequisites
- **PostgreSQL 16** must be running. Windows service: **`postgresql-x64-16`** (start elevated: `Start-Service postgresql-x64-16`). `psql` is not on PATH: `C:\Program Files\PostgreSQL\16\bin\psql.exe` (use `$env:PGPASSWORD='root'`).
- **Connection string is NOT in `appsettings.json`** (that file is committed and must stay secret-free). Local dev reads it from **`appsettings.Development.json`** (git-ignored). Production reads the env var **`ConnectionStrings__DefaultConnection`**.
- **Test data lives on `tenant_id = 2`**: students/enquiries are on `school_id = 1` (a row needs `is_active = TRUE` to show in the CRM); the configured `school_settings` row is `school_id = 7`.

## Architecture (the big picture)

### Request → service → stored proc
Controllers (in `educore/Controllers` and per-area `educore/Areas/{Admin,SuperAdmin,ERP}/Controllers`) depend on **service interfaces** and never touch the database directly. Each service:

1. Builds an `NpgsqlParameter[]` (named `p_*` params + one or more `Refcursor` OUT params).
2. Calls **`PgExec`** (`EduCoreDataAccessLayer/Infrastructure/PgExec.cs`) to execute the proc inside a transaction and `FETCH` each refcursor.
3. Maps result rows into models.

**`PgExec` is the only data-access primitive.** It is fully async (`ExecuteReaderAsync`/`ReadAsync` — no `DataAdapter.Fill`) and runs off a **singleton `NpgsqlDataSource`** registered in `Program.cs`. It exposes two shapes:
- `ExecuteCursorsAsync(proc, params, mapper0, mapper1, …)` — streams each refcursor's rows straight into the caller's `List<T>` via an `NpgsqlDataReader`. Used by the performance-critical path (`FeePaymentService`).
- `ExecuteProcedureWithCursorsAsync(proc, params) : DataSet` — async drop-in that returns a `DataSet` so a service can keep classic `DataRow` mapping. Used by most services.
- `ExecuteNonQueryProcedureAsync(proc, params)` — for procs that return no cursor.

When reading from a reader, use the helpers in **`Helpers/DbRead.cs`** (`DbRead.Int/Dec/Str/NStr/Bool/Date`, plus `reader.Columns()`), which tolerate missing/NULL columns.

### Services: Contract + Repository
Interfaces live in `EduCoreDataAccessLayer/Services/Contract/**`, implementations in `Services/Repository/**` (`Admin/`, `SuperAdmin/`). All are registered **`Scoped`** in `Program.cs`; `PgExec`, `NpgsqlDataSource`, and `AppCache` are **`Singleton`**.

### Multi-tenancy (non-negotiable convention)
Every data method takes `int tenantId, int schoolId, int actionUserId`, sourced from the authenticated user's **claims** (`Common.SK_TenantId` = `_tenantid`, `Common.SK_SchoolId` = `_schoolid`, etc. in `Helpers/Common.cs`). Services **guard `tenantId > 1 && schoolId > 0`** before any DB call (tenant 1 = SUPER_ADMIN / platform; real schools are tenant > 1). Stored procs enforce the same scope. When adding a method, **always thread these three ids through** and pass them to the proc.

### Auth, session, security (in `Program.cs`)
- Cookie auth (`EduCore.Auth`) + authorization policies (`SuperAdminOnly`, `SchoolAdminOnly`, `SchoolUserOnly`) keyed on role + tenant/school claims. Login flow + multi-role selection is in `Controllers/AccountController.cs` (BCrypt password verify).
- **`Security:RequireHttps`** config flag (default `false`): when `true`, cookies become `Secure`-only and HTTPS redirection + HSTS turn on. Leave `false` for plain-HTTP hosting or logins break. Flip on only with a real TLS cert.
- Login POST is rate-limited (`[EnableRateLimiting("login")]`, 5 attempts / 5 min per IP).

### Caching (`Infrastructure/AppCache.cs`)
In-memory cache for read-mostly reference data (currently fee heads and basic-profile dropdowns in `SchoolSettingsService`). **Cache keys are always tenant/school-scoped** (`AppCache.Key(name, tenantId, schoolId)`) to prevent cross-tenant leakage, and writes **must call `_cache.Remove(...)`** to invalidate (see the fee-head Save/Delete/Toggle and academic-year mutations for the pattern).

### Error logging convention
Services that catch DB errors inject `ILogger<T>` and log **before** returning a friendly message: a `PostgresException` (usually a proc `RAISE` business rule) is logged at **Warning** with its `SqlState`; an unexpected `Exception` is logged at **Error**. Services that don't catch let exceptions propagate to the framework's handler.

### Database scripts
Feature SQL (procs, migrations) lives in **`EduCoreDataAccessLayer/Database/*.sql`**, named per feature (e.g. `fee_collection_full_flow.sql`, `enquiry_registration.sql`). When changing a proc's signature or result columns, update the matching script and the consuming service together.

## Conventions for changes here
- **Keep it simple.** Prefer the smallest change that fits the existing pattern; match the surrounding service's style rather than introducing new abstractions.
- New data access goes through `PgExec` — never reintroduce a per-call connection or `DataAdapter`.
- Background and rationale for the data-layer/perf/security work is documented in **`docs/SCALING-AND-FIXES.md`** (read it before large refactors).
