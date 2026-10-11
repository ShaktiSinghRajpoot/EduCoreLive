-- ============================================================================
-- Institution categories: School / Computer-IT institute / Coaching centre.
--
-- WHY: the Create School wizard only knew schools. A computer institute had to be
-- saved as "ICSE board, Special Education School" because nothing else fitted, and
-- the school-type and ownership lists were each loaded twice (e.g. "Pre Primary"
-- next to "Pre-Primary (Nursery / KG)", "Trust" + "Society" + "Trust / Society").
--
-- WHAT:
--   1. config.institution_categories + core.school_profiles.institution_category_id
--      (every existing school becomes SCHOOL).
--   2. config.boards / school_types / ownership_types get category_codes text[]:
--      the categories a row is offered for. NULL = every category
--      (e.g. "Not affiliated / Independent").
--   3. Duplicate types are retired (soft delete) after moving any profile that used
--      them onto the row that stays; real institute options are added.
--   4. config.sp_school_dropdowns returns category_codes on those three lists and a
--      new categories cursor (last, with a default, so the running app -- which
--      passes 11 cursors -- keeps working until it is redeployed).
--
-- This file now owns config.sp_school_dropdowns (the copy in board_state.sql is
-- older -- do not re-run it). Target DB: PostgreSQL. Safe to re-run.
-- ============================================================================

-- -- 1. categories ----------------------------------------------------------
CREATE TABLE IF NOT EXISTS config.institution_categories (
    category_id    integer PRIMARY KEY,
    category_code  varchar(30)  NOT NULL UNIQUE,
    name           varchar(100) NOT NULL,
    type_label     varchar(50)  NOT NULL,   -- "School Type" / "Institute Type"
    board_label    varchar(50)  NOT NULL,   -- "Board" / "Affiliation / Certification"
    board_required boolean      NOT NULL,   -- a school must name its board; an institute need not
    display_order  integer      NOT NULL,
    is_deleted     boolean      NOT NULL DEFAULT FALSE,
    created_at     timestamptz  NOT NULL DEFAULT now()
);

INSERT INTO config.institution_categories
    (category_id, category_code, name, type_label, board_label, board_required, display_order)
VALUES
    (1, 'SCHOOL',      'School',                           'School Type',    'Board',                       TRUE,  1),
    (2, 'COMPUTER_IT', 'Computer / IT Training Institute', 'Institute Type', 'Affiliation / Certification', FALSE, 2),
    (3, 'COACHING',    'Coaching / Tuition Centre',        'Centre Type',    'Affiliation',                 FALSE, 3)
ON CONFLICT (category_id) DO UPDATE SET
    category_code  = EXCLUDED.category_code,
    name           = EXCLUDED.name,
    type_label     = EXCLUDED.type_label,
    board_label    = EXCLUDED.board_label,
    board_required = EXCLUDED.board_required,
    display_order  = EXCLUDED.display_order;

ALTER TABLE core.school_profiles
    ADD COLUMN IF NOT EXISTS institution_category_id integer NOT NULL DEFAULT 1;

DO $fk$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_school_profiles_institution_category') THEN
        ALTER TABLE core.school_profiles
            ADD CONSTRAINT fk_school_profiles_institution_category
            FOREIGN KEY (institution_category_id) REFERENCES config.institution_categories (category_id);
    END IF;
END
$fk$;

-- -- 2. which category each master row belongs to ------------------------------
ALTER TABLE config.boards          ADD COLUMN IF NOT EXISTS category_codes text[];
ALTER TABLE config.school_types    ADD COLUMN IF NOT EXISTS category_codes text[];
ALTER TABLE config.ownership_types ADD COLUMN IF NOT EXISTS category_codes text[];

-- -- 3a. boards ---------------------------------------------------------------
-- The school boards stay as they are, now marked SCHOOL only.
UPDATE config.boards SET category_codes = ARRAY['SCHOOL']
WHERE board_code IN ('CBSE', 'ICSE', 'STATE', 'IB', 'CAMBRIDGE', 'IGCSE', 'NIOS', 'MADRASAH');

-- "ICSE" alone hides that CISCE runs both ICSE (class 10) and ISC (class 12).
UPDATE config.boards SET name = 'ICSE / ISC (CISCE)' WHERE board_code = 'ICSE';

-- display_order: school boards are 1-7, institute ones follow, and the two that
-- fit every category come last.
INSERT INTO config.boards (board_code, name, requires_state, is_deleted, category_codes, display_order, created_by, created_at)
SELECT v.code, v.name, FALSE, FALSE, v.cats, v.ord, 1, now()
FROM (VALUES
    ('NIELIT',    'NIELIT (O-Level / CCC)',                       ARRAY['COMPUTER_IT'],             10),
    ('NSDC',      'Skill India / NSDC',                           ARRAY['COMPUTER_IT'],             11),
    ('MKCL',      'MKCL (MS-CIT)',                                ARRAY['COMPUTER_IT'],             12),
    ('TALLY',     'Tally Education Partner',                      ARRAY['COMPUTER_IT'],             13),
    ('OPEN_UNIV', 'University study centre (IGNOU / Open Univ.)', ARRAY['COMPUTER_IT', 'COACHING'], 14),
    ('FRANCHISE', 'Franchise / Brand partner',                    NULL::text[],                     20),
    ('NONE',      'Not affiliated / Independent',                 NULL::text[],                     21)
) AS v(code, name, cats, ord)
WHERE NOT EXISTS (SELECT 1 FROM config.boards b WHERE b.board_code = v.code);

-- -- 3b. school types ---------------------------------------------------------
-- Rows 1-6 are older copies of 7-12 ("Pre Primary" vs "Pre-Primary (Nursery / KG)").
-- Move any profile on an old row to its newer twin, then retire the old row.
UPDATE core.school_profiles sp
SET school_type_id = m.new_id
FROM (VALUES (1, 7), (2, 8), (3, 9), (4, 10), (5, 11), (6, 12)) AS m(old_id, new_id)
WHERE sp.school_type_id = m.old_id
  AND EXISTS (SELECT 1 FROM config.school_types t WHERE t.school_type_id = m.new_id AND NOT t.is_deleted);

UPDATE config.school_types
SET is_deleted = TRUE, deleted_by = 1, deleted_at = now()
WHERE school_type_id IN (1, 2, 3, 4, 5, 6)
  AND NOT is_deleted
  AND NOT EXISTS (SELECT 1 FROM core.school_profiles sp WHERE sp.school_type_id = config.school_types.school_type_id);

UPDATE config.school_types SET category_codes = ARRAY['SCHOOL']
WHERE school_type_id BETWEEN 1 AND 13;

-- school_types has no code column, so the name is the identity for re-runs.
INSERT INTO config.school_types (name, category_codes, created_by, created_at, is_deleted)
SELECT v.name, v.cats, 1, now(), FALSE
FROM (VALUES
    (1, 'Computer Training Centre (DCA / ADCA / Tally)',      ARRAY['COMPUTER_IT']),
    (2, 'IT & Software Training Institute',                   ARRAY['COMPUTER_IT']),
    (3, 'Digital Skills / Typing Centre',                     ARRAY['COMPUTER_IT']),
    (4, 'Competitive Exam Coaching (JEE / NEET / UPSC / SSC)', ARRAY['COACHING']),
    (5, 'School Tuition Centre',                              ARRAY['COACHING']),
    (6, 'Spoken English / Language Centre',                   ARRAY['COACHING']),
    (7, 'Test Prep (IELTS / PTE / GRE)',                      ARRAY['COACHING'])
) AS v(ord, name, cats)
WHERE NOT EXISTS (SELECT 1 FROM config.school_types t WHERE t.name = v.name)
ORDER BY v.ord;   -- the dropdown lists types by id, so insert in display order

-- -- 3c. ownership types ------------------------------------------------------
-- Duplicates: Private -> Private Unaided, Trust / Society -> Trust / Society.
-- "Deemed University" is a university status, not a school owner -> Private Unaided.
UPDATE core.school_profiles sp
SET ownership_type_id = m.new_id
FROM (VALUES (1, 8), (4, 9), (5, 9), (12, 8)) AS m(old_id, new_id)
WHERE sp.ownership_type_id = m.old_id;

UPDATE config.ownership_types
SET is_deleted = TRUE, deleted_by = 1, deleted_at = now()
WHERE ownership_type_id IN (1, 4, 5, 12)
  AND NOT is_deleted;

UPDATE config.ownership_types SET category_codes = ARRAY['SCHOOL']
WHERE ownership_type_id IN (2, 3, 8, 10, 11);
-- A trust or society can run an institute as well as a school.
UPDATE config.ownership_types SET category_codes = NULL WHERE ownership_type_id = 9;

-- The legal forms a computer institute or coaching centre is actually run as.
INSERT INTO config.ownership_types (tenant_id, name, category_codes, created_by, created_at, is_deleted)
SELECT 1, v.name, ARRAY['COMPUTER_IT', 'COACHING'], 1, now(), FALSE
FROM (VALUES (1, 'Sole Proprietorship'), (2, 'Partnership Firm'), (3, 'Private Limited Company'), (4, 'LLP')) AS v(ord, name)
WHERE NOT EXISTS (SELECT 1 FROM config.ownership_types o WHERE o.name = v.name AND NOT o.is_deleted)
ORDER BY v.ord;

-- -- 3d. mediums --------------------------------------------------------------
-- "Regional Language" next to Gujarati, Tamil, Bengali... says nothing; the real
-- languages are all listed. Retired only while nothing uses it.
UPDATE config.mediums
SET is_deleted = TRUE, deleted_by = 1, deleted_at = now()
WHERE medium_id = 4
  AND NOT is_deleted
  AND NOT EXISTS (SELECT 1 FROM core.school_profiles sp WHERE sp.medium_id = 4);

-- -- 4. the wizard's dropdowns ------------------------------------------------
-- Adding p_categories changes the signature; drop every overload first so the
-- CREATE below replaces instead of adding a second, ambiguous procedure.
DO $drop$
DECLARE r record;
BEGIN
    FOR r IN
        SELECT p.oid::regprocedure AS sig
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'config' AND p.proname = 'sp_school_dropdowns'
    LOOP
        EXECUTE 'DROP PROCEDURE ' || r.sig;
    END LOOP;
END
$drop$;

CREATE OR REPLACE PROCEDURE config.sp_school_dropdowns(
    INOUT p_tenants refcursor, INOUT p_statuses refcursor, INOUT p_boards refcursor,
    INOUT p_school_types refcursor, INOUT p_ownership_types refcursor, INOUT p_mediums refcursor,
    INOUT p_address_types refcursor, INOUT p_contact_types refcursor, INOUT p_academic_years refcursor,
    INOUT p_date_formats refcursor, INOUT p_time_formats refcursor,
    INOUT p_categories refcursor DEFAULT 'cur_categories'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
BEGIN
    -- Tenant 1 is the platform itself and cannot own a school (school tables check
    -- tenant_id > 1), so it is never offered as an "existing tenant".
    OPEN p_tenants FOR
    SELECT tenant_id AS id, tenant_name AS name
    FROM core.tenants
    WHERE is_active = TRUE
      AND is_deleted = FALSE
      AND tenant_id > 1
    ORDER BY tenant_name;

    OPEN p_statuses FOR
        SELECT school_status_id AS id, name
        FROM config.school_statuses
        WHERE is_deleted = FALSE
        ORDER BY name;

    -- categories: comma list of the institution categories the row is offered for;
    -- empty = every category. The wizard filters on it client-side.
    -- requires_state drives the "State Board" picker.
    OPEN p_boards FOR
        SELECT board_id AS id, name, requires_state,
               COALESCE(array_to_string(category_codes, ','), '') AS categories
        FROM config.boards
        WHERE is_deleted = FALSE
        ORDER BY display_order, name;

    OPEN p_school_types FOR
        SELECT school_type_id AS id, name,
               COALESCE(array_to_string(category_codes, ','), '') AS categories
        FROM config.school_types
        WHERE is_deleted = FALSE
        ORDER BY school_type_id;   -- creation order runs smallest class to largest

    OPEN p_ownership_types FOR
        SELECT ownership_type_id AS id, name,
               COALESCE(array_to_string(category_codes, ','), '') AS categories
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

    OPEN p_categories FOR
        SELECT category_id AS id, name, category_code, type_label, board_label, board_required
        FROM config.institution_categories
        WHERE is_deleted = FALSE
        ORDER BY display_order;
END;
$procedure$;
