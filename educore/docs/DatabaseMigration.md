# Database Migration Guide — Local → Live (Railway)

How to push your local PostgreSQL database (schema + stored procs + data) up to the
live Railway database. This is the procedure used to mirror local onto Railway.

> **There is no ORM and no EF migrations here.** Schema and stored procedures live as raw
> SQL, so "migrating" means **dump the local database and restore it onto Railway** — not
> running a migrations tool. This guide covers the **full-replace** strategy (make Railway an
> exact copy of local). For keeping live data while only adding new structure, see
> [Strategy B](#strategy-b--schema--procs-only-keep-live-data) at the end.

---

## ⚠️ Read this first

- **This OVERWRITES the live database.** Everything on Railway is dropped and replaced with a
  copy of local. Any data that exists only on Railway is **lost**. Always take the backup in
  Step 3 first.
- **Both databases currently hold test/dev data only.** If the live DB ever holds real
  customer data, do **not** full-replace — use Strategy B instead.
- **Never commit the live DB password.** It is not in this file on purpose. Get it from the
  Railway dashboard (Postgres service → *Connect*) or your private notes, and pass it via the
  `PGPASSWORD` environment variable as shown below.

---

## Version gotcha — why we need the PG18 client tools

| | Server version | `pg_dump` / `psql` you have |
|---|---|---|
| **Local** | PostgreSQL **16** | `C:\Program Files\PostgreSQL\16\bin\` (v16) |
| **Railway (live)** | PostgreSQL **18** | — |

`pg_dump` **refuses to dump a server newer than itself**, so the local PG16 `pg_dump`
**cannot** back up the PG18 Railway server:

```
pg_dump: error: aborting because of server version mismatch
pg_dump: detail: server version: 18.x; pg_dump version: 16.x
```

The fix: use **PG18 client tools for everything**. A newer `pg_dump` can dump *both* an older
server (local PG16) **and** a same-version server (Railway PG18). One toolset, no mismatch.

### Getting the PG18 client tools (one-time)

Download the portable Windows binaries (no install/admin needed) and extract just what you need:

```bash
# from a scratch/working folder
curl -L -o pg18.zip "https://get.enterprisedb.com/postgresql/postgresql-18.4-1-windows-x64-binaries.zip"
unzip -q pg18.zip "pgsql/bin/*" "pgsql/lib/*" "pgsql/share/*"

# verify
./pgsql/bin/pg_dump.exe --version   # -> pg_dump (PostgreSQL) 18.x
```

Below, `PG18` means the path to that extracted `pgsql/bin` folder, e.g.
`./pgsql/bin` or `C:\tools\pgsql\bin`.

---

## Connection details

| | Host | Port | Database | User |
|---|---|---|---|---|
| **Local** | `localhost` | `5432` | `educore` | `postgres` |
| **Railway (live)** | `acela.proxy.rlwy.net` | `33399` | `railway` | `postgres` |

> Host/port/db can change if Railway re-provisions the proxy — re-check the Railway dashboard
> if a connection fails. Passwords: local is `root` (dev only); live = **set from the
> dashboard**, never hard-code it.

---

## The migration — step by step

Run these from your working folder (where you extracted `pgsql/`). Commands are shown for
**Git Bash**; PowerShell equivalents are noted where the syntax differs.

### Step 1 — Sanity-check both servers are reachable

```bash
# local
PGPASSWORD='root' ./pgsql/bin/psql.exe -h localhost -p 5432 -U postgres -d educore \
  -c "select version();"

# live  (set the real password)
PGPASSWORD='<RAILWAY_PASSWORD>' ./pgsql/bin/psql.exe \
  -h acela.proxy.rlwy.net -p 33399 -U postgres -d railway -c "select version();"
```

PowerShell sets env vars differently:
```powershell
$env:PGPASSWORD='root'; .\pgsql\bin\psql.exe -h localhost -p 5432 -U postgres -d educore -c "select version();"
```

### Step 2 — Compare what's on each side (optional but recommended)

Confirms local really has the newer structure and shows what live data you'd be dropping.

```bash
# table counts per schema  (run against each server)
psql ... -c "SELECT schemaname, count(*) FROM pg_tables
             WHERE schemaname IN ('core','config','academic') GROUP BY 1 ORDER BY 1;"
```

### Step 3 — Back up the live (Railway) database  ⛑️ DO NOT SKIP

This is your rollback if anything goes wrong.

```bash
PGPASSWORD='<RAILWAY_PASSWORD>' ./pgsql/bin/pg_dump.exe \
  -h acela.proxy.rlwy.net -p 33399 -U postgres -d railway \
  -Fc -f railway_backup_$(date +%Y%m%d_%H%M%S).dump -v
```

`-Fc` = custom (compressed) format, restorable with `pg_restore`. Keep this file safe until
you've confirmed the migration is good.

### Step 4 — Dump the local database

```bash
PGPASSWORD='root' ./pgsql/bin/pg_dump.exe \
  -h localhost -p 5432 -U postgres -d educore \
  -Fc -f local_educore.dump -v
```

Inspect what it contains (schemas/extensions) if you want:
```bash
./pgsql/bin/pg_restore.exe -l local_educore.dump | grep -Ei "SCHEMA -|EXTENSION -"
# -> academic, config, core schemas + pgcrypto extension
```

### Step 5 — Wipe the live schemas

Drop the four schemas the app owns and recreate an empty `public`. This guarantees an **exact**
mirror (the alternative, `pg_restore --clean`, leaves behind any live-only tables).

> The app uses schemas `core`, `config`, `academic`, and stored procs in `public`.
> `pgcrypto` lives in `public` and is recreated by the restore in Step 6.

```bash
PGPASSWORD='<RAILWAY_PASSWORD>' ./pgsql/bin/psql.exe \
  -h acela.proxy.rlwy.net -p 33399 -U postgres -d railway -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
DROP SCHEMA IF EXISTS core     CASCADE;
DROP SCHEMA IF EXISTS config   CASCADE;
DROP SCHEMA IF EXISTS academic CASCADE;
DROP SCHEMA IF EXISTS public   CASCADE;
CREATE SCHEMA public;
GRANT ALL ON SCHEMA public TO postgres;
GRANT ALL ON SCHEMA public TO public;
COMMIT;
SQL
```

### Step 6 — Restore local onto live

`--single-transaction` makes it **all-or-nothing**: any error rolls the whole restore back, so
you never end up with a half-migrated live DB.

```bash
PGPASSWORD='<RAILWAY_PASSWORD>' ./pgsql/bin/pg_restore.exe \
  -h acela.proxy.rlwy.net -p 33399 -U postgres -d railway \
  --no-owner --single-transaction -v local_educore.dump
```

- `--no-owner` — objects are owned by the connecting role (`postgres`); avoids errors if role
  names differ between servers.
- Exit code `0` = success.

### Step 7 — Verify the mirror

**Structure** (tables + procs should match local):
```bash
psql <live> -c "SELECT schemaname, count(*) FROM pg_tables
                WHERE schemaname IN ('core','config','academic') GROUP BY 1 ORDER BY 1;"
```

**Row counts, every table — should be identical to local.** Dump both to files and `diff`:
```bash
COUNTSQL="SELECT format('%s.%s=%s', schemaname, tablename,
  (xpath('/row/c/text()', query_to_xml(
     format('SELECT count(*) c FROM %I.%I', schemaname, tablename), false, true, '')))[1]::text)
  FROM pg_tables WHERE schemaname IN ('core','config','academic') ORDER BY 1;"

PGPASSWORD='<RAILWAY_PASSWORD>' ./pgsql/bin/psql.exe -h acela.proxy.rlwy.net -p 33399 \
  -U postgres -d railway -t -A -c "$COUNTSQL" > rw_counts.txt
PGPASSWORD='root' ./pgsql/bin/psql.exe -h localhost -p 5432 \
  -U postgres -d educore -t -A -c "$COUNTSQL" > loc_counts.txt

diff loc_counts.txt rw_counts.txt && echo "IDENTICAL"
```

> **Expected harmless difference:** the live `public` schema will have one extra function,
> `fips_mode` — that's a built-in of **PG18's** `pgcrypto`, not your code. Everything in
> `core`/`config`/`academic` should match exactly.

### Step 8 — App picks it up automatically

No code or config change is needed. Production reads its connection string from the
`ConnectionStrings__DefaultConnection` environment variable (set in Railway), which already
points at this database. The new schema and stored procedures are live immediately.

---

## Rollback

If the migration went wrong, restore the Step 3 backup over the live DB:

```bash
PGPASSWORD='<RAILWAY_PASSWORD>' ./pgsql/bin/pg_restore.exe \
  -h acela.proxy.rlwy.net -p 33399 -U postgres -d railway \
  --clean --if-exists --no-owner --single-transaction -v railway_backup_YYYYMMDD_HHMMSS.dump
```

---

## Strategy B — schema + procs only (keep live data)

Use this **instead of Steps 5–6** if the live database holds data you must keep and you only
want to add new tables/columns/procs. There is no automatic diff tool here, so it's manual:

1. **New tables / procs** — safe to add. Restore only those objects, or run the matching
   feature SQL from `EduCoreDataAccessLayer/Database/*.sql`.
2. **Changed tables** (new columns, etc.) — write explicit `ALTER TABLE` statements; a restore
   will *not* alter an existing table.
3. **Changed stored procs** — `CREATE OR REPLACE FUNCTION ...` (or restore just those functions).
4. Always take the Step 3 backup first, and test on a throwaway copy if possible.

Full-replace (Steps 5–6) is simpler and guaranteed-correct, so prefer it whenever the live
data is disposable.

---

## Quick reference — full run

```bash
PG18=./pgsql/bin
LIVE="-h acela.proxy.rlwy.net -p 33399 -U postgres -d railway"
LOCAL="-h localhost -p 5432 -U postgres -d educore"

# 3) backup live          (set the real password first)
PGPASSWORD='<RAILWAY_PASSWORD>' $PG18/pg_dump.exe $LIVE -Fc -f railway_backup_$(date +%Y%m%d_%H%M%S).dump -v
# 4) dump local
PGPASSWORD='root'              $PG18/pg_dump.exe $LOCAL -Fc -f local_educore.dump -v
# 5) wipe live schemas      (see Step 5 heredoc)
# 6) restore
PGPASSWORD='<RAILWAY_PASSWORD>' $PG18/pg_restore.exe $LIVE --no-owner --single-transaction -v local_educore.dump
# 7) verify counts
```
