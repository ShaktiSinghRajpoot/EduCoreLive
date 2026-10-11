-- ============================================================================
-- Institution categories test suite (2026-10-11) -- institution_categories.sql.
--
--   A. Master data: categories, cleaned-up lists, category_codes on each row
--   B. config.sp_school_dropdowns: the new cursor and the categories column
--   C. core.sp_school_manage: board / type / ownership must fit the category,
--      only a SCHOOL must name a board, an older app (no category) still works
--   D. What the list and the school's own Basic Profile show
--
-- Creates its own tenants and schools through sp_school_manage, the way the
-- Super Admin wizard does. Runs inside ONE transaction and ROLLS BACK.
--
--     psql ... -f institution_categories_tests.sql
-- ============================================================================

\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE TEMP TABLE _t(id serial, name text, ok boolean, detail text) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.chk(p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO _t(name, ok, detail) VALUES (p_name, p_ok, p_detail);
    RAISE NOTICE '  [%] %  %', CASE WHEN p_ok THEN 'PASS' ELSE 'FAIL' END, rpad(p_name, 58), p_detail;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.super_user() RETURNS integer LANGUAGE sql AS $$
    SELECT ur.user_id FROM core.user_roles ur JOIN config.roles r ON r.role_id = ur.role_id
    WHERE r.role_code = 'SUPER_ADMIN' AND NOT ur.is_deleted ORDER BY ur.user_id LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION pg_temp.board(p_code text) RETURNS integer LANGUAGE sql AS $$
    SELECT board_id FROM config.boards WHERE board_code = p_code AND NOT is_deleted;
$$;
CREATE OR REPLACE FUNCTION pg_temp.stype(p_name text) RETURNS integer LANGUAGE sql AS $$
    SELECT school_type_id FROM config.school_types WHERE name = p_name AND NOT is_deleted;
$$;
CREATE OR REPLACE FUNCTION pg_temp.owner(p_name text) RETURNS integer LANGUAGE sql AS $$
    SELECT ownership_type_id FROM config.ownership_types WHERE name = p_name AND NOT is_deleted;
$$;

-- Creates a school on a new tenant. p_cat NULL = an app that does not send the
-- category. Returns 'OK:<school_id>' or 'ERR:<message>'.
CREATE OR REPLACE FUNCTION pg_temp.mk(p_tag text, p_cat int, p_board int, p_type int, p_own int)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'mk_' || p_tag; v_id integer;
BEGIN
    CALL core.sp_school_manage('INSERT', 1, pg_temp.super_user(),
        p_tenant_mode => 'new', p_tenant_name => 'IC Test ' || p_tag, p_tenant_code => 'ic-test-' || p_tag,
        p_school_name => 'IC Test ' || p_tag, p_status_id => 1,
        p_board_id => p_board, p_school_type_id => p_type, p_ownership_type_id => p_own,
        p_address_line1 => '1 Test Road', p_city => 'Jaipur', p_state => 'Rajasthan', p_pincode => '302001',
        p_contact_name => 'Tester', p_phone => '9876500000',
        p_result => c, p_institution_category_id => p_cat);
    FETCH c INTO v_id;
    CLOSE c;
    RETURN 'OK:' || v_id;
EXCEPTION WHEN others THEN
    RETURN 'ERR:' || SQLERRM;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.cat_of(p_result text) RETURNS integer LANGUAGE sql AS $$
    SELECT institution_category_id FROM core.school_profiles
    WHERE school_id = NULLIF(split_part(p_result, ':', 2), '')::int;
$$;


-- -- A. master data -----------------------------------------------------------
DO $a$
BEGIN
    RAISE NOTICE 'A. master data';
    PERFORM pg_temp.chk('A1 three categories', (SELECT count(*) FROM config.institution_categories WHERE NOT is_deleted) = 3);
    PERFORM pg_temp.chk('A2 only SCHOOL requires a board',
        (SELECT string_agg(category_code, ',') FROM config.institution_categories WHERE board_required) = 'SCHOOL');
    PERFORM pg_temp.chk('A3 every school profile has a category',
        NOT EXISTS (SELECT 1 FROM core.school_profiles WHERE institution_category_id IS NULL));
    PERFORM pg_temp.chk('A4 no duplicate school type names left',
        NOT EXISTS (SELECT 1 FROM config.school_types WHERE NOT is_deleted
                    AND name IN ('Pre Primary', 'Primary School', 'Middle School', 'High School', 'K-12 School')));
    PERFORM pg_temp.chk('A5 Private / Trust / Society / Deemed Univ retired',
        NOT EXISTS (SELECT 1 FROM config.ownership_types WHERE NOT is_deleted
                    AND name IN ('Private', 'Trust', 'Society', 'Deemed University')));
    PERFORM pg_temp.chk('A6 no profile points at a retired type',
        NOT EXISTS (SELECT 1 FROM core.school_profiles sp JOIN config.school_types t USING (school_type_id) WHERE t.is_deleted));
    PERFORM pg_temp.chk('A7 no profile points at a retired ownership',
        NOT EXISTS (SELECT 1 FROM core.school_profiles sp JOIN config.ownership_types o USING (ownership_type_id) WHERE o.is_deleted));
    PERFORM pg_temp.chk('A8 computer institute types exist',
        (SELECT count(*) FROM config.school_types WHERE NOT is_deleted AND 'COMPUTER_IT' = ANY (category_codes)) >= 3);
    PERFORM pg_temp.chk('A9 coaching types exist',
        (SELECT count(*) FROM config.school_types WHERE NOT is_deleted AND 'COACHING' = ANY (category_codes)) >= 3);
    PERFORM pg_temp.chk('A10 "Not affiliated" board fits every category',
        (SELECT category_codes IS NULL FROM config.boards WHERE board_code = 'NONE'));
    PERFORM pg_temp.chk('A11 CBSE is school-only',
        (SELECT category_codes = ARRAY['SCHOOL'] FROM config.boards WHERE board_code = 'CBSE'));
    PERFORM pg_temp.chk('A12 every live type has a category',
        NOT EXISTS (SELECT 1 FROM config.school_types WHERE NOT is_deleted AND category_codes IS NULL));
    PERFORM pg_temp.chk('A13 "Regional Language" medium retired',
        NOT EXISTS (SELECT 1 FROM config.mediums WHERE NOT is_deleted AND name = 'Regional Language'));
END
$a$;


-- -- B. dropdowns ---------------------------------------------------------------
DO $b$
DECLARE r record; n int := 0; v_cbse text; v_none text; v_has_platform boolean := FALSE;
        ct refcursor := 't'; cs refcursor := 's'; cb refcursor := 'b'; cty refcursor := 'ty';
        co refcursor := 'o'; cm refcursor := 'm'; ca refcursor := 'a'; cc refcursor := 'c';
        cy refcursor := 'y'; cd refcursor := 'd'; ctf refcursor := 'tf'; ccat refcursor := 'cat';
BEGIN
    RAISE NOTICE 'B. dropdowns';
    CALL config.sp_school_dropdowns(ct, cs, cb, cty, co, cm, ca, cc, cy, cd, ctf, ccat);
    LOOP FETCH ccat INTO r; EXIT WHEN NOT FOUND; n := n + 1; END LOOP;
    PERFORM pg_temp.chk('B1 categories cursor returns 3 rows', n = 3, n::text);

    LOOP FETCH cb INTO r; EXIT WHEN NOT FOUND;
        IF r.name = 'CBSE' THEN v_cbse := r.categories; END IF;
        IF r.name = 'Not affiliated / Independent' THEN v_none := r.categories; END IF;
    END LOOP;
    PERFORM pg_temp.chk('B2 board row carries its categories', v_cbse = 'SCHOOL', COALESCE(v_cbse, 'NULL'));
    PERFORM pg_temp.chk('B3 all-category board sends empty', v_none = '', COALESCE(v_none, 'NULL'));

    LOOP FETCH ct INTO r; EXIT WHEN NOT FOUND; IF r.id = 1 THEN v_has_platform := TRUE; END IF; END LOOP;
    PERFORM pg_temp.chk('B4 tenant list never offers tenant 1', NOT v_has_platform);
    CLOSE ct; CLOSE cs; CLOSE cb; CLOSE cty; CLOSE co; CLOSE cm; CLOSE ca; CLOSE cc; CLOSE cy; CLOSE cd; CLOSE ctf; CLOSE ccat;

END
$b$;

-- B5: the app that is live before the redeploy passes only the first 11 cursors.
-- A top-level CALL, as Npgsql sends it (inside PL/pgSQL every INOUT argument must
-- be a variable, so this case cannot be tested from a DO block). If it failed,
-- ON_ERROR_STOP would end the run here.
CALL config.sp_school_dropdowns('t2', 's2', 'b2', 'ty2', 'o2', 'm2', 'a2', 'c2', 'y2', 'd2', 'tf2');
SELECT pg_temp.chk('B5 old 11-cursor call still works', TRUE) \gset



-- -- C. create / edit rules ---------------------------------------------------------
DO $c$
DECLARE v text; v_id int; c refcursor;
BEGIN
    RAISE NOTICE 'C. create / edit rules';

    v := pg_temp.mk('c1', 2, NULL, pg_temp.stype('Computer Training Centre (DCA / ADCA / Tally)'), pg_temp.owner('Sole Proprietorship'));
    PERFORM pg_temp.chk('C1 computer institute with no board is saved', v LIKE 'OK:%', v);
    PERFORM pg_temp.chk('C2 ... and stored as category 2', pg_temp.cat_of(v) = 2, COALESCE(pg_temp.cat_of(v)::text, 'NULL'));

    v := pg_temp.mk('c3', 2, pg_temp.board('NIELIT'), pg_temp.stype('IT & Software Training Institute'), NULL);
    PERFORM pg_temp.chk('C3 computer institute with NIELIT is saved', v LIKE 'OK:%', v);

    v := pg_temp.mk('c4', 2, pg_temp.board('CBSE'), pg_temp.stype('Computer Training Centre (DCA / ADCA / Tally)'), NULL);
    PERFORM pg_temp.chk('C4 computer institute with CBSE is refused', v LIKE 'ERR:%board is not available%', v);

    v := pg_temp.mk('c5', 3, NULL, pg_temp.stype('Computer Training Centre (DCA / ADCA / Tally)'), NULL);
    PERFORM pg_temp.chk('C5 coaching centre with a computer type is refused', v LIKE 'ERR:%type is not available%', v);

    v := pg_temp.mk('c6', 3, NULL, pg_temp.stype('School Tuition Centre'), pg_temp.owner('Private Unaided'));
    PERFORM pg_temp.chk('C6 coaching centre with a school ownership refused', v LIKE 'ERR:%ownership is not available%', v);

    v := pg_temp.mk('c7', 3, pg_temp.board('NONE'), pg_temp.stype('School Tuition Centre'), pg_temp.owner('Trust / Society'));
    PERFORM pg_temp.chk('C7 coaching: Not affiliated + Trust/Society saved', v LIKE 'OK:%', v);

    v := pg_temp.mk('c8', 1, NULL, pg_temp.stype('K-12 School (Class 1–12)'), NULL);
    PERFORM pg_temp.chk('C8 school with no board is refused', v = 'ERR:Board is required.', v);

    v := pg_temp.mk('c9', 1, pg_temp.board('CBSE'), pg_temp.stype('School Tuition Centre'), NULL);
    PERFORM pg_temp.chk('C9 school with a coaching type is refused', v LIKE 'ERR:%type is not available%', v);

    v := pg_temp.mk('c10', 1, pg_temp.board('CBSE'), pg_temp.stype('K-12 School (Class 1–12)'), pg_temp.owner('Private Unaided'));
    PERFORM pg_temp.chk('C10 normal CBSE school is saved', v LIKE 'OK:%', v);

    v := pg_temp.mk('c11', NULL, pg_temp.board('CBSE'), pg_temp.stype('K-12 School (Class 1–12)'), NULL);
    PERFORM pg_temp.chk('C11 no category sent (old app) -> a SCHOOL', pg_temp.cat_of(v) = 1, v);

    v := pg_temp.mk('c12', 9, NULL, NULL, NULL);
    PERFORM pg_temp.chk('C12 unknown category is refused', v LIKE 'ERR:%valid institution category%', v);

    -- Edit from an app that does not send the category keeps the institute an institute.
    v := pg_temp.mk('c13', 2, NULL, pg_temp.stype('Digital Skills / Typing Centre'), NULL);
    v_id := split_part(v, ':', 2)::int;
    c := 'up13';
    CALL core.sp_school_manage('UPDATE', 1, pg_temp.super_user(),
        p_school_id => v_id, p_school_name => 'IC Test c13 renamed', p_status_id => 1,
        p_school_type_id => pg_temp.stype('Digital Skills / Typing Centre'),
        p_address_line1 => '1 Test Road', p_city => 'Jaipur', p_state => 'Rajasthan', p_pincode => '302001',
        p_contact_name => 'Tester', p_phone => '9876500000', p_result => c);
    CLOSE c;
    PERFORM pg_temp.chk('C13 edit without category keeps category 2',
        (SELECT institution_category_id FROM core.school_profiles WHERE school_id = v_id) = 2);

    -- Edit that moves a school into an institute (fixing a wrongly-created one).
    v := pg_temp.mk('c14', 1, pg_temp.board('ICSE'), pg_temp.stype('Special Education School'), NULL);
    v_id := split_part(v, ':', 2)::int;
    c := 'up14';
    CALL core.sp_school_manage('UPDATE', 1, pg_temp.super_user(),
        p_school_id => v_id, p_school_name => 'IC Test c14', p_status_id => 1,
        p_board_id => NULL, p_school_type_id => pg_temp.stype('Computer Training Centre (DCA / ADCA / Tally)'),
        p_address_line1 => '1 Test Road', p_city => 'Jaipur', p_state => 'Rajasthan', p_pincode => '302001',
        p_contact_name => 'Tester', p_phone => '9876500000', p_result => c, p_institution_category_id => 2);
    CLOSE c;
    PERFORM pg_temp.chk('C14 school re-saved as a computer institute',
        (SELECT institution_category_id = 2 AND board_id IS NULL FROM core.school_profiles WHERE school_id = v_id));
END
$c$;


-- -- D. list and Basic Profile ----------------------------------------------------
DO $d$
DECLARE v text; v_id int; v_t int; r record; c refcursor := 'lst'; v_seen text;
BEGIN
    RAISE NOTICE 'D. list and Basic Profile';
    v := pg_temp.mk('d1', 3, NULL, pg_temp.stype('Spoken English / Language Centre'), NULL);
    v_id := split_part(v, ':', 2)::int;
    SELECT tenant_id INTO v_t FROM core.schools WHERE school_id = v_id;

    CALL core.sp_school_list(1, pg_temp.super_user(), 'IC Test d1', p_result => c);
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
        IF r.school_id = v_id THEN v_seen := r.category_name; END IF;
    END LOOP;
    CLOSE c;
    PERFORM pg_temp.chk('D1 school list shows the category', v_seen = 'Coaching / Tuition Centre', COALESCE(v_seen, 'NULL'));

    c := 'bp';
    CALL core.sp_school_admin_basic_profile_manage('GetBasicProfile', v_t, v_id, pg_temp.super_user(), p_result => c);
    FETCH c INTO r;
    CLOSE c;
    PERFORM pg_temp.chk('D2 Basic Profile: category name', r.category_name = 'Coaching / Tuition Centre', COALESCE(r.category_name, 'NULL'));
    PERFORM pg_temp.chk('D3 Basic Profile: board label', r.board_label = 'Affiliation', COALESCE(r.board_label, 'NULL'));
    PERFORM pg_temp.chk('D4 Basic Profile: type label', r.type_label = 'Centre Type', COALESCE(r.type_label, 'NULL'));
END
$d$;


DO $sum$
DECLARE p integer; f integer; r record;
BEGIN
    SELECT COUNT(*) FILTER (WHERE ok), COUNT(*) FILTER (WHERE NOT ok) INTO p, f FROM _t;
    RAISE NOTICE '';
    RAISE NOTICE '========== RESULT: % passed, % failed ==========', p, f;
    IF f > 0 THEN
        RAISE NOTICE 'failures:';
        FOR r IN SELECT name, detail FROM _t WHERE NOT ok ORDER BY id LOOP
            RAISE NOTICE '   %  %', rpad(r.name, 58), r.detail;
        END LOOP;
    END IF;
    RAISE NOTICE '';
END
$sum$;

ROLLBACK;
