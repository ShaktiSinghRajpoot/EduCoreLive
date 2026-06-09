# Re-dumps the educore database schema (tables + functions/procedures) into schema.sql.
# Run this whenever you change a stored procedure or table so the repo stays in sync.
#
#   powershell -ExecutionPolicy Bypass -File db\dump-schema.ps1
#
# Override defaults via env vars if needed: PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD

$ErrorActionPreference = "Stop"

$pgDump = "C:\Program Files\PostgreSQL\16\bin\pg_dump.exe"
if (-not (Test-Path $pgDump)) { throw "pg_dump not found at $pgDump - update the path." }

$pgHost = if ($env:PGHOST)     { $env:PGHOST }     else { "localhost" }
$pgPort = if ($env:PGPORT)     { $env:PGPORT }     else { "5432" }
$pgDb   = if ($env:PGDATABASE) { $env:PGDATABASE } else { "educore" }
$pgUser = if ($env:PGUSER)     { $env:PGUSER }     else { "postgres" }
if (-not $env:PGPASSWORD) { $env:PGPASSWORD = "root" }  # dev default; set PGPASSWORD for other envs

$out = Join-Path $PSScriptRoot "schema.sql"

& $pgDump -h $pgHost -p $pgPort -U $pgUser -d $pgDb --schema-only --no-owner --no-privileges -f $out
if ($LASTEXITCODE -ne 0) { throw "pg_dump failed with exit code $LASTEXITCODE" }

Write-Host "Schema written to $out"
