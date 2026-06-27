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
