-- ============================================================================
-- Super Admin: schools test suite.
--
-- The platform super admin onboards a school (new or existing tenant, with or
-- without its admin), edits it, changes its status (the login gate) and finally
-- closes and purges it. A bug here shows up as a school whose admin can never
-- sign in, a status that does not lock anyone out, or a purge that leaves rows
-- behind.
--
-- EXTENDS platform_access_security_tests.sql (sections G and H there). That
-- suite depends on schools that no longer exist locally (tenants 23-25 were
-- wiped on 2026-10-11), so this one builds its OWN tenants and schools inside
-- the transaction and does not reuse any existing school.
--
-- Runs inside ONE transaction and ROLLS BACK. Run against LOCAL only:
--
--     psql -h localhost -U postgres -d educore -f superadmin_schools_tests.sql
--
-- Checks are named after the CORRECT behaviour, so a FAIL is a bug (or an open
-- decision). Ids point at the catalog:
--     educore/docs/test-cases/superadmin_schools.md
--
-- COVERS
--   A. Create: new tenant + school + admin       (core.sp_school_manage INSERT)
--   B. Create: second school on an existing tenant
--   C. Create without an admin, add the admin later on Edit
--   D. Validation and duplicates
--   E. Board needs a state (State Board / Madrasah)
--   F. Edit keeps what the form does not post
--   G. Status = login gate                        (sp_login_management, sp_session_check)
--   H. School list and dropdowns                  (core.sp_school_list, config.sp_school_dropdowns)
--   I. Purge and archive                          (core.sp_school_purge, sp_school_archive)
--   J. Platform-only operations
-- ============================================================================

\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE TEMP TABLE _t(id serial, name text, ok boolean, detail text) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.chk(p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO _t(name, ok, detail) VALUES (p_name, COALESCE(p_ok, FALSE), p_detail);
    RAISE NOTICE '  [%] %  %', CASE WHEN COALESCE(p_ok, FALSE) THEN 'PASS' ELSE 'FAIL' END,
                 rpad(p_name, 66), p_detail;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.chk_eq(p_name text, p_got numeric, p_want numeric)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.chk(p_name, p_got IS NOT DISTINCT FROM p_want,
                        format('got %s, expected %s', COALESCE(p_got::text,'NULL'), p_want));
END $$;

-- Rows in a refcursor (fetches them all, then closes it).
CREATE OR REPLACE FUNCTION pg_temp.cur_count(c refcursor)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE r record; n integer := 0;
BEGIN
    LOOP
        FETCH c INTO r;
        EXIT WHEN NOT FOUND;
        n := n + 1;
    END LOOP;
    CLOSE c;
    RETURN n;
END $$;

-- Create a school the way SchoolService.CreateSchoolAsync does (super admin =
-- tenant 1, user 1). Every argument has a sane default so a check only names
-- what it varies. Returns the new school_id.
CREATE OR REPLACE FUNCTION pg_temp.mk(
    p_school_name   text,
    p_tenant_mode   text    DEFAULT 'existing',
    p_sel_tenant    integer DEFAULT NULL,
    p_tenant_name   text    DEFAULT NULL,
    p_tenant_code   text    DEFAULT NULL,
    p_tenant_email  text    DEFAULT NULL,
    p_status_id     integer DEFAULT 1,
    p_board_id      integer DEFAULT 1,
    p_board_state   integer DEFAULT NULL,
    p_state_id      integer DEFAULT 26,           -- Uttar Pradesh
    p_state         text    DEFAULT 'Uttar Pradesh',
    p_pincode       text    DEFAULT '274001',
    p_phone         text    DEFAULT '9000000001',
    p_create_admin  boolean DEFAULT FALSE,
    p_admin_email   text    DEFAULT NULL,
    p_admin_phone   text    DEFAULT NULL,
    p_reg_no        text    DEFAULT NULL,
    p_actor_tenant  integer DEFAULT 1,
    p_admin_name    text    DEFAULT 'ZZ Admin')
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'mk_c'; r record;
BEGIN
    CALL core.sp_school_manage('INSERT', p_actor_tenant, 1,
         p_tenant_mode => p_tenant_mode, p_selected_tenant_id => p_sel_tenant,
         p_tenant_name => p_tenant_name, p_tenant_code => p_tenant_code, p_tenant_email => p_tenant_email,
         p_school_name => p_school_name, p_status_id => p_status_id,
         p_registration_number => p_reg_no,
         p_board_id => p_board_id, p_school_type_id => 8,
         p_address_type_id => 1, p_address_line1 => '1 Test Road', p_city => 'Deoria',
         p_state => p_state, p_pincode => p_pincode,
         p_contact_type_id => 1, p_contact_name => 'ZZ Contact', p_phone => p_phone,
         p_enable_email => TRUE,
         p_create_school_admin => p_create_admin, p_admin_full_name => p_admin_name,
         p_admin_email => p_admin_email, p_admin_phone => p_admin_phone,
         p_password_hash => CASE WHEN p_create_admin THEN '$2a$11$zzzzzzzzzzzzzzzzzzzzzuTESTHASHzzzzzzzzzzzzzzzzzzzzzzz' END,
         p_country_id => 1, p_state_id => p_state_id,
         p_board_state_id => p_board_state, p_result => c);
    FETCH c INTO r; CLOSE c;
    RETURN r.school_id;
END $$;

-- Same, but returns 'OK' or the error text (the call is undone on error).
CREATE OR REPLACE FUNCTION pg_temp.mk_try(
    p_school_name text, p_tenant_mode text DEFAULT 'existing', p_sel_tenant integer DEFAULT NULL,
    p_tenant_name text DEFAULT NULL, p_tenant_code text DEFAULT NULL, p_tenant_email text DEFAULT NULL,
    p_status_id integer DEFAULT 1, p_board_id integer DEFAULT 1, p_board_state integer DEFAULT NULL,
    p_state_id integer DEFAULT 26, p_state text DEFAULT 'Uttar Pradesh', p_pincode text DEFAULT '274001',
    p_phone text DEFAULT '9000000001', p_create_admin boolean DEFAULT FALSE,
    p_admin_email text DEFAULT NULL, p_admin_phone text DEFAULT NULL, p_reg_no text DEFAULT NULL,
    p_actor_tenant integer DEFAULT 1, p_admin_name text DEFAULT 'ZZ Admin')
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.mk(p_school_name, p_tenant_mode, p_sel_tenant, p_tenant_name, p_tenant_code,
                       p_tenant_email, p_status_id, p_board_id, p_board_state, p_state_id, p_state,
                       p_pincode, p_phone, p_create_admin, p_admin_email, p_admin_phone, p_reg_no,
                       p_actor_tenant, p_admin_name);
    RAISE EXCEPTION 'zz-undo-ok';
EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'zz-undo-ok' THEN RETURN 'OK'; END IF;
    RETURN SQLSTATE || ': ' || SQLERRM;
END $$;

-- Edit a school the way the Edit page does: GET, post every value back, change
-- only what the check names. NULL override = keep the GET value.
CREATE OR REPLACE FUNCTION pg_temp.edit(
    p_school_id    integer,
    p_status_id    integer DEFAULT NULL,
    p_school_name  text    DEFAULT NULL,
    p_board_id     integer DEFAULT NULL,
    p_board_state  integer DEFAULT NULL,
    p_create_admin boolean DEFAULT NULL,
    p_admin_email  text    DEFAULT NULL,
    p_admin_phone  text    DEFAULT NULL,
    p_admin_name   text    DEFAULT NULL,
    p_password     text    DEFAULT NULL,
    p_actor_tenant integer DEFAULT 1,
    p_blank_admin_phone boolean DEFAULT FALSE)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'edit_get'; g record; u refcursor := 'edit_upd';
BEGIN
    CALL core.sp_school_manage('GET', 1, 1, p_school_id => p_school_id, p_result => c);
    FETCH c INTO g; CLOSE c;
    IF g.school_id IS NULL THEN
        -- Editing a school that does not exist: post the id anyway, like a stale tab.
        CALL core.sp_school_manage('UPDATE', p_actor_tenant, 1, p_tenant_mode => 'existing',
             p_school_id => p_school_id, p_school_name => 'ZZ Ghost', p_status_id => 1, p_board_id => 1, p_school_type_id => 8,
             p_address_line1 => 'x', p_city => 'Deoria', p_state => 'Uttar Pradesh', p_pincode => '274001',
             p_contact_name => 'x', p_phone => '9000000001', p_result => u);
        CLOSE u;
        RETURN;
    END IF;
    CALL core.sp_school_manage('UPDATE', p_actor_tenant, 1,
         p_tenant_mode => 'existing', p_selected_tenant_id => g.tenant_id,
         p_school_id => g.school_id,
         p_school_name => COALESCE(p_school_name, g.school_name), p_display_name => g.display_name,
         p_status_id => COALESCE(p_status_id, g.status_id),
         p_registration_number => g.registration_number, p_affiliation_number => g.affiliation_number,
         p_board_id => COALESCE(p_board_id, g.board_id), p_school_type_id => g.school_type_id,
         p_ownership_type_id => g.ownership_type_id, p_medium_id => g.medium_id,
         p_established_year => g.established_year, p_website => g.website,
         p_address_type_id => g.address_type_id, p_address_line1 => g.address_line1,
         p_address_line2 => g.address_line2, p_city => g.city, p_district => g.district,
         p_state => g.state, p_pincode => g.pincode,
         p_contact_type_id => g.contact_type_id, p_contact_name => g.contact_name,
         p_designation => g.designation, p_contact_email => g.email, p_phone => g.phone,
         p_alternate_phone => g.alternate_phone,
         p_academic_year_id => g.academic_year_id, p_date_format_id => g.date_format_id,
         p_time_format_id => g.time_format_id, p_enable_sms => g.enable_sms,
         p_enable_email => g.enable_email, p_enable_whatsapp => g.enable_whatsapp,
         p_create_school_admin => COALESCE(p_create_admin, g.admin_user_id IS NOT NULL),
         p_admin_full_name => COALESCE(p_admin_name, g.admin_full_name),
         p_admin_email => COALESCE(p_admin_email, g.admin_email),
         p_admin_phone => CASE WHEN p_blank_admin_phone THEN NULL ELSE COALESCE(p_admin_phone, g.admin_phone) END,
         p_password_hash => p_password,
         p_country_id => g.country_id, p_state_id => g.state_id, p_district_id => g.district_id,
         p_board_state_id => COALESCE(p_board_state, g.board_state_id), p_result => u);
    CLOSE u;
END $$;

-- 'OK' or the error text of an edit.
CREATE OR REPLACE FUNCTION pg_temp.edit_try(
    p_school_id integer, p_status_id integer DEFAULT NULL, p_school_name text DEFAULT NULL,
    p_board_id integer DEFAULT NULL, p_board_state integer DEFAULT NULL, p_create_admin boolean DEFAULT NULL,
    p_admin_email text DEFAULT NULL, p_admin_phone text DEFAULT NULL, p_admin_name text DEFAULT NULL,
    p_password text DEFAULT NULL, p_actor_tenant integer DEFAULT 1)
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.edit(p_school_id, p_status_id, p_school_name, p_board_id, p_board_state,
                         p_create_admin, p_admin_email, p_admin_phone, p_admin_name, p_password, p_actor_tenant);
    RAISE EXCEPTION 'zz-undo-ok';
EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'zz-undo-ok' THEN RETURN 'OK'; END IF;
    RETURN SQLSTATE || ': ' || SQLERRM;
END $$;

-- Login lookup row for an email (NULL fields when nobody is found).
CREATE OR REPLACE FUNCTION pg_temp.login(p_email text)
RETURNS TABLE(user_id integer, school_id integer, role_code text, allows boolean, must_change boolean)
LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'login_c'; r record;
BEGIN
    CALL core.sp_login_management('GET_LOGIN_USER', p_email => p_email, p_result => c);
    FETCH c INTO r; CLOSE c;
    user_id := r.user_id; school_id := r.school_id; role_code := r.role_code;
    allows := r.school_allows_login; must_change := r.must_change_password;
    RETURN NEXT;
END $$;


DO $suite$
DECLARE
    v_super   CONSTANT integer := 1;
    c         refcursor;
    r         record;
    v_seq     integer;
    v_seq2    integer;
    v_t1      integer;     -- tenant created in A
    v_s1      integer;     -- school A (new tenant, with admin)
    v_s2      integer;     -- school B (existing tenant v_t1, with admin)
    v_t3      integer;     -- tenant created in C (no admin)
    v_s3      integer;     -- school C
    v_s4      integer;     -- school C2 (existing tenant v_t3, no admin)
    v_sp      integer;     -- school to purge
    v_n       integer;
    v_m       integer;
    v_txt     text;
    v_hash    text;
    v_stamp   timestamp;
    v_json    text;
    v_uid     integer;
    st        record;
    d1 refcursor; d2 refcursor; d3 refcursor; d4 refcursor; d5 refcursor; d6 refcursor;
    d7 refcursor; d8 refcursor; d9 refcursor; d10 refcursor; d11 refcursor; d12 refcursor;
BEGIN
    SELECT last_seq INTO v_seq FROM core.school_code_counters WHERE counter_key = 'GLOBAL';

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '-- A. Create: new tenant + school + admin --------------------';

    v_s1 := pg_temp.mk('ZZ Alpha Public School', p_tenant_mode => 'new',
                       p_tenant_name => 'ZZ Alpha Group', p_tenant_code => '  ZZ-Alpha ',
                       p_tenant_email => 'zz.alpha.group@example.invalid',
                       p_create_admin => TRUE, p_admin_email => '  ZZ.Alpha.Admin@Example.invalid ',
                       p_admin_phone => '9100000001');
    SELECT tenant_id INTO v_t1 FROM core.schools WHERE school_id = v_s1;

    SELECT * INTO r FROM core.tenants WHERE tenant_id = v_t1;
    PERFORM pg_temp.chk('A1 new tenant created, code trimmed + lower-cased',
                        v_t1 > 1 AND r.tenant_code = 'zz-alpha' AND r.is_active,
                        format('tenant=%s code=%L', v_t1, r.tenant_code));

    SELECT school_code INTO v_txt FROM core.schools WHERE school_id = v_s1;
    PERFORM pg_temp.chk('A2 school gets the next running code',
                        v_txt = 'SCH' || (v_seq + 1), format('code=%s counter was %s', v_txt, v_seq));

    SELECT (SELECT COUNT(*) FROM core.school_profiles  WHERE school_id = v_s1) * 1000
         + (SELECT COUNT(*) FROM core.school_addresses WHERE school_id = v_s1 AND is_primary) * 100
         + (SELECT COUNT(*) FROM core.school_contacts  WHERE school_id = v_s1 AND is_primary) * 10
         + (SELECT COUNT(*) FROM core.school_settings  WHERE school_id = v_s1) INTO v_n;
    PERFORM pg_temp.chk_eq('A3 one profile, primary address, primary contact, settings row', v_n, 1111);

    SELECT u.email, u.must_change_password, u.tenant_id, u.school_id, rr.role_code, ur.is_primary, up.full_name
      INTO r
      FROM core.users u
      JOIN core.user_roles ur ON ur.user_id = u.user_id AND NOT ur.is_deleted
      JOIN config.roles rr ON rr.role_id = ur.role_id
      LEFT JOIN core.user_profiles up ON up.user_id = u.user_id
     WHERE u.school_id = v_s1;
    PERFORM pg_temp.chk('A4 admin email stored trimmed + lower-cased',
                        r.email = 'zz.alpha.admin@example.invalid', format('email=%L', r.email));
    PERFORM pg_temp.chk('A5 admin is the primary SCHOOL_ADMIN of the new school, forced to reset',
                        r.role_code = 'SCHOOL_ADMIN' AND r.is_primary AND r.must_change_password
                        AND r.tenant_id = v_t1 AND r.school_id = v_s1,
                        format('role=%s primary=%s must=%s', r.role_code, r.is_primary, r.must_change_password));

    SELECT COUNT(*) INTO v_n FROM config.roles
     WHERE tenant_id = v_t1 AND role_code IN ('SCHOOL_ADMIN','TEACHER','ACCOUNTANT','RECEPTIONIST') AND NOT is_deleted;
    PERFORM pg_temp.chk_eq('A6 the four built-in roles are seeded for the new tenant', v_n, 4);

    SELECT COUNT(DISTINCT rp.role_id) INTO v_n
      FROM config.role_permissions rp JOIN config.roles rr ON rr.role_id = rp.role_id
     WHERE rp.tenant_id = v_t1 AND rp.school_id = v_s1 AND rp.is_allowed
       AND rr.role_code IN ('TEACHER','ACCOUNTANT','RECEPTIONIST');
    PERFORM pg_temp.chk_eq('A7 built-in role defaults applied (Teacher/Accountant/Receptionist)', v_n, 3);

    SELECT * INTO r FROM pg_temp.login('zz.alpha.admin@example.invalid');
    PERFORM pg_temp.chk('A8 the new admin can sign in (school gate open, must change pwd)',
                        r.school_id = v_s1 AND r.allows AND r.must_change AND r.role_code = 'SCHOOL_ADMIN',
                        format('school=%s allows=%s must=%s', r.school_id, r.allows, r.must_change));

    SELECT * INTO r FROM pg_temp.login('9100000001');
    PERFORM pg_temp.chk('A9 ...and by mobile number', r.user_id IS NOT NULL AND r.school_id = v_s1,
                        format('user=%s', r.user_id));

    SELECT COUNT(*) FILTER (WHERE action = 'SCHOOL_CREATE' AND record_id = v_s1),
           COUNT(*) FILTER (WHERE action = 'SCHOOL_ADMIN_CREATE')
      INTO v_n, v_m FROM core.admin_activity_logs
     WHERE tenant_id = 1 AND school_id IS NULL AND created_at = now();
    PERFORM pg_temp.chk('A10 create audited on the platform tenant (school + admin)',
                        v_n = 1 AND v_m = 1, format('school=%s admin=%s', v_n, v_m));

    SELECT enable_email, academic_year_id INTO r FROM core.school_settings WHERE school_id = v_s1;
    PERFORM pg_temp.chk('A11 settings row carries the wizard toggles (email on)', r.enable_email,
                        format('enable_email=%s ay=%s', r.enable_email, r.academic_year_id));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- B. Create: second school on an existing tenant -------------';

    v_s2 := pg_temp.mk('ZZ Alpha Junior School', p_sel_tenant => v_t1, p_phone => '9000000002',
                       p_create_admin => TRUE, p_admin_email => 'zz.alpha.junior@example.invalid',
                       p_admin_phone => '9100000002');
    SELECT COUNT(*) INTO v_n FROM config.roles WHERE tenant_id = v_t1 AND NOT is_deleted;
    PERFORM pg_temp.chk_eq('B1 roles are not duplicated for the second school', v_n, 4);

    SELECT school_code INTO v_txt FROM core.schools WHERE school_id = v_s2;
    PERFORM pg_temp.chk('B2 second school gets the following code', v_txt = 'SCH' || (v_seq + 2), v_txt);

    SELECT COUNT(DISTINCT rp.role_id) INTO v_n FROM config.role_permissions rp
     WHERE rp.tenant_id = v_t1 AND rp.school_id = v_s2 AND rp.is_allowed;
    PERFORM pg_temp.chk_eq('B3 built-in role defaults applied to the second school too', v_n, 3);

    SELECT * INTO r FROM pg_temp.login('zz.alpha.junior@example.invalid');
    PERFORM pg_temp.chk('B4 second admin signs in to the second school only', r.school_id = v_s2,
                        format('school=%s', r.school_id));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- C. Create without an admin; add the admin later on Edit -----';

    v_s3 := pg_temp.mk('ZZ Beta Vidyalaya', p_tenant_mode => 'new', p_tenant_name => 'ZZ Beta Trust',
                       p_tenant_code => 'zz-beta', p_phone => '9000000003', p_create_admin => FALSE);
    SELECT tenant_id INTO v_t3 FROM core.schools WHERE school_id = v_s3;

    SELECT COUNT(*) INTO v_n FROM config.roles WHERE tenant_id = v_t3 AND NOT is_deleted;
    PERFORM pg_temp.chk_eq('C1 a new tenant created WITHOUT an admin still gets the 4 built-in roles', v_n, 4);

    SELECT COUNT(*) INTO v_n FROM config.role_permissions WHERE tenant_id = v_t3 AND school_id = v_s3;
    PERFORM pg_temp.chk('C2 ...and the built-in role defaults', v_n > 0, format('grants=%s', v_n));

    v_txt := pg_temp.edit_try(v_s3, p_create_admin => TRUE, p_admin_name => 'ZZ Beta Admin',
                              p_admin_email => 'zz.beta.admin@example.invalid', p_admin_phone => '9100000003',
                              p_password => '$2a$11$zzzzzzzzzzzzzzzzzzzzzuTESTHASHzzzzzzzzzzzzzzzzzzzzzzz');
    PERFORM pg_temp.chk('C3 Edit accepts "create the admin now"', v_txt = 'OK', v_txt);
    PERFORM pg_temp.edit(v_s3, p_create_admin => TRUE, p_admin_name => 'ZZ Beta Admin',
                         p_admin_email => 'zz.beta.admin@example.invalid', p_admin_phone => '9100000003',
                         p_password => '$2a$11$zzzzzzzzzzzzzzzzzzzzzuTESTHASHzzzzzzzzzzzzzzzzzzzzzzz')
        WHERE v_txt = 'OK';

    SELECT COUNT(*) INTO v_n FROM core.users WHERE email = 'zz.beta.admin@example.invalid' AND is_active;
    PERFORM pg_temp.chk_eq('C4 ...the admin login row exists', v_n, 1);

    SELECT COUNT(*) INTO v_n FROM core.user_roles ur JOIN core.users u ON u.user_id = ur.user_id
     WHERE u.email = 'zz.beta.admin@example.invalid' AND NOT ur.is_deleted;
    PERFORM pg_temp.chk_eq('C5 ...and holds the SCHOOL_ADMIN role (tenant had no roles)', v_n, 1);

    SELECT * INTO r FROM pg_temp.login('zz.beta.admin@example.invalid');
    PERFORM pg_temp.chk('C6 ...and can actually sign in', r.user_id IS NOT NULL AND r.school_id = v_s3,
                        format('login row user=%s school=%s (NULL = "Invalid email or password")', r.user_id, r.school_id));

    -- The super admin notices and tries again: the half-made login now blocks the email.
    v_txt := pg_temp.edit_try(v_s3, p_create_admin => TRUE, p_admin_name => 'ZZ Beta Admin',
                              p_admin_email => 'zz.beta.admin@example.invalid', p_admin_phone => '9100000003',
                              p_password => '$2a$11$zzzzzzzzzzzzzzzzzzzzzuTESTHASHzzzzzzzzzzzzzzzzzzzzzzz');
    PERFORM pg_temp.chk('C6b a second Edit attempt can repair the admin (not "email already registered")',
                        v_txt = 'OK', v_txt);

    -- Same tenant, second school without admin: the roles exist only if C1 holds.
    v_s4 := pg_temp.mk('ZZ Beta Vidyalaya Branch', p_sel_tenant => v_t3, p_phone => '9000000004');
    SELECT COUNT(*) INTO v_n FROM config.role_permissions WHERE tenant_id = v_t3 AND school_id = v_s4;
    PERFORM pg_temp.chk('C7 role defaults for a 2nd admin-less school on an admin-less tenant',
                        v_n > 0, format('grants=%s', v_n));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- D. Validation and duplicates ------------------------------';

    v_txt := pg_temp.mk_try('ZZ X1', p_tenant_mode => 'new', p_tenant_name => 'ZZ X', p_tenant_code => ' zz-ALPHA ');
    PERFORM pg_temp.chk('D1 tenant code reused (other case / spaces) is refused',
                        v_txt LIKE '%Tenant code already exists%', v_txt);

    v_txt := pg_temp.mk_try('ZZ X2', p_tenant_mode => 'new', p_tenant_name => 'ZZ X', p_tenant_code => 'zz-x2',
                            p_tenant_email => 'ZZ.ALPHA.GROUP@example.invalid');
    PERFORM pg_temp.chk('D2 tenant email reused (other case) is refused',
                        v_txt LIKE '%Tenant email already exists%', v_txt);

    -- A soft-deleted tenant still owns its code in tenants_tenant_code_key.
    INSERT INTO core.tenants(tenant_name, tenant_code, is_active, is_deleted, created_by, created_at)
    VALUES ('ZZ Gone Tenant', 'zz-gone', FALSE, TRUE, v_super, now());
    v_txt := pg_temp.mk_try('ZZ X3', p_tenant_mode => 'new', p_tenant_name => 'ZZ X', p_tenant_code => 'ZZ-Gone');
    PERFORM pg_temp.chk('D3 code of a soft-deleted tenant: friendly refusal, not a raw 23505',
                        v_txt LIKE 'P0001%', v_txt);

    v_txt := pg_temp.mk_try('ZZ X4', p_tenant_mode => 'new', p_tenant_name => 'ZZ X', p_tenant_code => 'zz has spaces/!');
    PERFORM pg_temp.chk('D4 tenant code with spaces/symbols is refused (slug only)',
                        v_txt <> 'OK', v_txt);

    v_txt := pg_temp.mk_try('  zz alpha PUBLIC school ', p_sel_tenant => v_t1);
    PERFORM pg_temp.chk('D5 duplicate school name on the same tenant (case/space) refused',
                        v_txt LIKE '%School name already exists%', v_txt);

    v_txt := pg_temp.mk_try('ZZ Alpha Public School', p_sel_tenant => v_t3);
    PERFORM pg_temp.chk('D6 same school name on a DIFFERENT tenant is allowed', v_txt = 'OK', v_txt);

    UPDATE core.school_profiles SET registration_number = 'ZZ-REG-1' WHERE school_id = v_s1;
    v_txt := pg_temp.mk_try('ZZ X7', p_sel_tenant => v_t1, p_reg_no => ' zz-reg-1 ');
    PERFORM pg_temp.chk('D7 duplicate registration number on the tenant refused',
                        v_txt LIKE '%Registration number already exists%', v_txt);

    v_txt := pg_temp.mk_try('ZZ X8', p_sel_tenant => v_t1, p_create_admin => TRUE,
                            p_admin_email => 'SUPERADMIN@educore.com');
    PERFORM pg_temp.chk('D8 admin email = the super admin''s (case) refused',
                        v_txt LIKE '%already registered%', v_txt);

    v_txt := pg_temp.mk_try('ZZ X9', p_sel_tenant => v_t1, p_create_admin => TRUE,
                            p_admin_email => 'zz.x9@example.invalid', p_admin_phone => '9100000001');
    PERFORM pg_temp.chk('D9 admin phone already used refused with a friendly message',
                        v_txt LIKE '%Admin phone already exists%', v_txt);

    -- A login phone is a plain 10-digit mobile (the form allows nothing else).
    v_txt := pg_temp.mk_try('ZZ X9b', p_sel_tenant => v_t1, p_create_admin => TRUE,
                            p_admin_email => 'zz.x9b@example.invalid', p_admin_phone => '+91 91000-00001');
    PERFORM pg_temp.chk('D9b formatted admin phone refused with a clear message',
                        v_txt LIKE '%10-digit mobile%', v_txt);

    v_txt := pg_temp.mk_try('ZZ X10', p_sel_tenant => v_t1, p_create_admin => TRUE, p_admin_email => '  ');
    PERFORM pg_temp.chk('D10 create-admin with a blank email refused', v_txt LIKE '%Admin email is required%', v_txt);

    v_txt := pg_temp.mk_try('ZZ X11', p_sel_tenant => v_t1, p_pincode => '27400');
    PERFORM pg_temp.chk('D11 5-digit pincode refused', v_txt LIKE '%6 digits%', v_txt);
    v_txt := pg_temp.mk_try('ZZ X12', p_sel_tenant => v_t1, p_pincode => 'abcdef');
    PERFORM pg_temp.chk('D12 non-numeric pincode refused', v_txt LIKE '%6 digits%', v_txt);
    v_txt := pg_temp.mk_try('ZZ X13', p_sel_tenant => v_t1, p_pincode => '012345');
    PERFORM pg_temp.chk('D13 pincode starting with 0 refused (as the form does: ^[1-9][0-9]{5}$)',
                        v_txt <> 'OK', v_txt);

    v_txt := pg_temp.mk_try('ZZ X14', p_sel_tenant => v_t1, p_phone => '12');
    PERFORM pg_temp.chk('D14 contact phone "12" refused by the proc too (form needs 10 digits)',
                        v_txt <> 'OK', v_txt);

    v_txt := pg_temp.mk_try('ZZ X15', p_sel_tenant => v_t1, p_status_id => 999);
    PERFORM pg_temp.chk('D15 unknown status id refused', v_txt <> 'OK', v_txt);

    v_txt := pg_temp.mk_try('ZZ X16', p_sel_tenant => v_t1, p_board_id => 999);
    PERFORM pg_temp.chk('D16 unknown board id refused', v_txt <> 'OK', v_txt);

    v_txt := pg_temp.mk_try('ZZ X17', p_sel_tenant => 1);
    PERFORM pg_temp.chk('D17 tenant 1 (platform) as the owner refused with a plain message',
                        v_txt LIKE '%platform tenant cannot own a school%', v_txt);

    v_txt := pg_temp.mk_try('ZZ X18', p_sel_tenant => 987654);
    PERFORM pg_temp.chk('D18 non-existent tenant refused', v_txt LIKE '%Selected tenant does not exist%', v_txt);

    v_txt := pg_temp.mk_try('ZZ X19', p_tenant_mode => NULL);
    PERFORM pg_temp.chk('D19 no tenant option refused', v_txt LIKE '%Tenant option is required%', v_txt);

    SELECT last_seq INTO v_seq2 FROM core.school_code_counters WHERE counter_key = 'GLOBAL';
    PERFORM pg_temp.chk('D20 failed creates burn no school code (counter = created schools only)',
                        v_seq2 = v_seq + 4, format('counter=%s, expected %s', v_seq2, v_seq + 4));

    v_txt := pg_temp.mk_try('ZZ X21', p_sel_tenant => v_t1, p_create_admin => TRUE,
                            p_admin_email => 'zz.x21@example.invalid', p_admin_phone => '12345');
    v_m := 0;
    IF v_txt = 'OK' THEN
        PERFORM pg_temp.mk('ZZ X21', p_sel_tenant => v_t1, p_create_admin => TRUE,
                           p_admin_email => 'zz.x21@example.invalid', p_admin_phone => '12345');
        v_txt := pg_temp.mk_try('ZZ X22', p_sel_tenant => v_t1, p_create_admin => TRUE,
                                p_admin_email => 'zz.x22@example.invalid', p_admin_phone => '12345');
        v_m := 1;
    END IF;
    PERFORM pg_temp.chk('D21 short admin phone: refused up front, or a friendly duplicate message',
                        v_txt LIKE 'P0001%', format('%s%s', CASE WHEN v_m = 1 THEN '2nd create -> ' ELSE '' END, v_txt));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- E. Board needs a state ------------------------------------';

    v_txt := pg_temp.mk_try('ZZ E1', p_sel_tenant => v_t1, p_board_id => 3);
    PERFORM pg_temp.chk('E1 State Board without a board state refused', v_txt LIKE '%which state%', v_txt);
    v_txt := pg_temp.mk_try('ZZ E2', p_sel_tenant => v_t1, p_board_id => 12);
    PERFORM pg_temp.chk('E2 Madrasah Board without a board state refused', v_txt LIKE '%which state%', v_txt);
    v_txt := pg_temp.mk_try('ZZ E3', p_sel_tenant => v_t1, p_board_id => 3, p_board_state => 26,
                            p_state_id => 4, p_state => 'Bihar');
    PERFORM pg_temp.chk('E3 UP State Board school located in Bihar refused', v_txt LIKE '%does not match%', v_txt);
    v_txt := pg_temp.mk_try('ZZ E4', p_sel_tenant => v_t1, p_board_id => 3, p_board_state => 26,
                            p_state_id => NULL, p_state => 'Bihar');
    PERFORM pg_temp.chk('E4 UP State Board + address text "Bihar" with no state id refused',
                        v_txt <> 'OK', v_txt);

    v_n := pg_temp.mk('ZZ E5 Board School', p_sel_tenant => v_t1, p_board_id => 1, p_board_state => 26,
                      p_phone => '9000000005');
    SELECT board_state_id INTO v_m FROM core.school_profiles WHERE school_id = v_n;
    PERFORM pg_temp.chk('E5 CBSE ignores a posted board state (stored NULL)', v_m IS NULL, format('board_state=%s', v_m));

    v_n := pg_temp.mk('ZZ E6 UP Board School', p_sel_tenant => v_t1, p_board_id => 3, p_board_state => 26,
                      p_phone => '9000000006');
    SELECT board_state_id INTO v_m FROM core.school_profiles WHERE school_id = v_n;
    PERFORM pg_temp.chk_eq('E6 UP State Board in UP is stored with its state', v_m, 26);

    PERFORM pg_temp.edit(v_n, p_board_id => 1);
    SELECT board_state_id INTO v_m FROM core.school_profiles WHERE school_id = v_n;
    PERFORM pg_temp.chk('E7 Edit State Board -> CBSE clears the stale board state', v_m IS NULL,
                        format('board_state=%s', v_m));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- F. Edit keeps what the form does not post -----------------';

    -- What the school maintains itself (Basic Profile / settings) is not on the wizard.
    UPDATE core.school_profiles SET logo_url = '/uploads/zz-logo.png', header_image_url = '/uploads/zz-head.png',
           description = 'ZZ about us' WHERE school_id = v_s1;
    UPDATE core.school_settings SET receipt_format = 'Thermal', tc_format = 'Board', id_card_format = 'Landscape',
           attendance_backdate_days = 9, timezone = 'Asia/Kolkata', currency = 'INR',
           academic_year_id = 3, date_format_id = 2 WHERE school_id = v_s1;
    SELECT password_hash, password_changed_at INTO v_hash, v_stamp FROM core.users WHERE email = 'zz.alpha.admin@example.invalid';
    UPDATE core.users SET must_change_password = FALSE WHERE email = 'zz.alpha.admin@example.invalid';

    PERFORM pg_temp.edit(v_s1, p_school_name => 'ZZ Alpha Public School (Main)');

    SELECT logo_url, header_image_url, description, registration_number INTO r FROM core.school_profiles WHERE school_id = v_s1;
    PERFORM pg_temp.chk('F1 Edit keeps logo, header image, description, registration no.',
                        r.logo_url = '/uploads/zz-logo.png' AND r.header_image_url = '/uploads/zz-head.png'
                        AND r.description = 'ZZ about us' AND r.registration_number = 'ZZ-REG-1', r::text);
    SELECT receipt_format, tc_format, id_card_format, attendance_backdate_days, timezone, currency,
           academic_year_id, date_format_id INTO r FROM core.school_settings WHERE school_id = v_s1;
    PERFORM pg_temp.chk('F2 Edit keeps receipt/TC/ID-card formats, backdate days, year, date format',
                        r.receipt_format = 'Thermal' AND r.tc_format = 'Board' AND r.id_card_format = 'Landscape'
                        AND r.attendance_backdate_days = 9 AND r.academic_year_id = 3 AND r.date_format_id = 2, r::text);

    SELECT password_hash = v_hash AND password_changed_at IS NOT DISTINCT FROM v_stamp AND NOT must_change_password
      INTO st FROM core.users WHERE email = 'zz.alpha.admin@example.invalid';
    PERFORM pg_temp.chk('F3 Edit with a blank password keeps the hash, stamp and the reset flag', st::text = '(t)', st::text);

    v_txt := pg_temp.edit_try(v_s1, p_admin_email => 'ZZ.Alpha.Junior@example.invalid');
    PERFORM pg_temp.chk('F4 Edit admin email to another user''s email refused', v_txt LIKE '%already registered%', v_txt);

    v_txt := pg_temp.edit_try(v_s1, p_admin_phone => '9100000002');
    PERFORM pg_temp.chk('F5 Edit admin phone to another user''s phone refused', v_txt LIKE '%phone already exists%', v_txt);

    v_txt := pg_temp.edit_try(v_s1, p_school_name => 'zz alpha junior school');
    PERFORM pg_temp.chk('F6 Edit school name to a sibling''s name (same tenant) refused',
                        v_txt LIKE '%School name already exists%', v_txt);

    PERFORM pg_temp.edit(v_s1, p_admin_email => 'ZZ.Alpha.NEW@Example.invalid');
    SELECT COUNT(*) INTO v_n FROM core.users WHERE email = 'zz.alpha.new@example.invalid';
    PERFORM pg_temp.chk_eq('F7 Edited admin email stored lower-cased', v_n, 1);

    PERFORM pg_temp.edit(v_s1, p_password => '$2a$11$zzzzzzzzzzzzzzzzzzzzzuNEWHASHzzzzzzzzzzzzzzzzzzzzzzzz');
    SELECT must_change_password AND password_changed_at IS DISTINCT FROM v_stamp INTO st
      FROM core.users WHERE email = 'zz.alpha.new@example.invalid';
    PERFORM pg_temp.chk('F8 Super-admin password reset is single-use and ends sessions', st::text = '(t)', st::text);

    v_txt := pg_temp.edit_try(2147480000);
    PERFORM pg_temp.chk('F9 Edit of a school that no longer exists says "School not found"',
                        v_txt LIKE '%School not found%', v_txt);

    PERFORM pg_temp.edit(v_s2, p_blank_admin_phone => TRUE);
    SELECT up.phone INTO v_txt FROM core.user_profiles up JOIN core.users u ON u.user_id = up.user_id
     WHERE u.email = 'zz.alpha.junior@example.invalid';
    PERFORM pg_temp.chk('F10 clearing the admin phone on Edit stores NULL (no unique clash)', v_txt IS NULL, COALESCE(v_txt, 'NULL'));

    SELECT COUNT(*) INTO v_n FROM core.schools WHERE school_id = v_s1 AND tenant_id = v_t1;
    PERFORM pg_temp.chk_eq('F11 Edit never moves the school to another tenant', v_n, 1);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- G. Status = login gate -------------------------------------';

    v_n := 0; v_m := 0;
    FOR st IN SELECT school_status_id, name, allows_login, login_message FROM config.school_statuses
              WHERE NOT is_deleted ORDER BY school_status_id LOOP
        PERFORM pg_temp.edit(v_s2, p_status_id => st.school_status_id);
        SELECT * INTO r FROM pg_temp.login('zz.alpha.junior@example.invalid');
        v_n := v_n + 1;
        IF r.allows IS NOT DISTINCT FROM st.allows_login THEN v_m := v_m + 1;
        ELSE RAISE NOTICE '     status % (%): login allows=% expected %', st.name, st.school_status_id, r.allows, st.allows_login;
        END IF;
    END LOOP;
    PERFORM pg_temp.chk('G1 every status opens/closes sign-in exactly as allows_login says',
                        v_n = v_m AND v_n >= 6, format('%s of %s statuses', v_m, v_n));

    -- session check, separately (a cookie issued before a suspension)
    SELECT user_id INTO v_uid FROM core.users WHERE email = 'zz.alpha.junior@example.invalid';
    PERFORM pg_temp.edit(v_s2, p_status_id => 7);   -- Suspended
    c := 'g2';
    CALL core.sp_session_check(v_uid, v_s2, c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('G2 an open session dies when the school is Suspended', NOT r.school_ok, r::text);

    SELECT COUNT(*) INTO v_n FROM core.admin_activity_logs
     WHERE tenant_id = 1 AND action = 'SCHOOL_STATUS' AND record_id = v_s2 AND created_at = now();
    PERFORM pg_temp.chk('G3 each status change is audited on the platform tenant', v_n >= 6, format('rows=%s', v_n));

    PERFORM pg_temp.edit(v_s2, p_status_id => 1);
    c := 'g4';
    CALL core.sp_session_check(v_uid, v_s2, c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('G4 re-activating (Suspended -> Active) re-opens the school', r.school_ok, r::text);

    c := 'g5';
    CALL core.sp_session_check(v_super, 0, c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('G5 the super admin session (school 0) is never school-gated', r.user_ok AND r.school_ok, r::text);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- H. School list and dropdowns -------------------------------';

    c := 'h1';
    CALL core.sp_school_list(1, v_super, p_search => 'ZZ Alpha', p_page_size => 50, p_result => c);
    v_n := pg_temp.cur_count(c);
    PERFORM pg_temp.chk('H1 super admin finds the new schools by name', v_n >= 2, format('rows=%s', v_n));

    c := 'h2';
    CALL core.sp_school_list(1, v_super, p_search => 'zz-alpha', p_page_size => 50, p_result => c);
    v_n := pg_temp.cur_count(c);
    PERFORM pg_temp.chk('H2 search by tenant CODE finds the tenant''s schools', v_n >= 2, format('rows=%s', v_n));

    c := 'h3';
    CALL core.sp_school_list(1, v_super, p_search => '%', p_page_size => 500, p_result => c);
    v_n := pg_temp.cur_count(c);
    SELECT COUNT(*) INTO v_m FROM core.schools WHERE NOT is_deleted AND is_active AND school_name LIKE '%\%%';
    PERFORM pg_temp.chk('H3 searching "%" matches only names containing "%" (wildcards escaped)',
                        v_n = v_m, format('rows=%s, names with %% =%s', v_n, v_m));

    PERFORM pg_temp.edit(v_s3, p_status_id => 6);   -- Under Review: login allowed
    c := 'h4';
    CALL core.sp_school_list(1, v_super, p_search => 'ZZ Beta Vidyalaya', p_page_size => 50, p_result => c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('H4 "active" counter counts every school whose status allows login',
                        r.active_count = 2, format('total=%s active=%s (Under Review + Active)', r.total_count, r.active_count));

    c := 'h5';
    CALL core.sp_school_list(v_t1, 0, p_page_size => 50, p_result => c);
    v_n := pg_temp.cur_count(c);
    SELECT COUNT(*) INTO v_m FROM core.schools WHERE tenant_id = v_t1 AND NOT is_deleted;
    PERFORM pg_temp.chk('H5 a tenant caller lists only its own schools', v_n = v_m, format('rows=%s own=%s', v_n, v_m));

    c := 'h6';
    CALL core.sp_school_manage('GET', v_t3, 0, p_school_id => v_s1, p_result => c);
    v_n := pg_temp.cur_count(c);
    PERFORM pg_temp.chk_eq('H6 another tenant cannot GET our school', v_n, 0);

    BEGIN
        d1 := 'd1'; d2 := 'd2'; d3 := 'd3'; d4 := 'd4'; d5 := 'd5'; d6 := 'd6';
        d7 := 'd7'; d8 := 'd8'; d9 := 'd9'; d10 := 'd10'; d11 := 'd11'; d12 := 'd12';
        -- 12th cursor (institution categories) added by institution_categories.sql.
        CALL config.sp_school_dropdowns(d1, d2, d3, d4, d5, d6, d7, d8, d9, d10, d11, d12);
        v_n := 0; v_m := 0;
        LOOP FETCH d1 INTO r; EXIT WHEN NOT FOUND; IF r.id = 1 THEN v_n := v_n + 1; END IF;
             IF r.id = v_t1 THEN v_m := v_m + 1; END IF; END LOOP;
        CLOSE d1;
        PERFORM pg_temp.chk('H7 tenant dropdown hides the platform tenant, lists the new one',
                            v_n = 0 AND v_m = 1, format('tenant1=%s new=%s', v_n, v_m));
        CLOSE d2; CLOSE d3; CLOSE d4; CLOSE d5; CLOSE d6; CLOSE d7;
        CLOSE d8; CLOSE d9; CLOSE d10; CLOSE d11; CLOSE d12;
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('H7 tenant dropdown hides the platform tenant, lists the new one', FALSE, SQLERRM);
    END;

    c := 'h8';
    CALL core.sp_user_email_check(' ZZ.Alpha.NEW@example.invalid ', NULL, c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('H8 CheckEmail says "taken" for a used email (case/space)', r.is_taken, r::text);
    c := 'h9';
    SELECT user_id INTO v_uid FROM core.users WHERE email = 'zz.alpha.new@example.invalid';
    CALL core.sp_user_email_check('zz.alpha.new@example.invalid', v_uid, c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('H9 CheckEmail excludes the admin being edited', NOT r.is_taken, r::text);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- I. Purge and archive ---------------------------------------';

    v_sp := pg_temp.mk('ZZ Purge Me School', p_sel_tenant => v_t1, p_phone => '9000000009',
                       p_create_admin => TRUE, p_admin_email => 'zz.purge.admin@example.invalid',
                       p_admin_phone => '9100000009');

    BEGIN
        c := 'i1';
        CALL core.sp_school_purge(1, v_sp, v_super, 'ZZ Purge Me School', c); CLOSE c;
        PERFORM pg_temp.chk('I1 purge of an ACTIVE school refused', FALSE, 'purged!');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('I1 purge of an ACTIVE school refused', SQLERRM LIKE '%Closed%', SQLERRM);
    END;

    PERFORM pg_temp.edit(v_sp, p_status_id => 8);   -- Closed

    BEGIN
        c := 'i2';
        CALL core.sp_school_purge(1, v_sp, v_super, 'ZZ Purge Me', c); CLOSE c;
        PERFORM pg_temp.chk('I2 purge with a partial name refused', FALSE, 'purged!');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('I2 purge with a partial name refused', SQLERRM LIKE '%does not match%', SQLERRM);
    END;

    BEGIN
        c := 'i3';
        CALL core.sp_school_purge(v_t1, v_sp, v_super, 'ZZ Purge Me School', c); CLOSE c;
        PERFORM pg_temp.chk('I3 purge by a non-platform caller refused', FALSE, 'purged!');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('I3 purge by a non-platform caller refused', SQLERRM LIKE '%platform%', SQLERRM);
    END;

    c := 'i4';
    CALL core.sp_school_archive(1, v_sp, c);
    FETCH c INTO r; CLOSE c;
    v_json := r.archive_json;
    PERFORM pg_temp.chk('I4 archive has the school''s rows and no password hash',
                        r.total_rows > 5 AND position('password_hash' IN v_json) = 0
                        AND position('zz.purge.admin@example.invalid' IN v_json) > 0,
                        format('rows=%s', r.total_rows));

    c := 'i5';
    CALL core.sp_school_archive(1, 2147480000, c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('I5 archive of a non-existent school is empty (purge then says "School not found")',
                        r.total_rows = 0 AND r.school_name IS NULL, format('name=%s rows=%s', r.school_name, r.total_rows));

    BEGIN
        c := 'i6';
        CALL core.sp_school_purge(1, v_sp, v_super, '  ZZ Purge Me School  ', c); CLOSE c;
        PERFORM pg_temp.chk('I6 Closed school + typed name (stray spaces ok) is purged', TRUE, '');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('I6 Closed school + typed name (stray spaces ok) is purged', FALSE, SQLERRM);
    END;

    -- Orphans: every table in ANY schema that has a school_id column.
    v_n := 0; v_txt := '';
    FOR r IN SELECT c2.table_schema AS sch, c2.table_name AS tbl
             FROM information_schema.columns c2
             JOIN information_schema.tables t ON t.table_schema = c2.table_schema AND t.table_name = c2.table_name
              AND t.table_type = 'BASE TABLE'
             WHERE c2.column_name = 'school_id' AND c2.table_schema NOT IN ('pg_catalog','information_schema')
               AND c2.table_schema NOT LIKE 'pg_temp%' LOOP
        EXECUTE format('SELECT count(*) FROM %I.%I WHERE school_id = $1', r.sch, r.tbl) INTO v_m USING v_sp;
        IF v_m > 0 THEN v_n := v_n + v_m; v_txt := v_txt || r.sch || '.' || r.tbl || ' '; END IF;
    END LOOP;
    PERFORM pg_temp.chk_eq('I7 no row with the purged school_id remains anywhere', v_n, 0);

    SELECT COUNT(*) INTO v_n FROM core.users WHERE email = 'zz.purge.admin@example.invalid';
    SELECT COUNT(*) INTO v_m FROM core.user_profiles WHERE phone = '9100000009';
    PERFORM pg_temp.chk('I8 the purged admin''s login and profile are gone (email/phone reusable)',
                        v_n = 0 AND v_m = 0, format('users=%s profiles=%s', v_n, v_m));

    SELECT COUNT(*) INTO v_n FROM core.schools WHERE school_id IN (v_s1, v_s2);
    SELECT COUNT(*) INTO v_m FROM config.roles WHERE tenant_id = v_t1 AND NOT is_deleted;
    PERFORM pg_temp.chk('I9 sibling schools and the tenant roles survive', v_n = 2 AND v_m = 4,
                        format('siblings=%s roles=%s', v_n, v_m));

    SELECT * INTO r FROM pg_temp.login('zz.alpha.junior@example.invalid');
    PERFORM pg_temp.chk('I10 a sibling school''s admin still signs in', r.school_id = v_s2, format('school=%s', r.school_id));

    SELECT COUNT(*) INTO v_n FROM core.admin_activity_logs
     WHERE tenant_id = 1 AND action = 'SCHOOL_PURGE' AND record_id = v_sp;
    PERFORM pg_temp.chk_eq('I11 purge audited on the platform tenant', v_n, 1);

    v_txt := pg_temp.mk_try('ZZ Purge Me School', p_sel_tenant => v_t1, p_create_admin => TRUE,
                            p_admin_email => 'zz.purge.admin@example.invalid', p_admin_phone => '9100000009');
    PERFORM pg_temp.chk('I12 after a purge the same name/email/phone can be onboarded again', v_txt = 'OK', v_txt);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- J. Platform-only operations ---------------------------------';

    v_txt := pg_temp.mk_try('ZZ J1', p_sel_tenant => v_t3, p_actor_tenant => v_t1);
    PERFORM pg_temp.chk('J1 a school-tenant caller cannot INSERT a school', v_txt LIKE '%Only the platform%', v_txt);

    v_txt := pg_temp.edit_try(v_s1, p_status_id => 1, p_actor_tenant => v_t1);
    PERFORM pg_temp.chk('J2 a school-tenant caller cannot change its own status', v_txt LIKE '%Only the platform%', v_txt);

    BEGIN
        c := 'j3';
        CALL core.sp_school_manage('DELETE', 1, v_super, p_school_id => v_s4, p_result => c); CLOSE c;
        PERFORM pg_temp.chk('J3 leftover DELETE op is gone (it strands schools: hidden from list AND Edit)',
                            FALSE, 'DELETE still soft-deletes');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('J3 leftover DELETE op is gone (it strands schools: hidden from list AND Edit)',
                            TRUE, SQLERRM);
    END;
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
            RAISE NOTICE '   %  %', rpad(r.name, 66), r.detail;
        END LOOP;
    END IF;
    RAISE NOTICE '';
END
$sum$;

ROLLBACK;
