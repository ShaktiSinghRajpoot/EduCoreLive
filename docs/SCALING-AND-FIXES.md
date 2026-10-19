# EduCore — Scaling, Architecture & Fixes (Learning Guide)

> **Purpose of this file**
> This is a *learning document* and a *change log* in one.
>
> - **Part 1** explains the concepts from scratch (Redis, horizontal scaling, connection
>   pooling, async, caching) — no prior knowledge assumed.
> - **Part 2** explains each of the 7 prioritized fixes: **what** it is, **why** it
>   matters, and **how** it applies to *our* EduCore code.
> - **Part 3** is the running **Change Log**. Every code change we make gets an entry
>   here: *what changed* and *why*. Code changes also get short `// WHY:` comments so
>   the reasoning lives next to the code too.
>
> Read Part 1 once to build the mental model. Come back to Part 2/3 as we implement.

---

# Part 1 — Concepts From Scratch

## 1.1 What does "1000 concurrent users" actually mean?

"Concurrent users" does **not** mean 1000 database queries at the exact same millisecond.
It means ~1000 people have the app open and are clicking around. At any given instant only
a fraction are actually waiting on the server (say 50–200 "in-flight" requests). The job of
a scalable system is to make sure that when those in-flight requests spike, the server
**queues gracefully** instead of **falling over**.

A system "falls over" when one shared, limited resource runs out. The usual suspects:

1. **Threads** (the app runs out of workers to handle requests)
2. **Database connections** (the app runs out of open pipes to the DB)
3. **Memory** (the app buffers too much data per request)
4. **A single machine's CPU** (only fixable by adding more machines)

Most of our fixes are about not running out of #1, #2, and #3, and making it *possible*
to add more machines for #4.

---

## 1.2 Vertical scaling vs. Horizontal scaling

**Vertical scaling** = make the one server bigger (more CPU/RAM). Easy, but there's a
ceiling, it's expensive, and if that one machine dies, the whole app is down.

**Horizontal scaling** = run **many copies** of the app behind a **load balancer**, and
add/remove copies as traffic changes. This is how real production systems handle thousands
of users and survive a machine dying.

```
                     ┌─────────────┐
   users  ───────►   │ Load        │
                     │ Balancer    │
                     └──────┬──────┘
            ┌───────────────┼───────────────┐
            ▼               ▼               ▼
      ┌──────────┐    ┌──────────┐    ┌──────────┐
      │ EduCore  │    │ EduCore  │    │ EduCore  │   ← 3 identical copies
      │ instance │    │ instance │    │ instance │     ("instances")
      │    #1    │    │    #2    │    │    #3    │
      └────┬─────┘    └────┬─────┘    └────┬─────┘
           └───────────────┼───────────────┘
                           ▼
                   ┌───────────────┐
                   │  PostgreSQL   │   ← still ONE shared database
                   └───────────────┘
```

A **load balancer** is a traffic cop: it spreads incoming requests across the instances.
The key consequence: **request #1 from a user might hit instance #1, and their very next
request might hit instance #2.** The instances must therefore be **interchangeable**.

### Stateless vs. Stateful — the make-or-break idea

- A **stateless** instance keeps *nothing important in its own memory* between requests.
  Everything it needs is either in the request, in the database, or in a shared store.
  Any instance can serve any request. ✅ Horizontally scalable.

- A **stateful** instance remembers things in its *local* memory (e.g. "user 42 is logged
  in and chose the Accountant role"). If the next request lands on a different instance,
  that instance has never heard of user 42's choice. ❌ Breaks when scaled out.

**This single idea is why fixes #1 (Redis session) and the DataProtection part matter.**
Today EduCore is stateful (in-memory session), so it can only run as **one** instance.

> **"Sticky sessions"** is a band-aid where the load balancer always sends a given user
> back to the same instance. It works, but it unbalances load and loses the user's state
> if that instance restarts. The proper fix is to move shared state *out* of the instance.

---

## 1.3 What is "session" and why ours blocks scaling

**Session** = a per-user scratchpad on the server that survives across their requests,
keyed by a cookie in their browser. We use it in `AccountController`:

```csharp
HttpContext.Session.SetInt32("PendingUserId", user.UserId);   // login role-choice flow
HttpContext.Session.SetString("RoleCode", user.RoleCode);     // SaveUserDataToSession
```

By default ASP.NET Core stores session **in the instance's own RAM**
(`AddSession()` uses an in-memory store). That is *local* state → stateful → not scalable
(see 1.2). Move the session store to a **shared** place that every instance can read, and
the instances become interchangeable again. That shared place is typically **Redis**.

---

## 1.4 What is Redis?

**Redis** is a separate, very fast, in-memory **key-value store** that runs as its own
service (like PostgreSQL is a separate service). Think of it as a shared dictionary that
*all* your app instances can read and write over the network.

Common uses (we'll use the first two):

1. **Distributed session store** — instead of each instance keeping session in its own RAM,
   they all keep it in Redis. Now any instance can serve any user. (Fixes #1)
2. **Distributed cache** — store the results of expensive/rarely-changing DB lookups
   (dropdowns, school settings, fee heads) so you don't hit Postgres every request. (Fixes #6)
3. **Shared DataProtection key ring** — see next section.

Mental model:

```
   instance #1 ─┐
   instance #2 ─┼──►  ┌─────────┐   "session:abc → {UserId:42, Role:Accountant}"
   instance #3 ─┘     │  REDIS  │   "cache:dropdown:classes:tenant7 → [...]"
                      └─────────┘
```

> You don't need to *know* Redis internals to use it. From C# you call the standard
> `IDistributedCache` / `ISession` interfaces; the Redis package just plugs in behind them.
> Locally you can run Redis in Docker with one command, or skip it entirely (see the
> "fallback" approach in fix #1) until you actually deploy multiple instances.

---

## 1.5 What are "DataProtection keys" and why they matter when scaling

When a user logs in, ASP.NET Core gives them an **auth cookie**. That cookie is
**encrypted** so the user can't tamper with it. The encryption uses a set of keys called
the **DataProtection key ring**.

By default each instance generates and stores these keys **locally** (on disk or, in a
container, in ephemeral memory). Problem when you have multiple instances:

- Instance #1 encrypts the cookie with *its* key.
- The load balancer sends the next request to instance #2.
- Instance #2 has *different* keys → it can't decrypt the cookie → it thinks the user is
  logged out → **random logouts**.

Fix: store the DataProtection key ring in a **shared** location (Redis, or a shared folder,
or a database table) so all instances use the same keys. This is the silent partner of the
session fix — both are needed before you can run more than one instance.

---

## 1.6 Connection pooling and why PgBouncer

Opening a brand-new connection to PostgreSQL is **expensive** (TCP handshake,
authentication, etc. — tens of milliseconds). So drivers keep a **pool**: a set of already-
open connections that get *borrowed* for a query and *returned* (not closed) afterward.

Our driver, **Npgsql**, pools automatically, keyed by the connection string. When our code
does `new PostgreSqlDal(_connectionString)` and opens a connection, it's really *borrowing*
from the pool.

Two limits matter:

- **Npgsql `MaxPoolSize`** — default **100**. The app will not keep more than 100
  connections open *per connection string*. Request #101 must **wait** for one to be
  returned; if it waits too long it throws a *pool exhausted / timeout* error.
- **PostgreSQL `max_connections`** — default ~**100**. The *database server itself* refuses
  more than this many connections, total, from everyone.

So you **cannot** fix pool exhaustion by just setting `MaxPoolSize=1000` — Postgres would
reject them. This is where **PgBouncer** comes in.

**PgBouncer** is a lightweight proxy that sits *between* your app and Postgres. Your many
app instances open thousands of *cheap* connections to PgBouncer, and PgBouncer multiplexes
them onto a *small* number of real Postgres connections (say 20–50), handing a real
connection to whichever query needs one *only for the moment it runs* ("transaction
pooling").

```
  instance #1 ─┐
  instance #2 ─┼─► PgBouncer ─► (only ~25 real connections) ─► PostgreSQL
  instance #3 ─┘   (accepts
                    thousands)
```

PgBouncer is **infrastructure**, not app code — you install/configure it on the server or
as a container. The only *code* part on our side is pointing the connection string at
PgBouncer and tuning `MaxPoolSize`. (That's why fix #3 is mostly a deployment note.)

---

## 1.7 Async/await and "thread pool starvation"

A web server has a limited pool of **worker threads** that handle requests. When a request
calls the database, that work is mostly *waiting* for the DB to respond — the CPU has
nothing to do during that wait.

- **Blocking (synchronous) DB call:** the worker thread *sits and waits*, doing nothing,
  until the DB returns. That thread can't serve anyone else meanwhile.
- **Async DB call (`await ...Async()`):** the worker thread is *released back to the pool*
  while waiting, free to serve other requests; when the DB responds, a thread picks the
  work back up.

If many requests block at once, the pool runs out of free threads = **thread pool
starvation**. New requests queue, latency spikes, throughput collapses — even though the
CPU is mostly idle (it's all just *waiting*).

**Our problem:** the methods *look* async, but inside `PostgreSqlDal` we call
`NpgsqlDataAdapter.Fill(table)`, which is **synchronous** — it blocks the thread for the
entire fetch. So under load we get the starvation we were trying to avoid. Fix #2 replaces
that with a truly async `ExecuteReaderAsync` / `ReadAsync` loop.

> **Bonus from fix #2 — memory.** `DataSet`/`DataTable` buffer the *entire* result set in a
> heavyweight structure, then we copy it again into our `List<T>`. A `DataReader` streams
> one row at a time straight into our `List<T>` — one copy instead of two, far less memory
> and allocation under load. This is the "fixes memory" part.

---

## 1.8 Caching

**Caching** = remember the answer to an expensive question so you don't ask again.

Some data barely changes (the list of classes, sections, fee heads, school settings) but we
re-fetch it from Postgres on *every* page load. Caching it for, say, 5–10 minutes means
thousands of requests get served from fast memory instead of hammering the database.

Two kinds:

- **In-memory cache (`IMemoryCache`)** — per-instance RAM. Simplest, but each instance has
  its own copy (fine for read-mostly reference data).
- **Distributed cache (Redis)** — shared across instances. Needed when the cached data must
  be consistent everywhere or invalidated centrally.

**Cache invalidation** is the hard part: when the underlying data *does* change (admin edits
a fee head), the cache must be cleared or it serves stale data. Strategy: short expiry +
explicit "bust this key" when an admin saves. **Always scope cache keys by tenant/school**
(e.g. `dropdown:classes:tenant=7:school=12`) so one school never sees another's data.

---

# Part 2 — The 7 Fixes (What / Why / How-for-EduCore)

> Difficulty & risk are rough guides. "Pure code" = I can do and verify locally.
> "Infra" = needs a server/service decision from you.

> ### 🎯 Current scope decision (target: ~100 concurrent users, ONE instance)
>
> We are **not** doing horizontal scaling right now. The app will run as a **single
> instance** for ~100 simultaneous users. That changes the priorities:
>
> - **#1 Redis — DEFERRED.** In-memory session is fine for one instance. (Revisit only if/when
>   we run multiple copies behind a load balancer.) *One cheap exception:* if we deploy in a
>   container, persist DataProtection keys to a **folder/volume** (not Redis) so container
>   restarts don't log everyone out — see note under #1.
> - **#3 PgBouncer — DEFERRED.** One instance with the default ~100 pool roughly matches
>   Postgres's default `max_connections`, so 100 users won't exhaust it **as long as
>   connections are released quickly — which Fix #2 ensures.** Just a one-line config note,
>   no PgBouncer to install.
> - **#2 STILL APPLIES even single-instance.** At 100 users the real risk isn't the connection
>   pool — it's **thread-pool starvation** from the synchronous `DataAdapter.Fill` (see 1.7).
>   A single box with an idle CPU can still stall because all worker threads are blocked
>   waiting on the DB. This is the top performance fix in scope.
>
> **Working order for this scope:** **#4 → #5 → #2 + #7 → #6.**  (#1 and #3 shelved.)

### Fix #1 — Move Session + DataProtection keys to Redis
- **What:** Store session and the cookie-encryption key ring in Redis instead of local RAM.
- **Why:** They are *local state*. Local state makes instances non-interchangeable, so the
  app can only run as one copy. This is the #1 blocker to horizontal scaling (see 1.2–1.5).
- **EduCore today:** `Program.cs` → `AddSession()` (in-memory) and no DataProtection config.
  `AccountController` relies on session for the multi-role login flow.
- **Plan:** Add Redis-backed `IDistributedCache` + session + `PersistKeysToStackExchangeRedis`,
  **with a fallback**: if no Redis connection string is configured, fall back to in-memory so
  local dev keeps working with zero setup. Type: *mostly pure code*, needs a Redis instance
  only when you actually deploy multiple copies.

### Fix #2 — Make the DAL fully async (drop DataSet/DataAdapter)
- **What:** Rewrite `PostgreSqlDal` to use `ExecuteReaderAsync` + `await reader.ReadAsync()`
  and map rows directly into our `List<T>` models; remove `NpgsqlDataAdapter.Fill`/`DataSet`.
- **Why:** The current sync `Fill` blocks worker threads (thread starvation, 1.7) and double-
  buffers result sets in memory. This is the biggest *performance* and *throughput* win.
- **EduCore today:** Every service calls `dal.ExecuteProcedureWithCursorsAsync(...)` and reads
  `ds.Tables[...]`. Changing the return shape touches **every** service's mapping code.
- **Plan:** Biggest, highest-risk change → do **one pilot service first** (e.g.
  `FeePaymentService`), verify, then roll the pattern out. Type: *pure code*.

### Fix #3 — PgBouncer + tune MaxPoolSize
- **What:** Put PgBouncer between app and Postgres; set a sane `MaxPoolSize` in the conn string.
- **Why:** Default pool (100) and Postgres `max_connections` (~100) get exhausted under load
  (see 1.6). PgBouncer lets thousands of app connections share a few real DB connections.
- **EduCore today:** Direct `Host=localhost;...` connection string, no pool tuning.
- **Plan:** I provide the connection-string change + a short deployment note (how to run
  PgBouncer as a container and what `transaction` pooling mode means). Type: *infra + tiny code*.

### Fix #4 — Add ILogger to every service; log before swallowing
- **What:** Inject `ILogger<T>` into each service; log the real exception before returning a
  friendly message — especially in the fee/refund paths.
- **Why:** Today `catch { return (false, "Unable to..."); }` throws away the only evidence of
  *why* a financial operation failed. Unacceptable for money flows; also needed for ops.
- **EduCore today:** No logger injected anywhere; bare `catch {}` blocks.
- **Plan:** Low-risk, high-value. Add logging without changing behavior/return shapes.
  Type: *pure code*.

### Fix #5 — Secrets, HTTPS, Secure cookies, login rate-limiting
- **What:** (a) Move connection string + encryption key out of `appsettings.json` into
  user-secrets/env vars. (b) **You** rotate the leaked Railway password. (c) Force HTTPS and
  set cookies `Secure`. (d) Add login rate-limiting / lockout.
- **Why:** Secrets in source = anyone with the repo has the DB. Cookies over HTTP = sniffable
  auth. No throttle = brute-force login.
- **EduCore today:** Live-looking conn string in `appsettings.json`; hardcoded
  `Common.EncryptionKey`; `CookieSecurePolicy.SameAsRequest`; HTTPS redirect disabled; no
  rate limit on `AccountController.Login`.
- **Plan:** Mixed. Code/config parts I can do; **password rotation is yours** (Railway
  dashboard). Type: *pure code + one action by you*.

### Fix #6 — Cache dropdowns / settings / fee-heads
- **What:** Cache rarely-changing reference lookups (with tenant/school-scoped keys + short
  expiry + bust-on-save).
- **Why:** These are fetched every request but almost never change → wasted DB load (1.8).
- **EduCore today:** `BaseService.GetSelectListAsync` and settings/fee-head reads hit Postgres
  every time.
- **Plan:** Start with `IMemoryCache` (per-instance, zero infra). Move to Redis later if
  needed. Type: *pure code*.

### Fix #7 — Singleton NpgsqlDataSource; stop reading IConfiguration per constructor
- **What:** Register one `NpgsqlDataSource` (the modern Npgsql object) as a singleton; inject
  it instead of re-reading the connection string in every service constructor.
- **Why:** Cleaner pooling, prepared-statement caching, one place to tune; removes repeated
  config reads. Pairs naturally with fix #2.
- **EduCore today:** Every service does `configuration.GetConnectionString("DefaultConnection")`.
- **Plan:** Do alongside #2. Type: *pure code*.

---

## Suggested order (lowest risk → highest)

1. **#4 ILogger** — safe, immediately useful, no behavior change.
2. **#5 config/security** — secrets, HTTPS, cookies, rate-limit (you rotate the password).
3. **#7 + #2 on ONE pilot service** — introduce `NpgsqlDataSource` + async reader on
   `FeePaymentService`, review together, then roll out to the rest.
4. **#6 caching** — once the read path is settled.
5. **#1 Redis** — when you're ready to actually run multiple instances.
6. **#3 PgBouncer** — deployment step, at the same stage as #1.

---

# Part 3 — Change Log (what & why, per change)

> Every code change goes here. Format:
> **[date] Fix #N — file(s)** — *What* changed and *Why*. Plus any `// WHY:` comments left
> in the code itself.

### [2026-06-23] Fix #4 — ILogger added to services that swallow exceptions

**Files changed**
- `Services/Repository/Admin/FeePaymentService.cs`
- `Services/Repository/Admin/EnquiryService.cs`
- `Services/Repository/Admin/RegistrationService.cs`
- `Services/Repository/Admin/TransportService.cs`
- (`AdmissionWorkflowService.cs` already logged correctly — left as-is.)

**What changed**
- Injected `ILogger<T>` into each service's constructor (ASP.NET Core's DI provides it
  automatically — no registration needed; `builder.Logging.AddConsole()` was already in
  `Program.cs`).
- Every `catch` block that previously swallowed an exception into a friendly string now
  **logs the real exception first**, with context (ids, school, SqlState).

**Why**
- Before this, a failed payment / refund / day-close / registration returned a generic
  message like `"Unable to record the payment."` and **threw away the actual exception** —
  zero diagnostic trace for a *financial* module. Unacceptable for money flows and ops.

**Two log levels, on purpose** (this is the part to learn):
- **`LogWarning` for `PostgresException`** — a proc `RAISE EXCEPTION` is usually an
  *expected business rule* (e.g. "already admitted", "duplicate receipt"). We log it at
  Warning with the `SqlState` so it's visible but not alarming, then surface its message
  to the user.
- **`LogError` for the generic `catch (Exception ex)`** — a truly *unexpected* failure
  (bug, DB down, bad data). Logged at Error with the full exception/stack.
  > Note: the bare `catch { }` blocks were changed to `catch (Exception ex)` so we have the
  > exception object to log.

**Scope note — why not *every* service?**
Only the 5 services above actually *caught and swallowed* exceptions. `LoginService`,
`AdmissionService`, `SchoolSettingsService`, `SchoolService`, `RolePermissionService` let
exceptions **propagate** — which is fine, and arguably better than swallowing. The right
place to catch *those* is one **global exception handler/logger** (so nothing is lost and
we don't sprinkle dead `try/catch` everywhere). That global handler is part of **Fix #5**
and is the cleaner home for "log everything uncaught." Adding an unused `ILogger` to
services that never log would just create dead fields/warnings.

**Verified:** `dotnet build` → 0 errors (pre-existing warnings unchanged).

---

### [2026-06-23] Fix #5 — Secrets out of source, login rate-limiting, config-driven HTTPS

**Files changed**
- `educore/appsettings.json` — removed DB credentials; added `Security:RequireHttps` flag.
- `educore/appsettings.Development.json` — local dev connection string (this file is git-ignored).
- `educore/Program.cs` — rate limiter, config-driven cookies/HTTPS/HSTS.
- `educore/Controllers/AccountController.cs` — `[EnableRateLimiting("login")]` on login POST.

**What & why, item by item**

1. **DB credentials removed from `appsettings.json`** (which IS committed to git).
   - *Why:* anyone with the repo (or its history) had the database. The committed file now
     contains **no** credentials — just a comment explaining where they go.
   - *Local dev:* connection string lives in `appsettings.Development.json` (git-ignored).
   - *Production:* set env var `ConnectionStrings__DefaultConnection` (the `__` maps to the
     `ConnectionStrings:DefaultConnection` config key). No code change needed — ASP.NET reads
     env vars automatically.
   - ⚠️ **YOUR ACTION:** the old Railway password was in git history → treat it as
     compromised and **rotate it in the Railway dashboard**. Removing it from the file does
     not remove it from past commits.

2. **Login rate-limiting** (`AddRateLimiter` + `[EnableRateLimiting("login")]`).
   - *Why:* the login endpoint verified passwords with no throttle → open to brute-force.
   - *How:* .NET 9 built-in rate limiter (no NuGet package). A **fixed-window** limiter,
     **partitioned by client IP**: 5 attempts per 5 minutes per IP; excess → HTTP 429, which
     the existing `UseStatusCodePagesWithReExecute("/Account/Error")` turns into a friendly page.
   - *Learn:* "partition by IP" means each IP gets its own independent counter, so blocking
     one attacker doesn't lock out everyone. `UseRateLimiter()` is placed **after**
     `UseRouting()` so per-endpoint policies resolve.

3. **Config-driven HTTPS / Secure cookies** (`Security:RequireHttps`, default **false**).
   - *Why this is a switch, not a hard "on":* you host over **plain HTTP** today. `Secure`
     cookies are silently dropped over HTTP, so forcing them would make login impossible.
     One flag controls all HTTPS hardening together so they can't get out of sync:
     - `false` (today): cookies `SameAsRequest`, no HTTPS redirect, no HSTS → HTTP works.
     - `true` (once you have a TLS cert / HTTPS reverse proxy): auth + session cookies become
       `Secure`-only, `UseHttpsRedirection()` and `UseHsts()` turn on.
   - *To turn it on later:* set `"Security": { "RequireHttps": true }` (or env
     `Security__RequireHttps=true`). **Do not** flip it until HTTPS actually works.

**What we deliberately did NOT do**
- **Encryption key (`Common.EncryptionKey`) — left as-is.** `Utility.Encrypt/Decrypt` and the
  key are **dead code** (no callers anywhere in the app). Moving an unused secret to a vault is
  busywork. Recommendation: either **delete** `Encrypt`/`Decrypt`/`EncryptionKey`, or, *when you
  start using them*, read the key from config and use a per-value random salt/IV (the build
  already warns `SYSLIB0041` about the outdated `Rfc2898DeriveBytes` here).
- **Global exception handler — not added; already covered.** ASP.NET's `UseExceptionHandler`
  logs unhandled exceptions at Error level for free, and Fix #4 made the swallowing services
  log too. Adding more would just double-log.

**Verified:** `dotnet build` → 0 errors. Local dev still reads the connection string from
`appsettings.Development.json`. Runtime smoke test: app boots, login page returns 200, and
the 6th rapid login POST from one IP returns **429** (rate limiter confirmed working).

---

### [2026-06-23] Fix #2 + #7 — async reader-based DAL, PILOT on FeePaymentService

**New files**
- `Infrastructure/PgExec.cs` — fully-async, reader-based executor (replaces DataSet/DataAdapter).
- `Helpers/DbRead.cs` — null/missing-safe column readers for `NpgsqlDataReader`.

**Files changed**
- `Services/Repository/Admin/FeePaymentService.cs` — rewritten to use `PgExec` + `DbRead`
  (all 14 methods). Same logic, same validation, same Fix #4 logging — only the data access
  mechanism changed.
- `educore/Program.cs` — registered a **singleton `NpgsqlDataSource`** (Fix #7) and the
  **singleton `PgExec`** (Fix #2).

**What changed & why**

1. **`NpgsqlDataAdapter.Fill` (sync) → `ExecuteReaderAsync` + `ReadAsync` (async).**
   - *Why:* `Fill` blocks a worker thread for the entire DB fetch → thread-pool starvation
     under load (the real risk at ~100 concurrent users on one box — see Part 1, §1.7). The
     reader path releases the thread while waiting on the DB.

2. **`DataSet`/`DataTable` removed → rows stream into `List<T>`.**
   - *Why:* DataSet buffered every result set, then we copied it again into our models — two
     copies. Now it's one. Lower memory and allocations per request.

3. **`new PostgreSqlDal(connectionString)` per call → injected singleton `NpgsqlDataSource`.**
   - *Why (Fix #7):* one object owns the pool + prepared-statement cache; one place to tune
     pooling (the Fix #3 note: append `;Maximum Pool Size=NN` to the connection string here).
     Services no longer read `IConfiguration` to build a connection string.

**How the new pattern reads (the part to learn)**
`PgExec.ExecuteCursorsAsync(proc, params, mapper0, mapper1, ...)` calls the proc, then for
each refcursor parameter (in order) hands an open async reader to the matching mapper. A
mapper builds its column set **once** (`reader.Columns()`), then loops `while (await
reader.ReadAsync())` mapping each row with `DbRead.*` helpers (which fall back safely if a
column is missing or NULL — same behaviour the old DataRow code had). Single-row results just
do one `if (await reader.ReadAsync())`. Cursors and their FETCH stay inside one transaction,
because Postgres refcursors are only valid within the transaction that opened them.

**Migration safety**
- The old `PostgreSqlDal` is **untouched and still registered-by-use** — the other services
  still `new PostgreSqlDal(_connectionString)` and keep working unchanged. Only
  `FeePaymentService` moved to `PgExec`. This is the pilot; once reviewed, the same mechanical
  pattern rolls out to `EnquiryService`, `RegistrationService`, `TransportService`,
  `AdmissionService`, `SchoolSettingsService`, `LoginService`, `BaseService`, `SchoolService`,
  `AdmissionWorkflowService`, `RolePermissionService` — then `PostgreSqlDal` can be deleted.

**Verified:** `dotnet build` → 0 errors; app boots with the new DI graph; login page 200.
⚠️ Functional DB testing of an actual fee collection (login + collect a payment) still needs
test data/credentials — recommend a manual pass before rolling out to the other services.

---

### [2026-06-23] Fix #2 + #7 — ROLLOUT to all remaining services; old DAL deleted

**Files changed**
- `Infrastructure/PgExec.cs` — added a **drop-in async `DataSet` method**
  `ExecuteProcedureWithCursorsAsync(string, NpgsqlParameter[])` and renamed the non-query method
  to `ExecuteNonQueryProcedureAsync` (matching the old DAL's names). Fills the DataSet via
  `ExecuteReaderAsync`/`ReadAsync` (helper `ReadTableAsync`), **not** the blocking `DataAdapter.Fill`.
- Migrated to inject `PgExec` (instead of `IConfiguration` + connection string):
  `EnquiryService`, `RegistrationService`, `AdmissionService`, `AdmissionWorkflowService`,
  `SchoolSettingsService`, `LoginService`, `BaseService`, `RolePermissionService`,
  `SchoolService` (SuperAdmin), `TransportService`.
- **Deleted** `Infrastructure/PostgreSqlDal.cs` — no longer referenced.

**Why two flavours of PgExec?** (the design choice to learn)
- `FeePaymentService` (the financial path) got the **full reader-mapper** treatment in the pilot:
  rows stream straight into `List<T>`, *no* DataSet at all → best memory profile.
- The other 10 services use the **drop-in `DataSet` method**: they keep their existing, well-tested
  `DataRow` mapping code untouched, but the *fetch* is now fully async (no thread-block) and runs
  off the singleton `NpgsqlDataSource`.
- *Why not reader-map all 10 too?* Rewriting ~2,500 lines of mapping (SchoolSettingsService alone
  is 945) risks subtle bugs for a smaller, secondary win (the second in-memory copy). The async
  fetch — the part that fixes thread starvation — is delivered to **every** service either way.
  Any service can be upgraded to the reader-mapper style later, incrementally.

**Net effect:** every DB call in the app is now genuinely async and shares one pooled
`NpgsqlDataSource`. The synchronous `NpgsqlDataAdapter.Fill` is gone from the codebase.

**Verified:** `dotnet build` → 0 errors; old DAL deleted with no remaining references; app boots
in Development and login page returns 200 (every service resolves `PgExec` via DI). Note: running
in *Production* without `ConnectionStrings__DefaultConnection` set now fails fast with a clear
"not configured" error — that's the intended Fix #5 behaviour, not a regression.

**Still recommended:** a manual functional pass over the main screens (login, enquiry list,
admission, fee collection, school settings) against the local DB before deploying — the mapping
code is unchanged, but this rollout touched every data path.

---

### [2026-07-28] Frontend — shared `EC` helpers, and the dead `asp-*` attributes

Not one of the seven numbered fixes; this is the frontend equivalent. Full conventions and the
trap list live in **`educore/docs/FRONTEND-CONVENTIONS.md`** — read that before touching page
JavaScript. Summary only here.

**What changed.** Page JavaScript now shares one global `EC` in `wwwroot/js/site.js` (loaders,
busy buttons, `confirm`/`prompt`, list loading/empty states, `esc`, `money`, `num`/`numPos`),
plus the single `ecToast` in `_Scripts.cshtml`. Page-local copies were removed across ~46
views: 5 different toast function names (two taking their arguments in the *opposite* order),
14 `esc` definitions across 4 variants, 8 `money` across 2, and one `num` name with two
different behaviours. All 17 native `confirm()`, the 1 `prompt()` and 1 of the 2 `alert()`
calls are gone — the remaining `alert` is the fallback *inside* `ecToast` for when toastr
itself fails to load, and must stay.

**The find that mattered most:** `Areas/ERP/Views/_ViewImports.cshtml` did not exist, so tag
helpers were off for the whole ERP area and **363 `asp-*` attributes across 48 views rendered
as literal dead HTML**. Add Staff was the clearest casualty — its 21 inputs had no `name`, so
the form posted nothing and could never have worked. Adding the one file fixed all of it. A new
area needs its own `_ViewImports.cshtml`, and Razor runtime compilation does not pick up a
*new* one without an app restart.

**Also fixed:** `Views/Account/Error.cshtml` hardcoded "404 Page Not Found" while
`UseStatusCodePagesWithReExecute` routes every status through it, so a user hitting a page
their role can't open was told it did not exist — it now reads the real status code.
`_FeeReceiptModal` used `$` in a body-rendered partial, but jQuery loads at the bottom of the
page, so its format buttons never got a handler on any of the 6 pages that include it.

**Verified:** `dotnet build` → 0 errors. Helpers, toasts, confirm/prompt, empty states, money
and number formatting exercised in the browser against the running app.

**Worth knowing:** `dotnet build` does **not** check inline JavaScript — a `.cshtml` with a
broken `<script>` still reports 0 errors. Three such breakages were found only by fetching each
rendered page and running its inline scripts through `new Function(src)`. Roughly 10,400 of the
24,661 `.cshtml` lines are inline `<script>`, and none of it is linted; adding ESLint is the
highest-value frontend work left.

**Not verified end to end:** the receipt format buttons and the TC void prompt — this school
has no receipts and no TC records to exercise them.

---

### [2026-07-29] Enquiry CRM — S.No column, newest-first ordering, proc pulled into the repo

**What changed.** The Enquiry CRM table gained an `S.No` column — and so did the mobile card
list, which renders the same rows below 768px — and `GetEnquiries` now orders newest enquiry
first. The old ordering treated the list as a follow-up work queue
(`CASE WHEN is_overdue THEN 0 ELSE 1 END, next_followup_date ASC NULLS LAST, created_at DESC`);
it is now `created_at DESC, enquiry_id DESC`. The id tie-breaker matters — without it, two rows
sharing a `created_at` can swap places between page fetches and appear twice or not at all.

**S.No is computed, not stored.** Paging is server-side, so the number is
`(page - 1) * pageSize + index + 1` — taken from the response, not from the row array index,
which would restart at 1 on every page. The offset is computed once in the fetch callback and
handed to both `renderTable` and `renderMobileCards`, so the two views cannot drift apart.

**`core.sp_enquiry_crm_manage` existed only in the database.** There was no matching script under
`EduCoreDataAccessLayer/Database/`, so the proc body was unversioned. It is now checked in as
`Database/enquiry_crm_manage.sql`, dumped from the live definition with the ORDER BY changed.
Other procs may be in the same state; check for a script before editing one.

**No shared sorting mechanism exists.** `Models/ListModelBase.cs` provides the *state*
(`SortColumn`, `SortDir`, paging, `Search`) and 6 list models inherit it, but the clickable
header UI is copy-pasted: `StudentList.cshtml` and `FeeDueReminders/Index.cshtml` each hold a
private `SortUrl()`/`SortIcon()` `@functions` pair, and `InventoryItem.cshtml` sorts client-side
over an in-memory array. Enquiry CRM opts out of all of it — it is AJAX + server-paged, so a
client-side sort would only reorder the visible page. Sortable headers there need proc-level
sort params first. A shared `_SortHeader` partial is the obvious cleanup if a third page wants
sorting.

**Verified:** proc replaced on Railway (`CREATE PROCEDURE`), `pg_get_functiondef` confirms the
new ORDER BY, and `GetEnquiries` for tenant 23 / school 33 returns enquiry ids 52, 51, 50, 49,
48 — descending by `created_at`. No C# changed, so no build was needed; note again that
`dotnet build` would not have checked the view's inline JavaScript anyway.

---

### [2026-07-29] Enquiry CRM converted to the StudentList list pattern

**Why.** The repo had two unrelated ways to build a list screen. StudentList / StaffList /
FeeDueReminders / TC Register are server-rendered: a model deriving from `ListModelBase`, a GET
filter form, `SortUrl`/`SortIcon` header links and the shared `_Pager` / `_PageSize` partials.
Enquiry CRM was AJAX: a JSON endpoint, rows built as HTML strings in JavaScript, and a
hand-rolled pager. Same job, two patterns, and the AJAX copy had already drifted (see the
per-page bug below). Enquiry CRM now follows the StudentList pattern exactly.

**What changed, layer by layer.**

| Layer | Change |
|---|---|
| `EnquiryModel.cs` | `EnquiryCrmPageModel` now derives from `ListModelBase`; `Enquiries` → `Items`; filters became bound properties |
| `IEnquiryService` / `EnquiryService` | `GetEnquiryCrmPageAsync(query, …)` fills the bound model, mirroring `GetStudentListPageAsync`; `GetEnquiriesAsync` gained `sortColumn` / `sortDir` |
| `sp_enquiry_crm_manage` | `GetEnquiries` gained `p_sort_column` / `p_sort_dir` with the same whitelisted CASE sort as `sp_student_list` |
| `EnquiryController` | `EnquiryCRM(EnquiryCrmPageModel query)` binds from the query string; the `GetEnquiriesData` JSON endpoint was deleted |
| `EnquiryCRM.cshtml` | List, filters, pipeline tabs, sorting and paging are all server-rendered |

**Adding proc parameters means DROP + CREATE, not CREATE OR REPLACE** — REPLACE cannot change a
signature. DDL is transactional in Postgres, so wrapping the script in `BEGIN`/`COMMIT` makes the
swap atomic. This is safe here only because Npgsql binds **named** parameters: `EnquiryService`
passes ~16 parameters in a completely different order from the 50-parameter signature and works,
which is the proof. If binding were positional, inserting parameters would have broken every
caller.

**Net effect on the page:** inline JavaScript dropped from **1041 to 686 lines**. Gone entirely:
`fetchData`, `renderTable`, `buildTableRow`, `renderMobileCards`, `buildMobileCard`,
`updatePagination`, `buildPgHtml`, `pageRange`, `buildStatusDropdown`, `STATUS_LIST`, and every
filter/page-size handler. What replaced them is Razor markup plus two partials,
`_EnquiryStatusCell.cshtml` and `_EnquiryRowActions.cshtml`, shared by the table and the mobile
cards so the two cannot drift. Row actions (status change, follow-up, register, convert, delete)
are still AJAX and now call `reloadList()` — StudentList keeps AJAX for its row actions too, so
this matches rather than diverges.

**Two bugs fixed on the way:**

1. *Per-page selector vanished.* The old JS hid the whole pager bar on `totalPages <= 1`. With 11
   records at 25/page everything fits one page, so the selector that got you there disappeared and
   there was no way back to 10. The shared partials deliberately use **two different rules** —
   `_Pager` hides on `TotalPages <= 1`, `_PageSize` on `TotalCount <= smallest offered size` — and
   adopting them fixes this by construction.
2. *Duplicate `PageSize` input.* Rendering `_PageSize` in both the desktop and mobile bars would
   put two `name="PageSize"` selects in one form; they post as `"10,25"`, which fails to bind to
   `int` and silently does nothing. There is now **one** pagination bar serving both layouts, in
   its own card outside `.crm-table-wrap` and `.crm-card-list`.

**Sortable columns:** name, class, status, source, nextfu, age. Unknown keys — including an
injection attempt — fall through to the default `created_at DESC, enquiry_id DESC`.

**Verified:** `dotnet build` → **0 errors** (the 2 CS8620 nullability warnings on the new
`SortUrl` are the same ones StudentList, StaffList and FeeDueReminders already carry — inherent to
the shared helper). Proc exercised directly for every sort key plus a `'; DROP TABLE …'` input,
which sorted as default and changed nothing. Inline JS re-checked with `node --check`.

**Not verified:** the rendered page in a browser. Razor views are compiled at build time, so type
and syntax errors in the view are caught — but the visual result was not confirmed.

**Follow-ups, same day.** The KPI card row was removed from Enquiry CRM: it repeated the pipeline
tabs (Total/All, Campus Visits, Admitted) and the quick-filter buttons (Due Today, Overdue) — the
same figure in two or three places. Stage counts stay on the tabs, Due Today / Overdue became
counts on the buttons that filter by them, and Conversion Rate — the only number unique to the
row — became a chip in the pipeline card header. `.crm-kpi-card` went with it.

**The list table style is now shared.** It lived in `StudentList.css` as `.sl-tbl` and is now
`.ec-list-tbl` / `.ec-sortable` / `.ec-si` in **`wwwroot/css/educore-theme.css`**, used by
StudentList, Student/Inactive and Enquiry CRM. Copying it into the Enquiry page would have
recreated exactly the duplication this whole change set is removing. Page-specific column widths
and breakpoints stay in each page's own file. **Add a new list screen by using these classes — do
not paste the rules again.**

Two things the extraction fixed that the original `.sl-tbl` had wrong:
`.ec-table thead th` carries no `white-space` rule, so multi-word headers wrapped once a sort icon
was added — the shared block sets `nowrap`. And `.sl-sortable:hover { color: … }` never applied,
because Bootstrap's `.text-reset` is `color: inherit !important`; the shared rule matches that
specificity. The sort icon is also `inline-flex` with a `gap` now, so it sits on the text baseline
instead of being nudged with `margin-left` and a `vertical-align`.

---

### [2026-08-10] Student promotion — the write step, in-place, with a history table

**Files changed**
- `EduCoreDataAccessLayer/Database/student_promotion.sql` (new)
- `EduCoreDataAccessLayer/Models/ERP/StudentPromotionModel.cs` (new)
- `EduCoreDataAccessLayer/Services/Contract/ERP/IAdmissionService.cs`
- `EduCoreDataAccessLayer/Services/Repository/ERP/AdmissionService.cs`
- `educore/Areas/ERP/Controllers/StudentController.cs`
- `educore/Areas/ERP/Views/Student/Promotion.cshtml`

**What was wrong.** `ERP/Student/Promotion` looked finished but nothing was ever written.
`commitBtn` hid the modal and toasted *"The promote step isn't enabled yet."* — a hardcoded
placeholder, not a setting — and the `[HttpPost] Promotion` action was a stub that set a
success message without touching the database. No promote proc existed.

**In-place update, not a row per year.** `core.students` holds one row per student with
`class_name` / `section` / `academic_year` on it; there is no enrolment table, and
`uq_student_admission_no (tenant_id, school_id, admission_no)` forbids a second row for the
same student in a new session. `student_fee_plan` and `student_ledger` key on `student_id`
alone with no year column, so a new row per year would strand every ledger entry and payment
on the old id. `student_attendance` already snapshots `academic_year`/`class_name`/`section`
per row *because* the student row is expected to change underneath it. So promotion updates
the student row and the `student_id` never changes — same reasoning as the exit flow.

**History.** The student row therefore remembers nothing about where it came from, so
`core.student_promotion_history` records one row per student per run (from year/class/section,
to year/class/section, outcome, dues snapshot, who and when).

**The ladder bug this uncovered.** The page built its "next class" ladder from
`config.sp_dropdown_common` `'Class'`, which orders `academic_class_id DESC` — i.e. reversed.
For the school with LKG…8 configured, "promote" resolved to the class *below*: the write step
would have demoted the entire school. `academic.academic_classes.display_order` is the column
meant for this, so `core.sp_class_ladder` reads the ladder from there, the page uses it for the
preview, and `sp_student_promote` derives the target class from the same ladder server-side —
the browser no longer says which class a student lands in.

**Dues.** The ledger is not year-scoped, so dues follow the student whatever the checkbox says.
"Carry forward pending dues" is therefore implemented as a gate: unticked, students with an
outstanding balance are skipped and named so the office can settle them first.

Skips are per-student and reported (`skipped_detail`), not fatal — one stale row should not roll
back the class. Re-running is safe: the proc only moves students still sitting on the source
year, so a double submit finds nothing to do.

---

### [2026-08-11] Session rollover — promotion could write students into a session that had no classes

**Files changed**
- `EduCoreDataAccessLayer/Database/academic_session_rollover.sql` (new)
- `EduCoreDataAccessLayer/Database/student_promotion_rollback_2026_08_11.sql` (new, one-off repair)
- `EduCoreDataAccessLayer/Database/student_promotion.sql`
- `EduCoreDataAccessLayer/Database/reference_data_lookup.sql`
- `EduCoreDataAccessLayer/Models/ERP/SessionStructureModel.cs` (new)
- `EduCoreDataAccessLayer/Services/Contract/ERP/{IAdmissionService,ISchoolSettingsService}.cs`
- `EduCoreDataAccessLayer/Services/Repository/ERP/{AdmissionService,SchoolSettingsService}.cs`
- `educore/Areas/ERP/Controllers/{StudentController,SchoolSettingsController}.cs`
- `educore/Areas/ERP/Views/Student/Promotion.cshtml`
- `educore/Areas/ERP/Views/SchoolSettings/ClassSection.cshtml`

**What was wrong.** `academic.academic_classes` and `academic.academic_class_sections` both carry
`academic_year_id` — classes and sections belong to **one session**, which is what
`ERP/SchoolSettings/ClassSection` edits. `sp_student_promote` only checked that the target session
existed as a row in `academic.academic_years`. A newly created session does exist, and is empty. So
promotion happily wrote `class_name`/`academic_year` onto student rows for a session with **zero**
classes and zero sections — free text pointing at nothing, students missing from every
class-filtered page. This was not theoretical: two runs on 2026-08-11 moved 14 real students into
`2028-2029`, which had no structure at all. `student_promotion_rollback_2026_08_11.sql` reversed
them from the history table (a clean 1:1 map, guarded so it is a no-op on anything since moved).

**Three separate holes, all from the same root.**
1. *Target session not checked for structure* — the one above.
2. *The ladder was not session-scoped.* `sp_class_ladder` read `academic_classes` with no
   `academic_year_id` filter, so it returned every session's classes concatenated. Invisible while
   only one session had structure; the moment a second one does, the ladder reads
   `1st, 1st, 2nd, 2nd, …`. Same bug in `config.sp_dropdown_common` `'Class'`, which feeds eleven
   pages.
3. *Sections were carried over unchecked.* "Keep same section" moved `1st-C` to `2nd-C` when class
   `2nd` had only sections A and B. Even a fully set-up session produced invalid rows.

**Session rollover is now its own step.** `academic.sp_academic_year_clone` copies classes (with
`display_order`, stream, coordinator) and their sections (with `display_order`, capacity, room)
from one session into an empty one; `academic.sp_academic_year_structure_info` answers "does this
session have structure, and what could it copy from" and backs both new UI guards. Class teacher is
deliberately not copied — staff change between sessions and it has its own page. The clone refuses
to run when the target already has classes rather than merging and silently doubling it.

This mirrors how school ERPs actually sequence it: roll the structure forward first, promote
students second. Promotion now hard-fails with a message naming the session and the fix, the
Classes & Sections page offers "Copy from <previous session>" when the selected session is empty,
and the Promotion page checks the target session on selection — disabling *Review & Promote* and
explaining why, instead of failing at the last click.

**Promotion is now session-aware end to end.** The next class is read from the **target** session by
`display_order`, and both class and section must exist there or the student is skipped and named.
`sp_class_ladder` takes an optional session (null = current), and the page reloads the ladder from
the target session so the preview matches what the proc will do. The `'Class'` dropdown collapses
to one row per `class_name` ordered by `MIN(display_order)` — every consumer filters on the class
name (students store `class_name` as text, and the views bind `c.Text`), so historic classes stay
selectable for filtering past sessions.

**Still open (the structural one).** Real SIS products keep an enrolment row per session
(`student_id, session_id, class_id, section_id, roll_no, status`) and leave the student row as
identity only — that is what gives them year-wise class strength, historical reports and a
reversible promotion. EduCore updates in place because there is no enrolment table (see the
2026-08-10 entry for why), so `core.student_promotion_history` remains the only record of where a
student came from. Fee dues also still share one un-scoped ledger rather than opening a
per-session balance.

---

### [2026-08-12] Enrolment per session — the structural fix behind the promotion bugs

**Files changed**
- `EduCoreDataAccessLayer/Database/student_enrolment.sql` (new — table, helpers, backfill, history proc)
- `EduCoreDataAccessLayer/Database/{student_master_fields,student_exit,student_promotion,student_list,academic_class_section_fields}.sql`
- `EduCoreDataAccessLayer/Models/ERP/StudentEnrolmentModel.cs` (new)
- `EduCoreDataAccessLayer/Services/{Contract,Repository}/ERP/AdmissionService*`
- `educore/Areas/ERP/Controllers/StudentController.cs`
- `educore/Areas/ERP/Views/Student/Dashboard.cshtml`

**The root cause behind two days of promotion bugs.** `core.students` holds one row per
student with `class_name` / `section` / `academic_year` on it, and promotion overwrites all
three. The moment a student moves up, where they came from is gone — so "how many students
were in 3rd class in 2027-2028" had no answer, filtering the directory by a past session
returned only the students who happened *not* to have been promoted, and an undo meant
replaying `student_promotion_history` backwards by hand (which is exactly what the
2026-08-11 repair had to do).

`core.student_enrolment` now holds **one row per student per session** — the model every
real SIS uses. `core.students` is deliberately left alone: it keeps its three columns and
still carries the student's *present* position, so nothing that reads it broke.

**Phase 1 — write, don't read.** The table, a backfill, and dual-write from all three write
paths (`sp_admission_manage`, `sp_student_promote`, `sp_student_exit`). Nothing read the new
table yet, so Phase 1 could not break a page. Two helpers keep the logic in one place:
`fn_student_enrolment_open` (upsert on `(student_id, academic_year)`, so a double submit or a
re-applied backfill cannot duplicate a session) and `fn_student_enrolment_close` (records the
outcome: Promoted / Retained / PassedOut / Left). `is_current` marks the row matching
`students.academic_year` — exactly one per student, enforced by the open helper.

Keyed on the session **name**, not the id: `students.academic_year` is text and that is what
the whole app matches on. `academic_year_id` / `academic_class_id` are resolved as a
convenience for joins and are nullable, so a student whose session row is missing can still
be admitted. Past sessions were rebuilt from `student_promotion_history` (7 rows on prod,
from the promotion the office ran before the table existed).

**Phase 2 — move the year-wise reads across.**
- `sp_student_list` and `sp_admission_manage 'GetStudents'` LEFT JOIN enrolment on the
  requested session. With no session filter the join matches nothing and the COALESCEs fall
  back to `core.students` — current behaviour is byte-for-byte unchanged. With one, the list
  returns everyone enrolled *that* session, showing the class and section they held **then**,
  and the class/section filters match against that same position. On prod, filtering
  2027-2028 went from 11 students to the correct 18.
- Class/section strength on the Classes & Sections page now counts enrolment rows for the
  session being viewed, so past sessions no longer read as zero. The "cannot remove a class
  that still has students" guard was moved to the same source, which makes it correct for a
  session other than the current one.
- New: `sp_student_enrolment_history` + a **Session History** card on the student dashboard —
  the session-by-session timeline the table was built for. (Note: the rest of that page is
  still mock data; this card is real.)

**Still open.** Attendance, fee plan and ledger continue to key on `student_id` alone —
`enrolment_id` should reach them as those modules are next touched, and the exam module
should be built on it from day one rather than retrofitted. Fee dues still share one
un-scoped ledger rather than opening a per-session balance.

---

### [2026-08-19] Exam Schedule — the Create Exam page was a mock-up; it now has a backend

**Files changed**
- `EduCoreDataAccessLayer/Database/exam_schedule.sql` (new — `academic.exams`, `academic.exam_subjects`, `sp_school_admin_exam_manage`, two more `ExamType` lookup rows)
- `EduCoreDataAccessLayer/Models/ERP/ExamModel.cs` (new)
- `EduCoreDataAccessLayer/Services/{Contract,Repository}/ERP/*ExamService*` (new)
- `educore/Program.cs` (register `IExamService`)
- `educore/Areas/ERP/Controllers/ExamController.cs`
- `educore/Areas/ERP/Views/Exam/CreateExam.cshtml` · `wwwroot/css/ERP/Exam/CreateExam.css`

**What it was.** `CreateExam.cshtml` read its class list and subject rows from
`localStorage['educore_subjects']` — a store nothing has written since Subject Management
moved to `academic.class_subjects` — with a hard-coded `fallbackMap` of class and subject
names behind it. The academic year was the literal string `"2025 – 2026"`, sections were a
hard-coded `A–E`, exam types were a 5-card picker whose labels exist nowhere else in the app,
and Save did `console.log(payload)` followed by a success toast. The controller had no
service injected.

**Scope: an exam belongs to a class, not a class-section.** Every section of the class sits
the same paper on the same date, which is how schools actually publish a datesheet; Marks
Entry picks the section. That removed the Section step and its whole failure mode (a
hard-coded section list that had no relationship to `academic_class_sections`).

**Reused rather than rebuilt.** Three existing services already held what the page needed, so
the only new SQL is the exam tables themselves:
- classes → `ISubjectService.GetClassesAsync` (current year's classes with a subject count)
- the datesheet's subject rows → `ISubjectService.GetClassSubjectsAsync`
- exam types → `IReferenceDataService.GetOptionsAsync("ExamType", …)`, the
  `config.lookup_value` category that has been sitting there unused since the
  reference-data work. Two platform defaults were added (`half`, `preboard`) to cover the
  types the mock-up offered.

**The proc.** One `sp_school_admin_exam_manage` with `GetExams | GetExam | SaveExam |
DeleteExam`, shaped after `sp_school_admin_subject_manage`: same scope guard, same
`COALESCE(p_academic_year_id, <is_current>)` year resolution, and the same replace-all
datesheet write (walk the JSON, collect `v_keep`, delete what is no longer listed). Business
rules are `RAISE`d so the service surfaces `MessageText` to a toast: duplicate name for that
class+year (case-insensitive, via a partial unique index that excludes soft-deleted rows so a
name is reusable after a delete), a subject the class does not study, a subject date outside
the exam window, pass marks above max, end before start. Delete is soft — marks will
reference these rows.

**Session-aware from day one**, per the note left on the enrolment entry above: exams key on
`academic_year_id` + `academic_class_id`, not on a class name. When the marks table is built
it should carry `enrolment_id`, so a student's marks stay attached to the session they sat
the paper in.

**Verified** against the local dev database (16 cases: create, list, edit-with-a-dropped-
subject, soft delete, name reuse after delete, and every guard above). Applying the script to
Railway is a separate step.

**Still open.** `MarkEntry.cshtml` is still a mock-up — its exam / class / section / subject
dropdowns can now be fed from these two tables, but it needs a marks table and its own proc.
*(Done the same day — see the next entry.)*

---

### [2026-08-19] Marks Entry — wired to real rosters, with a per-sheet lock

**Files changed**
- `EduCoreDataAccessLayer/Database/exam_marks.sql` (new — `academic.exam_marks`, `academic.exam_mark_sheets`, `fn_exam_sheet_roster`, `sp_school_admin_exam_marks_manage`)
- `EduCoreDataAccessLayer/Models/ERP/ExamModel.cs` · `Services/{Contract,Repository}/ERP/*ExamService*`
- `educore/Areas/ERP/Controllers/ExamController.cs`
- `educore/Areas/ERP/Views/Exam/MarkEntry.cshtml`

**What it was.** A well-built page on top of three mock arrays: `EXAMS` (four hard-coded exams),
`SUBJECT_SCHEDULE` (five subjects at 100/33), and `STUDENTS` (twelve invented names). Subjects
were read from the dead `localStorage['educore_subjects']` key. An `autoLoad()` block fired on
page load so the mock always showed something. Save Draft was `ecToast('success', …)` and
Finalize only flipped a local flag; `ExamController.SaveMarks` set a TempData message and
redirected.

**A SHEET is one (exam, subject, section)** — what a teacher fills in one sitting. Since an exam
belongs to a class (previous entry), the selector cascade collapsed to **Exam → Section →
Subject**: picking the exam fills the Class box read-only, and the section list is built from the
sections that actually have students enrolled, with their head-counts.

**The roster reads `core.student_enrolment`, not `core.students`.** This is the thing that would
have quietly broken later. On prod, tenant 23's 2027-2028 enrolment holds 1st-A/B/C, but those
students have since been promoted, so `core.students` no longer shows anyone in 1st. Reading the
current table would have made a past session's sheet come back empty. `fn_exam_sheet_roster` is a
single SQL function used by both the read and the finalize-fill, so the two can never disagree
about who sits a paper. `roll_no` is not captured on any prod enrolment row yet, so it falls back
to `students.roll_no` then `admission_no`.

**The lock lives on the sheet, not on the mark.** `exam_mark_sheets` holds
`is_finalized / finalized_by / finalized_at / reopened_by / reopened_at` per
(exam, subject, section) — a half-finalized sheet is not a state that should be representable.
Finalizing English leaves Maths open. Marks carry `enrolment_id` from day one, as the enrolment
entry above asked for.

**Decisions.** Marks entry is gated on `exams.manage` alone — not on being the class or subject
teacher, which would silently lock out any school that has not assigned class teachers or built a
timetable. Reopening a finalized sheet is **school-admin only**, enforced server-side in
`ReopenSheet` via `IPermissionService.GetUserAccessAsync`, because the page's own text tells
teachers to ask an admin. **Grades are not stored** — no configurable grade scheme exists, so the
page derives them from marks for display only; storing them would freeze a scale nobody has set.

**Guards** (all `RAISE`d, surfaced as toasts): marks outside 0..max *for that subject* (a 50-mark
paper rejects 60), a student not enrolled in that class+section, a subject not on the exam's
datesheet, saving into a finalized sheet, reopening a sheet that is not finalized. `is_absent` and
`marks_obtained` cannot disagree — a CHECK constraint plus the proc dropping marks when absent is
set.

**Verified** with 19 assertions against the local dev database (draft save, absent handling,
per-subject max, foreign student, finalize filling blanks as Absent, per-sheet lock isolation,
reopen, cascade on exam delete, scope guards), then read-only against prod: the real exam's
7-subject datesheet, its sections (A:5, B:2, C:2), and the 5-student 1st-A roster all load.

**Still open.** No report card / consolidated marksheet yet — that is the natural consumer of
these two tables, and it is where a configurable grade scheme should land rather than being
hard-coded in a second page. Attendance and the fee ledger still key on `student_id` alone.

---

### [2026-08-19] An exam covers MANY classes — the per-class exam was the wrong shape

**Files changed**
- `EduCoreDataAccessLayer/Database/exam_multiclass_migration.sql` (new)
- `EduCoreDataAccessLayer/Database/{exam_schedule,exam_marks}.sql` (rewritten to the new shape)
- `EduCoreDataAccessLayer/Models/ERP/ExamModel.cs` · `Services/{Contract,Repository}/ERP/*ExamService*`
- `educore/Areas/ERP/Controllers/ExamController.cs`
- `educore/Areas/ERP/Views/Exam/{CreateExam,MarkEntry}.cshtml` · `Views/Exam/Datesheet.cshtml` (new)
- `educore/wwwroot/css/ERP/Exam/{CreateExam,Datesheet}.css` · `Views/Shared/Sections/Menu/_VerticalMenu.cshtml`

**The design error, reported from use.** Both entries above keyed the exam itself to one
class (`academic.exams.academic_class_id`), chosen to drop the Section dropdown. That took the
simplification one level too far, and within a day of use it showed up three ways at once:

- "Unit Test 1" for two classes meant **two exam rows with the same name** — the name and the
  whole 7-subject datesheet retyped per class. Prod had exactly that: exam 2 (1st) and exam 3
  (2nd), identical in name, type and dates.
- Marks Entry's exam dropdown listed what looked like **duplicates**, and its Class box had to be
  read-only because the exam had already decided the class — backwards from how anyone picks it.
- There was **nowhere** to answer "what is 1st class sitting, and on which date".

**The fix is the shape real school ERPs use.** The exam is school-wide for one academic year;
the class moves down onto the datesheet (`exam_subjects.academic_class_id`) and onto the marks
rows. A class sits the exam exactly when it has datesheet rows, so there is no separate
exam-classes table to keep in step. The duplicate-name guard loses the class: one "Unit Test 1"
per year. Per-class datesheets are genuinely independent — on prod, 1st and 2nd share a name and
window but order EVS and General Knowledge on different days.

**A real bug this surfaced.** `exam_mark_sheets` was keyed
`(exam_id, subject_id, section)`. With one exam spanning classes, section 'A' of 1st and section
'A' of 2nd would have **shared one lock** — finalizing one would silently freeze the other. The
class is now part of that key; a regression test asserts the two sheets lock independently.

**Migration.** `exam_multiclass_migration.sql` moves the column, backfills from the old
`exams.academic_class_id` (falling back to the student's enrolment for marks rows), swaps both
unique keys, then drops the column. Two guards matter: it refuses rather than guessing if any row
cannot be attributed to a class, and it **names the exams that now collide** instead of letting
`CREATE UNIQUE INDEX` fail with a bare Postgres error. That guard fired on prod exactly as
intended — the two "Unit Test 1" rows were merged by hand (7 datesheet rows moved onto the
surviving exam, 0 marks existed, nothing lost) and the migration then completed. It also drops
the stale 11-argument marks proc, because the signature gained a parameter and
`CREATE OR REPLACE` would have added a second overload rather than replacing it.

**UI.** Exam Schedule now names the exam once, ticks the classes that sit it (a class with no
subjects mapped is shown disabled with the reason, not hidden), and edits one class's datesheet at
a time with **"Copy to other classes"** — which copies dates and marks for every subject the
target class also studies and leaves its other subjects alone. All classes' datesheets are held
client-side and posted in one Save. Marks Entry is back to the natural
**Exam → Class → Section → Subject** cascade, auto-selecting the class when only one sits the exam.
A new **Datesheet** page (third item under Examinations) groups papers by date for one class or
all, and prints.

**Verified**: 16 assertions on the local dev database (one exam over two classes with different
subjects and different max marks for the same subject, per-class subject validation, duplicate
name, class dropped from an exam clearing its datesheet, off-exam class rejected, and the
sheet-lock isolation above), the migration run end to end locally before prod, and every read path
re-checked against prod after migrating.

**Still open.** No report card yet — the natural consumer of these tables, and where a
configurable grade scheme belongs. Max marks on the create form still accepts up to 1000; a
1000-mark paper was typed by accident once already.

---

### [2026-08-22] Exams: simplified the three pages, then added timing, sections and publish

**Files changed**
- `EduCoreDataAccessLayer/Database/exam_timing_sections_status.sql` (new migration)
- `EduCoreDataAccessLayer/Database/{exam_schedule,exam_marks}.sql`
- `EduCoreDataAccessLayer/Models/ERP/ExamModel.cs` · `Services/{Contract,Repository}/ERP/*ExamService*`
- `educore/Areas/ERP/Controllers/ExamController.cs`
- `educore/Areas/ERP/Views/Exam/{CreateExam,MarkEntry,Datesheet}.cshtml`
- `educore/wwwroot/css/ERP/Exam/{CreateExam,MarkEntry,Datesheet}.css`

**Part 1 — the pages were too heavy.** Reported as "looks complex". Marks Entry had an
8-metric summary strip, six badges/pills, a progress bar and a **7-column** grid, for a job that
is typing one number per student. It is now one context line (`Unit Test 1 · 1st-A · English` /
`10:00–13:00 · Max 100 · Pass 35 · 3 of 5 entered`) and **4 columns**; pass/fail shows as a row
tint rather than three extra columns, and "All Present" went because rows already default to
present. Exam Schedule lost its Step 1/2/3 wizard numbering and its copy sub-panel (toggle →
checkbox list → Apply/Cancel) in favour of one **"Same dates for all classes"** tick, and marks
moved from every subject row to **one setting for the exam** — on live data that is 28 boxes down
to 2. `MarkEntry.css` 363 → 251 lines. Datesheet was already lean and was left alone.

Note the trap this created and fixed: `.me-grid-card` was `display:none` in CSS, revealed by a
`showUI()` that the rewrite deleted — the sheet would never have appeared.

**Part 2 — three things the pages were missing.**

*Timing.* `exam_subjects` gains `start_time` / `end_time`, set once for the exam with the same
"different for some subjects" escape hatch as marks. Shows on the Datesheet as a chip and on the
Marks Entry context line. A `CHECK` plus a proc rule reject a finish before the start.

*Optional sections.* New `academic.exam_class_sections`. **No rows for a (exam, class) means the
whole class** — the default and the common case — so the feature costs nothing when unused.
Ticking sections narrows the exam, and Marks Entry's Section dropdown narrows with it. Unticking
them all reverts to the whole class.

*Publish status.* `exams.status` is `Draft | Published`. A new exam saves as **Draft**, visible
only on the Exam Schedule page; `GetDatesheet` filters `status = 'Published'` proc-side and the
Marks Entry / Datesheet exam dropdowns filter in the controller. Verified end to end: the live
exam's 14 papers vanish from the datesheet as a draft and return on publish. Editing an exam does
not silently change its status, and publishing an exam with no datesheet is refused. Existing
exams were backfilled to `Published` — defaulting them to Draft would have made live datesheets
and marks sheets disappear.

**The list is now class-wise**, as asked: a table of Exam Name (with academic year) · Class &
Section · Dates · Status · Actions, **one row per class-section**, from a new `GetExamList` op.
A class with no section targeting yields one row marked "all sections". The exam name, year and
actions render once per exam and the continuation rows leave those cells blank, since Edit /
Publish / Delete act on the whole exam.

**A trap worth recording:** Npgsql maps a Postgres `time` to **TimeOnly**, which is not
`IConvertible` — exactly the same crash as `DateOnly` earlier in this work. `NullTimeStr` uses the
same cast ladder, and the format string is a const `"HH\\:mm"` so a culture's time separator
cannot change it.

**Verified**: 11 assertions for timing/sections/status plus the earlier 16 multi-class ones, all
against the local database; the migration run end to end; three views build-checked and their
inline JS syntax-checked. **Not applied to Railway** — this is mid-iteration feature work and
local is now the dev database.

**Part 3 — the same-dates simplification went too far, and was buggy.** "Same dates for all
classes" was added as a toggle, with a per-class mode behind it. Two real defects came out of that
duality:

- Typing in the exam-level Max / Pass / Time boxes ran `renderSheet()` **per keystroke**, rebuilding
  the table and destroying the caret — you could type `1` but never `00`.
- The toggle's change handler called `captureSheet()`, which read the **new** mode while the rows on
  screen were still rendered in the **old** one, writing the wrong rows into the wrong classes and
  silently clobbering per-class dates.

Removing the toggle fixed both, but then a normal request — *1st sits English on 22 Aug, 2nd on
25 Aug* — was not expressible. That was the wrong trade: in a real school, dates stagger because the
same teachers invigilate, **max marks differ by level** (1st English 50, 10th 100), duration differs
(juniors 2h, seniors 3h) and subject lists differ. Per-class variation is the model, not the
exception — and `exam_subjects` was already keyed per (exam, class, subject) with its own date, time
and marks, so **the database supported all of it; only the UI could not express it.** No migration
was needed to fix this.

The datesheet is now a **grid: subjects down, classes across**, with a switcher for what the cells
hold (Dates / Times / Max / Pass) so the layout never changes. A dash marks a subject the class does
not study. The convenience that the toggle was trying to provide became a per-row **copy-across**
button — an action, not a mode, so it cannot desynchronise state. The `advanced` per-subject
override mode was deleted too: the grid covers it. The four boxes above the grid now only seed new
subjects and deliberately re-render nothing.

Verified with 11 assertions covering exactly the reported scenario: same subject on different dates
per class, 50-mark and 100-mark papers in one exam, different start times, subject lists that differ
per class, all under a single exam row, with the outside-the-window date guard still firing.

**Part 4 — a class cannot sit two papers at once.** Reported from the Datesheet, where one class
showed several subjects on the same date at the same time. Two causes:

- **No guard.** Nothing stopped it, in the UI or the proc.
- **A bad default.** Seeding every subject with the exam's start date put a whole class's papers in
  one slot. On live data that produced **59 of 84 papers clashing** — class 4th had all 7 subjects
  at 09:30–12:30 on 23 Aug.

`SaveExam` now refuses a clash, in two passes. Within the exam: same class, same day, papers whose
times overlap — or where **either time is missing**, since an unspecified time cannot be
distinguished from an overlap; if two papers share a day, say when each runs. Across exams: the same
check against every other non-deleted exam in the year, so "Q1 Test" and "Q2 Test" cannot both put
4th class on 23 Aug at 09:30. Both are **section-aware** via `fn_exam_sections_overlap` — 1st-A and
1st-B may sit different papers in the same slot, because no `exam_class_sections` rows means the
whole class and an empty set overlaps everything.

The default now **staggers papers onto consecutive days** from the start date, leaving anything past
the end date blank rather than piling it up; the start-date handler re-staggers instead of
collapsing everything back onto day one, which was the same bug in another place.

Existing bad rows predate the guard, so `GetDatesheet` returns a computed `has_clash` per row and
the Datesheet flags each one plus a count at the top — the data is shown as broken rather than
quietly rendered.

Verified with 8 assertions: identical times, partial overlap and missing times all refused;
**morning-plus-afternoon on one day allowed**; two different classes in the same slot allowed;
cross-exam clash refused; 1st-B allowed alongside 1st-A; the same section double-booked refused.
Fixing the 59 existing rows is the school's call — the page now shows which ones.

**Part 5 — a session picker on Exam Schedule and Datesheet.** Both pages were hard-wired to the
current academic year. They now carry a **SESSION** dropdown with a badge reading `CURRENT` or
`NOT CURRENT`, so it is obvious when you are looking at another year.

Almost no new code was needed: `sp_school_admin_exam_manage` already took `p_academic_year_id` and
only defaulted to `is_current` because every caller passed null, and `config.sp_dropdown_common
'AcademicYear'` already returns the school's sessions with the current one flagged `IsSelected`. So
the work was threading an optional `academicYearId` (0 = current) through `IExamService` and
`ISubjectService` — added as **optional parameters** so `SchoolSettingsController`, which shares
`GetClassesAsync`/`GetClassSubjectsAsync`, is untouched.

Changing the session **reloads the page** rather than refreshing in place: the class list, the
subject lists, the exam list and the datesheet all belong to one session, and a partial refresh
would mix two sessions on screen. The class/subject reads take the session too, so picking a past
year shows *that* year's classes — not the current year's against old exams. Empty-state messages
now name the session instead of saying "the current academic year", which was wrong the moment a
different one could be selected.

Verified against live data: `GetExamList` for session 11 returns that session's exam, session 15
returns nothing — same proc, different `p_academic_year_id`.

**Marks Entry deliberately has NO session picker.** It is structurally different: Exam Schedule
*creates* (so it must be told the session) and Datesheet *browses* (so it must be given a scope),
but Marks Entry starts from an **exam**, and an exam belongs to exactly one session. The session is
derived, not chosen — `sp_school_admin_exam_marks_manage` reads `academic_year_id` off the exam and
`fn_exam_sheet_roster` uses it, which is why a past session's sheet lists who was in that class
*then*. A picker would be a fifth selector on the page, redundant, and able to disagree with the
exam.

The gap was that the exam dropdown filtered to the current session, so marks for a past exam could
not be entered or corrected — common, because results are often finalised after rollover. Fixed with
no new controls: the dropdown is **grouped by session** with native `<optgroup>` headings (current
session first, sessions with no published exam omitted so there are no empty headings), and the
session now shows as a chip on the sheet's context line and in the finalize dialog, so nobody marks
the wrong year by accident. No SQL change — the controller calls `GetExamsAsync` once per session.

A note for the next person: the local test data has classes with `is_deleted = true` whose ids are
still referenced by `exam_subjects` (the FK does not check the flag). A test written against a
hard-coded `academic_class_id` will start failing with "A selected class does not belong to this
school" after classes are recreated — resolve ids by name instead.

---

### [2026-08-23] Side menu: half of it led nowhere

**Files changed**
- `educore/Views/Shared/Sections/Menu/_VerticalMenu.cshtml`
- `educore/Controllers/HomeController.cs` · `educore/Views/Home/Roadmap.cshtml` (new)
- `EduCoreDataAccessLayer/Database/school_module_toggles.sql` (new)
- `EduCoreDataAccessLayer/Models/ERP/AdmissionWorkflowModel.cs` · `Services/Repository/ERP/AdmissionWorkflowService.cs`
- `educore/Areas/ERP/Views/AdmissionWorkflow/WorkflowSettings.cshtml`

**Reported as "the items are bogus, a basic school will get confused".** Measuring it
first showed the complaint was not really about grouping: **17 top-level groups, 79 items,
39 of them (49%) dimmed `soon` placeholders, and five groups where nothing at all worked**
— Accounting, Library, Hostel, Communication, Certificates & ID. A menu is a promise, and
39 of them were broken. Front Office showed 10 items of which 2 worked; there was an empty
"More" section header.

Removed the five dead groups and every `soon` stub: **79 items → 45, all real**, verified by
resolving every `asp-controller`/`asp-action` pair in the menu against the actual controllers
(45 links, 0 broken). That check also turned up `Fee/DayClose` — a complete, working page
that had no menu entry at all.

Regrouped by how often a school touches something, and renamed for plainness (Front Office →
**Admissions**, in funnel order Enquiries → Registrations → New Admission; Human Resources →
Staff). Timetable became a direct link rather than a group of one. The 14-item **School
Settings** dumping ground split into **School Setup / Academic Setup / Fee Setup / Users &
Access**, each gated by the permission it needs.

The 39 planned features are not lost — they moved to a **What's coming** page (More → What's
coming), so the roadmap stays visible without costing 39 lines of navigation.

**Module toggles.** Extended the existing `enable_transport` switch to `enable_exams`,
`enable_inventory` and `enable_payroll` on the same table, proc and settings page, so a school
hides modules it does not run (the menu item is now called **Modules & Workflow**, since that
is what the page holds). All default TRUE. Deliberately *not* a new Modules page: the workflow
proc `COALESCE`s missing params to defaults, so a second page saving only module flags would
silently **reset** every other workflow setting. Transport's own flag was left where it is — it
has six consumers including a real access guard in `TransportController`.

**A regression I caused and fixed.** The rewrite used `<ul class="menu-inner py-1">` as a split
boundary and never re-emitted it, leaving 12 `<ul>` against 13 `</ul>`. `menu.js` binds
PerfectScrollbar to `.menu-inner`, so with no such element the sidebar could not scroll and
wheel events fell through to the page; the menu search, which selects
`#layout-menu > ul.menu-inner > li.menu-item`, silently matched nothing too. I had verified
link targets and counts but not that the markup was still well-formed — for a wholesale rewrite
of a structural partial, **tag balance is the first check, not an afterthought**.

**Still open.** Inventory is gated on `fees.view` because no `inventory.*` permission key
exists yet.

---

### [2026-08-23] Session pickers on the setup pages (and a wrong-year bug they exposed)

**Files changed**
- `EduCoreDataAccessLayer/Database/class_teacher_session.sql` (new)
- `Services/{Contract,Repository}/ERP/{IClassTeacherService,ClassTeacherService}` · `{ITimetableService,TimetableService}`
- `educore/Areas/ERP/Controllers/SchoolSettingsController.cs`
- `educore/Areas/ERP/Views/SchoolSettings/{SubjectManagement,Timetable,AssignClassTeacher}.cshtml` + their CSS

**Which pages need a session, decided from the schema not by eye.** The test is whether
the page's data carries `academic_year_id`:

| Session-keyed → needs a picker | Not session-keyed → does not |
|---|---|
| `academic_classes`, `academic_class_sections` (Classes & Sections, Assign Class Teacher) | `school_calendar` — keyed by date |
| `class_subjects` (Subjects) | `period_structure`, `school_calendar_settings` (Smart Bell) |
| `academic.timetable` (Timetable) | `school_fee_heads`, `school_fee_structures` (Fee Setup) |

So Smart Bell and School Calendar deliberately have **no** picker: a bell schedule and a
weekly-off pattern are school-wide facts, and a picker would imply a per-session variation the
tables cannot store.

**Classes & Sections already had a picker** — dropdown, default-to-current, URL param, even a
"copy the previous session's structure" action. The other three now copy that pattern exactly
rather than the slightly different one used on the Exam pages. Changing session **reloads the
page**: the class list, subject lists, teacher grid and timetable all belong to one session, so a
partial refresh would leave two on screen at once. Only `sp_class_teacher_manage` needed a
parameter added; the subject and timetable procs already took one.

**The bug this exposed.** `sp_class_teacher_manage` resolved the year from
`core.school_settings.academic_year_id` and then fell back to `MAX(academic_year_id)`. That column
is **NULL for a live school**, so it silently resolved to the *newest* year, not the current one:
the grid showed 2028-2029's 2 sections instead of 2027-2028's 11. Worse, the same resolution backs
the `IsTeacher` operation behind `IClassTeacherService.IsClassTeacherAsync`, which gates **who may
mark attendance** — so a class teacher of a current section could be told they were not one and
refused. The fallback order is now: explicit parameter → `academic_years.is_current` (what every
other proc in the app treats as current) → `school_settings` → newest. Verified: with no parameter
the grid went from 2 rows to the correct 11.

**Still open.** `core.school_settings.academic_year_id` being NULL is not fixed here — it is now
simply not relied on first. Worth deciding whether that column should be populated or dropped,
since two sources of "current session" will drift again.

---

# Glossary (quick reference)

| Term | Plain meaning |
|---|---|
| **Concurrent users** | People with the app open at once (not simultaneous DB queries). |
| **Vertical scaling** | Bigger single server. Simple, has a ceiling. |
| **Horizontal scaling** | Many app copies behind a load balancer. Survives load & failures. |
| **Load balancer** | Traffic cop spreading requests across instances. |
| **Instance** | One running copy of the app. |
| **Stateless** | Keeps no important data in its own memory between requests → scalable. |
| **Stateful** | Remembers things locally → breaks across multiple instances. |
| **Sticky sessions** | Load balancer pins a user to one instance (band-aid). |
| **Session** | Per-user server scratchpad keyed by a cookie. |
| **Redis** | Separate fast in-memory key-value store shared by all instances. |
| **Distributed cache/session** | Cache/session stored in Redis so all instances share it. |
| **DataProtection keys** | Keys ASP.NET uses to encrypt the auth cookie; must be shared across instances. |
| **Connection pool** | Reusable set of open DB connections borrowed per query. |
| **MaxPoolSize** | Max connections Npgsql keeps per connection string (default 100). |
| **max_connections** | Max connections Postgres itself accepts (default ~100). |
| **PgBouncer** | Proxy that lets many app connections share few real DB connections. |
| **Thread pool starvation** | All worker threads blocked waiting → app stalls though CPU idle. |
| **Async/await** | Releases the thread while waiting on I/O → more throughput. |
| **DataReader** | Streams DB rows one at a time (low memory) vs. DataSet buffering all. |
| **Caching** | Remember an expensive answer to avoid recomputing/refetching. |
| **Cache invalidation** | Clearing cached data when the real data changes. |

### [2026-08-23] Dropping a proc overload broke the deployed app (42883)

class_teacher_session.sql added `p_academic_year_id` to
`core.sp_class_teacher_manage` and dropped the 9-arg signature, because
CREATE OR REPLACE cannot add a parameter. Applying it to Railway broke the
Railway-hosted app with **42883 procedure does not exist**: local dev and the
deployed app **share one database**, and the deployed build was still sending 9
params. It took out the `IsTeacher` operation too — the attendance-marking gate
at `AttendanceController.cs:38` — so it was not merely a settings page.

Fix: `class_teacher_session_compat.sql` keeps both signatures while the two
builds coexist, the 9-arg one a thin shim delegating with a NULL year.

Two things that make this less obvious than it looks:

- **Two overloads differing only by a trailing DEFAULT param are ambiguous to a
  named-argument call** — `procedure is not unique` — and named args are how
  Npgsql calls procs. So `p_academic_year_id` must have **no** default: a 9-name
  call then cannot match the 10-arg proc, and a 10-name call cannot match the
  shim. Verified both ways on PG 16 before touching production.
- **CREATE OR REPLACE cannot remove a parameter default**, so the proc has to be
  dropped and recreated. Wrapping it in BEGIN/COMMIT makes that atomic —
  PostgreSQL DDL is transactional — so no request can land mid-swap.

**The rule this establishes:** a proc signature change is only safe to apply to
a shared database once every build talking to it sends the new shape. Ship the
compatible signature first, deploy, then remove the shim. Remove this one when
the deployed build is on 10 params.

---

### [2026-08-25] Data Protection wired up explicitly (half of Fix #1, without Redis)

`Program.cs` had **no DataProtection configuration at all** (1.5, Fix #1). ASP.NET
still worked, because it silently generates a key ring in a per-machine path — on
Linux `~/.aspnet/DataProtection-Keys`, inside the container. That path is part of
the image's writable layer, so **every Railway deploy threw the keys away** and
every `EduCore.Auth` cookie issued before it became undecryptable: users were
being signed out on each deploy, and it read as a session bug rather than a
key-ring one.

Now registered explicitly:

- `SetApplicationName("EduCore")` — the name is baked into every protected
  payload. It must never change, or previously protected values stop opening.
- `PersistKeysToFileSystem(...)` — path from `DataProtection:KeyPath`, defaulting
  to `App_Data/keys` and resolved against the content root so the same relative
  value works on Windows dev and in the Linux container. Git-ignored: those XML
  files *are* the keys that sign the auth cookie.
- `AppSettings.ProtectorValue` (a fixed GUID in `appsettings.json`, bound via
  `IOptions<AppSettings>`) is the **purpose string** for `CreateProtector`, not a
  key. Same rule as the app name: fixed forever.
- `AccountController` takes `IDataProtectionProvider` + `IOptions<AppSettings>`
  and builds `_dataProtector` once.

**Applied to: the login-flow user id.** `PendingUserId` — the half-logged-in user
waiting on the multi-role picker, the only live user id the login flow keeps in
session — is now written with `Protect` and read back through
`ReadProtectedUserId`, which catches `CryptographicException`, drops the bad
value and returns null so the caller bounces to Login. A stale token (an old
session, a deploy that lost the key ring) is an invalid value, not a 500. The
`Session["UserId"]` copy in `SaveUserDataToSession` is protected the same way.

Worth recording, because it was invisible until we went looking: **everything
`SaveUserDataToSession` writes is write-only.** Nothing in the repo reads
`Session["UserId"]`, `"Email"`, `"UserName"`, `"RoleCode"`, `"RoleName"`,
`"TenantId"` or `"SchoolId"` — identity is read from **claims**
(`Common.SK_UserId` and friends), and the only session value read outside
`AccountController` is `SK_ActiveRoleId`. So that whole method is a leftover, and
protecting its user id changes nothing observable. It is a deletion candidate,
not a security fix. Left in place here because removing it is a separate call.

The forgot-password `ResetUserId` (`ForgotPassword` → `VerifyOtp`) goes through
the same helper. One property had to survive the change: that flow deliberately
stores **id 0** when the identifier matched nobody, so the verify page looks
identical whether or not the account exists (anti-enumeration). `0` protects and
unprotects like any other id, so the page still cannot tell the two apart — and
`ReadProtectedUserId` returning null only ever means "no reset in progress or an
unreadable token", never "no such user".

After this, the only `SetInt32` values left in session are `SK_ActiveRoleId` (a
role id, read by the menu and `HasPermissionAttribute`) and the dead
`TenantId`/`SchoolId` writes described above.

Two things to know before relying on it:

- **Production still needs a mounted volume.** The `Dockerfile` has none, so
  `App_Data/keys` inside the container is as ephemeral as the default path was.
  Attach a Railway volume and point `DataProtection__KeyPath` at it (e.g.
  `/app/keys`); until then this fixes local dev only.
- **The first deploy after this signs everyone out once**, because the new key
  ring cannot read cookies encrypted with the old discarded keys. Once.

This is Fix #1's key-ring half done with a shared *folder* instead of Redis —
which 1.5 lists as an acceptable form. The session half (`AddSession()` is still
in-memory) is untouched, so the app is still single-instance.

---

### [2026-08-25] Protected ids in URLs — built, audited, then REVERTED

Ids were briefly converted to `IDataProtector` tokens in URLs across 13
controllers (49 parameters, a `[ProtectedId]` model binder, `Url.ProtectId` in
views). **That work was reverted the same day.** Recording why, so nobody rebuilds
it.

**What the measurement showed.** `Protect()` is deliberately non-deterministic —
the same id produces a different 134-character token on every call:

    token1 : CfDJ8PobHlMPbP9LnslLOBNZsphOhu_pDiDkb9SSLJKq8Oqj...
    token2 : CfDJ8PobHlMPbP9LnslLOBNZspj_qrByUR7FB4Coq9WJ3uH6...
    same id, same token? False   -> both decrypt to 12

So one record has unlimited URLs (breaks caching, analytics, comparison), a route
with three ids runs to ~400 characters, and **every URL dies whenever the key ring
is lost** — which on Railway is every deploy until a volume is mounted. Bookmarked
and emailed links would break permanently, not just log users out.

**The audit that settled it.** All 49 id-taking actions were checked for tenant
scope:

| | count | verdict |
|---|---|---|
| tenant + school scoped | 41 | correct |
| tenant only, `[Authorize(Roles = SuperAdmin)]` | 2 | correct by design — SuperAdmin manages schools |
| unimplemented stubs (no DB call at all) | 4 | Leave Approve/Reject, Payroll MarkPaid, EditStudent POST |
| view-only (`ViewBag` + `return View()`, data loads via scoped ajax) | 2 | Student Dashboard, EditStudent GET |

**Zero missing tenant filters.** Defence in depth is real and three layers deep —
controller reads tenant/school from claims, the service refuses early
(`if (tenantId <= 1 || schoolId <= 0 ...) return null`), and the proc filters:

    WHERE s.tenant_id = p_tenant_id
      AND s.school_id = p_school_id
      AND s.staff_id  = p_staff_id

That is what stops one school reading another's record, and it holds whether the
URL says `12` or `CfDJ8…`. The token layer added obscurity on top of working
authorization, at the cost of unreadable URLs and a permanent migration flag —
and with `AllowRawIds: true` (needed because 37 URLs are built in JavaScript,
which the compiler cannot check) it added nothing at all while looking like it
did. That false impression is the main reason it is gone rather than parked.

**Two things the audit did leave behind, worth doing:**

- The 4 stubs must get tenant/school scope when their SPs are written. Nothing
  leaks today because they touch no data, but they are the obvious place for the
  first real hole to appear.
- `Student/Dashboard/{id}` and `EditStudent/{id}` render for any id; the page is
  empty because the ajax behind it is scoped. Harmless, slightly untidy.

**If the number itself ever needs hiding** (leaking how many students a school
has, or a URL that travels outside the app), the answer is a `public_id uuid`
column — stable, non-guessable, survives key rotation — not encryption. See the
UUID notes.

**Kept from this work:** Data Protection registration + persisted key ring, and
the login/reset-flow session protection in the entry above. Those solve real
problems. Deleted: `IdProtector`, `ProtectedIdAttribute`, `UrlHelperExtensions`,
and the `AllowRawIds` flag.

---

### [2026-08-25] `public_id uuid` for students and staff

The replacement for the reverted token scheme, and the reason it is a better
answer: a uuid is **stable**. It survives key rotation, redeploys and a lost Data
Protection key ring, so a bookmarked or emailed link still works next year. A
`Protect()` token does not — and on Railway, where the key ring currently lives
on an unmounted container path, it would break on the next deploy.

To be clear about what this buys: the integer id was never a security hole. The
audit above found zero missing tenant filters across all 49 id-taking actions.
What the integer leaks is **volume** — `/Student/4700` rendering a page tells you
roughly how many students a school has, and that ids are sequential. The uuid
closes that, nothing more.

**`Database/public_id_students_staff.sql`** (new):

- `public_id uuid NOT NULL DEFAULT gen_random_uuid()` on `core.students` and
  `core.staff`, each with a **UNIQUE** index. Unique matters: a duplicate would
  let one school's URL resolve to another school's row.
- The integer PK is untouched. `public_id` is for the outside world only — making
  uuid the PK would bloat every index and every join for no gain.
- `core.fn_public_id_to_id(entity, public_id, tenant_id, school_id)` resolves a
  uuid to the internal id **with the tenant check built in**, returning NULL when
  the row is not that school's. Plus `core.sp_resolve_public_id`, a thin
  refcursor wrapper, because PgExec speaks procedures and has no scalar-function
  shape.

Verified on the local copy (19 students, 14 staff) — **not** on Railway:

| call | result |
|---|---|
| correct tenant + school | `53` (the real id) |
| wrong school | NULL |
| wrong tenant | NULL |
| tenant 1 (platform) | NULL |
| unknown uuid | NULL |
| re-running the whole script | clean (idempotent) |

Unknown-uuid and wrong-school both return NULL, so the response cannot be used to
probe which uuids are real.

**Additive proc changes** — `student_list.sql`, `staff_list.sql` and
`sp_staff_manage.sql` (LIST *and* GET branches) now also return `public_id`. This
is deliberately result-set-only: no signature changed, nothing dropped, so the
build currently deployed on Railway — which knows nothing about the column —
keeps working untouched. That is the lesson from the 42883 incident applied up
front rather than after the outage.

**Two things about running it:**

- `ADD COLUMN` with a **volatile** default (`gen_random_uuid()`) cannot take
  PostgreSQL's catalog fast path. The table is rewritten so each row gets its own
  uuid, under an ACCESS EXCLUSIVE lock. At this size that is seconds, but it is a
  lock — use a quiet window. For a very large table: add nullable, backfill in
  batches, then SET NOT NULL.
- Local dev and Railway **share one database**. Applying this to Railway is a
  production change; it has only been run against the stale local copy here.

**App wiring — done for STAFF only.** `/ERP/Staff/StaffProfile/12` is now
`/ERP/Staff/StaffProfile/36733179-0f7d-4d2f-bc74-449a28bb8f24`:

- `StaffModel` and `StaffListItem` carry `PublicId`; `StaffService` maps
  `public_id` at all three mapping sites via a `GuidVal` reader that returns
  `Guid.Empty` when the column is absent (so the code is inert until the SQL runs).
- `IStaffService.ResolveStaffIdAsync(Guid, tenant, school)` calls
  `core.sp_resolve_public_id`. Unknown uuid and another school's uuid both come
  back as **0** — indistinguishable, so it cannot be used to probe for real ids.
- `StaffProfile`, `EditStaff` (GET + POST), `Reactivate`, `Deactivate` take a
  `Guid`, resolve it, and redirect to the list on 0. The action bodies below that
  line are unchanged — they still work on the internal int.
- Links converted: StaffList (2), StaffProfile (Edit link + the Deactivate form's
  hidden id), EditStaff (3), Inactive (the Reactivate form's hidden id).
- After a save the internal id is what comes back, so `RedirectToProfileAsync`
  reads the row once to get its uuid for the redirect URL.

**Left on int deliberately:** the Attendance / Leave / Payroll links on the
profile page — those controllers still take an int, and Leave/Payroll are
unimplemented stubs anyway.

**Student side NOT wired, and this is the reason:** `Student/Dashboard` and
`Student/EditStudent` are **mock-ups**. Dashboard's JS matches the id against a
hardcoded 10-student array (`students.find(x => x.id === STUDENT_ID)`) and
`EditStudent.cshtml` says "Mock student data — replace with API/ViewBag call";
the POST is a stub. Wiring a uuid into fake data buys nothing and would break the
`x.id === STUDENT_ID` comparison. `core.sp_student_list` already returns
`public_id`, so the column is there and ready — do the wiring when those pages get
a real backend. (`colors[s.StudentId % colors.Length]` in the list also needs the
int, which is why `StudentId` stays on the model alongside `PublicId`.)

**Verified on the local copy** (not Railway): the resolver returns the right id
for the owning school and NULL for wrong school / wrong tenant / unknown uuid;
re-running the migration is clean; and a **named-argument** `CALL` — the shape
Npgsql actually sends — resolves without ambiguity, which is the specific trap
that caused the 42883 outage. Not verified: clicking the pages, which needs a
login against the shared live database.

**And the rule that does not change:** a uuid hides the number, it does not
authorise the request. The `tenant_id`/`school_id` filters in every proc are what
stop one school reading another's data. Anyone who legitimately sees a record can
copy its uuid, so those filters stay regardless of how unguessable the id looks.

---

### [2026-08-25] `public_id` extended to Student, TC and ID Card

Staff proved the pattern; these three follow it. Everything the outside world can
open by URL — a student, a staff member, a printed certificate, an ID card — now
travels as a uuid. Settings-level ids (fee heads, roles, masters) and selector
ids (`academicYearId`, `sessionId`, `classId`, `stateId`) deliberately stay
integers: a token there breaks dropdowns and hides nothing worth hiding.

**One resolver, not four.** The `ResolveStaffIdAsync` written for staff was moved
out of `StaffService` into **`IPublicIdService.ResolveAsync(entity, uuid, tenant,
school)`** with `Student`/`Staff`/`Tc` name constants. Four copies of the same
twenty lines would have drifted; entity names now exist in one place, next to the
guard. `StaffController` was repointed at it, so there is exactly one
implementation.

| Entity | Column | Notes |
|---|---|---|
| Student | `core.students.public_id` | already added in the first migration |
| Staff | `core.staff.public_id` | done previously |
| **TC** | `core.tc_register.public_id` | **new** — the Print branch is `SELECT r.*`, so it picks the column up automatically; only the List projection needed it added |
| **ID Card** | — | **no new column**: `IdCard/Single`'s id is a *student* id, so it resolves through the `student` entity |

**Converted:** `Student` Dashboard / EditStudent (GET + POST) / EnrolmentHistory /
UploadPhoto, `Tc/Print`, `IdCard/Single`. Links: StudentList (2 dashboard links +
2 photo buttons), Dashboard, EditStudent (4), Tc/Register (the Print link).

**Left on int on purpose:**

- `Student/Exit` and `Tc/Void` — the id rides in a **JSON body**, not a URL, and
  both are already tenant-scoped. Nothing leaks by browsing.
- `colors[s.StudentId % colors.Length]` in the list needs a number, which is why
  `StudentId` stays on the model beside `PublicId`.
- `Areas/ERP/Views/Admission/Dashboard.cshtml` is an orphan — no action renders
  it — so it was left untouched.

**Note on the pages themselves.** `Student/Dashboard` and `EditStudent` are still
**mock-ups** (a hardcoded 10-student array; the POST is a stub). Only the session-
history card reads real data. The uuid plumbing is now correct and the URLs are
clean, but do not read "student dashboard works" into this — the page still shows
mock content until it gets a real backend. `UploadPhoto` and `EnrolmentHistory`
are real and do work.

**Verified on the local copy:** the student uuid resolves to its real id through
`sp_resolve_public_id` using a **named-argument** CALL (the shape Npgsql sends),
wrong school returns NULL, the `tc` branch executes, and an unknown entity raises
`22023`. The local copy holds no TC rows, so the TC path is verified as SQL but
not against real data. Build: 0 errors.

**Deployment order is unchanged and still matters:** run
`public_id_students_staff.sql` (now also touching `core.tc_register`), then
`transfer_certificate.sql` / `student_list.sql` / `staff_list.sql` /
`sp_staff_manage.sql`, and only then deploy the app. Reversed, every converted
link resolves to `Guid.Empty` and bounces to the list page.

---

### [2026-08-25] A stale duplicate of sp_dropdown_common, deleted before it fired

Two scripts in `Database/` defined **the same procedure**,
`config.sp_dropdown_common`:

- `reference_data_lookup.sql` — the current one, and what the database actually
  runs (verified against both local and Railway).
- `dropdown_academicyear_current_first.sql` — an older revision of the same proc,
  referenced by nothing.

The old one is missing two things the live version has:

    AND tenant_id = v_tenant AND school_id = v_school   -- multi-tenant scope

on both the AcademicYear and Class branches, and the Class de-duplication
(`GROUP BY class_name ... ORDER BY MIN(display_order)`) that stops the list
reading "1st, 1st, 2nd, 2nd" once a school has a second session.

Nothing was broken — but running that file, which looks like a perfectly
reasonable thing to do when re-applying scripts, would have `CREATE OR REPLACE`d
the good version with one that shows **every school's** sessions and classes in
every school's dropdowns. A loaded gun in the scripts folder. Deleted; git keeps
the history, and `reference_data_lookup.sql` is a strict superset (same
current-session-first ordering and `IsSelected` flag).

**The lesson worth keeping:** the repo is not automatically the source of truth
for what a proc does. This one drifted because a later fix edited a different
file. Before reasoning about proc behaviour, read it from the database
(`pg_get_functiondef`), not from whichever `.sql` happens to have a matching
name — and when two scripts define one proc, delete the loser rather than
leaving both.

---

### [2026-08-25] Promote Students — the validation ran too late to help

The page worked, but only if you already knew what it wanted. Five problems, all
of them the same shape: the page knew something was wrong and told you at the
worst possible moment.

**1. The default state was invalid.** Both session selects are built from the
same list and the current session is ordered first, but only `srcYear` carried
`selected`. So the page opened with From and To both set to the current session —
a combination that can never run. `initTargetYear()` now picks the first session
that is not the source.

**2. And if there is no other session, it now says so.** A school with a single
academic year (which is the common case early on) had no way to learn that
promotion is impossible for it yet — the page looked ready. It now disables the
button and points at Settings → Academic Year.

**3. The confirm modal opened before anything was checked.** `reviewBtn` carried
`data-bs-toggle="modal"`, so Bootstrap opened it unconditionally; every check
lived in the commit handler. Clicking "Confirm & Promote" with nothing selected
fired a toast *behind* the open modal and left it sitting there — which reads as
"the button is broken". The toggle is gone, `validate()` runs first, and failures
render inline above the buttons where the user is already looking. The commit
handler keeps the same check as a backstop, because the roster stays interactive
while the modal is open.

**4. Unticking "carry forward dues" silently dropped people.** It does not mean
"promote them and clear the dues" — the proc *skips* every student who owes money
(pass-outs excepted). The page already knows each student's dues, so the confirm
modal now says "N selected student(s) have pending dues and will be skipped"
before the office commits, rather than after.

**5. The skipped list vanished.** The proc names everyone it could not move —
pending dues, already left, not in the source session, already in the final class
— and that list is a work queue for the office. It was being shown in a toast
that disappears in 3.5 seconds. There is now a Promotion Result card that stays
on the page, one name per line, with a Dismiss button.

Also: `.fail()` said "Something went wrong." for every failure. It now separates
an expired antiforgery token (400), an expired session (401), a permissions
problem (403) and an unreachable server, and always says that nothing was
changed.

No backend change — the proc's validation was already thorough and correct; this
is entirely about surfacing it at the right moment.

**Checked the way this repo has to check views:** `dotnet build` reports 0 errors
on a `.cshtml` whose `<script>` is broken, so the block was extracted, its Razor
expressions stubbed, and run through `node --check`; and every id the script
looks up (40 of them) was matched against the markup.

---

### [2026-08-25] Promotion: the Class list ignored the session, and one class could graduate itself

Two related problems on the same page, found by asking a simple question — is the
Class dropdown tied to the Academic Year? It was not.

**1. The Class list was session-less.** It came from the shared
`config.sp_dropdown_common` 'Class' activity, which deliberately collapses every
session's classes to one row per name so filters on past sessions keep working.
Right for the directory, wrong here. School 33 shows why:

| session | classes |
|---|---|
| 2027-2028 | 1st, 2nd, 3rd, 4th, 5th, 6th |
| 2028-2029 | **2nd only** |

With the source set to 2028-2029 the dropdown still offered all six; picking any
of the other five returned an empty roster with no explanation. New
`Student/PromotionClasses(year)` returns the class **ladder** for the chosen
session — that list already exists and is in teaching order — and the dropdown is
refilled whenever the source session changes. The shared dropdown proc was left
alone on purpose: other pages depend on its session-less behaviour.

**2. `nextClass()` conflated "final class" with "class not in the target
session".** Both returned `null`, and `defaultOutcome()` reads `null` as *Pass
Out*. So loading a class the target session did not contain pre-selected **Pass
Out for every student on screen** — and Confirm would have graduated a whole
class instead of promoting it. The bulk "promote all" button had the same
conflation. `nextClass` now returns the class name, `null` for a genuine final
class, and `undefined` for not-in-target; only `null` means Pass Out.

**The correction worth recording:** the first version of this fix blocked any
class missing from the target session. That was wrong, and re-reading the proc is
what caught it — it takes the student's `display_order` from the **source**
session and moves them to the first higher class that exists in the **target**,
so 1st → 2nd is valid even when the target holds only 2nd. Blocking it would have
stopped a legitimate promotion. Now only a class in **neither** ladder is an error
(the proc genuinely cannot place those); a class present in the source but not the
target is normal and the preview says "Set by session" rather than inventing a
target class the page cannot actually compute — `display_order` is not exposed to
the client, so guessing it would sometimes be wrong.

Verified against the real ladders: `core.sp_class_ladder` returns
`1st 2nd 3rd 4th 5th 6th` for 2027-2028 and `2nd` for 2028-2029 on the same
school. View checks as before — extracted script through `node --check`, all ids
matched, every `Url.Action` target confirmed to exist on the controller.

---

### [2026-08-25] Promotion: a checkbox that lied, and a preview that guessed

**The fee checkbox did not do what it said.** "Carry forward pending fee dues to
the new session" described an action that does not exist. `p_carry_dues` appears
in exactly one place in the whole proc:

    IF NOT p_carry_dues AND v_dues > 0 AND v_outcome <> 'PassOut' THEN
        v_skipped := ... (pending dues);  CONTINUE;

There is no ledger write anywhere — the proc's own comment explains why: *"The
ledger is not year-scoped, so dues follow the student no matter what."* So
ticking it did nothing at all, and unticking it quietly **held students back**.
On the page it was worse: the `carry` variable was assigned in `render()` and
never read — a dead variable, so toggling the box changed nothing on screen
either. Which is exactly why it looked broken.

Relabelled to what it actually controls — **"Promote students who still owe
fees"**, with a line saying dues follow the student either way and nothing is
written off. The dead variable is gone. The wire name stays `carryDues` to match
`p_carry_dues`; the model property now carries a comment saying what it really
means.

**The "next class" preview was guessing, so it stopped guessing.** The page only
had class *names*, while the proc works in `display_order`: it takes the order
from the SOURCE session and moves the student to the first class in the TARGET
session with a higher order. With names alone that is not computable, which is
why the previous pass showed "Set by session" as an honest placeholder.

`core.sp_class_ladder` now returns `display_order` alongside `class_name`
(additive; existing consumers read by name), the page carries both ladders as
`[{name, order}]`, and `nextClass()` does the proc's computation exactly. The
preview also shows the **section** now — the chosen one, or the student's own
when "Keep same section" is selected, which is what `COALESCE(v_sec, s.section)`
does — so a row reads "3rd – A". Changing the section dropdown redraws it.

Verified by running the page's own `nextClass()` in node against the real ladders
of a school whose two sessions differ (2027-2028 holds 1st–6th, 2028-2029 holds
only 2nd):

| class | page says | proc does |
|---|---|---|
| 1st | 2nd | order 1 → first target class above 1 → 2nd |
| 2nd | final class → Pass Out | no target class above 2 → skip "mark Pass Out" |
| 6th | final class → Pass Out | same |
| Nursery | in neither session → blocked | would skip "not in the session setup" |

**Still not supported, deliberately:** moving one student two rungs (1st → 3rd).
The target class is computed in the proc and not accepted from the page, so this
needs a signature change plus per-student validation. Today's workaround is to
promote normally and then edit that student.

---

### [2026-08-25] Promotion: moving a student more than one class up

Until now the target class was always the next rung, computed inside the proc and
not accepted from the page. A student who needed to jump (1st → 3rd) had to be
promoted normally and then edited by hand.

**The signature did not have to change**, which is the whole reason this was safe
to do. `p_students` is already `jsonb`, so the per-student class rides inside the
existing payload as a new key:

    [{"studentId": 53, "outcome": "promote", "toClass": "7"}]

`jsonb_to_recordset` simply yields NULL for `toClass` when an older build omits
it, so the deployed app kept working while this went out — no shim, no 42883.
A new parameter would have needed one.

**Guard rails, because a bulk screen is the wrong place to be loose.** A chosen
class must exist in the TARGET session, and must be strictly **above** the
student's current one. Moving a student *down* is a correction, not a promotion,
and belongs on that student's own page where it is one deliberate act rather than
something buried in a run of forty.

On the page, the Next Class cell becomes a picker offering every class above the
student, defaulting to "Next (X)". It only appears when there is actually a
choice to make (two or more classes above them) and only for a *promote* outcome
— switching a student to Retain or Pass Out drops their chosen class. No
re-render on change, so picking a class on a long roster does not throw away the
user's scroll position.

Verified against real data on the local copy, inside a transaction that was rolled
back (school 34 has one session, so a second one was created for the test):

| sent | result |
|---|---|
| `toClass: "7"` from class 5 | promoted straight to **7** |
| `toClass: "2"` from class 5 | refused — *"2 is not above 5"* |
| `toClass: "12th"` | refused — *"chosen class 12th is not set up in FY 27-28"* |
| no `toClass` at all | auto next rung → **6** (old payload still works) |

Applied to local and Railway.

---

### [2026-08-25] Fees: a back-dated admission billed ten years of tuition

Found by looking at live data, not by reading code: the school's one active
student had **481 ledger rows totalling ₹4,29,000**, against a fee plan worth
about ₹42,000 for the year.

    admission_date : 2017-04-20
    session        : FY 26-27  (2026-04-01 .. 2027-03-31)
    monthly charges: Apr 2017 .. Mar 2027   = 120 installments, not 12

`core.sp_admission_manage` bills monthly heads from the admission month up to the
session end month. That rule exists for a **mid-session joiner** — admitted in
August, bill Aug–Mar — and it is correct for that. But when the admission date is
*earlier than the session*, the same rule walks backwards: an existing student
carried forward, or a back-dated entry, gets billed every month since they first
joined. Ten years here, and it scales with how old the admission date is.

Fix: clamp the first billing month to the session start. A session can now only
ever bill its own months.

    IF v_sess_start IS NOT NULL AND v_month_start < DATE_TRUNC('month', v_sess_start)::DATE THEN
        v_month_start := DATE_TRUNC('month', v_sess_start)::DATE;
    END IF;

Verified on the local copy, in a rolled-back transaction, that the fix does not
break the case the rule was written for:

| admitted | installments | range |
|---|---|---|
| 2017-04-20 (back-dated) | **12** (was 120) | Apr 2026 – Mar 2027 |
| 2026-08-10 (mid-session) | 8 | Aug 2026 – Mar 2027 — unchanged |
| 2026-04-05 (normal) | 12 | Apr 2026 – Mar 2027 |

Applied to local and Railway.

**This matters most for migration.** Today it affects one student, but every
existing student imported with their real admission date would have been
over-charged the moment their fee plan was applied — which is exactly what a
school does when it starts using the system.

**The existing bad data is a separate decision.** Student 53 has 433 rows dated
before the session (₹3,87,000) and 48 correct ones (₹42,000). Nothing has been
paid, conceded or refunded against any of them, so the bad rows carry no payment
history — but deleting rows from a live fee ledger is the school's call, not a
side effect of a code fix.

---

### [2026-08-25] Student Dashboard and Edit Student, off the mock data

Both pages looked finished and neither was. Edit Student could not save at all,
and the Dashboard filled seven tabs from a hardcoded array of ten students plus
`Math.random()`.

**Edit Student had no save path, and that was not a stale TODO.**
`sp_admission_manage`'s `SaveAdmission` is INSERT-only — there is no update
branch — so the controller's "replace once the SP is ready" comment was accurate.
New `core.sp_student_update` provides it.

What it deliberately does **not** touch:

- **the fee plan and `core.student_ledger`.** Changing what a student owes is a
  money operation and belongs in the fee module, where it leaves a concession or
  adjustment trail. Regenerating the ledger from an edit screen would wipe paid
  installments. Verified in a rolled-back transaction: 481 ledger rows before the
  update, 481 after.
- **`admission_no`** — the school's permanent reference, printed on receipts and
  the TC. Re-issuing one is not an edit.

Guards, both verified: another school's student id raises "Student not found"
(indistinguishable from a bad id), and a class that is not in the school's setup
is refused by name rather than leaving the student on a class no roster,
timetable or promotion ladder knows about.

**The mapper was also quietly incomplete.** `GetStudentByIdAsync` selects `s.*`
but only read about half the columns, so blood group, religion, category,
nationality, ID proof and previous school could never be shown or edited — they
were in the result set the whole time. Now mapped.

**Dashboard.** The mock roster and `getDetail()` are gone. A new
`Student/DashboardData` returns the student, the fee ledger and the receipts in
one call; `buildDetail()` shapes it into the keys the existing render functions
already used, so nothing below the data layer changed.

**Three tabs now say they have no data instead of inventing it.** Attendance,
Timetable and Exam Results have no per-student getter yet. They used to show
`rand(1,40)` ranks, random subject marks and a randomly generated weekly
timetable — numbers that read as real and were not. They now render one line
saying the data is not wired up. A blank with a reason is worth more than a
convincing fabrication, and it stops anyone making a decision on a random number.

Also fixed on the form: three field names never bound to the model
(`AadharNo`→`IdProofNo`, `PreviousSchool`→`PrevSchoolName`, `Email`→
`FatherEmail`), so those inputs silently discarded what was typed; the class list
was a hardcoded CBSE ladder rather than the school's own classes; sections did
not follow the chosen class; and a hidden `StudentId` posted a uuid into an int
property. The id now comes only from the URL — a form field could otherwise name
a different student than the one the URL authorised.

Checked as views have to be checked here: `dotnet build` reports 0 errors on a
`.cshtml` with a broken `<script>`, so both script blocks were extracted, their
Razor stubbed, and run through `node --check`; all 50 element ids the two scripts
look up were matched against the markup; and every `Url.Action` target confirmed
to exist on the controller.

---

### [2026-08-25] Per-student attendance, and the number that must not be invented

`core.sp_attendance_month_register` answers "the whole class, one month" — the
register grid. The Student Dashboard needs the other axis: one student, a whole
session. New `core.sp_attendance_student` returns three cursors — a session
summary, the months that have a register (for the picker), and the day marks for
one month (the calendar).

**It follows the register's conventions exactly**, so the two screens can never
disagree about the same student:

- a **school day** is a day a register was actually taken for that class
  (`COUNT(DISTINCT attendance_date)`), not a calendar day;
- Sundays are excluded (`EXTRACT(DOW) <> 0`);
- status folds the same way — Absent → A, Leave → L, Present and Late both → P.

**The rule that drove the design: a day nobody marked is not an absence.** The
percentage is computed over days the student's own class actually held a
register, so a student who joined in August is not marked down for July, and a
class whose register was never taken shows "No attendance has been marked for
this class yet" rather than a red 0%. The calendar draws an unmarked day as a
blank with the tooltip "No register", never as absent.

Verified on seeded data — 24 school days in April 2026 (Sundays excluded), 20
present, 3 absent, 1 leave → **83.3%**, and the day grid skipped the 5th, 12th,
19th and 26th correctly.

**Subject-wise attendance was deleted rather than left empty.**
`core.student_attendance` holds one row per student per day, with no period or
subject column — there is nothing to group by. That table was being filled with
invented numbers. It comes back if attendance is ever taken per period.

Timetable and Exam Results still say they are not wired; neither has a
per-student source yet.

---

### [2026-08-25] The student's timetable is their section's

No new SQL for this one — `GetSetupAsync` (periods, days, sections) and
`GetGridAsync(sectionId)` already existed for the timetable editor. The only
missing piece was the link from a student to a section: the dashboard resolves
class + section against the setup's section list, then reads that section's week.

**Three states, and the page distinguishes all three** — the old version drew a
randomly generated week for every one of them:

| situation | what it shows |
|---|---|
| class/section not in the timetable setup | "does not appear in the timetable setup, so there is no week to show" |
| set up, but no periods defined | "No periods have been set up yet (Settings → Period Structure)" |
| set up with empty slots | the real grid, with — in the unfilled cells |

Also better than the mock it replaced: period rows come from the school's own
**Period Structure** (real times, e.g. 08:00–08:45) rather than a hardcoded
eight-period day; a **break or lunch row spans the week** instead of drawing
dashes under every day, because it is not a subject; and today's column is
highlighted off `getDay()` matched against `TimetableDay.DayOfWeek` — both use
0 = Sunday — rather than the old `getDay()-1` arithmetic that put the star on the
wrong column on Sundays.

The week is indexed into a `dow:seq` map once instead of scanning the entry list
per cell, which is O(n²) on a full grid.

Exam Results is the last tab still saying it has no source; there is no
per-student marks getter yet.

---

### [2026-08-25] Exam results per student — and the Dashboard is off the mocks entirely

`core.sp_exam_result_student` is the last of the three per-student getters: one
student, every subject of one exam, plus the list of exams to pick from.

Two rules the schema itself argued for:

**Published exams only.** `academic.exams.status` is `'Draft'` until the school
publishes, and a draft is a sheet a teacher is still typing into — half-entered
marks are not a result. Marks Entry is where unpublished work belongs; this is
the parent-facing view. Verified: a Draft exam with marks in it does not appear
in the picker at all.

**Absent is not zero.** The table already says so —
`CHECK (NOT (is_absent AND marks_obtained IS NOT NULL))` forces marks to be NULL
when absent. So an absent subject is reported as absent, excluded from the totals
and the percentage, and counted separately. One missed paper does not read as a
failed one. Verified on seeded marks: 78/100, absent, 10/50 → **2 subjects,
88/150, 58.7%, 1 absent, 1 failed** — the absent subject's 100 max marks are not
in the denominator.

`passed` is deliberately **tri-state**: true, false, or null when it cannot be
said (absent, or the exam has no pass mark configured). Null is not "failed".

**What was deleted rather than faked**, continuing the pattern of the last three
commits:

| removed | why |
|---|---|
| Grade column | no grading scale exists in settings; a letter would be invented |
| Class Rank column, "Class Rank" metric | ranking needs every classmate's marks, which this page does not fetch. It was `rand(1,40)` |
| Previous Exam Comparison table | needs two exams side by side; the picker already lets you look at either |
| Academic tab's term chart + grade table | the exam module records marks per EXAM, not per term — "Term 1 / Term 2 / Annual" never existed |
| Overview's "last payment"/"last absent" activity | both were hardcoded dates |

The Academic tab now lists the student's published exams and their current
placement; the Overview's subject bars come from the latest published exam's real
marks, skipping absent subjects rather than drawing them as zero-length bars.

**With this, no tab on the Student Dashboard renders invented data.** Every
render function reads from `Student/DashboardData`, and the dead `notYet()`
placeholder is gone because nothing needs it any more.

---

### [2026-08-25] Leave and Payroll — two pages that had no backend at all

Both screens were fully designed and completely inert: Apply, Approve, Reject,
Run Payroll and Mark Paid each set a TempData message and changed nothing. Zero
service calls between them. This builds the modules.

**`core.staff_leave` + `sp_staff_leave_manage`** (LIST / APPLY / DECIDE)

- **Days exclude Sundays**, via a new `core.fn_working_days` — the same rule the
  attendance register uses. A Monday-to-Saturday leave is 6 days, not 7. The
  modal's day preview was recomputed in the browser to match; it previously used
  a plain date subtraction and would have shown 7 where the server saved 6.
- **Overlap is refused.** Two live requests over the same day would be charged
  twice by payroll and almost always mean a duplicate entry.
- **A decided request cannot be decided again** — approve/reject record who and
  when, and a second decision would overwrite that.

**`core.staff_payroll` + `sp_staff_payroll_manage`** (LIST / RUN / MARK_PAID)

- **Gross is snapshotted** from `core.staff.monthly_salary` onto the payroll row.
  A later salary revision must not silently rewrite a payslip the school has
  already issued — that is why the amount is stored rather than joined.
- **LOP is approved `'Unpaid'` leave** overlapping the month, counted through the
  same `fn_working_days`. A *pending* unpaid leave costs nothing until someone
  approves it. That one leave type is the entire link between the two modules —
  deliberately not a separate LOP register that could drift.
- **Per-day rate is gross ÷ working days in THAT month**, not a flat 30.
  February days are worth more than July days and staff notice.
- **A paid month cannot be re-run**; those rows are reported as skipped. One row
  per staff per month is a unique index, not a convention.

End-to-end on real data, rolled back:

| step | result |
|---|---|
| apply Mon 1 – Sat 6 Jun | **6 working days** (Sunday excluded) |
| overlapping application | refused |
| payroll with the leave still **pending** | LOP 0, net full ₹30,000 |
| after approving | LOP 6, rate ₹1153.85 (30000 ÷ 26), net **₹23,076.90** |
| deciding twice | refused |
| re-run after Mark Paid | "5 generated. 1 already paid and left untouched." |
| paying twice | refused |

**What the payroll page no longer pretends to know.** The mock split pay into
basic / HRA / DA / conveyance / medical / special and deducted EPF, ESI,
professional tax and TDS computed off **hardcoded income-tax slabs**. None of
that is configured anywhere: `core.staff` holds one `monthly_salary`, and there
is no salary-component or statutory-rate table. Slabs baked into a page would be
wrong for most schools and stale after any budget. The payslip now shows what
the school actually recorded — gross, Loss of Pay, net — and the CSV export
matches, instead of exporting four columns computed in the browser and stored
nowhere.

**Noted while here:** `StaffProfile.cshtml` links to `Attendance/StaffAttendance`,
which does not exist. There is no staff attendance register at all, which is why
LOP is derived from leave rather than from absences.

---

### [2026-08-25] The landing dashboard — the most-seen page in the app was entirely fake

`DashboardsController` was twelve lines with no service call, and every figure in
its 576-line view was a literal. Every school saw the same **₹13,201** collected
today, the same **₹1,41,912** outstanding, the same four invented notices and the
same three birthdays. This is the first page after sign-in.

New `core.sp_dashboard_summary` returns nine cursors in one round trip — a dozen
cards would otherwise be a dozen calls on every sign-in.

**Now real:** the four KPI cards, the greeting banner, today's attendance gauge,
the 7-day collection trend, class strength, collection by payment mode, top fee
defaulters, recent receipts, pending leave approvals, upcoming calendar entries,
birthdays (students and staff, matched on day+month so leap years do not matter),
and the Student Fee Matrix — whose rows now link to the real student dashboard.

**Removed rather than faked**, the same rule as the last few commits:

| card | why it is gone |
|---|---|
| Income vs Expense | there is no expense module; half the chart could only be invented, and income alone under that title misleads |
| Collection Target | no target is configured anywhere, so the ring was progress towards a made-up number |
| Notice Board | no notices table, and its Post button linked to /ERP/NoticeBoard, which does not exist |
| Student/Staff/Due sparklines | those totals are not snapshotted anywhere, so seven points of history were pure invention. The collection sparkline stayed — the 7-day trend is real |
| "Due Cleared" trend series | a second invented line on the collection chart |
| Week / Month / Download buttons | never wired to anything |
| Approve + Reject buttons on approvals | both just opened the leave page — two buttons that looked like decisions. One "Review" link now |
| "Wish" button on birthdays | there is no message to send and no record of sending one |
| Staff attendance bar | there is no staff attendance register at all |

**Conventions kept in step with the rest of the app:** a cancelled receipt is
never counted as collection; outstanding comes from `core.student_ledger` and is
never recomputed from payments; and today's attendance is a percentage of
students *actually marked*, because a class nobody marked is not a class that was
absent — the card says so when nothing has been marked, instead of showing 0%.

The KPI trend lines say only what can be supported. "+12.5% vs yesterday" is now
"nothing collected yesterday" on a day that is true.

---

### [2026-08-25] Fee module: a test suite, and what it found

`Database/tests/fee_module_tests.sql` — 28 checks over ledger generation,
collection, cancellation, the collect-at-admission allocation and receipt
numbering. It runs in one transaction and **rolls back**, so it is safe to point
at any database; it was run against both the local copy and Railway.

Each check prints PASS/FAIL with the numbers behind it, so a failure says what it
expected and what it got rather than just stopping.

**What it found.**

**1. Receipt numbers were malformed for most schools.** The number was built as

    v_year := left(COALESCE(NULLIF(trim(p_fin_year),''), to_char(v_date,'YYYY')), 4);

— the first four characters of the session **name**. That only works if the
school happens to call it "2026-2027". This school calls it **"FY 26-27"**, so
every receipt read:

    RCP-FY 2-0001

A space in the middle of a number handed to a parent, and a prefix that means
nothing. It is also the key of `core.receipt_counters`, so the sequence hung off
a truncated label. New `core.fn_receipt_year` resolves it the way a human would:
the session's own `start_date` year, else a four-digit run in the name, else a
two-digit run read as 20xx, else the payment date. Verified across all four
paths. Receipts now read `RCP-2026-0001`. **Existing receipts are not
renumbered** — a receipt number is printed, filed and quoted, and rewriting old
ones would break every reference to them.

**2. `sp_fee_payment_collect` exists as TWO overloads in the database** — a
16-parameter one from `fee_payment_tenders.sql` and a 17-parameter one (with
`p_advance_used`) from `fee_advance.sql`. The app calls the 17-param version.
This cost real time: the fix was applied to the wrong one first, and the tests
kept failing while the proc looked fixed. Both are now marked in their files
saying which is which and that a change to collection logic has to be made in
both. Three further files hold superseded revisions of the same proc and are
marked SUPERSEDED, so re-running one cannot silently downgrade the live proc —
the same loaded-gun problem as the `sp_dropdown_common` duplicate.

**What the suite confirmed is already right**, which is most of it: the
back-dated-admission fix holds (9-year-old admission date still bills 12 months,
mid-session joiner bills 8); overpaying a line, a negative amount, an empty
selection and a cross-school collection are all refused; a concession is recorded
on the row without cash moving; cancelling a receipt puts the ledger back exactly
and a second cancel reports failure without reversing twice or overwriting the
audit trail; the admission-point charge is settled before scheduled dues; and no
ledger row anywhere ends up over-paid or negative.

**A note on C4.** The first version of that test asserted that cancelling twice
*raises*. It does not — it returns `success = false` with "Receipt not found or
already cancelled", which is the better design: already-cancelled is a state, not
an error. The test was wrong, not the code, and it now asserts what actually
matters — that the ledger is not reversed twice and the original cancel reason
survives.

---

### [2026-08-25] Enquiry + Registration test suite

`Database/tests/enquiry_registration_tests.sql` — 30 checks over the enquiry CRM,
follow-ups, registration and the enquiry → registration → admission chain. Same
shape as the fee suite: one transaction, rolled back, safe against any database.
Run against local and Railway — 30 passed on both.

**What it found: a revived lead kept the reason it was once lost for.**
`UpdateStatus` wrote

    lost_reason = CASE WHEN p_status IN ('Not Interested','Dropped')
                       THEN COALESCE(p_lost_reason, lost_reason)
                       ELSE lost_reason END          -- <- kept the old value

so an enquiry marked "Not Interested — too far" and later moved back to
Interested still carried "too far", and would still carry it after being
admitted. `lost_reason` on the row means *why this enquiry is lost right now* —
the full trail already lives in `core.enquiry_status_history`, which is what that
table is for. Nothing displays the stale value today, but the first
why-do-we-lose-leads report would have counted won students among the losses.
Fixed in both branches that write it (`SaveEnquiry` and `UpdateStatus`).

**What the suite confirmed is already right:**

- an enquiry is created as New and active, and is invisible to another school;
- every status change is written to `enquiry_status_history` with what it came
  *from*, and re-setting the same status adds no duplicate row;
- a follow-up is logged and its next date is carried onto the enquiry;
- registration mints a number, stamps the date, and **re-registering returns the
  same number** rather than minting a second;
- another school cannot register your enquiry, and asking for a number with
  auto-generate off and none supplied is refused;
- the registration fee books against the **enquiry**, not a student — there is no
  student yet — and its receipt number now has no space (the same
  `fn_receipt_year` fix as the fee module);
- admitting from an enquiry links the two, and after that the enquiry can be
  neither re-registered nor have its status walked backwards from
  "Admission Confirmed".

**Note on writing these:** `sp_enquiry_crm_manage` takes **53 parameters**. The
first version of the suite called it positionally and was unreadable and wrong;
it is now called with named arguments throughout, which also survives a parameter
being added in the middle.

---

### [2026-08-25] Attendance + Exam test suite

`Database/tests/attendance_exam_tests.sql` — 28 checks. Same shape as the other
two: one transaction, rolled back, safe against any database. **28 passed on
local and Railway, with nothing to fix** — both modules hold up.

**Attendance guards, all confirmed:** a future date is refused (nobody knows who
will turn up tomorrow); **Sundays are refused**, the same definition of a school
day the leave module, payroll and the per-student view all use; a date past the
school's back-date window is locked, so last term's absence cannot be quietly
rewritten; and an empty register is refused rather than silently recording
nothing.

**One row per student per day** is a unique index, and re-saving a day
**corrects** rather than duplicating — a teacher fixing a mistake does not leave
two rows for one child on one day.

**The rule that matters most, verified twice:** a day nobody marked is not an
absence. A student marked present on the one day their class took a register
reads **100%**, not 1/30th. A student whose class has never taken one reads
"0 school days" rather than a red 0%.

**Exam marks:** marks above the paper's maximum and negative marks are both
refused by name; an absent student is flagged absent and stored with **NULL
marks, not zero**, which the table's own CHECK constraint insists on; a finalised
sheet is locked with a message telling the teacher to ask for a reopen; and
reopening lets the edit through.

**Per-student results:** a **Draft** exam does not appear at all, and an absent
paper is counted as an absence and left out of both the numerator and the
denominator — a student absent in their only subject shows 0 out of 0 rather than
a 0% that reads like a fail.

**Two notes on writing it.** The absent flag is sent as `"absent"`, not
`"isAbsent"` — the test had it wrong and four checks failed in a way that looked
like a product bug; `ExamService` had it right all along. And the suite picks its
own test date (yesterday, or the day before if that is a Sunday) so it stays
inside whatever back-date window the school has configured rather than assuming
one.

Three suites now exist and can be run at any time:

    Database/tests/fee_module_tests.sql             28
    Database/tests/enquiry_registration_tests.sql   30
    Database/tests/attendance_exam_tests.sql        28

---

### [2026-08-25] Transport + TC + ID Card test suite

`Database/tests/transport_tc_tests.sql` — 31 checks. **31 passed on local and
Railway, nothing to fix in the product.** Two of the tests were weak and were
strengthened; that is the whole finding.

**Transport:** a route needs a name; a stop carries its own fare, so assigning a
student to the far stop bills 6 × ₹900 rather than a flat route rate; an unknown
stop is refused (nobody ends up on a bus that does not run); and re-assigning
leaves exactly one active row rather than putting a child on two buses.

**Removing an assignment does the right thing in two directions**, which is the
part worth having a test for: the month already **paid** for survives — taking a
child off the bus does not unbill the months they rode — while the unpaid future
months are **dropped**, so nobody is chased for a bus they no longer take.

**TC gates, all enforced:** a still-enrolled student is refused ("mark them as
left first"); a student with an unpaid balance is refused by amount ("Clear the
pending dues of 2,500.00"); only one live certificate per student, with a second
attempt told to use reprint instead.

**The TC is a frozen snapshot** — renaming the student afterwards does not change
the issued certificate, which is the whole reason `tc_register` copies the
student's details rather than joining to them.

**Print and void:** the first print is counted and a reprint increments it, which
is what stamps a copy as DUPLICATE; voiding retires the number rather than
deleting the row, so a mistaken certificate leaves a trail; voiding twice is
refused; and after a void the student is eligible for a fresh certificate.

**ID cards** come back for the class roster, exclude a student who has left, and
return nothing at all to another school.

**What the failure actually taught.** D3 ("TC refused while dues are pending")
failed at first, and the gate looked broken. It was not: the test issued the TC
to the bus rider whose dues had just been deleted by `RemoveAssignment` two
sections earlier. The test now uses a student with a real unpaid balance. And
C2 was worse than wrong — it asserted `chk(..., TRUE, ...)`, which passes
unconditionally. It now pays one month, removes the assignment, and checks both
halves separately.

Four suites now exist, 117 checks in total:

    Database/tests/fee_module_tests.sql             28
    Database/tests/enquiry_registration_tests.sql   30
    Database/tests/attendance_exam_tests.sql        28
    Database/tests/transport_tc_tests.sql           31

---

### [2026-08-25] Page-by-page audit — CSRF gaps and three dead procedures

`educore/docs/PAGE-CHECKLIST.md` — all 64 pages, each rated on whether it shows
real data, whether the **server** refuses bad input, whether every read and write
is tenant-scoped, whether mutating POSTs carry an antiforgery token, and whether
a test suite covers it. The open TODOs live there too.

The audit was mechanical, not by eye: one script walks every controller and
flags any `[HttpPost]` without `[ValidateAntiForgeryToken]` or without a
permission gate; one query walks every mutating proc and flags any without
validation or without a tenant filter. Both are in the doc so the audit can be
re-run rather than re-done.

**Found: five settings mutations had no CSRF protection.** `SaveClassSection`,
`SaveAcademicYear`, `SetCurrentAcademicYear`, `DeleteAcademicYear` and
`SavePeriodStructure`. Two of the three views were already sending the token, so
only the attribute was missing; the Academic Years page was not sending one at
all and now does. 86 POST actions were audited; these five were the only gaps.

**Found: three procedures nothing calls.** The query flagged them as having no
validation, which was true, but the real problem was that they were dead:

- `core.sp_admission_manage1` — an orphaned copy of the admission proc from a
  rewrite. It predates the back-dated-admission fix, so it still bills a student
  every month since they joined.
- `config.sp_role_permission_management` — reached only by `RolePermissionService`,
  which was never registered in DI. The live path is `config.sp_role_manage` +
  `sp_role_permissions_save`, both scoped and validated.
- `core.sp_school_user_management` — creates and updates **logins**, with no
  scope guard, called by nothing.

Dropped in both databases, and the dead service, contract and DTO deleted.
Leaving them was the risk: each looks like live security surface, and the next
person needing "save role permissions" or "create a user" would reasonably wire
one up and inherit its missing guards — the same trap as the superseded
`sp_fee_payment_collect` revisions and the stale `sp_dropdown_common`.

**Two false positives worth recording**, because the next person running the
audit will hit them: `SchoolsController.Create/Edit/Purge` look ungated but the
class carries `[Authorize(Roles = SuperAdmin)]`; and `Account.ContinueAs`,
`VerifyOtp` and `Logout` are part of the login flow and cannot require an
authenticated user. Likewise a proc with zero `RAISE EXCEPTION` is not
automatically unguarded — several report a refusal as `success = false` with a
message, which is the better shape for "already cancelled".

All four suites still pass on both databases after the removals: 28 / 30 / 28 / 31.

---

### [2026-08-25] Admission Workflow test suite, and the menu flag it was ignoring

`Database/tests/admission_workflow_tests.sql` — 23 checks. These settings are a
school's on/off switches, and getting one wrong does not throw: it quietly
changes what the school is billed or what its office can reach.

**Found: the Registrations menu item ignored its own toggle.** The menu reads
five module flags' worth of settings but gated only four of them — Transport,
Exams, Inventory and Payroll each hid their section, while `enable_registration`
was honoured by the Registration *page* and ignored by the menu. A school that
switched registration off still saw "Registrations" in the sidebar, leading to a
page that had been turned off. Now gated the same way as the other four.

**Confirmed correct — `charge_fees_from`, the setting with real money behind it.**
Same student, same plan, same joining date, only the policy differs:
`SessionStart` bills all 12 months of the session; `AdmissionMonth` bills 7, from
the month they actually arrived. And under either policy a back-dated admission
still bills 12 months, never one per month since 2017 — the regression guard for
the back-dating bug, now checked from the settings side too.

Also confirmed: settings round-trip through the proc the app actually calls; a
second save updates rather than inserting a second row; dependent flags collapse
(registration off leaves neither "required before admission" nor a registration
fee set); another school's row is untouched; and a platform-scope write is
refused.

**Two things pinned rather than changed.** A save that leaves a module flag NULL
resets it to ON, because the proc reads `COALESCE(p_enable_x, TRUE)` and cannot
tell "no opinion" from "switch it on". The app never hits this — the form posts
all five (`asp-for` on a bool emits the hidden false companion) and the service
sends plain bools — so check B7 documents the behaviour instead of a speculative
fix, for whoever later adds a quick-toggle endpoint. And
`RegistrationFeeAmount` / `SecurityFeeAmount` are dead: on the model and in the
table, but no view field, no proc parameter, no reader. The registration amount
is typed at collection time; the security amount comes from the fee head.

**A note on writing it:** the first run failed three module-flag checks and it
looked like the flags were not saving. They were — the suite's own partial save
two checks earlier had reset them through exactly the COALESCE path above. Same
shape as the transport/TC suite, where a removed assignment had cleared the dues
a later check depended on. A test that mutates shared state is a test that can
lie about the code.

Five suites now exist, 140 checks:

    fee_module_tests.sql             28
    enquiry_registration_tests.sql   30
    attendance_exam_tests.sql        28
    transport_tc_tests.sql           31
    admission_workflow_tests.sql     23

---

### [2026-08-25] Promotion and Leave/Payroll test suites

`Database/tests/promotion_tests.sql` (17) and `leave_payroll_tests.sql` (29).
**Both passed clean on local and Railway with nothing to fix.** These were the
last two modules with real guards and no suite.

**Promotion** moves a whole cohort in one click, so a wrong rule is not one bad
row — it is every student in the school. Confirmed: promoting into the same
session, into an unknown session, or with nobody selected are all refused; a
promoted student moves up exactly one class and into the new session while
keeping their **section**, their **admission number** and their Active status;
`retain` keeps the class but still advances the session; `passout` leaves the
school; a per-student `toClass` allows a genuine double promotion (1 straight to
3) while **promoting downwards is refused** — "1 is not above 3" — so a mis-click
in the dropdown cannot quietly demote a child; and a debt survives promotion when
carry-forward is on.

**Leave and payroll** are tested together because the rules that matter live in
the join: an approved unpaid leave becomes Loss of Pay, and LOP is money.
Confirmed: backwards dates, a missing type and an unknown staff member are all
refused; a **Sunday-only range has no working days in it** and cannot be leave;
a calendar week counts 6 working days, from the one shared `fn_working_days` the
student register also uses; an overlapping request is refused while the first is
live, so the same days cannot be charged twice; a decision must be approve or
reject, is recorded with **who** made it, and cannot be re-made afterwards.

On the money itself: gross comes from the staff record, three unpaid days give
three LOP days, LOP is gross ÷ working days × LOP days (₹3,461.55 on a ₹30,000
salary over 26 days), net is gross − LOP − deductions and never negative.
**Approved *casual* leave costs nothing** and a **pending** unpaid request is not
deducted — only an approved unpaid one is. Re-running a month updates rather than
stacking payslips, a payslip is marked paid once with who paid it, paying twice
is refused, and — the one that matters most — **a re-run leaves an already-PAID
payslip alone**, so the record keeps matching the bank transfer.

**Two fixture lessons.** Section names here are per class: the pre-primary
classes use "Kid A" while class 1 upwards use "A", so the suite now picks three
consecutive classes that *share* a section rather than assuming one. And a target
session needs its classes **and their sections** copied, or every promotion fails
with "section A does not exist".

Seven suites now exist, **186 checks**, identical on local and Railway:

    fee_module_tests.sql             28
    enquiry_registration_tests.sql   30
    attendance_exam_tests.sql        28
    transport_tc_tests.sql           31
    admission_workflow_tests.sql     23
    promotion_tests.sql              17
    leave_payroll_tests.sql          29

---

### [2026-08-25] Settings and Roles test suites, and a missing fee-head name guard

`Database/tests/settings_tests.sql` (26) and `roles_tests.sql` (23) — the last
two areas with real guards and no suite. **Nine suites now exist, 235 checks,
identical on local and Railway.**

**Found: `sp_school_admin_fee_head_manage` had no name guard.** It was the only
settings proc without one — academic years, transport routes and roles all refuse
a blank name. A fee head made of spaces was created happily, and because the
unique index compares the raw string, an empty name and a whitespace name were
two *different* blank heads. A blank head reaches student ledgers
(`student_ledger` identifies its head by name) and prints as an empty line on a
receipt. The proc now trims the name and refuses it when empty. Applied to both
databases.

**Settings, confirmed correct.** Sessions refuse a blank name, an end date before
the start, and a duplicate; setting one current leaves **exactly one** current.
Fee heads store their amount and their refundable flag (which is how the security
deposit is modelled), saving an existing name **upserts rather than duplicating**
— deliberate, since it also revives a head someone had deleted — and a padded
name is now the same head rather than a second one. Deleting a head cascades its
unpaid ledger rows, so nobody is left owing against a head that no longer exists.
Subjects refuse a missing class and a class from another school.

**The guard most worth having:** a class or section with enrolled students
**cannot be removed** — "Move or promote those students first." A settings
tidy-up cannot orphan real children.

**Roles, confirmed correct.** Blank and duplicate names refused; a custom role can
be renamed; **built-in roles cannot be renamed or deleted** (they are identified
by `role_code`, and the application checks for those five codes, so renaming one
would silently detach every check that looks it up); a role still assigned to a
user cannot be deleted. Permission saving is a **replace**, not an append: an
unticked box really revokes. The revoke is a **soft** delete, so re-ticking
revives the original row instead of piling up a second grant for the same
permission — checked both ways. Another tenant can neither grant on nor delete
our role.

**A note for whoever reads this suite.** Four roles checks failed at first and it
looked like saving appended instead of replacing. It did not — the proc
soft-deletes revoked grants, and the test counted every row rather than the live
ones. That is the third suite in this series where the test was wrong and the code
was right (after the fee cancel-twice check and the transport dues check). When a
check fails, read the proc before believing the test.

I also suspected `sp_role_permissions_save` of a cross-school hole, because its
role lookup filters on `tenant_id` but not `school_id`. It is not a hole:
`config.roles.school_id` is NULL for every real tenant, so roles are tenant-scoped
and the tenant check is the real boundary.

**Left alone deliberately:** two fee heads on Railway still have
`collection_point = 'Recurring'` on a `One Time` frequency, which
`fee_collection_point.sql` migrates to `'Admission'` — school 33 "Annually
Function" and school 34 "Admission Fee". Only the procedure change was applied
there; running a pending data migration was not what was asked for. Noted in the
checklist TODO.

    fee_module_tests.sql             28      leave_payroll_tests.sql     29
    enquiry_registration_tests.sql   30      settings_tests.sql          26
    attendance_exam_tests.sql        28      roles_tests.sql             23
    transport_tc_tests.sql           31
    admission_workflow_tests.sql     23      TOTAL                      235
    promotion_tests.sql              17

---

### [2026-09-20] The pending fee-head collection-point migration, run on Railway

The two rows left behind by the previous entry are migrated. School 33 "Annually
Function" (`fee_head_id` 54) and school 34 "Admission Fee" (61) were `One Time`
heads still carrying `collection_point = 'Recurring'`; both are now `'Admission'`,
and nothing on Railway is unmigrated.

**What that actually changes.** `collection_point` decides how the admission
screen treats a head: `'Admission'` puts it in the "One Time Payable Now" group
with stage `Admission`, while `'Recurring'` schedules it as an instalment. So an
"Admission Fee" marked Recurring was being offered as a scheduled due rather than
collected at the desk, which is precisely the state the migration exists to fix.

**What it does not change: any money already owed.** Checked before running —
`sp_admission_manage` never reads `collection_point` and `core.student_ledger`
has no such column, so no existing ledger row, receipt or balance is affected.
Only how those two heads are grouped for *future* admissions.

All nine suites re-run on Railway afterwards: **235 checks, 0 failed**, unchanged.

A one-statement rollback (the two ids and their previous value) is in this
session's scratchpad as `feehead_collection_point_rollback.sql`. The `\copy`
backup attempted first failed on its output path; the before-state is recorded in
that file and in this entry instead, which is enough to reverse a two-row change.

---

### [2026-09-20] Inventory module

The two Inventory pages were shells: they rendered, saved nothing, and drew their
rows from `wwwroot/js/inventory-catalog.js`, a hardcoded array of ten invented
items whose own header said *"When a backend exists, replace the items array with
an API fetch."* The backend now exists, so that file is deleted and both pages
read from the database.

**`Database/inventory.sql`** — `inventory_items`, `inventory_suppliers`,
`inventory_purchases` + `_purchase_items`, and `inventory_stock_ledger`, behind
`sp_inventory_manage` and `sp_inventory_purchase_manage`.

**The central decision: stock is a LEDGER, not a number.** Every change writes a
row saying what moved, how much, why and who did it. `current_stock` on the item
is a running total kept in the same transaction — a cache for the list screen,
never the source of truth — and `Recount` rebuilds it from the ledger, so the two
can be reconciled rather than argued about. The test breaks the cache on purpose
and proves Recount repairs it. This is the fee-ledger lesson applied: a balance
you only ever UPDATE drifts, and nobody can say when or why.

**Opening stock is a movement too**, so the very first figure on the shelf has a
date and an author like every later one.

**Stock cannot go below zero.** Issuing more than is there is refused by name and
amount — *"Only 25.00 Piece of ZZ School Tie left"* — because a negative stock
figure is never a thing that really happened; it is always a mistake someone must
correct at the time, not discover at audit.

**A purchase is immutable once saved.** It can be cancelled, which writes matching
negative movements and keeps both the invoice and its reversal on the record, but
never edited. Cancelling twice is refused, and cancelling a purchase whose goods
have already been issued is refused with the arithmetic in the message: *"only
0.00 Piece of ZZ School Tie left, and this purchase brought in 10.00."*

Also guarded: duplicate item names and duplicate SKUs (a blank SKU is fine, and
several items may have none); one invoice number per supplier, so the same bill
cannot be entered twice; a future-dated purchase; a purchase with no lines; and a
line naming an item from another school — checked before anything is written, so
a bad line cannot leave a half-purchase behind. Deleting an item still holding
stock is refused; once empty it soft-deletes, its movement history survives, and
its name becomes available again.

**Beyond the shells.** The two pages only had item master and purchase entry,
which between them can only make stock go *up*. Issue / Return / Damage /
Adjustment are added, with a stock-history view per item — without them the module
would not be an inventory system.

**Shell fields that needed a home rather than deletion.** The item form already
drew Cost Price, Selling Price, Brand, Model, Description and a Status toggle, and
the list had a Value column and a Stock Value card. Rather than delete half the
designed form, those columns were added; cost price is what gives Value a real
source. The four summary cards are computed in the page from the same rows the
table draws, so they cannot disagree with the list under them — and the
server-side summary I had written for them was removed rather than shipped as a
second source for the same number.

**A trap worth recording.** `CREATE OR REPLACE PROCEDURE` cannot change a
parameter list, so adding the pricing parameters left the old overload in place
and every call failed with *"is not unique"*. Worse, three tests **passed for the
wrong reason** — they expected a refusal, and the ambiguity error was a refusal.
Both procs now drop every existing signature by name before creating themselves.
Same shape as the two `sp_fee_payment_collect` revisions.

`Database/tests/inventory_tests.sql` — 49 checks. Ten suites now exist,
**284 checks**, identical on local and Railway.

---

### [2026-09-20] The money trail, and a real bug in receipt cancellation

`Database/tests/money_trail_tests.sql` — 98 checks. Every other suite tests one
module; this one follows a single child through the whole financial life of a
school place — enquiry, registration fee, admission, a concession, an
overpayment, paying from the wallet, two cancellations, the bus, a refund,
promotion, and leaving with a TC — and after **every step** re-proves the same
five equations.

**Found: cancelling a receipt did not reverse the advance wallet.** The collect
proc moves the wallet in two directions on one receipt — a surplus is credited,
and anything drawn from the wallet is used — but `sp_fee_receipt_cancel` only
reversed the ledger. That lost real money **in both directions**:

- Cancel a receipt that had **credited** the wallet (parent overpaid, then the
  cheque bounced) and the family kept the credit. Proven: 500 survived a
  cancelled receipt. **The school loses.**
- Cancel a receipt that had been **settled from** the wallet and the balance was
  never returned. Proven: 500 the parent had already handed over simply vanished.
  **The family loses.**

Cancel now applies the exact mirror — `balance - advance_credit + advance_used`.
Both directions verified before and after. **No live data was affected:** a
reconciliation over Railway found zero wallets disagreeing with their receipts,
and zero cancelled receipts that had ever touched a wallet, so the bug was latent
rather than realised.

**The five equations, re-checked at every stage**

1. `SUM(ledger.amount_paid)` equals the lines on live receipts — the office and
   the cash book agree.
2. Concession agrees the same way. A concession is money deliberately not
   collected, and it must be visible in exactly one place.
3. Wallet balance equals credits minus uses over live receipts. *This is the one
   that was broken.*
4. No ledger row shows more paid than it was due, and the wallet never goes
   negative.
5. **The till reconciles two ways.**

**What equation 5 pins down, and why it matters.** `fee_payments.amount` is what
was **settled on the ledger**, not what crossed the counter: a parent handing over
2,500 against a 1,000 due leaves `amount = 1000` and `advance_credit = 1500`. Real
cash is therefore `amount + advance_credit - advance_used`. Day close counts the
same money a second way, from `v_fee_tender_lines`, which falls back to the
header's mode and amount when a payment has no explicit tender split. Both
routes were checked against three shapes — plain cash with no tenders, an
explicit over-tender, and a payment funded entirely from the wallet — and agree
at 3,500. **The drawer reconciles.** Two of my own checks failed here first,
because I had assumed `amount` was the till; it is not, and the suite now says so
by name.

**What the walk confirms about the rest of the trail**

- A registration fee is booked against the **enquiry**, and stays there. It is not
  quietly pulled onto the student's ledger at admission, where it would look like
  a tuition payment nobody could trace to its receipt.
- Cash and concession settle a due together, and the receipt is for the **cash
  only** — the concession is not money that moved.
- Adding the bus raises new dues and touches nothing already collected.
- Taking a student off the bus drops the months they will not ride but keeps the
  month they **paid** for, and — the part worth stating — the receipt for it stays
  in the cash book.
- A refund is recorded against the ledger row and in the refund register, and does
  **not** rewrite the original receipt. Both facts stay true: 600 was taken, 200
  went back.
- Promotion carries the debt and disturbs neither the collections nor the wallet.
- A TC is refused while money is owed, and issued once the account reaches zero.
- Cancelled receipts stay on file for audit and count as nothing.

At the end the books close: **billed 17,600 = paid 16,600 + concession 1,000**,
receipts equal what the ledger says was paid, no wallet balance is left behind for
a student who has gone, and the 200 refunded is accounted for separately.

**Reconciliation query**, for checking a live database at any time:

```sql
SELECT a.school_id, a.student_id, a.balance AS wallet_says,
       COALESCE((SELECT SUM(COALESCE(p.advance_credit,0) - COALESCE(p.advance_used,0))
                 FROM core.fee_payments p
                 WHERE p.student_id = a.student_id AND NOT p.is_cancelled), 0) AS should_be
FROM core.student_advance a
WHERE a.balance <> COALESCE((SELECT SUM(COALESCE(p.advance_credit,0) - COALESCE(p.advance_used,0))
                             FROM core.fee_payments p
                             WHERE p.student_id = a.student_id AND NOT p.is_cancelled), 0);
```

Eleven suites now exist, **382 checks**, identical on local and Railway.

---

### [2026-09-20] Do the Admission Workflow settings actually control the money?

`Database/tests/workflow_billing_tests.sql` — 28 checks. The workflow page offers
a school switches like *charge fees from* and *collect fee at admission*. This
suite asks the only question that matters about them: when the switch is flipped,
does the school's money change, and by exactly the right amount?

**Yes, for `charge_fees_from` — and it is enforced in the database.**
`sp_admission_manage` reads it, so the policy holds no matter what reaches the
proc. Tested across both policies and four joining dates:

| Joins | SessionStart | AdmissionMonth |
|---|---|---|
| day one of the session | 12 instalments | 12 |
| 5 months in | **12** (billed back to April) | **7** (from their own month) |
| the last month | 12 | **1** |
| years before the session | 12 | 12 |

Same child, same ₹1,000 a month, joining five months in: **SessionStart bills
₹12,000, AdmissionMonth bills ₹7,000** — the switch is worth ₹5,000 to that one
family, and the difference is exactly the five months skipped.

The last row is the back-dating regression guard seen from the settings side: a
child admitted in 2017 sitting in the 2026-27 session is billed **12** months, not
120, under **either** policy. That bug once billed ₹4,29,000 instead of ₹42,000.

**Other frequencies ignore the policy**, as they must: a One Time admission fee
and a Yearly charge are each billed once and for the same money whichever way the
switch is set. Only the monthly schedule moves.

**A session bills only its own months.** Across every case in the suite, no
instalment falls before the session starts or after it ends.

**The honest part, which the settings page does not say.** Of the settings on that
screen, exactly **one** is enforced inside the database:

- `charge_fees_from` — **enforced in the proc**. Verified by counting references
  in `sp_admission_manage`, so the claim cannot quietly go stale.
- `collect_fee_at_admission` — **application only**. `Create.cshtml` hides the
  collection panel and `AdmissionController` zeroes `payAmount` regardless of what
  was posted, so the screen genuinely cannot collect. The proc never reads it.
- `registration_required_before_admission` — **application only**.
  `AdmissionController.Create` refuses a walk-in; the proc will still admit one.
- `enable_security_fee` — **application only**; the controller filters the fee
  list, the proc bills whatever plan it is handed.
- The five module toggles — **application only**; menu and page gating.

That is defence at the app layer, not a constraint on the data: anything reaching
the procedures another way — a script, an import, a future endpoint — will not be
stopped by the four app-only settings. Checks F4 to F7 state this per setting, so
the day one of them moves into SQL the note gets updated rather than silently
becoming wrong.

One nuance worth knowing: with collection switched off, a **concession** can still
be recorded at admission. That is a waiver, not money changing hands, so it is
defensible — but it is the one thing that still writes to the ledger on that
screen when collection is off.

Twelve suites now exist, **410 checks**, identical on local and Railway.

---

### [2026-09-20] New Admission: validation at all three layers, a photo, and a name bug

A full audit of `/ERP/Admission/Create`, then fixes at every layer. Two things I
first reported as missing turned out to be already right, and are recorded here so
the audit is not remembered wrongly: the red asterisks **do** render
(`.required::after { content:" *" }` in `Create.css`), and they match the inputs'
`required` attribute exactly — ten fields, no drift. A duplicate admission number
was **already** refused with a clear message, and does not overwrite the first
child.

**Fixed: pressing Save could appear to do nothing.** The handler was
`if (!this.checkValidity()) { $form.addClass('was-validated'); return; }` — a red
border and nothing else. On a form this long the empty field is usually off
screen, so the office pressed Save and saw no reaction at all. It now scrolls to
the first invalid field, focuses it, and says which one by name.

**Fixed: seven of the ten starred fields were not checked server-side.** Only
name, class and academic year were. Section, gender, date of birth, admission
date, father/guardian name and address could all be posted blank — and **mobile
was only format-checked when present**, so a blank one passed the server even
though the form demands it. A school with no way to reach the parent has a
record, not a contact. All ten are now re-checked, along with the alternate
mobile's format, a date of birth after the admission date, and an admission date
in the future.

**Fixed: the proc accepted almost anything.** Each of these was reproduced as a
successful admission before the guard was written:

- a student whose **name was three spaces**;
- a student sitting in **a class that does not exist** — an orphan no class list
  shows, no fee structure matches and promotion cannot move;
- an admission dated **2027-10-25**, which also lands the first instalment in a
  month the session has not reached;
- a child **born after the day they joined**.

All four are refused by name now, while a *back-dated* admission — a real student
entered late — still goes through, because that is a legitimate thing to do.

**Found while reading the test output: admission numbers said `ADM-FY 2-0001`.**
The generator was `LEFT(v_year, 4)` on the session's *name*, so "FY 26-27" became
"FY 2". This is the same bug `core.fn_receipt_year` was written for when receipt
numbers hit it; the admission number had been left on the old expression. Now
`ADM-2026-0001`. **One existing student on Railway carries the old format** — an
admission number is identity and is referenced by receipts and certificates, so it
is deliberately left alone rather than rewritten.

**Added: a student photo at admission.** The upload endpoint, storage folder and
limits already existed for the profile page; the admission form now offers the
same thing at the point the child is standing at the desk. It is a square drop
target beside the name — the photo is part of identifying a student, not a
separate section — with live preview, drag-and-drop, a remove button, and the
JPG/PNG/WEBP and 2 MB checks mirrored client-side so the office is told before
filling in the rest of the form. The file rides along in the form's existing
`FormData`, and is filed after the student has an id. **A photo that fails never
fails the admission:** the child is admitted and the picture can be added later.

**Removed: Roll No.** Roll numbers are assigned per class once admissions close,
usually alphabetically, so at admission the field was always blank or a guess. The
column and the directory's Roll No stay, so existing numbers are untouched.

**Resequenced.** The form used to open with two reference numbers — one that
auto-generates and one that should not be set yet — before it asked the child's
name. Now the photo and the name lead, and Admission No sits with the placement
fields it belongs to, under a hint that says leaving it blank is normal.

`Database/tests/admission_validation_tests.sql` — 18 checks over the proc layer,
including that a refused admission leaves no half-written student and that
exactly the valid ones were created.

**Two of my own checks in `workflow_billing_tests` failed after this work**, and
were right to: they admitted a student in the last month of the session, which is
March 2027 — a date the new guard now refuses because it has not happened. They
now test the latest month that *has* happened, plus the refusal itself.

Thirteen suites, **430 checks**, identical on local and Railway.

### [2026-09-20] Every `date` column is now `varchar`, and C# stopped converting dates

The trigger was one line, copied into nine services:

```csharp
private static DateOnly? DateVal(DataRow r, string c) =>
    Has(r, c) && r[c] != DBNull.Value ? DateOnly.FromDateTime(Convert.ToDateTime(r[c])) : null;
```

Npgsql returns a `DateOnly` for a `date` column, and `Convert.ToDateTime` throws
`InvalidCastException` on one, because `DateOnly` is not `IConvertible`. Four of
the nine copies did exactly that. The decision was to take the type out of the
problem: store dates as ISO text and let the app carry them as strings.

**Schema — `Database/dates_as_text.sql`.** Generated from the catalog, so nothing
was missed: 30 `date` columns across the three schemas, converted with
`ALTER … TYPE varchar(10) USING to_char(col,'YYYY-MM-DD')`, with `CURRENT_DATE`
defaults rewritten to `to_char(CURRENT_DATE,'YYYY-MM-DD')`. The dependent view
`core.v_fee_tender_lines` and three range check constraints
(`chk_academic_year_dates`, `chk_exams_dates`, `chk_staff_leave_dates`) are
dropped first and restored after — they still hold, because ISO text compares and
sorts in date order. Zero `date` columns remain.

**Procedures — 84 casts across 18 files.** Text comparison and `ORDER BY` were
already correct on ISO text, so only the places where a column meets a real date
needed `::date`: `EXTRACT`, `BETWEEN` against a date variable, `CURRENT_DATE`
arithmetic, `DATE_TRUNC`, and `COALESCE(col, DATE '…')`. Assignments did **not**
need touching — `SET col = p_date` casts itself. Two rules were verified against
the server before editing anything, because the whole edit plan rested on them:
`COALESCE(date, varchar)` fails, and `INSERT … VALUES (CURRENT_DATE)` into a
varchar column succeeds.

**`sp_enquiry_followup_manage` had no source file.** It was live and called by
`EnquiryService`, but existed only in the database and in the pre-cleanup backup —
the repo could not have rebuilt it. Captured as `Database/enquiry_followup.sql`.

**C# — the date types are gone.** `DbRead.Date` is deleted (both overloads) and
date columns are read with `DbRead.NStr`; `DbRead.DateTimeN` stays, because the
`*_at` timestamp columns are still timestamps. `DateOnly` no longer appears
anywhere in the codebase. Model properties, service signatures, interfaces,
controllers and views all carry `string`.

**`Helpers/Dates.cs` is the one place a date is still parsed**: `Norm` turns
whatever a browser posted into ISO text (and returns null for anything that is
not a date, so a bad value is dropped before it reaches the database), `Parse` is
for genuine arithmetic such as `MonthsToYearEnd`, and `Show` formats for display.

**Parameters.** The procs still declare `date` parameters — changing 27
signatures would have meant a second wave of edits inside every body. Instead the
services send `NpgsqlDbType.Unknown` with an ISO string, and PostgreSQL resolves
it from the signature. Verified two ways: a prepared statement resolves an
untyped parameter to `date`, and a throwaway Npgsql client proved that
`Unknown` + `"2026-09-20"` arrives as a real date (`p_d + 10` returned
`2026-09-30`), that `DBNull` still passes, and that `core.sp_attendance_roster`
runs end to end.

**One silent bug this created and caught.** `Admission/Create.cshtml` tested
`ViewBag.PreDob is DateOnly` — legal C#, compiles fine, and would now never match,
so the date of birth would have quietly stopped pre-filling when converting an
enquiry. Found by grepping for the last `DateOnly` mentions rather than by the
compiler, which is the lesson: a runtime type test survives a type change.

All fifteen suites, **481 checks**, passed against the converted database — and
the dashboard was still broken. See the entry below.

### [2026-09-20] The dashboard broke anyway, and why 481 checks did not notice

Opening the landing dashboard threw
`42883: operator does not exist: character varying = date`. One line, in the
seven-day collection trend inside `sp_dashboard_summary`:

```sql
AND fp.payment_date = g.d::date          -- payment_date is varchar now
```

**How it got through.** The cast script matched a column followed by a date
*value*, and separately a column followed by a **bracketed** cast
(`(expr)::date`). `g.d::date` is a cast with no brackets, so it fell between the
two rules. It was in my own list of sites needing a cast — I never checked the
applied diff back against that list, which is the actual mistake. A re-scan with
a looser rule (any operand ending in `::date`, bracketed or not) found this one
site and no others, across every procedure, view and source file.

**How it got past the tests.** The dashboard was the one module with no suite.
Fifteen suites and 481 checks never called `sp_dashboard_summary`, so the most-
opened page in the app was the least covered. The user found it by opening it.

`Database/tests/dashboard_tests.sql` — 19 checks. The shape matters more than
the count: **every check FETCHES its cursor.** A refcursor procedure does almost
nothing until the cursor is read, so a test that only `CALL`s would have passed
while the page stayed broken. Section A fetches all nine cursors, B pins the
trend that actually broke (seven days, ending today, starting six days back), C
asserts the stored text really is `YYYY-MM-DD`, D checks the platform tenant
gets nothing.

Verified as a regression test the honest way: the bug was put back, the suite
reproduced the user's exact error, the fix was restored, the suite passed.

Sixteen suites, **500 checks**.

### [2026-09-21] The date-to-text change applied to Railway

`Database/dates_as_text_deploy.sql` — one script: the schema migration, then
every procedure that touches a date column, then a verification query. Both
halves are guarded, so a failed run can simply be run again.

**Checked before running.** `dates_as_text.sql` was generated from the *local*
catalog, so the first question was whether production had a date column the
script did not know about. Railway reported 31 to local's 30; the extra one was
`core.v_fee_tender_lines.payment_date`, a view column the script already drops
and recreates. Coverage was complete.

**Proved nothing moved.** A before-snapshot recorded the row count, minimum and
maximum of all 30 date columns. The same snapshot after the migration was
**byte-identical** — same counts, same earliest date, same latest date — and no
stored value fails `^\d{4}-\d{2}-\d{2}$`. The view came back with its row, and
all three range constraints are back on.

**Verified after.** Zero `date` columns. Zero uncast sites across every procedure
and view (the looser scan, the one that should have caught the dashboard the
first time). All sixteen suites, **500 checks, 0 failed**, against Railway.

Local and Railway now hold the same 110 procedures. One, `sp_school_admin_fee_head_manage`,
showed a different `pg_get_functiondef` hash — that is PostgreSQL 16 and 18.6
formatting the same body differently. Whitespace-normalised, the two are
identical.

**The application code has not been deployed yet**, and does not have to be
urgently: the procedures take `date` parameters exactly as before, and the old
reader parses the ISO text fine. The irony is that the failure that started all
of this — `Convert.ToDateTime` on a `DateOnly` — cannot happen now, because a
string is `IConvertible` and a `DateOnly` never was.

### [2026-09-21] Classes & Sections: the save was never reaching the server

**"Save failed. Check your connection."** on `/ERP/SchoolSettings/ClassSection`.
Nothing was wrong with the connection. `SaveClassSection` carries
`[ValidateAntiForgeryToken]`, but `persist()` sent only `X-Requested-With` — no
token — so ASP.NET rejected every save with **400** before the action ran, and
jQuery's `.fail()` printed the one generic message it has. The page *does* render
`@Html.AntiForgeryToken()`, and the Copy button *did* send it; only the save call
was missing the header. That is why copy worked and save did not. Every other
`.cshtml` with a POST was checked — no other page has the gap.

**Then the validation behind it was audited**, and only three things turned out
to be enforced server-side: tenant scope, "a year is selected", and the guard
that refuses to drop a class or section with students still enrolled. Everything
else — required names, duplicate names, capacity, lengths — lived in the browser,
so a stale tab or a hand-made POST walked straight past it.

- **Duplicate sections were not blocked anywhere but the page.** The controller
  de-duplicated class names and not section names, the procedure only checked
  non-empty, and the tables carry no unique index. Two sections named "A" in one
  class would persist, and enrolment, attendance and fees all join sections by
  *name*.
- **Silent drops were reported as success.** A blank or duplicate class name was
  skipped with `continue`, then `success = true` came back. The page toasted
  "Class saved." and did not reload, so the discarded class stayed on screen
  until the next load and then vanished. Data loss under a success message.
- **No length checks**, so an over-long name reached PostgreSQL and the user was
  shown `value too long for type character varying(20)` — the raw SQLSTATE 22001
  text, passed through by the `PostgresException` handler.
- **`min="1"` on the number inputs was decorative**: native form validation never
  runs, because the click handlers read `.value` directly. `parseInt("-5")` gave
  a negative capacity that nothing rejected.
- **`stream` was the one value interpolated raw** into markup, and into a class
  attribute at that, while the name, room and coordinator beside it all went
  through `EC.esc`. The server accepted any string for it.
- **`coordinatorStaffId` was stored unchecked.** The procedure looked the *name*
  up scoped to tenant and school but inserted the id regardless, so another
  school's id was stored as a dangling reference with no name next to it.
- **The year id on save was never checked as the caller's.** The year-name lookup
  had no tenant filter. The foreign key kept the id real and inserted rows still
  carried the caller's own `tenant_id`, so nothing crossed tenants — but classes
  could be attached to a session the school does not own.

**The read path was checked too, and had the same loose spot.** `GetAcademicSetup`
filtered `academic_years` by id alone. Every class, section and staff join under
it was already scoped, so another school's structure never appeared - proved by
calling the procedure as tenant 23 for tenant 24's year and getting all-NULL
columns, against 14 rows for its rightful owner. What did come back was that
year's own row: start date, end date, is_current. Nothing displayed it (the
service maps none of those dates, and the year dropdown is tenant-scoped, so the
id could only be reached by editing the URL), but the filter belongs there, and
is now on. The same call afterwards returns no rows at all.

**Fixed** by validating in `SaveClassSection` and *rejecting* with a message
instead of dropping the row: names required, lengths matched to the column widths
(50/20/150/50, now also `maxlength` on the inputs), duplicate class **and**
section names refused, rank and capacity range-checked on both sides, and stream
restricted to the four the dropdown offers. `EC.esc` was put on the stream badge.
In the procedure, the year lookup is now scoped to tenant and school and raises
when it finds nothing, and a coordinator staff id that is not this school's is
dropped to NULL rather than stored.

**Verified against the local database, every call rolled back.** A save into
another tenant's year now raises, as does a nonexistent year. The real structure
round-trips unchanged. A coordinator id from school 34 comes back NULL; school
33's own id comes back with its name. The pre-existing enrolled-students guard
still fires — it is what refused the first draft of the test.

`Database/academic_class_section_unique.sql` adds the partial unique indexes that
should have been holding the duplicate rule all along, case-insensitive and over
live rows only, so the procedure's delete-all-then-reinsert still works inside one
transaction. **It is not applied yet**: it fails if duplicates already exist, and
resolving one means renaming a section that students are enrolled under. The
check query is in the script's header.

`Database/classsection_hardening_deploy.sql` wraps the whole thing for Railway:
it prints the current procedure first as a rollback copy, lists any duplicates,
reloads the procedure, and then creates the indexes only if that list came back
empty - a duplicate makes it warn and name them rather than fail halfway. It ran
clean against local end to end, all four verification flags true.

**The indexes are now on locally, and the save was re-tested with them in
place** - the delete-all-then-reinsert still works, because the partial predicate
ignores the soft-deleted rows inside that transaction, and a section "a" sent
alongside an existing "A" is now refused by the database itself. That is the
backstop behind the controller check, not a replacement for it: the controller
still answers first, with a sentence a human wrote.

**Applied to Railway** (PostgreSQL 18.6) the same day. The procedure there was
checked first and was our own lineage - the enrolled-students guard, the class
teacher snapshot and the enrolment-based strength were all present, none of the
three new filters were - so replacing it clobbered nothing, and the old
definition was saved off first as a rollback copy. The duplicate check came back
empty, so both indexes were created. All four verification flags true.

One of those flags was lying before it was fixed: `LIKE '%v_coord_staff_id :=
NULL%'` also matches `v_coord_staff_id := NULLIF(...)`, which is in the original,
so the coordinator check read true on a database that did not have the fix. It
now looks for `IF v_coordinator IS NULL THEN`, which only the new version has.

**Proved on Railway itself**, every call rolled back: a cross-tenant read returns
no rows where the rightful owner gets 18; a cross-tenant save raises; the real
11-class structure round-trips unchanged with the indexes in place; and a section
"kid a" sent next to the existing "Kid A" is refused by
`ux_academic_class_sections_name`. Live counts afterwards were untouched at 31
classes and 47 sections, with no stray row left behind.

### [2026-09-21] Period Structure: two new period types, and the validation to hold them

Assembly and Diary time. Assembly and prayer are the same slot in these schools,
not two, and it runs every day - which is the answer that kept this small: no
per-day column, no second schedule, just two more values.

**Adding a type turned out to be safe by design.** Everywhere in the codebase the
rule is `type === 'class'` means a bookable teaching slot and everything else does
not, which Timetable relies on in six places and StudentController notes in a
comment. Assembly and Diary land in the non-bookable half on their own, which is
exactly right - nobody books a teacher against assembly.

**It was not one change, it was five.** The CHECK constraint, the procedure's
whitelist, the page's dropdown and label/icon maps, the CSS, and the controller.
`CREATE TABLE IF NOT EXISTS` only shapes a fresh database, so the widened
constraint needed an explicit re-runnable DROP/ADD beside it for databases that
already exist.

**Smart Bell was the part that would have been missed.** The same schedule drives
the kiosk, and there the type picks the icon, the hero tint, the timeline colour,
**how many times the bell rings**, and both the Hindi and English PA lines. Left
alone, assembly would have announced "please move to your scheduled class" and
rung like any other period. Assembly opens the day, so it now gets the same one
long ring the end of day gets, rather than a count of short ones; diary rings
two, and both have their own announcement in both languages.

The validation here was already better than Classes & Sections - the procedure
checked labels, times, ordering and overlap server-side, and the page sent its
antiforgery token. What was missing:

- **The overlap test trusted the array order.** The comment said so out loud:
  "the UI keeps them chronological". A payload posted out of order raised a
  *false* overlap - 10:00-11:00 followed by 08:00-09:00 does not overlap, but the
  check compared 08:00 against the previous 11:00 and refused it. It now walks
  them in clock order, and that case is a regression test.
- **An empty schedule saved silently**, and this schedule is what rings the bell.
  Refused now, in the page, the controller and the procedure.
- **Duplicate labels**, which both the timetable and the bell show by name.
- **An unknown type was quietly rewritten to 'class'** by a CASE in the INSERT,
  hiding the mistake until someone noticed the wrong colour. It is refused now,
  so the CASE is gone.
- **Label length and time format**, which reached PostgreSQL and came back as its
  own wording - `value too long...`, `invalid input syntax for type time`.
- **No cap on the number of periods.**

Six procedure checks verified locally, each rolled back: a schedule using both new
types saves; empty, duplicate label, unknown type and a real overlap all raise;
and the out-of-order pair that used to be refused now passes.

### [2026-09-22] Classes & Sections: real streams, and why the class name carries them

The stream dropdown offered General / Science / Commerce / Arts. Real Indian
schools split Science into PCM and PCB, call Arts "Humanities", and run a
Vocational stream - and the app already knew this: the Enquiry CRM's Interested
Stream list has had the right six values all along. Classes & Sections just never
caught up. The codes stay short (`pcm`, `pcb`, `com`, `art`, `voc`, `gen`) so the
`varchar(50)` column is untouched, and `sci` stays in the whitelist so classes
saved before the split can still be re-saved.

**The interesting part was the duplicate-name complaint.** Creating "Class 11" for
PCM and "Class 11" again for PCB is refused, and the obvious fix - make the
uniqueness check `(name, stream)` instead of `name` - is the wrong one. Nothing
downstream carries the stream. `core.student_enrolment` stores `class_name` as
text with no stream column, and the enrolment procedure resolves the class by
name with `ORDER BY display_order, academic_class_id LIMIT 1`. Two rows named
"Class 11" and that `LIMIT 1` silently attaches a PCB student to the PCM class.
The student, fee and report filters all match on the name the same way.

So the name stays the key, and the page composes it: you type "Class 11", pick
Science (PCM), and it saves as "Class 11 Science (PCM)", with a live "Saved as:"
hint so the suffix is never a surprise. The duplicate check then reads as
class + stream, which is what was actually wanted. Composition is idempotent, and
it runs only when **adding** - recomposing on edit would rename a class that
already has students enrolled under the old name, and enrolment stores that name
as text.

**A class with no sections is invisible.** Attendance requires a section and gates
marking on being that section's class teacher, the timetable is built per section
and bails without one, and class-teacher assignment is per section. So "Nursery
doesn't need sections" cannot mean zero sections - every new class now gets
section A, and classes that already have none are badged rather than left
looking fine. Ten such classes existed locally and were backfilled.

**Rooms were never checked anywhere.** Two sections could share "Room 101" with
nothing said, and the timetable's clash detection keys on
`day_period_teacherId` only - it flags a double-booked teacher, never a
double-booked room. The section save now warns (and still saves, because labs and
halls are legitimately shared) when a room is already taken, matching across the
whole year rather than just the current class. The room clash check inside
Timetable itself is still open.

One bug found while checking the legacy path: a class holding a stream the
dropdown no longer offers left the select blank, and saving cleared the stream.
The stored value is now added as an option so it survives the round trip.

Not fixed, and worth knowing: `Program.cs` pins `UseUrls` to
`0.0.0.0:{PORT ?? 8080}`, which overrides `ASPNETCORE_URLS` and every
launchSettings profile. On a machine where 8080 is in the reserved port
exclusions, `dotnet run` dies with a bare `SocketException (10013)`.

### [2026-09-27] Quarterly fees were billed once a year, and the billing policy moved to the session

Two billing fixes, found by reading the Fee Head and Admission Workflow pages
end to end rather than by a bug report.

**Quarterly billed one installment instead of four.** The Fee Head page has
offered Monthly / Quarterly / Yearly / One Time all along, but the ledger
generator special-cased exactly one of them: `IF frequency = 'Monthly'` looped
per month, and *everything else* fell into a single-row ELSE. So a school with
"Exam Fee, Quarterly, 250" billed 250 for the whole year. Meanwhile the Fee
Structure annual total already multiplied quarterly by 4, and Fee Collection
already had a Quarterly tab - both sides assumed four installments that were
never created. Live data had it: 7 students on Railway, one ledger row each,
1,750 billed where 7,000 was due. Frequency now yields a step in months
(Monthly 1, Quarterly 3, Half Yearly 6) and the same loop, with the same
session-end clamp, runs for all of them.

**The cycles are the school's, not the child's.** The first version started a
joiner's quarters at their admission month, so a September arrival got a
private "Sep-Nov, Dec-Feb, Mar". Real schools run fixed terms - Apr-Jun,
Jul-Sep, Oct-Dec, Jan-Mar - the same ones for every student, and an exam fee is
tied to a term, not to when a child walked in. The first billing month is now
snapped back to the start of the cycle it falls inside, counted from the
session start. An August joiner and a September joiner both get
"Jul 2026 - Sep 2026" as their first quarter, which is the point: two children
in the same class can be compared. Monthly is left alone, since a month is
already aligned.

**"Charge recurring fees from" now belongs to the academic year.** It decides
how a student's entire session is billed, but it lived as one row per school,
upserted in place, with only `updated_by`/`updated_at` behind it. A fee plan is
generated once, at admission, and then frozen - so changing the switch in
August could not reach the students admitted in April, and nothing recorded
what the rule had been. Two children in one class billed differently, with no
way left to answer why.

Moving it onto `academic.academic_years` (backfilled from each school's current
value, so no behaviour changed on the day it ran) does three things. Last
year's policy can no longer be rewritten by this year's change. The admission
procedure gets *shorter*, because it was already reading that same row two
lines above for the session window. And the save can now refuse the change once
the session has students - a question that could not even be asked while the
value belonged to the school, since there was no session to count against.
Renaming a year or fixing its dates stays allowed; only the policy locks, and
the page disables the field and says how many students locked it.

The old column is dropped rather than left behind. `registration_fee_amount`
and `security_fee_amount` are still sitting on that same table reading 0.00,
long after the amounts moved to Fee Heads, and that is exactly the trap being
avoided - a second copy of an answer that nothing maintains.

All 16 suites: 500 checks, 0 failures. Four of them called the two procedures
whose signatures changed and were updated with the move rather than left to
rot.

Still open, found in the same read and not fixed here: a fee head can be
deleted while students are billed against it, and always reports success;
`uq_school_fee_heads_name` is case-sensitive while `student_ledger` keys on the
name text alone, so "Tuition Fee" and "tuition fee" split one fee into two;
renaming a head orphans the ledger rows already written under the old name; and
fee head save validates presence only - a negative amount is accepted.

### [2026-09-27] Fee Head: the name is the identity, so it is protected now

`core.student_ledger` carries `fee_head_name` and no `fee_head_id` - the cascade
delete says so out loud, because it has to match on the name. So the name is the
join key for every due, every receipt line and every report, exactly the shape
`class_name` has. It had none of the protection `class_name` got.

**The Active/Inactive toggle did nothing at all.** It was written, stored,
toggled and rendered as a pill - and no layer filtered on it. The procedure
selected `is_active` without a WHERE, no C# filtered it, and FeeStructure only
printed the label. A head marked inactive still appeared in the structure picker
and was still charged on new admissions. The flag now decides: the picker offers
only active heads, and the admission fee list skips them. Deliberately it does
*not* filter in the master read - the by-id enrichment that gives a saved
structure row its collection point would lose inactive heads and blank out their
lifecycle. Filtering belongs at the decision, not at the lookup.

That flag matters more than it looks, because it is the answer to the next one.

**Deleting purged paid dues.** The cascade is intentional and documented - a head
removed from the master must leave the structures and plans too. But it also
deleted the head's ledger rows *including the paid ones*, while receipts in
`core.fee_payment_details` are kept on purpose. A receipt survived pointing at a
due that had been erased, so money collected could not be reconciled against what
it was collected for. A due with any payment, concession or refund against it now
refuses the delete and says to deactivate instead - which is why the toggle had to
start working first.

**Uniqueness was case-sensitive.** "Tuition Fee" and "tuition fee" were two heads
writing two sets of ledger rows that read identically on screen and never summed
together. The index is now on `lower(fee_head_name)`. Saving a NEW head under an
existing name stays an upsert rather than an error - that is deliberate and
tested (settings_tests C4): it revives a head someone deleted instead of
complaining about a row the user cannot see. The duplicate error is raised only
on a rename, which is the case that used to reach the index and come back as a
bare 500.

**A rename orphaned everything already written.** Fixing a typo - and there is a
live one, "Tution Fee" - left every existing row under the old spelling, so one
fee showed as two in every report. The rename now carries into `student_ledger`,
`student_fee_plan`, `school_fee_structure_details` and `fee_payment_details`, and
the message says how many rows followed. Receipt lines move too: a receipt is a
snapshot of amounts, not of spelling, and leaving them behind is what splits a
collection report down the middle.

**The procedure's message now reaches the user.** All three writes returned `int`
and the page replaced whatever happened with a fixed sentence - so "removed from
3 structure rows, 12 plan rows and 148 ledger dues" was thrown away and shown as
"Fee head deleted successfully." They return `(Success, Message)` now, matching
the academic-year methods, and the save catches `PostgresException` so a business
rule arrives as a sentence instead of a 500. Validation moved into the procedure
with it: negative amounts, unknown billing cycles and unknown collection points
were all accepted before, checked nowhere.

Eight behaviours verified against the real procedures, each rolled back, plus all
16 suites: 500 checks, 0 failures. One of those suites caught a real mistake - the
first version raised on any duplicate name and broke the documented upsert, which
is the whole reason that test spells out its reasoning.

Not done here: `display_order` is dead weight (22 heads on Railway, one distinct
value, no UI input, and the only ORDER BY on it degrades to the name), and the
Fee Head page still gives no hint when a head is switched off by a Workflow
toggle rather than by its own flag.

### [2026-09-27] Half Yearly reaches the dropdown, and filters wait for the button

**Half Yearly was implemented everywhere except the one place you could pick
it.** The billing engine steps it by six months, the Fee Structure annual total
already multiplied it by two, and the admission summary already had a
Half-Yearly line. Only the Fee Head dropdown never offered it. Adding the option
to the form and the filter is the whole change; the FeeCycle lookup gained the
row too, with an explicit UPDATE beside the seed because that INSERT is
`DO NOTHING` and an existing Yearly would have kept sort order 4 and sat on top
of the new entry. Verified end to end: 2 installments, "Apr 2026 - Sep 2026" and
"Oct 2026 - Mar 2027".

**Every list page applied its filters on change.** Twenty-three
`onchange="this.form.submit()"` across seven forms, each one a full page load -
so picking a class, then a gender, then a year cost three round trips and
rendered two states nobody asked for. Filters now apply on a Search button, and
the five forms that had no button got one. Enter in the search box still
submits, because the inputs are `type="search"` inside the form.

Two things deliberately kept their automatic submit. The Enquiry quick-filter
buttons flip a hidden field and submit from their own click handler - that is an
explicit press, not a side effect of choosing a value. And `_PageSize` stays
automatic, with a comment saying why: "rows per page" is not a filter, it is how
you look at an answer you already asked for, and hiding it behind Search would
read as broken.

The Search button reuses `btn btn-sm btn-primary` with a `bx-search` icon,
because Student/Inactive already had exactly that and matching it beat inventing
a shared class - the first attempt here added one to site.css and it was the
wrong call.

### [2026-09-27] A switched-off module is switched off now, and a silenced fee head says so

Both halves of the same complaint: a setting said one thing and the app did
another.

**Turning a module off only hid its menu.** `EnableExams`, `EnableInventory` and
`EnablePayroll` were read in exactly one place, `_VerticalMenu.cshtml`, so a
bookmark, a typed URL or a stale tab walked straight into a module the school had
switched off. Transport was the only one that checked server-side, and it did it
with a twenty-five line `OnActionExecutionAsync` override inside its own
controller. Copying that into three more controllers is how four copies of one
rule drift apart, so it became `[RequiresModule(SchoolModule.Exams)]` - shaped
like the `[HasPermission]` attribute already in the project, because a
cross-cutting controller guard is exactly what that pattern is for. Transport now
uses it too and is 36 lines lighter.

It is deliberately not a permission check. Permissions decide what a user may do;
this decides whether the school runs the module at all, so it refuses everyone
equally and redirects to the screen where it can be turned back on. AJAX callers
get the same refusal as JSON, because a fetch cannot follow a redirect usefully -
it would parse the settings page as its payload.

Leave is guarded by the Payroll switch, not one of its own, because that is what
the menu already does - both items sit behind `showPayroll`.

**A fee head can be valid and still never be charged.** Two workflow switches
silence one without touching it: a Registration-point head is only collected when
the school runs a registration fee, and the refundable Admission head - the
security deposit - only when that toggle is on. The Fee Head page showed
"Security Deposit 5,000" with nothing to say it was dormant. It now carries a
"Not charged" badge naming the switch responsible.

Worth saying plainly: this is the opposite of the fee head's own Active flag,
which was fixed earlier today and means "we stopped charging this". These two
badges answer the same question - why is nothing happening - from the two
different places that can cause it.

### [2026-09-27] `dotnet run` works again, because UseUrls stopped overriding everything

`Program.cs` carried this, under a comment reading "ADD THIS LINE":

```csharp
builder.WebHost.UseUrls($"http://0.0.0.0:{Environment.GetEnvironmentVariable("PORT") ?? "8080"}");
```

`UseUrls` outranks `ASPNETCORE_URLS` **and** every launchSettings profile, so the
5055 / 7230 / 44383 profiles in this repo were decorative -- `dotnet run` always
tried `0.0.0.0:8080`. On a machine where 8080 sits in Windows' reserved port
exclusions, that dies with a bare `SocketException (10013)` naming neither the
port nor the cause, which is a genuinely miserable thing to hit on a fresh
checkout. It also bound every interface, putting the dev server on the LAN.

The fix is to honour `PORT` only when it is actually set. What makes it safe is
something the line itself hid: the Dockerfile **already** sets
`ASPNETCORE_URLS=http://+:8080` and exposes 8080, so production never needed this
line at all -- it was overriding an answer that was already correct. With `PORT`
set the binding is identical to before; without it, the Dockerfile's value takes
over and produces the same address.

Both paths were run, not reasoned about. Published to a temp directory (the
working copy's `bin\Debug` was locked by the user's Visual Studio, which is the
MSB3027 case this file's own gotchas section describes) and started twice:

- `PORT` unset, `ASPNETCORE_URLS=http://localhost:5099` → listening on 5099.
  Before this change it would have ignored that and tried 8080.
- `PORT=5098` with `ASPNETCORE_URLS=http://localhost:5099` → listening on 5098,
  and **not** on 5099. PORT still wins, which is what Railway depends on.

CLAUDE.md claimed `dotnet run` used port 5055 and had been wrong since this line
landed. It now says what decides the port.

### [2026-09-27] The backlog, and the file that would have undone this morning

Clearing the last of the list turned up something worse than anything on it.

**`fee_collection_point.sql` still defined `sp_school_admin_fee_head_manage`.**
That is the procedure `fee_head_identity.sql` rewrote hours earlier to protect
the fee head name. Running the older file -- which its own header invites, "safe
to re-run" -- would have silently put back the case-sensitive matching, dropped
the rename cascade, and removed the amount and billing-cycle validation, with no
error and nothing to notice. This repo already has seven files racing to define
the admission workflow procedure; that is how they drift. The definition is
deleted from the older file and replaced with a pointer to its current home. The
columns and backfill it actually owns stay. Proved by re-running it and checking
the validation was still in the live procedure afterwards.

**Delete now names the way out.** The refusal said "mark it inactive instead"
and stopped there, which moves the problem to whoever reads it. Cancelling a
receipt reverses `amount_paid` and `concession` on the ledger
(`fee_receipt_cancel.sql`), so once the receipts against a head are cancelled the
delete goes through -- the guard is an ordering requirement, not a wall. One case
genuinely has no way out: `fee_refund.sql` only ever *adds* to `refund_amount`,
nothing reverses it, so a refunded head can be deactivated and never deleted. The
message says so, because letting someone cancel receipts all afternoon for
nothing is worse than admitting it.

**`DeleteSetupFee` took any id.** The endpoint exists to clear the two cards on
the workflow page and would delete any fee head in the school. The caller holds
`fees.manage` and could do it from the Fee Head master anyway, so this was not a
security boundary -- it was a trap for the next person editing that page. It now
checks the id is one of the two it manages, and surfaces the procedure's message
instead of always reporting success.

**`display_order` is gone**, from the column, the procedure signature, the model
and both mappings: 22 heads on Railway, one distinct value, nothing non-zero, no
input on the page, and the only `ORDER BY` on it sorted by name in practice.
`registration_fee_amount` and `security_fee_amount` went too, with a guard that
refuses to drop them if a non-zero value ever appears -- the premise is that they
are dead, and a value would mean the premise is wrong.

**The timetable checks the room, not just the teacher.** A booking ties up two
things and only one was ever checked, so two sections could sit in Room 101 for
the same period in silence. The busy cursor now carries the room -- the entry's
own, else the section's -- and the check returns which half is double-booked:
"Teacher is", "Room 101 is", or both. The modal reacts as the room is typed,
since a clash found on save is found too late.

`isRealRoom` moved onto `EC` on the way. Classes & Sections had it, the timetable
needed the same answer about "N.A", and a second copy is precisely how the two
would have started disagreeing about what a room is.

All 16 suites: 500 checks, 0 failures. `settings_tests` caught the changed
procedure signature, which is the second time today a test has been the thing
that noticed.

### [2026-09-27] Eight files defined one procedure; now one does

`core.sp_school_admin_admission_workflow_manage` was re-created by eight
different migration files. Each was correct the day it was written, each widened
the parameter list a little further, and every one of them says "safe to re-run".
Running any of the older seven silently reverted everything the newer ones had
added -- no error, nothing to notice. The same shape had already been caught
hours earlier in `fee_collection_point.sql`, still holding a stale copy of the
fee head procedure.

`fee_charge_from_per_year.sql` is now the only file that defines it. The other
seven keep the columns and backfills that are genuinely theirs, and where the
procedure used to be there is a note saying who owns it and why the copy was
removed. The old `DROP PROCEDURE` statements went with it: the owner file handles
overload cleanup, and a stray DROP in a file nobody expects to matter is the next
version of this problem.

**The test found a second layer of it.** Re-running the seven left the procedure
byte-identical -- and put two dropped columns back. `security_fee_at_admission.sql`
still added `security_fee_amount` and `fee_charge_from_setting.sql` still added
`charge_fees_from`, both `IF NOT EXISTS`, both dropped on purpose earlier today
when the amounts moved to Fee Heads and the billing policy moved to the academic
year. Exactly the same "an old migration undoes a newer one" bug, one layer down,
and it would have been missed by reading the files instead of running them.

Verified the way it should be: drop the columns, hash the procedure definition,
run all seven files, hash again.

    proc md5 before   4ebf8327d71ee0f249575abece46cf82
    proc md5 after    4ebf8327d71ee0f249575abece46cf82   (identical)
    dead columns back 0
    overloads         1

All 16 suites: 500 checks, 0 failures.

### [2026-09-27] Fee Structure: a procedure with no source, and a save that was not one

**The procedure had no source file.** `core.sp_school_admin_fee_structure_manage`
existed in the live databases and in `database/backup_pre_cleanup/`, and nowhere
in `EduCoreDataAccessLayer/Database` -- so rebuilding from the scripts produced a
database without it. It has a home now, `fee_structure_manage.sql`.

**Saving a structure was not one operation.** It was a header call followed by
one call per fee head, each in its own transaction, and the header save
soft-deletes the existing details *before* the new ones are written. Anything
going wrong in between left a header with no details: a class the page lists as
configured that would bill nothing. Two such rows were sitting in the local
database (fee_structure_id 64 and 65, zero details, zero totals). The C# made it
invisible -- on an unexpected header result it skipped the details with
`continue` and still returned success, and the page's message counted the classes
that had been *asked* for, so it read identically whether every class saved or
none did.

The details now travel with the header as JSONB and the whole save is one call,
so it either happens or it does not. The rollups are computed inside the
procedure from the rows being written, which is also the only way the stored
totals cannot drift from the stored details. It collapses 1 + N round trips per
class into one, and an empty payload is refused before a header exists rather
than after.

**Quarterly and Half Yearly were filed under "Collected once per year".** The
controller overwrote each head's `FeeGroup` with a three-way bucket for the
page's headings -- destroying the real group (Academic / Transport / Optional
Services) and folding Quarterly and Half Yearly into "yearly". After this
morning's billing fix those are charged 4x and 2x, so the page was contradicting
the money. It groups by `Frequency` directly now, with a heading per cycle and
the real periods spelled out; empty cycles are skipped, since most schools use
two or three of the five.

**The list showed "Monthly 0" beside a large annual.** `quarterly_total` and
`half_yearly_total` did not exist as columns -- the amounts were folded into
`annual_total` and nowhere else. They exist now, are backfilled from the saved
details, and the column shows whichever cycles a structure actually uses. A
structure with no heads says so in red instead of showing an empty list.

Two things fell out on the way: `GetFeeStructureByClassAsync` was dead (nothing
called it) and its operation went with the rewrite, and the detail insert needed
an upsert rather than a plain insert -- `uq_school_fee_structure_details_head`
covers soft-deleted rows, so a head marked deleted moments earlier still owns its
key. The test caught that; reading the constraint list would not have.

Four behaviours verified against the real procedure, rolled back: all five cycles
save with annual 2,000 + 12,000 + 1,000 + 6,000 + 500 = 21,500; five detail rows;
re-saving with one head leaves one live row and resets quarterly to zero; an
empty payload is refused and writes no header. All 16 suites: 500 checks, 0
failures.

### [2026-09-27] Seventeen empty fee structures, and the line that made them

The live database had seventeen fee structures with a header, zero details and a
zero annual -- every class from Class 2 to Class 12 including all the stream
classes. The page listed each one like any other, so those classes read as
configured while billing nothing.

**The earlier entry blamed the non-atomic save. That was wrong.** The evidence
ruled it out: a failed save leaves *soft-deleted* details behind, and these
structures had none at all, deleted or otherwise. The cause was
`fee_head_cascade_delete.sql`, which HARD-deletes a head's structure rows and
then did this to whatever was left with nothing:

```sql
-- Structures left with no details at all → zero the totals.
UPDATE core.school_fee_structures
SET one_time_total = 0, monthly_total = 0, yearly_total = 0, annual_total = 0
WHERE ... AND NOT EXISTS (SELECT 1 FROM ..._details ...);
```

Zero the totals, leave it alive. Delete one fee head that every class shares and
you get one of these per class -- which is exactly the shape of the seventeen.

A structure whose last fee head just went is not a structure, so it is retired
now rather than zeroed, and the delete message says how many went with the head.
The recompute above it also gained `quarterly_total` and `half_yearly_total`,
which it had been leaving stale since those columns were added.

`fee_structure_retire_empty.sql` clears what the old behaviour produced. It is
idempotent -- it only touches structures with no live details -- and says how
many it retired rather than doing it quietly.

Six behaviours verified against the real procedures, rolled back: a structure
using only the deleted head is retired; a structure that used it alongside
another head survives; that survivor's annual is recomputed correctly; and the
message names the retirement. All 16 suites: 500 checks, 0 failures.

### [2026-09-27] Two versions of the money-collection procedure were live

`core.sp_fee_payment_collect` -- the procedure that takes a parent's cash and
writes the receipt -- existed twice on both databases: a 16-arg version without
`p_advance_used` and a 17-arg version with it. Calling it without naming every
parameter answered `procedure is not unique` instead of taking a payment. The
application happened to be safe because its C# passes all seventeen, so
PostgreSQL could resolve it; anything else -- a script, a report, a future
endpoint -- could not.

Five files defined it: `fee_collection_full_flow.sql`, `fee_collection_extras.sql`,
`fee_discount_meta.sql`, `fee_advance.sql` and `fee_payment_tenders.sql`. Each
added a parameter and created its own signature. `fee_advance.sql` holds the
full one (tenders *and* advance) and already dropped the 16-arg -- but
`fee_payment_tenders.sql` is dated two days later and re-created exactly that
16-arg without advance. Run them in date order and you get the pair.

This is the fourth instance of the same disease found today, after
`fee_collection_point.sql`, the eight workflow files, and the missing
`fee_structure_manage.sql`. It is the one that mattered most: the others
reverted behaviour, this one sat on the cash counter.

`fee_advance.sql` owns it now and the other four carry a note. Verified by the
test that exposed it -- a collect call that omits `p_advance_used`, which failed
with "is not unique" before and now records the payment -- and by re-running all
four retired files afterwards to confirm the second overload does not come back.

While proving it, the partial-payment question that started this got its answer.
Ten thousand due, four thousand paid:

    ZZ Admission Fee      due 6000  paid 4000  outstanding 2000  Partial
    ZZ Security Deposit   due 4000  paid 0     outstanding 4000  Pending
    receipt RCP-2026-0001 -> ZZ Admission Fee 4000.00

Partial collection at admission already works, itemised, with the balance left
in the ledger. What does not work is registration, which has no ledger row at
all -- that is the next change.

All 16 suites: 500 checks, 0 failures.

### [2026-09-27] A registration fee can be paid in parts, and the admission receipt appears

Two questions from the counter: what if a parent pays only part of the
registration fee, and where is the admission receipt.

**Admission already handled partials.** Worth stating because it was not
obvious: `PaymentAmount` is a free amount capped at what is due now,
`AllocateAdmissionPayment` spreads it across the freshly created dues capped at
each one's outstanding, and the rest stays in the ledger. Ten thousand due, four
thousand paid:

    ZZ Admission Fee      due 6000  paid 4000  outstanding 2000  Partial
    ZZ Security Deposit   due 4000  paid 0     outstanding 4000  Pending

What was missing was being *told*: the screen said "Receipt generated" and
nothing about the six thousand. It now names the balance and where to collect it.

**The admission receipt was generated and never shown.** The branch that runs
when a receipt exists attached a modal-close handler and stopped -- no open, no
redirect -- so the page sat there while the parent waited for a document that
already existed in the database. Its own comment admitted it: "Receipt not
auto-opened; print it from the fee history / list." One line, `EcReceipt.show`.

**Registration genuinely could not take a part payment.**
`enquiries.registration_fee_paid` is a boolean, the amount was always the full
Registration-point total, and `sp_registration_fee_record` wrote one row to
`core.fee_payments` and nothing else -- no details, no ledger. No due meant
nowhere for a balance to live.

The obvious fix is a `student_ledger` row, and it was measured and rejected: 23
SQL files read that table and 30 places filter on `student_id`, and at
registration there is no student, so `student_id` would have to go nullable and
every one of those 30 could then include or exclude enquiry rows by accident.
That is the billing core wagered on a small feature.

Two things already true did most of the work instead. `core.fee_payments`
already carries `enquiry_id` with a nullable `student_id`, so registration money
already lands in the same table as every other rupee and already reaches the
reports -- "history of every transaction" was already satisfied. And nothing
stopped an enquiry having several receipts.

So only the agreed amount was missing, and it goes on the enquiry, frozen at
registration so a later edit to the fee head cannot rewrite what a family was
told. **What has been paid is never stored** -- it is summed from the receipts
each time. A running total would drift and would have to be unwound by hand when
a receipt is cancelled; derived, the balance comes back on its own. That is the
seventh check below.

Verified against the real procedure, rolled back: 2,000 of a 5,000 fee leaves
"3,000.00 still outstanding" and the flag false; trying to take 9,000 is refused
naming the 3,000 actually outstanding; a second payment of 3,000 reads "received
in full" and flips the flag; two receipts against one enquiry; and cancelling
the second receipt puts the balance back to 3,000 with nothing touched.

Backwards compatible on purpose: a caller that does not mention a fee -- every
existing one -- has its payment treated as the whole fee, which is exactly the
old all-or-nothing behaviour. Three suites caught the first version, which
raised instead. All 16: 500 checks, 0 failures.

### [2026-09-27] An unpaid registration balance follows the child into the ledger

Part payment at registration works, and the remainder is derived from the
receipts against the enquiry. That holds right up to the moment the enquiry
becomes a student -- and then stops. Every screen that chases money reads
`core.student_ledger`, which is keyed on `student_id`, so the balance would sit
on a record nobody opens again and never be collected. The family would simply
never be asked for it.

At admission it becomes an ordinary due on the new student: it shows at the fee
counter, in the due list, on reminders and in the reports, and it is collected
and receipted like anything else.

It is billed under the school's own Registration-point fee head when there is
exactly one, so the line matches the fee master and the reports group it with
the rest of the registration money. With none or several, a plain "Registration
Fee" beats guessing which head was meant.

**Nothing is written back to the enquiry.** Its balance is derived from its own
receipts and keeps saying what happened at registration; from admission onwards
the student's ledger is where the money is chased. Nothing anywhere sums an
enquiry's balance into a student's dues, so the two cannot double-count.

**The first attempt was wrong and worth recording.** It patched
`sp_admission_manage` at runtime -- read `pg_get_functiondef`, string-replace,
`EXECUTE`. Clever, and it would have been erased the next time
`student_master_fields.sql` ran, which is precisely the "an old file undoes a
newer one" disease dug out of this repo four times today. The owning file was
edited instead.

Verified end to end against the real procedures, rolled back:

    registration  2,000 of 5,000 -> "3,000.00 still outstanding"
    admission     -> student ledger:
                       Tuition           Sep 2026 .. Mar 2027   1000.00  Pending
                       Registration Fee  Registration           3000.00  Pending
    audit         -> "Unpaid registration balance 3000.00 carried from enquiry 222"

And the two cases that must NOT produce a row: a registration already paid in
full (0 rows) and a walk-in admission with no enquiry at all (0 rows).

All 16 suites: 500 checks, 0 failures.

### [2026-09-27] The part-payment receipt, and a button that took money without asking

Two things reported from the Registration screen after part payments went in.

**The receipt printed the cash and nothing else.** Collect 900 of a 1,000
registration fee and the slip read "Registration Fee 900, Total Paid 900" -- true
about the cash and silent about the arrangement. The family goes home with a
document that reads like the fee was 900 and there is nothing left to pay. It
now prints the fee and what is still owed beside the amount received, and only
when there IS a balance, so a fully paid receipt is unchanged.

The numbers come from `sp_registration_fee_summary`, added because two screens
need the same three figures -- the receipt, and the collect dialog below. The
receipt procedure already returned `enquiry_id`; only the model had not mapped
it, so nothing there had to change.

**"Mark fee collected" posted the full fee on click.** No amount, no payment
mode, no reference, no confirmation -- and after part payments existed, no way
to take part of one. It opens a dialog now: student, fee, already received,
outstanding, an amount box that starts at the outstanding figure and says what
will still be owed as it is typed, payment mode and reference. On save it
collects, and then shows the receipt rather than leaving the cashier to find it
in a list while the parent waits.

Verified against the real procedures, rolled back, using the reported case:

    collect 900 of 1,000  -> "Part payment received. 100.00 still outstanding."
    summary               -> fee 1000, received 900, outstanding 100, paid flag false
    receipt               -> received 900, plus "Registration fee 1,000"
                             and "Balance payable 100"

All 16 suites: 500 checks, 0 failures.

### [2026-09-28] A receipt must not change after it is handed over

Reported as a question rather than a bug, which is how the good ones arrive:
part of the registration fee is taken from the Enquiry screen, the rest later
from the Registration screen -- what does the second receipt look like?

Running it exposed something worse than the second receipt. Yesterday's change
printed the balance on a part-payment receipt, and it asked for the balance
**now**. So collecting the final 100 silently erased the "Balance payable 100"
line from the 900 receipt that had already been printed and handed over. Reprint
it a week later and it says something different from the paper in the parent's
file. That is not a receipt.

It is computed as of the receipt now: the agreed fee, everything settled by live
receipts *before* this one, this receipt's own amount, and what was left after
it. Ordered by payment_id rather than date, because two payments on one day
still have an order and it is the order they were taken in. Cancelling a later
receipt cannot reach back and change an earlier one.

The second receipt also gains the context it had none of -- it now reads fee
1,000, received earlier 900, this receipt 100, balance 0, instead of a bare
"Registration Fee 100" that says nothing about what it completed.

Two procedures now, answering two different questions on purpose:
`sp_registration_fee_summary` is "where does this fee stand now", which is what
the collect dialog needs before taking money, and
`sp_registration_receipt_context` is "where did it stand when this receipt was
written", which is what printing needs. Collapsing them into one is exactly the
mistake that caused this.

Verified against the real procedures, rolled back:

    Receipt A (900 from Enquiry), reprinted after BOTH payments
        fee 1000 | earlier 0   | this 900 | balance 100   <- unchanged
    Receipt B (100 from Registration)
        fee 1000 | earlier 900 | this 100 | balance 0
    Receipt B cancelled, A reprinted
        balance still 100

All 16 suites: 500 checks, 0 failures.

### [2026-09-28] The admission side of a part payment

Same walk-through as registration, on the admission screen. The money was
already right -- the amount box is free, capped at what is due now, and the
allocation caps each line at its own outstanding -- so what was left was
everything around it.

**The counter said nothing about the remainder.** Typing 4,000 against 10,000
due gave no reaction at all; the balance only surfaced later on the fee screen,
by which time the parent has gone. It now says what will still be due as the
amount is typed, and where to collect it.

**The receipt said nothing either.** A fee receipt had no concept of a balance
at all -- itemised lines and "Total Paid", nothing else. It carries the
outstanding now.

**And the first version of that was wrong in a way worth writing down.** Summing
every open ledger row put the whole year's unbilled monthly instalments on the
slip: a parent settling 4,000 of the 10,000 owed at admission would have read
"Outstanding 13,000", or on a student with a full year loaded, 4,35,000. True
arithmetic, useless document, and genuinely alarming. A receipt states what is
owed *now*; the year ahead is a fee structure, not a debt. Only dues that have
actually fallen due are counted.

It is also dated -- "Outstanding as on 28-Sep-2026" -- and deliberately not a
frozen snapshot like the registration receipt beside it. A registration fee is
one agreed figure, so "the balance when this was written" is a real thing to
freeze. A student's dues keep being generated all year, so there is no honest
fixed number; what there is, is what they owe today, and the line says so in as
many words instead of implying otherwise.

Verified end to end against the real procedures, rolled back:

    admission   6,000 + 4,000 due now, plus Sep tuition 1,000
    collect     4,000
    receipt     Total Paid 4,000
                Outstanding as on 2026-09-28   7,000
                (summing everything would have said 13,000)

All 16 suites: 500 checks, 0 failures. No SQL changed.

### [2026-09-28] The receipt read like two charges, and three screens never handed it over

Checking the Enquiry path found that the registration receipt was still wrong,
just differently from before.

**It printed two lines that looked like the same thing.** Yesterday's balance
rows went into the adjustments block, which sits ABOVE "Total Paid" among the
charges, so a part-paid registration read:

    #  Particulars              Amount
    1  Registration Fee            900     <- the charge
       Registration fee          1,000     <- the fee total
       Balance payable             100
       Total Paid                  900

Two near-identical labels with different amounts, stacked. Adjustments are
deductions from what is being paid; a balance is not one. It is its own small
boxed summary below the total now -- fee, received earlier, paid on this
receipt, balance -- in all three layouts, and a single full payment prints with
no block at all, exactly as it always did.

**And the receipt was never shown on the Enquiry path.** Registering with a fee
from the CRM generated a receipt and told nobody: the modal and the renderer
were already included on the page and simply never called, under a comment
saying to print it from the Registrations list instead. The walk-in form on the
Registrations page did the same -- `receiptNo` came back in the response and was
dropped on the floor.

That is now the fourth and fifth instance of this one pattern, after the
admission screen and the Registrations list button. The receipt exists, the
renderer is wired up, and a comment explains why it is not being used.

`ManageFee` is deliberately left alone. It does not auto-open either, and there
the stated reason holds: a cashier working a queue does not want a modal after
every payment, and the history list has a Print button. Admission and
registration are one-off moments with a parent waiting.

All 16 suites: 500 checks, 0 failures. No SQL changed.

### [2026-09-28] Both balance blocks were dead code, and the tests had not noticed

Checking the admission receipt found that neither balance block had ever
printed -- not on the admission receipt, and not on the registration one either,
which is why it still looked wrong after yesterday's work.

`sp_fee_receipt_get` returns the student's NAME, admission number and class, all
resolved through `LEFT JOIN core.students` and `LEFT JOIN core.enquiries` -- and
never returned `student_id` or `enquiry_id` themselves. The C# mapped both, got
0 from `DbRead.Int` (which tolerates a missing column by design), and the
controller's guards -- `r.EnquiryId > 0` and `r.StudentId > 0` -- were false
every single time. Both features were wired end to end and switched off by one
missing column.

**Worth being honest about how this got through.** The procedures were tested
directly and passed, and the layout was rendered from a hand-built payload and
looked right. Neither exercise touched the join between them: the thing that
returns the receipt and the thing that answers "what is still owed" were never
asked to work together. Verifying two layers separately is not the same as
verifying the path, and a `DbRead` helper that tolerates missing columns turns
that gap into silence rather than an error.

The header returns both keys now. Verified through the real procedures:

    admission receipt     student_id 1948, enquiry_id 0 -> dues block computes
    registration receipt  enquiry_id 252, student_id 0  -> fee 1000, balance 100

All 16 suites: 500 checks, 0 failures -- and none of them caught this, because
no test asserts on what a receipt prints. That is the gap worth closing next.

### [2026-09-28] Day Close showed ₹0 without saying why

Reported as a bug: fees were collected, and `ERP/Fee/DayClose` still read zero.

The procedure was right. Run against live data it answers correctly:

    user 53 (who collected), 27 Sep  ->  48,500 across 13 receipts
    any other user,          27 Sep  ->  0
    user 53,                 28 Sep  ->  0

`sp_fee_day_collection_get` filters on `created_by = p_action_user_id`, and that
is deliberate -- a day close reconciles *one drawer* against *one cash count*.
Totalling the whole school on this page would make the cash-count line
meaningless. So a zero means "not my counter" or "not this date", never "the
money is missing".

The page simply never said so. A bare ₹0 after a day of collection reads like
lost money, and there was nothing on screen to suggest looking at the date or
at whose login was being used.

The summary cursor now also returns `school_collected` / `school_receipts` --
the same day across every cashier. They take no part in the reconciliation;
they exist so the page can tell the two cases apart:

- collected 0, school > 0  -> "You collected nothing on this date. The school
  took ₹48,500 across 13 receipt(s) at other counters."
- collected 0, school 0    -> genuinely a quiet day, nothing added.

The headings say whose sheet it is now ("Your own counter", "Your receipts
only"), and the empty mode table says "You collected nothing on this date"
rather than a flat "No collection on this date", which claimed more than it knew.

### [2026-09-28] The server was on UTC, so five and a half hours of every day had yesterday's date

Reported as "Day Close shows 0 even after collecting". The previous entry
explained the per-cashier scoping and added a note to the page. That was not the
whole answer, and the follow-up -- *"but collection to aaj kiya hu"* -- was right.

The payments were stamped 27 September. They were taken on the 28th:

    Railway server   2026-09-27 22:12 UTC     TimeZone = Etc/UTC
    India, same moment  2026-09-28 03:42       <- when the money was actually taken
    stored           payment_date = 2026-09-27

`sp_fee_payment_collect` does `v_date := COALESCE(p_payment_date, CURRENT_DATE)`,
the app passes NULL, and `CURRENT_DATE` on a UTC server is the UTC date. The page
asks the browser for today and gets the India date. They disagree from midnight
until 5:30 am, every night.

Day Close was only where it got noticed. For those five and a half hours a
receipt printed yesterday's date, a fee register missed the row, and an admission
made at 1 am was dated a day early. It never showed up in development because the
developer machine's PostgreSQL is on Asia/Calcutta -- only the hosted database
was on UTC.

**Not fixed one call site at a time.** There are 426 uses of `CURRENT_DATE`,
`now()` and `CURRENT_TIMESTAMP` across the procedures and 30 of `DateTime.Now`
in C#. Editing them individually is how this kind of thing goes wrong. Instead,
one setting at each end:

- `school_timezone.sql` sets the database's own timezone to Asia/Kolkata. All 426
  are correct from that moment, and no procedure is touched. It also carries a
  one-shot correction for the payments already written in UTC -- guarded twice:
  by a new `core.schema_marks` row so it cannot apply twice, and by reading the
  timezone *before* changing it, so it does nothing on a database that was
  already on India time. Run on the dev machine it correctly did nothing.
- `Dates.Now` / `Dates.Today` are the app's clock, and the fourteen files that
  asked the server for the time now ask them instead.

`Dates` uses a fixed +05:30 rather than a named zone on purpose. India has had no
daylight saving since 1945, so the offset is exact, and a named lookup needs the
tzdata package that slim container images leave out -- without it the lookup
throws, or silently falls back to UTC, which is the bug itself.

One consequence worth naming: `EnquiryModel.TimeAgo` used to compare
`DateTime.UtcNow` against a `created_at` assumed to be UTC. With the database on
India time that assumption would have made every follow-up read five hours stale
-- the exact symptom a comment there already warned about. Both sides of that
subtraction are now the school's clock.

### [2026-10-10] Classes & Sections saved in place; academic years can no longer lose their current session

**Files changed**
- `Database/academic_year_class_section_fixes.sql` (new; supersedes the year proc in
  `fee_charge_from_per_year.sql` and the setup proc in `academic_class_section_fields.sql`)
- `Services/Repository/ERP/SchoolSettingsService.cs` (setup JSON carries `originalName`;
  PostgresException logged at Warning), `Models/ERP/AcademicSetupModel.cs`
- `Areas/ERP/Controllers/SchoolSettingsController.cs` (ClassSection + AcademicYear actions, DTOs)
- `Areas/ERP/Views/SchoolSettings/AcademicYears.cshtml`, `ClassSection.cshtml`
- `Database/tests/settings_years_classes_tests.sql` (new, 177 checks)

**What and why**
- **Classes & Sections save is no longer delete-all + re-insert.** Every save gave every
  class and section a new id, and `class_subjects`, `exam_subjects` and `timetable` (keyed
  by id) were left pointing at deleted rows — an unchanged Save took a school's subject
  mappings from 49 to 0. The proc now matches each class/section by the name the page
  loaded (`originalName`), then by name, updates it in place and only soft-deletes what was
  really removed. A renamed class keeps its id and carries its name into the session's fee
  structures; renaming one that has students is still refused.
- **A session can not be renamed once anything stores its name** (students, enrolment, fee
  structures, attendance, transport, TC register, enquiries, admission/registration
  counters). Refusing was chosen over a cascade: nine tables, counters that would restart
  numbering, and receipts/TCs already printed with the old name.
- **The school always has exactly one current session**: set-current/edit/delete check the
  id belongs to this school first (an unknown id used to clear every flag), and the current
  session can not be un-ticked or deleted.
- Overlapping sessions refused; dates required with end after start; name ≤ 20; a deleted
  session's name can be reused (`uq_academic_year` replaced by a partial unique index).

### [2026-10-10] School Settings test pass: subjects, class teacher, periods, profile, workflow, fees

A real-world test pass over the ten School Settings pages (four new SQL suites in
`Database/tests/settings_*_tests.sql`, 604 checks, all rolled back). Every bug they found
is fixed; the year/class-section part is the entry above.

**New scripts:** `Database/school_scope_fk.sql` — composite FKs `(tenant_id, school_id)` from
`school_profiles/addresses/contacts/settings/admission_workflow_settings` to `core.schools`,
so a tenant/school pair that does not exist can never get settings rows (the procs only
checked `tenant > 1 && school > 0`). Purge already deletes these children first.

**Subjects / class teacher / periods**
- `subject_management.sql`: a save goes under the class's OWN session (it defaulted to the
  current one, so next session's classes were saved into this session); duplicate names
  counted once; a subject taken off a class also leaves that class's timetable; inactive
  classes refused; names over 80 chars get a readable message.
- `class_teacher_session*.sql`: the teacher pool and Assign accept only active *teaching*
  staff of the same school (any staff id was accepted, including another school's).
- `period_structure.sql`: the save renumbers periods, and timetable lessons are keyed by that
  number — so adding an assembly moved every lesson one period. Lessons now follow their
  period by label; removing (or making non-teaching) a period that has lessons is refused.
- Views: stored XSS in subject pills (`EC.esc`), numeric class/subject names (`attr` not
  `data`), dirty-state after switching class, Period Structure's fake up/down reorder removed,
  full legend, unsaved-changes warning; an inactive class teacher no longer shows "Unassigned".

**Profile / Documents / Workflow**
- District id can no longer outlive its text or state (`COALESCE` kept Gurugram under Delhi).
- Manual registration numbers must be unique per session (`enquiry_registration.sql`).
- Workflow fee cards can not take over another head by typing its name (controller guard +
  fee-head proc rule) and re-activate a switched-off head; a failed settings read disables Save.
- BasicProfile: website without a scheme gets `https://`, bad logo extension is a validation
  message (was a 500), established year capped at this year, read-only data kept after a
  failed save, DB errors logged. The TC dialog opens on the saved default format.

**Fee head / structure** (`fee_head_identity.sql`, `fee_structure_manage.sql`,
`fee_head_list.sql`, `fee_head_cascade_delete.sql`)
- A rename rewrote receipt lines of EVERY school with that head name; now scoped to this school.
- Structure lines must be live heads of this school; name/cycle come from the master;
  negative amounts, blank class/session refused; totals from rounded amounts.
- A billing-cycle change now updates this school's saved structures (admitted ledgers stay).
- Cycle stored in its standard spelling; fee type must be Mandatory/Optional.
- `ecToast` escapes HTML (TempData messages carried head names into toastr).

### [2026-10-10] Money across admission and the student lifecycle: closed, never deleted

Test pass `tests/money_admission_lifecycle_tests.sql` (catalog
`educore/docs/test-cases/money_admission_lifecycle.md`) found 26 bugs; all fixed here.

**New building blocks — `student_money_lifecycle.sql` (apply FIRST, then the procs below).**
- `student_ledger` gains `academic_year`, `fee_head_id` and a CLOSE trail: `closed_amount`,
  `close_reason`, `close_source`, `closed_by`, `closed_at`. Closing a due drops `amount_due`
  to what was settled and keeps the rest in `closed_amount`, so every existing "outstanding"
  formula reads 0 without being changed, receipt lines keep pointing at a real row, and the
  close can be undone exactly (`fn_ledger_close` / `fn_ledger_reopen`).
- `fn_plan_periods` + `fn_student_bill_plan`: the month arithmetic moved out of
  `sp_admission_manage` so admission, promotion and a class change bill a plan the same
  way. One plan per student per session (`student_fee_plan.academic_year/is_current`).
- `fn_class_fee_plan` (recurring heads of a class structure), `sp_plan_instalments`,
  `sp_student_fee_totals`, `sp_student_history_get` (audit + promotion + closed dues + bus +
  refunds — none of that was readable anywhere before).

**Procs** — `student_master_fields.sql` (plan validation, advisory lock against concurrent
duplicate admissions, one admission per enquiry with `FOR UPDATE`, list Fee Due honours
concession) · `transport_module.sql` (student must be this school's and active; billing
clamped
to the session's real end date; route change / removal CLOSE unpaid months with a reason
instead of deleting them; a part-paid month is topped up, not re-billed) · `student_exit.sql`
(exit closes dues after the leaving date and ends the bus; reactivate restores exactly that,
writes an audit row, refused while a live TC exists) · `student_promotion.sql` (Promote /
Retain bill the target class's recurring structure for the new session and re-bill a kept
bus route; PassOut closes later dues) · `student_update.sql` (class must exist in the
student's session, section in the class; enrolment follows; class change closes the old
class's later instalments and bills the new one from next month when it has a structure;
audit row) · `transfer_certificate.sql` (TC refused while the advance wallet holds money;
void needs a reason) · `student_list.sql` (Fee Due honours concession).

**C#** — `AdmissionController` builds the plan, totals and concession on the server from the
fee structure (the browser used to supply amounts), shares an "Estimated annual" concession
in proportion instead of front-loading it, holds an over-cap concession for approval, names
the fallback deposit after its real fee head, and reports receipt / bus failures; the
Create page shows them (`feeMessage` was never read). Transport month counts are left to
the proc. Student Dashboard totals come from the whole ledger, plus an Activity & Money
History card. `AdmissionService` / `TransferCertificateService` log `PostgresException`.
`transport_tc_tests.sql` C3 was updated: it counted deleted rows, now it checks that the
closed rows are no longer owed and carry a reason.

### [2026-10-10] Money reports and Day Close: one story, and a closed day that stays closed

A test pass over Day Close, the three report tabs, Fee Due reminders and the dashboard
money tiles (`Database/tests/money_reports_dayclose_tests.sql`, catalog
`educore/docs/test-cases/money_reports_dayclose.md`) found 31 bugs. All of them are
fixed in the files below.

**Files changed**
- `Database/fee_day_close.sql` — new `core.fn_fee_money_lines`, `core.fn_fee_day_closed`,
  `core.fn_user_display_name`, `core.sp_fee_day_reopen`, table `core.fee_day_close_log`,
  columns `fee_day_close.reopened_at/by/reason`; `sp_fee_day_collection_get` gained a
  history cursor (old 2-cursor overload dropped).
- `Database/fee_reports.sql` — register gained `p_class/p_section` (old overload dropped);
  defaulters rewritten.
- `Database/dashboard_summary.sql`, `fee_due_list.sql`, `fee_concession_cancel_report.sql`,
  `fee_refund_register.sql`, `fee_reminder_log.sql`.
- `FeePaymentService.cs` / `IFeePaymentService.cs` (report methods + `ReopenDayAsync`),
  `Models/ERP/FeeCollection.cs`, `FeeDueModel.cs`, `FeeController.cs` (report actions +
  `ReopenDay`), `FeeDueRemindersController.cs`, views `Fee/DayClose`, `Fee/Reports`,
  `FeeDueReminders/Index`.
- Apply order: `fee_day_close.sql` first. The other report scripts call its functions.

**What and why**
- **Expected cash was wrong whenever a receipt was not plain cash.** Every report grouped by
  the receipt *header*. That header says "Mixed" for Cash+UPI and records the settled amount
  for an overpayment or a wallet payment. On the test day an exact drawer count of 10,800
  was recorded as "Excess 1,400". `fn_fee_money_lines` turns receipts into tender lines.
  Day Close, the register and the dashboard all read it now, so they cannot disagree.
  `FeeModule.md` claimed this had been done since the split-tender work; it had not.
- **A closed day changed afterwards.** Two causes: money could still be collected into a
  closed day, and cancelling an old receipt removed it from its own day. User decision:
  a cancellation counts on the day it is cancelled, in the canceller's drawer, as a
  negative line. `fn_fee_day_closed` is the lock that the collect and cancel procs call.
  Re-closing used to overwrite the first count. Now a close must be re-opened with a
  reason, and every close and re-open is kept. Future dates and negative counts are refused.
- **"Outstanding" overstated the debt.**
  - It included every instalment for the rest of the year. A family paid up to date was
    listed as a defaulter, and a reminder told a parent they owed the whole year.
  - It is now what has *fallen due*, under one rule for Defaulters, the Fee Due list and the
    Dashboard.
  - Students who left are listed while they owe. The Fee Due list used to hide them, so the
    two totals disagreed.
  - A registration fee part-paid before admission is its own Defaulters row.
- **The dashboard's "Highest outstanding" multiplied each student's dues by their receipt
  count.** It joined payments into the ledger GROUP BY.
- **Audit gaps.**
  - The concession register missed registration discounts.
  - No register showed the *user* who cancelled or refunded; only a free-text authoriser.
  - SendReminders dropped selected students who were outside the first page.
  - Export stopped at 200 rows, because ListModelBase caps PageSize. It now reads every page.
  - The reminder log accepted another school's student.
  - DayClose's "the school took ₹X at other counters" note never showed: the JSON never
    carried `schoolCollected`.

**Still for other owners:** `sp_fee_receipt_cancel` must refuse when
`core.fn_fee_day_closed(tenant, school, canceller, today)` is true. Until it does, DC-21 and
DC-21a stay red, and a closed day can still move by a cancel from that cashier.

---

### 2026-10-10 — Fee collection: every money path leaves a history (collect / cancel / refund / reprint)

Found by `tests/money_fee_collection_tests.sql` (catalog: `educore/docs/test-cases/money_fee_collection.md`).

- **Collect engine (`fee_advance.sql`).**
  - The same due sent twice in one request was paid twice over. Lines are now merged per
    ledger row, and every row is locked `FOR UPDATE` in id order before its outstanding is
    checked. Two counters can no longer over-collect it either.
  - An extras-only receipt never checked whose student it was, so it was issued for another
    school's student or an id that does not exist. The student must now belong to the school.
  - A negative tender, an `Advance` tender (dues settled from an empty wallet), advance used
    beyond the bill (the wallet lost the excess), a concession with no reason, a concession on a
    refundable deposit, and a cheque / DD with no number are all refused.
  - `client_ref` (unique per school) means a retried Collect returns the first receipt.
  - `discount_approved_by` records who approved a concession.
  - Collecting after the counter closed today is refused (`fn_fee_day_closed`).
  - The signature grew to 19 args. The two new ones come *after* `p_result`, so positional
    callers keep working.
- **Cancel (`fee_receipt_cancel.sql`).**
  - Refused when money on the receipt was already refunded, or when the credit it created was
    already spent (the wallet went to −1400).
  - Refused when the canceller's today is closed.
  - A registration receipt recomputes the enquiry's paid flag. After admission it raises a due
    for the reversed amount.
  - History now returns who collected and who cancelled, when, and on whose authority.
- **Refund (`fee_refund.sql`).**
  - The advance wallet can be refunded at exit (ledger id 0).
  - Vouchers are numbered per school per year.
  - More than two decimals is refused (0.004 used to make a ₹0.00 voucher).
  - Refundability is looked up by the head's id, not its name.
  - A closed-today cashier can't refund.
  - New `sp_fee_refund_history_get` puts refunds in the student's Payment History.
- **Reprint.** `sp_fee_receipt_get` returns `is_cancelled` with who, when and why, plus the
  cashier, the discount amount and approver, and the tender split with references.
  `fee-receipt.js` prints a CANCELLED banner, the split mode by mode, and the cashier.
  A refund voucher can be printed.
- **Counter (`ManageFee.cshtml`).**
  - Each tender has a reference input; a cheque or DD number is required.
  - Discount needs "Approved by"; cancel and refund need an authoriser.
  - The extra-charge note is now sent.
  - History lists refunds, the wallet is refundable, and a settlement id goes with every Collect.
- **Database guards (`fee_money_guards.sql`, new).**
  - A ledger CHECK enforces: amounts ≥ 0, paid + concession ≤ due, refunded ≤ paid.
  - Wallet ≥ 0, and tender lines > 0.
  - The ledger and wallet FKs to `students` changed from CASCADE to RESTRICT. `sp_school_purge`
    deletes those rows first, so it still works.
  - Receipt lines and tenders still cascade from their header on purpose: only purge deletes
    a header.
- **Tests.**
  - `money_fee_collection_tests.sql`: 122 / 0.
  - Older suites now pass a concession reason (`admission_fee_tests`, `money_trail_tests`).
  - `settings_fee_head_structure_tests` J14 now takes the money and refunds it through the
    procs, instead of writing an impossible "refunded but never paid" row.

### [2026-10-10] Fee permissions split; refundable tag on the counter; one deploy bundle

- **`fee_permissions_split.sql`**: `fees.collect`, `fees.cancel`, `fees.refund`, `fees.concession`
  added; every role holding `fees.manage` was granted all four, so nobody lost access. Collect /
  CancelReceipt / Refund use them; a concession inside Collect, registration with a fee
  (RegisterEnquiry, RegisterWalkin), Registration MarkFeePaid and money taken at admission are
  checked in the action via `HasPermissionAttribute.UserHasAsync`. The Roles page shows finer
  actions as extra ticks under the View/Manage row (`MatrixFeatureRow.Extras`).
  `fees.manage` still covers fee setup, day close and re-open.
- **`student_dues_refundable.sql`**: `sp_student_dues_get` returns `is_refundable`; ManageFee tags
  those dues and keeps a discount off them. `student_dues.sql` is marked SUPERSEDED: re-running
  it brings back a version that ignores concession.
- `fn_user_display_name` was defined differently in `fee_advance.sql` and `fee_day_close.sql`;
  the two are now identical so run order cannot change it.
- **`deploy_2026_10_10.sql`** runs every changed script in dependency order (verified end to end
  locally, then all 24 suites: 1,578 checks green).

### [2026-10-10] Inventory: deep test pass and fixes (stock = sum of its movements, again)

A deeper suite (`tests/inventory_store_tests.sql`, catalog `educore/docs/test-cases/inventory_store.md`)
found 10 failing checks plus UI and permission bugs. All fixed. The suite is 142 / 0 and
`inventory_tests.sql` 49 / 0.

- **Cancel corrupted stock (HIGH).** The CANCEL loop read `current_stock` once for every line, so
  a bill with the same item on two lines left stock 52 against a ledger of 22. The same stale read
  let a cancel take true stock to -15. Now the cancel locks the items, checks per ITEM (the whole
  bill's quantity), then reverses line by line with `UPDATE ... RETURNING`.
- **Permissions (HIGH).** The controller was gated on `fees.view` for reads and writes alike. It is
  now `inventory.view` on the class and `inventory.manage` on all seven write actions (cancel
  included). The sidebar (`_VerticalMenu.cshtml:66`) still uses `fees.view` and needs the same
  change by whoever owns that file.
- **Decimals.** A quantity of 0.335 rounded differently in the item (9.67) and the ledger (-0.34),
  so stock drifted. Quantities and prices now take at most 2 decimals (proc and page).
- **Bill totals.** Each line rounds its base and tax once, and the header is the sum of the
  lines. Before, the header could be a paisa off its own lines.
- **Duplicates.** The bill-number index keys on `COALESCE(supplier_id, 0)`, so a no-supplier bill
  can no longer be entered twice. Duplicate item, SKU, supplier and bill numbers are caught in the
  procs with plain sentences instead of the index name.
- **Rules (user-approved defaults D-1..D-11).** No negative opening stock or prices (with table
  CHECKs behind the procs: `current_stock >= 0`, prices >= 0). Inactive items cannot be issued or
  bought. The unit is frozen once stock has moved. A cancel needs a reason. Future-dated bills
  are refused, back-dated ones allowed. New `StockTake` movement: enter the counted quantity, the
  signed difference is recorded, and a reason is required.
- **History.** Every movement keeps `unit_rate` (new column; NULL on older rows). The item history
  shows who made each movement, the rate and the bill number, in date order then entry order,
  with a running balance in that order.
- **Service.** `InventoryService` now has an `ILogger` (Warning with SqlState for PostgresException,
  Error otherwise) and maps raw database errors to sentences. Filter dates go through `Dates.Norm`,
  the purchase date is validated, and a line with no item is refused instead of dropped.
- **Pages.** The purchase page's four hard-coded cards (Rs 42,500 / 18 / 560 / 12) now show real
  figures. Confirm dialogs use `EC.confirm` / `EC.prompt`'s real options: "Cancel purchase" no
  longer reads "Delete". The default purchase date comes from `Dates.Today` instead of UTC
  `toISOString()`. Stock value is labelled "at cost price".
- `inventory.sql` stays re-runnable (procs dropped and recreated; index and constraints dropped
  and re-added). It is not yet in `deploy_2026_10_10.sql`.
- Not done (features, not bugs): supplier list/edit screen, purchase detail view, transfers and
  partial returns (D-10).


### [2026-10-10] Platform, access and security: test pass and fixes

Suite `Database/tests/platform_access_security_tests.sql` (catalog
`educore/docs/test-cases/platform_access_security.md`). First run: 79 passed, 23 failed. After the fixes: **123 passed, 0 failed**.

- **Custom roles can sign in.** `AccountController.IsValidSaasScope` used to accept only the built-in codes. It now treats every code except SUPER_ADMIN/TENANT_ADMIN as a school role.
- **A cookie no longer outlives the account, the school, or the password.**
  - New `Helpers/SessionValidator.cs`, wired as the cookie's `OnValidatePrincipal`, asks `core.sp_session_check` at most once a minute per user (AppCache).
  - It rejects the cookie when the user is deactivated or deleted, when the school stops allowing sign-in, or when the `pwd_stamp` claim no longer matches `core.users.password_changed_at` (new column). Change password, OTP reset and admin resets all set that column.
  - Change Password re-issues the current cookie with the new stamp and keeps its properties, so remember-me survives.
  - `PermissionService` now resolves roles through the new `core.sp_user_roles_effective`, which is empty for an inactive user or a blocked school.
- **Staff Inactive = login off.** `sp_staff_manage` DELETE also switches off the login, and REACTIVATE turns it back on, with email/phone clash checks.
  - A one-off fix in `access_security_hardening.sql` switched off the 5 existing inactive-staff logins. It never touches the last admin of a school.
- **Role rules (decisions D-2, D-3).**
  - Role ids must belong to the tenant.
  - Nobody can change their own roles or deactivate their own login.
  - Only a school admin (or the platform) can grant or remove SCHOOL_ADMIN.
  - The last active school admin of a school cannot lose the role or be deactivated.
  - StaffController drops the role cache and session cache for the user id the database resolves, not the posted form value.
- **Roles.** New roles never get a reserved code ("Super Admin" becomes SUPER_ADMIN_2, not a hidden full-bypass role). The matrix refuses permission ids that are not in the catalog. The role key cache is per tenant, so a matrix edit applies at once in every school of the tenant (D-1).
- **Password reset.** An unknown account answers INVALID, like a wrong code, so the form no longer reveals which accounts exist. Reset by phone uses login's digits-only match.
- **Audit (D-6).** New `core.fn_admin_audit` writes `admin_activity_logs` rows for:
  - role create, rename and delete;
  - every matrix change, recorded as old -> new;
  - user role changes;
  - login activation and deactivation;
  - admin password resets.
  School create, status change, admin creation and super-admin resets are logged on tenant 1, so they survive a purge.
- **SuperAdmin.**
  - `sp_school_manage` INSERT/UPDATE/DELETE are platform-only.
  - Phone checks use `fn_user_phone_taken`, so a duplicate gets a message instead of a raw constraint error.
  - An admin created from Edit is forced to reset their password.
- **Purge.** `sp_school_purge` now covers the 15 tables added since it was written (exams, inventory, leave/payroll, enrolment, promotion, day-close log) plus the two edit-history tables. Schools that ran exams can now be purged.
  - The archive drops `password_reset_tokens` and strips the password, token and refresh-token hashes from every row.
  - SchoolsController deletes the archive file if the purge then fails.
  - Purging a tenant's only school keeps the tenant and its roles (D-7).
- **Rate limit behind Railway (SEC-10).**
  - `UseForwardedHeaders` now clears KnownNetworks/KnownProxies, so `RemoteIpAddress` is the real client and the 5-per-5-minute login limit is per visitor, not site-wide.
  - Login attempts now record the IP and user agent.
  - `Security:RequireHttps` stays false. With X-Forwarded-Proto honoured, turning it on no longer loops.
- **Dashboard (D-5).** Money cards, trend, payment modes, defaulters and recent receipts need `fees.view`. Without it they are emptied in the controller and hidden in the view.
- **Deploy order:**
  1. `academics_edit_history.sql` (the purge deletes from its tables)
  2. `access_security_hardening.sql`
  3. `change_password.sql`
  4. `forgot_password.sql`
  5. `sp_rbac_manage.sql`
  6. `sp_staff_manage.sql`
  7. `sp_school_manage.sql`
  8. `school_purge.sql`

### [2026-10-10] Daily academics: attendance, exams, timetable, calendar follow one set of rules

Test pass and fixes for Attendance, Exams, Timetable, School Calendar and Smart Bell. Catalog: `educore/docs/test-cases/academics_attendance_exams.md`. Suite: `Database/tests/academics_attendance_exams_tests.sql` (137 pass; one deliberate BUG check left: ATT-B8, the class-teacher gate in `core.sp_class_teacher_manage` ignores an inactive teacher, which belongs to the settings area).

- **One answer to "is the school open?"** New `academic.fn_school_day_type(tenant, school, date)` returns holiday / weekly_off / half_day / working, the same answer the Smart Bell gets.
  - Attendance refuses declared holidays and configured weekly offs, and accepts declared working days. There is no longer a hard-coded Sunday rule.
  - A half day is a normal attendance day; only the bell changes.
  - Exam papers on a closed day are refused.
  - Half-day closing times must fall inside the period structure.
- **Attendance save is scoped to the class-section.** `core.sp_attendance_save` gained `p_class, p_section`. **Signature change:** the old 6-argument overload is dropped.
  - `core.fn_attendance_register` defines who is on a register for a date; the roster and the save both use it.
  - A teacher approved for 7-A can no longer post 7-B students.
  - Students not yet admitted, or already left, are refused by name; a back-dated day still lists a student who left later.
  - Unknown statuses are refused.
  - Unchanged marks are not rewritten.
- **Attendance % counts only the days a student belonged.** Mid-month joiners, leavers and section changers no longer read 50% or 150% (`core.fn_attendance_student_days`). `core.sp_attendance_month_register` (**signature change:** new `p_days_off` cursor):
  - keeps leavers and movers for the days they sat there;
  - shows marks by the class-section snapshot;
  - returns per-student `school_days` and the calendar's days off.
- **Edit history.** `academics_edit_history.sql` adds `core.student_attendance_history` and `academic.exam_marks_history`. AFTER UPDATE triggers write old value, new value, who and when, only on a real change.
- **Exams.**
  - `to_char` on the text date columns was fixed (hotfix kept).
  - A paper that has marks cannot be removed, and its max cannot drop below an entered mark.
  - An exam with finalised sheets cannot be deleted; it can still be unpublished.
  - Marks are refused on a Draft exam and on a section the exam does not cover.
  - Finalise turns blank draft rows into Absent.
  - Results join papers on (exam, class, subject). A multi-class exam with a shared subject was being counted three times. Orphan or not-entered marks no longer reach the totals.
  - The exam list no longer shows another school's session name.
- **Timetable.** SaveCell now requires all of the following:
  - a subject the class studies;
  - an active teaching staff member of this school;
  - a working weekday;
  - a free room. Room clashes are enforced server-side via `academic.fn_room_key`, the same rule as `EC.isRealRoom`.
  The picker lists teaching staff only. Copy Day skips busy rooms too.
- **UI.**
  - Attendance page: escapes names, keeps Late/Leave, shows "not marked yet", uses the server's date, and shows `EC.listEmpty` on failure.
  - Report: per-student %, calendar shading, CSV formula guard.
  - The mock `/ERP/Student/StudentAttendance` page (fake students, a Save that saved nothing) is removed.
  - The dead localStorage mirror in Subject Management is removed.
  - Attendance, Exam, Calendar and Timetable services now log rejected proc calls at Warning.
- **Deploy order:**
  1. `hotfix_2026_10_10.sql` (if not yet applied; it is superseded by the two scripts below that redefine the same procs)
  2. `school_calendar.sql`
  3. `academics_edit_history.sql`
  4. `student_attendance.sql`
  5. `attendance_student.sql`
  6. `attendance_report.sql`
  7. `exam_marks.sql`
  8. `exam_result_student.sql`
  9. `exam_schedule.sql`
  10. `timetable.sql`

  All of them are safe to re-run. **Do not re-run `hotfix_2026_10_10.sql` after step 9**: it would put back the older exam and calendar procs.

### [2026-10-10] Students, transport and documents: test pass and fixes

Catalog: `educore/docs/test-cases/students_transport_documents.md`. Suite: `Database/tests/students_transport_documents_tests.sql` (phase 1: 69 passed / 28 BUG failures; after the fixes: 120 passed, 0 failed).

- **Edit Student** refuses what admission refuses: a future DOB, a DOB after the admission date, a mobile that is not 10 digits, an Aadhaar that is not 12 digits, an unknown gender, a duplicate name + DOB + mobile, and a roll number already used in the class + section + session. The checks live in the proc and the controller. Each rule only fires when that value changes, so older rows stay editable. Every changed field is written to `admission_audit` as `StudentEdited` (old → new, who, when). The Aadhaar number itself is not copied into the audit text. A roll change reaches `student_enrolment`.
- **Admission** applies the same Aadhaar and roll rules (`sp_admission_manage` SaveAdmission).
- **Edit Student page:**
  - Fields that were posted and silently dropped are gone: email, WhatsApp, caste, remarks, and the status block. Status changes belong to the Exit flow, and the page now links to it.
  - The photo uploads as soon as it is picked, and the current photo is shown.
  - A refused save keeps the locked fields filled in.
- **Sections** for Edit Student and Promotion come from the session's class setup (`core.sp_class_setup_sections`, new), so an empty section can be picked. `sp_class_active_sections` is unchanged; attendance still uses it.
- **Directory:**
  - Search collapses inner spaces and treats `%` / `_` as literal characters (strpos, not LIKE). The same applies to GetStudents, the exit list and the TC register.
  - "Sort by class" follows the teaching order.
  - The CSV export honours the Fee filter and neutralises cells that start with `=` `+` `-` `@`.
- **Photos:** a replaced file is deleted, and only when it sits in this school's student folder. Every photo change is audited (`PhotoChanged`).
- **Student Dashboard:**
  - Every database value is escaped (stored XSS).
  - It shows the real address, contact and status instead of a hard-coded address.
  - A left student's dashboard opens read-only (the Inactive list links it). Edit refuses leavers.
- **Promotion:**
  - Unticking a student really leaves them out. Each student has one picked flag; the desktop and mobile checkboxes mirror each other.
  - Desktop and mobile radios no longer share a group.
  - A reloaded roster for the source session no longer lists children already moved on: GetStudents with status Active plus a session needs that session's enrolment to be Active.
- **Transport:**
  - **Fixed:** `GetForStudent` alias clash (the Assign page's "Currently assigned / Remove").
  - **Unique and valid entries:** route and vehicle numbers are unique (case and spacing ignored); fares ≥ 0; capacity ≥ 1.
  - **Delete and remove guards:**
    - A route, or one of its stops, cannot be removed while children ride it. An empty route is soft-deleted and its buses are detached.
    - The last active bus of a route with riders cannot be switched off or deleted.
  - **Assignment:**
    - Refused on an inactive or deleted route or a removed stop. A child already on that route or stop is exempt, so promotion's re-bill keeps working.
    - Refused when the route's active buses are full. Routes with no capacity set are unlimited.
    - Riders and seats are shown on Routes and Assign.
  - **Vehicles:** a bus can only point at this school's routes.
  - **Messages:** a foreign or deleted id gets "not found", never a success message.
  - **Fares:** a stop fare change applies to new riders only, and the UI says so.
  - **Pages:** Assign escapes every name, and Save shows a busy state on Routes and Vehicles.
- **Admission + transport (SEC-20):** no bus is assigned or billed, and no routes are offered, when the Transport module is off.
- **TC:**
  - Issue returns the certificate's public id. "Issue & Print" used to open a 404 because it passed the integer id.
  - Opening or refreshing `Tc/Print` no longer counts a print. The Print button POSTs `Tc/MarkPrinted` (`students.manage`). Until then the sheet carries a "NOT AN ORIGINAL" watermark.
  - A voided TC is refused for printing and shows VOID.
  - Board fields are validated: no negative days, present ≤ working, application date ≤ issue date.
  - The Register shows the void reason, who voided it and when.
  - The number series still restarts on 1 January, by decision.
- **ID cards:**
  - Index lists children with no photo before printing.
  - A sheet with missing photos does not auto-print, and lists them on screen.
  - A missing file falls back to the blank box.
  - The stale "upload not enabled" banner is gone.
  - Sections reload when the year changes.
- **Admission/Dashboard:** this mock page (random grades, `rank:rand(1,40)`) is removed. The URL redirects to the student list.
- **Deploy order (all safe to re-run):**
  1. `transport_module.sql`
  2. `transfer_certificate.sql`
  3. `student_update.sql`
  4. `student_photo.sql`
  5. `student_list.sql`
  6. `student_master_fields.sql`
  7. `student_exit.sql`

  Apply `transport_module.sql` **after** `hotfix_2026_10_10.sql`. Never re-run that hotfix afterwards: it carries an older `sp_transport_assign_manage`.

### [2026-10-10] HR, leave and payroll: every salary leaves a trail, a paid payslip never changes

Suite `tests/hr_leave_payroll_tests.sql` went from 73 passed / 32 failed to **149 / 0**
(catalog: `educore/docs/test-cases/hr_leave_payroll.md`). All other suites stay green.

- **Staff (`sp_staff_manage.sql`):**
  - New `core.staff.last_working_date`. Deactivate takes it (default today; never future, never before joining).
  - Choosing Inactive on the Edit form now behaves like Deactivate (is_active, stamp, login off, out of the teacher pools). Back to Active behaves like Reactivate.
  - The login on/off logic moved into `core.sp_staff_login_switch`, which keeps the self / last-admin guards.
  - Writes check the staff row is in this school first. An out-of-scope edit used to create an orphan login.
  - Refused: an employee code that differs only by case (new index `uq_staff_employee_code_ci`), a negative salary, an unknown status or staff type, a new staff member created Inactive.
  - `p_last_working_date` is added AFTER `p_result`, so positional callers still work.
- **Masters (`staff_masters_manage.sql`):**
  - An edit keeps the sort order and default role the page does not send.
  - A rename follows through to the staff rows (and to designation defaults); a staff type change does too.
  - A deleted row gives up its name, so the name can be added again.
  - A foreign or deleted id gets "not found".
- **Leave (`staff_leave.sql`):**
  - Days are counted on the School Calendar by the new `core.fn_school_working_days`, which payroll uses too.
  - Leave types are a fixed list, with yearly caps in `core.fn_leave_entitlement` (pending days count).
  - New: half days (`days` is numeric), CANCEL (with reason, who, when), BALANCE, and a DAYS preview.
  - Refused: leave for an inactive person, leave before joining or after the last working day.
- **Payroll (`staff_payroll.sql`):**
  - Pro-rata from the joining date to the last working day.
  - LOP is worked from the salary, so an all-LOP month nets 0. "On Leave" staff are paid.
  - A future month is refused.
  - Mark Paid needs a mode and a reference.
  - New `core.staff_payroll_adjustment` (Addition / Deduction / Advance; void only, with a reason, while the month is unpaid).
  - New append-only `core.staff_payroll_history`.
  - A trigger refuses any UPDATE of a paid payslip. RUN reports paid slips whose figures now differ.
- **Purge (`school_purge.sql`):** the purge also deletes the two new payroll tables.
- **App:**
  - Leave, Payroll and StaffMasters pages: cancel, balance, half day, server-side day count, adjustments, mode/reference, money trail, EC.money / EC.esc / EC.listEmpty.
  - Edit Staff saves again: a hidden int `id` had beaten the route uuid in model binding.
  - Last working day appears on the Edit, Profile and Inactive pages.
  - Leave and payroll services log a `PostgresException` at Warning.
  - Dashboard leave days are decimal.
- **Deploy order (all re-runnable):**
  1. `sp_staff_manage.sql`
  2. `staff_list.sql`
  3. `staff_masters_manage.sql`
  4. `staff_leave.sql`
  5. `staff_payroll.sql`
  6. `school_purge.sql`

  Regenerate `deploy_2026_10_10b_parts/part2.sql` first, or leave it out: it still holds the old `sp_staff_manage`.

### [2026-10-10] Login limit counts only failed sign-ins

The "login" rate limiter (5 requests / 5 min per IP) counted correct logins too, and a
school office shares one IP, so the 6th teacher signing in at 9am was blocked. Login now
uses `Helpers/LoginThrottle.cs`: only unknown-account / wrong-password / inactive-account
attempts count, 10 per 5 minutes per IP, then that IP waits out the window. The forgot-
password and OTP pages keep a request limiter of their own ("otp", 5 / 5 min per IP), no
longer shared with login. In-memory, per app instance (like AppCache).

### [2026-10-10] Exam results: grade scale, a results publish step, grades and class rank

BD-02 and BD-03 were "future feature"; they are built now (catalog section I of
`educore/docs/test-cases/academics_attendance_exams.md`, new suite
`tests/exam_results_publish_tests.sql`: **81 / 0**). All other suites stay green.

- **Two statuses per exam.** `academic.exams.status` stays the DATESHEET. New
  `results_status` (Unpublished | Published) + `results_published_by/_at`, and an
  append-only `academic.exam_result_log` (Publish / Unpublish, reason, who, when).
  - Publish needs `exams.manage`, a published datesheet, and every expected mark sheet
    finalised (`fn_exam_pending_sheets`: each paper x each section with students, the
    same rule as Marks Entry's section list). The refusal names the first pending sheet.
  - Once published, `SaveMarks`, `ReopenSheet`, `SaveExam` (edit) and `SetStatus Draft`
    refuse. Unpublish needs a reason; it is logged. Mark edit history is untouched.
  - `core.sp_exam_result_student` (the Student Dashboard) shows an exam only when its
    results are published. Before this, draft marks were visible (EXM-51).
- **Grade scale per school** (`academic.grade_scale`, `sp_school_admin_grade_scale_manage`).
  No rows = the CBSE 8-point default (`fn_default_grade_scale`, not seeded per school).
  Save is replace-all and checks: labels unique (any case), 0-100 covered, no overlap,
  no gap wider than 1. A band runs from its min % to the next band's min %. Grades are
  never stored: `fn_grade_for_percent` works them out on every read.
- **Rank**: `fn_exam_class_result` (one exam, one class): totals, 2-dp %, grade, class rank
  and section rank with `RANK()` (ties 1, 1, 3). Today's rules kept: absent papers out of
  the total, marks of a paper no longer on the datesheet ignored, absent-from-everything
  = no %/grade/rank.
- **App**: new `IExamResultService` / `ExamResultService` (grade scale cached with
  `AppCache.Key("gradescale", t, s)`, removed on save/reset; `PostgresException` logged at
  Warning). Exam controller: Grade Scale page, Result Sheet page (exam/class/section,
  publish/unpublish panel with pending sheets and log, sort by roll/rank, print, CSV with a
  formula-injection guard). Marks Entry locks the grid when results are published.
  Student Dashboard shows grade per subject, overall grade and class rank.
- **Tests changed**: `academics_attendance_exams_tests.sql` (F section) and
  `attendance_exam_tests.sql` (E section) flag the results published directly before
  checking the arithmetic, since results now need that step.
- **Purge** (`school_purge.sql`) also deletes `grade_scale` and `exam_result_log` (H12).
- **Deploy order (all re-runnable):**
  1. `exam_results_publish.sql` (new: tables, columns, functions, two procs)
  2. `exam_marks.sql`
  3. `exam_result_student.sql`
  4. `exam_schedule.sql`
  5. `school_purge.sql`

  `deploy_2026_10_10b.sql` includes 2-4 but not 1; run step 1 before re-running it.

### [2026-10-10] Inventory: store locations, transfers, returns to supplier, supplier screen

Owner-approved design for D-10 (`educore/docs/test-cases/inventory_store.md`). New suite
`tests/inventory_locations_tests.sql` (111 / 0); `inventory_tests.sql` 49 / 0 and
`inventory_store_tests.sql` 142 / 0 unchanged.

- **Locations.** `core.inventory_locations` (one default per school, "Main Store",
  renamable, never deactivated) and `core.inventory_location_stock` (item x location,
  `CHECK quantity >= 0`). `current_stock` stays as the school-wide total, so the rule is now
  `current_stock = SUM(location stock) = SUM(ledger)` and, per location, stock = SUM(ledger rows
  at it). Every ledger row names its `location_id` (NOT NULL) and `location_balance_after`;
  `balance_after` stays the item total so the old running-sum checks still hold. One helper,
  `core.fn_inventory_post_movement`, writes location stock + item total + ledger row together;
  every writer locks the item row first. A location that holds stock cannot be deactivated.
- **Migration** (in `inventory.sql`, re-runnable): every school with inventory gets "Main
  Store"; every ledger row and bill without a location goes into it; location stock is built
  from the ledger. Only rows with no location are touched, so a re-run changes nothing (MIG-07).
- **Transfers.** `core.inventory_transfers` + a paired `TransferOut` / `TransferIn` ledger row
  (reference_type `Transfer`). Refused: more than the source holds, same location, inactive item
  or location, other school's location, >2 decimals, blank reason.
- **Return to supplier.** `core.inventory_purchase_returns`, one row per line returned (rate,
  tax, amount rounded like a bill line, reason, who/when) and a `SupplierReturn` ledger row linked
  to the bill and the bill line (`purchase_item_id`, also now set on `Purchase` rows). Limits: per
  line bought - already returned; per item what the bill's location holds now. Named
  `SupplierReturn` because `Return` already means "came back into the store".
- **Cancelling a bill with returns reverses only the remainder** (bought - returned per line).
  Chosen over refusing: it never takes the returned goods out twice, and the bill still nets to
  zero per line. No returns after a cancel. A fully returned bill can be cancelled (no movement).
- **Suppliers.** `SetSupplierActive`; inactive suppliers keep their bills but are refused on a new
  bill (and left out of the purchase picker). List search (name/contact/mobile/GSTIN), status
  filter, bill count / total / last bill (live bills). Email and 15-character GSTIN checked.
- **Bug fixed: purchase calls failed in the app.** `sp_inventory_purchase_manage` opened only
  `p_result` on List/Save/Cancel, and PgExec FETCHes every refcursor parameter, so the second
  FETCH failed with "cursor does not exist". Every branch now opens both cursors (CUR-01). A
  third INOUT cursor would break every existing PL/pgSQL CALL, so a bill's returns are their own
  `Returns` operation.
- **App.** `InventoryService` / `IInventoryService` / models / `InventoryController`: locations,
  item stock by location, transfers, supplier active, return to supplier, purchase detail (lines
  with returned qty, returns, cancel status, who/when). New pages `StoreLocations` and
  `SupplierMaster` (menu entries added). `InventoryItem`: location filter, location on
  movements and opening stock, transfer dialog, per-location stock and location column in the
  history. `PurchaseEntry`: "goods go to" location, View on each bill (detail + return to
  supplier + cancel). Friendly messages for `ux_inventory_location_name` / `chk_inv_loc_stock`.
- **Purge.** `school_purge.sql` deletes the four new tables.
- **Deploy order (re-runnable):** `inventory.sql`, then `school_purge.sql`.

### [2026-10-10] Payroll permission, defaulters by session, remove logo, landline phone

- **Payroll has its own keys.** `payroll.view` / `payroll.manage` (People group, one
  "Payroll & Salary" row on the Roles page). `payroll_permissions.sql` grants BOTH only to roles
  that hold `staff.manage` today, so nobody who ran payroll loses it and a `staff.view`-only role
  no longer sees salaries. Re-runnable; a payroll grant a school has removed (soft-deleted row) is
  not revived by a re-run. `PayrollController`: class `payroll.view`, every write
  (RunPayroll, MarkPaid, AddAdjustment, VoidAdjustment) `payroll.manage`. Sidebar shows Payroll on
  `payroll.view` (the Staff group now opens for either key; directory/leave stay on
  `staff.view`). **Salary gated on `payroll.view`:** Staff Profile's Monthly Salary field and its
  "Payroll / Payslips" link. Not gated: Add/Edit Staff salary inputs (they need `staff.manage`,
  and hiding a posted field would blank the salary on save) and the dashboard Quick Access tile
  (a link only; the page itself is gated).
- **Defaulters report: Session filter** (default current session, "All sessions" option).
  `sp_fee_defaulters_get` grew `p_academic_year` as its LAST parameter (after the cursor) so the
  old positional calls still bind; old signature dropped. A ledger row's session is the first of:
  `student_ledger.academic_year` (stamped by `fn_student_bill_plan` since today) -> the school
  session whose dates contain the due date -> the student's own session -> the current session.
  Rows billed before the column existed (all 481 local rows have it blank) are placed by the
  fallbacks, and anything unplaceable counts in the current session (the report's default), so
  no old due drops out. Registration rows follow `core.enquiries.session`, else current. Today's
  rules unchanged (fallen-due only, exited students listed while they owe).
- **Remove school logo.** `sp_school_admin_basic_profile_manage` new operation `RemoveLogo`
  (clears `logo_url`, returns the old URL; the save's COALESCE keeps a logo when none is posted,
  so it needed its own operation). `SchoolSettings/RemoveLogo` (POST, `settings.manage`,
  antiforgery) deletes the file only when the URL is inside this school's upload folder, reduced
  to a bare file name (same rule as the student photo replace). Button on Basic Profile behind
  `EC.confirm`, shown only with `settings.manage` and a logo.
- **Official / alternate phone may be a landline.** Rule (same in `core.fn_school_phone_clean`,
  `PhoneRules` C#, `EC.rule.phone` site.js): after removing spaces/hyphens, a 10-digit mobile
  `[6-9]` or a number starting with 0 of 10-12 digits (0141-2345678, 011 23456789). **Stored as
  digits only** (0141-2345678 -> 01412345678). The proc normalises and refuses junk; the
  controller drops the model's mobile-only regex verdict for these two fields (the SuperAdmin
  wizard still uses that model and stays mobile-only).
- **Tests:** `tests/small_features_tests.sql` (runs `payroll_permissions.sql` twice inside the
  transaction).
- **Deploy order (re-runnable):** `payroll_permissions.sql`, `fee_reports.sql`,
  `sp_school_admin_basic_profile_manage.sql`. App restart needed (permission catalog is cached).

### [2026-10-10] Bell schedule per weekday; timetable follows the day; calendar date ranges

- **Per-weekday bell schedules.** `academic.period_structure` gained `day_of_week smallint NULL`
  (CHECK 0..6, index `(tenant, school, day_of_week, seq)`). NULL = the **default** schedule, used
  on every day that has no rows of its own; 0..6 = that weekday's **custom** schedule (e.g. a
  short Saturday). **Migration:** none needed beyond the column: every existing row is NULL, so
  each school's schedule simply becomes its default; re-running the script changes nothing.
- **`academic.fn_day_periods(tenant, school, day)`** returns the schedule a weekday runs on (its
  own rows, else the default). Everything that resolves a timetable slot now goes through it.
- **`sp_school_admin_period_structure_manage`** grew `p_day_of_week` as its LAST parameter (after
  the cursor) so every old positional call still binds; the 6-argument signature is dropped.
  Operations: `GetPeriodStructure` (no day = default; a day = that day's effective schedule, rows
  carry `day_of_week`), `GetAllSchedules` (page seed), `SavePeriodStructure` (replace-all of ONE
  schedule; a weekly-off day is refused), `UseDefault` (drop a day's own rows). All of today's
  rules stay, per schedule. The booked-period protection is now per day: the save snapshots the
  old effective schedule of every affected day (one custom day, or every day without its own when
  the default is saved), writes, then refuses (RAISE = whole save undone) if a lesson's period
  label is no longer a teaching period of that day, and otherwise moves each lesson to its label's
  new seq on that day. So Saturday lessons follow the Saturday schedule, and switching a day to
  or from the default moves its lessons by label too.
- **Timetable (`timetable.sql`).** GetSetup cursor 1 now lists each working day's periods
  (`day_of_week` column); SaveCell checks the slot is a teaching period of THAT day ("not a
  teaching period on Saturday"); Copy Day maps each lesson to the same label on the target day
  and skips + names labels the target day lacks ("Sat P5, Sat P7"; `skipped` includes them, new
  `no_period` column). All earlier checks (subject/teacher/day/room, teaching staff only, weekly
  offs from the calendar) are unchanged. Page: rows = every label any day has; a day without the
  period shows "—"; stats count each day's own teaching periods.
- **Smart Bell** rings `GetPeriodStructure(today's weekday)`; half-day calendar entries still cut
  it short. Attendance is daily and unaffected.
- **Period Structure page:** day selector (Default + every weekday that is not a weekly off, with a
  Custom badge), "Use default" (confirm, immediate) / "Custom schedule" (starts as a copy of the
  default), "Copy from default", Save posts `day`. New action `UseDefaultPeriodSchedule`
  (`academics.manage`, antiforgery); `SavePeriodStructure` takes `day`. Service:
  `GetAllPeriodSchedulesAsync`, `UseDefaultScheduleAsync`, optional `dayOfWeek` on Get/Save;
  write failures now logged at Warning with SqlState (they were not logged before).
- **School Calendar date ranges (`school_calendar.sql`).** `SaveRange` (p_date..p_to_date, one
  entry per day; a date that already has an entry is skipped and reported; holiday / half-day
  ranges skip weekly offs, a working-day range does not; max one year; returns created /
  skipped counts and a message) and `DeleteRange` (every entry in the range; "no calendar
  entries" when empty). SaveEntry and SaveRange share one code path. A half day's closing time is
  now checked against **that date's own** schedule (a short Saturday has its own hours).
  `fn_school_day_type` is unchanged, so attendance, exam papers and leave/payroll day counts work
  across a range (tested). Actions `SaveCalendarRange` / `DeleteCalendarRange`
  (`academics.manage`, antiforgery); "Date range" dialog on the page.
- **Note:** `hotfix_2026_10_10.sql` still holds an older copy of the calendar proc; do not re-run
  it after `school_calendar.sql`.
- **Tests:** `tests/weekday_schedules_tests.sql` (97 checks). Every suite in `Database/tests`
  re-run green; no existing check needed changing.
- **Deploy order (re-runnable, each ends with a semicolon):** `period_structure.sql`,
  `timetable.sql`, `school_calendar.sql`. App restart needed (new binaries).

### [2026-10-11] Transport: live bus tracking (driver's phone, staff map, parent link, 30-day history)

- **Location source = the driver's phone browser.** A driver is a staff row with a login
  (`staff.user_id`) set as `transport_vehicles.driver_staff_id`. New page **`/ERP/MyBus`**
  (`MyBusController`, `[Authorize(SchoolUserOnly)]`, no permission key — being the assigned driver
  of an active bus is the permission, checked again by the proc on every write; the Transport
  switch is checked in the controller because `[RequiresModule]` would redirect a driver to a
  settings page they cannot open). Start/End Trip; `navigator.geolocation.watchPosition`; posts
  at most every 15 s (antiforgery); re-sends the last fix while standing still (at most 5 min old)
  so a bus waiting at a stop is not taken as abandoned; asks for a screen wake lock; warns to keep
  the page open. "My Bus" menu item only for drivers (`IsDriverAsync`, AppCache 5 min per user).
- **Tables** (`transport_live_tracking.sql`): `core.transport_trips` (snapshots of bus / route /
  driver; the latest point is copied onto the trip row so the live map reads one row per bus — no
  "latest point per trip" scan), `core.transport_trip_points`, `core.transport_route_shares`
  (sha256 hex of the token only). Indexes: unique running trip per vehicle (partial), running
  trips per school (partial), history `(tenant, school, started_at desc)`,
  `points(trip_id, recorded_at)`, and `points(recorded_at)` / `trips(started_at)` for the purge.
- **Procs:** `fn_transport_close_stale_trips` (no point *received* for 30 min → ended `Stale`;
  server receive time, so a wrong phone clock cannot keep a trip alive), `sp_transport_trip_manage`
  (MyBus / IsDriver / StartTrip / EndTrip / AddPoint: lat/lng in range and not 0,0; accuracy
  0..2000 m; not > 2 min in the future nor before the trip; < 5 s after the last point = dropped,
  not an error; junk speed/heading stored NULL), `sp_transport_tracking_manage` (LiveList /
  TripHistory / TripPoints / ShareList / ShareCreate / ShareRevoke), `sp_transport_track_public`
  (token hash → its own school and route; nothing when revoked, unknown, route deleted or the
  module is off; returns only route name, vehicle no., position and age).
- **30-day retention without a scheduler:** `StartTrip` runs `DELETE ... points WHERE recorded_at <
  now() - 30 days` and deletes ended trips started more than 30 days ago, for every school.
  Indexed, so it is cheap at the start of each trip.
- **Staff:** `/ERP/Transport/LiveTracking` (Leaflet 1.9.4 from cdnjs + OpenStreetMap tiles with
  attribution; polling every 10 s, no SignalR; grey after 3 min) and `/ERP/Transport/TripHistory`
  (vehicle/date filter, polyline with start/end markers, replay), both under the existing
  `transport.view` + `[RequiresModule(Transport)]`.
- **Parent link:** per route on the Routes page (`transport.manage`): create / new link /
  turn off. 32 random bytes, base64url, shown once (copy link, WhatsApp, SMS text); only the hash
  is stored, so to re-share the office makes a new link and the old one stops at once.
  Public `/BusTrack/{token}` and `/BusTrack/{token}/data` (`BusTrackController`, AllowAnonymous,
  attribute routes): malformed tokens never reach the DB, unknown and revoked look identical,
  `Cache-Control: no-store`, `noindex`; new rate-limit policy **`bustrack`** (60/min per IP —
  room for families behind one carrier IP; the page polls 4 times a minute).
- **Purge:** `school_purge.sql` deletes the three tables (before vehicles / routes / staff); H12
  stays green.
- **Roadmap:** "Live bus tracking" moved from Planned to a new "Now available" block.
- **Tests:** `tests/transport_live_tracking_tests.sql` (75 checks). Every suite in
  `Database/tests` re-run green (34 suites). Smoke-tested against a local run: start, points,
  future/NaN refusal, CSRF 400, live list, public JSON (no driver name), end, history, path,
  create/regenerate/revoke, 429.
- **Deploy order (re-runnable, each ends with a semicolon):** `transport_live_tracking.sql`, then
  `school_purge.sql`. App restart needed (new binaries).

### [2026-10-11] Dashboard and menu follow the role; built-in roles get default permissions

- **Dashboard** (`DashboardsController`, `Views/Dashboards/Index.cshtml`): every block now needs
  its module permission and is removed on the server when the role lacks it (students,
  staff, attendance, admission, finance as before). Quick Access lists only modules the role
  can open, with the module switches; drivers get a My Bus shortcut. Also fixed: Upcoming
  Events was four hard-coded events (now the school calendar), the session chip was a
  hard-coded 2025-26, and the Reports tile linked to a missing page.
- **Menu**: New Admission and Promote Students need `students.manage` (a view-only role saw
  forms it could not save); the Admissions group no longer shows empty.
- **`builtin_role_defaults.sql`**: TEACHER / ACCOUNTANT / RECEPTIONIST had no permissions in any
  school, so they saw only the Dashboard. `config.fn_apply_builtin_role_defaults` grants a
  sensible set per school where the role has no grant at all (a school's own setup is never
  overwritten); applied to every existing school and called by `sp_school_manage` for new
  schools. Bundle: `deploy_2026_10_11f.sql`.
- Tested in the browser with one login per role (admin, teacher, accountant, receptionist,
  driver, transport in-charge, cashier, front office, HR manager).

### [2026-10-11] Exam marks and day re-open get their own permissions; role templates

- **`exams.marks`** ("Examinations — Enter marks"): `ExamController.SaveMarks` (save + finalise)
  now needs `exams.marks` **or** `exams.manage` (a small `CanEnterMarksAsync` check in the
  action, since the attribute takes one key). Creating/editing/deleting exams, the grade scale
  and publish/unpublish stay `exams.manage`. Marks Entry locks the grid without either key;
  Exam Schedule hides Save/Clear and the row edit/publish/delete buttons without
  `exams.manage` (Grade Scale and Result Sheet already did).
- **`fees.reopen`** ("Fees & Collection — Re-open a closed day"): `FeeController.ReopenDay`
  needs it instead of `fees.manage`; the Day Close page hides Re-open without it. Not copied
  to any role on purpose — school admins bypass as always, anyone else is ticked deliberately.
- **`permissions_exams_reopen.sql`** (re-runnable): adds both keys; copies every live
  `exams.manage` grant to `exams.marks` (nobody loses mark entry); removes the default
  `exams.manage` from built-in TEACHER roles (rows with `created_by = 0` never edited since —
  a school that re-ticks it keeps it on a re-run). `builtin_role_defaults.sql`: TEACHER now
  gets `exams.marks` instead of `exams.manage`.
- **Role templates** (Roles → New Role → "Start from template"): Principal, Transport
  In-charge, Driver, Store Keeper, HR / Office, Cashier, Teacher-like, Accountant-like,
  Receptionist-like. Defined once in `educore/Helpers/RoleTemplates.cs`; after the role is
  created the server ticks the template's keys that exist in the catalog through
  `config.sp_role_permissions_save` (so the audit row is written as for a manual save) and
  invalidates the role's cache. The school can change the ticks afterwards.
  `IRbacService.GetCatalogAsync` was extracted from `GetMatrixAsync` for this.
- **Tests:** `tests/permissions_split_templates_tests.sql` (23 checks). Every suite in
  `Database/tests` re-run green (35 suites); no existing check asserted the old teacher set.
- **Deploy order (re-runnable, each ends with a semicolon):** `permissions_exams_reopen.sql`,
  then `builtin_role_defaults.sql`. App restart needed (new binaries; it also clears the
  cached role permissions).

### [2026-10-11] Staff self-service: My Leave and My Payslip

- **What:** every signed-in user with a staff record in the school (`core.staff.user_id` = the
  user, same tenant/school, not deleted) gets **My Leave** (`/ERP/MyLeave`: balance per type for
  the year, own requests with who/when/why, apply for themselves, cancel own request) and **My
  Payslip** (`/ERP/MyPayslip`: own generated payslips marked Draft / Paid; `/ERP/MyPayslip/Slip/{id}`
  is a stand-alone printable slip). No permission key, same pattern as My Bus: the staff record
  is the permission and the procedure re-checks it on every call.
- **`staff_self_service.sql`** (new, re-runnable): `core.fn_my_staff_id(tenant, school, user)`,
  `core.sp_staff_my_leave` (ME / LIST / BALANCE / DAYS / APPLY / CANCEL) and
  `core.sp_staff_my_payslip` (LIST / GET). Neither proc takes a staff id: it is resolved from the
  user id, and someone else's leave or payslip id reads as "not found". BALANCE / DAYS / APPLY /
  CANCEL `CALL core.sp_staff_leave_manage` with the resolved id, so caps, School Calendar day
  count, half days, overlap, joining / last working day, inactive staff and the cancel rule are
  the HR ones, unchanged (the HR procs were not widened). A self-applied request is an ordinary
  Pending row (`applied_by` = the staff member) and shows on Leave Management and the dashboard
  Pending Approvals. Payslips never return `payment_reference` or `paid_by` (mode + date only).
- **App:** `IStaffSelfService` / `StaffSelfService` (PgExec; Warning log with SqlState on a
  `PostgresException`), models in `Models/ERP/StaffSelfModel.cs`, `MyLeaveController`,
  `MyPayslipController`, views `Areas/ERP/Views/MyLeave/Index`, `MyPayslip/{Index,Slip}`. Menu
  entries under My Bus and two Quick Access tiles, shown only with a current (not Inactive) staff
  record and the Payroll module on (`HasStaffRecordAsync`, cached 5 min like `IsDriverAsync`).
  Leave follows the Payroll module switch, as Leave Management already did.
- **Tests:** `tests/staff_self_service_tests.sql` (58 checks); cases appended to
  `educore/docs/test-cases/hr_leave_payroll.md` (section G). Every suite in `Database/tests`
  re-run green (36 suites).
- **Deploy:** `staff_self_service.sql` (after `staff_leave.sql` / `staff_payroll.sql`); app restart
  (new binaries).

### [2026-10-11] Institution categories (school / computer institute / coaching) + Super Admin fixes

- **Why:** after the data wipe the "existing tenant" list offered only tenant 1 (the platform), and a
  school created there failed on `chk_school_profiles_scope`. Separately, the board and school-type
  lists only knew schools, so a computer institute went live as "ICSE, Special Education School",
  and the type / ownership lists held the same entries twice.
- **`deploy_2026_10_11h.sql`:** the tenant dropdown skips tenant 1 and deleted tenants;
  `sp_school_manage` refuses tenant 1 with a readable message.
- **`institution_categories.sql`** (new, re-runnable; now owns `config.sp_school_dropdowns`):
  `config.institution_categories` (SCHOOL / COMPUTER_IT / COACHING, with the labels and whether a
  board is required), `core.school_profiles.institution_category_id` (default 1),
  `category_codes text[]` on boards / school_types / ownership_types (NULL = every category).
  Retires duplicate types (profiles moved to the surviving row first), adds institute boards
  (NIELIT, NSDC, MKCL, Tally, open-university study centre, Franchise, Not affiliated), types and
  legal forms. The dropdown proc gains a 12th cursor *with a default*, and `sp_school_manage`
  gains `p_institution_category_id` *after* `p_result` -- both so the running app keeps working
  between the DB deploy and the app deploy.
- **`sp_school_manage`:** board / type / ownership must fit the category; only a school must name a
  board; plus the 12 fixes from `tests/superadmin_schools_tests.sql` (roles seeded on every save so
  an admin added later from Edit can sign in, tenant-code slug and uniqueness, pincode / phone /
  status / board-state checks, "School not found.", DELETE branch removed). `sp_school_list`:
  category name, tenant code, literal search, active = `allows_login`. Basic Profile GET returns the
  category and its labels.
- **App:** wizard step 1 has Institution Category; board / type / ownership options are filtered
  client-side from `data-categories`; Ownership and Medium are now visible (optional). Super admin
  (tenant 1) menu shows Platform -> Schools / Add School instead of the school modules, and the
  dashboard redirects to the school list. `SchoolsController` logs DB errors and shows the proc's
  message (not `ex.Message`).
- **Tests:** `tests/institution_categories_tests.sql` (36), `tests/superadmin_schools_tests.sql`
  (92), catalog `educore/docs/test-cases/superadmin_schools.md`.
- **Deploy:** `deploy_2026_10_11h.sql`, then `institution_categories.sql`, `sp_school_manage.sql`,
  `sp_school_list.sql`, `sp_school_admin_basic_profile_manage.sql`; then push (app restart).


### [2026-10-12] QA report: the seven High bugs (SmartSchoolWala_Test_Report.xlsx)
- **BUG-012 Schools "Created date" filter 500:** `SchoolService.GetSchoolsAsync` sent `p_from_date` /
  `p_to_date` as `NpgsqlDbType.Unknown` with a `DateTime` value, which Npgsql refuses to write.
  Now `NpgsqlDbType.Date`.
- **BUG-031 creating a fee head with an existing name overwrote it:** the proc's create path is a
  name upsert by design (settings tests C4/D8). `SchoolSettingsController.SaveFeeHead` now refuses
  a new head (id 0) whose name already exists, active or not. The Admission Workflow cards already
  send the existing id, so they are unaffected; the proc is unchanged.
- **BUG-038 staff form accepted garbage:** `StaffController.ValidateDetails` (Add + Edit): DOB age
  14-100, joining date not > 1 year ahead and at least 14 years after DOB, experience 0-60,
  salary >= 0, PAN / IFSC / Aadhaar format (upper-cased / spaces stripped first).
- **BUG-046 unpaid registration fee lost at admission:** the agreed fee is only frozen on the
  enquiry by the first receipt, so an unpaid registration carried 0 - 0 = 0. `sp_admission_manage`
  now falls back to the resolved Registration-point fee (class-wise structure, else head defaults)
  for a *registered* enquiry while the school has the registration fee on, freezes it on the
  enquiry, and the existing carry puts the balance on `student_ledger`.
- **BUG-067 admin could not re-open a cashier's day:** `FeeController.ReopenDay` always passed the
  caller as the cashier. It now takes an optional `CashierId`; new `GetClosedCounters` +
  `core.sp_fee_day_close_list` and an "All counters on this date" card (fees.reopen only) on Day Close.
- **BUG-004 login stuck on "Signing in…":** if the page is still there 20 s after submit, the button
  and the double-submit flag reset with a toast. (Root cause not reproduced -- the tester's Chrome
  window was hidden; same for BUG-009, left for a retest in a visible browser.)
- **Deploy:** `deploy_2026_10_12.sql`, then push (app restart).

### [2026-10-12] QA report: Medium bugs (platform, fees, staff/settings)
- **Platform:** sidebar search matches `textContent` + "No menu items match." (006); demo notification
  bell replaced by an empty state (010); Super Admin admin password needs a letter and a digit, rule in
  `SchoolManageModel.PasswordPattern` (016); `frame-ancestors 'self'` CSP, Permissions-Policy
  (geolocation self for driver tracking), X-Frame-Options SAMEORIGIN, antiforgery cookie follows
  `Security:RequireHttps` (019). 013 was already fixed; 022 needs `Email__*` env vars on Railway.
- **Fees:** max fee amount 1 crore with friendly messages, only RAISE text reaches the user (030);
  blank structure amount = head default (033); registration discount/over-collection refused before
  anything is written (043); honest concession label on the student dashboard (047); discount above
  payable refused (057); "authorised by X (entered by user)" on receipt, history and concession
  register -- `fee_concession_cancel_report.sql` (063); `DbRead.DateTimeN` converts UTC timestamptz to
  the school clock via `Dates.ToSchool` (064); fee heads / structures / setup fees need
  `settings.manage` instead of `fees.manage` (065).
- **Staff/settings:** subjects confirm before discarding unsaved changes (025); Transport department
  no longer matches "sport" -> Teaching (029); Aadhaar masked unless staff.manage (040); duplicate
  active staff mobile/email refused in `sp_staff_manage.sql` (041); admission without
  `students.manage` hidden/redirected with a clear message (066); 10-digit mobile on driver phone and
  supplier mobile (068).
- **Deploy:** `fee_concession_cancel_report.sql` (concession register proc), `sp_staff_manage.sql`.

### [2026-10-12] QA report: last Medium bugs + Low bugs
- **Medium (attendance/exams):** a Present tap counts as reviewed and an untouched roster saves after a
  confirm (052); out-of-range marks stay as typed, are highlighted and block Save (055); teachers
  with `exams.marks` but not `exams.manage` only get sheets for sections they are class teacher of
  or subjects they teach in the timetable -- new `GetMarkScope` op in `exam_marks.sql` (060).
- **Low, public/Super Admin:** dead Terms/Privacy and Support links removed; login fields required
  without leaving the button busy; no Dashboard menu item for tenant 1; roadmap hides school-only
  modules from Super Admin; role badge not repeated; contact/admin name min length; PIN first digit
  must fit the state (`SchoolManageModel.PinZonesByState`, unknown states never blocked);
  beforeunload on the Add School wizard; error page title. 021 not in our code.
- **Low, settings:** unique class order except stream classes; plurals; PCM/PCB subject suggestions;
  Staff Masters keeps its tab; Fee Head edit scrolls to the form; Fee Structure list in class order;
  "No periods yet"; working-day override refused on a normal weekday (`school_calendar.sql`);
  School Admin role shows "All permissions"; staff form errors all come back in one round (client
  validation partial removed).
- **Low, students/fees/inventory:** same-mobile enquiry warning (`enquiry_crm_manage.sql`); "Fees for
  rest of session" label; receipt date formatted; student age / subjects / "Collected by";
  low-attendance warning only after marked days; Collect Fees header = the cashier's Day Close
  figure; Fee Status hidden without `fees.view`; selling-below-cost warning. 058 not reproduced.
- **Low, attendance/exams:** "Future date" label; holiday / weekly-off notice and disabled Save;
  a visible reason when a teacher cannot mark; exam end-date message; default max/pass marks
  update untouched grid cells; write buttons hidden without `academics.manage` / `students.manage`.
  062 not reproduced locally (Railway may lack `fn_school_working_days`).

### [2026-10-13] Student Dashboard works end to end; Edit Student covers the whole admission form
- **Tabs did nothing:** no click handler existed and `activateTab` was called but never defined
  (the console error QA saw). Tabs now switch, and the open tab is kept in the URL hash
  (`#fee`, `#profile`) so it can be linked to and survives a reload.
- **Header actions:** Edit (students.manage) and Collect Fee (fees.collect) — Collect Fee opens
  `Fee/ManageFee?adm=...&session=...`, which now picks that student straight away.
- **Fees only for fees.view:** `DashboardData` returns `fee`/`receipts` as null otherwise and the
  page hides the Fee tab and the Fee Due card (a Teacher opens this page too).
- **Fee tab:** "Fee Structure" was really only the rows still owing -> now "Pending Dues" per
  instalment (head, instalment, due date). The print button called `window.print()` on the
  whole page; it now opens the real receipt (shared `_FeeReceiptModal` + `fee-receipt.js`).
- **Profile tab:** mother tongue, APAAR, UDISE, parents' occupation / qualification / email,
  income, previous board / class / TC were always "—" (never read back). The dead Documents,
  Caste and TC Date rows are gone.
- **Edit Student:** those fields are now editable (plain inputs, `value="@Model.X"`).
  `core.sp_student_update` takes them AFTER `p_result` and writes them only when
  `p_extended = TRUE`, so the old app build (during a deploy) keeps the stored values instead of
  blanking them. APAAR 12 digits, email format and income >= 0 are checked when changed; the
  audit row says which group changed. The documents checklist stays admission-only (it is JSON).
- **Deploy:** `deploy_2026_10_13.sql`, then push.

### [2026-10-13] Collect Fees: find a student by name, father's name or mobile
- A parent at the counter often does not know the class / section. The "Admission Number" box on
  `Fee/ManageFee` is now **Find Student**: new `FeeController.SearchStudents` reuses the student
  list search (`GetStudentsAsync(search:)`, which already matches student name, admission no,
  guardian name and mobile). One match or an exact admission no opens the student through the
  existing `doAdmSearch()`; several matches are listed (name, class, father, mobile, adm no) to
  pick from. No DB change.

### [2026-10-13] Phone-width pass (390px) + QA Test School data
- **How tested:** every menu page loaded in a 390px frame and measured for overflow, then the
  states that only appear after an action (search results, a picked student's dues, discount
  modal, payment history, every Student Dashboard tab, attendance roster, timetable editor, marks
  sheet, loaded reports, Enquiry modal).
- **Fixed:** Day Close header ran off the screen and cut its Print button (shared rule: rows inside
  `.ec-page-header-inner` wrap on phones); Vehicles and Staff Masters tables were cut instead of
  scrolling (wrapped in `.table-responsive`); Fee Due Reminders filters wrap; Enquiry pipeline header
  wraps; Find Student results show class / father / mobile under the name on phones; timetable
  break labels left-aligned (centred they sat off-screen); attendance roster no longer breaks
  surnames mid-word on narrow phones. Server-rendered rupee amounts use Indian grouping via
  `Money.Inr` (5,67,200, not 567,200).
- **QA Test School (tenant 32) data, live:** 23 teachers, a class teacher for all 15 sections,
  a full clash-free timetable (720 periods), 3 students per section admitted through
  `sp_admission_manage` with the class fee plan. Generated by a one-off script calling the app's
  own procs (`sp_staff_manage`, `sp_class_teacher_manage`, timetable `SaveCell`).

### [2026-10-13] Admit cards; exam results checked end to end
- **Admit Cards** (Examinations › Admit Cards, `exams.view`): pick a published exam, a class and
  optionally a section; one card per student with the exam's datesheet for their section. Three
  templates: Classic (2 per A4), Compact (4 per A4), Full page (with instructions). Built live like
  the ID cards: `AdmitCardController` reads `IExamService.GetDatesheetAsync` and
  `IIdCardService.GetClassCardsAsync`; `AdmitCardPrintModel.PapersFor` keeps only the papers a
  student's section sits. No new SQL.
- **Results test (QA Test School, Unit Test 1):** marks for 9 students / 23 sheets entered and
  finalised through `SaveMarks`, then compared with hand-worked figures: totals, %, absences left
  out of the total, pass mark inclusive (17/50 passes), grade-scale gaps round down (90.5% -> A2,
  32.5% -> E), tied students share a rank and the next rank skips. All matched; results published.
  Noted: the Result Sheet shows % to 2 decimals and the student page to 1; a student with no roll
  number shows the admission no in the Roll column (by design in the proc).

### [2026-10-13] Exam percentages: 2 decimals everywhere
- The Result Sheet showed 82.86% and the Student Dashboard 82.9% for the same student:
  `core.sp_exam_result_student` rounded the subject and overall % to 1 decimal. Both are now
  `ROUND(..., 2)` (`exam_result_student.sql`, deployed with `deploy_2026_10_13b.sql`), and the
  dashboard prints exam percentages with `examPct()` (`toFixed(2)`), like the Result Sheet.

### [2026-10-13] Teachers request timetable periods, admins approve
- **My Timetable** (staff menu, no permission key: a staff record is the permission, like My Leave):
  a teacher's own week; a free period shows "+ Request", an own period "Change". A request is
  Pending and not live; "My requests" shows the status and the admin's reason on a rejection.
- **Timetable page** (academics.manage): a "Teacher requests" card with what is live in that slot
  now, Approve and Reject (reason required). The admin can still edit the grid directly.
- **Storage:** new `academic.timetable_requests` + `academic.sp_timetable_request_manage`
  (`timetable_requests.sql`, deployed with `deploy_2026_10_13c.sql`). `academic.timetable` is still
  the live timetable and nothing that reads it changed. Approve calls the existing `SaveCell`, so
  every timetable rule applies; approving one request rejects other pending requests for the same
  section + period. The teacher always comes from the logged-in user, never from the browser.
- **Tests:** `tests/timetable_requests_tests.sql`, 11 checks on QA Test School data, rolled back.
- Menu: the admin Timetable item now matches `SchoolSettings/Timetable` so it does not light up on
  My Timetable.

### [2026-10-13] Timetable School view (one day, every section) + same look on My Timetable
- **School view** (`SchoolSettings/TimetableSchool`, linked from the Timetable toolbar): day pills with
  filled/total periods, a filled-periods bar and the busiest teacher, a "Find teacher" box, and a grid
  of every section (grouped by class) for the day. Click a period or search a teacher: their periods
  get an orange ring and everything else fades to 40%. Hover dims a cell slightly. A section's label
  is underlined green with ✓ when its day is full. Teachers' pending requests sit in their cells with
  ✓ / ✕, plus "Approve all" for the day. Phone: pick a section, its periods stacked. Our existing
  theme (`Timetable.css`, `tt-` classes, the 8 subject colours as soft tints `t1`–`t8`).
- Data: one call. New read-only `academic.sp_timetable_school_view` (`timetable_school_view.sql`,
  `deploy_2026_10_13d.sql`) returns every live period of the session; setup and pending requests come
  from the existing procs.
- **My Timetable** uses the same tinted cells and the dashed card for a waiting request.

### [2026-10-13] Year-End Fee Closure (Fee › Year-End Closure)
- New page `Fee/YearEnd`: every unpaid fee line of a session, grouped per student (search by name,
  father, mobile or adm. no; class filter; tabs To decide / Carried / Written off / All). Per line
  **Carry fwd** / **Write off**, per student **Carry all** / **Write off all**, and **Carry all
  remaining** for the session. Every decision has **Undo**. Viewing needs `fees.view`, acting `fees.manage`.
- Carry does not move money: the ledger is not year-scoped, so the due already shows at the counter
  next session. Carry only records that it was reviewed (`student_ledger.carried_at/by`).
- Write off reuses `core.fn_ledger_close` with `close_source = 'YearEnd'` and a required reason, the
  same mechanism Exit uses, so every report reading `amount_due - amount_paid - concession` drops it
  without changes; Undo is `core.fn_ledger_reopen`.
- One proc `core.sp_fee_year_end_manage` (`fee_year_end.sql`, `deploy_2026_10_13f.sql`), 12 rolled-back
  checks in `tests/fee_year_end_tests.sql`.

### [2026-10-14] Announcements / Notice Board
- New page `Notice/Index` (menu: Notice Board, under Dashboard, every school user). A notice has a
  title, message, category (General, Circular, Holiday, Event, PTM, Exam, Fee), who it is for
  (Everyone / Staff / All parents / Parents of selected classes), optional pin and "show until" date.
- Posting / editing / deleting needs the new permission `notices.manage` (School Admin bypasses; the
  Principal role template includes it). Everyone else only reads.
- Opening the board marks notices read, so the poster sees "Seen by N of M" with names and times.
  The navbar bell shows the five newest notices and an unread count (`Notice/Latest`).
- Parents have no login and no SMS gateway is set up, so each notice has **Print** (a circular on the
  school letterhead, `Notice/Print/{id}`) and **WhatsApp** (opens WhatsApp with the text, to share in
  the class/parents group).
- DB: `core.announcements`, `core.announcement_reads`, proc `core.sp_announcement_manage`
  (`announcements.sql`, `deploy_2026_10_14.sql`); 9 rolled-back checks in `tests/announcements_tests.sql`.
- Also: the Year-End page no longer converts its "decided on" time to school time twice.

### [2026-10-14] Staff attendance + substitute teachers
- New page `StaffAttendance/Index` (menu: Staff › Staff Attendance) with three tabs:
  - **Mark attendance**: one day, every active staff member, Present / Absent / Half day / Late /
    Leave plus a remark. Approved leave (`core.staff_leave`) is pre-selected; "Unmarked → Present"
    fills the rest. Future dates are refused. Needs `staff.manage` (viewing `staff.view`).
  - **Month register**: staff × days with P / A / H / L / LV and totals; unmarked days of approved
    leave show as LV. Printable.
  - **Substitutes**: every period of a teacher who is Absent / Half day / on leave that date, each
    given to a free teacher (present, not on leave, not already teaching or covering that period,
    least-loaded first). Needs `academics.manage`. The live timetable is never changed.
- **My Timetable** shows a teacher the periods they cover from today on.
- DB: `core.staff_attendance`, `academic.timetable_substitutions`, `core.fn_staff_away`,
  `core.sp_staff_attendance_manage`, `academic.sp_substitution_manage` (`staff_attendance.sql`,
  `deploy_2026_10_14b.sql`); 11 rolled-back checks in `tests/staff_attendance_tests.sql`.
- Payroll is not linked to attendance yet (salary still uses leave only).

### [2026-10-14] Homework
- New page `Homework/Index` (menu: Homework, under Notice Board) for teachers (a staff record is
  enough, like My Timetable) and anyone with `academics.view`. A Teaching staff member gives homework
  to one class section for one subject (title, details, given on, due on); `academics.manage` may give
  and change anyone's, a teacher only their own (enforced in the procedure).
- "Who did it?": the section's students with Done / Not done / Late, "Unmarked → Done".
- The list groups by day and class; each group has **WhatsApp** (the day's homework as text for the
  parents' group) and **Diary** (a printable homework diary with a parent's signature line).
- DB: `academic.homework`, `academic.homework_status`, `academic.sp_homework_manage`
  (`homework.sql`, `deploy_2026_10_14c.sql`); 10 rolled-back checks in `tests/homework_tests.sql`.
  Operation 'Student' (a student's last 30 days) is ready for the Student Dashboard.

### [2026-10-14] Report cards + Bonafide / Character certificates
- **Report Cards** (`ReportCard/Index`, menu Examinations › Report Cards, `exams.view`): pick an exam whose
  results are published, a class and an optional section; one A4 page per student with the letterhead,
  photo, father / mother / DOB, subject marks (max, pass, obtained, grade, result), total, percentage,
  grade, section and class rank, the session's attendance, the grade scale's remark and three signature
  lines. Built live from `GetClassResult` + the ID-card student data + `core.sp_report_card_extras`
  (mother's name, attendance counted like the Student Dashboard). Unpublished results are refused.
- **Certificates** (`Certificate/Index`, menu Students › Certificates; view `students.view`, issue/void
  `students.manage`): Bonafide (current students only, "needed for" required) and Character (current or
  former, conduct). Numbered `BC-/CC-YYYY-0001` per school and year, the student frozen at issue time,
  never deleted (Void keeps the number with a reason), printed on the letterhead with a VOID stamp when void.
- DB: `core.certificates`, `core.certificate_counters`, `core.sp_certificate_manage`,
  `core.sp_report_card_extras` (`report_card_certificates.sql`, `deploy_2026_10_14d.sql`);
  8 rolled-back checks in `tests/report_card_certificates_tests.sql`.

### [2026-10-14] Payroll counts Staff Attendance as loss of pay
- `core.fn_staff_payslip_build` now adds to LOP every day Staff Attendance marks **Absent** (1),
  **HalfDay** (0.5) or **Leave** (1) on a school working day (weighted by `fn_school_working_days`, so a
  half school day counts half) that **no approved leave of any type covers**. Approved paid leave stays
  paid and approved Unpaid leave is not counted twice. **Late** costs nothing. A school that does not mark
  staff attendance gets exactly the old leave-only LOP.
- New column `core.staff_payroll.absent_days` (the attendance part of `lop_days`), shown on the payroll
  grid ("2 absent"), the payslip modal, the CSV ("Of which Absent") and the staff's own payslip. A change
  re-generates the draft with a REGENERATED row in the money trail; a paid payslip is never touched.
- `staff_payroll.sql`, `staff_self_service.sql` (`deploy_2026_10_14e.sql`); 6 rolled-back checks in
  `tests/payroll_attendance_tests.sql`; `tests/leave_payroll_tests.sql` still 29/29.

### [2026-10-14] Homework › Overview tab (who is / is not giving homework)
- (Restricted to `academics.manage` after the first live check: teachers hold academics.view by default and should not see a colleague leaderboard.)
- New **Overview** tab on the Homework page for `academics.view`: quick ranges (Today / 7 days / 30 days /
  This session / Custom) and class chips with done %; cards (teachers giving none, missing some sections,
  homework given, checked in class); a "Who is giving homework?" donut (All / Some / None of the sections
  they teach — tap to filter the table); "Nobody is giving homework here" (busiest first); homework by
  teacher (given, sections covered, periods/week, last given, checked %, done %); a leaderboard
  (60% sections covered + 40% students checked; done % shown, not scored); was it done (done / not done /
  not checked); by subject; by class.
- Teachers come from the LIVE timetable of the current session, so someone who gives nothing still shows.
  One read-only proc `academic.sp_homework_overview` (`homework_overview.sql`, `deploy_2026_10_14f.sql`).
- Not built: parent messages / parent-app completion (there is no parent login).
- Student Dashboard gets a **Homework** tab (loaded when opened, `Student/DashboardHomework`): the
  student's homework of the last 30 days with Done / Late / Not done / Not checked, from the existing
  `sp_homework_manage` 'Student' operation.

### [2026-10-14] Fee Dashboard + Attendance Overview (read-only dashboards)
- **Fee › Fee Dashboard** (`FeeDashboard/Index`, `fees.view`): collection rate, collected this month (vs last),
  still due (families), doubtful dues, falling due in 10 days; where the money stands; collection rate by
  due month; daily collections (30 days); modes and staff this month; collection rate by class; sections
  owing most with the class teacher; class × fee head matrix; fee heads (collected / overdue / not due,
  older sessions = "Old dues") and what dues are made of; aging; how families pay (siblings grouped by the
  guardian's mobile: on time / late / habitual defaulter / too new); families owing most; recovery grading
  (safe / at risk / doubtful / likely lost by age, or the student left); money given away (concessions,
  year-end write-offs, counter discount and voids by staff); billing checks (no price set, class without a
  fee structure, students never billed). One proc `core.sp_fee_dashboard`, money in via
  `fn_fee_money_lines` without Advance / To-wallet lines.
- **Attendance › Overview** (`AttendanceOverview/Index`, `reports.view` because it ranks teachers):
  Today — every section's register for a day, pending ones "waiting on" the class teacher, the day's
  Present / Late / Absent / Leave; Insights — registers taken vs expected on school working days,
  week by week, class-teacher leaderboard (70% taken + 30% same day), sections worst-first, every missing
  register with its class teacher. One proc `core.sp_attendance_overview`.
- Homework Overview now uses `reports.view` too (was `academics.manage`, which the Principal template lacks).
- Both pages read through `DashboardReportService` (cursor rows passed to the page as column → value).
  DB: `fee_dashboard.sql`, `attendance_overview.sql` (`deploy_2026_10_14g.sql`).
- Not built: register lock / unlock and the Half day / Excused student statuses (they change marking).

### [2026-10-14] Students › Data Checks + bulk roll numbers
- New page `DataChecks/Index` (`students.view`; numbering `students.manage`): active students of the session
  failing each check — no / duplicate roll number, no / duplicate admission number, no valid section, mobile
  missing or not 10 digits, no guardian, DOB or gender (all "fix"), no photo / APAAR ID ("info") — each
  listed with View / Fix (Edit Student) links.
- **Assign roll numbers** for one section: only students without a number (continues after the highest)
  or renumber 1..n in name order. Written to `core.students` and the session's `core.student_enrolment`,
  with an `admission_audit` row, exactly like Edit Student.
- One proc `core.sp_student_data_checks` (`student_data_checks.sql`, `deploy_2026_10_14h.sql`); 6 rolled-back
  checks in `tests/student_data_checks_tests.sql`. Shared helper `Helpers/CursorRows.cs` (cursor rows for
  read-only pages) now also backs `DashboardReportService`.

### [2026-10-14] Seal & signature on printed documents
- School Setup › **Seal & Signature** (`SchoolSettings/SealSignature`; view `settings.view`, change
  `settings.manage`): upload the head of school's signature and the school seal (JPG / PNG / WEBP, < 1 MB,
  stored like the logo under the school's upload folder; a replaced or removed file is deleted), and an
  optional name + designation (default "Principal").
- `Views/Shared/_HeadSignature.cshtml` prints them (seal + signature above the line, name / designation
  below) on certificates, report cards, circulars, TC and admit cards. Nothing uploaded = the old
  "Principal" line.
- Stored in four new nullable `core.school_profiles` columns through a separate proc
  `core.sp_school_signature_manage` (`school_signature.sql`, `deploy_2026_10_14i.sql`) — the basic-profile
  proc on live differs from the repo file, so it was deliberately not touched. `GetBasicProfileAsync`
  reads the signature too (a failure there never breaks the profile).

### [2026-10-14] Staff Attendance › Month at a glance
- Under the month register: average present, days marked, absences, late arrivals, leave days, a present-each-day chart and the five staff most absent / late / on leave. Worked out in the page from the register's own data (no new call, no DB change).

### [2026-10-14] School Setup › Rooms
- New page `Rooms/Index` (`academics.view`; changes `academics.manage`): the school's rooms (name, type,
  seats, building / floor, notes) as cards with periods a week booked in the current timetable, the
  sections it is home to, and "See the week" (days × periods with section, subject, teacher).
- Rooms the timetable uses that are not in the list are flagged with an Add link. Names match through the
  existing `academic.fn_room_key` ("Lab-2" = "Lab 2"), the same key the timetable's clash check uses; a
  unique index stops two live rooms with one key. Removing a room keeps timetable bookings.
- The Timetable cell editor's Room box now suggests the listed rooms (datalist; free text still allowed).
- `academic.rooms`, `academic.sp_room_manage` (`rooms.sql`, `deploy_2026_10_14j.sql`); 6 rolled-back checks
  in `tests/rooms_tests.sql`. New base `Services/Repository/ProcRowsService.cs` for small one-proc modules.

### [2026-10-14] Front Office: visitor book, calls, complaints
- New page `FrontOffice/Index` (menu Admissions › Front Office; `enquiry.view`, entries `enquiry.manage` —
  the reception's keys). Cards: visitors today, inside now, calls today, follow-ups due, open complaints.
- **Visitors**: name, mobile, purpose, whom to meet, people, ID proof, note; time in, "Mark out".
- **Calls**: incoming / outgoing, purpose, what was said, optional follow-up date; a pending follow-up stays
  on the list until "Done" (its note is appended).
- **Complaints**: numbered `CMP-YYYY-0001`, from parent / student / staff, category, about which student,
  assigned to; Open → In progress → Resolved / Closed, a note required to resolve.
- Nothing is deleted. `core.fo_visitors`, `core.fo_calls`, `core.fo_complaints`, `core.sp_front_office_manage`
  (`front_office.sql`, `deploy_2026_10_14k.sql`); 6 rolled-back checks in `tests/front_office_tests.sql`.

### [2026-10-14] QA round 3 — batch 1 (newest modules)
- **BUG-091 (P1) Year-End**: only fees already due can be carried or written off; **Carry now moves the line
  into the next session** (`academic_year` = next, `carried_from` = old) so it leaves this session's
  defaulters — refused until the next session exists; Undo moves it back. Write-off needs the new key
  **`fees.writeoff`** (School Admin bypasses; Principal template has it), checked in the controller; the
  page hides write-off buttons without it and tags "Not due yet" lines. Old carry marks that moved nothing
  were cleared (lines open again).
- **BUG-098 / 111 Homework**: a teacher may give homework only for a class + subject on their timetable, or
  any subject of the section they are class teacher of (`sp_homework_manage` 'MyClasses' + check in Save);
  the give form lists only those; "Give homework" is hidden from staff who cannot use it. **BUG-113**: the
  admin's name shows when the admin gave homework; Late counts as done.
- **BUG-101 Substitutes**: only staff working on that date (joined, not left) are offered / accepted.
- **BUG-102 / 113 Notice Board**: "show until" cannot be in the past (an old notice may keep its date);
  posted-by and seen-by show names; "until" in Indian format; no staff "seen by" on parent-only notices.
- **BUG-104 Attendance Overview**: a section's registers are expected only from its first admission date
  (no September "misses" for a section filled in October); empty weeks hidden; label "sections with every
  register taken".
- **BUG-105 Fee Dashboard**: students who left stay in their class's money, so class totals add up.
- Bundle `deploy_2026_10_14l.sql`; tests updated: year-end 8, homework 11, staff attendance 11, announcements 9.

### [2026-10-14] QA round 3 — batch 2a (fees / cash)
- **BUG-097 / 109 Day Close**: a drawer that does not tally needs a remark (`sp_fee_day_close` refuses
  without one; the page asks first); the difference reads "Short by ₹3.00" (no double minus) and the
  closing message "short / over by Rs …".
- **BUG-096** Fee Reports register: receipt and line dates now "12 Oct 2026" — a SQL `date` read with
  `NStr` printed the server's US culture ("10/12/2026"); new `DbRead.IsoDate` reads it as ISO text.
- **BUG-072** Collect Fees due dates via a new shared helper **`EC.date`** (site.js): "Due 01 Oct 2026".
- **BUG-081** exit message amounts "Rs 10,500.00"; the leaving toast uses `EC.money`.
- **BUG-063** cancellations and refunds are recorded as authorised by the signed-in person (who must hold
  `fees.cancel` / `fees.refund`); the self-chosen "Principal / Accountant…" list is gone.
- **BUG-083 / 084 Refunds**: only refundable heads (deposits) and the advance are refundable — enforced in
  `sp_student_refundables_get` and `sp_fee_refund_record`; a wrong receipt is cancelled instead. The
  Student Dashboard lists refunds (RFD-…) beside receipts and "Paid" is net of refunds.
- **BUG-082** Collect Fees also finds students who have LEFT (tagged "Left") and opens their dues
  directly, so their fees can be cleared for a TC. **BUG-080** Mark-as-left shows the fees still on the
  account before confirming.
- **BUG-108** Collect Fees header shows "Due now" (fallen due) plus "Whole session"; the month chips also
  tick one-time / annual fees that are already due.
- Bundle `deploy_2026_10_14m.sql` (fee_day_close, fee_refund, student_exit).

### 2026-10-14 — QA round 3, batch 2b (day close for every cash-taker)
- **BUG-099** Day Close moved to its own `DayCloseController` (`/ERP/DayClose`, old `/ERP/Fee/DayClose`
  redirects). It needs `fees.collect` instead of `fees.view`, so the front desk that takes registration
  fees can close its own drawer; closing no longer needs `fees.manage`. The menu shows a Fees group with
  only Day Close to such users. The admin's "All counters" list (`sp_fee_day_close_list`) now also lists
  drawers that took money but were never closed ("Not closed yet").
- **BUG-112** The Enquiry CRM register dialog already sends payment mode + reference (the tester left it on
  Cash); a cheque now needs its number.
- Bundle `deploy_2026_10_14n.sql` (fee_day_close).

### 2026-10-14 — QA round 3, batch 3 (exams)
- **BUG-095** An absent paper now counts as 0 out of its max marks in the total, % and rank
  (`fn_exam_class_result`, `sp_exam_result_student`); a student absent from every paper still has no
  % / rank. The report card says "Absent in N subject(s)" instead of "Passed (absent …)".
- **BUG-094** An exam cannot be published while any paper has no date (the error names the papers);
  Publish asks for confirmation.
- **BUG-076** Marks cannot be saved before the paper's date (`SaveMarks`); Marks Entry shows
  "Paper not written yet" and locks the grid.
- **BUG-075** Admit cards: optional "Hold cards of students with fees due" — those students are left
  out and listed on the print page with their due amount (uses the Due Reminders list).
- **BUG-079** Result publish dialog no longer promises a parent view that does not exist.
- BUG-054 was already handled (changing the default max/pass updates cells still on the old default).
- Bundle `deploy_2026_10_14o.sql` (exam_results_publish, exam_marks, exam_result_student, exam_schedule).

### 2026-10-14 — QA round 3, batch 2c (admission fees)
- **BUG-092** The admission concession is spread over the session in whole rupees (any remainder goes to
  rows with room), so no fee ends in paise and a round payment no longer leaves a few paise in advance.
- **BUG-093** Receipts list only lines that money was paid against, each at its full charge, so the lines
  minus the Concession row add up to Total Paid; concession on later fees shows as a note, not a ₹0.00
  column. The admission "still due" message now uses the receipt's "due as on today" figure.
- **BUG-100** `fn_plan_periods`: a cycle that began before the joining day is due on the joining day, so a
  student admitted mid-month is not overdue on day one.
- Bundle `deploy_2026_10_14p.sql` (student_money_lifecycle).

### 2026-10-14 — QA round 3, batch 5 + small batch-4 items
- **BUG-019** `Strict-Transport-Security` is sent whenever the request really came over HTTPS (after
  `UseForwardedHeaders`), so the live site gets HSTS without flipping `Security:RequireHttps`.
- **BUG-059/065** Fee Head and Fee Structure hide their write buttons from users without
  `settings.manage` (the other setup pages already did). **BUG-066** Enquiry CRM hides Convert to
  Admission without `students.manage` (the admission page already redirects with a message, BUG-107).
- **BUG-086** Super Admin › Schools: a From date after the To date is swapped, with a note.
- **BUG-087** Run Payroll asks first, saying how many drafts are rebuilt and that paid ones stay.
  **BUG-089** No Void button on adjustments of a paid payslip.
- **BUG-103** Absent WhatsApp text: no "Class Class", no "(Today)"; "Notified" is remembered on this
  browser per student per day.
- **BUG-040** Student dashboard shows the ID proof number masked to the last 4 digits.
- **BUG-110** Inventory: a negative quantity says so (not "decimal places"); stock in messages prints
  without ".00" (`trim_scale`). `inventory.sql` is re-runnable again (the old short move-type check
  failed once transfers existed).
- BUG-026 / BUG-035 were already fixed.
- Bundle `deploy_2026_10_14q.sql` (inventory).

### 2026-10-14 — QA round 3, batch 4 (students / attendance / staff)
- **BUG-074** Admission with no roll number typed gets the next one in the class-section (highest numeric
  roll + 1) in `sp_admission_manage`.
- **BUG-106** Mark Attendance has Late and Leave buttons. A student added after the day's register was
  saved shows "Not marked" and is not counted Present until someone taps a status.
- **BUG-085** Every TC (Basic too) prints DOB in words, fees paid up to, working days and days present.
  Left blank on the form, `sp_tc_manage` fills them from the register and the fee ledger.
- **BUG-114** Acting class teacher: on a day the class teacher is away (approved leave / marked absent),
  a teacher with a period in that section that day (timetable or substitute) may take the register —
  new `core.sp_class_teacher_acting` (class_teacher_acting.sql), used by AttendanceController.
- **BUG-115 / BUG-090** Approving leave says which class the person is class teacher of, how many
  timetable periods need a substitute, and — for unpaid leave in an already-paid month — that a payroll
  deduction must be added (automatic LOP recovery is not built; it is a warning).
- **BUG-116** The navbar bell lists the periods a teacher covers as a substitute (from today on), linking
  to My Timetable.
- Bundle `deploy_2026_10_14r.sql` (student_master_fields, transfer_certificate, class_teacher_acting,
  staff_leave).

### 2026-10-14 — QA round 3 retest (database)
- New suite `Database/tests/qa_round3_fixes_tests.sql` (11 checks, rolled back on the QA school): all pass.
  It found that exam paper dates are stored as text on live, so the undated / future-paper checks now use
  `NULLIF(exam_date::text, '')`, and that Half Yearly results had been published before its papers were
  written: `PublishResults` now refuses while any paper is still to come (BUG-076).
- `report_card_certificates_tests` / `student_data_checks_tests` no longer assume an empty register /
  no roll gaps on the live QA data. All tenant-32 suites pass.
- Bundle `deploy_2026_10_14s.sql` (exam_results_publish, exam_marks, exam_schedule).

### 2026-10-14 — QA round 3 retest (screens, as School Admin)
- Found while retesting: `EC.money` printed a negative as "₹-3.00" (now "−₹3.00", site-wide); Payment
  History dates were ISO (now `EC.date`); Collect Fees opened from `?adm=` showed " - A" with no class
  (the class list arrived after the student and wiped it — the student now opens after the list); the
  admission form's part-payment hint now says it covers the admission-day charges only.
- Homework menu and page are for people who teach a class (timetable or class teacher, new cached
  `IHomeworkService.TeachesAnyClassAsync`) or have academics.view — an accountant's or clerk's staff record
  no longer shows it.
- My Timetable shows only for teaching staff (`staff_type` Teaching or not recorded) or anyone with
  periods; `sp_staff_my_leave` 'ME' now returns `staff_type`. Bundle `deploy_2026_10_14t.sql`.
- **BUG-063 (discounts)** Collect Fees' discount dialog no longer has a self-picked "Approved by" list:
  the approver is the signed-in user (who needs fees.concession), set by FeeController, and the receipt
  drops "(entered by …)" when it is the same person. Refunds / cancellations already worked this way.
- Student attendance is marked Present / Absent only (school's decision, 15 Oct): the Late and Leave buttons
  are removed again. Days saved earlier as Late show as Present; an old Leave keeps its tag until changed.
- Mobile check (375 px, live, 15 Oct): 27 pages, none scrolls sideways.

### 2026-10-15 — Session change: Promotion and Year-End work as one path
- Shared `Views/Shared/_SessionSteps.cshtml` on Sessions, Fee Structure, Promotion and Year-End:
  1 new session → 2 fee structure → 3 promotion → 4 year-end → 5 make it current, with links.
- **Copy fee structure** (Fee Structure page, `core.sp_fee_structure_copy`, new file
  fee_structure_copy.sql): every class's structure from one session into another, optional % increase in
  whole rupees; classes already set up are left alone (safe to run twice).
- **Year-End**: new ops `Status` / `Close` / `Reopen` in `sp_fee_year_end_manage`
  (`academic_years.fees_closed_at/by`). Close only when no line is left to decide; a closed session refuses
  Carry / Write off / Undo; Reopen needs fees.writeoff. Carry buttons are hidden when there is no next session.
- **Promotion**: a student with no roll number, or whose roll is already taken in the new class-section, gets
  the next free number (after classmates of the same run); others keep theirs. The "promote students who owe"
  note now points to Year-End for the old dues.
- New suite `tests/session_change_tests.sql` (7 checks, rolled back): all pass.
- Bundle `deploy_2026_10_15a.sql` (fee_structure_copy, fee_year_end, student_promotion).
- Screen check on live (QA school, 15 Oct): created session 2027-28, copied 14 classes / 15 sections and the
  fees (+10%), opened Promotion up to Review (not confirmed), Year-End shows 2027-28 as the next session with
  Close disabled while 518 lines remain. Found: three Promotion alerts used `d-flex` + inline `display:none`,
  which Bootstrap's `d-flex !important` overrides, so the "will be held back" warning showed with 0 students —
  they now use the `d-none` class.

### 2026-10-15 — New session: copy the whole set-up; "current" only after promotion
- The class copy (`sp_academic_year_clone`) now brings each class's **subjects** too. New
  `academic.sp_academic_year_copy_setup` copies class subjects / **class teachers** / **timetable** into a session
  that already has its classes (matched by class + section name; only staff still working; nothing already set
  is overwritten). Classes & Sections shows a "Copy from <previous>" card with the three tick boxes.
- Audit of "which session does each page use": most pages open on the current session but list students by the
  session the STUDENT is in, so making a new session current before promotion left Collect Fees, attendance
  overview, homework, data checks and the fee dashboard empty. `SetCurrentAcademicYear` now refuses a session
  with no classes, and refuses while any active student is still in another session ("N student(s) are still in
  2026-27. Promote them first"). Order: set up → promote → make current.
- Promotion's default target is the session right after the source (by name), not "the first other one".
  Year-End opens on the previous session while it still has lines to decide and is not closed.
- `tests/session_change_tests.sql` now 11 checks, all pass (uses its own ZZ sessions; rolled back).
- Bundle `deploy_2026_10_15b.sql` (academic_session_rollover, academic_year_class_section_fixes).
- **Session change edge cases**: ID cards of a chosen (older) session read the student's class / section / roll for
  that session from `core.student_enrolment`, so promoted students still print on last session's cards with last
  session's class. A TC issued when the new session has fewer than 30 register days for the student's section is
  written for the session they finished (class last studied, session, its attendance and fees paid up to).
  ID card / TC sample previews show today's April–March session instead of a fixed "2026-2027".
  `tests/session_change_tests.sql` now 13 checks, all pass. Bundle `deploy_2026_10_15c.sql` (id_card,
  transfer_certificate).

### 2026-10-15 — Real-world flow test: new student, leaving / TC / re-admit, mid-year changes
Found by walking whole flows (a new student on live; code audits of leaving and mid-year changes),
each verified before fixing. New suite `tests/flow_fixes_tests.sql` (17 checks, rolled back): all pass;
the other tenant-32 suites still pass.
- **Admission "Pay Today"** left out the first instalments due on the joining day (Rs 5,300 due a minute
  after "clears everything"). `sp_plan_instalments` returns `due_now`; the quote and the form include them.
- **Leaving**: no future date / date before admission (a future date hid the child from homework, exams and
  ID cards while still attending); an unpaid refundable deposit is closed; money already paid for later
  months is reported.
- **Re-admit**: only fees from this month on come back (not the months away); refused once the session the
  child left is over (admit again instead); a roll number taken meanwhile gets the next free one; a new
  admission of a child who left this session is refused with a pointer to Re-admit.
- **TC**: working days / days present are the days the child was on the register (joined mid-year, moved
  section, up to leaving) via `fn_attendance_student_days`; the 30-day "just promoted" rule uses the child's
  own days; "fees paid up to" never names a line closed at leaving and prefers a month label; a warning when a
  refundable deposit is still held.
- **After a TC** no money can be collected and no receipt cancelled (void the TC first). Cancelling a receipt
  on a CLOSED line keeps it closed instead of making it due again.
- **Class change** no longer bills a running quarter / half-year twice (the new class's line for that cycle is
  dropped); refused when later months are already paid (cancel / refund first).
- **Exams**: a moved student's mark on the old section's finalised sheet cannot be overwritten from the new one.
- **Fee heads**: a head with unpaid arrears of an earlier session cannot be deleted (inactive instead); the
  "inactive" message says how many instalments already billed stay due.
- **Calendar**: a day whose attendance was taken cannot be made a holiday.
- **Staff leaving** (Deactivate or status Inactive): new `core.sp_staff_release_duties` frees their class
  teacher role and timetable periods in the current and later sessions.
- **Session dates** cannot be shrunk past fees or attendance already in the session (carried-in dues ignored).
- **Dates on screen**: new `EC.today()` (local date); five pages used `toISOString()`, which in India is
  yesterday until 05:30.
- Bundle `deploy_2026_10_15d.sql`.

### 2026-10-15 — Flow fixes, part 2 (exams, due list, transport, payroll)
New suite `tests/flow_fixes2_tests.sql` (10 checks, rolled back): all pass; the other suites still pass.
- **Publish results** is refused while a student on a sheet's roster has no mark row (joined after the sheet
  was finalised): they had no result, rank or report card and nobody was told.
- **Report card**: "Needs improvement in N subject(s)" also says "absent in M" when both happen.
- **Admit cards**: an exam held for some sections only (9-A, 9-B) offers and prints only those sections.
- **Due list** sets the advance wallet against the dues: a parent who overpaid is not a defaulter (no reminder,
  no admit-card hold).
- **Bus**: a start date before the admission date is refused; a start before the session begins is moved to its
  first day; a driver marked as left cannot be put on a bus; a save that leaves fewer seats than riders is refused.
- **Staff leaving**: `sp_staff_release_duties` also takes a driver off their bus.
- **Payroll Mark Paid** rebuilds the draft first (an old draft paid yesterday's figures after a leave or salary
  change) and is refused before the month's last day.
- Bundle `deploy_2026_10_15e.sql`.

### 2026-10-15 — Last two QA fails (BUG-071, BUG-090)
- **Admission "Collect at Admission"** now includes the registration fee still unpaid on the enquiry (it is
  carried onto the student, due on the admission day, so the panel said "clears everything" while Rs 500 was
  left). `AdmissionController.RegistrationBalanceAsync` uses the same rule as `sp_admission_manage`.
- **Unpaid leave approved for a month already paid** is taken back as a Deduction adjustment in the next unpaid
  month, at the payslip's own rate (salary / school days). Days already cut as Absent are not taken twice; the
  approval message says how much and in which month. Test 11 in `tests/flow_fixes2_tests.sql`.
- Bundle `deploy_2026_10_15f.sql` (staff_leave.sql).

### 2026-10-16 — Super Admin: modules per school, Login as School Admin
- **Three levels.** Super Admin gives a school its modules (Transport, Exams, Inventory, Payroll) on
  Schools > Modules; the School Admin switches given ones on/off (Workflow page) and sets who sees what
  (Users & Roles). New columns `allow_*` on `core.school_admission_workflow_settings`; the Workflow read
  returns `enable_* AND allow_*`, so the menu, `[RequiresModule]` and every flag reader respect it. A module
  not given shows "Not in your plan" on the Workflow page and cannot be switched on. Existing schools: all given.
- **Nothing of an off module anywhere.** New `educore/Helpers/ModuleFlags.cs` (scoped, one read per request)
  and SQL `core.fn_module_on`. Gated: dashboard (My Bus, Leave link, Pending Approvals, on-leave KPI), student
  profile (exam tab/cards, bus history rows), enquiry bus question and lost reason, front-office purposes,
  promotion text (the unwired "Result" column and "Auto by result" button were removed), notice "Exam"
  category, What's coming, fee group "Transport", staff salary (kept as a hidden field on Edit Staff),
  staff profile leave/salary cards, staff attendance leave tags, Roles matrix rows (grants kept as hidden
  inputs) and module templates, settings help texts. Promotion and re-admit no longer bring a bus back when
  Transport is off; the public bus link honours the Super Admin choice. My Timetable no longer disappears
  when Payroll is off (it was tied to the Payroll switch).
- **Transport** cannot be taken away (Super Admin) or switched off (school) while students ride or owe bus
  fees -- those dues would sit on the counter with no module. Paid history (receipts, reports) keeps
  "Transport Fee": a reprint must match the original and totals must add up.
- **Module guard** now sends a user to the dashboard ("not in your school's plan" / "turned off") instead of
  the Workflow page, a dead end for anyone but the admin.
- **Login as School Admin** (Schools list, Active schools): signs the Super Admin in as the school's first
  active School Admin with two extra claims; every page shows a red "Back to Super Admin" bar. Logged in
  `core.superadmin_login_as_log` (start/end). The school's own first-login password reset is not forced on
  the Super Admin.
- Tests: `tests/superadmin_modules_tests.sql` (8). Bundle `deploy_2026_10_16a.sql`.

### 2026-10-17 — Class teachers can see their class
- New read-only `core.sp_class_teacher_of` (`class_teacher_of.sql`) and `IClassTeacherService.GetClassesOfAsync`.
- Profile menu: "Class Teacher · Class 3-A" under the name (cached 5 min, like the other menu checks).
- Dashboard: a "Your class" card per section -- students, session, whether today's attendance is marked, and a
  Mark attendance / Open register button (only with attendance.view) that opens the register on that class
  (`StudentAttendance?class=..&section=..`).
- Staff Profile: "Class Teacher of: Class 3-A (2026-27)" in Employment Details.
- Dashboard: the "Class Strength" list repeated the Class-wise Strength chart (and read "Class Class 1"); removed.
- Bundle `deploy_2026_10_16b.sql`.
- **Attendance register** (`core.fn_attendance_register`, used by the roster and the save) left in students of a
  session that has not started on that date: three children admitted in October for 2027-28 were on Class 1-A's
  2026-27 register and marked present. Found because the new "Your class" card (3 students) disagreed with the
  register (6). Bundle `deploy_2026_10_17a.sql`; flow_fixes2 #12. The three rows saved on 17 Oct stay in the table
  (QA data) but no longer show or count on the register.

### 2026-10-17 — One session's students never show up in another
Found while checking the class-teacher card: three Nursery-A children promoted on 15 Oct to 2027-28 Class 1
(promotion is allowed any time) had left Nursery-A's 2026-27 register and appeared on Class 1-A's, and saving
attendance stamped rows with the student's PRESENT class and session. Rule now, everywhere a class list is built:
**a child belongs to the class of their enrolment (`core.student_enrolment`) for the session of the date or screen.**
- New `core.fn_session_on(date)` (session containing the date, else current) and `core.fn_session_rolls`.
- Attendance: register, save (rows carry the register's class/section/session), roster roll numbers, month
  register (same register day by day), section dropdown, student attendance % (`fn_attendance_student_days`,
  so report card and TC too; the page defaults to the session in progress), Attendance Overview.
- Dashboard: student count and class strength from the session's enrolment; class strength joined classes by
  name, so every class was counted once per session (doubled with two sessions set up).
- Roll numbers: admission (check + next roll), Edit Student and Data Checks count rolls of children promoted out
  early. Certificates: class/session of the session in progress; Bonafide refused before the child's session starts.
- Fee dashboard and defaulters (with a session) group each line under that session's class. ID Cards default to
  the current session. Homework: class strength, the section's list, a student's own homework and Done/Not done
  all follow the section's session.
- Not changed (minor): fee due list / collection register class filter uses the present class; bus seat count
  includes riders booked for a later start.
- Tests: `tests/session_isolation_tests.sql` (12). Bundle `deploy_2026_10_17b.sql`.

### 2026-10-17 — Dashboard attendance section; the two leftovers
- Dashboard: **Student Attendance · Today** card opens Attendance Overview (reports.view) or the register;
  new **Staff Attendance · Today** card (present / absent / half day / on leave / not marked) opens Staff
  Attendance; new **Attendance Defaulters** card with Students (below 75% this session, after 5 days marked)
  and Staff (absences this month: Absent 1, half day 0.5; late marks shown) tabs, each name opening the profile.
  New read-only `core.sp_dashboard_attendance` (`dashboard_attendance.sql`), `IDashboardService.FillAttendanceAsync`.
- Fee Due list: the class of the session in progress; a child admitted for next session shows "Class 1 (2027-28)".
  Collection register: each receipt under the class the child was in on the receipt's date.
- Bus seats: `fn_transport_route_riders(route, except, p_on)` -- the Routes page, route dropdown and the
  "route is full" check count riders whose bus has started (by today / by the new booking's start); removing a
  vehicle or deleting a route still counts every booked rider.
- Bundle `deploy_2026_10_17c.sql`.

### 2026-10-17 — Staff Attendance: Staff report tab
- New tab on Staff Attendance: pick a staff member (search box; people who left are listed too) and a date range
  (default this month, at most a year): working days, present, late, absent, half day, on leave, not marked and
  attendance % (over the days marked), plus each day with its mark, remark, approved leave, holiday or weekly off.
- Read-only `core.sp_staff_attendance_history` (`staff_attendance_history.sql`), `IStaffAttendanceService.GetHistoryAsync`,
  `StaffAttendanceController.History`. Dashboard: today's attendance moved onto the Total Students / Total Staff
  cards (which open the attendance pages); the two separate attendance cards were removed.
- Bundle `deploy_2026_10_17d.sql`.
- **My Attendance** (`/ERP/MyAttendance`, menu + dashboard quick link for anyone with a staff record, not tied to
  Payroll): the same report as the Staff report tab for the signed-in person only -- month picker or date range.
  The staff id comes from the login's own staff record, never from the browser.

### 2026-10-17 — Promotion flow test; Year-End carry only at year end
- New `tests/promotion_flow_tests.sql` (14, rolled back): promote Class 7-A to 2027-28 mid-session and check
  register, dashboard, class-teacher card, exam sheet, homework, ID cards (both sessions), rolls, bonafide, fee due
  list, a second promotion, set-current guard, Year-End. Found: the class-teacher card counted students by their
  present record (now the session's enrolment).
- **Year-End Carry / Carry all only from the first day of the session's last month.** On 15 Oct the QA admin had
  carried 253 lines (Rs 5,24,909) of 2026-27 dues into 2027-28, which took that money out of every 2026-27 report
  (dashboard, fee dashboard, defaulters by session, Year-End). Write-off stays open all year. The 253 carries were
  undone with Year-End's own Undo on the QA school. Bundle `deploy_2026_10_17g.sql`.
- Real promotion on the QA school (Class 7-A -> Class 8, 2027-28, 17 Oct) checked screen by screen. Fixed after it:
  the **student profile** read the present record (Class 8, 2027-28: 0 school days); it now uses the class of the
  session in progress (class, section, roll, attendance, timetable, subjects, Collect Fee session) and says
  "Promoted to Class 8 – A for 2027-28". The **Student List** shows the session beside the class when it is not
  the current one.

### 2026-10-17 — Student profile: fee due split the way a fee counter keeps it
- `core.sp_student_dues_get` also returns each line's `academic_year` (bundle `deploy_2026_10_17h.sql`).
- The profile's fee card is now **Fee Due Now**: only what is owed today (due date reached). It no longer shows one
  total that mixes next session's fees into this one. The Fee tab adds a line under it with "Previous session",
  "Rest of 2026-27" (instalments not due yet) and "2027-28 (from its start)" for a child promoted early.
  An instalment row from another session carries a session badge. Logic: `DueByToday/SameYear/Later/Earlier`
  in `StudentController`.
- Same split on **Fee › Collect Fees**: `GetStudentDues` sends each due's `session`. The line under "Due now" was
  "Whole session ₹58,100" and counted next session's fees in. It now reads "Rest of 2026-27 ₹10,600 · 2027-28
  (from its start) ₹34,100" (plus "Previous session" when old dues are open), measured against the session picked
  in the filter. A due from another session carries a session badge.

### 2026-10-17 — Carried dues marked; Promotion flags only fees already due
- `sp_student_dues_get` also returns `carried_from` (bundle `deploy_2026_10_17i.sql`). A due that Year-End carried into
  the new session shows a red **"Dues of 2025-26"** badge on Collect Fees and on the student profile, and counts
  under "Previous session" there. Before, it looked like an ordinary line of the new session.
- **Promotion:** the Pending Dues column summed every open ledger line, including months still ahead and next
  session's fees, so almost every child showed red. `sp_admission_manage` 'GetStudents' now also returns
  `fee_due_now` (due date today or earlier). The roster's column is "Fee Due Now" ("Paid up" when 0, a red flag
  when not), and the confirm box says "N owe ₹X". With "Promote students who still owe fees" unticked,
  `sp_student_promote` holds back only a child with a due already fallen due. Test:
  `tests/promotion_dues_flag_tests.sql` (5, rolled back).

### 2026-10-17 — Promotion and Year-End tested together, in either order
- `tests/promotion_year_end_flow_tests.sql` (25 checks, rolled back; the session is made to end today). It covers:
  promote with dues then Year-End carry; Year-End carry before promoting, then promote (hold-back still counts carried
  dues); pass out with dues then write-off; and promoting after the session's fees are closed.
- Fixed from it: the **Year-End list** showed a promoted child's old dues under next session's class (Class 4 for
  2026-27 dues). `sp_fee_year_end_manage` 'List' now takes the class of that session from `core.student_enrolment`
  (bundle `deploy_2026_10_17j.sql`).
- Collect Fees: an older session's months not yet due were counted twice (under Previous session and under Rest of
  the selected session). Now counted once.

### 2026-10-17 — Students › Promotion History
- New page `/ERP/Student/PromoteHistory` (menu: Students › Promotion History; action named so the menu's
  `On("Promotion")` does not light up both items). Pick the session promoted FROM. It shows Total / Promoted /
  Kept in same class / Passed out (click one to filter), a class-by-class table (click a class to list it), and a
  list: from class → to class (session), result, fee due at the time (fee users only), done by and when. Each
  name opens the profile.
- `core.sp_promotion_history` (`promotion_history.sql`, bundle `deploy_2026_10_17k.sql`) reads
  `core.student_promotion_history`, using the latest move per child. `p_only_my_class` limits it to sections
  whose class teacher in that session is the user. The office (`students.manage`) sees the whole school;
  anyone else sees only their own class.

### 2026-10-17 — Profile Class history; fee receipt follows the session
- **Student profile › Academic:** "Current placement · 2026-27" names its session, and a new **Class history** box lists
  every session (newest first) from `GetEnrolmentHistoryAsync`: "Studying now", "Next session" (promoted before
  this session ended), or Promoted / Kept in same class / Passed out / Left. A child promoted early showed only
  "Nursery" and looked as if the promotion had not happened.
- **Fee receipt** (`core.sp_fee_receipt_get`, bundle `deploy_2026_10_17l.sql`; only that proc from
  `fee_advance.sql`). The class is now the one of the session the payment was made in (`fn_session_on(payment_date)`
  + `core.student_enrolment`). Before, a child promoted early paying this year's fee got a receipt saying next
  session's class. The receipt prints "Nursery - A (2026-27)", each line carries its session when it is another
  one ("Tuition Fee — Apr 2027 (2027-28)", "… (Dues of 2025-26)" for a Year-End carry), and under "Outstanding as
  on" a line "of which previous session". A registration receipt (no enrolment yet) prints no session.

### 2026-10-18 — One School Calendar (events + exams); Books & Uniform Sale
- **School Calendar** (`school_events.sql`, bundle `deploy_2026_10_18a.sql`). New `academic.school_events` (PTM / Event /
  Sports / Trip / Meeting / Other; date range, optional times, "for whom", notes; soft delete) and
  `academic.sp_school_events_manage` List / Save / Delete. List also returns the **exam periods** from `academic.exams`
  while the Exams module is on (exam dates are text columns, so they are cast). The calendar page shows event and exam
  chips on the month grid, an "Events & Exams" list, and an event dialog; a day click shows what is on. Holidays
  still decide working days, so events do not touch attendance or the Smart Bell. The page and its data are now
  `SchoolUserOnly` (every member of staff sees them); changes still need `academics.manage`. The menu item moved from
  Setup to the common staff items. The dashboard has an **Upcoming** card (next 30 days; a vacation's days in a row
  show as one line).
- **Books & Uniform Sale** (`inventory_student_sale.sql`; Inventory › Books & Uniform Sale, `inventory.manage`). Built on
  Inventory: an item sold is a 'Saleable' item with a selling price (one item per uniform size). A sale issues the
  stock ('Issue' movement, issued to the student) and adds one fee line per item to `core.student_ledger` (head =
  item category, 'One Time', due today, in the session chosen: a child promoted early can get next session's books
  charged in 2027-28). So Collect Fees, receipts, due list and reminders need no change. **Class sets**
  (`core.inventory_class_kits`) fill in a class's books when a student is picked. A **return** is allowed only while
  the fee line is unpaid: the line is closed (`fn_ledger_close`, source 'Store') and the stock comes back.
  `StudentSaleService` / `IStudentSaleService` (new). `school_purge.sql` deletes events, sales and class sets.
- Tests: `tests/calendar_store_tests.sql` (16 checks, rolled back).

### 2026-10-18 — Full inventory flow test
- Database: `inventory_tests` 49/49, `inventory_store_tests` 142/142, `inventory_locations_tests` 111/111, `calendar_store_tests`
  16/16 (all rolled back on the live QA school). The three older suites pointed at the wiped tenant 24; they now use the
  QA school (32/45/62) and a made-up "other school" 99001 that exists only inside the test. Stale expectations updated:
  stock messages print whole numbers ("35", not "35.00"), and the ledger's "who" is any name.
- Fixed from it: `sp_inventory_student_sale` 'SaveKit' deleted the class set's rows, against the store rule that rows
  are never hard-deleted (LED-07). An item taken out of a set now keeps its row with quantity 0 (bundle
  `deploy_2026_10_18b.sql`).
- On screen (QA school, real data): supplier → purchase (10 @ ₹200, stock 19 → 29) → issue / damage / over-issue refused
  / stock-take → transfer to Science Lab → sale from the Science Lab → supplier return 2 (over-return refused) → bill
  cancel (only the 8 not returned come out) → minimum stock → Low Stock. Stock by location and value checked by hand.

### 2026-10-18 — Books & Uniform Register (✓ / ✗ per child)
- `/ERP/StoreRegister` (`StoreRegisterController`, Inventory module). It shows a class-section's children (enrolment of the
  session, by roll) down the side and the store's items across the top: the class set's items plus anything a child of the
  class was given that session. Each cell is ✓ (held this session, not returned) or ✗. Sizes are separate items, so
  "Shirt - 28" / "Shirt - 30" share one "Shirt" column, with the size under the tick. There is a "missing" count per
  child, "have it n/N" per column, a "only children missing something" filter, and Print. Unpaid amounts show only with
  `fees.view`.
- Store staff (`inventory.view`) pick any session/class/section (menu: Inventory). Anyone else sees only the sections
  they are class teacher of this session (menu: Students). `Data` refuses another class.
- `core.sp_inventory_class_register` (in `inventory_student_sale.sql`, bundle `deploy_2026_10_18c.sql`), 3 cursors.

### 2026-10-18 — Expenses and the Cash Book
- `expense_cashbook.sql` (bundle `deploy_2026_10_18d.sql`): `core.expense_categories` (default heads created on first use;
  never deleted, only hidden), `core.expenses` (never edited or deleted: cancelled with a reason), `core.cashbook_opening`
  (cash + bank on a date), and the permissions `expenses.view` / `expenses.manage` (Finance).
- `core.fn_school_money` is the one place that turns money into lines, reading where it is already recorded: fee receipts
  via `fn_fee_money_lines` (real modes only; 'Advance' / 'To wallet' are wallet bookkeeping), fee refunds, salaries paid
  (`staff_payroll` Paid), store purchase bills, supplier returns, expenses. A cancellation is a reversal on the day it
  happened (Day Close's rule), so a past month never changes. Book = Cash (mode Cash) or Bank (everything else).
- `core.sp_cashbook`: opening (opening balance + everything from its date up to the range), lines with running balance,
  totals by head, month by month. Pages: Finance › Expenses & Cash Book (`ExpenseController`, `IExpenseService`).
- Test: `tests/expense_cashbook_tests.sql` (17, rolled back): fees in the book = the Day Close money lines, a cancelled
  expense comes back on its cancel day, a bought / part-returned / cancelled bill nets to 0, opening balances carry.

### 2026-10-18 — Books & uniform money kept apart from fees; store summary
- `core.fn_school_money` splits each fee receipt by what it paid: the share paid against fee lines that came from a store
  sale (`inventory_student_sale_lines.ledger_id`) is shown under **"Books & Uniform sales"**, the rest under "Fees". A
  receipt paid in several modes is split in proportion in each mode, so the total never changes (bundle
  `deploy_2026_10_18e.sql`).
- `core.sp_inventory_store_summary` (Inventory › Books & Uniform Sale, "Store summary": this month / last month / this
  session). It shows **sold** (charged to students, returns off), **margin** (sold − cost at which the items were issued),
  **collected** / **still unpaid** of those fee lines, **bought** (supplier bills of saleable items, returns off,
  cancelled bills out), and **stock on hand** at cost.
- Test: `expense_cashbook_tests.sql` now 18 checks, including "store items paid at Collect Fees are Books & Uniform sales"
  and "fees + store sales = the Day Close money lines".

### 2026-10-18 — Inventory made simple for a small school
- Menu: Inventory is now three items. **Store** (Items & Stock; Store Locations open from its button), **Purchase**
  (Suppliers open from its button), **Student Items** (two tabs, `_StudentItemsTabs`: Give items | Register ✓/✗). A user
  who can see but not give goes straight to the register.
- No more "Class sets" screen. A saleable item says **which class it is for** on the item itself
  (`inventory_items.for_class`, NULL = every class; set in the item form). Existing class sets were moved over: an item
  that was in exactly one class's set is for that class. The sale page lists the class's items unticked (the parent takes
  what they want; "Tick all (1 each)" fills one of each), and the register's columns are every item for the class plus
  anything given to its children.
- **Sizes in one go:** the item form takes "24, 28, 32" and makes one item per size ("Uniform - 24" ...). Sizes share one
  register column, and are never ticked automatically. `core.fn_item_base_name` is the base-name rule in SQL.
- `sp_inventory_student_sale` gained `p_item_id` (ops ItemClass / SetItemClass), placed after `p_result` so older callers
  still fit. Old signature dropped (bundle `deploy_2026_10_18f.sql`). `core.inventory_class_kits` is kept but not read.
  Tests: `calendar_store_tests.sql` 20 checks.

### 2026-10-18 — Store walked through from empty (QA school data cleared), fixes
- QA school store data was cleared (items, purchases, suppliers, movements, sales; open store fee lines closed with
  "Store reset", the one paid receipt cancelled first). Then the flow was run as a new school on screen: item → supplier
  (from Purchase's "+") → bill → give to a student → pay part by UPI → return the unpaid item → register / summary /
  Cash Book. Money and stock agreed at every step.
- Fixed from it:
  - A new item defaulted to "Consumable", so an item with a selling price never showed in Student Items. The type is now
    asked in plain words ("Given to students / Used up in school / School equipment"), and a new item defaults to "Given
    to students". The list and filter use the same words.
  - The Store page is called Store. An empty store says how to add the first item.
  - With one location, Purchase does not ask "Goods go to", and the item form does not ask where the opening stock is
    kept.
  - Student Items: a paid item says "To return: cancel its receipt first".
  - A store fee line reads like the item: head = item name, label = size / quantity ("Uniform — 24", "School Diary × 2"),
    not "Uniform — Uniform - 24" (bundle `deploy_2026_10_18g.sql`). Lines made earlier keep their wording.

### 2026-10-18 — Register: every class at once for store staff
- Store staff (`inventory.view`) open the Books & Uniform Register on **"All classes (overview)"**: one line per class-section
  of the session, "n/N" children holding each item ("—" where the item is not for that class), and "Have everything" =
  children holding every item meant for their class. Sizes share a column. Clicking a line opens that class-section's
  ✓ / ✗ list. Teachers are unchanged: their own class only.
- `core.sp_inventory_register_overview` (bundle `deploy_2026_10_18h.sql`) returns the session's children, the items and
  who holds what; `StoreRegisterController.Overview` adds it up.

### 2026-10-18 — WhatsApp alerts to parents (platform account, test mode until connected)
- One platform WhatsApp Business number (Meta Cloud API). `WhatsAppChannel.SendTemplateAsync` sends approved templates;
  the settings live in `Notifications:WhatsApp` (Railway variables, never in appsettings). While it is not connected,
  every message is built and recorded as **Test**. Setup steps: `educore/docs/WHATSAPP-SETUP.md`.
- `SchoolMessenger` is the one place pages send from: it checks the school's switch, normalises Indian mobiles (91 +
  10 digits), sends the template and writes **every** message to `core.message_log` (Sent / Failed with the reason /
  Test / NoPhone).
- `messaging.sql` (bundles `deploy_2026_10_18i/j.sql`): `core.school_messaging` (Super Admin switch per school, off by
  default), `fn_whatsapp_on`, `sp_school_messaging` (Super Admin only), `sp_whatsapp_on`, `sp_message_log`
  (Add / List / Summary). `school_purge.sql` covers both tables.
- Alerts:
  - **Attendance** → "Send to all parents" (absent children from the saved register; the class-teacher rule
    applies).
  - **Fee Due Reminders** → WhatsApp sends the `fee_reminder` template (WhatsApp does not allow free text when the
    school writes first).
  - **Notice Board** → "Send to parents" (the notice's audience, one message per number; staff-only notices are not
    sent).
  - **Message Log** page for admins.
  - **Super Admin Modules** has a "WhatsApp messages" switch with the month's count.
- The old "open a WhatsApp chat" buttons stay for schools without it.
- Tests: `tests/messaging_tests.sql` (9, rolled back).

### 2026-10-18 — Store: opening stock shown apart (no supplier, no bill)
- Add Item: "Opening Stock" is now **"Stock already in school (before today)"**, with a note that new stock goes through **Purchase** (supplier + bill).
- `sp_inventory_manage` 'ListItems' returns `opening_qty` (sum of the item's 'Opening' ledger rows). The item list shows "N opening (no bill)" under the stock, the Stock filter has **"Opening stock (no bill)"**, and History labels it the same way.
- Bundle `deploy_2026_10_18k.sql`.
- Follow-up after a full flow test (same day): stock **added by hand** (an Adjustment, or a stock-take that counted more) also has no bill, so 'ListItems' returns `added_qty` and the note reads e.g. "23 no bill (20 opening + 3 added by hand)"; the filter is now **"Came in without a bill"**.
- A **new purchase needs a supplier** (page + `sp_inventory_purchase_manage` 'Save'); old bills without one stay as they are. No fixed shop → add a supplier called "Local market". Bundle `deploy_2026_10_18l.sql`.
- Phone check: the note reads "23 came in without a bill (20 opening + 3 added by hand)" and sits on its own line under the card's icons; the Purchase supplier box is no longer squeezed by the + button; Store / Purchase summary cards drop the icon on phones so a full rupee figure fits.

### 2026-10-18 — Student Items: "Items given" slip
- After **Give items**, a **Print slip** button prints a small slip for the parent: school, child, class/session, date, items × qty × rate, total, "added to the fee account, pay at the office, this is not a receipt", given by + parent's signature.
- Same day, reworked: the slip now opens in the **shared receipt modal** (`fee-receipt.js` `EcReceipt.showItemsGiven`, layout `renderItemsGiven`): the receipt's letterhead + logo, the school's receipt format (A4 / A5 / Thermal, switchable), a preview on screen, then Print. The page passes school name/address/logo and the format from `InventoryController.StudentSale` (store staff may not have `fees.view`, so it does not call `Fee/GetSchoolHeader`). No DB change.

### 2026-10-19 — Student Items: "Sell by class"
- New tab **Sell by class** (`Inventory/ClassSale`, inventory.manage): pick session / class / section (and store), search in the class, "only children with something pending". Each child shows ✓ (size, ×qty, unpaid) for what they have this session and a tick box (or a size drop-down for sized items) for what is still pending; a header tick ticks a column for everyone missing it.
- The bar shows "N items for M children · ₹total"; stock is checked before giving. **Give** calls the existing `Inventory/Sell` once per child (qty 1 per item), then lists who got what with **Collect** and **Slip** (the same Items-given slip) buttons, and reloads the grid.
- No DB change: the grid reads `StoreRegister/Data` (who has what) and `Inventory/SaleItems` (price, stock). Slip header code moved into `InventoryController.SetSlipHeaderAsync` for both pages.

### 2026-10-19 — Inventory pages tidied (repeated / dead things removed)
- **Purchase:** removed the "Print Preview" button (it only said "not built yet"), the "Purchase Notes" box (technical, and one line was out of date after suppliers became required), the second "Add Purchase Item" button in the empty list and the "Suppliers" card (the Suppliers button sits above it). Three cards remain.
- **Store:** the SKU column shows only when some item has an SKU; "Stock in / out" has its own icon (it looked like Transfer); Transfer and the location filter show only with two or more stores.
- **Sell by class / Register on phones:** a narrow name column (name on two lines, roll only, adm. no hidden) so 2-3 items fit beside it.
- Old names fixed in page text: "Items & Stock" / "Item Master" -> Store, "type Saleable" -> "Given to students".

### 2026-10-19 — Store list shows which class an item is for
- `sp_inventory_manage` 'ListItems' returns `for_class` ('' = every class). The Store list shows it under "Given to students" ("Class 1" / "All classes", also on the phone card), and a **For class** filter lists what a child of that class can be given (its own items and the all-class ones). Bundle `deploy_2026_10_19a.sql`.

### 2026-10-19 — An item can be for several classes
- Real schools sell some items to a group of classes (senior uniform / lab coat for Class 9-12), so `inventory_items.for_class` is now `text[]` (NULL = every class); old single values became one-element lists. Procs match with `p_class = ANY (for_class)` and send the list as one text joined by '|' (`array_to_string`); `SetItemClass` takes 'Class 9|Class 10|Class 11'.
- Store form: **For which classes?** is a wrap of tick pills (none ticked = all classes). The list, phone card, For class filter, Give items badge and the Register overview read the list.
- Bundle `deploy_2026_10_19b.sql` (column change + sp_inventory_student_sale, sp_inventory_class_register, sp_inventory_register_overview, sp_inventory_manage).

### 2026-10-19 — Store: order list, size exchange, supplier dues
- **Order list** (`Inventory/OrderList`, button on Purchase): per item given to students (sizes on one line with stock per size), the children enrolled in its classes for a session, how many already have it, still need, in stock and **to order**; print. `sp_inventory_order_list`. It counts enrolment, so next session needs promotion / admissions first (the page says so).
- **Change size** on Give items: a sold line moves to another size of the same item (`sp_inventory_student_sale` 'Exchange'): old size back on the shelf, new one off it (two movements), fee line label and, if unpaid, price follow; a paid line only takes a size of the same price.
- **Supplier dues**: Purchase payment mode **"Credit (pay later)"** = owed, not money out. `core.inventory_supplier_payments` + `sp_inventory_supplier_pay` (Pay / List / Cancel, never deleted) + `fn_supplier_due`; Suppliers page shows **Due**, **Pay** and **Payments**. Cash Book (`fn_school_money`): credit bills (and their returns / cancels) left out, "Supplier payment" money out, "Supplier payment cancelled" back in on the cancel day.
- Files: `inventory_store_extras.sql` (new), `inventory_student_sale.sql`, `expense_cashbook.sql`, `inventory.sql` (supplier `due`); bundle `deploy_2026_10_19c.sql`; tests `tests/store_extras_tests.sql` (18, rolled back).

