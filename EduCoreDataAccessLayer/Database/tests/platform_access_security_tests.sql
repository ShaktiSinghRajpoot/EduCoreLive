-- ============================================================================
-- Platform, access and security test suite.
--
-- Who can get in, what they can do once they are in, and what the platform
-- can do to a school. A bug here does not show up as a wrong number on a
-- page: it shows up as a teacher who left in March still signing in, or a
-- suspended school still working, or a "Super Admin" role nobody can see.
--
-- Goes deeper than roles_tests.sql (which already covers blank/duplicate role
-- names, built-in rename/delete, basic grant/revoke and the "assigned role
-- cannot be deleted" rule) and dashboard_tests.sql. Those are not repeated.
--
-- Runs inside ONE transaction and ROLLS BACK.
--
--     psql ... -f platform_access_security_tests.sql
--
-- Checks are named after the CORRECT behaviour. The first run found 23 bugs; all
-- are fixed (Oct 2026) and their checks now assert the fix. Ids point at the catalog:
--     educore/docs/test-cases/platform_access_security.md
--
-- COVERS
--   A. Login lookup and the school gate        (core.sp_login_management)
--   B. Login audit and change password
--   C. Password reset by OTP                   (core.sp_password_reset)
--   D. Roles, deeper                           (config.sp_role_manage)
--   E. Permission matrix, deeper               (config.sp_role_permissions_*)
--   F. Users, roles and deactivation           (core.sp_user_roles_resolve, sp_staff_manage)
--   G. Super admin: schools                    (core.sp_school_manage, sp_school_list)
--   H. Super admin: purge and archive          (core.sp_school_purge, sp_school_archive)
--   I. Module toggles                          (sp_school_admin_admission_workflow_manage)
--   J. Dashboard and geo scope
--   L. Sessions and the security stamp       (core.sp_session_check)
--   F12-F17 who may change roles / deactivate (decisions D-2, D-3)
--   Audit rows (decision D-6) are checked where each change is made
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
                 rpad(p_name, 60), p_detail;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.chk_eq(p_name text, p_got numeric, p_want numeric)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.chk(p_name, p_got IS NOT DISTINCT FROM p_want,
                        format('got %s, expected %s', COALESCE(p_got::text,'NULL'), p_want));
END $$;

-- Rows in a refcursor (fetches them all, then closes it). A refcursor proc does
-- nothing until it is fetched, so every check below fetches.
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


-- Save one staff row's role set as a given actor (everything else unchanged).
CREATE OR REPLACE FUNCTION pg_temp.staff_roles(p_staff_id integer, p_actor integer, p_roles integer[])
RETURNS void LANGUAGE plpgsql AS $$
DECLARE s record; c refcursor := 'staff_roles_c';
BEGIN
    SELECT * INTO s FROM core.staff WHERE staff_id = p_staff_id;
    CALL core.sp_staff_manage('UPDATE', s.tenant_id, s.school_id, p_actor, s.staff_id,
         s.employee_code::text, s.full_name::text, s.gender::text, s.dob::date, s.mobile::text,
         s.alt_mobile::text, s.email::text, s.blood_group::text, s.address::text, s.staff_type::text,
         s.department::text, s.designation::text, s.joining_date::date, s.qualification::text,
         s.experience_years, s.status::text, s.monthly_salary, s.bank_account_no::text,
         s.ifsc_code::text, s.pan::text, s.aadhaar::text,
         FALSE, NULL, p_roles, NULL, NULL, c);
    CLOSE c;
END $$;

-- Deactivate one staff row as a given actor.
CREATE OR REPLACE FUNCTION pg_temp.staff_off(p_staff_id integer, p_actor integer)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE s record; c refcursor := 'staff_off_c';
BEGIN
    SELECT * INTO s FROM core.staff WHERE staff_id = p_staff_id;
    CALL core.sp_staff_manage('DELETE', s.tenant_id, s.school_id, p_actor, s.staff_id,
         NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
         NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, c);
    CLOSE c;
END $$;


DO $suite$
DECLARE
    c_tenant CONSTANT integer := 24;
    c_school CONSTANT integer := 34;
    c_user   CONSTANT integer := 39;     -- SCHOOL_ADMIN of school 34

    c_tenant_b CONSTANT integer := 23;   -- another tenant / school
    c_school_b CONSTANT integer := 33;

    v_email  text;
    v_phone  text;
    v_acct   integer;                    -- an ACCOUNTANT-only login in school 34
    v_acct_staff integer;
    v_role_teacher integer;
    v_role_acct    integer;
    v_role_admin   integer;
    v_role_admin_b integer;              -- tenant 23's SCHOOL_ADMIN role id
    v_custom integer;
    v_super  integer;
    v_super_mail text;
    v_acct_mail  text;
    v_name_a     text;
    v_name_b     text;

    c     refcursor;
    r     record;
    v_n   integer;
    v_m   integer;
    v_txt text;
    v_ok  boolean;
    v_new integer;
    v_new2 integer;
    v_code text;
    v_seq  integer;
    v_ids  integer[];
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '========= PLATFORM / ACCESS / SECURITY TESTS =========';

    SELECT u.email, up.phone INTO v_email, v_phone
    FROM core.users u JOIN core.user_profiles up ON up.user_id = u.user_id
    WHERE u.user_id = c_user;

    SELECT role_id INTO v_role_admin   FROM config.roles WHERE tenant_id = c_tenant   AND role_code = 'SCHOOL_ADMIN' AND NOT is_deleted;
    SELECT role_id INTO v_role_teacher FROM config.roles WHERE tenant_id = c_tenant   AND role_code = 'TEACHER'      AND NOT is_deleted;
    SELECT role_id INTO v_role_acct    FROM config.roles WHERE tenant_id = c_tenant   AND role_code = 'ACCOUNTANT'   AND NOT is_deleted;
    SELECT role_id INTO v_role_admin_b FROM config.roles WHERE tenant_id = c_tenant_b AND role_code = 'SCHOOL_ADMIN' AND NOT is_deleted;

    -- An active staff member whose ONLY role is Accountant.
    SELECT s.staff_id, s.user_id INTO v_acct_staff, v_acct
    FROM core.staff s
    JOIN core.users u ON u.user_id = s.user_id AND u.is_active AND NOT u.is_deleted
    WHERE s.tenant_id = c_tenant AND s.school_id = c_school AND s.is_active
      AND (SELECT array_agg(ur.role_id) FROM core.user_roles ur
            WHERE ur.user_id = s.user_id AND NOT ur.is_deleted AND ur.is_active) = ARRAY[v_role_acct]
    ORDER BY s.staff_id LIMIT 1;

    SELECT u.user_id INTO v_super
    FROM core.users u JOIN core.user_roles ur ON ur.user_id = u.user_id AND NOT ur.is_deleted
    JOIN config.roles rr ON rr.role_id = ur.role_id AND rr.role_code = 'SUPER_ADMIN'
    WHERE u.tenant_id = 1 AND u.is_active AND NOT u.is_deleted ORDER BY u.user_id LIMIT 1;

    IF v_email IS NULL OR v_role_admin IS NULL OR v_role_acct IS NULL OR v_acct IS NULL
       OR v_role_admin_b IS NULL OR v_super IS NULL THEN
        RAISE EXCEPTION 'Fixture missing: email=% admin_role=% acct_role=% acct_user=% role_b=% super=%',
            v_email, v_role_admin, v_role_acct, v_acct, v_role_admin_b, v_super;
    END IF;
    SELECT email INTO v_super_mail FROM core.users WHERE user_id = v_super;
    SELECT email INTO v_acct_mail  FROM core.users WHERE user_id = v_acct;
    SELECT school_name INTO v_name_a FROM core.schools WHERE school_id = c_school;
    SELECT school_name INTO v_name_b FROM core.schools WHERE school_id = c_school_b;
    RAISE NOTICE 'fixture: admin=% (%), accountant user=% staff=%, super=%',
        c_user, v_email, v_acct, v_acct_staff, v_super;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- A. Login lookup and the school gate -----------------';

    c := 'a1';
    CALL core.sp_login_management('GET_LOGIN_USER', p_email => '  ' || upper(v_email) || ' ', p_result => c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('A1 email login ignores case and surrounding spaces',
                        r.user_id = c_user, format('user_id=%s', r.user_id));

    c := 'a2';
    CALL core.sp_login_management('GET_LOGIN_USER',
         p_email => '+91 ' || substr(v_phone, 1, 5) || '-' || substr(v_phone, 6), p_result => c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('A2 phone login ignores +91, spaces and dashes',
                        r.user_id = c_user, format('user_id=%s', r.user_id));

    c := 'a3';
    CALL core.sp_login_management('GET_LOGIN_USER', p_email => 'nobody.zz@example.invalid', p_result => c);
    PERFORM pg_temp.chk_eq('A3 an unknown identifier finds nobody', pg_temp.cur_count(c), 0);

    -- A short digit string must never match a phone (an email has < 10 digits).
    c := 'a3b';
    CALL core.sp_login_management('GET_LOGIN_USER', p_email => right(v_phone, 6), p_result => c);
    PERFORM pg_temp.chk_eq('A3b a 6-digit fragment of a phone matches nobody', pg_temp.cur_count(c), 0);

    -- Deactivated / deleted users are filtered in the proc, so the controller's
    -- "your account is not active" branch is unreachable -- no enumeration.
    UPDATE core.users SET is_active = FALSE WHERE user_id = c_user;
    c := 'a4';
    CALL core.sp_login_management('GET_LOGIN_USER', p_email => v_email, p_result => c);
    PERFORM pg_temp.chk_eq('A4 a deactivated user cannot be found to log in', pg_temp.cur_count(c), 0);
    UPDATE core.users SET is_active = TRUE, is_deleted = TRUE WHERE user_id = c_user;
    c := 'a5';
    CALL core.sp_login_management('GET_LOGIN_USER', p_email => v_email, p_result => c);
    PERFORM pg_temp.chk_eq('A5 a soft-deleted user cannot be found to log in', pg_temp.cur_count(c), 0);
    UPDATE core.users SET is_deleted = FALSE WHERE user_id = c_user;

    -- Every school status: the login gate follows config.school_statuses.allows_login.
    DECLARE s record;
    BEGIN
        FOR s IN SELECT school_status_id, status_code, allows_login
                 FROM config.school_statuses WHERE NOT is_deleted ORDER BY display_order LOOP
            UPDATE core.schools SET status_id = s.school_status_id WHERE school_id = c_school;
            c := 'a6_' || s.school_status_id;
            CALL core.sp_login_management('GET_LOGIN_USER', p_email => v_email, p_result => c);
            FETCH c INTO r; CLOSE c;
            PERFORM pg_temp.chk(format('A6 status %s %s login', s.status_code,
                                       CASE WHEN s.allows_login THEN 'allows' ELSE 'blocks' END),
                                r.school_allows_login IS NOT DISTINCT FROM s.allows_login
                                AND r.school_status_code = s.status_code,
                                format('allows=%s code=%s msg=%s', r.school_allows_login,
                                       r.school_status_code, COALESCE(r.school_login_message, '')));
        END LOOP;
        UPDATE core.schools SET status_id = 1 WHERE school_id = c_school;
    END;

    -- A disabled school blocks login whatever its status says.
    UPDATE core.schools SET is_active = FALSE WHERE school_id = c_school;
    c := 'a7';
    CALL core.sp_login_management('GET_LOGIN_USER', p_email => v_email, p_result => c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('A7 a disabled school blocks login even when status is Active',
                        r.school_allows_login = FALSE AND r.school_login_message ILIKE '%closed%',
                        format('allows=%s msg=%s', r.school_allows_login, r.school_login_message));
    UPDATE core.schools SET is_active = TRUE WHERE school_id = c_school;

    c := 'a8';
    CALL core.sp_login_management('GET_LOGIN_USER', p_email => v_super_mail, p_result => c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('A8 the platform super admin (no school) passes the gate',
                        r.school_allows_login = TRUE AND r.tenant_id = 1 AND COALESCE(r.school_id, 0) = 0,
                        format('allows=%s tenant=%s school=%s', r.school_allows_login, r.tenant_id, r.school_id));

    -- Removing a person's only role removes their login.
    UPDATE core.user_roles SET is_deleted = TRUE WHERE user_id = v_acct;
    c := 'a9';
    CALL core.sp_login_management('GET_LOGIN_USER', p_user_id => NULL,
         p_email => v_acct_mail, p_result => c);
    PERFORM pg_temp.chk_eq('A9 a user whose only role was removed cannot log in', pg_temp.cur_count(c), 0);
    UPDATE core.user_roles SET is_deleted = FALSE WHERE user_id = v_acct;

    -- Multi-role: the picker lists every live role, primary first.
    -- (Any active login of school 34 holding more than one role.)
    SELECT ur.user_id INTO v_new
    FROM core.user_roles ur JOIN core.users u ON u.user_id = ur.user_id AND u.is_active AND NOT u.is_deleted
    WHERE ur.tenant_id = c_tenant AND ur.school_id = c_school AND NOT ur.is_deleted AND ur.is_active
    GROUP BY ur.user_id HAVING COUNT(*) > 1 ORDER BY ur.user_id LIMIT 1;
    c := 'a10';
    CALL core.sp_login_management('GET_USER_ROLES', p_user_id => v_new, p_result => c);
    v_n := pg_temp.cur_count(c);
    SELECT COUNT(*) INTO v_m FROM core.user_roles ur JOIN config.roles rr ON rr.role_id = ur.role_id AND rr.tenant_id = ur.tenant_id
     WHERE ur.user_id = v_new AND NOT ur.is_deleted AND ur.is_active AND NOT rr.is_deleted AND rr.is_active;
    PERFORM pg_temp.chk('A10 the role picker lists every live role of a multi-role user',
                        v_n = v_m AND v_n > 1, format('%s listed, %s live', v_n, v_m));

    -- A custom role is the whole point of dynamic RBAC. The login lookup finds a
    -- custom-role user fine; AccountController.IsValidSaasScope then has to accept
    -- the role code, and it only accepts the five built-in codes (+ TENANT_ADMIN).
    c := 'a11r';
    CALL config.sp_role_manage('INSERT', c_tenant, c_school, c_user, NULL, 'ZZ Librarian', NULL, c);
    FETCH c INTO r; CLOSE c;
    v_custom := r.role_id;
    UPDATE core.user_roles SET role_id = v_custom WHERE user_id = v_acct AND role_id = v_role_acct;
    c := 'a11';
    CALL core.sp_login_management('GET_LOGIN_USER',
         p_email => v_acct_mail, p_result => c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('A11 the login lookup finds a custom-role user',
                        r.user_id = v_acct, format('role_code=%s', r.role_code));
    -- AccountController.IsValidSaasScope: any code except SUPER_ADMIN / TENANT_ADMIN
    -- is a school role and needs tenant > 1 and school > 0.
    PERFORM pg_temp.chk('A12 a custom-role user passes the login scope check (AUTH-12)',
                        r.role_code NOT IN ('SUPER_ADMIN','TENANT_ADMIN') AND r.tenant_id > 1 AND r.school_id > 0,
                        format('role_code=%s tenant=%s school=%s', r.role_code, r.tenant_id, r.school_id));
    UPDATE core.user_roles SET role_id = v_role_acct WHERE user_id = v_acct AND role_id = v_custom;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- B. Login audit and change password ------------------';

    SELECT COUNT(*) INTO v_m FROM core.login_attempts;
    CALL core.sp_login_management('SAVE_LOGIN_ATTEMPT', p_email => upper(v_email), p_is_success => FALSE,
         p_failure_reason => 'ZZ test wrong password', p_result => c);
    SELECT user_id INTO v_n FROM core.login_attempts WHERE failure_reason = 'ZZ test wrong password' ORDER BY 1 DESC LIMIT 1;
    PERFORM pg_temp.chk('B1 a failed login is recorded against the right user',
                        v_n = c_user, format('user_id=%s', v_n));

    CALL core.sp_login_management('SAVE_LOGIN_ATTEMPT', p_email => '+91' || v_phone, p_is_success => FALSE,
         p_failure_reason => 'ZZ test phone', p_result => c);
    SELECT user_id INTO v_n FROM core.login_attempts WHERE failure_reason = 'ZZ test phone' ORDER BY 1 DESC LIMIT 1;
    PERFORM pg_temp.chk('B2 a login attempt by phone is attributed to the user',
                        v_n = c_user, format('user_id=%s', v_n));

    CALL core.sp_login_management('SAVE_LOGIN_ATTEMPT', p_email => 'ghost.zz@example.invalid', p_is_success => FALSE,
         p_failure_reason => 'ZZ test ghost', p_result => c);
    SELECT COUNT(*) INTO v_n FROM core.login_attempts WHERE failure_reason = 'ZZ test ghost' AND user_id IS NULL;
    PERFORM pg_temp.chk_eq('B3 an attempt on an unknown email is still logged (no user)', v_n, 1);

    -- LoginService.SaveLoginAttemptAsync now passes the client IP and user agent
    -- (AUTH-21); the proc must keep both.
    CALL core.sp_login_management('SAVE_LOGIN_ATTEMPT', p_email => v_email, p_is_success => FALSE,
         p_failure_reason => 'ZZ test ip', p_ip_address => '203.0.113.7', p_user_agent => 'ZZ-UA', p_result => c);
    SELECT COUNT(*) INTO v_n FROM core.login_attempts
     WHERE failure_reason = 'ZZ test ip' AND ip_address = '203.0.113.7' AND user_agent = 'ZZ-UA';
    PERFORM pg_temp.chk_eq('B3b a login attempt records the client IP and agent (AUTH-21)', v_n, 1);

    CALL core.sp_login_management('SAVE_USER_SESSION', p_user_id => c_user, p_ip_address => '10.0.0.9', p_user_agent => 'ZZ-agent', p_result => c);
    SELECT COUNT(*) INTO v_n FROM core.user_sessions WHERE user_id = c_user AND user_agent = 'ZZ-agent' AND school_id = c_school;
    PERFORM pg_temp.chk_eq('B4 a successful sign-in opens a session row for the right school', v_n, 1);

    UPDATE core.users SET must_change_password = TRUE WHERE user_id = c_user;
    CALL core.sp_login_management('CHANGE_PASSWORD', p_user_id => c_user, p_password_hash => 'ZZ-new-hash', p_result => c);
    SELECT (password_hash = 'ZZ-new-hash' AND NOT must_change_password) INTO v_ok FROM core.users WHERE user_id = c_user;
    PERFORM pg_temp.chk('B5 change password stores the new hash and lifts the forced reset', v_ok, '');

    UPDATE core.users SET is_active = FALSE WHERE user_id = v_acct;
    BEGIN
        CALL core.sp_login_management('CHANGE_PASSWORD', p_user_id => v_acct, p_password_hash => 'ZZ-x', p_result => c);
        PERFORM pg_temp.chk('B6 a deactivated user cannot change a password', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('B6 a deactivated user cannot change a password', TRUE, SQLERRM);
    END;
    UPDATE core.users SET is_active = TRUE WHERE user_id = v_acct;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- L. Sessions and the security stamp ------------------';

    -- SessionValidator (Program.cs cookie OnValidatePrincipal) asks this proc, at
    -- most once a minute per user, and rejects the cookie when any answer is wrong.
    DECLARE s0 text; s1 text;
    BEGIN
        UPDATE core.users SET password_changed_at = NULL WHERE user_id = v_acct;
        c := 'l1a';
        CALL core.sp_session_check(v_acct, c_school, c);
        FETCH c INTO r; CLOSE c;
        s0 := r.password_stamp;
        PERFORM pg_temp.chk('L1 an active user of an open school passes the session check',
                            r.user_ok AND r.school_ok AND s0 = '0',
                            format('user_ok=%s school_ok=%s stamp=%s', r.user_ok, r.school_ok, s0));

        CALL core.sp_login_management('CHANGE_PASSWORD', p_user_id => v_acct, p_password_hash => 'ZZ-stamp', p_result => c);
        c := 'l2';
        CALL core.sp_session_check(v_acct, c_school, c);
        FETCH c INTO r; CLOSE c;
        s1 := r.password_stamp;
        PERFORM pg_temp.chk('L2 a password change moves the security stamp (AUTH-48)',
                            s1 IS DISTINCT FROM s0, format('%s -> %s', s0, s1));

        c := 'l3';
        CALL core.sp_login_management('GET_LOGIN_USER', p_email => v_acct_mail, p_result => c);
        FETCH c INTO r; CLOSE c;
        PERFORM pg_temp.chk('L3 the login lookup hands the cookie the same stamp',
                            r.password_stamp = s1, format('login=%s check=%s', r.password_stamp, s1));
    END;

    UPDATE core.users SET is_active = FALSE WHERE user_id = v_acct;
    c := 'l4';
    CALL core.sp_session_check(v_acct, c_school, c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('L4 a deactivated user fails the session check (SEC-02)', r.user_ok = FALSE,
                        format('user_ok=%s', r.user_ok));
    UPDATE core.users SET is_active = TRUE WHERE user_id = v_acct;

    UPDATE core.schools SET status_id = 7 WHERE school_id = c_school;
    c := 'l5';
    CALL core.sp_session_check(v_acct, c_school, c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('L5 a suspended school fails the session check (SEC-04)', r.school_ok = FALSE,
                        format('school_ok=%s', r.school_ok));
    UPDATE core.schools SET status_id = 1 WHERE school_id = c_school;

    c := 'l6';
    CALL core.sp_session_check(v_super, 0, c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('L6 the platform super admin (no school) passes the session check',
                        r.user_ok AND r.school_ok, format('user_ok=%s school_ok=%s', r.user_ok, r.school_ok));

    c := 'l7';
    CALL core.sp_session_check(-1, c_school, c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('L7 an unknown user id fails the session check', r.user_ok = FALSE,
                        format('user_ok=%s', r.user_ok));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- C. Password reset by OTP ----------------------------';

    DECLARE v_mail text; v_tok1 integer; v_tok2 integer;
    BEGIN
        SELECT email INTO v_mail FROM core.users WHERE user_id = v_acct;

        c := 'c1';
        CALL core.sp_password_reset('REQUEST', upper(v_mail), 'OTP-ONE', NULL, NULL, c);
        FETCH c INTO r; CLOSE c;
        SELECT password_reset_token_id INTO v_tok1 FROM core.password_reset_tokens
         WHERE user_id = v_acct AND token_hash = 'OTP-ONE' AND used_at IS NULL;
        PERFORM pg_temp.chk('C1 a reset request for a known email issues one code',
                            r.user_id = v_acct AND v_tok1 IS NOT NULL, format('token=%s', v_tok1));

        SELECT EXTRACT(EPOCH FROM (expires_at - created_at))::int INTO v_n
          FROM core.password_reset_tokens WHERE password_reset_token_id = v_tok1;
        PERFORM pg_temp.chk('C2 the code expires in 10 minutes', v_n BETWEEN 590 AND 610,
                            format('%s seconds', v_n));

        c := 'c3';
        CALL core.sp_password_reset('REQUEST', 'ghost.zz@example.invalid', 'OTP-GHOST', NULL, NULL, c);
        v_n := pg_temp.cur_count(c);
        SELECT COUNT(*) INTO v_m FROM core.password_reset_tokens WHERE token_hash = 'OTP-GHOST';
        PERFORM pg_temp.chk('C3 an unknown email gets no code and no contact row',
                            v_n = 0 AND v_m = 0, format('%s rows, %s tokens', v_n, v_m));

        c := 'c4';
        CALL core.sp_password_reset('REQUEST', v_mail, 'OTP-TWO', NULL, NULL, c);
        CLOSE c;
        SELECT COUNT(*) INTO v_n FROM core.password_reset_tokens
         WHERE user_id = v_acct AND used_at IS NULL AND NOT is_deleted;
        PERFORM pg_temp.chk_eq('C4 a second request leaves exactly one live code', v_n, 1);

        c := 'c5';
        CALL core.sp_password_reset('RESET_WITH_OTP', NULL, 'OTP-ONE', 'ZZ-H', v_acct, c);
        FETCH c INTO r; CLOSE c;
        PERFORM pg_temp.chk('C5 the superseded first code no longer works',
                            r.status <> 'OK', format('status=%s', r.status));

        c := 'c6';
        CALL core.sp_password_reset('RESET_WITH_OTP', NULL, 'WRONG', 'ZZ-H', v_acct, c);
        FETCH c INTO r; CLOSE c;
        PERFORM pg_temp.chk('C6 a wrong code is refused as INVALID', r.status = 'INVALID',
                            format('status=%s', r.status));

        -- Enumeration: an identifier that matched NOBODY is carried as user 0. Its
        -- wrong code must look exactly like a real user's wrong code, or the
        -- "Incorrect code" vs "Your code has expired" message tells an attacker
        -- which emails/phones have accounts.
        c := 'c7';
        CALL core.sp_password_reset('RESET_WITH_OTP', NULL, 'WRONG', 'ZZ-H', 0, c);
        FETCH c INTO r; CLOSE c;
        PERFORM pg_temp.chk('C7 an unknown account answers like a known one (AUTH-37)',
                            r.status = 'INVALID', format('unknown -> %s, known -> INVALID', r.status));

        -- Lockout: 5 wrong guesses in total burn the code.
        -- C5 and C6 were wrong guesses 1 and 2 on this code; three more make five.
        FOR v_n IN 1..3 LOOP
            c := 'c8_' || v_n;
            CALL core.sp_password_reset('RESET_WITH_OTP', NULL, 'WRONG', 'ZZ-H', v_acct, c);
            CLOSE c;
        END LOOP;
        c := 'c8';
        CALL core.sp_password_reset('RESET_WITH_OTP', NULL, 'OTP-TWO', 'ZZ-H', v_acct, c);
        FETCH c INTO r; CLOSE c;
        PERFORM pg_temp.chk('C8 after 5 wrong guesses even the right code is LOCKED',
                            r.status = 'LOCKED', format('status=%s', r.status));
        c := 'c8b';
        CALL core.sp_password_reset('RESET_WITH_OTP', NULL, 'OTP-TWO', 'ZZ-H', v_acct, c);
        FETCH c INTO r; CLOSE c;
        PERFORM pg_temp.chk('C8b ...and stays dead afterwards', r.status <> 'OK', format('status=%s', r.status));

        -- Happy path, then reuse.
        UPDATE core.users SET must_change_password = TRUE, password_changed_at = NULL WHERE user_id = v_acct;
        c := 'c9r';
        CALL core.sp_password_reset('REQUEST', v_mail, 'OTP-THREE', NULL, NULL, c);
        CLOSE c;
        c := 'c9';
        CALL core.sp_password_reset('RESET_WITH_OTP', NULL, 'OTP-THREE', 'ZZ-RESET-HASH', v_acct, c);
        FETCH c INTO r; CLOSE c;
        SELECT (password_hash = 'ZZ-RESET-HASH' AND NOT must_change_password) INTO v_ok FROM core.users WHERE user_id = v_acct;
        PERFORM pg_temp.chk('C9 the right code resets the password', r.status = 'OK' AND v_ok,
                            format('status=%s', r.status));
        SELECT password_changed_at IS NOT NULL INTO v_ok FROM core.users WHERE user_id = v_acct;
        PERFORM pg_temp.chk('C9b an OTP reset moves the security stamp (ends old sessions)', v_ok, '');

        c := 'c10';
        CALL core.sp_password_reset('RESET_WITH_OTP', NULL, 'OTP-THREE', 'ZZ-REUSE', v_acct, c);
        FETCH c INTO r; CLOSE c;
        SELECT password_hash INTO v_txt FROM core.users WHERE user_id = v_acct;
        PERFORM pg_temp.chk('C10 a used code cannot be replayed', r.status <> 'OK' AND v_txt = 'ZZ-RESET-HASH',
                            format('status=%s', r.status));

        c := 'c11r';
        CALL core.sp_password_reset('REQUEST', v_mail, 'OTP-FOUR', NULL, NULL, c);
        CLOSE c;
        UPDATE core.password_reset_tokens SET expires_at = now() - interval '1 second'
         WHERE user_id = v_acct AND token_hash = 'OTP-FOUR';
        c := 'c11';
        CALL core.sp_password_reset('RESET_WITH_OTP', NULL, 'OTP-FOUR', 'ZZ-LATE', v_acct, c);
        FETCH c INTO r; CLOSE c;
        PERFORM pg_temp.chk('C11 an expired code is refused even when correct', r.status = 'EXPIRED',
                            format('status=%s', r.status));

        UPDATE core.users SET is_active = FALSE WHERE user_id = v_acct;
        c := 'c12';
        CALL core.sp_password_reset('REQUEST', v_mail, 'OTP-INACTIVE', NULL, NULL, c);
        CLOSE c;
        SELECT COUNT(*) INTO v_n FROM core.password_reset_tokens WHERE token_hash = 'OTP-INACTIVE';
        PERFORM pg_temp.chk_eq('C12 a deactivated user gets no reset code', v_n, 0);
        UPDATE core.users SET is_active = TRUE WHERE user_id = v_acct;

        -- Login accepts '+91 98390-73643'; reset should find the same person.
        c := 'c13';
        CALL core.sp_password_reset('REQUEST', '+91 ' || substr(v_phone, 1, 5) || ' ' || substr(v_phone, 6),
             'OTP-PHONE', NULL, NULL, c);
        v_n := pg_temp.cur_count(c);
        PERFORM pg_temp.chk('C13 reset by phone accepts the formats login accepts (AUTH-43)',
                            v_n = 1, format('formatted phone matched %s user(s); login matches it', v_n));
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- D. Roles, deeper ------------------------------------';

    -- A school naming a role "Super Admin" must not be handed the platform's
    -- reserved code: PermissionService.IsAdminCode treats SUPER_ADMIN as a full
    -- bypass, and sp_role_manage LIST hides SUPER_ADMIN rows from the school.
    c := 'd1';
    CALL config.sp_role_manage('INSERT', c_tenant, c_school, c_user, NULL, 'Super Admin', NULL, c);
    FETCH c INTO r; CLOSE c;
    SELECT role_code INTO v_code FROM config.roles WHERE role_id = r.role_id;
    PERFORM pg_temp.chk('D1 a school role never gets the reserved SUPER_ADMIN code (RBAC-01)',
                        v_code IS DISTINCT FROM 'SUPER_ADMIN', format('role_code=%s', v_code));

    c := 'd2';
    CALL config.sp_role_manage('LIST', c_tenant, c_school, c_user, NULL, NULL, NULL, c);
    v_ok := FALSE;
    LOOP
        FETCH c INTO r; EXIT WHEN NOT FOUND;
        IF r.role_name = 'Super Admin' THEN v_ok := TRUE; END IF;
    END LOOP;
    CLOSE c;
    PERFORM pg_temp.chk('D2 every role a school creates shows in its role list (RBAC-02)', v_ok,
                        'the "Super Admin" role it just created is hidden by LIST');

    c := 'd3';
    CALL config.sp_role_manage('INSERT', c_tenant, c_school, c_user, NULL, 'School_Admin', NULL, c);
    FETCH c INTO r; CLOSE c;
    SELECT role_code INTO v_code FROM config.roles WHERE role_id = r.role_id;
    PERFORM pg_temp.chk('D3 a lookalike of School Admin gets a de-duped code, not the admin code',
                        v_code <> 'SCHOOL_ADMIN', format('role_code=%s', v_code));

    BEGIN
        c := 'd4';
        CALL config.sp_role_manage('INSERT', c_tenant, c_school, c_user, NULL, '   zz librarian  ', NULL, c);
        PERFORM pg_temp.chk('D4 a padded, differently-cased duplicate name refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('D4 a padded, differently-cased duplicate name refused', TRUE, SQLERRM);
    END;

    c := 'd5';
    CALL config.sp_role_manage('GET', c_tenant_b, c_school_b, 38, v_custom, NULL, NULL, c);
    PERFORM pg_temp.chk_eq('D5 another tenant cannot read our custom role', pg_temp.cur_count(c), 0);

    BEGIN
        c := 'd6';
        CALL config.sp_role_manage('UPDATE', c_tenant_b, c_school_b, 38, v_custom, 'ZZ Hijacked', NULL, c);
        PERFORM pg_temp.chk('D6 another tenant cannot rename our custom role', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('D6 another tenant cannot rename our custom role', TRUE, SQLERRM);
    END;

    -- Documented design: roles are per TENANT. Tenant 25 runs two schools; both
    -- see (and can edit) the same role list. Recorded so a change is deliberate.
    c := 'd7a';
    CALL config.sp_role_manage('LIST', 25, 35, 40, NULL, NULL, NULL, c);
    v_n := pg_temp.cur_count(c);
    c := 'd7b';
    CALL config.sp_role_manage('LIST', 25, 36, 41, NULL, NULL, NULL, c);
    v_m := pg_temp.cur_count(c);
    PERFORM pg_temp.chk('D7 two schools of one tenant share one role list (by design)',
                        v_n = v_m AND v_n > 0, format('school 35: %s, school 36: %s', v_n, v_m));

    -- A role whose only assignment was removed is no longer "in use".
    INSERT INTO core.user_roles (tenant_id, user_id, role_id, school_id, is_primary, is_active, is_deleted, created_by, created_at)
    VALUES (c_tenant, v_acct, v_custom, c_school, FALSE, FALSE, TRUE, c_user, now());
    BEGIN
        c := 'd8';
        CALL config.sp_role_manage('DELETE', c_tenant, c_school, c_user, v_custom, NULL, NULL, c);
        CLOSE c;
        PERFORM pg_temp.chk('D8 a role whose assignments were all removed can be deleted', TRUE, '');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('D8 a role whose assignments were all removed can be deleted', FALSE, SQLERRM);
    END;
    -- re-create it for the sections below
    c := 'd8r';
    CALL config.sp_role_manage('INSERT', c_tenant, c_school, c_user, NULL, 'ZZ Cashier', NULL, c);
    FETCH c INTO r; CLOSE c;
    v_custom := r.role_id;

    SELECT COUNT(*) INTO v_n FROM core.admin_activity_logs
     WHERE action = 'ROLE_CREATE' AND record_id = v_custom AND user_id = c_user AND tenant_id = c_tenant;
    PERFORM pg_temp.chk_eq('D9 creating a role is audited with who did it', v_n, 1);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- E. Permission matrix, deeper ------------------------';

    -- The cashier the fee split was built for: view + collect, no cancel/refund.
    SELECT array_agg(permission_id) INTO v_ids FROM config.permissions
     WHERE permission_key IN ('fees.view', 'fees.collect');
    c := 'e1';
    CALL config.sp_role_permissions_save(c_tenant, c_school, c_user, v_custom, v_ids, c);
    CLOSE c;
    c := 'e1r';
    CALL config.sp_role_permissions_resolve(c_tenant, c_school, v_custom, c);
    SELECT NULL INTO v_txt;
    v_txt := '';
    LOOP
        FETCH c INTO r; EXIT WHEN NOT FOUND;
        v_txt := v_txt || r.permission_key || ' ';
    END LOOP;
    CLOSE c;
    PERFORM pg_temp.chk('E1 a cashier role resolves to exactly fees.view + fees.collect',
                        v_txt LIKE '%fees.view %' AND v_txt LIKE '%fees.collect %'
                        AND v_txt NOT LIKE '%fees.cancel%' AND v_txt NOT LIKE '%fees.refund%'
                        AND v_txt NOT LIKE '%fees.manage%', v_txt);

    -- fees.manage does NOT carry the money extras: they are separate keys now.
    SELECT array_agg(permission_id) INTO v_ids FROM config.permissions WHERE permission_key IN ('fees.view', 'fees.manage');
    c := 'e2';
    CALL config.sp_role_permissions_save(c_tenant, c_school, c_user, v_custom, v_ids, c);
    CLOSE c;
    c := 'e2r';
    CALL config.sp_role_permissions_resolve(c_tenant, c_school, v_custom, c);
    v_txt := '';
    LOOP
        FETCH c INTO r; EXIT WHEN NOT FOUND;
        v_txt := v_txt || r.permission_key || ' ';
    END LOOP;
    CLOSE c;
    PERFORM pg_temp.chk('E2 fees.manage alone does not grant cancel / refund / collect',
                        v_txt NOT LIKE '%fees.cancel%' AND v_txt NOT LIKE '%fees.refund%'
                        AND v_txt NOT LIKE '%fees.collect%', v_txt);

    -- The revoke is attributable: the soft-deleted grant says who removed it.
    SELECT COUNT(*) INTO v_n FROM config.role_permissions rp JOIN config.permissions p USING (permission_id)
     WHERE rp.role_id = v_custom AND p.permission_key = 'fees.collect' AND rp.is_deleted AND rp.updated_by = c_user;
    PERFORM pg_temp.chk_eq('E3 a revoked grant records who revoked it', v_n, 1);

    SELECT COUNT(*), max(description) INTO v_n, v_txt FROM core.admin_activity_logs
     WHERE action = 'ROLE_PERMISSIONS' AND record_id = v_custom AND user_id = c_user;
    PERFORM pg_temp.chk('E3b each matrix change is audited old -> new', v_n = 2 AND v_txt LIKE '%->%',
                        format('%s row(s), e.g. %s', v_n, v_txt));

    -- A permission id that is not in the catalog must not be storable.
    BEGIN
        c := 'e4';
        CALL config.sp_role_permissions_save(c_tenant, c_school, c_user, v_custom, ARRAY[999999], c);
        CLOSE c;
        PERFORM pg_temp.chk('E4 a permission id outside the catalog is refused (RBAC-14)', FALSE,
                            'accepted: config.role_permissions has no FK to config.permissions');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('E4 a permission id outside the catalog is refused (RBAC-14)', TRUE, SQLERRM);
    END;

    -- Switching a capability off in the catalog switches it off everywhere.
    SELECT array_agg(permission_id) INTO v_ids FROM config.permissions WHERE permission_key IN ('fees.view', 'fees.refund');
    c := 'e5';
    CALL config.sp_role_permissions_save(c_tenant, c_school, c_user, v_custom, v_ids, c);
    CLOSE c;
    UPDATE config.permissions SET is_active = FALSE WHERE permission_key = 'fees.refund';
    c := 'e5r';
    CALL config.sp_role_permissions_resolve(c_tenant, c_school, v_custom, c);
    v_txt := '';
    LOOP
        FETCH c INTO r; EXIT WHEN NOT FOUND;
        v_txt := v_txt || r.permission_key || ' ';
    END LOOP;
    CLOSE c;
    PERFORM pg_temp.chk('E5 a deactivated catalog permission is not resolved', v_txt NOT LIKE '%fees.refund%', v_txt);
    UPDATE config.permissions SET is_active = TRUE WHERE permission_key = 'fees.refund';

    c := 'e6';
    CALL config.sp_role_permissions_resolve(c_tenant_b, c_school_b, v_custom, c);
    PERFORM pg_temp.chk_eq('E6 another tenant resolves nothing for our role id', pg_temp.cur_count(c), 0);

    BEGIN
        c := 'e7';
        CALL config.sp_role_permissions_get(1, 0, v_custom, c);
        CLOSE c;
        PERFORM pg_temp.chk('E7 platform scope cannot read a school role''s grants', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('E7 platform scope cannot read a school role''s grants', TRUE, SQLERRM);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- F. Users, roles and deactivation --------------------';

    c := 'f1';
    CALL core.sp_user_roles_resolve(c_tenant, c_school, v_acct, c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('F1 a user resolves to their role', r.role_code = 'ACCOUNTANT', format('role=%s', r.role_code));

    -- HasPermission resolves through sp_user_roles_effective (cached 10 min; the
    -- cookie check in SessionValidator also re-checks user + school every minute).
    -- A deactivated or deleted user must resolve to nothing, or their existing
    -- cookie keeps every permission until it expires (8h sliding = indefinitely).
    UPDATE core.users SET is_active = FALSE WHERE user_id = v_acct;
    c := 'f2';
    CALL core.sp_user_roles_effective(c_tenant, c_school, v_acct, c);
    v_n := pg_temp.cur_count(c);
    PERFORM pg_temp.chk('F2 a deactivated user keeps no access roles (SEC-02)', v_n = 0,
                        format('%s role(s) still resolved', v_n));
    UPDATE core.users SET is_active = TRUE, is_deleted = TRUE WHERE user_id = v_acct;
    c := 'f3';
    CALL core.sp_user_roles_effective(c_tenant, c_school, v_acct, c);
    v_n := pg_temp.cur_count(c);
    PERFORM pg_temp.chk('F3 a deleted user keeps no access roles (SEC-03)', v_n = 0,
                        format('%s role(s) still resolved', v_n));
    UPDATE core.users SET is_deleted = FALSE WHERE user_id = v_acct;

    -- ...and a suspended school's users likewise (no per-request school check exists).
    UPDATE core.schools SET status_id = 7 WHERE school_id = c_school;
    c := 'f4';
    CALL core.sp_user_roles_effective(c_tenant, c_school, v_acct, c);
    v_n := pg_temp.cur_count(c);
    PERFORM pg_temp.chk('F4 users of a suspended school keep no access roles (SEC-04)', v_n = 0,
                        format('%s role(s) still resolved while Suspended', v_n));
    UPDATE core.schools SET status_id = 1 WHERE school_id = c_school;

    c := 'f5';
    CALL core.sp_user_roles_resolve(c_tenant_b, c_school_b, v_acct, c);
    PERFORM pg_temp.chk_eq('F5 another tenant resolves nothing for our user', pg_temp.cur_count(c), 0);

    -- A staff member marked Inactive (left the school) must lose the login.
    c := 'f6';
    CALL core.sp_staff_manage('DELETE', c_tenant, c_school, c_user, v_acct_staff,
         NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
         NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, c);
    CLOSE c;
    SELECT is_active INTO v_ok FROM core.users WHERE user_id = v_acct;
    c := 'f6b';
    CALL core.sp_login_management('GET_LOGIN_USER', p_email => v_acct_mail, p_result => c);
    v_n := pg_temp.cur_count(c);
    PERFORM pg_temp.chk('F6 deactivating a staff member disables their login (SEC-06)',
                        v_ok = FALSE AND v_n = 0, format('users.is_active=%s, login lookup rows=%s', v_ok, v_n));

    -- Live data, same hole: inactive staff that still hold a working login.
    SELECT COUNT(*), string_agg(s.staff_id || '->user ' || s.user_id, ', ') INTO v_n, v_txt
    FROM core.staff s JOIN core.users u ON u.user_id = s.user_id
    WHERE NOT s.is_active AND NOT s.is_deleted AND u.is_active AND NOT u.is_deleted
      AND s.staff_id <> v_acct_staff;
    PERFORM pg_temp.chk('F7 no inactive staff member holds a live login, data (SEC-07)',
                        v_n = 0, format('%s: %s', v_n, COALESCE(v_txt, '')));

    SELECT COUNT(*) INTO v_n FROM core.admin_activity_logs
     WHERE action = 'USER_DEACTIVATE' AND record_id = v_acct AND created_at = now() AND user_id = c_user;
    PERFORM pg_temp.chk_eq('F7b the deactivation is audited with who did it', v_n, 1);

    c := 'f7c';
    CALL core.sp_staff_manage('REACTIVATE', c_tenant, c_school, c_user, v_acct_staff,
         NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
         NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, c);
    CLOSE c;
    c := 'f7d';
    CALL core.sp_login_management('GET_LOGIN_USER', p_email => v_acct_mail, p_result => c);
    v_n := pg_temp.cur_count(c);
    PERFORM pg_temp.chk_eq('F7c re-activating the staff member restores the login', v_n, 1);

    -- The People form sends role ids from the browser. One from another tenant
    -- must be refused -- there is no FK, and if it lands it becomes the PRIMARY
    -- role (lowest id wins) and the login join drops the user entirely.
    DECLARE s record;
    BEGIN
        SELECT * INTO s FROM core.staff WHERE staff_id = v_acct_staff;
        BEGIN
            c := 'f8';
            CALL core.sp_staff_manage('UPDATE', c_tenant, c_school, c_user, s.staff_id,
                 s.employee_code::text, s.full_name::text, s.gender::text, s.dob::date, s.mobile::text,
                 s.alt_mobile::text, s.email::text, s.blood_group::text, s.address::text, s.staff_type::text,
                 s.department::text, s.designation::text, s.joining_date::date, s.qualification::text,
                 s.experience_years, s.status::text, s.monthly_salary, s.bank_account_no::text,
                 s.ifsc_code::text, s.pan::text, s.aadhaar::text,
                 FALSE, NULL, ARRAY[v_role_acct, v_role_admin_b], NULL, NULL, c);
            CLOSE c;
            SELECT COUNT(*) INTO v_n FROM core.user_roles
             WHERE user_id = v_acct AND role_id = v_role_admin_b AND NOT is_deleted;
            PERFORM pg_temp.chk('F8 a role id from another tenant is refused (RBAC-21)', v_n = 0,
                                format('tenant %s''s SCHOOL_ADMIN role %s was assigned', c_tenant_b, v_role_admin_b));
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('F8 a role id from another tenant is refused (RBAC-21)', TRUE, SQLERRM);
        END;

        c := 'f9';
        CALL core.sp_login_management('GET_LOGIN_USER', p_email => v_acct_mail, p_result => c);
        v_n := pg_temp.cur_count(c);
        PERFORM pg_temp.chk('F9 a bad role id never locks the person out (RBAC-22)',
                            v_n = 1, format('login lookup rows=%s after the save', v_n));
        -- put the accountant back
        UPDATE core.user_roles SET is_deleted = TRUE, is_active = FALSE, is_primary = FALSE
         WHERE user_id = v_acct AND role_id = v_role_admin_b;
        UPDATE core.user_roles SET is_primary = TRUE WHERE user_id = v_acct AND role_id = v_role_acct;
    END;

    -- A phone typed differently is the same phone. The guard compares raw text,
    -- the unique index compares the last 10 digits, so the guard waves it through
    -- and the index answers with a raw Postgres error.
    BEGIN
        c := 'f10';
        CALL core.sp_staff_manage('INSERT', c_tenant, c_school, c_user, NULL,
             'ZZ-EMP-1', 'ZZ Phone Twin', 'Male', DATE '1990-01-01',
             '+91 ' || substr(v_phone, 1, 5) || ' ' || substr(v_phone, 6), NULL,
             'zz.phonetwin@example.invalid', NULL, NULL, NULL, NULL, NULL, CURRENT_DATE, NULL, NULL,
             'Active', NULL, NULL, NULL, NULL, NULL,
             TRUE, 'ZZ-HASH', ARRAY[v_role_teacher], NULL, NULL, c);
        CLOSE c;
        PERFORM pg_temp.chk('F10 a login with someone else''s phone (other format) refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('F10 a login with someone else''s phone (other format) refused', TRUE, SQLERRM);
        PERFORM pg_temp.chk('F10b ...with a friendly message, not a raw constraint error (RBAC-24)',
                            SQLERRM NOT ILIKE '%duplicate key%', SQLERRM);
    END;

    BEGIN
        c := 'f11';
        CALL core.sp_staff_manage('INSERT', c_tenant, c_school, c_user, NULL,
             'ZZ-EMP-2', 'ZZ Email Twin', 'Male', DATE '1990-01-01', NULL, NULL,
             '  ' || upper(v_email) || ' ', NULL, NULL, NULL, NULL, NULL, CURRENT_DATE, NULL, NULL,
             'Active', NULL, NULL, NULL, NULL, NULL,
             TRUE, 'ZZ-HASH', ARRAY[v_role_teacher], NULL, NULL, c);
        CLOSE c;
        PERFORM pg_temp.chk('F11 a login with an existing email (other case) refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('F11 a login with an existing email (other case) refused',
                            SQLERRM NOT ILIKE '%duplicate key%', SQLERRM);
    END;

    -- Who may change roles (decision D-2) and the last admin (decision D-3).
    DECLARE v_tstaff integer; v_tuser integer; v_astaff integer; v_auser integer;
    BEGIN
        -- a teacher-only login, and the school admin who has a People row
        SELECT s.staff_id, s.user_id INTO v_tstaff, v_tuser
        FROM core.staff s JOIN core.users u ON u.user_id = s.user_id AND u.is_active AND NOT u.is_deleted
        WHERE s.tenant_id = c_tenant AND s.school_id = c_school AND s.is_active
          AND (SELECT array_agg(ur.role_id) FROM core.user_roles ur
                WHERE ur.user_id = s.user_id AND NOT ur.is_deleted AND ur.is_active) = ARRAY[v_role_teacher]
        ORDER BY s.staff_id LIMIT 1;
        SELECT s.staff_id, s.user_id INTO v_astaff, v_auser
        FROM core.staff s JOIN core.users u ON u.user_id = s.user_id AND u.is_active AND NOT u.is_deleted
        JOIN core.user_roles ur ON ur.user_id = s.user_id AND ur.role_id = v_role_admin AND NOT ur.is_deleted AND ur.is_active
        WHERE s.tenant_id = c_tenant AND s.school_id = c_school AND s.is_active
        ORDER BY s.staff_id LIMIT 1;
        RAISE NOTICE 'role-rule fixture: teacher staff=% user=%, admin staff=% user=%', v_tstaff, v_tuser, v_astaff, v_auser;

        BEGIN
            PERFORM pg_temp.staff_roles(v_tstaff, v_acct, ARRAY[v_role_teacher, v_role_admin]);
            PERFORM pg_temp.chk('F12 a non-admin cannot grant School Admin (D-2)', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('F12 a non-admin cannot grant School Admin (D-2)', SQLERRM ILIKE '%School Admin%', SQLERRM);
        END;

        BEGIN
            PERFORM pg_temp.staff_roles(v_acct_staff, v_acct, ARRAY[v_role_acct, v_role_teacher]);
            PERFORM pg_temp.chk('F13 nobody can change their own roles (D-2)', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('F13 nobody can change their own roles (D-2)', SQLERRM ILIKE '%own roles%', SQLERRM);
        END;

        PERFORM pg_temp.staff_roles(v_tstaff, c_user, ARRAY[v_role_teacher, v_role_acct]);
        SELECT COUNT(*) INTO v_n FROM core.user_roles
         WHERE user_id = v_tuser AND role_id = v_role_acct AND NOT is_deleted AND is_active;
        PERFORM pg_temp.chk_eq('F14 a school admin can add a role to someone else', v_n, 1);
        SELECT COUNT(*), max(description) INTO v_n, v_txt FROM core.admin_activity_logs
         WHERE action = 'USER_ROLES_CHANGE' AND record_id = v_tuser AND user_id = c_user;
        PERFORM pg_temp.chk('F14b the role change is audited old -> new', v_n = 1, COALESCE(v_txt, ''));

        BEGIN
            PERFORM pg_temp.staff_off(v_acct_staff, v_acct);
            PERFORM pg_temp.chk('F15 nobody can deactivate their own login', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('F15 nobody can deactivate their own login', SQLERRM ILIKE '%own login%', SQLERRM);
        END;

        -- Make v_auser the only active admin left, then try to remove them.
        UPDATE core.users SET is_active = FALSE
         WHERE user_id IN (SELECT ur.user_id FROM core.user_roles ur
                           WHERE ur.school_id = c_school AND ur.role_id = v_role_admin
                             AND NOT ur.is_deleted AND ur.is_active AND ur.user_id <> v_auser);
        BEGIN
            PERFORM pg_temp.staff_roles(v_astaff, c_user,
                (SELECT array_agg(role_id) FROM core.user_roles WHERE user_id = v_auser
                    AND NOT is_deleted AND is_active AND role_id <> v_role_admin));
            PERFORM pg_temp.chk('F16 the last school admin cannot lose School Admin (D-3)', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('F16 the last school admin cannot lose School Admin (D-3)', SQLERRM ILIKE '%last active%', SQLERRM);
        END;
        BEGIN
            PERFORM pg_temp.staff_off(v_astaff, c_user);
            PERFORM pg_temp.chk('F17 the last school admin cannot be deactivated (D-3)', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('F17 the last school admin cannot be deactivated (D-3)', SQLERRM ILIKE '%last active%', SQLERRM);
        END;
        UPDATE core.users SET is_active = TRUE WHERE user_id = c_user;
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- G. Super admin: schools -----------------------------';

    SELECT last_seq INTO v_seq FROM core.school_code_counters WHERE counter_key = 'GLOBAL';

    c := 'g1';
    CALL core.sp_school_manage('INSERT', 1, v_super,
         p_tenant_mode => 'existing', p_selected_tenant_id => 25,
         p_school_name => 'ZZ Onboarded School', p_status_id => 1, p_board_id => 1,
         p_address_line1 => '1 Test Road', p_city => 'Deoria', p_state => 'Uttar Pradesh', p_pincode => '274001',
         p_contact_name => 'ZZ Contact', p_phone => '7000000001',
         p_create_school_admin => TRUE, p_admin_full_name => 'ZZ New Admin',
         p_admin_email => 'ZZ.NewAdmin@Example.invalid', p_admin_phone => '7000000002',
         p_password_hash => 'ZZ-TEMP-HASH', p_result => c);
    FETCH c INTO r; CLOSE c;
    v_new := r.school_id;
    SELECT school_code INTO v_code FROM core.schools WHERE school_id = v_new;
    PERFORM pg_temp.chk('G1 onboarding a school gives it the next code, gap-free',
                        v_code = 'SCH' || (v_seq + 1), format('code=%s, counter was %s', v_code, v_seq));

    SELECT u.must_change_password, rr.role_code, ur.is_primary INTO r
    FROM core.users u JOIN core.user_roles ur ON ur.user_id = u.user_id AND NOT ur.is_deleted
    JOIN config.roles rr ON rr.role_id = ur.role_id
    WHERE u.email = 'zz.newadmin@example.invalid';
    PERFORM pg_temp.chk('G2 the new admin is a primary SCHOOL_ADMIN forced to reset',
                        r.role_code = 'SCHOOL_ADMIN' AND r.is_primary AND r.must_change_password,
                        format('role=%s primary=%s must_change=%s', r.role_code, r.is_primary, r.must_change_password));

    c := 'g3';
    CALL core.sp_login_management('GET_LOGIN_USER', p_email => 'zz.newadmin@example.invalid', p_result => c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('G3 ...and can log in straight away', r.school_id = v_new AND r.school_allows_login,
                        format('school=%s allows=%s', r.school_id, r.school_allows_login));

    SELECT COUNT(*) FILTER (WHERE action = 'SCHOOL_CREATE' AND record_id = v_new),
           COUNT(*) FILTER (WHERE action = 'SCHOOL_ADMIN_CREATE' AND description LIKE '%zz.newadmin@example.invalid%')
      INTO v_n, v_m
      FROM core.admin_activity_logs WHERE tenant_id = 1 AND user_id = v_super AND created_at = now();
    PERFORM pg_temp.chk('G3b onboarding is audited on the platform tenant (school + admin)',
                        v_n = 1 AND v_m = 1, format('school rows=%s admin rows=%s', v_n, v_m));

    BEGIN
        c := 'g4';
        CALL core.sp_school_manage('INSERT', 1, v_super, p_tenant_mode => 'existing', p_selected_tenant_id => 25,
             p_school_name => 'ZZ Dup Email School', p_status_id => 1, p_board_id => 1,
             p_address_line1 => '1 Test Road', p_city => 'Deoria', p_state => 'Uttar Pradesh', p_pincode => '274001',
             p_contact_name => 'ZZ', p_phone => '7000000003', p_create_school_admin => TRUE,
             p_admin_full_name => 'ZZ Dup', p_admin_email => ' ' || upper(v_email), p_password_hash => 'H', p_result => c);
        PERFORM pg_temp.chk('G4 an admin email already in use (other case) refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('G4 an admin email already in use (other case) refused',
                            SQLERRM NOT ILIKE '%duplicate key%', SQLERRM);
    END;

    BEGIN
        c := 'g5';
        CALL core.sp_school_manage('INSERT', 1, v_super, p_tenant_mode => 'existing', p_selected_tenant_id => 25,
             p_school_name => 'ZZ Dup Phone School', p_status_id => 1, p_board_id => 1,
             p_address_line1 => '1 Test Road', p_city => 'Deoria', p_state => 'Uttar Pradesh', p_pincode => '274001',
             p_contact_name => 'ZZ', p_phone => '7000000004', p_create_school_admin => TRUE,
             p_admin_full_name => 'ZZ Dup', p_admin_email => 'zz.dupphone@example.invalid',
             p_admin_phone => '+91 ' || substr(v_phone, 1, 5) || ' ' || substr(v_phone, 6),
             p_password_hash => 'H', p_result => c);
        PERFORM pg_temp.chk('G5 an admin phone already in use (other format) refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('G5 an admin phone already in use (other format) refused', TRUE, SQLERRM);
        PERFORM pg_temp.chk('G5b ...with a friendly message, not a raw constraint error (SA-06)',
                            SQLERRM NOT ILIKE '%duplicate key%', SQLERRM);
    END;

    c := 'g11';
    CALL core.sp_school_list(c_tenant_b, 38, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 1, 100, c);
    v_ok := TRUE; v_n := 0;
    LOOP
        FETCH c INTO r; EXIT WHEN NOT FOUND;
        v_n := v_n + 1;
        IF r.school_id <> c_school_b THEN v_ok := FALSE; END IF;
    END LOOP;
    CLOSE c;
    PERFORM pg_temp.chk('G11 a tenant''s school list shows only its own schools', v_ok AND v_n = 1,
                        format('%s row(s)', v_n));

    -- Only the platform onboards schools. The controller enforces it with
    -- [Authorize(Roles = SuperAdmin)], but sp_school_purge re-checks p_tenant_id = 1
    -- and sp_school_manage INSERT/UPDATE do not.
    BEGIN
        c := 'g7';
        CALL core.sp_school_manage('INSERT', c_tenant, c_user, p_tenant_mode => 'existing', p_selected_tenant_id => c_tenant_b,
             p_school_name => 'ZZ Planted School', p_status_id => 1, p_board_id => 1,
             p_address_line1 => '1 Test Road', p_city => 'Deoria', p_state => 'Uttar Pradesh', p_pincode => '274001',
             p_contact_name => 'ZZ', p_phone => '7000000005', p_result => c);
        CLOSE c;
        PERFORM pg_temp.chk('G7 a school user cannot create a school, any tenant (SA-07)', FALSE,
                            'tenant 24 created a school inside tenant 23');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('G7 a school user cannot create a school, any tenant (SA-07)', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'g8';
        CALL core.sp_school_manage('UPDATE', c_tenant, c_user, p_school_id => c_school,
             p_school_name => v_name_a,
             p_status_id => 6, p_address_line1 => '1 Test Road', p_city => 'Deoria', p_state => 'Uttar Pradesh',
             p_pincode => '274001', p_contact_name => 'ZZ', p_phone => '7000000006', p_result => c);
        CLOSE c;
        SELECT status_id INTO v_n FROM core.schools WHERE school_id = c_school;
        PERFORM pg_temp.chk('G8 only the platform can change a school''s status (SA-08)',
                            v_n <> 6, format('school 34 set its own status to %s', v_n));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('G8 only the platform can change a school''s status (SA-08)', TRUE, SQLERRM);
    END;
    UPDATE core.schools SET status_id = 1 WHERE school_id = c_school;

    BEGIN
        c := 'g9';
        CALL core.sp_school_manage('UPDATE', c_tenant_b, 38, p_school_id => c_school,
             p_school_name => 'ZZ Hijack', p_status_id => 7, p_address_line1 => 'x', p_city => 'x', p_state => 'x',
             p_pincode => '274001', p_contact_name => 'x', p_phone => '7000000007', p_result => c);
        PERFORM pg_temp.chk('G9 another tenant cannot edit our school', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('G9 another tenant cannot edit our school', TRUE, SQLERRM);
    END;

    c := 'g10';
    CALL core.sp_school_manage('GET', c_tenant_b, 38, p_school_id => c_school, p_result => c);
    PERFORM pg_temp.chk_eq('G10 another tenant cannot read our school', pg_temp.cur_count(c), 0);

    -- Edit of a school that had no admin: the admin created there gets a password
    -- typed by the super admin, exactly like INSERT -- so it must be single-use too.
    c := 'g12a';
    CALL core.sp_school_manage('INSERT', 1, v_super, p_tenant_mode => 'existing', p_selected_tenant_id => 25,
         p_school_name => 'ZZ Admin Later School', p_status_id => 1, p_board_id => 1,
         p_address_line1 => '1 Test Road', p_city => 'Deoria', p_state => 'Uttar Pradesh', p_pincode => '274001',
         p_contact_name => 'ZZ', p_phone => '7000000008', p_create_school_admin => FALSE, p_result => c);
    FETCH c INTO r; CLOSE c;
    v_new2 := r.school_id;
    c := 'g12';
    CALL core.sp_school_manage('UPDATE', 1, v_super, p_school_id => v_new2,
         p_school_name => 'ZZ Admin Later School', p_status_id => 1, p_board_id => 1,
         p_address_line1 => '1 Test Road', p_city => 'Deoria', p_state => 'Uttar Pradesh', p_pincode => '274001',
         p_contact_name => 'ZZ', p_phone => '7000000008', p_create_school_admin => TRUE,
         p_admin_full_name => 'ZZ Late Admin', p_admin_email => 'zz.lateadmin@example.invalid',
         p_password_hash => 'ZZ-TYPED-HASH', p_result => c);
    CLOSE c;
    SELECT must_change_password INTO v_ok FROM core.users WHERE email = 'zz.lateadmin@example.invalid';
    PERFORM pg_temp.chk('G12 an admin created on Edit is forced to reset their password (SA-12)',
                        v_ok IS TRUE, format('must_change_password=%s (INSERT path sets TRUE)', v_ok));
    SELECT COUNT(*) INTO v_n FROM core.admin_activity_logs
     WHERE action = 'SCHOOL_ADMIN_CREATE' AND description LIKE '%zz.lateadmin@example.invalid%';
    PERFORM pg_temp.chk_eq('G12b the admin created on Edit is audited', v_n, 1);

    UPDATE core.users SET must_change_password = FALSE WHERE email = 'zz.newadmin@example.invalid';
    c := 'g13';
    CALL core.sp_school_manage('UPDATE', 1, v_super, p_school_id => v_new,
         p_school_name => 'ZZ Onboarded School', p_status_id => 7, p_board_id => 1,
         p_address_line1 => '1 Test Road', p_city => 'Deoria', p_state => 'Uttar Pradesh', p_pincode => '274001',
         p_contact_name => 'ZZ Contact', p_phone => '7000000001', p_create_school_admin => TRUE,
         p_admin_full_name => 'ZZ New Admin', p_admin_email => 'zz.newadmin@example.invalid',
         p_admin_phone => '7000000002', p_password_hash => 'ZZ-RESET-BY-SA', p_result => c);
    CLOSE c;
    SELECT (password_hash = 'ZZ-RESET-BY-SA' AND must_change_password) INTO v_ok
      FROM core.users WHERE email = 'zz.newadmin@example.invalid';
    PERFORM pg_temp.chk('G13 a super-admin password reset is single-use', v_ok, '');
    SELECT COUNT(*) INTO v_n FROM core.admin_activity_logs
     WHERE action = 'PASSWORD_RESET_BY_ADMIN' AND user_id = v_super AND created_at = now()
       AND record_id = (SELECT user_id FROM core.users WHERE email = 'zz.newadmin@example.invalid');
    PERFORM pg_temp.chk_eq('G13b the admin password reset is audited', v_n, 1);

    c := 'g14';
    CALL core.sp_login_management('GET_LOGIN_USER', p_email => 'zz.newadmin@example.invalid', p_result => c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('G14 suspending the school on Edit blocks its admin at login',
                        r.school_allows_login = FALSE AND r.school_status_code = 'SUSPENDED',
                        format('allows=%s code=%s', r.school_allows_login, r.school_status_code));

    -- Who suspended this school, and when? Only schools.updated_by remembers the
    -- LAST change; there is no history and nothing in admin_activity_logs.
    SELECT COUNT(*) INTO v_n FROM core.admin_activity_logs WHERE record_id = v_new AND table_name = 'core.schools';
    PERFORM pg_temp.chk('G15 a school status change leaves an audit row (SA-15)', v_n > 0,
                        format('%s audit row(s) for the suspension', v_n));

    SELECT COUNT(*) INTO v_n FROM (SELECT school_code FROM core.schools GROUP BY school_code HAVING COUNT(*) > 1) d;
    PERFORM pg_temp.chk_eq('G16 school codes are unique across the platform', v_n, 0);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- H. Super admin: purge and archive -------------------';

    BEGIN
        c := 'h1';
        CALL core.sp_school_purge(c_tenant, c_school, c_user, 'whatever', c);
        PERFORM pg_temp.chk('H1 a school user cannot purge a school', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('H1 a school user cannot purge a school', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'h2';
        CALL core.sp_school_purge(1, v_new2, v_super, 'ZZ Admin Later School', c);
        PERFORM pg_temp.chk('H2 an Active school cannot be purged', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('H2 an Active school cannot be purged', TRUE, SQLERRM);
    END;

    UPDATE core.schools SET status_id = 8 WHERE school_id = v_new2;
    BEGIN
        c := 'h3';
        CALL core.sp_school_purge(1, v_new2, v_super, 'zz admin later school', c);
        PERFORM pg_temp.chk('H3 the confirmation name must match exactly', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('H3 the confirmation name must match exactly', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'h4';
        CALL core.sp_school_archive(c_tenant, c_school, c);
        PERFORM pg_temp.chk('H4 a school user cannot archive (export) a school', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('H4 a school user cannot archive (export) a school', TRUE, SQLERRM);
    END;

    -- The archive file is written to App_Data before the purge runs, and kept.
    c := 'h5';
    CALL core.sp_school_archive(1, c_school, c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('H5 the archive carries no password hashes or reset codes (SA-25)',
                        position('password_hash' in r.archive_json) = 0 AND position('token_hash' in r.archive_json) = 0,
                        format('%s rows archived; password_hash present=%s', r.total_rows,
                               position('password_hash' in r.archive_json) > 0));

    -- Purge of a fresh, clean school: everything school-scoped goes; the tenant,
    -- its shared roles and its sibling schools stay.
    SELECT COUNT(*) INTO v_m FROM config.roles WHERE tenant_id = 25 AND NOT is_deleted;
    BEGIN
        c := 'h6';
        CALL core.sp_school_purge(1, v_new2, v_super, 'ZZ Admin Later School', c);
        CLOSE c;
        SELECT COUNT(*) INTO v_n FROM core.schools WHERE school_id = v_new2;
        PERFORM pg_temp.chk_eq('H6 a Closed school with the right name is purged', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM core.users WHERE email = 'zz.lateadmin@example.invalid';
        PERFORM pg_temp.chk_eq('H7 its admin login went with it', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM config.roles WHERE tenant_id = 25 AND NOT is_deleted;
        PERFORM pg_temp.chk_eq('H8 the tenant''s shared roles survived', v_n, v_m);
        SELECT COUNT(*) INTO v_n FROM core.users WHERE user_id IN (40, 41) AND is_active AND NOT is_deleted;
        PERFORM pg_temp.chk_eq('H9 sibling schools'' admins (same tenant) untouched', v_n, 2);
        SELECT COUNT(*) INTO v_n FROM core.admin_activity_logs
         WHERE action = 'SCHOOL_PURGE' AND record_id = v_new2 AND tenant_id = 1;
        PERFORM pg_temp.chk_eq('H10 the purge is audited on the platform tenant', v_n, 1);
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('H6 a Closed school with the right name is purged', FALSE, SQLERRM);
    END;

    -- A real school with exams, inventory, enrolments, leave or payroll. The purge
    -- list predates those modules (15 school-scoped tables are missing), so the
    -- delete trips a foreign key -- rolled back, but the school can never be purged.
    BEGIN
        UPDATE core.schools SET status_id = 8 WHERE school_id = c_school_b;
        c := 'h11';
        CALL core.sp_school_purge(1, c_school_b, v_super,
             v_name_b, c);
        CLOSE c;
        PERFORM pg_temp.chk('H11 a Closed school that ran exams/inventory can be purged (SA-26)', TRUE, '');
        RAISE EXCEPTION 'undo-purge';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'undo-purge' THEN
            PERFORM pg_temp.chk('H11 a Closed school that ran exams/inventory can be purged (SA-26)', FALSE, SQLERRM);
        END IF;
    END;

    SELECT COUNT(*) INTO v_n
    FROM information_schema.columns col
    JOIN information_schema.tables t ON t.table_schema = col.table_schema AND t.table_name = col.table_name
     AND t.table_type = 'BASE TABLE'
    WHERE col.column_name = 'school_id' AND col.table_schema IN ('core', 'academic', 'config')
      AND position(format('DELETE FROM %s.%s ', col.table_schema, col.table_name)
                   IN regexp_replace(pg_get_functiondef('core.sp_school_purge'::regproc), '\s+', ' ', 'g')) = 0;
    PERFORM pg_temp.chk_eq('H12 the purge list covers every school-scoped table (SA-27)', v_n, 0);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- I. Module toggles -----------------------------------';

    c := 'i0';
    CALL core.sp_school_admin_admission_workflow_manage('GetAdmissionWorkflow', c_tenant, c_school, c_user,
         NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, c);
    FETCH c INTO r; CLOSE c;
    c := 'i1';
    CALL core.sp_school_admin_admission_workflow_manage('SaveAdmissionWorkflow', c_tenant, c_school, c_user,
         r.enable_registration, r.registration_required_before_admission, r.enable_registration_fee,
         r.auto_generate_registration_number, r.registration_number_prefix, r.collect_fee_at_admission,
         r.enable_security_fee, r.enable_transport, FALSE, r.enable_inventory, FALSE, c);
    CLOSE c;
    c := 'i1g';
    CALL core.sp_school_admin_admission_workflow_manage('GetAdmissionWorkflow', c_tenant, c_school, c_user,
         NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('I1 switching Exams and Payroll off is stored',
                        r.enable_exams = FALSE AND r.enable_payroll = FALSE,
                        format('exams=%s payroll=%s', r.enable_exams, r.enable_payroll));

    c := 'i2';
    CALL core.sp_school_admin_admission_workflow_manage('GetAdmissionWorkflow', c_tenant_b, c_school_b, 38,
         NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('I2 another school''s modules are untouched',
                        COALESCE(r.enable_exams, TRUE) = TRUE, format('school 33 exams=%s', r.enable_exams));

    BEGIN
        c := 'i3';
        CALL core.sp_school_admin_admission_workflow_manage('SaveAdmissionWorkflow', 1, 0, v_super,
             TRUE, FALSE, FALSE, TRUE, 'X', FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, c);
        PERFORM pg_temp.chk('I3 platform scope cannot toggle a school''s modules', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('I3 platform scope cannot toggle a school''s modules', TRUE, SQLERRM);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- J. Dashboard and geo scope --------------------------';

    -- A tenant/school pair that does not belong together returns nothing from
    -- that school (defence in depth: claims are signed, but procs must not trust
    -- one id alone).
    DECLARE k1 refcursor := 'j_k'; k2 refcursor := 'j_t'; k3 refcursor := 'j_c'; k4 refcursor := 'j_m';
            k5 refcursor := 'j_d'; k6 refcursor := 'j_r'; k7 refcursor := 'j_a'; k8 refcursor := 'j_e';
            k9 refcursor := 'j_b';
    BEGIN
        CALL core.sp_dashboard_summary(c_tenant_b, c_school, 38, k1, k2, k3, k4, k5, k6, k7, k8, k9);
        v_n := pg_temp.cur_count(k6) + pg_temp.cur_count(k5) + pg_temp.cur_count(k9);
        CLOSE k1; CLOSE k2; CLOSE k3; CLOSE k4; CLOSE k7; CLOSE k8;
        PERFORM pg_temp.chk_eq('J1 a mismatched tenant/school pair sees none of that school''s rows', v_n, 0);
    END;

    BEGIN
        c := 'j2';
        CALL config.sp_geo_lookup('Bogus', NULL, NULL, c);
        PERFORM pg_temp.chk('J2 an unknown geo activity is refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('J2 an unknown geo activity is refused', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'j3';
        CALL config.sp_geo_lookup('District', '1; DROP TABLE core.users', NULL, c);
        CLOSE c;
        PERFORM pg_temp.chk('J3 a hostile state id is rejected, not executed', TRUE, 'returned harmlessly');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('J3 a hostile state id is rejected, not executed',
                            to_regclass('core.users') IS NOT NULL, SQLERRM);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- K. Leaks --------------------------------------------';

    SELECT COUNT(*) INTO v_n FROM config.roles
     WHERE role_name IN ('ZZ Librarian', 'ZZ Cashier', 'Super Admin', 'School_Admin') AND tenant_id <> c_tenant
       AND created_at = now();   -- created by this run (one transaction, one now())
    PERFORM pg_temp.chk_eq('K1 roles we created exist only in our tenant', v_n, 0);

    SELECT COUNT(*) INTO v_n FROM config.role_permissions rp JOIN config.roles rr ON rr.role_id = rp.role_id
     WHERE rp.tenant_id <> rr.tenant_id;
    PERFORM pg_temp.chk_eq('K2 no grant points at a role of another tenant', v_n, 0);
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
            RAISE NOTICE '   %  %', rpad(r.name, 60), r.detail;
        END LOOP;
    END IF;
    RAISE NOTICE '';
END
$sum$;

ROLLBACK;
