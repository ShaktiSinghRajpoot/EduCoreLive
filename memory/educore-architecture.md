---
name: educore-architecture
description: EduCore's actual architecture and key technical-debt facts
metadata:
  type: project
---

EduCore = multi-tenant school SaaS. Two projects: `educore` (ASP.NET Core 9 MVC) + `EduCoreDataAccessLayer` (thin ADO.NET stored-proc caller). ALL business logic lives in PostgreSQL stored procedures; the "DAL" only marshals NpgsqlParameters and copies DataRow→models via DataSet/DataAdapter.

Key debt (as of 2026-06-09): no .gitignore, ~978 build artifacts tracked in git; DB credentials committed in appsettings.json; hardcoded EncryptionKey in Common.cs; zero .sql files in repo (schema + procs unversioned); no tests, no CI (.github empty); in-memory session blocks horizontal scaling; `[Authorize]` commented out on some controllers.

How to apply: respect the proc-centric design — it's a valid choice for a [[user-profile|solo dev]]. Prioritize security + versioning the database over re-architecture.
