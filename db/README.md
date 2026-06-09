# Database

`schema.sql` is the version-controlled snapshot of the EduCore PostgreSQL schema:
all tables, functions, and stored procedures (structure only — **no data**).

This is the source of truth for the database. All business logic lives in the
stored procedures, so keeping this file current is as important as committing C# code.

## Regenerate after any DB change

```powershell
powershell -ExecutionPolicy Bypass -File db\dump-schema.ps1
git add db/schema.sql
git commit -m "Update DB schema"
```

## Rebuild the database from scratch

```powershell
createdb -U postgres educore
psql -U postgres -d educore -f db/schema.sql
```
