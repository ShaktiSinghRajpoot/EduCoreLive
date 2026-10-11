-- Bundle I (2026-10-11): institution categories (school / computer institute / coaching)
-- + Super Admin fixes + Basic Profile status. Needs bundle H (already live). Run with:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_11i.sql
-- Safe before the app deploy: the new proc parameter and cursor both have defaults.

-- ===== institution_categories.sql =====
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

-- ===== sp_school_manage.sql =====
-- Oct 2026 (platform_access_security_tests.sql) -- needs access_security_hardening.sql:
--   * INSERT / UPDATE / DELETE are platform-only (p_tenant_id = 1), like purge.
--     Only the SuperAdmin controller calls them; the proc no longer trusts that.
--   * Admin phone uniqueness uses core.fn_user_phone_taken (last 10 digits).
--   * An admin created from Edit is forced to reset the typed password, and any
--     super-admin password set stamps users.password_changed_at (ends sessions).
--   * School create, status change, admin creation and admin password reset write
--     admin_activity_logs on the PLATFORM tenant (1, no school) so the record
--     outlives a purge of the school.
-- Oct 2026 (superadmin_schools_tests.sql):
--   * The tenant's built-in roles are seeded on EVERY save, not only when an admin is
--     created at INSERT -- a school created without an admin got a login with no role
--     later (Edit -> add admin) and that admin could never sign in. Assigning the
--     SCHOOL_ADMIN role now fails loudly instead of silently inserting nothing.
--   * Tenant code: lower-case slug, and unique even against deleted tenants (the index
--     is, so the check was letting a raw 23505 through).
--   * Pincode, contact phone, admin phone, status and the board's state are checked
--     here as strictly as the form checks them.
--   * Editing a missing school says "School not found."; the soft-delete branch is gone
--     (the controller action was removed because it stranded schools).
-- Oct 2026 (institution_categories.sql): p_institution_category_id -- School /
--   Computer-IT institute / Coaching centre. It sits AFTER p_result on purpose: an app
--   that does not know it yet still calls the proc correctly (it defaults), so the DB
--   can be deployed before the app. Board / type / ownership must be offered for the
--   chosen category, and only a SCHOOL must name a board.
-- Adding p_country_id / p_state_id / p_district_id changes the signature, and in
-- Postgres CREATE OR REPLACE would then create a SECOND overload instead of
-- replacing — every CALL afterwards fails as ambiguous. Drop all overloads first.
DO $drop$
DECLARE r record;
BEGIN
    FOR r IN
        SELECT p.oid::regprocedure AS sig
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'core' AND p.proname = 'sp_school_manage'
    LOOP
        EXECUTE 'DROP PROCEDURE ' || r.sig;
    END LOOP;
END
$drop$;

CREATE OR REPLACE PROCEDURE core.sp_school_manage(IN p_operation character varying, IN p_tenant_id integer, IN p_action_user_id integer, IN p_tenant_mode character varying DEFAULT NULL::character varying, IN p_selected_tenant_id integer DEFAULT NULL::integer, IN p_tenant_name character varying DEFAULT NULL::character varying, IN p_tenant_code character varying DEFAULT NULL::character varying, IN p_tenant_email character varying DEFAULT NULL::character varying, IN p_tenant_phone character varying DEFAULT NULL::character varying, IN p_school_id integer DEFAULT NULL::integer, IN p_school_name character varying DEFAULT NULL::character varying, IN p_display_name character varying DEFAULT NULL::character varying, IN p_status_id integer DEFAULT NULL::integer, IN p_registration_number character varying DEFAULT NULL::character varying, IN p_affiliation_number character varying DEFAULT NULL::character varying, IN p_board_id integer DEFAULT NULL::integer, IN p_school_type_id integer DEFAULT NULL::integer, IN p_ownership_type_id integer DEFAULT NULL::integer, IN p_medium_id integer DEFAULT NULL::integer, IN p_established_year integer DEFAULT NULL::integer, IN p_website character varying DEFAULT NULL::character varying, IN p_address_type_id integer DEFAULT NULL::integer, IN p_address_line1 character varying DEFAULT NULL::character varying, IN p_address_line2 character varying DEFAULT NULL::character varying, IN p_city character varying DEFAULT NULL::character varying, IN p_district character varying DEFAULT NULL::character varying, IN p_state character varying DEFAULT NULL::character varying, IN p_pincode character varying DEFAULT NULL::character varying, IN p_contact_type_id integer DEFAULT NULL::integer, IN p_contact_name character varying DEFAULT NULL::character varying, IN p_designation character varying DEFAULT NULL::character varying, IN p_contact_email character varying DEFAULT NULL::character varying, IN p_phone character varying DEFAULT NULL::character varying, IN p_alternate_phone character varying DEFAULT NULL::character varying, IN p_academic_year_id integer DEFAULT NULL::integer, IN p_date_format_id integer DEFAULT NULL::integer, IN p_time_format_id integer DEFAULT NULL::integer, IN p_enable_sms boolean DEFAULT false, IN p_enable_email boolean DEFAULT false, IN p_enable_whatsapp boolean DEFAULT false, IN p_create_school_admin boolean DEFAULT false, IN p_admin_full_name character varying DEFAULT NULL::character varying, IN p_admin_email character varying DEFAULT NULL::character varying, IN p_admin_phone character varying DEFAULT NULL::character varying, IN p_password_hash character varying DEFAULT NULL::character varying, IN p_country_id integer DEFAULT NULL::integer, IN p_state_id integer DEFAULT NULL::integer, IN p_district_id integer DEFAULT NULL::integer, IN p_board_state_id integer DEFAULT NULL::integer, INOUT p_result refcursor DEFAULT 'school_cursor'::refcursor, IN p_institution_category_id integer DEFAULT NULL::integer)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_school_id integer;
    v_tenant_id integer;
    v_school_code character varying;
    v_user_id integer;
    v_seq integer;
    v_old_status character varying;
    v_new_status character varying;
    v_category_id integer;
    v_category_code character varying;
    v_category_name character varying;
    v_board_required boolean;
BEGIN
    IF p_operation IS NULL OR TRIM(p_operation) = '' THEN
        RAISE EXCEPTION 'Operation is required.';
    END IF;

    p_operation := UPPER(TRIM(p_operation));

    -- Creating or changing a school -- including its status, which is the login
    -- gate -- is a platform action. GET / LIST stay readable by the school itself.
    IF p_operation IN ('INSERT', 'UPDATE', 'DELETE') AND COALESCE(p_tenant_id, 0) <> 1 THEN
        RAISE EXCEPTION 'Only the platform super admin can create or change a school.';
    END IF;

    /*
        LIST
    */
    IF p_operation = 'LIST' THEN
        OPEN p_result FOR
        SELECT
            s.school_id,
            s.school_code,
            s.school_name,
            s.display_name,
            t.tenant_name,
            st.name AS status_name,
            b.name AS board_name,
            sty.name AS school_type_name,
            a.city,
            a.state,
            c.contact_name,
            c.phone,
            s.created_at
        FROM core.schools s
        INNER JOIN core.tenants t
            ON t.tenant_id = s.tenant_id
           AND t.is_deleted = FALSE
        LEFT JOIN core.school_profiles sp
            ON sp.tenant_id = s.tenant_id
           AND sp.school_id = s.school_id
           AND sp.is_deleted = FALSE
           AND sp.is_active = TRUE
        LEFT JOIN config.school_statuses st
            ON st.school_status_id = s.status_id
           AND st.is_deleted = FALSE
        LEFT JOIN config.boards b
            ON b.board_id = sp.board_id
           AND b.is_deleted = FALSE
        LEFT JOIN config.school_types sty
            ON sty.school_type_id = sp.school_type_id
           AND sty.is_deleted = FALSE
        LEFT JOIN core.school_addresses a
            ON a.tenant_id = s.tenant_id
           AND a.school_id = s.school_id
           AND a.is_primary = TRUE
           AND a.is_active = TRUE
           AND a.is_deleted = FALSE
        LEFT JOIN core.school_contacts c
            ON c.tenant_id = s.tenant_id
           AND c.school_id = s.school_id
           AND c.is_primary = TRUE
           AND c.is_active = TRUE
           AND c.is_deleted = FALSE
        WHERE s.is_active = TRUE
          AND s.is_deleted = FALSE
          AND (
                p_tenant_id = 1
                OR s.tenant_id = p_tenant_id
              )
        ORDER BY s.school_id DESC;

        RETURN;
    END IF;

    /*
        GET BY ID
    */
    IF p_operation = 'GET' THEN
        IF p_school_id IS NULL OR p_school_id <= 0 THEN
            RAISE EXCEPTION 'School id is required.';
        END IF;

        OPEN p_result FOR
        SELECT
            s.tenant_id,
            t.tenant_name,
            t.tenant_code,
            s.school_id,
            s.school_code,
            s.school_name,
            s.display_name,
            s.status_id,

            sp.registration_number,
            sp.affiliation_number,
            sp.board_id,
            sp.board_state_id,
            sp.institution_category_id,
            sp.school_type_id,
            sp.ownership_type_id,
            sp.medium_id,
            sp.established_year,
            sp.website,
            sp.logo_url,
            sp.header_image_url,
            sp.description,

            a.address_type_id,
            a.address_line1,
            a.address_line2,
            a.city,
            a.district,
            a.state,
            a.pincode,
            a.country_id,
            a.state_id,
            a.district_id,

            c.contact_type_id,
            c.contact_name,
            c.designation,
            c.email,
            c.phone,
            c.alternate_phone,

            ss.academic_year_id,
            ss.date_format_id,
            ss.time_format_id,
            COALESCE(ss.enable_sms, FALSE) AS enable_sms,
            COALESCE(ss.enable_email, FALSE) AS enable_email,
            COALESCE(ss.enable_whatsapp, FALSE) AS enable_whatsapp,

            adm.user_id   AS admin_user_id,
            adm.full_name AS admin_full_name,
            adm.email     AS admin_email,
            adm.phone     AS admin_phone
        FROM core.schools s
        LEFT JOIN core.tenants t
            ON t.tenant_id = s.tenant_id
           AND t.is_deleted = FALSE
        LEFT JOIN core.school_profiles sp
            ON sp.tenant_id = s.tenant_id
           AND sp.school_id = s.school_id
           AND sp.is_deleted = FALSE
        LEFT JOIN core.school_addresses a
            ON a.tenant_id = s.tenant_id
           AND a.school_id = s.school_id
           AND a.is_primary = TRUE
           AND a.is_active = TRUE
           AND a.is_deleted = FALSE
        LEFT JOIN core.school_contacts c
            ON c.tenant_id = s.tenant_id
           AND c.school_id = s.school_id
           AND c.is_primary = TRUE
           AND c.is_active = TRUE
           AND c.is_deleted = FALSE
        LEFT JOIN core.school_settings ss
            ON ss.tenant_id = s.tenant_id
           AND ss.school_id = s.school_id
           AND ss.is_deleted = FALSE
        -- primary SCHOOL_ADMIN for this school (for edit pre-fill)
        LEFT JOIN LATERAL (
            SELECT u.user_id, u.email, up.full_name, up.phone
            FROM core.user_roles ur
            JOIN config.roles r
                ON r.role_id = ur.role_id
               AND r.tenant_id = s.tenant_id
               AND r.role_code = 'SCHOOL_ADMIN'
            JOIN core.users u
                ON u.user_id = ur.user_id
               AND u.is_active = TRUE
               AND u.is_deleted = FALSE
            LEFT JOIN core.user_profiles up
                ON up.user_id = u.user_id
               AND up.tenant_id = u.tenant_id
               AND up.is_deleted = FALSE
            WHERE ur.tenant_id = s.tenant_id
              AND ur.school_id = s.school_id
              AND ur.is_active = TRUE
              AND ur.is_deleted = FALSE
            ORDER BY ur.is_primary DESC, u.user_id
            LIMIT 1
        ) adm ON TRUE
        WHERE s.school_id = p_school_id
          AND (p_tenant_id = 1 OR s.tenant_id = p_tenant_id)
          AND s.is_active = TRUE
          AND s.is_deleted = FALSE;

        RETURN;
    END IF;

    -- DELETE (soft delete) was removed: it hid the school from the list AND from Edit,
    -- so it could never be reopened or purged. Close it (status) or purge it instead.

    /*
        INSERT / UPDATE VALIDATION
    */
    IF p_operation NOT IN ('INSERT', 'UPDATE') THEN
        RAISE EXCEPTION 'Invalid operation: %', p_operation;
    END IF;

    IF p_school_name IS NULL OR TRIM(p_school_name) = '' THEN
        RAISE EXCEPTION 'School name is required.';
    END IF;

    IF p_status_id IS NULL OR p_status_id <= 0 THEN
        RAISE EXCEPTION 'Status is required.';
    END IF;

    -- core.schools.status_id has no foreign key; an unknown id would block every login
    -- with an empty message.
    IF NOT EXISTS (SELECT 1 FROM config.school_statuses
                   WHERE school_status_id = p_status_id AND is_deleted = FALSE) THEN
        RAISE EXCEPTION 'Please select a valid status.';
    END IF;

    IF p_address_line1 IS NULL OR TRIM(p_address_line1) = '' THEN
        RAISE EXCEPTION 'Address line 1 is required.';
    END IF;

    IF p_city IS NULL OR TRIM(p_city) = '' THEN
        RAISE EXCEPTION 'City is required.';
    END IF;

    IF p_state IS NULL OR TRIM(p_state) = '' THEN
        RAISE EXCEPTION 'State is required.';
    END IF;

    IF p_pincode IS NULL OR TRIM(p_pincode) = '' THEN
        RAISE EXCEPTION 'Pincode is required.';
    END IF;

    IF TRIM(p_pincode) !~ '^[1-9][0-9]{5}$' THEN
        RAISE EXCEPTION 'Pincode must be 6 digits and cannot start with 0.';
    END IF;

    IF p_contact_name IS NULL OR TRIM(p_contact_name) = '' THEN
        RAISE EXCEPTION 'Primary contact person is required.';
    END IF;

    -- Boards flagged requires_state (State Board, Madrasah Board) are meaningless
    -- without knowing WHICH state's board — MSBSHSE and UP Board share nothing but
    -- the label. Driven by the flag, not a hardcoded board_id.
    IF p_board_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM config.boards
                   WHERE board_id = p_board_id AND requires_state = TRUE AND is_deleted = FALSE)
       AND (p_board_state_id IS NULL OR p_board_state_id <= 0) THEN
        RAISE EXCEPTION 'Please select which state''s board this school follows.';
    END IF;

    -- Without the address state id the mismatch check below cannot run, and a UP Board
    -- school could be saved in Bihar.
    IF p_board_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM config.boards
                   WHERE board_id = p_board_id AND requires_state = TRUE AND is_deleted = FALSE)
       AND (p_state_id IS NULL OR p_state_id <= 0) THEN
        RAISE EXCEPTION 'Please select the state from the list.';
    END IF;

    -- A State Board is granted by one state's education department, so a UP Board school
    -- cannot be located in Bihar. Rejected rather than silently corrected: here the super
    -- admin chose both values, so they should see which one is wrong. (On the school's own
    -- Basic Profile the field is locked instead — nothing to correct there.)
    -- This is the hole SCH14 came through.
    IF p_board_id IS NOT NULL
       AND p_board_state_id IS NOT NULL AND p_board_state_id > 0
       AND p_state_id IS NOT NULL AND p_state_id > 0
       AND p_state_id <> p_board_state_id
       AND EXISTS (SELECT 1 FROM config.boards
                   WHERE board_id = p_board_id AND requires_state = TRUE AND is_deleted = FALSE) THEN
        RAISE EXCEPTION 'A % school must be located in % — the address state does not match the board.',
            (SELECT name FROM config.boards WHERE board_id = p_board_id),
            (SELECT name FROM config.states WHERE state_id = p_board_state_id);
    END IF;

    -- Mobile or landline with STD code, stored as digits -- the same rule as the
    -- school's own Basic Profile (core.fn_school_phone_clean).
    p_phone := core.fn_school_phone_clean(p_phone, 'Phone');
    IF p_phone IS NULL THEN
        RAISE EXCEPTION 'Phone is required.';
    END IF;

    -- A login phone is a mobile number: 10 digits starting 6-9, like the form asks.
    IF p_admin_phone IS NOT NULL AND TRIM(p_admin_phone) <> ''
       AND TRIM(p_admin_phone) !~ '^[6-9][0-9]{9}$' THEN
        RAISE EXCEPTION 'Admin phone must be a 10-digit mobile number.';
    END IF;

    -- Institution category. Not sent (an app older than this parameter, or a direct
    -- call): an existing school keeps its own, a new one is a SCHOOL.
    v_category_id := p_institution_category_id;
    IF v_category_id IS NULL AND p_operation = 'UPDATE' THEN
        SELECT institution_category_id INTO v_category_id
        FROM core.school_profiles
        WHERE school_id = p_school_id AND is_deleted = FALSE;
    END IF;
    v_category_id := COALESCE(v_category_id, 1);

    SELECT category_code, name, board_required
      INTO v_category_code, v_category_name, v_board_required
    FROM config.institution_categories
    WHERE category_id = v_category_id AND is_deleted = FALSE;
    IF v_category_code IS NULL THEN
        RAISE EXCEPTION 'Please select a valid institution category.';
    END IF;

    IF v_board_required AND p_board_id IS NULL THEN
        RAISE EXCEPTION 'Board is required.';
    END IF;

    -- Each list row says which categories it is offered for (category_codes, NULL = all),
    -- so a coaching centre cannot be saved with a CBSE board or a "K-12 School" type.
    IF p_board_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM config.boards
        WHERE board_id = p_board_id AND is_deleted = FALSE
          AND (category_codes IS NULL OR v_category_code = ANY (category_codes))) THEN
        RAISE EXCEPTION 'The selected board is not available for a %.', v_category_name;
    END IF;

    IF p_school_type_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM config.school_types
        WHERE school_type_id = p_school_type_id AND is_deleted = FALSE
          AND (category_codes IS NULL OR v_category_code = ANY (category_codes))) THEN
        RAISE EXCEPTION 'The selected type is not available for a %.', v_category_name;
    END IF;

    IF p_ownership_type_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM config.ownership_types
        WHERE ownership_type_id = p_ownership_type_id AND is_deleted = FALSE
          AND (category_codes IS NULL OR v_category_code = ANY (category_codes))) THEN
        RAISE EXCEPTION 'The selected ownership is not available for a %.', v_category_name;
    END IF;

    /*
        TENANT RESOLUTION
    */
    IF p_operation = 'INSERT' THEN
        IF p_tenant_mode = 'existing' THEN
            IF p_selected_tenant_id IS NULL OR p_selected_tenant_id <= 0 THEN
                RAISE EXCEPTION 'Please select tenant.';
            END IF;

            -- Tenant 1 is the platform; a school there fails chk_school_profiles_scope
            -- with a raw constraint error, so say it plainly instead.
            IF p_selected_tenant_id = 1 THEN
                RAISE EXCEPTION 'The platform tenant cannot own a school. Choose another tenant or create a new one.';
            END IF;

            IF NOT EXISTS (
                SELECT 1
                FROM core.tenants
                WHERE tenant_id = p_selected_tenant_id
                  AND is_active = TRUE
                  AND is_deleted = FALSE
            ) THEN
                RAISE EXCEPTION 'Selected tenant does not exist.';
            END IF;

            v_tenant_id := p_selected_tenant_id;

        ELSIF p_tenant_mode = 'new' THEN
            IF p_tenant_name IS NULL OR TRIM(p_tenant_name) = '' THEN
                RAISE EXCEPTION 'Tenant name is required.';
            END IF;

            IF p_tenant_code IS NULL OR TRIM(p_tenant_code) = '' THEN
                RAISE EXCEPTION 'Tenant code is required.';
            END IF;

            -- A short slug: lower-case letters, digits and hyphens (e.g. "dps-group").
            IF LOWER(TRIM(p_tenant_code)) !~ '^[a-z0-9][a-z0-9-]{1,49}$' THEN
                RAISE EXCEPTION 'Tenant code may use only letters, digits and hyphens (2-50 characters).';
            END IF;

            -- No is_deleted filter: the unique index covers deleted tenants too, so a
            -- deleted tenant's code is still taken.
            IF EXISTS (
                SELECT 1
                FROM core.tenants
                WHERE LOWER(TRIM(tenant_code)) = LOWER(TRIM(p_tenant_code))
            ) THEN
                RAISE EXCEPTION 'Tenant code already exists.';
            END IF;

            IF p_tenant_email IS NOT NULL
               AND TRIM(p_tenant_email) <> ''
               AND EXISTS (
                    SELECT 1
                    FROM core.tenants
                    WHERE LOWER(TRIM(contact_email)) = LOWER(TRIM(p_tenant_email))
                      AND is_deleted = FALSE
               ) THEN
                RAISE EXCEPTION 'Tenant email already exists.';
            END IF;

            INSERT INTO core.tenants
            (
                tenant_name,
                tenant_code,
                contact_email,
                contact_phone,
                is_active,
                created_by,
                created_at
            )
            VALUES
            (
                TRIM(p_tenant_name),
                LOWER(TRIM(p_tenant_code)),
                NULLIF(TRIM(p_tenant_email), ''),
                NULLIF(TRIM(p_tenant_phone), ''),
                TRUE,
                p_action_user_id,
                NOW()
            )
            RETURNING tenant_id INTO v_tenant_id;

        ELSE
            RAISE EXCEPTION 'Tenant option is required.';
        END IF;
    ELSE
        -- UPDATE: the platform super admin (tenant 1) may edit a school on any tenant,
        -- so resolve the school's own tenant; a school-scoped user stays on their tenant.
        IF p_tenant_id = 1 THEN
            SELECT tenant_id INTO v_tenant_id
            FROM core.schools
            WHERE school_id = p_school_id
              AND is_deleted = FALSE;
        ELSE
            v_tenant_id := p_tenant_id;
        END IF;
    END IF;

    IF v_tenant_id IS NULL OR v_tenant_id <= 0 THEN
        IF p_operation = 'UPDATE' THEN
            RAISE EXCEPTION 'School not found.';
        END IF;
        RAISE EXCEPTION 'Tenant id is required.';
    END IF;

    /*
        SCHOOL DUPLICATE VALIDATION
    */
    IF EXISTS (
        SELECT 1
        FROM core.schools
        WHERE tenant_id = v_tenant_id
          AND LOWER(TRIM(school_name)) = LOWER(TRIM(p_school_name))
          AND is_deleted = FALSE
          AND (p_operation = 'INSERT' OR school_id <> p_school_id)
    ) THEN
        RAISE EXCEPTION 'School name already exists for this tenant.';
    END IF;

    IF p_registration_number IS NOT NULL
       AND TRIM(p_registration_number) <> ''
       AND EXISTS (
            SELECT 1
            FROM core.school_profiles sp
            WHERE sp.tenant_id = v_tenant_id
              AND LOWER(TRIM(sp.registration_number)) = LOWER(TRIM(p_registration_number))
              AND sp.is_deleted = FALSE
              AND (p_operation = 'INSERT' OR sp.school_id <> p_school_id)
       ) THEN
        RAISE EXCEPTION 'Registration number already exists for this tenant.';
    END IF;

    IF p_affiliation_number IS NOT NULL
       AND TRIM(p_affiliation_number) <> ''
       AND EXISTS (
            SELECT 1
            FROM core.school_profiles sp
            WHERE sp.tenant_id = v_tenant_id
              AND LOWER(TRIM(sp.affiliation_number)) = LOWER(TRIM(p_affiliation_number))
              AND sp.is_deleted = FALSE
              AND (p_operation = 'INSERT' OR sp.school_id <> p_school_id)
       ) THEN
        RAISE EXCEPTION 'Affiliation number already exists for this tenant.';
    END IF;

    /*
        ADMIN VALIDATION
    */
    IF COALESCE(p_create_school_admin, FALSE) = TRUE THEN
        IF p_admin_full_name IS NULL OR TRIM(p_admin_full_name) = '' THEN
            RAISE EXCEPTION 'Admin full name is required.';
        END IF;

        IF p_admin_email IS NULL OR TRIM(p_admin_email) = '' THEN
            RAISE EXCEPTION 'Admin email is required.';
        END IF;

        -- One shared guard (see Database/user_email_unique.sql) instead of an
        -- inline EXISTS. The inline version filtered only is_active, so an email
        -- held by a DEACTIVATED user slipped past it and then blew up on the
        -- unique index with a raw Postgres error instead of this message.
        IF p_operation = 'INSERT' AND core.fn_user_email_taken(p_admin_email) THEN
            RAISE EXCEPTION 'This email is already registered to another user.';
        END IF;

        -- Phone must be unique across active login users (mirrors the email rule).
        IF p_operation = 'INSERT'
           AND p_admin_phone IS NOT NULL AND TRIM(p_admin_phone) <> ''
           AND core.fn_user_phone_taken(p_admin_phone) THEN
            RAISE EXCEPTION 'Admin phone already exists.';
        END IF;
    END IF;

    /*
        INSERT / UPDATE SCHOOL MASTER
        Only basic school fields should be stored in core.schools.
    */
    IF p_operation = 'INSERT' THEN
        -- Running sequence: SCH1, SCH2, SCH3, ... (see Database/school_code_sequence.sql)
        --
        -- WHY a counter row and not a sequence: nextval() does not roll back, so a
        -- failed save would burn a number and leave a hole. This UPDATE rolls back
        -- with the transaction, keeping the numbering gap-free, and its row lock
        -- makes concurrent creates queue instead of racing to the same number.
        --
        -- The old 'SCH' || YYYYMMDDHH24MISS was only unique to the second, so two
        -- schools created in the same second on one tenant collided on
        -- uq_school_code (tenant_id, school_code) and the second save failed.
        UPDATE core.school_code_counters
        SET last_seq   = last_seq + 1,
            updated_at = NOW()
        WHERE counter_key = 'GLOBAL'
        RETURNING last_seq INTO v_seq;

        IF v_seq IS NULL THEN
            RAISE EXCEPTION 'School code counter is missing. Run Database/school_code_sequence.sql.';
        END IF;

        v_school_code := 'SCH' || v_seq;

        INSERT INTO core.schools
        (
            tenant_id,
            school_code,
            school_name,
            display_name,
            status_id,
            is_active,
            created_by,
            created_at
        )
        VALUES
        (
            v_tenant_id,
            v_school_code,
            TRIM(p_school_name),
            NULLIF(TRIM(p_display_name), ''),
            p_status_id,
            TRUE,
            p_action_user_id,
            NOW()
        )
        RETURNING school_id INTO v_school_id;

        PERFORM core.fn_admin_audit(1, NULL, p_action_user_id, 'SCHOOL_CREATE', 'SuperAdmin/Schools',
            'core.schools', v_school_id,
            format('School %s (%s) created on tenant %s', TRIM(p_school_name), v_school_code, v_tenant_id));

    ELSE
        IF p_school_id IS NULL OR p_school_id <= 0 THEN
            RAISE EXCEPTION 'School id is required.';
        END IF;

        IF NOT EXISTS (
            SELECT 1
            FROM core.schools
            WHERE school_id = p_school_id
              AND tenant_id = v_tenant_id
              AND is_active = TRUE
              AND is_deleted = FALSE
        ) THEN
            RAISE EXCEPTION 'School not found.';
        END IF;

        v_school_id := p_school_id;

        SELECT st.name INTO v_old_status
        FROM core.schools s LEFT JOIN config.school_statuses st ON st.school_status_id = s.status_id
        WHERE s.school_id = v_school_id;

        UPDATE core.schools
        SET
            school_name = TRIM(p_school_name),
            display_name = NULLIF(TRIM(p_display_name), ''),
            status_id = p_status_id,
            updated_by = p_action_user_id,
            updated_at = NOW()
        WHERE school_id = v_school_id
          AND tenant_id = v_tenant_id;

        SELECT name INTO v_new_status FROM config.school_statuses WHERE school_status_id = p_status_id;
        IF v_old_status IS DISTINCT FROM v_new_status THEN
            PERFORM core.fn_admin_audit(1, NULL, p_action_user_id, 'SCHOOL_STATUS', 'SuperAdmin/Schools',
                'core.schools', v_school_id,
                format('School %s (tenant %s) status: %s -> %s', v_school_id, v_tenant_id,
                       COALESCE(v_old_status, '?'), COALESCE(v_new_status, '?')));
        END IF;
    END IF;

    /*
        SCHOOL PROFILE UPSERT
    */
    INSERT INTO core.school_profiles
    (
        tenant_id,
        school_id,
        registration_number,
        affiliation_number,
        board_id,
        board_state_id,
        institution_category_id,
        school_type_id,
        ownership_type_id,
        medium_id,
        established_year,
        website,
        is_active,
        created_by,
        created_at
    )
    VALUES
    (
        v_tenant_id,
        v_school_id,
        NULLIF(TRIM(p_registration_number), ''),
        NULLIF(TRIM(p_affiliation_number), ''),
        p_board_id,
        -- Cleared when the chosen board doesn't need one, so switching State Board
        -- -> CBSE can't leave a stale state behind.
        CASE WHEN EXISTS (SELECT 1 FROM config.boards
                          WHERE board_id = p_board_id AND requires_state = TRUE AND is_deleted = FALSE)
             THEN p_board_state_id ELSE NULL END,
        v_category_id,
        p_school_type_id,
        p_ownership_type_id,
        p_medium_id,
        p_established_year,
        NULLIF(TRIM(p_website), ''),
        TRUE,
        p_action_user_id,
        NOW()
    )
    ON CONFLICT (tenant_id, school_id)
    DO UPDATE SET
        registration_number = EXCLUDED.registration_number,
        affiliation_number = EXCLUDED.affiliation_number,
        board_id = EXCLUDED.board_id,
        board_state_id = EXCLUDED.board_state_id,
        institution_category_id = EXCLUDED.institution_category_id,
        school_type_id = EXCLUDED.school_type_id,
        ownership_type_id = EXCLUDED.ownership_type_id,
        medium_id = EXCLUDED.medium_id,
        established_year = EXCLUDED.established_year,
        website = EXCLUDED.website,
        is_active = TRUE,
        is_deleted = FALSE,
        updated_by = p_action_user_id,
        updated_at = NOW();

    /*
        ADDRESS UPSERT
    */
    INSERT INTO core.school_addresses
    (
        tenant_id,
        school_id,
        address_type_id,
        address_line1,
        address_line2,
        city,
        district,
        state,
        pincode,
        country_id,
        state_id,
        district_id,
        is_primary,
        is_active,
        created_by,
        created_at
    )
    VALUES
    (
        v_tenant_id,
        v_school_id,
        COALESCE(p_address_type_id, 1),
        TRIM(p_address_line1),
        NULLIF(TRIM(p_address_line2), ''),
        TRIM(p_city),
        NULLIF(TRIM(p_district), ''),
        TRIM(p_state),
        TRIM(p_pincode),
        p_country_id,
        p_state_id,
        p_district_id,
        TRUE,
        TRUE,
        p_action_user_id,
        NOW()
    )
    ON CONFLICT (tenant_id, school_id, address_type_id)
    DO UPDATE SET
        address_line1 = EXCLUDED.address_line1,
        address_line2 = EXCLUDED.address_line2,
        city = EXCLUDED.city,
        district = EXCLUDED.district,
        state = EXCLUDED.state,
        pincode = EXCLUDED.pincode,
        country_id = EXCLUDED.country_id,
        state_id = EXCLUDED.state_id,
        district_id = EXCLUDED.district_id,
        is_primary = TRUE,
        is_active = TRUE,
        is_deleted = FALSE,
        updated_by = p_action_user_id,
        updated_at = NOW();

    /*
        CONTACT UPSERT
    */
    INSERT INTO core.school_contacts
    (
        tenant_id,
        school_id,
        contact_type_id,
        contact_name,
        designation,
        email,
        phone,
        alternate_phone,
        is_primary,
        is_active,
        created_by,
        created_at
    )
    VALUES
    (
        v_tenant_id,
        v_school_id,
        COALESCE(p_contact_type_id, 1),
        TRIM(p_contact_name),
        NULLIF(TRIM(p_designation), ''),
        NULLIF(TRIM(p_contact_email), ''),
        TRIM(p_phone),
        NULLIF(TRIM(p_alternate_phone), ''),
        TRUE,
        TRUE,
        p_action_user_id,
        NOW()
    )
    ON CONFLICT (tenant_id, school_id, contact_type_id)
    DO UPDATE SET
        contact_name = EXCLUDED.contact_name,
        designation = EXCLUDED.designation,
        email = EXCLUDED.email,
        phone = EXCLUDED.phone,
        alternate_phone = EXCLUDED.alternate_phone,
        is_primary = TRUE,
        is_active = TRUE,
        is_deleted = FALSE,
        updated_by = p_action_user_id,
        updated_at = NOW();

    /*
        SETTINGS UPSERT
    */
    INSERT INTO core.school_settings
    (
        tenant_id,
        school_id,
        academic_year_id,
        date_format_id,
        time_format_id,
        enable_sms,
        enable_email,
        enable_whatsapp,
        is_active,
        created_by,
        created_at
    )
    VALUES
    (
        v_tenant_id,
        v_school_id,
        p_academic_year_id,
        p_date_format_id,
        p_time_format_id,
        COALESCE(p_enable_sms, FALSE),
        COALESCE(p_enable_email, FALSE),
        COALESCE(p_enable_whatsapp, FALSE),
        TRUE,
        p_action_user_id,
        NOW()
    )
    ON CONFLICT (tenant_id, school_id)
    DO UPDATE SET
        academic_year_id = EXCLUDED.academic_year_id,
        date_format_id = EXCLUDED.date_format_id,
        time_format_id = EXCLUDED.time_format_id,
        enable_sms = EXCLUDED.enable_sms,
        enable_email = EXCLUDED.enable_email,
        enable_whatsapp = EXCLUDED.enable_whatsapp,
        is_active = TRUE,
        is_deleted = FALSE,
        updated_by = p_action_user_id,
        updated_at = NOW();

    -- Roles are tenant-scoped (config.roles has a row per tenant). Seed the standard
    -- staff roles for this tenant if they are missing -- on every save, not only when
    -- an admin is created at INSERT. Otherwise a school created without an admin has
    -- no SCHOOL_ADMIN role, so the admin added later from Edit gets a login with no
    -- role and can never sign in, and the built-in role defaults below find nothing.
    -- role_id is an identity column, so it is left to auto-generate.
    INSERT INTO config.roles
    (
        tenant_id, role_code, role_name, is_active, is_deleted, created_by, created_at
    )
    SELECT
        v_tenant_id, x.code, x.name, TRUE, FALSE, p_action_user_id, NOW()
    FROM (VALUES
        ('SCHOOL_ADMIN', 'School Admin'),
        ('TEACHER',      'Teacher'),
        ('ACCOUNTANT',   'Accountant'),
        ('RECEPTIONIST', 'Receptionist')
    ) AS x(code, name)
    WHERE NOT EXISTS (
        SELECT 1 FROM config.roles r
        WHERE r.tenant_id = v_tenant_id
          AND r.role_code = x.code
    );

    /*
        CREATE SCHOOL ADMIN
    */
    IF p_operation = 'INSERT' AND COALESCE(p_create_school_admin, FALSE) = TRUE THEN
        INSERT INTO core.users
        (
            tenant_id,
            school_id,
            email,
            password_hash,
            --role_id,
            is_active,
            must_change_password,
            created_by,
            created_at
        )
        VALUES
        (
            v_tenant_id,
            v_school_id,
            LOWER(TRIM(p_admin_email)),
            p_password_hash,
           -- 3,
            TRUE,
            TRUE,   -- force the emailed temp-password admin to reset on first login
            p_action_user_id,
            NOW()
        )
        RETURNING user_id INTO v_user_id;

        INSERT INTO core.user_profiles
        (
            tenant_id,
            user_id,
            school_id,
            full_name,
            phone,
            designation,
            is_active,
            created_by,
            created_at
        )
        VALUES
        (
            v_tenant_id,
            v_user_id,
            v_school_id,
            TRIM(p_admin_full_name),
            NULLIF(TRIM(p_admin_phone), ''),
            'School Admin',
            TRUE,
            p_action_user_id,
            NOW()
        );

        -- Assign the SCHOOL_ADMIN role for THIS tenant by code (not a hardcoded id).
        INSERT INTO core.user_roles
        (
            tenant_id,
            user_id,
            role_id,
            school_id,
            is_primary,
            is_active,
            created_by,
            created_at
        )
        SELECT
            v_tenant_id,
            v_user_id,
            r.role_id,
            v_school_id,
            TRUE,
            TRUE,
            p_action_user_id,
            NOW()
        FROM config.roles r
        WHERE r.tenant_id = v_tenant_id
          AND r.role_code = 'SCHOOL_ADMIN'
          AND r.is_active = TRUE
          AND r.is_deleted = FALSE
        ON CONFLICT (tenant_id, user_id, role_id) DO NOTHING;

        -- A brand-new user cannot conflict, so nothing inserted means the tenant's
        -- SCHOOL_ADMIN role is missing or switched off: stop rather than leave a login
        -- that can never sign in.
        IF NOT FOUND THEN
            RAISE EXCEPTION 'This tenant has no active School Admin role, so the admin could not be created.';
        END IF;

        PERFORM core.fn_admin_audit(1, NULL, p_action_user_id, 'SCHOOL_ADMIN_CREATE', 'SuperAdmin/Schools',
            'core.users', v_user_id,
            format('School admin %s created for school %s (tenant %s)', LOWER(TRIM(p_admin_email)), v_school_id, v_tenant_id));
    END IF;

    -- A new school's built-in roles (Teacher, Accountant, Receptionist) start with
    -- sensible permissions instead of none (builtin_role_defaults.sql).
    IF p_operation = 'INSERT' THEN
        PERFORM config.fn_apply_builtin_role_defaults(v_tenant_id, v_school_id, p_action_user_id);
    END IF;

    /*
        UPDATE SCHOOL ADMIN (edit existing; create one if none exists yet)
    */
    IF p_operation = 'UPDATE'
       AND COALESCE(p_create_school_admin, FALSE) = TRUE
       AND p_admin_email IS NOT NULL AND TRIM(p_admin_email) <> '' THEN

        SELECT u.user_id INTO v_user_id
        FROM core.user_roles ur
        JOIN config.roles r
            ON r.role_id = ur.role_id
           AND r.tenant_id = v_tenant_id
           AND r.role_code = 'SCHOOL_ADMIN'
        JOIN core.users u
            ON u.user_id = ur.user_id
           AND u.is_active = TRUE
           AND u.is_deleted = FALSE
        WHERE ur.tenant_id = v_tenant_id
          AND ur.school_id = v_school_id
          AND ur.is_active = TRUE
          AND ur.is_deleted = FALSE
        ORDER BY ur.is_primary DESC, u.user_id
        LIMIT 1;

        -- Same guard, excluding the admin being edited so they don't clash with themselves.
        IF core.fn_user_email_taken(p_admin_email, v_user_id) THEN
            RAISE EXCEPTION 'This email is already registered to another user.';
        END IF;

        -- Phone must stay unique across active login users (excluding the admin being edited).
        IF p_admin_phone IS NOT NULL AND TRIM(p_admin_phone) <> ''
           AND core.fn_user_phone_taken(p_admin_phone, v_user_id) THEN
            RAISE EXCEPTION 'Admin phone already exists.';
        END IF;

        IF v_user_id IS NOT NULL THEN
            -- Update existing admin. Password is changed only when a new hash is supplied.
            UPDATE core.users
            SET email = LOWER(TRIM(p_admin_email)),
                password_hash = COALESCE(NULLIF(TRIM(p_password_hash), ''), password_hash),
                -- A super-admin reset must be single-use: the admin is forced to pick
                -- their own password at next login, so the person who reset it does not
                -- keep working knowledge of a live credential. INSERT already does this
                -- for brand-new admins; the reset path was missing it.
                -- CASE, not TRUE: this same UPDATE runs for a plain name/email edit with
                -- no password, and that must NOT lock the admin out of their own session.
                must_change_password = CASE
                    WHEN NULLIF(TRIM(p_password_hash), '') IS NOT NULL THEN TRUE
                    ELSE must_change_password
                END,
                -- A new password ends the admin's open sessions (cookie stamp check).
                password_changed_at = CASE
                    WHEN NULLIF(TRIM(p_password_hash), '') IS NOT NULL THEN NOW()
                    ELSE password_changed_at
                END,
                updated_by = p_action_user_id,
                updated_at = NOW()
            WHERE user_id = v_user_id;

            IF NULLIF(TRIM(p_password_hash), '') IS NOT NULL THEN
                PERFORM core.fn_admin_audit(1, NULL, p_action_user_id, 'PASSWORD_RESET_BY_ADMIN', 'SuperAdmin/Schools',
                    'core.users', v_user_id,
                    format('School admin password reset for school %s (tenant %s)', v_school_id, v_tenant_id));
            END IF;

            UPDATE core.user_profiles
            SET full_name = COALESCE(NULLIF(TRIM(p_admin_full_name), ''), full_name),
                phone = NULLIF(TRIM(p_admin_phone), ''),
                updated_by = p_action_user_id,
                updated_at = NOW()
            WHERE user_id = v_user_id
              AND tenant_id = v_tenant_id;

        ELSIF p_password_hash IS NOT NULL AND TRIM(p_password_hash) <> '' THEN
            -- No admin yet: create one (only when a password was supplied).
            -- must_change_password = TRUE, exactly like INSERT: the super admin typed
            -- this password, so it must be single-use.
            INSERT INTO core.users
                (tenant_id, school_id, email, password_hash, must_change_password, is_active, created_by, created_at)
            VALUES
                (v_tenant_id, v_school_id, LOWER(TRIM(p_admin_email)), p_password_hash, TRUE, TRUE, p_action_user_id, NOW())
            RETURNING user_id INTO v_user_id;

            PERFORM core.fn_admin_audit(1, NULL, p_action_user_id, 'SCHOOL_ADMIN_CREATE', 'SuperAdmin/Schools',
                'core.users', v_user_id,
                format('School admin %s created for school %s (tenant %s)', LOWER(TRIM(p_admin_email)), v_school_id, v_tenant_id));

            INSERT INTO core.user_profiles
                (tenant_id, user_id, school_id, full_name, phone, designation, is_active, created_by, created_at)
            VALUES
                (v_tenant_id, v_user_id, v_school_id, TRIM(p_admin_full_name), NULLIF(TRIM(p_admin_phone), ''), 'School Admin', TRUE, p_action_user_id, NOW());

            INSERT INTO core.user_roles
                (tenant_id, user_id, role_id, school_id, is_primary, is_active, created_by, created_at)
            SELECT v_tenant_id, v_user_id, r.role_id, v_school_id, TRUE, TRUE, p_action_user_id, NOW()
            FROM config.roles r
            WHERE r.tenant_id = v_tenant_id
              AND r.role_code = 'SCHOOL_ADMIN'
              AND r.is_active = TRUE
              AND r.is_deleted = FALSE
            ON CONFLICT (tenant_id, user_id, role_id) DO NOTHING;

            IF NOT FOUND THEN
                RAISE EXCEPTION 'This tenant has no active School Admin role, so the admin could not be created.';
            END IF;
        END IF;
    END IF;

    /*
        FINAL RESULT
    */
    OPEN p_result FOR
    SELECT
        v_school_id AS school_id,
        v_tenant_id AS tenant_id;
END;
$procedure$;

-- ===== sp_school_list.sql =====
-- Server-side school listing for the SuperAdmin Schools screen: tenant-scoped,
-- with optional filters and pagination. Window counts (total / active) are computed
-- over the full filtered set (before LIMIT) so the UI can show accurate totals.
CREATE OR REPLACE PROCEDURE core.sp_school_list(
    IN p_tenant_id       integer,
    IN p_action_user_id  integer,
    IN p_search          character varying DEFAULT NULL,
    IN p_city            character varying DEFAULT NULL,
    IN p_state           character varying DEFAULT NULL,
    IN p_status_id       integer DEFAULT NULL,
    IN p_board_id        integer DEFAULT NULL,
    IN p_school_type_id  integer DEFAULT NULL,
    IN p_from_date       date DEFAULT NULL,
    IN p_to_date         date DEFAULT NULL,
    IN p_page_no         integer DEFAULT 1,
    IN p_page_size       integer DEFAULT 10,
    INOUT p_result       refcursor DEFAULT 'school_list_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_offset integer;
    -- Typed text is matched literally: % and _ are LIKE wildcards, so a search for
    -- "%" used to return every school. Backslash is ILIKE's default escape.
    v_search text := replace(replace(replace(TRIM(COALESCE(p_search, '')), '\', '\\'), '%', '\%'), '_', '\_');
    v_city   text := replace(replace(replace(TRIM(COALESCE(p_city,   '')), '\', '\\'), '%', '\%'), '_', '\_');
    v_state  text := replace(replace(replace(TRIM(COALESCE(p_state,  '')), '\', '\\'), '%', '\%'), '_', '\_');
BEGIN
    IF p_page_no IS NULL OR p_page_no < 1 THEN p_page_no := 1; END IF;
    IF p_page_size IS NULL OR p_page_size < 1 THEN p_page_size := 10; END IF;
    v_offset := (p_page_no - 1) * p_page_size;

    OPEN p_result FOR
    SELECT
        s.school_id,
        s.school_code,
        s.school_name,
        s.display_name,
        t.tenant_name,
        t.tenant_code,
        st.name AS status_name,
        -- "State Board" alone is not useful on a list of schools across states, so
        -- boards that carry a state show it: "State Board (Maharashtra)".
        CASE WHEN bs.name IS NOT NULL THEN b.name || ' (' || bs.name || ')' ELSE b.name END
            AS board_name,
        sty.name AS school_type_name,
        -- School / Computer-IT institute / Coaching centre (institution_categories.sql).
        COALESCE(ic.name, 'School') AS category_name,
        a.city,
        a.state,
        c.contact_name,
        c.phone,
        s.created_at,
        COUNT(*) OVER()                                          AS total_count,
        -- "Active" = can sign in, so Under Review (allows_login) counts too.
        COUNT(*) FILTER (WHERE st.allows_login) OVER()           AS active_count
    FROM core.schools s
    INNER JOIN core.tenants t
        ON t.tenant_id = s.tenant_id
       AND t.is_deleted = FALSE
    LEFT JOIN core.school_profiles sp
        ON sp.tenant_id = s.tenant_id
       AND sp.school_id = s.school_id
       AND sp.is_deleted = FALSE
       AND sp.is_active = TRUE
    LEFT JOIN config.school_statuses st
        ON st.school_status_id = s.status_id
       AND st.is_deleted = FALSE
    LEFT JOIN config.boards b
        ON b.board_id = sp.board_id
       AND b.is_deleted = FALSE
    LEFT JOIN config.states bs
        ON bs.state_id = sp.board_state_id
    LEFT JOIN config.school_types sty
        ON sty.school_type_id = sp.school_type_id
       AND sty.is_deleted = FALSE
    LEFT JOIN config.institution_categories ic
        ON ic.category_id = sp.institution_category_id
    LEFT JOIN core.school_addresses a
        ON a.tenant_id = s.tenant_id
       AND a.school_id = s.school_id
       AND a.is_primary = TRUE
       AND a.is_active = TRUE
       AND a.is_deleted = FALSE
    LEFT JOIN core.school_contacts c
        ON c.tenant_id = s.tenant_id
       AND c.school_id = s.school_id
       AND c.is_primary = TRUE
       AND c.is_active = TRUE
       AND c.is_deleted = FALSE
    WHERE s.is_active = TRUE
      AND s.is_deleted = FALSE
      AND (p_tenant_id = 1 OR s.tenant_id = p_tenant_id)
      AND (v_search = '' OR
              s.school_name  ILIKE '%' || v_search || '%' OR
              s.school_code  ILIKE '%' || v_search || '%' OR
              t.tenant_name  ILIKE '%' || v_search || '%' OR
              t.tenant_code  ILIKE '%' || v_search || '%' OR
              a.city         ILIKE '%' || v_search || '%' OR
              c.contact_name ILIKE '%' || v_search || '%')
      AND (v_city = '' OR a.city ILIKE '%' || v_city || '%')
      AND (v_state = '' OR a.state ILIKE '%' || v_state || '%')
      AND (p_status_id IS NULL OR s.status_id = p_status_id)
      AND (p_board_id IS NULL OR sp.board_id = p_board_id)
      AND (p_school_type_id IS NULL OR sp.school_type_id = p_school_type_id)
      AND (p_from_date IS NULL OR s.created_at::date >= p_from_date)
      AND (p_to_date   IS NULL OR s.created_at::date <= p_to_date)
    ORDER BY s.school_id DESC
    LIMIT p_page_size OFFSET v_offset;
END;
$procedure$;

-- ===== sp_school_admin_basic_profile_manage.sql =====
-- ============================================================================
-- core.sp_school_admin_basic_profile_manage
--
-- Dumped from the live DB so this proc finally has a source file (the only
-- previous mention of it anywhere was a comment). Edit here, re-apply with psql -f.
--
-- Changes made on top of the original:
--   1. board_name now includes the board's STATE. A State Board school was
--      showing just "State Board" on Basic Profile while the school list already
--      said "State Board (Uttar Pradesh)" — the two screens disagreed.
--   2. GET returns country_id / state_id / district_id so the shared
--      Country->State->District picker can pre-select, matching the SuperAdmin
--      wizard instead of using free-text boxes.
--   3. SAVE accepts and stores those same ids (new p_country_id / p_state_id /
--      p_district_id parameters, added at the END, just before p_result).
--   4. (2026-10-10) Official / alternate phone may be a landline: see
--      core.fn_school_phone_clean below. Stored as digits only.
--   5. (2026-10-10) 'RemoveLogo' operation: clears logo_url and returns the old
--      URL so the controller can delete the file (only when it sits in this
--      school's upload folder).
-- ============================================================================

-- ── fn_school_phone_clean ───────────────────────────────────────────────────
-- A school's official number is often a landline. Accepted, after removing
-- spaces and hyphens:
--   * a 10-digit Indian mobile        9876543210
--   * a landline with its STD code    0141-2345678, 011 23456789, 01412345678
--     (starts with 0, 10 to 12 digits in all)
-- Returns the number as DIGITS ONLY (0141-2345678 -> 01412345678), NULL for a
-- blank value, and raises for anything else. The same rule is in
-- EC.rule.phone (site.js) and PhoneRules (C#).
CREATE OR REPLACE FUNCTION core.fn_school_phone_clean(p_value varchar, p_label varchar)
RETURNS varchar
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
    v varchar := regexp_replace(COALESCE(p_value, ''), '[\s-]', '', 'g');
BEGIN
    IF v = '' THEN
        RETURN NULL;
    END IF;
    IF v ~ '^[6-9][0-9]{9}$' OR v ~ '^0[0-9]{9,11}$' THEN
        RETURN v;
    END IF;
    RAISE EXCEPTION '% must be a 10-digit mobile number or a landline with STD code (e.g. 0141-2345678).', p_label
        USING ERRCODE = 'check_violation';
END;
$$;

CREATE OR REPLACE PROCEDURE core.sp_school_admin_basic_profile_manage(IN p_operation character varying, IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_display_name character varying DEFAULT NULL::character varying, IN p_registration_number character varying DEFAULT NULL::character varying, IN p_affiliation_number character varying DEFAULT NULL::character varying, IN p_board_id integer DEFAULT NULL::integer, IN p_school_type_id integer DEFAULT NULL::integer, IN p_ownership_type_id integer DEFAULT NULL::integer, IN p_medium_id integer DEFAULT NULL::integer, IN p_established_year integer DEFAULT NULL::integer, IN p_website character varying DEFAULT NULL::character varying, IN p_logo_url character varying DEFAULT NULL::character varying, IN p_header_image_url character varying DEFAULT NULL::character varying, IN p_address_type_id integer DEFAULT NULL::integer, IN p_address_line1 character varying DEFAULT NULL::character varying, IN p_address_line2 character varying DEFAULT NULL::character varying, IN p_city character varying DEFAULT NULL::character varying, IN p_district character varying DEFAULT NULL::character varying, IN p_state character varying DEFAULT NULL::character varying, IN p_pincode character varying DEFAULT NULL::character varying, IN p_contact_type_id integer DEFAULT NULL::integer, IN p_contact_name character varying DEFAULT NULL::character varying, IN p_designation character varying DEFAULT NULL::character varying, IN p_contact_email character varying DEFAULT NULL::character varying, IN p_phone character varying DEFAULT NULL::character varying, IN p_alternate_phone character varying DEFAULT NULL::character varying, IN p_academic_year_id integer DEFAULT NULL::integer, IN p_date_format_id integer DEFAULT NULL::integer, IN p_time_format_id integer DEFAULT NULL::integer, IN p_enable_sms boolean DEFAULT false, IN p_enable_email boolean DEFAULT true, IN p_enable_whatsapp boolean DEFAULT false, IN p_country_id integer DEFAULT NULL::integer, IN p_state_id integer DEFAULT NULL::integer, IN p_district_id integer DEFAULT NULL::integer, INOUT p_result refcursor DEFAULT 'basic_profile_cursor'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    -- Set only for boards flagged requires_state; the address state is then forced
    -- to these values on save (see the UpdateBasicProfile branch).
    v_locked_state_id   integer;
    v_locked_state_name character varying;
    v_old_logo          character varying;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    IF p_operation = 'GetBasicProfile' THEN

        OPEN p_result FOR
        SELECT
            s.tenant_id,
            t.tenant_name,

            s.school_id,
            s.school_code,
            s.school_name,
            s.display_name,
            s.status_id,
            -- The page's status pill read "Status -" for every school: this join was
            -- left commented out (with a wrong table and column name).
            sm.name AS status_name,

            sp.registration_number,
            sp.affiliation_number,

            sp.board_id,
            sp.board_state_id,
            -- "State Board (Uttar Pradesh)", not a bare "State Board". Boards flagged
            -- config.boards.requires_state carry a board_state_id; without this join
            -- the school list and this page described the same school differently.
            CASE WHEN bs.name IS NOT NULL THEN b.name || ' (' || bs.name || ')' ELSE b.name END
                AS board_name,
            -- Drives the read-only lock on the address State. A State Board is granted by
            -- one state's education department, so a UP Board school cannot sit in Bihar —
            -- for these boards the address state is not the school's to choose. CBSE/ICSE/IB
            -- are national, so they stay free.
            COALESCE(b.requires_state, FALSE) AS board_requires_state,

            sp.school_type_id,
            st.name AS school_type_name,

            -- School / Computer-IT institute / Coaching centre, and what this page calls
            -- the board and type fields for it (institution_categories.sql).
            COALESCE(ic.name, 'School')         AS category_name,
            COALESCE(ic.board_label, 'Board')   AS board_label,
            COALESCE(ic.type_label, 'School Type') AS type_label,

            sp.ownership_type_id,
            sp.medium_id,
            sp.established_year,
            sp.website,
            sp.logo_url,
            sp.header_image_url,

            COALESCE(sa.address_type_id, 1) AS address_type_id,
            sa.address_line1,
            sa.address_line2,
            sa.city,
            sa.district,
            sa.state,
            sa.pincode,
            -- Needed so the shared Country -> State -> District picker can pre-select,
            -- instead of this page falling back to free-text boxes that drift from
            -- what the SuperAdmin wizard stored.
            sa.country_id,
            sa.state_id,
            sa.district_id,

            COALESCE(sc.contact_type_id, 1) AS contact_type_id,
            sc.contact_name,
            sc.designation,
            sc.email,
            sc.phone,
            sc.alternate_phone,

            ss.academic_year_id,
            ss.date_format_id,
            ss.time_format_id,
            COALESCE(ss.enable_sms, FALSE) AS enable_sms,
            COALESCE(ss.enable_email, TRUE) AS enable_email,
            COALESCE(ss.enable_whatsapp, FALSE) AS enable_whatsapp

        FROM core.schools s

        LEFT JOIN core.tenants t
            ON t.tenant_id = s.tenant_id

        LEFT JOIN core.school_profiles sp
            ON sp.tenant_id = s.tenant_id
           AND sp.school_id = s.school_id

        LEFT JOIN config.school_statuses sm
            ON sm.school_status_id = s.status_id

        LEFT JOIN config.boards b
            ON b.board_id = sp.board_id

        LEFT JOIN config.states bs
            ON bs.state_id = sp.board_state_id

        LEFT JOIN config.institution_categories ic
            ON ic.category_id = sp.institution_category_id

        LEFT JOIN config.school_types st
            ON st.school_type_id = sp.school_type_id

        LEFT JOIN core.school_addresses sa
            ON sa.tenant_id = s.tenant_id
           AND sa.school_id = s.school_id
           AND sa.address_type_id = 1

        LEFT JOIN core.school_contacts sc
            ON sc.tenant_id = s.tenant_id
           AND sc.school_id = s.school_id
           AND sc.contact_type_id = 1

        LEFT JOIN core.school_settings ss
            ON ss.tenant_id = s.tenant_id
           AND ss.school_id = s.school_id

        WHERE s.tenant_id = p_tenant_id
          AND s.school_id = p_school_id
          AND COALESCE(s.is_deleted, FALSE) = FALSE;

    ELSIF p_operation = 'UpdateBasicProfile' THEN

        -- Mobile or landline, stored as digits (fn_school_phone_clean).
        p_phone           := core.fn_school_phone_clean(p_phone, 'Official phone');
        p_alternate_phone := core.fn_school_phone_clean(p_alternate_phone, 'Alternate phone');

        -- A State Board is granted by one state's education department, so a UP Board
        -- school cannot be located in Bihar. For boards flagged requires_state the
        -- address state is NOT the school's to choose — it follows the board.
        --
        -- Forced here, on the server, and not just disabled in the UI: a disabled input
        -- simply doesn't post, and a hand-crafted POST would otherwise slip a different
        -- state through. The board state is the single source of truth.
        --
        -- Only applies to requires_state boards; CBSE / ICSE / IB / NIOS are national
        -- and their schools may sit in any state, so those fall through untouched.
        SELECT sp.board_state_id, st.name
          INTO v_locked_state_id, v_locked_state_name
        FROM core.school_profiles sp
        JOIN config.boards b     ON b.board_id = sp.board_id AND b.requires_state = TRUE
        JOIN config.states st    ON st.state_id = sp.board_state_id
        WHERE sp.tenant_id = p_tenant_id
          AND sp.school_id = p_school_id
          AND sp.is_deleted = FALSE;

        IF v_locked_state_id IS NOT NULL THEN
            p_state_id := v_locked_state_id;
            p_state    := v_locked_state_name;

            -- A district from the old state would now contradict the forced state, so
            -- drop it rather than store an impossible pair. The school re-picks it.
            IF p_district_id IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM config.districts d
                               WHERE d.district_id = p_district_id
                                 AND d.state_id = v_locked_state_id) THEN
                p_district_id := NULL;
                p_district    := NULL;
            END IF;
        END IF;

        UPDATE core.schools
        SET
            display_name = p_display_name,
            updated_by = p_action_user_id,
            updated_at = NOW()
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

        INSERT INTO core.school_profiles (
            tenant_id,
            school_id,
            registration_number,
            affiliation_number,
            established_year,
            website,
            logo_url,
            header_image_url,
            created_by,
            created_at,
            updated_by,
            updated_at
        )
        VALUES (
            p_tenant_id,
            p_school_id,
            p_registration_number,
            p_affiliation_number,
            p_established_year,
            p_website,
            p_logo_url,
            p_header_image_url,
            p_action_user_id,
            NOW(),
            p_action_user_id,
            NOW()
        )
        ON CONFLICT (tenant_id, school_id)
        DO UPDATE SET
            registration_number = EXCLUDED.registration_number,
            affiliation_number = EXCLUDED.affiliation_number,
            established_year = EXCLUDED.established_year,
            website = EXCLUDED.website,
            logo_url = COALESCE(EXCLUDED.logo_url, core.school_profiles.logo_url),
            header_image_url = COALESCE(EXCLUDED.header_image_url, core.school_profiles.header_image_url),
            updated_by = p_action_user_id,
            updated_at = NOW();

        INSERT INTO core.school_addresses (
            tenant_id,
            school_id,
            address_type_id,
            address_line1,
            address_line2,
            city,
            district,
            state,
            pincode,
            country_id,
            state_id,
            district_id,
            created_by,
            created_at,
            updated_by,
            updated_at
        )
        VALUES (
            p_tenant_id,
            p_school_id,
            COALESCE(p_address_type_id, 1),
            p_address_line1,
            p_address_line2,
            p_city,
            p_district,
            p_state,
            p_pincode,
            p_country_id,
            p_state_id,
            p_district_id,
            p_action_user_id,
            NOW(),
            p_action_user_id,
            NOW()
        )
        ON CONFLICT (tenant_id, school_id, address_type_id)
        DO UPDATE SET
            address_line1 = EXCLUDED.address_line1,
            address_line2 = EXCLUDED.address_line2,
            city = EXCLUDED.city,
            district = EXCLUDED.district,
            -- COALESCE so a caller that doesn't send the ids (an older screen, or a
            -- partial save) cannot blank out geography the wizard already set.
            country_id = COALESCE(EXCLUDED.country_id, core.school_addresses.country_id),
            state_id = COALESCE(EXCLUDED.state_id, core.school_addresses.state_id),
            -- The district id must never outlive its text or its state: no district
            -- text means no district, and a new state drops the old state's district.
            -- (A plain COALESCE kept Gurugram after the state moved to Delhi.)
            district_id = CASE
                WHEN NULLIF(trim(EXCLUDED.district), '') IS NULL THEN NULL
                WHEN EXCLUDED.district_id IS NOT NULL THEN EXCLUDED.district_id
                WHEN COALESCE(EXCLUDED.state_id, core.school_addresses.state_id)
                     IS DISTINCT FROM core.school_addresses.state_id THEN NULL
                ELSE core.school_addresses.district_id
            END,
            state = EXCLUDED.state,
            pincode = EXCLUDED.pincode,
            updated_by = p_action_user_id,
            updated_at = NOW();

        INSERT INTO core.school_contacts (
            tenant_id,
            school_id,
            contact_type_id,
            contact_name,
            designation,
            email,
            phone,
            alternate_phone,
            created_by,
            created_at,
            updated_by,
            updated_at
        )
        VALUES (
            p_tenant_id,
            p_school_id,
            COALESCE(p_contact_type_id, 1),
            p_contact_name,
            p_designation,
            p_contact_email,
            p_phone,
            p_alternate_phone,
            p_action_user_id,
            NOW(),
            p_action_user_id,
            NOW()
        )
        ON CONFLICT (tenant_id, school_id, contact_type_id)
        DO UPDATE SET
            contact_name = EXCLUDED.contact_name,
            designation = EXCLUDED.designation,
            email = EXCLUDED.email,
            phone = EXCLUDED.phone,
            alternate_phone = EXCLUDED.alternate_phone,
            updated_by = p_action_user_id,
            updated_at = NOW();

        OPEN p_result FOR
        SELECT
            TRUE AS success,
            p_school_id AS school_id,
            'Basic profile updated successfully.' AS message;

    ELSIF p_operation = 'RemoveLogo' THEN

        -- The save above keeps the old logo when none is sent (COALESCE), so
        -- taking a logo off needs its own operation. Only this school's row.
        SELECT sp.logo_url INTO v_old_logo
        FROM core.school_profiles sp
        WHERE sp.tenant_id = p_tenant_id AND sp.school_id = p_school_id;

        UPDATE core.school_profiles
        SET logo_url = NULL,
            updated_by = p_action_user_id,
            updated_at = NOW()
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND logo_url IS NOT NULL;

        OPEN p_result FOR
        SELECT
            TRUE AS success,
            p_school_id AS school_id,
            v_old_logo AS removed_logo_url,
            CASE WHEN NULLIF(trim(v_old_logo), '') IS NULL THEN 'There was no logo to remove.'
                 ELSE 'Logo removed.' END AS message;

    ELSE
        RAISE EXCEPTION 'Invalid operation %. Allowed operations are GetBasicProfile, UpdateBasicProfile, RemoveLogo', p_operation;
    END IF;
END;
$procedure$

;
