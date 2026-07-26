-- ============================================================================
-- BOARD → which State Board?
--
-- PROBLEM: "State Board" is one row in config.boards, so a school could say it
-- follows a state board but never WHICH state's. MSBSHSE, UP Board and RBSE have
-- different syllabi, exam patterns, result formats and TC rules — the app cannot
-- do anything board-specific while that information is missing.
--
-- APPROACH: keep config.boards as board TYPES (7 rows, a short dropdown) and add
-- core.school_profiles.board_state_id, pointing at the config.states master that
-- geo_master.sql already seeded. The alternative — replacing "State Board" with
-- 36 per-state rows — would make a 43-item board dropdown and duplicate the state
-- list a second time in the database.
--
-- Which boards need a state is DATA (config.boards.requires_state), not a
-- hardcoded board_id. Same reasoning as school status: a board added later just
-- sets the flag, no code change. Never branch on board_id (differs per
-- environment) or name (renameable) — use board_code.
-- Re-runnable.
-- ============================================================================

ALTER TABLE config.boards
    ADD COLUMN IF NOT EXISTS board_code     varchar(30),
    ADD COLUMN IF NOT EXISTS requires_state boolean NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS display_order  integer NOT NULL DEFAULT 0;

UPDATE config.boards b
SET board_code    = p.code,
    requires_state = p.needs_state,
    display_order  = p.ord
FROM (VALUES
    ('CBSE',                             'CBSE',      FALSE, 1),
    ('ICSE',                             'ICSE',      FALSE, 2),
    ('State Board',                      'STATE',     TRUE,  3),
    ('IB (International Baccalaureate)', 'IB',        FALSE, 4),
    ('Cambridge',                        'CAMBRIDGE', FALSE, 5),
    ('Cambridge (IGCSE)',                'IGCSE',     FALSE, 6),
    ('NIOS',                             'NIOS',      FALSE, 7),
    ('Madrasah Board',                   'MADRASAH',  TRUE,  8)
) AS p(nm, code, needs_state, ord)
WHERE b.name = p.nm AND b.is_deleted = FALSE;

-- A board this migration doesn't know about (a tenant added its own): give it a
-- code so nothing has to fall back to matching on name, and leave requires_state
-- FALSE — demanding a state for an unknown board would block saves.
UPDATE config.boards
SET board_code = 'CUSTOM_' || board_id
WHERE is_deleted = FALSE AND board_code IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_board_code
    ON config.boards (board_code) WHERE is_deleted = FALSE AND board_code IS NOT NULL;

-- NOTE: "Cambridge" and "Cambridge (IGCSE)" were the same board seeded twice.
-- Since merged into "Cambridge International (CAIE / IGCSE)" — see
-- board_cambridge_merge.sql. The seed above still names both, on purpose: this
-- file must stay runnable against a database that predates that merge.

-- ── The board's state, on the school ───────────────────────────────────────
ALTER TABLE core.school_profiles
    ADD COLUMN IF NOT EXISTS board_state_id integer REFERENCES config.states(state_id);

COMMENT ON COLUMN core.school_profiles.board_state_id IS
    'Which state board, for boards with config.boards.requires_state = TRUE. NULL otherwise.';

-- Existing State Board schools have no board state recorded. Seed it from the
-- school''s own address state, which is right in the overwhelming majority of
-- cases (a school follows the board of the state it sits in) and is far better
-- than leaving it NULL. The wizard can correct the exceptions.
-- (The board join lives in WHERE, not in the FROM clause: Postgres will not let a
--  FROM-list join condition reference the UPDATE target.)
UPDATE core.school_profiles sp
SET board_state_id = a.state_id
FROM core.school_addresses a, config.boards b
WHERE sp.board_state_id IS NULL
  AND b.board_id = sp.board_id
  AND b.requires_state = TRUE
  AND a.tenant_id = sp.tenant_id
  AND a.school_id = sp.school_id
  AND a.is_primary = TRUE
  AND a.is_deleted = FALSE
  AND a.state_id IS NOT NULL;

-- Still unresolved (address state was junk, so nothing to copy):
--   SELECT sp.school_id FROM core.school_profiles sp
--   JOIN config.boards b ON b.board_id = sp.board_id AND b.requires_state
--   WHERE sp.board_state_id IS NULL;

-- ============================================================================
-- Send requires_state to the wizard so it knows when to reveal the "which
-- state's board?" picker. Only the boards cursor changes; every other list is
-- byte-identical to the original proc.
-- ============================================================================
CREATE OR REPLACE PROCEDURE config.sp_school_dropdowns(
    INOUT p_tenants refcursor, INOUT p_statuses refcursor, INOUT p_boards refcursor,
    INOUT p_school_types refcursor, INOUT p_ownership_types refcursor, INOUT p_mediums refcursor,
    INOUT p_address_types refcursor, INOUT p_contact_types refcursor, INOUT p_academic_years refcursor,
    INOUT p_date_formats refcursor, INOUT p_time_formats refcursor)
 LANGUAGE plpgsql
AS $procedure$
BEGIN
    OPEN p_tenants FOR
    SELECT tenant_id AS id, tenant_name AS name
    FROM core.tenants
    WHERE is_active = TRUE;

    OPEN p_statuses FOR
        SELECT school_status_id AS id, name
        FROM config.school_statuses
        WHERE is_deleted = FALSE
        ORDER BY name;

    -- requires_state drives the "State Board" picker (see above). Ordered by
    -- display_order so the merge/renumber in board_cambridge_merge.sql is honoured.
    OPEN p_boards FOR
        SELECT board_id AS id, name, requires_state
        FROM config.boards
        WHERE is_deleted = FALSE
        ORDER BY display_order, name;

    OPEN p_school_types FOR
        SELECT school_type_id AS id, name
        FROM config.school_types
        WHERE is_deleted = FALSE
        ORDER BY name;

    OPEN p_ownership_types FOR
        SELECT ownership_type_id AS id, name
        FROM config.ownership_types
        WHERE is_deleted = FALSE
        ORDER BY name;

    OPEN p_mediums FOR
        SELECT medium_id AS id, name
        FROM config.mediums
        WHERE is_deleted = FALSE
        ORDER BY name;

    OPEN p_address_types FOR
        SELECT address_type_id AS id, name
        FROM config.address_types
        WHERE is_deleted = FALSE
        ORDER BY name;

    OPEN p_contact_types FOR
        SELECT contact_type_id AS id, name
        FROM config.contact_types
        WHERE is_deleted = FALSE
        ORDER BY name;

    OPEN p_academic_years FOR
        SELECT academic_year_id AS id, name
        FROM config.academic_years
        WHERE is_deleted = FALSE
        ORDER BY name DESC;

    OPEN p_date_formats FOR
        SELECT date_format_id AS id, format_value AS name
        FROM config.date_formats
        WHERE is_deleted = FALSE
        ORDER BY format_value;

    OPEN p_time_formats FOR
        SELECT time_format_id AS id, format_value AS name
        FROM config.time_formats
        WHERE is_deleted = FALSE
        ORDER BY format_value;
END;
$procedure$;
