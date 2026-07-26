-- ============================================================================
-- config.boards / school_types / school_statuses — drop the fake tenant scoping.
--
-- THE MISMATCH
-- These three carried a tenant_id column and tenant-scoped unique constraints:
--     uq_board_name        UNIQUE (tenant_id, name)
--     uq_school_type_name  UNIQUE (tenant_id, name)
--     uq_school_status_name UNIQUE (tenant_id, name)
-- ...so the SCHEMA promised "every tenant may define its own". But every reader
-- ignores tenant_id entirely, e.g. config.sp_school_dropdowns:
--     SELECT board_id AS id, name FROM config.boards WHERE is_deleted = FALSE
-- and in the data all rows sit on tenant_id = 1.
--
-- That combination is a trap in BOTH directions:
--   1. Insert a row with tenant_id = 7 (which the schema invites) and it shows
--      up in EVERY tenant's dropdown — a cross-tenant config leak. sp_school_manage
--      also validates board_id without a tenant check, so one tenant's school could
--      be saved against another tenant's board.
--   2. "Fix" it by adding WHERE tenant_id = p_tenant_id and every real tenant's
--      dropdown goes EMPTY — all rows are on tenant 1 and real tenants are > 1.
--      This is the more dangerous one, because it looks like the obvious fix.
--
-- THE DECISION: these are PLATFORM data, not tenant data.
--   * Boards (CBSE / ICSE / State Board) are nationally fixed.
--   * School types (Primary / Secondary / Sr. Secondary) are fixed.
--   * School statuses are the PLATFORM's lifecycle for a school — the super admin
--     owns them, not the tenant.
-- So the column goes, matching what the code already does and mirroring
-- config.countries / states / districts, which never had tenant_id.
--
-- NOT touched: config.roles. That one is genuinely per-tenant (8 tenants, 31 rows)
-- and login joins on it — see the roles note in docs/SuperAdminSchools.md.
--
-- Verified before writing: no proc INSERTs/UPDATEs these tables, no FK references
-- them, no C# touches tenant_id on them, and no duplicate names exist.
-- Re-runnable.
-- ============================================================================

-- ── boards ─────────────────────────────────────────────────────────────────
DROP INDEX IF EXISTS config.idx_boards_tenant;
ALTER TABLE config.boards DROP CONSTRAINT IF EXISTS uq_board_name;
DROP INDEX IF EXISTS config.uq_board_name;
DROP INDEX IF EXISTS config.uq_board_code;

ALTER TABLE config.boards DROP COLUMN IF EXISTS tenant_id;

-- Partial, unlike the old plain UNIQUE: a retired board must be able to share its
-- name/code with a live one (e.g. after the Cambridge merge).
CREATE UNIQUE INDEX IF NOT EXISTS uq_board_name
    ON config.boards (name) WHERE is_deleted = FALSE;
CREATE UNIQUE INDEX IF NOT EXISTS uq_board_code
    ON config.boards (board_code) WHERE is_deleted = FALSE AND board_code IS NOT NULL;

-- ── school_types ───────────────────────────────────────────────────────────
DROP INDEX IF EXISTS config.idx_school_types_tenant;
ALTER TABLE config.school_types DROP CONSTRAINT IF EXISTS uq_school_type_name;
DROP INDEX IF EXISTS config.uq_school_type_name;

ALTER TABLE config.school_types DROP COLUMN IF EXISTS tenant_id;

CREATE UNIQUE INDEX IF NOT EXISTS uq_school_type_name
    ON config.school_types (name) WHERE is_deleted = FALSE;

-- ── school_statuses ────────────────────────────────────────────────────────
DROP INDEX IF EXISTS config.idx_school_statuses_tenant;
ALTER TABLE config.school_statuses DROP CONSTRAINT IF EXISTS uq_school_status_name;
DROP INDEX IF EXISTS config.uq_school_status_name;

ALTER TABLE config.school_statuses DROP COLUMN IF EXISTS tenant_id;

CREATE UNIQUE INDEX IF NOT EXISTS uq_school_status_name
    ON config.school_statuses (name) WHERE is_deleted = FALSE;
