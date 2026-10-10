-- ============================================================================
-- Small features test suite (2026-10-10).
--
--   A. Payroll permission keys (payroll_permissions.sql)
--   B. Defaulters report by session (fee_reports.sql, sp_fee_defaulters_get)
--   C. Remove school logo (sp_school_admin_basic_profile_manage 'RemoveLogo')
--   D. Official phone: mobile OR landline (core.fn_school_phone_clean)
--
-- Fixture: tenant 24 / school 34 / user 39. Tenant 23 / school 33 is the
-- other school for the cross-school checks.
--
-- Runs inside ONE transaction and ROLLS BACK. The payroll script itself is
-- run (twice) from here, so the test exercises the real file.
--
--     psql ... -f small_features_tests.sql
-- ============================================================================

\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE TEMP TABLE _t(id serial, name text, ok boolean, detail text) ON COMMIT DROP;
CREATE TEMP TABLE _fx(k text PRIMARY KEY, v integer) ON COMMIT DROP;

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

-- Payroll grants of one role (live rows only).
CREATE OR REPLACE FUNCTION pg_temp.payroll_keys(p_role int)
RETURNS text LANGUAGE sql AS $$
    SELECT COALESCE(string_agg(p.permission_key, ',' ORDER BY p.permission_key), '')
    FROM config.role_permissions rp JOIN config.permissions p USING (permission_id)
    WHERE rp.role_id = p_role AND p.permission_key LIKE 'payroll.%'
      AND COALESCE(rp.is_deleted, FALSE) = FALSE;
$$;

-- Defaulters report: what one entry owes (fallen due) in one session view.
-- p_year NULL = all sessions. p_name picks the row (student name).
CREATE OR REPLACE FUNCTION pg_temp.owed(p_tenant int, p_school int, p_name text, p_year text)
RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'df_' || md5(random()::text); r record; v numeric := 0;
BEGIN
    CALL core.sp_fee_defaulters_get(p_tenant, p_school, 39, NULL, NULL, c, p_year);
    LOOP
        FETCH c INTO r;
        EXIT WHEN NOT FOUND;
        IF r.student_name = p_name THEN v := v + r.total_outstanding; END IF;
    END LOOP;
    CLOSE c;
    RETURN v;
END $$;

-- Row count of the report (all entries) for one session view.
CREATE OR REPLACE FUNCTION pg_temp.rows_in(p_tenant int, p_school int, p_year text, p_legacy boolean DEFAULT FALSE)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'dr_' || md5(random()::text); r record; n int := 0;
BEGIN
    IF p_legacy THEN
        CALL core.sp_fee_defaulters_get(p_tenant, p_school, 39, NULL, NULL, c);   -- the old positional call
    ELSE
        CALL core.sp_fee_defaulters_get(p_tenant, p_school, 39, NULL, NULL, c, p_year);
    END IF;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; n := n + 1; END LOOP;
    CLOSE c;
    RETURN n;
END $$;


-- ── A. setup: roles BEFORE the payroll script runs ───────────────────────────
DO $setup$
DECLARE
    v_mgr  int; v_view int; v_off int; v_oth int;
    p_sm   int := (SELECT permission_id FROM config.permissions WHERE permission_key = 'staff.manage');
    p_sv   int := (SELECT permission_id FROM config.permissions WHERE permission_key = 'staff.view');
    p_pv   int := (SELECT permission_id FROM config.permissions WHERE permission_key = 'payroll.view');
BEGIN
    -- payroll.view must already exist for the "removed grant" fixture; the script
    -- creates it with ON CONFLICT DO NOTHING, so creating it here is harmless.
    IF p_pv IS NULL THEN
        INSERT INTO config.permissions (permission_key, module_group, display_name, sort_order)
        VALUES ('payroll.view', 'People', 'Payroll & Salary — View', 83) RETURNING permission_id INTO p_pv;
    END IF;

    INSERT INTO config.roles (tenant_id, school_id, role_name, role_code, created_by)
    VALUES (24, 34, 'ZZ HR Manager', 'ZZ_HR_MGR', 39) RETURNING role_id INTO v_mgr;
    INSERT INTO config.roles (tenant_id, school_id, role_name, role_code, created_by)
    VALUES (24, 34, 'ZZ HR Clerk', 'ZZ_HR_CLERK', 39) RETURNING role_id INTO v_view;
    INSERT INTO config.roles (tenant_id, school_id, role_name, role_code, created_by)
    VALUES (24, 34, 'ZZ HR No Pay', 'ZZ_HR_NOPAY', 39) RETURNING role_id INTO v_off;
    INSERT INTO config.roles (tenant_id, school_id, role_name, role_code, created_by)
    VALUES (23, 33, 'ZZ Other HR', 'ZZ_OTHER_HR', 39) RETURNING role_id INTO v_oth;

    INSERT INTO config.role_permissions (tenant_id, school_id, role_id, permission_id, created_by) VALUES
        (24, 34, v_mgr,  p_sm, 39), (24, 34, v_mgr,  p_sv, 39),
        (24, 34, v_view, p_sv, 39),
        (24, 34, v_off,  p_sm, 39),
        (23, 33, v_oth,  p_sm, 39);
    -- A school already took payroll.view away from this staff.manage role.
    INSERT INTO config.role_permissions (tenant_id, school_id, role_id, permission_id, is_allowed, is_deleted, created_by)
    VALUES (24, 34, v_off, p_pv, FALSE, TRUE, 39);

    INSERT INTO _fx VALUES ('mgr', v_mgr), ('view', v_view), ('off', v_off), ('oth', v_oth);
END
$setup$;

\ir ../payroll_permissions.sql

INSERT INTO _fx SELECT 'grants_after_1', COUNT(*)::int FROM config.role_permissions rp
  JOIN config.permissions p USING (permission_id) WHERE p.permission_key LIKE 'payroll.%';

\ir ../payroll_permissions.sql

INSERT INTO _fx SELECT 'grants_after_2', COUNT(*)::int FROM config.role_permissions rp
  JOIN config.permissions p USING (permission_id) WHERE p.permission_key LIKE 'payroll.%';
INSERT INTO _fx SELECT 'perms_after_2', COUNT(*)::int FROM config.permissions WHERE permission_key LIKE 'payroll.%';


DO $suite$
DECLARE
    c_tenant CONSTANT integer := 24;
    c_school CONSTANT integer := 34;
    c_user   CONSTANT integer := 39;
    o_tenant CONSTANT integer := 23;
    o_school CONSTANT integer := 33;

    v_mgr  int := (SELECT v FROM _fx WHERE k = 'mgr');
    v_view int := (SELECT v FROM _fx WHERE k = 'view');
    v_off  int := (SELECT v FROM _fx WHERE k = 'off');
    v_oth  int := (SELECT v FROM _fx WHERE k = 'oth');

    v_year   varchar;
    v_stu    int;
    v_sname  varchar;
    v_base   numeric;
    v_baseo  numeric;
    v_basea  numeric;
    v_n      int;
    v_txt    text;
    c        refcursor;
    r        record;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '========= SMALL FEATURES TESTS =========';

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- A. Payroll permission keys ---------------------------';

    SELECT COUNT(*) INTO v_n FROM config.permissions
     WHERE permission_key IN ('payroll.view', 'payroll.manage') AND module_group = 'People';
    PERFORM pg_temp.chk_eq('A1 payroll.view + payroll.manage exist (People)', v_n, 2);

    SELECT string_agg(display_name, ' | ' ORDER BY sort_order) INTO v_txt FROM config.permissions
     WHERE permission_key LIKE 'payroll.%';
    PERFORM pg_temp.chk('A2 one Roles-page row: "Payroll & Salary" view/manage',
                        v_txt = 'Payroll & Salary — View | Payroll & Salary — Manage', v_txt);

    PERFORM pg_temp.chk('A3 staff.manage role got both keys',
                        pg_temp.payroll_keys(v_mgr) = 'payroll.manage,payroll.view', pg_temp.payroll_keys(v_mgr));
    PERFORM pg_temp.chk('A4 staff.view-only role got none (no salary access)',
                        pg_temp.payroll_keys(v_view) = '', pg_temp.payroll_keys(v_view));
    PERFORM pg_temp.chk('A5 a removed payroll.view grant is not revived',
                        pg_temp.payroll_keys(v_off) = 'payroll.manage', pg_temp.payroll_keys(v_off));

    SELECT COUNT(*) INTO v_n FROM config.role_permissions rp JOIN config.permissions p USING (permission_id)
     WHERE rp.role_id = v_oth AND p.permission_key LIKE 'payroll.%'
       AND rp.tenant_id = o_tenant AND rp.school_id = o_school AND NOT rp.is_deleted;
    PERFORM pg_temp.chk_eq('A6 other school''s role granted in its OWN scope', v_n, 2);

    -- Every live staff.manage grant now carries both payroll keys (or a removed row).
    SELECT COUNT(*) INTO v_n
    FROM config.role_permissions rp JOIN config.permissions p USING (permission_id)
    CROSS JOIN config.permissions np
    WHERE p.permission_key = 'staff.manage' AND NOT rp.is_deleted
      AND np.permission_key IN ('payroll.view', 'payroll.manage')
      AND NOT EXISTS (SELECT 1 FROM config.role_permissions x
                      WHERE x.role_id = rp.role_id AND x.permission_id = np.permission_id
                        AND x.tenant_id IS NOT DISTINCT FROM rp.tenant_id
                        AND x.school_id IS NOT DISTINCT FROM rp.school_id);
    PERFORM pg_temp.chk_eq('A7 no staff.manage role left without the keys', v_n, 0);

    -- Nobody gained payroll who lacks staff.manage (fixture roles).
    SELECT COUNT(*) INTO v_n
    FROM config.role_permissions rp JOIN config.permissions p USING (permission_id)
    WHERE p.permission_key LIKE 'payroll.%' AND NOT rp.is_deleted
      AND rp.role_id IN (v_mgr, v_view, v_off, v_oth)
      AND NOT EXISTS (SELECT 1 FROM config.role_permissions x JOIN config.permissions xp USING (permission_id)
                      WHERE x.role_id = rp.role_id AND xp.permission_key = 'staff.manage' AND NOT x.is_deleted);
    PERFORM pg_temp.chk_eq('A8 no payroll grant without staff.manage', v_n, 0);

    PERFORM pg_temp.chk_eq('A9 re-run added no grants',
                           (SELECT v FROM _fx WHERE k = 'grants_after_2'), (SELECT v FROM _fx WHERE k = 'grants_after_1'));
    PERFORM pg_temp.chk_eq('A10 re-run added no permission rows', (SELECT v FROM _fx WHERE k = 'perms_after_2'), 2);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- B. Defaulters by session -----------------------------';

    SELECT academic_year_name INTO v_year FROM academic.academic_years
     WHERE tenant_id = c_tenant AND school_id = c_school AND is_current AND NOT is_deleted LIMIT 1;
    SELECT student_id, student_name INTO v_stu, v_sname FROM core.students
     WHERE tenant_id = c_tenant AND school_id = c_school ORDER BY student_id LIMIT 1;
    IF v_year IS NULL OR v_stu IS NULL THEN
        RAISE EXCEPTION 'Fixture missing: school % needs a current session and a student.', c_school;
    END IF;
    UPDATE core.students SET academic_year = v_year WHERE student_id = v_stu;

    -- A past session the school defined, so a dated old row can land in it.
    INSERT INTO academic.academic_years (tenant_id, school_id, academic_year_name, start_date, end_date, is_current, created_by)
    VALUES (c_tenant, c_school, 'ZZ 2019-20', '2019-04-01', '2020-03-31', FALSE, c_user);

    v_base  := pg_temp.owed(c_tenant, c_school, v_sname, v_year);
    v_baseo := pg_temp.owed(c_tenant, c_school, v_sname, 'ZZ 2019-20');
    v_basea := pg_temp.owed(c_tenant, c_school, v_sname, NULL);
    RAISE NOTICE 'fixture: session=%  student=% (%)  owed now: current=% all=%', v_year, v_sname, v_stu, v_base, v_basea;

    -- 1. stamped with its session (new billing) -> that session only
    INSERT INTO core.student_ledger (tenant_id, school_id, student_id, fee_head_name, frequency, due_date, amount_due, academic_year)
    VALUES (c_tenant, c_school, v_stu, 'ZZ Tuition', 'Monthly', '2019-06-10', 1000, 'ZZ 2019-20');
    -- 2. old row, no session, due date inside 2019-20 -> 2019-20 by its due date
    INSERT INTO core.student_ledger (tenant_id, school_id, student_id, fee_head_name, frequency, due_date, amount_due)
    VALUES (c_tenant, c_school, v_stu, 'ZZ Tuition', 'Monthly', '2019-07-10', 200);
    -- 3. old row, no session, due date in no session (2010) -> the student's session
    INSERT INTO core.student_ledger (tenant_id, school_id, student_id, fee_head_name, frequency, due_date, amount_due)
    VALUES (c_tenant, c_school, v_stu, 'ZZ Old Due', 'One Time', '2010-05-01', 30);
    -- 4. a row stamped with the CURRENT session, not yet due -> never counted as owed
    INSERT INTO core.student_ledger (tenant_id, school_id, student_id, fee_head_name, frequency, due_date, amount_due, academic_year)
    VALUES (c_tenant, c_school, v_stu, 'ZZ Future', 'Monthly', to_char(CURRENT_DATE + 40, 'YYYY-MM-DD'), 5000, v_year);

    PERFORM pg_temp.chk_eq('B1 stamped + due-date rows count in their session',
                           pg_temp.owed(c_tenant, c_school, v_sname, 'ZZ 2019-20') - v_baseo, 1200);
    PERFORM pg_temp.chk_eq('B2 undated-session old row falls back to student''s session',
                           pg_temp.owed(c_tenant, c_school, v_sname, v_year) - v_base, 30);
    PERFORM pg_temp.chk_eq('B3 All sessions shows every fallen-due row',
                           pg_temp.owed(c_tenant, c_school, v_sname, NULL) - v_basea, 1230);
    PERFORM pg_temp.chk_eq('B4 session name match ignores case/spaces',
                           pg_temp.owed(c_tenant, c_school, v_sname, '  zz 2019-20 ') - v_baseo, 1200);
    PERFORM pg_temp.chk_eq('B5 blank session = all sessions',
                           pg_temp.owed(c_tenant, c_school, v_sname, '') - v_basea, 1230);
    PERFORM pg_temp.chk_eq('B6 old positional call (no session) still = all sessions',
                           pg_temp.rows_in(c_tenant, c_school, NULL, TRUE), pg_temp.rows_in(c_tenant, c_school, NULL));

    -- 5. student with a blank session (the column is NOT NULL), undated row -> the current session
    UPDATE core.students SET academic_year = '' WHERE student_id = v_stu;
    PERFORM pg_temp.chk_eq('B7 nothing to place it by -> current session (not lost)',
                           pg_temp.owed(c_tenant, c_school, v_sname, v_year) - v_base, 30);
    UPDATE core.students SET academic_year = v_year WHERE student_id = v_stu;

    -- Exited students stay listed while they owe, in a session view too.
    UPDATE core.students SET is_active = FALSE, status = 'Transfer' WHERE student_id = v_stu;
    PERFORM pg_temp.chk_eq('B8 exited student still listed for an old session',
                           pg_temp.owed(c_tenant, c_school, v_sname, 'ZZ 2019-20') - v_baseo, 1200);
    UPDATE core.students SET is_active = TRUE, status = 'Active' WHERE student_id = v_stu;

    -- Registration balance rows follow the enquiry's session.
    INSERT INTO core.enquiries (tenant_id, school_id, student_name, class_name, session, mobile,
                                registration_fee_amount, registration_number)
    VALUES (c_tenant, c_school, 'ZZ Reg Session Kid', '1', 'ZZ 2019-20', '9000000091', 300, 'ZZREG91');
    PERFORM pg_temp.chk_eq('B9 registration row shows in its own session',
                           pg_temp.owed(c_tenant, c_school, 'ZZ Reg Session Kid', 'ZZ 2019-20'), 300);
    PERFORM pg_temp.chk_eq('B10 ...not in another session',
                           pg_temp.owed(c_tenant, c_school, 'ZZ Reg Session Kid', v_year), 0);
    PERFORM pg_temp.chk_eq('B11 ...and in All sessions',
                           pg_temp.owed(c_tenant, c_school, 'ZZ Reg Session Kid', NULL), 300);

    -- Scope: the other school sees none of it.
    PERFORM pg_temp.chk_eq('B12 other school''s report does not show our rows',
                           pg_temp.owed(o_tenant, o_school, 'ZZ Reg Session Kid', NULL)
                         + pg_temp.owed(o_tenant, o_school, v_sname, 'ZZ 2019-20'), 0);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- C. Remove school logo --------------------------------';

    UPDATE core.school_profiles SET logo_url = '/uploads/schools/24/34/logo_zz.png'
     WHERE tenant_id = c_tenant AND school_id = c_school;
    UPDATE core.school_profiles SET logo_url = '/uploads/schools/23/33/logo_other.png'
     WHERE tenant_id = o_tenant AND school_id = o_school;

    -- Our tenant with the other tenant's school: must touch nothing.
    c := 'c0';
    CALL core.sp_school_admin_basic_profile_manage(
        p_operation => 'RemoveLogo', p_tenant_id => c_tenant, p_school_id => o_school,
        p_action_user_id => c_user, p_result => c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('C1 cross-tenant remove finds no logo', r.removed_logo_url IS NULL, COALESCE(r.message, ''));
    SELECT logo_url INTO v_txt FROM core.school_profiles WHERE tenant_id = o_tenant AND school_id = o_school;
    PERFORM pg_temp.chk('C2 ...and the other school keeps its logo',
                        v_txt = '/uploads/schools/23/33/logo_other.png', COALESCE(v_txt, 'NULL'));

    c := 'c1';
    CALL core.sp_school_admin_basic_profile_manage(
        p_operation => 'RemoveLogo', p_tenant_id => c_tenant, p_school_id => c_school,
        p_action_user_id => c_user, p_result => c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('C3 remove returns the old URL (for the file delete)',
                        r.success AND r.removed_logo_url = '/uploads/schools/24/34/logo_zz.png', r.message);
    SELECT logo_url INTO v_txt FROM core.school_profiles WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk('C4 logo_url is cleared', v_txt IS NULL, COALESCE(v_txt, 'NULL'));

    c := 'c2';
    CALL core.sp_school_admin_basic_profile_manage(
        p_operation => 'GetBasicProfile', p_tenant_id => c_tenant, p_school_id => c_school,
        p_action_user_id => c_user, p_result => c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('C5 profile reads back with no logo', r.logo_url IS NULL, '');

    c := 'c3';
    CALL core.sp_school_admin_basic_profile_manage(
        p_operation => 'RemoveLogo', p_tenant_id => c_tenant, p_school_id => c_school,
        p_action_user_id => c_user, p_result => c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('C6 removing again is harmless', r.success AND r.removed_logo_url IS NULL, r.message);

    SELECT logo_url INTO v_txt FROM core.school_profiles WHERE tenant_id = o_tenant AND school_id = o_school;
    PERFORM pg_temp.chk('C7 other school''s logo untouched throughout',
                        v_txt = '/uploads/schools/23/33/logo_other.png', COALESCE(v_txt, 'NULL'));

    BEGIN
        c := 'c4';
        CALL core.sp_school_admin_basic_profile_manage(
            p_operation => 'RemoveLogo', p_tenant_id => 1, p_school_id => c_school,
            p_action_user_id => c_user, p_result => c);
        PERFORM pg_temp.chk('C8 platform tenant (1) refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C8 platform tenant (1) refused', TRUE, SQLERRM);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- D. Official phone: mobile or landline ----------------';

    PERFORM pg_temp.chk('D1 mobile kept',            core.fn_school_phone_clean('9876543210', 'x') = '9876543210', '');
    PERFORM pg_temp.chk('D2 0141-2345678 -> digits', core.fn_school_phone_clean('0141-2345678', 'x') = '01412345678', '');
    PERFORM pg_temp.chk('D3 011 23456789 -> digits', core.fn_school_phone_clean('011 23456789', 'x') = '01123456789', '');
    PERFORM pg_temp.chk('D4 01412345678 accepted',   core.fn_school_phone_clean('01412345678', 'x') = '01412345678', '');
    PERFORM pg_temp.chk('D5 12-digit landline ok',   core.fn_school_phone_clean('0124-12345678', 'x') = '012412345678', '');
    PERFORM pg_temp.chk('D6 blank -> NULL',          core.fn_school_phone_clean('  ', 'x') IS NULL, '');

    FOREACH v_txt IN ARRAY ARRAY['12345', '5876543210', '98765432101', '0141-23', '0141234567890',
                                 '+919876543210', '98765-4321a', 'phone', '1412345678'] LOOP
        BEGIN
            PERFORM core.fn_school_phone_clean(v_txt, 'Official phone');
            PERFORM pg_temp.chk('D7 junk refused: ' || v_txt, FALSE, 'it was accepted');
        EXCEPTION WHEN check_violation THEN
            PERFORM pg_temp.chk('D7 junk refused: ' || v_txt, TRUE, '');
        END;
    END LOOP;

    -- Through the real save: landline stored as digits, alternate too.
    c := 'd1';
    CALL core.sp_school_admin_basic_profile_manage(
        p_operation => 'UpdateBasicProfile', p_tenant_id => c_tenant, p_school_id => c_school,
        p_action_user_id => c_user, p_display_name => 'ZZ Roman',
        p_address_line1 => 'Plot 12, Sector 5', p_city => 'Gurugram', p_district => 'Gurugram',
        p_state => 'Haryana', p_pincode => '122001', p_contact_name => 'Anita Sharma',
        p_phone => '0124-2345678', p_alternate_phone => '98765 43210',
        p_state_id => 8, p_district_id => 199, p_result => c);
    CLOSE c;
    SELECT phone || '/' || COALESCE(alternate_phone, 'NULL') INTO v_txt FROM core.school_contacts
     WHERE tenant_id = c_tenant AND school_id = c_school AND contact_type_id = 1;
    PERFORM pg_temp.chk('D8 save stores landline + mobile as digits', v_txt = '01242345678/9876543210', v_txt);

    c := 'd2';
    CALL core.sp_school_admin_basic_profile_manage(
        p_operation => 'UpdateBasicProfile', p_tenant_id => c_tenant, p_school_id => c_school,
        p_action_user_id => c_user, p_display_name => 'ZZ Roman',
        p_address_line1 => 'Plot 12, Sector 5', p_city => 'Gurugram', p_district => 'Gurugram',
        p_state => 'Haryana', p_pincode => '122001', p_contact_name => 'Anita Sharma',
        p_phone => '9876543210', p_alternate_phone => '',
        p_state_id => 8, p_district_id => 199, p_result => c);
    CLOSE c;
    SELECT alternate_phone INTO v_txt FROM core.school_contacts
     WHERE tenant_id = c_tenant AND school_id = c_school AND contact_type_id = 1;
    PERFORM pg_temp.chk('D9 blank alternate phone stored as NULL', v_txt IS NULL, COALESCE(v_txt, 'NULL'));

    BEGIN
        c := 'd3';
        CALL core.sp_school_admin_basic_profile_manage(
            p_operation => 'UpdateBasicProfile', p_tenant_id => c_tenant, p_school_id => c_school,
            p_action_user_id => c_user, p_address_line1 => 'Plot 12', p_city => 'Gurugram',
            p_state => 'Haryana', p_pincode => '122001', p_contact_name => 'Anita Sharma',
            p_phone => '12345', p_result => c);
        PERFORM pg_temp.chk('D10 save refuses a junk official phone', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('D10 save refuses a junk official phone', SQLERRM LIKE 'Official phone%', SQLERRM);
    END;

    BEGIN
        c := 'd4';
        CALL core.sp_school_admin_basic_profile_manage(
            p_operation => 'UpdateBasicProfile', p_tenant_id => c_tenant, p_school_id => c_school,
            p_action_user_id => c_user, p_address_line1 => 'Plot 12', p_city => 'Gurugram',
            p_state => 'Haryana', p_pincode => '122001', p_contact_name => 'Anita Sharma',
            p_phone => '9876543210', p_alternate_phone => '0141-23', p_result => c);
        PERFORM pg_temp.chk('D11 save refuses a junk alternate phone', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('D11 save refuses a junk alternate phone', SQLERRM LIKE 'Alternate phone%', SQLERRM);
    END;

    SELECT phone INTO v_txt FROM core.school_contacts
     WHERE tenant_id = o_tenant AND school_id = o_school AND contact_type_id = 1;
    PERFORM pg_temp.chk('D12 other school''s phone untouched', v_txt NOT IN ('01242345678'), COALESCE(v_txt, 'NULL'));
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
