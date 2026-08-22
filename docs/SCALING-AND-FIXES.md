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
