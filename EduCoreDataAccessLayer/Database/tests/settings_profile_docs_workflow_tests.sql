-- ============================================================================
-- Basic Profile, Documents & Formats, and Admission Workflow test suite.
--
-- Real-world scenario: "Roman Public School" (tenant 24 / school 34) sets up for
-- session 2026-27. The admin fills in the school profile (it prints on every
-- receipt, TC and ID card), picks how documents print, and decides whether a
-- parent must register (and pay a registration fee) before admission.
--
-- Runs inside ONE transaction and ROLLS BACK.
--
--     psql ... -f settings_profile_docs_workflow_tests.sql
--
-- COVERS
--   A. Basic profile read and scope
--   B. Basic profile save round-trip
--   C. What the database refuses on a profile save
--   D. Address geography (state / district) consistency
--   E. Documents & Formats (receipt, TC, ID card)
--   F. Admission workflow settings
--   G. Downstream: registration numbering reads the workflow prefix
--   H. Inline fee setup on the workflow page (as the controller calls it)
--   I. Tenant isolation and permission keys
-- ============================================================================

\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE TEMP TABLE _t(id serial, name text, ok boolean, detail text) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.chk(p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO _t(name, ok, detail) VALUES (p_name, p_ok, p_detail);
    RAISE NOTICE '  [%] %  %', CASE WHEN p_ok THEN 'PASS' ELSE 'FAIL' END, rpad(p_name, 54), p_detail;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.chk_eq(p_name text, p_got numeric, p_want numeric)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.chk(p_name, p_got IS NOT DISTINCT FROM p_want,
                        format('got %s, expected %s', COALESCE(p_got::text,'NULL'), p_want));
END $$;

-- A valid basic-profile save with every required field filled. Tests that want
-- to break one field pass it explicitly; everything else stays valid.
CREATE OR REPLACE PROCEDURE pg_temp.bp_save(
    p_tenant int, p_school int,
    p_line1   varchar DEFAULT 'Plot 12, Sector 5',
    p_city    varchar DEFAULT 'Gurugram',
    p_state   varchar DEFAULT 'Haryana',
    p_pincode varchar DEFAULT '122001',
    p_contact varchar DEFAULT 'Anita Sharma',
    p_phone   varchar DEFAULT '9876543210',
    p_est     int     DEFAULT 1995,
    p_website varchar DEFAULT NULL,
    p_display varchar DEFAULT 'ZZ Roman',
    p_regno   varchar DEFAULT NULL,
    p_email   varchar DEFAULT NULL,
    p_state_id int    DEFAULT 8,
    p_district varchar DEFAULT 'Gurugram',
    p_district_id int DEFAULT 199)
LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'bp_' || md5(random()::text);
BEGIN
    CALL core.sp_school_admin_basic_profile_manage(
        p_operation => 'UpdateBasicProfile', p_tenant_id => p_tenant, p_school_id => p_school,
        p_action_user_id => 39, p_display_name => p_display, p_registration_number => p_regno,
        p_established_year => p_est, p_website => p_website,
        p_address_line1 => p_line1, p_city => p_city, p_district => p_district,
        p_state => p_state, p_pincode => p_pincode, p_contact_name => p_contact,
        p_contact_email => p_email, p_phone => p_phone,
        p_state_id => p_state_id, p_district_id => p_district_id, p_result => c);
    CLOSE c;
END $$;


DO $suite$
DECLARE
    c_tenant CONSTANT integer := 24;
    c_school CONSTANT integer := 34;
    c_user   CONSTANT integer := 39;
    -- Another real school, on another tenant, for isolation checks.
    o_tenant CONSTANT integer := 23;
    o_school CONSTANT integer := 33;

    v_year   varchar;
    c        refcursor;
    r        record;
    v_n      integer;
    v_txt    text;
    v_b      boolean;
    v_id     integer;
    v_logo   text;
    v_other  text;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '===== PROFILE / DOCUMENTS / WORKFLOW TESTS =====';

    SELECT academic_year_name INTO v_year FROM academic.academic_years
     WHERE tenant_id = c_tenant AND school_id = c_school AND COALESCE(is_current, FALSE) LIMIT 1;
    IF v_year IS NULL THEN
        RAISE EXCEPTION 'Fixture missing: school % has no current session.', c_school;
    END IF;
    SELECT logo_url INTO v_logo FROM core.school_profiles
     WHERE tenant_id = c_tenant AND school_id = c_school;
    RAISE NOTICE 'fixture: session=%  logo=%', v_year, v_logo;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- A. Basic profile read and scope ----------------------';

    c := 'a1';
    CALL core.sp_school_admin_basic_profile_manage(
        p_operation => 'GetBasicProfile', p_tenant_id => c_tenant, p_school_id => c_school,
        p_action_user_id => c_user, p_result => c);
    FETCH c INTO r;
    PERFORM pg_temp.chk('A1 GetBasicProfile returns our school', FOUND AND r.school_id = c_school,
                        format('school_name=%s', r.school_name));
    MOVE NEXT FROM c;
    PERFORM pg_temp.chk('A2 ...and exactly one row', NOT FOUND, '');
    CLOSE c;

    -- Our tenant id with another tenant's school id: nothing must come back.
    c := 'a3';
    CALL core.sp_school_admin_basic_profile_manage(
        p_operation => 'GetBasicProfile', p_tenant_id => c_tenant, p_school_id => o_school,
        p_action_user_id => c_user, p_result => c);
    FETCH c INTO r;
    PERFORM pg_temp.chk('A3 another tenant''s school is not readable', NOT FOUND, '');
    CLOSE c;

    BEGIN
        c := 'a4';
        CALL core.sp_school_admin_basic_profile_manage(
            p_operation => 'GetBasicProfile', p_tenant_id => 1, p_school_id => c_school,
            p_action_user_id => c_user, p_result => c);
        PERFORM pg_temp.chk('A4 platform tenant (1) refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('A4 platform tenant (1) refused', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'a5';
        CALL core.sp_school_admin_basic_profile_manage(
            p_operation => 'GetBasicProfile', p_tenant_id => c_tenant, p_school_id => 0,
            p_action_user_id => c_user, p_result => c);
        PERFORM pg_temp.chk('A5 school id 0 refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('A5 school id 0 refused', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'a6';
        CALL core.sp_school_admin_basic_profile_manage(
            p_operation => 'DeleteBasicProfile', p_tenant_id => c_tenant, p_school_id => c_school,
            p_action_user_id => c_user, p_result => c);
        PERFORM pg_temp.chk('A6 unknown operation refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('A6 unknown operation refused', TRUE, SQLERRM);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- B. Basic profile save round-trip ---------------------';

    -- Something on school_settings the profile page never shows. A profile save
    -- must not touch it (the page does not post these flags).
    UPDATE core.school_settings SET enable_sms = TRUE
     WHERE tenant_id = c_tenant AND school_id = c_school;

    c := 'b1';
    CALL core.sp_school_admin_basic_profile_manage(
        p_operation => 'UpdateBasicProfile', p_tenant_id => c_tenant, p_school_id => c_school,
        p_action_user_id => c_user,
        p_display_name => 'ZZ Roman Public School',
        p_registration_number => 'REG/HR/2001/77',
        p_affiliation_number => '530123',
        p_board_id => 2,                    -- the page cannot change the board
        p_school_type_id => 99,             -- ...or the school type
        p_established_year => 1995,
        p_website => 'https://romanpublic.edu.in',
        p_logo_url => NULL,                 -- no new logo picked
        p_address_line1 => 'Plot #12, ''A'' Block, नई सड़क',
        p_address_line2 => 'Near Water Tank',
        p_city => 'Gurugram', p_district => 'Gurugram', p_state => 'Haryana',
        p_pincode => '122001',
        p_contact_name => 'Anita Sharma', p_designation => 'Principal',
        p_contact_email => 'office@romanpublic.edu.in',
        p_phone => '9876543210', p_alternate_phone => '8765432109',
        p_enable_sms => FALSE,
        p_country_id => 1, p_state_id => 8, p_district_id => 199,
        p_result => c);
    FETCH c INTO r;
    PERFORM pg_temp.chk('B1 save reports success with our school id',
                        r.success AND r.school_id = c_school, format('%s', r.message));
    CLOSE c;

    c := 'b2';
    CALL core.sp_school_admin_basic_profile_manage(
        p_operation => 'GetBasicProfile', p_tenant_id => c_tenant, p_school_id => c_school,
        p_action_user_id => c_user, p_result => c);
    FETCH c INTO r;
    CLOSE c;
    PERFORM pg_temp.chk('B2 display name round-trips', r.display_name = 'ZZ Roman Public School', r.display_name);
    PERFORM pg_temp.chk('B3 registration number round-trips', r.registration_number = 'REG/HR/2001/77', r.registration_number);
    PERFORM pg_temp.chk('B4 affiliation number round-trips', r.affiliation_number = '530123', r.affiliation_number);
    PERFORM pg_temp.chk_eq('B5 established year round-trips', r.established_year, 1995);
    PERFORM pg_temp.chk('B6 website round-trips', r.website = 'https://romanpublic.edu.in', r.website);
    PERFORM pg_temp.chk('B7 address with quotes and Hindi round-trips exactly',
                        r.address_line1 = 'Plot #12, ''A'' Block, नई सड़क', r.address_line1);
    PERFORM pg_temp.chk('B8 hidden address line 2 round-trips', r.address_line2 = 'Near Water Tank', r.address_line2);
    PERFORM pg_temp.chk('B9 city / district / state text round-trip',
                        r.city = 'Gurugram' AND r.district = 'Gurugram' AND r.state = 'Haryana',
                        format('%s / %s / %s', r.city, r.district, r.state));
    PERFORM pg_temp.chk('B10 state and district ids round-trip',
                        r.state_id = 8 AND r.district_id = 199, format('%s / %s', r.state_id, r.district_id));
    PERFORM pg_temp.chk('B11 pincode round-trips', r.pincode = '122001', r.pincode);
    PERFORM pg_temp.chk('B12 contact name and designation round-trip',
                        r.contact_name = 'Anita Sharma' AND r.designation = 'Principal',
                        format('%s / %s', r.contact_name, r.designation));
    PERFORM pg_temp.chk('B13 email, phone, alternate phone round-trip',
                        r.email = 'office@romanpublic.edu.in' AND r.phone = '9876543210'
                        AND r.alternate_phone = '8765432109',
                        format('%s / %s / %s', r.email, r.phone, r.alternate_phone));
    PERFORM pg_temp.chk('B14 no logo picked keeps the existing logo',
                        r.logo_url IS NOT DISTINCT FROM v_logo, format('logo=%s', r.logo_url));
    PERFORM pg_temp.chk_eq('B15 board is not changed by this page', r.board_id, 1);
    PERFORM pg_temp.chk('B16 school type is not changed by this page',
                        r.school_type_id IS DISTINCT FROM 99, format('school_type_id=%s', r.school_type_id));
    PERFORM pg_temp.chk('B17 SMS flag on school_settings left alone', r.enable_sms IS TRUE,
                        format('enable_sms=%s', r.enable_sms));

    -- A new logo replaces the old one.
    c := 'b18';
    CALL core.sp_school_admin_basic_profile_manage(
        p_operation => 'UpdateBasicProfile', p_tenant_id => c_tenant, p_school_id => c_school,
        p_action_user_id => c_user, p_display_name => 'ZZ Roman Public School',
        p_logo_url => '/uploads/schools/24/34/logo_zz.png',
        p_address_line1 => 'Plot 12', p_city => 'Gurugram', p_state => 'Haryana',
        p_district => 'Gurugram', p_pincode => '122001', p_contact_name => 'Anita Sharma',
        p_phone => '9876543210', p_state_id => 8, p_district_id => 199, p_result => c);
    CLOSE c;
    SELECT logo_url INTO v_txt FROM core.school_profiles WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk('B18 an uploaded logo replaces the old one',
                        v_txt = '/uploads/schools/24/34/logo_zz.png', v_txt);

    -- Optional fields can be cleared.
    CALL pg_temp.bp_save(c_tenant, c_school, p_display => NULL, p_est => NULL, p_website => NULL);
    SELECT s.display_name, sp.established_year::text INTO v_txt, v_other
      FROM core.schools s JOIN core.school_profiles sp USING (tenant_id, school_id)
     WHERE s.tenant_id = c_tenant AND s.school_id = c_school;
    PERFORM pg_temp.chk('B19 display name and established year can be cleared',
                        v_txt IS NULL AND v_other IS NULL, format('%s / %s', v_txt, v_other));

    -- Saving twice never makes a second address / contact / profile row.
    CALL pg_temp.bp_save(c_tenant, c_school);
    CALL pg_temp.bp_save(c_tenant, c_school);
    SELECT (SELECT COUNT(*) FROM core.school_profiles  WHERE tenant_id = c_tenant AND school_id = c_school)
         + (SELECT COUNT(*) FROM core.school_addresses WHERE tenant_id = c_tenant AND school_id = c_school AND address_type_id = 1)
         + (SELECT COUNT(*) FROM core.school_contacts  WHERE tenant_id = c_tenant AND school_id = c_school AND contact_type_id = 1)
      INTO v_n;
    PERFORM pg_temp.chk_eq('B20 re-save keeps one profile, address, contact row', v_n, 3);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- C. What the database refuses on a profile save ------';

    BEGIN
        CALL pg_temp.bp_save(c_tenant, c_school, p_line1 => NULL);
        PERFORM pg_temp.chk('C1 missing address line 1 refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C1 missing address line 1 refused', TRUE, SQLERRM);
    END;

    BEGIN
        CALL pg_temp.bp_save(c_tenant, c_school, p_city => NULL);
        PERFORM pg_temp.chk('C2 missing city refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C2 missing city refused', TRUE, SQLERRM);
    END;

    BEGIN
        CALL pg_temp.bp_save(c_tenant, c_school, p_state => NULL);
        PERFORM pg_temp.chk('C3 missing state refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C3 missing state refused', TRUE, SQLERRM);
    END;

    BEGIN
        CALL pg_temp.bp_save(c_tenant, c_school, p_pincode => NULL);
        PERFORM pg_temp.chk('C4 missing pincode refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C4 missing pincode refused', TRUE, SQLERRM);
    END;

    BEGIN
        CALL pg_temp.bp_save(c_tenant, c_school, p_pincode => '12200');
        PERFORM pg_temp.chk('C5 5-digit pincode refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C5 5-digit pincode refused', TRUE, SQLERRM);
    END;

    BEGIN
        CALL pg_temp.bp_save(c_tenant, c_school, p_pincode => '12A001');
        PERFORM pg_temp.chk('C6 pincode with a letter refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C6 pincode with a letter refused', TRUE, SQLERRM);
    END;

    BEGIN
        CALL pg_temp.bp_save(c_tenant, c_school, p_pincode => '1220011');
        PERFORM pg_temp.chk('C7 7-digit pincode refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C7 7-digit pincode refused', TRUE, SQLERRM);
    END;

    BEGIN
        CALL pg_temp.bp_save(c_tenant, c_school, p_contact => NULL);
        PERFORM pg_temp.chk('C8 missing contact name refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C8 missing contact name refused', TRUE, SQLERRM);
    END;

    BEGIN
        CALL pg_temp.bp_save(c_tenant, c_school, p_phone => NULL);
        PERFORM pg_temp.chk('C9 missing phone refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C9 missing phone refused', TRUE, SQLERRM);
    END;

    BEGIN
        CALL pg_temp.bp_save(c_tenant, c_school, p_est => 1799);
        PERFORM pg_temp.chk('C10 established year 1799 refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C10 established year 1799 refused', TRUE, SQLERRM);
    END;

    BEGIN
        CALL pg_temp.bp_save(c_tenant, c_school, p_est => 2101);
        PERFORM pg_temp.chk('C11 established year 2101 refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C11 established year 2101 refused', TRUE, SQLERRM);
    END;

    CALL pg_temp.bp_save(c_tenant, c_school, p_est => 1800);
    SELECT established_year INTO v_n FROM core.school_profiles WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk_eq('C12 established year 1800 (lower bound) accepted', v_n, 1800);

    CALL pg_temp.bp_save(c_tenant, c_school, p_est => 2100);
    SELECT established_year INTO v_n FROM core.school_profiles WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk_eq('C13 established year 2100 (upper bound) accepted', v_n, 2100);

    BEGIN
        CALL pg_temp.bp_save(c_tenant, c_school, p_website => 'https://' || repeat('w', 193) || '.in');
        PERFORM pg_temp.chk('C14 website over 200 chars refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C14 website over 200 chars refused', TRUE, SQLERRM);
    END;

    -- Exactly at the model limit (200) must still save.
    CALL pg_temp.bp_save(c_tenant, c_school, p_website => 'https://' || repeat('w', 189) || '.in');
    SELECT length(website) INTO v_n FROM core.school_profiles WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk_eq('C15 website of exactly 200 chars accepted', v_n, 200);

    BEGIN
        CALL pg_temp.bp_save(c_tenant, c_school, p_regno => repeat('R', 101));
        PERFORM pg_temp.chk('C16 registration number over 100 chars refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C16 registration number over 100 chars refused', TRUE, SQLERRM);
    END;

    BEGIN
        CALL pg_temp.bp_save(c_tenant, c_school, p_display => repeat('D', 201));
        PERFORM pg_temp.chk('C17 display name over 200 chars refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C17 display name over 200 chars refused', TRUE, SQLERRM);
    END;

    BEGIN
        CALL pg_temp.bp_save(c_tenant, c_school, p_line1 => repeat('A', 251));
        PERFORM pg_temp.chk('C18 address line over 250 chars refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C18 address line over 250 chars refused', TRUE, SQLERRM);
    END;

    BEGIN
        CALL pg_temp.bp_save(c_tenant, c_school, p_contact => repeat('N', 151));
        PERFORM pg_temp.chk('C19 contact name over 150 chars refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C19 contact name over 150 chars refused', TRUE, SQLERRM);
    END;

    BEGIN
        CALL pg_temp.bp_save(c_tenant, c_school, p_email => repeat('e', 141) || '@school.in');
        PERFORM pg_temp.chk('C20 email over 150 chars refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C20 email over 150 chars refused', TRUE, SQLERRM);
    END;

    BEGIN
        CALL pg_temp.bp_save(c_tenant, c_school, p_city => repeat('C', 101));
        PERFORM pg_temp.chk('C21 city over 100 chars refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C21 city over 100 chars refused', TRUE, SQLERRM);
    END;

    BEGIN
        CALL pg_temp.bp_save(c_tenant, c_school, p_state_id => 999999);
        PERFORM pg_temp.chk('C22 a state id that does not exist refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C22 a state id that does not exist refused', TRUE, SQLERRM);
    END;

    -- A refused save leaves the last good profile untouched.
    SELECT pincode INTO v_txt FROM core.school_addresses
     WHERE tenant_id = c_tenant AND school_id = c_school AND address_type_id = 1;
    PERFORM pg_temp.chk('C23 refused saves left the address intact', v_txt = '122001', v_txt);

    BEGIN
        CALL pg_temp.bp_save(1, 0);
        PERFORM pg_temp.chk('C24 platform scope profile write refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C24 platform scope profile write refused', TRUE, SQLERRM);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- D. Address geography consistency --------------------';

    -- The school moves to Delhi. District is optional on the page, so the admin
    -- picks the state and leaves district on "Select District". The old
    -- Gurugram (Haryana) district must not survive under a Delhi state.
    CALL pg_temp.bp_save(c_tenant, c_school, p_state => 'Delhi', p_state_id => 32,
                         p_city => 'New Delhi', p_pincode => '110001',
                         p_district => NULL, p_district_id => NULL);
    SELECT a.state_id, a.district_id, d.state_id AS d_state INTO r
      FROM core.school_addresses a LEFT JOIN config.districts d ON d.district_id = a.district_id
     WHERE a.tenant_id = c_tenant AND a.school_id = c_school AND a.address_type_id = 1;
    PERFORM pg_temp.chk('D1 state changed, old-state district not kept',
                        r.district_id IS NULL OR r.d_state = r.state_id,
                        format('state_id=%s district_id=%s (district belongs to state %s)',
                               r.state_id, r.district_id, r.d_state));

    -- Back in Haryana with Gurugram, then the admin clears the district.
    CALL pg_temp.bp_save(c_tenant, c_school);
    CALL pg_temp.bp_save(c_tenant, c_school, p_district => NULL, p_district_id => NULL);
    SELECT district, district_id INTO r FROM core.school_addresses
     WHERE tenant_id = c_tenant AND school_id = c_school AND address_type_id = 1;
    PERFORM pg_temp.chk('D2 clearing district clears the id with the text',
                        r.district IS NULL AND r.district_id IS NULL,
                        format('district text=%s, district_id=%s', r.district, r.district_id));

    -- State Board (requires_state) granted by Uttar Pradesh: the address state
    -- follows the board whatever the post says.
    UPDATE core.school_profiles SET board_id = 3, board_state_id = 26
     WHERE tenant_id = c_tenant AND school_id = c_school;

    CALL pg_temp.bp_save(c_tenant, c_school);   -- posts Haryana / Gurugram
    SELECT state, state_id, district_id INTO r FROM core.school_addresses
     WHERE tenant_id = c_tenant AND school_id = c_school AND address_type_id = 1;
    PERFORM pg_temp.chk('D3 state board: address state forced to the board state',
                        r.state_id = 26 AND r.state = 'Uttar Pradesh',
                        format('%s (%s)', r.state, r.state_id));
    PERFORM pg_temp.chk('D4 ...and a district from another state is dropped',
                        r.district_id IS NULL, format('district_id=%s', r.district_id));

    CALL pg_temp.bp_save(c_tenant, c_school, p_state => 'Uttar Pradesh', p_state_id => 26,
                         p_district => 'Kushinagar', p_district_id => 660);
    SELECT district_id INTO v_n FROM core.school_addresses
     WHERE tenant_id = c_tenant AND school_id = c_school AND address_type_id = 1;
    PERFORM pg_temp.chk_eq('D5 ...a district inside the board state is kept', v_n, 660);

    c := 'd6';
    CALL core.sp_school_admin_basic_profile_manage(
        p_operation => 'GetBasicProfile', p_tenant_id => c_tenant, p_school_id => c_school,
        p_action_user_id => c_user, p_result => c);
    FETCH c INTO r;
    CLOSE c;
    PERFORM pg_temp.chk('D6 Get flags the state lock and names the board state',
                        r.board_requires_state AND r.board_name LIKE '%(Uttar Pradesh)',
                        format('%s, lock=%s', r.board_name, r.board_requires_state));

    -- Back to CBSE: a national board leaves the state free.
    UPDATE core.school_profiles SET board_id = 1, board_state_id = NULL
     WHERE tenant_id = c_tenant AND school_id = c_school;
    CALL pg_temp.bp_save(c_tenant, c_school, p_state => 'Delhi', p_state_id => 32,
                         p_district => NULL, p_district_id => NULL, p_pincode => '110001');
    SELECT state_id INTO v_n FROM core.school_addresses
     WHERE tenant_id = c_tenant AND school_id = c_school AND address_type_id = 1;
    PERFORM pg_temp.chk_eq('D7 national board: the chosen state is stored', v_n, 32);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- E. Documents & Formats ------------------------------';

    -- Receipt format.
    c := 'e1';
    CALL core.sp_school_receipt_format_manage('Save', c_tenant, c_school, c_user, 'A5', c);
    CLOSE c;
    c := 'e1g';
    CALL core.sp_school_receipt_format_manage('Get', c_tenant, c_school, c_user, NULL, c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('E1 receipt format A5 round-trips', r.receipt_format = 'A5', r.receipt_format);

    c := 'e2';
    CALL core.sp_school_receipt_format_manage('Save', c_tenant, c_school, c_user, 'Thermal', c);
    FETCH c INTO r; CLOSE c;
    SELECT receipt_format INTO v_txt FROM core.school_settings WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk('E2 receipt format Thermal round-trips', v_txt = 'Thermal' AND r.success, v_txt);

    -- An unknown value is coerced to the default, never stored as junk.
    c := 'e3';
    CALL core.sp_school_receipt_format_manage('Save', c_tenant, c_school, c_user, 'Letter', c);
    CLOSE c;
    SELECT receipt_format INTO v_txt FROM core.school_settings WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk('E3 unknown receipt format falls back to A4', v_txt = 'A4', v_txt);

    c := 'e4';
    CALL core.sp_school_receipt_format_manage('Save', c_tenant, c_school, c_user, 'a5', c);
    CLOSE c;
    SELECT receipt_format INTO v_txt FROM core.school_settings WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk('E4 wrong-case "a5" is not stored as is', v_txt IN ('A4','A5'), v_txt);

    c := 'e5';
    CALL core.sp_school_receipt_format_manage('Save', c_tenant, c_school, c_user, NULL, c);
    CLOSE c;
    SELECT receipt_format INTO v_txt FROM core.school_settings WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk('E5 missing receipt format saves the default A4', v_txt = 'A4', v_txt);

    -- TC format.
    c := 'e6';
    CALL core.sp_school_tc_format_manage('Save', c_tenant, c_school, c_user, 'Board', c);
    CLOSE c;
    c := 'e6g';
    CALL core.sp_school_tc_format_manage('Get', c_tenant, c_school, c_user, NULL, c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('E6 TC format Board round-trips', r.tc_format = 'Board', r.tc_format);

    c := 'e7';
    CALL core.sp_school_tc_format_manage('Save', c_tenant, c_school, c_user, 'Standard', c);
    CLOSE c;
    SELECT tc_format INTO v_txt FROM core.school_settings WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk('E7 unknown TC format falls back to Basic', v_txt = 'Basic', v_txt);

    -- ID card format.
    c := 'e8';
    CALL core.sp_school_id_card_format_manage('Save', c_tenant, c_school, c_user, 'Landscape', c);
    CLOSE c;
    c := 'e8g';
    CALL core.sp_school_id_card_format_manage('Get', c_tenant, c_school, c_user, NULL, c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('E8 ID card Landscape round-trips', r.id_card_format = 'Landscape', r.id_card_format);

    c := 'e9';
    CALL core.sp_school_id_card_format_manage('Save', c_tenant, c_school, c_user, '<script>', c);
    CLOSE c;
    SELECT id_card_format INTO v_txt FROM core.school_settings WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk('E9 unknown ID card layout falls back to Portrait', v_txt = 'Portrait', v_txt);

    -- The three are independent: saving one leaves the other two alone.
    c := 'e10a'; CALL core.sp_school_receipt_format_manage('Save', c_tenant, c_school, c_user, 'A5', c); CLOSE c;
    c := 'e10b'; CALL core.sp_school_tc_format_manage('Save', c_tenant, c_school, c_user, 'Board', c); CLOSE c;
    c := 'e10c'; CALL core.sp_school_id_card_format_manage('Save', c_tenant, c_school, c_user, 'Landscape', c); CLOSE c;
    c := 'e10d'; CALL core.sp_school_tc_format_manage('Save', c_tenant, c_school, c_user, 'Basic', c); CLOSE c;
    SELECT receipt_format || '/' || tc_format || '/' || id_card_format INTO v_txt
      FROM core.school_settings WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk('E10 saving TC does not touch receipt or ID card', v_txt = 'A5/Basic/Landscape', v_txt);

    SELECT enable_sms INTO v_b FROM core.school_settings WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk('E11 format saves leave other school settings alone', v_b IS TRUE,
                        format('enable_sms=%s', v_b));

    -- A school with no settings row yet: Get returns nothing (the service then
    -- shows the default) and the first Save creates exactly one row.
    DELETE FROM core.school_settings WHERE tenant_id = c_tenant AND school_id = c_school;
    c := 'e12';
    CALL core.sp_school_receipt_format_manage('Get', c_tenant, c_school, c_user, NULL, c);
    FETCH c INTO r;
    PERFORM pg_temp.chk('E12 no settings row: Get returns no row (default applies)', NOT FOUND, '');
    CLOSE c;

    c := 'e13'; CALL core.sp_school_id_card_format_manage('Save', c_tenant, c_school, c_user, 'Landscape', c); CLOSE c;
    c := 'e13b'; CALL core.sp_school_id_card_format_manage('Save', c_tenant, c_school, c_user, 'Landscape', c); CLOSE c;
    SELECT COUNT(*) INTO v_n FROM core.school_settings WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk_eq('E13 first save creates one row, re-save keeps one', v_n, 1);

    SELECT receipt_format || '/' || tc_format INTO v_txt
      FROM core.school_settings WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk('E14 ...the other formats start at their defaults', v_txt = 'A4/Basic', v_txt);

    BEGIN
        c := 'e15'; CALL core.sp_school_receipt_format_manage('Save', 1, 0, c_user, 'A5', c);
        PERFORM pg_temp.chk('E15 platform scope receipt format refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('E15 platform scope receipt format refused', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'e16'; CALL core.sp_school_tc_format_manage('Save', c_tenant, 0, c_user, 'Board', c);
        PERFORM pg_temp.chk('E16 school id 0 TC format refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('E16 school id 0 TC format refused', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'e17'; CALL core.sp_school_id_card_format_manage('Get', 1, c_school, c_user, NULL, c);
        PERFORM pg_temp.chk('E17 platform scope ID card read refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('E17 platform scope ID card read refused', TRUE, SQLERRM);
    END;

    -- Our saves must not change the other school's formats.
    SELECT receipt_format || '/' || tc_format || '/' || id_card_format INTO v_txt
      FROM core.school_settings WHERE tenant_id = o_tenant AND school_id = o_school;
    PERFORM pg_temp.chk('E18 the other school''s formats are untouched', v_txt = 'A4/Basic/Portrait', v_txt);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- F. Admission workflow settings ----------------------';

    DELETE FROM core.school_admission_workflow_settings WHERE tenant_id = c_tenant AND school_id = c_school;
    c := 'f1';
    CALL core.sp_school_admin_admission_workflow_manage('GetAdmissionWorkflow', c_tenant, c_school, c_user,
         p_result => c);
    FETCH c INTO r;
    PERFORM pg_temp.chk('F1 never-saved school: Get returns no row (defaults)', NOT FOUND, '');
    CLOSE c;

    -- Sunrise-style setup: registration on and mandatory, with a fee, auto
    -- numbers "SPS/", collect at admission, deposit on, no buses, no store.
    c := 'f2';
    CALL core.sp_school_admin_admission_workflow_manage('SaveAdmissionWorkflow', c_tenant, c_school, c_user,
         TRUE, TRUE, TRUE, TRUE, 'SPS/', TRUE, TRUE, FALSE, TRUE, FALSE, TRUE, c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('F2 save reports success', r.success, r.message);

    c := 'f3';
    CALL core.sp_school_admin_admission_workflow_manage('GetAdmissionWorkflow', c_tenant, c_school, c_user,
         p_result => c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('F3 registration on / required / fee round-trip',
                        r.enable_registration AND r.registration_required_before_admission AND r.enable_registration_fee,
                        format('%s/%s/%s', r.enable_registration, r.registration_required_before_admission, r.enable_registration_fee));
    PERFORM pg_temp.chk('F4 auto-number and prefix round-trip',
                        r.auto_generate_registration_number AND r.registration_number_prefix = 'SPS/',
                        format('%s "%s"', r.auto_generate_registration_number, r.registration_number_prefix));
    PERFORM pg_temp.chk('F5 collect-at-admission and security deposit round-trip',
                        r.collect_fee_at_admission AND r.enable_security_fee,
                        format('%s/%s', r.collect_fee_at_admission, r.enable_security_fee));
    PERFORM pg_temp.chk('F6 module toggles round-trip (T off, E on, I off, P on)',
                        NOT r.enable_transport AND r.enable_exams AND NOT r.enable_inventory AND r.enable_payroll,
                        format('%s/%s/%s/%s', r.enable_transport, r.enable_exams, r.enable_inventory, r.enable_payroll));

    -- Registration off: its children cannot stay on (a crafted post sends them on).
    c := 'f7';
    CALL core.sp_school_admin_admission_workflow_manage('SaveAdmissionWorkflow', c_tenant, c_school, c_user,
         FALSE, TRUE, TRUE, TRUE, 'SPS/', FALSE, FALSE, TRUE, TRUE, TRUE, TRUE, c);
    CLOSE c;
    SELECT * INTO r FROM core.school_admission_workflow_settings WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk('F7 registration off clears required + fee',
                        NOT r.enable_registration AND NOT r.registration_required_before_admission
                        AND NOT r.enable_registration_fee,
                        format('%s/%s/%s', r.enable_registration, r.registration_required_before_admission, r.enable_registration_fee));
    PERFORM pg_temp.chk('F8 ...but the prefix and auto-number survive for later',
                        r.auto_generate_registration_number AND r.registration_number_prefix = 'SPS/',
                        r.registration_number_prefix);

    c := 'f9';
    CALL core.sp_school_admin_admission_workflow_manage('SaveAdmissionWorkflow', c_tenant, c_school, c_user,
         TRUE, FALSE, FALSE, TRUE, '    ', FALSE, FALSE, TRUE, TRUE, TRUE, TRUE, c);
    CLOSE c;
    SELECT registration_number_prefix INTO v_txt FROM core.school_admission_workflow_settings
     WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk('F9 blank prefix falls back to REG-', v_txt = 'REG-', format('"%s"', v_txt));

    c := 'f10';
    CALL core.sp_school_admin_admission_workflow_manage('SaveAdmissionWorkflow', c_tenant, c_school, c_user,
         TRUE, FALSE, FALSE, TRUE, '  SPS/26-27/  ', FALSE, FALSE, TRUE, TRUE, TRUE, TRUE, c);
    CLOSE c;
    SELECT registration_number_prefix INTO v_txt FROM core.school_admission_workflow_settings
     WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk('F10 padded prefix with / and - stored trimmed', v_txt = 'SPS/26-27/', format('"%s"', v_txt));

    c := 'f11';
    CALL core.sp_school_admin_admission_workflow_manage('SaveAdmissionWorkflow', c_tenant, c_school, c_user,
         TRUE, FALSE, FALSE, TRUE, repeat('P', 20), FALSE, FALSE, TRUE, TRUE, TRUE, TRUE, c);
    CLOSE c;
    SELECT length(registration_number_prefix) INTO v_n FROM core.school_admission_workflow_settings
     WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk_eq('F11 prefix of exactly 20 chars accepted', v_n, 20);

    BEGIN
        c := 'f12';
        CALL core.sp_school_admin_admission_workflow_manage('SaveAdmissionWorkflow', c_tenant, c_school, c_user,
             TRUE, FALSE, FALSE, TRUE, repeat('P', 21), FALSE, FALSE, TRUE, TRUE, TRUE, TRUE, c);
        PERFORM pg_temp.chk('F12 prefix of 21 chars refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('F12 prefix of 21 chars refused', TRUE, SQLERRM);
    END;

    SELECT COUNT(*) INTO v_n FROM core.school_admission_workflow_settings
     WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk_eq('F13 many saves, still one workflow row', v_n, 1);

    -- A soft-deleted row is revived by the next save, not left hidden.
    UPDATE core.school_admission_workflow_settings SET is_deleted = TRUE
     WHERE tenant_id = c_tenant AND school_id = c_school;
    c := 'f14';
    CALL core.sp_school_admin_admission_workflow_manage('SaveAdmissionWorkflow', c_tenant, c_school, c_user,
         TRUE, TRUE, FALSE, TRUE, 'SPS/', TRUE, FALSE, TRUE, TRUE, TRUE, TRUE, c);
    CLOSE c;
    c := 'f14g';
    CALL core.sp_school_admin_admission_workflow_manage('GetAdmissionWorkflow', c_tenant, c_school, c_user,
         p_result => c);
    FETCH c INTO r;
    PERFORM pg_temp.chk('F14 save revives a soft-deleted workflow row',
                        FOUND AND r.registration_required_before_admission, '');
    CLOSE c;

    BEGIN
        c := 'f15';
        CALL core.sp_school_admin_admission_workflow_manage('SaveAdmissionWorkflow', 1, 0, c_user,
             TRUE, TRUE, TRUE, TRUE, 'X', TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, c);
        PERFORM pg_temp.chk('F15 platform scope workflow save refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('F15 platform scope workflow save refused', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'f16';
        CALL core.sp_school_admin_admission_workflow_manage('GetAdmissionWorkflow', c_tenant, 0, c_user,
             p_result => c);
        PERFORM pg_temp.chk('F16 school id 0 workflow read refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('F16 school id 0 workflow read refused', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'f17';
        CALL core.sp_school_admin_admission_workflow_manage('ResetWorkflow', c_tenant, c_school, c_user,
             p_result => c);
        PERFORM pg_temp.chk('F17 unknown workflow operation refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('F17 unknown workflow operation refused', TRUE, SQLERRM);
    END;

    -- The other school's workflow is untouched by everything above.
    SELECT * INTO r FROM core.school_admission_workflow_settings WHERE tenant_id = o_tenant AND school_id = o_school;
    PERFORM pg_temp.chk('F18 the other school''s workflow is untouched',
                        r.enable_registration AND r.registration_number_prefix = 'REG-' AND NOT r.enable_transport,
                        format('reg=%s prefix=%s transport=%s', r.enable_registration,
                               r.registration_number_prefix, r.enable_transport));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- G. Downstream: registration numbering ---------------';

    -- The workflow row now says auto-number with prefix "SPS/". EnquiryController
    -- passes exactly those two values into sp_enquiry_register.
    DECLARE
        v_e1 integer; v_e2 integer; v_e3 integer; v_e4 integer;
        v_auto boolean; v_prefix varchar; v_r1 text; v_r2 text;
    BEGIN
        SELECT auto_generate_registration_number, registration_number_prefix INTO v_auto, v_prefix
          FROM core.school_admission_workflow_settings WHERE tenant_id = c_tenant AND school_id = c_school;

        INSERT INTO core.enquiries(tenant_id, school_id, student_name, class_name, session, mobile)
        VALUES (c_tenant, c_school, 'ZZ Reg Kid One', '1', v_year, '9000000001') RETURNING enquiry_id INTO v_e1;
        INSERT INTO core.enquiries(tenant_id, school_id, student_name, class_name, session, mobile)
        VALUES (c_tenant, c_school, 'ZZ Reg Kid Two', '1', v_year, '9000000002') RETURNING enquiry_id INTO v_e2;
        INSERT INTO core.enquiries(tenant_id, school_id, student_name, class_name, session, mobile)
        VALUES (c_tenant, c_school, 'ZZ Reg Kid Three', '1', v_year, '9000000003') RETURNING enquiry_id INTO v_e3;
        INSERT INTO core.enquiries(tenant_id, school_id, student_name, class_name, session, mobile)
        VALUES (c_tenant, c_school, 'ZZ Reg Kid Four', '1', v_year, '9000000004') RETURNING enquiry_id INTO v_e4;

        c := 'g1';
        CALL core.sp_enquiry_register(c_tenant, c_school, c_user, v_e1, NULL, NULL, FALSE, v_auto, v_prefix, c);
        FETCH c INTO r; CLOSE c;
        v_r1 := r.registration_number;
        PERFORM pg_temp.chk('G1 auto number carries the workflow prefix', v_r1 LIKE 'SPS/%', v_r1);

        c := 'g2';
        CALL core.sp_enquiry_register(c_tenant, c_school, c_user, v_e2, NULL, NULL, FALSE, v_auto, v_prefix, c);
        FETCH c INTO r; CLOSE c;
        v_r2 := r.registration_number;
        PERFORM pg_temp.chk('G2 next registration gets the next number',
                            v_r2 LIKE 'SPS/%' AND v_r2 <> v_r1, format('%s then %s', v_r1, v_r2));

        c := 'g3';
        CALL core.sp_enquiry_register(c_tenant, c_school, c_user, v_e1, NULL, NULL, TRUE, v_auto, 'NEW-', c);
        FETCH c INTO r; CLOSE c;
        PERFORM pg_temp.chk('G3 re-registering keeps the issued number', r.registration_number = v_r1,
                            r.registration_number);

        SELECT status INTO v_txt FROM core.enquiries WHERE enquiry_id = v_e1;
        PERFORM pg_temp.chk('G4 enquiry moves to "Registration Done" (admission gate)',
                            v_txt = 'Registration Done', v_txt);

        -- Auto-number switched off: a number must be typed.
        BEGIN
            c := 'g5';
            CALL core.sp_enquiry_register(c_tenant, c_school, c_user, v_e3, NULL, NULL, FALSE, FALSE, v_prefix, c);
            PERFORM pg_temp.chk('G5 manual mode without a number refused', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('G5 manual mode without a number refused', TRUE, SQLERRM);
        END;

        c := 'g6';
        CALL core.sp_enquiry_register(c_tenant, c_school, c_user, v_e3, '  MAN-001 ', NULL, FALSE, FALSE, v_prefix, c);
        FETCH c INTO r; CLOSE c;
        PERFORM pg_temp.chk('G6 manual number stored (trimmed)', r.registration_number = 'MAN-001',
                            format('"%s"', r.registration_number));

        -- Two families must not get the same registration number.
        BEGIN
            c := 'g7';
            CALL core.sp_enquiry_register(c_tenant, c_school, c_user, v_e4, 'MAN-001', NULL, FALSE, FALSE, v_prefix, c);
            CLOSE c;
            SELECT COUNT(*) INTO v_n FROM core.enquiries
             WHERE tenant_id = c_tenant AND school_id = c_school AND registration_number = 'MAN-001';
            PERFORM pg_temp.chk('G7 duplicate manual registration number refused', v_n <= 1,
                                format('%s enquiries now share MAN-001', v_n));
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('G7 duplicate manual registration number refused', TRUE, SQLERRM);
        END;
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- H. Inline fee setup (SaveSetupFee as built) ---------';

    -- AdmissionWorkflowController.SaveSetupFee builds: id = existing head of that
    -- kind or 0, the typed name, 'One Time', amount, 'Mandatory', 'Academic',
    -- 'Registration' or 'Admission', refundable = (kind = Security).

    -- THE ONE THAT MATTERS: there is no security-deposit head yet and the admin
    -- types "Admission Fee" as the deposit name. The controller sends id 0, and
    -- the proc upserts by name -- so the school's real Admission Fee head would
    -- turn into a refundable deposit. Run inside a block that is undone.
    DECLARE v_ref boolean; v_refused boolean := FALSE; v_msg text := '';
    BEGIN
        BEGIN
            c := 'h1';
            CALL core.sp_school_admin_fee_head_manage('SaveFeeHead', c_tenant, c_school, c_user,
                 0, 'Admission Fee', 'One Time', 5000, 'Mandatory', 'Academic', 'Admission', TRUE, c);
            CLOSE c;
            SELECT is_refundable INTO v_ref FROM core.school_fee_heads
             WHERE tenant_id = c_tenant AND school_id = c_school AND lower(fee_head_name) = 'admission fee'
               AND COALESCE(is_deleted, FALSE) = FALSE;
            RAISE EXCEPTION 'undo h1';
        EXCEPTION WHEN OTHERS THEN
            IF SQLERRM <> 'undo h1' THEN v_refused := TRUE; v_msg := SQLERRM; END IF;
        END;
        PERFORM pg_temp.chk('H1 deposit named "Admission Fee" does not hijack that head',
                            v_refused OR v_ref IS NOT TRUE,
                            CASE WHEN v_refused THEN v_msg
                                 ELSE format('Admission Fee is_refundable became %s', v_ref) END);
    END;

    -- Same with the registration card and a recurring head name.
    DECLARE v_cp text; v_freq text; v_refused boolean := FALSE; v_msg text := '';
    BEGIN
        BEGIN
            c := 'h2';
            CALL core.sp_school_admin_fee_head_manage('SaveFeeHead', c_tenant, c_school, c_user,
                 0, 'Tution Fee', 'One Time', 300, 'Mandatory', 'Academic', 'Registration', FALSE, c);
            CLOSE c;
            SELECT collection_point, frequency INTO v_cp, v_freq FROM core.school_fee_heads
             WHERE tenant_id = c_tenant AND school_id = c_school AND lower(fee_head_name) = 'tution fee'
               AND COALESCE(is_deleted, FALSE) = FALSE;
            RAISE EXCEPTION 'undo h2';
        EXCEPTION WHEN OTHERS THEN
            IF SQLERRM <> 'undo h2' THEN v_refused := TRUE; v_msg := SQLERRM; END IF;
        END;
        PERFORM pg_temp.chk('H2 reg fee named "Tution Fee" does not hijack tuition',
                            v_refused OR (v_cp = 'Recurring' AND v_freq = 'Monthly'),
                            CASE WHEN v_refused THEN v_msg
                                 ELSE format('Tution Fee became %s / %s', v_cp, v_freq) END);
    END;

    -- Normal use: create the registration fee and the security deposit.
    c := 'h3';
    CALL core.sp_school_admin_fee_head_manage('SaveFeeHead', c_tenant, c_school, c_user,
         0, 'ZZ Registration Fee', 'One Time', 500, 'Mandatory', 'Academic', 'Registration', FALSE, c);
    CLOSE c;
    SELECT fee_head_id, collection_point, is_refundable, default_amount INTO r FROM core.school_fee_heads
     WHERE tenant_id = c_tenant AND school_id = c_school AND fee_head_name = 'ZZ Registration Fee';
    v_id := r.fee_head_id;
    PERFORM pg_temp.chk('H3 registration fee head created at Registration point',
                        r.collection_point = 'Registration' AND NOT r.is_refundable AND r.default_amount = 500,
                        format('id=%s %s %s %s', r.fee_head_id, r.collection_point, r.is_refundable, r.default_amount));

    c := 'h4';
    CALL core.sp_school_admin_fee_head_manage('SaveFeeHead', c_tenant, c_school, c_user,
         v_id, 'ZZ Registration Fee', 'One Time', 750, 'Mandatory', 'Academic', 'Registration', FALSE, c);
    CLOSE c;
    SELECT COUNT(*), MAX(default_amount) INTO v_n, v_txt FROM core.school_fee_heads
     WHERE tenant_id = c_tenant AND school_id = c_school AND collection_point = 'Registration'
       AND COALESCE(is_deleted, FALSE) = FALSE;
    PERFORM pg_temp.chk('H4 editing the amount updates, never duplicates',
                        v_n = 1 AND v_txt::numeric = 750, format('%s head(s), amount %s', v_n, v_txt));

    c := 'h5';
    CALL core.sp_school_admin_fee_head_manage('SaveFeeHead', c_tenant, c_school, c_user,
         0, 'ZZ Security Deposit', 'One Time', 5000, 'Mandatory', 'Academic', 'Admission', TRUE, c);
    CLOSE c;
    SELECT collection_point, is_refundable INTO r FROM core.school_fee_heads
     WHERE tenant_id = c_tenant AND school_id = c_school AND fee_head_name = 'ZZ Security Deposit';
    PERFORM pg_temp.chk('H5 security deposit is a refundable Admission head',
                        r.collection_point = 'Admission' AND r.is_refundable,
                        format('%s refundable=%s', r.collection_point, r.is_refundable));

    -- Renaming the registration head onto an existing head is refused.
    BEGIN
        c := 'h6';
        CALL core.sp_school_admin_fee_head_manage('SaveFeeHead', c_tenant, c_school, c_user,
             v_id, 'Lab Fee', 'One Time', 750, 'Mandatory', 'Academic', 'Registration', FALSE, c);
        PERFORM pg_temp.chk('H6 renaming reg fee onto "Lab Fee" refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('H6 renaming reg fee onto "Lab Fee" refused', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'h7';
        CALL core.sp_school_admin_fee_head_manage('SaveFeeHead', c_tenant, c_school, c_user,
             v_id, repeat('N', 81), 'One Time', 750, 'Mandatory', 'Academic', 'Registration', FALSE, c);
        PERFORM pg_temp.chk('H7 fee name over 80 chars refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('H7 fee name over 80 chars refused', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'h8';
        CALL core.sp_school_admin_fee_head_manage('SaveFeeHead', c_tenant, c_school, c_user,
             v_id, 'ZZ Registration Fee', 'One Time', 10000000000, 'Mandatory', 'Academic', 'Registration', FALSE, c);
        PERFORM pg_temp.chk('H8 amount beyond numeric(12,2) refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('H8 amount beyond numeric(12,2) refused', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'h9';
        CALL core.sp_school_admin_fee_head_manage('SaveFeeHead', c_tenant, c_school, c_user,
             v_id, 'ZZ Registration Fee', 'One Time', -1, 'Mandatory', 'Academic', 'Registration', FALSE, c);
        PERFORM pg_temp.chk('H9 negative amount refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('H9 negative amount refused', TRUE, SQLERRM);
    END;

    -- The head was switched off in the Fee Head master. The workflow card still
    -- shows it ("Current: Rs 750 -- editing updates it"), so saving an amount
    -- there should make it chargeable again; otherwise registration charges 0.
    c := 'h10t';
    CALL core.sp_school_admin_fee_head_manage('ToggleFeeHeadStatus', c_tenant, c_school, c_user,
         v_id, p_result => c);
    CLOSE c;
    c := 'h10';
    CALL core.sp_school_admin_fee_head_manage('SaveFeeHead', c_tenant, c_school, c_user,
         v_id, 'ZZ Registration Fee', 'One Time', 900, 'Mandatory', 'Academic', 'Registration', FALSE, c);
    CLOSE c;
    -- The Fee Head master's edit keeps a head's active flag, so SaveSetupFee
    -- (AdmissionWorkflowController) toggles an inactive head back on after the
    -- save. Make the same two calls the controller makes.
    SELECT is_active INTO v_b FROM core.school_fee_heads WHERE fee_head_id = v_id;
    IF v_b IS NOT TRUE THEN
        c := 'h10r';
        CALL core.sp_school_admin_fee_head_manage('ToggleFeeHeadStatus', c_tenant, c_school, c_user,
             v_id, p_result => c);
        CLOSE c;
    END IF;
    SELECT is_active INTO v_b FROM core.school_fee_heads WHERE fee_head_id = v_id;
    PERFORM pg_temp.chk('H10 saving an amount on the card re-activates the head', v_b IS TRUE,
                        format('is_active=%s after setting 900 on the card', v_b));

    -- Remove from the card (DeleteSetupFee -> cascade delete).
    c := 'h11';
    CALL core.sp_fee_head_delete_cascade(c_tenant, c_school, c_user, v_id, c);
    FETCH c INTO r; CLOSE c;
    SELECT COUNT(*) INTO v_n FROM core.school_fee_heads
     WHERE fee_head_id = v_id AND COALESCE(is_deleted, FALSE) = FALSE;
    PERFORM pg_temp.chk('H11 remove deletes the registration head', r.success AND v_n = 0, r.message);

    -- Another tenant cannot delete our deposit through this endpoint's proc.
    SELECT fee_head_id INTO v_id FROM core.school_fee_heads
     WHERE tenant_id = c_tenant AND school_id = c_school AND fee_head_name = 'ZZ Security Deposit';
    BEGIN
        c := 'h12';
        CALL core.sp_fee_head_delete_cascade(o_tenant, o_school, c_user, v_id, c);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    SELECT COUNT(*) INTO v_n FROM core.school_fee_heads
     WHERE fee_head_id = v_id AND COALESCE(is_deleted, FALSE) = FALSE;
    PERFORM pg_temp.chk_eq('H12 another school could not delete our deposit', v_n, 1);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- I. Tenant isolation and permission keys -------------';

    -- Claims supply tenant and school separately. If they ever disagree (our
    -- tenant, another tenant's school) the procs must refuse rather than write
    -- rows under a pair that does not exist in core.schools.
    BEGIN
        CALL pg_temp.bp_save(c_tenant, o_school);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    SELECT (SELECT COUNT(*) FROM core.school_profiles  WHERE tenant_id = c_tenant AND school_id = o_school)
         + (SELECT COUNT(*) FROM core.school_addresses WHERE tenant_id = c_tenant AND school_id = o_school)
         + (SELECT COUNT(*) FROM core.school_contacts  WHERE tenant_id = c_tenant AND school_id = o_school)
      INTO v_n;
    PERFORM pg_temp.chk_eq('I1 profile save for a school outside the tenant writes nothing', v_n, 0);

    BEGIN
        c := 'i2'; CALL core.sp_school_receipt_format_manage('Save', c_tenant, o_school, c_user, 'Thermal', c);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    SELECT COUNT(*) INTO v_n FROM core.school_settings WHERE tenant_id = c_tenant AND school_id = o_school;
    PERFORM pg_temp.chk_eq('I2 format save for a school outside the tenant writes nothing', v_n, 0);

    BEGIN
        c := 'i3';
        CALL core.sp_school_admin_admission_workflow_manage('SaveAdmissionWorkflow', c_tenant, o_school, c_user,
             TRUE, TRUE, TRUE, TRUE, 'X', TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, c);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    SELECT COUNT(*) INTO v_n FROM core.school_admission_workflow_settings WHERE tenant_id = c_tenant AND school_id = o_school;
    PERFORM pg_temp.chk_eq('I3 workflow save for a school outside the tenant writes nothing', v_n, 0);

    SELECT COUNT(*) INTO v_n FROM config.permissions
     WHERE permission_key IN ('settings.view','settings.manage','admission_workflow.view',
                              'admission_workflow.manage','fees.manage')
       AND is_active;
    PERFORM pg_temp.chk_eq('I4 every permission these pages check exists', v_n, 5);
END
$suite$;


DO $sum$
DECLARE p integer; f integer; r record;
BEGIN
    SELECT COUNT(*) FILTER (WHERE ok), COUNT(*) FILTER (WHERE NOT ok) INTO p, f FROM _t;
    RAISE NOTICE '';
    RAISE NOTICE '========== RESULT: % passed, % failed ==========', p, f;
    IF f > 0 THEN
        RAISE NOTICE 'failures:';
        FOR r IN SELECT name, detail FROM _t WHERE NOT ok ORDER BY id LOOP
            RAISE NOTICE '   %  %', rpad(r.name, 54), r.detail;
        END LOOP;
    END IF;
    RAISE NOTICE '';
END
$sum$;

ROLLBACK;
