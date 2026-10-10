-- ============================================================================
-- HR, Leave and Payroll test suite (deep).
--
-- Payroll is money. Every salary paid has to leave a durable trail — who, when,
-- how much, which month — and nothing that was paid may ever be rewritten. Leave
-- feeds payroll (approved Unpaid leave becomes Loss of Pay), and the staff record
-- feeds both (salary, joining date, status). So this suite walks the real life of
-- a staff member: hired, given a login, takes leave, gets paid, changes status,
-- leaves — and checks the money at every step.
--
-- It goes DEEPER than leave_payroll_tests.sql (which covers the basic guards,
-- one LOP case and pay-once). Nothing here repeats those checks.
--
-- Runs inside ONE transaction and ROLLS BACK.
--
--     psql ... -f hr_leave_payroll_tests.sql
--
-- Fixed calendar: July 2025 has 27 working days (Mon-Sat; Sundays 6/13/20/27).
-- A salary of 27000 is therefore exactly 1000 a day, so every LOP figure below
-- is a round number and a wrong one is obvious.
--
-- Every check asserts the CORRECT behaviour. The 32 that failed when this suite
-- was written (Oct 2026) were fixed in sp_staff_manage.sql, staff_masters_manage.sql,
-- staff_leave.sql and staff_payroll.sql. IDs match docs/test-cases/hr_leave_payroll.md.
--
-- The School Calendar decides working days (core.fn_school_working_days); the
-- suite owns this school's Jul/Aug 2025 calendar while it runs.
--
-- COVERS
--   A. Staff create / edit — codes, salary, status, logins, roles, scope
--   B. Status changes — deactivate, edit-form status, the teacher pools
--   C. Staff masters — designations and departments
--   D. Leave — cancel, calendar, overlap, types, balance, scope
--   E. Payroll — pro-rata, leavers, LOP across months, paid slips, trail
--   F. Leakage
-- ============================================================================

\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE TEMP TABLE _t(id serial, name text, ok boolean, detail text) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.chk(p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO _t(name, ok, detail) VALUES (p_name, COALESCE(p_ok, FALSE), p_detail);
    RAISE NOTICE '  [%] %  %', CASE WHEN COALESCE(p_ok, FALSE) THEN 'PASS' ELSE 'FAIL' END, rpad(p_name, 54), p_detail;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.chk_eq(p_name text, p_got numeric, p_want numeric)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.chk(p_name, p_got IS NOT DISTINCT FROM p_want,
                        format('got %s, expected %s', COALESCE(p_got::text,'NULL'), p_want));
END $$;

-- sp_staff_manage has 31 positional parameters and no defaults; this wraps the
-- ones the staff form actually uses and returns the staff_id the proc reports.
CREATE OR REPLACE FUNCTION pg_temp.stf(
    p_op text, p_tenant integer, p_school integer, p_id integer,
    p_code text, p_name text, p_mobile text, p_email text,
    p_desig text, p_type text, p_dept text, p_join date, p_status text, p_salary numeric,
    p_login boolean DEFAULT FALSE, p_hash text DEFAULT NULL, p_roles integer[] DEFAULT NULL,
    p_lwd date DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'stf_c'; v integer;
BEGIN
    CALL core.sp_staff_manage(p_op, p_tenant, p_school, 39, p_id, p_code, p_name, 'Male', NULL::date,
         p_mobile, NULL, p_email, NULL, NULL, p_type, p_dept, p_desig, p_join, NULL, NULL,
         p_status, p_salary, NULL, NULL, NULL, NULL, p_login, p_hash, p_roles, NULL, NULL, c, p_lwd);
    FETCH c INTO v;
    CLOSE c;
    RETURN v;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.lv_apply(p_staff integer, p_type text, p_from date, p_to date,
                                            p_tenant integer DEFAULT 24, p_school integer DEFAULT 34,
                                            p_half boolean DEFAULT FALSE)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'lv_c'; r record;
BEGIN
    CALL core.sp_staff_leave_manage('APPLY', p_tenant, p_school, 39, NULL, p_staff, p_type,
         p_from, p_to, 'hr suite', NULL, NULL, c, p_half);
    FETCH c INTO r;
    CLOSE c;
    RETURN r.leave_id;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.lv_decide(p_leave integer, p_status text, p_remark text DEFAULT NULL,
                                             p_tenant integer DEFAULT 24, p_school integer DEFAULT 34)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'lvd_c';
BEGIN
    CALL core.sp_staff_leave_manage('DECIDE', p_tenant, p_school, 39, p_leave, NULL, NULL,
         NULL, NULL, NULL, p_status, p_remark, c);
    CLOSE c;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.pay_run(p_month integer, p_year integer,
                                           p_tenant integer DEFAULT 24, p_school integer DEFAULT 34)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'pr_c';
BEGIN
    CALL core.sp_staff_payroll_manage('RUN', p_tenant, p_school, 39, p_month, p_year, NULL, NULL, c);
    CLOSE c;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.pay_paid(p_payroll integer,
                                            p_tenant integer DEFAULT 24, p_school integer DEFAULT 34,
                                            p_mode text DEFAULT 'Bank Transfer', p_ref text DEFAULT 'UTR-ZZ-0001')
RETURNS void LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'pp_c';
BEGIN
    CALL core.sp_staff_payroll_manage('MARK_PAID', p_tenant, p_school, 39, NULL, NULL, p_payroll, NULL, c,
                                      p_mode, p_ref);
    CLOSE c;
END $$;

-- Payroll adjustment (ADD / VOID); returns the adjustment id.
CREATE OR REPLACE FUNCTION pg_temp.pay_adj(p_op text, p_id integer, p_staff integer, p_month integer, p_year integer,
                                           p_kind text, p_amount numeric, p_reason text,
                                           p_mode text DEFAULT NULL, p_ref text DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'pa_c'; r record;
BEGIN
    CALL core.sp_staff_payroll_adjust(p_op, 24, 34, 39, p_id, p_staff, p_month, p_year,
                                      p_kind, p_amount, p_reason, p_mode, p_ref, c);
    FETCH c INTO r;
    CLOSE c;
    RETURN r.adjustment_id;
END $$;

-- Is this staff id offered by the class-teacher picker / the timetable picker?
CREATE OR REPLACE FUNCTION pg_temp.in_ct_pool(p_staff integer)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'ctp_c'; r record; v boolean := FALSE;
BEGIN
    CALL core.sp_class_teacher_manage('Teachers'::varchar, 24, 34, 39, NULL::int, NULL::int, NULL::int,
                                      NULL::varchar, NULL::varchar, c);
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.staff_id = p_staff THEN v := TRUE; END IF; END LOOP;
    CLOSE c;
    RETURN v;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.in_tt_pool(p_staff integer)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := 'ttp1'; c2 refcursor := 'ttp2'; c3 refcursor := 'ttp3'; c4 refcursor := 'ttp4';
        r record; v boolean := FALSE;
BEGIN
    CALL academic.sp_school_admin_timetable_manage('GetSetup', 24, 34, 39,
         NULL, NULL, NULL, NULL, NULL, NULL, NULL, c1, c2, c3, c4);
    LOOP FETCH c3 INTO r; EXIT WHEN NOT FOUND; IF r.staff_id = p_staff THEN v := TRUE; END IF; END LOOP;
    CLOSE c1; CLOSE c2; CLOSE c3; CLOSE c4;
    RETURN v;
END $$;


DO $suite$
DECLARE
    c_tenant CONSTANT integer := 24;
    c_school CONSTANT integer := 34;
    c_user   CONSTANT integer := 39;
    c_hash   CONSTANT text    := '$2a$11$zzzzzzzzzzzzzzzzzzzzzuzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz';

    c     refcursor;
    r     record;
    v_n   integer;
    v_txt text;
    v_dec numeric;
    v_b   boolean;
    v_id  integer;

    -- staff
    v_t1   integer;   -- teacher, code ZZHR-001
    v_lg1  integer;   -- has a login
    v_ein  integer;   -- set Inactive through the edit form
    v_cln  integer;   -- a cleaner (Support)
    v_l1   integer;   -- leave: cancel / today
    v_l2   integer;   -- leave: school calendar
    v_l3   integer;   -- leave: entitlement
    v_l4   integer;   -- leave: deactivated
    v_p1   integer;   -- payroll: full month, LOP across month end, paid
    v_p2   integer;   -- payroll: joined 15 Jul 2025
    v_p3   integer;   -- payroll: joined 1 Sep 2025
    v_p4   integer;   -- payroll: left mid-July, deactivated before the run
    v_p5   integer;   -- payroll: status "On Leave"
    v_p7   integer;   -- payroll: every working day unpaid
    v_p8   integer;   -- payroll: deactivated AFTER the run
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '========= HR / LEAVE / PAYROLL TESTS =========';

    PERFORM pg_temp.chk_eq('fixture: July 2025 has 27 working days',
                           core.fn_working_days(DATE '2025-07-01', DATE '2025-07-31'), 27);

    -- The suite owns the July/Aug 2025 calendar for this school while it runs.
    DELETE FROM academic.school_calendar
     WHERE tenant_id = c_tenant AND school_id = c_school AND calendar_date LIKE '2025-0%';
    UPDATE academic.school_calendar_settings SET weekly_off_days = '{0}'
     WHERE tenant_id = c_tenant AND school_id = c_school;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- A. Staff create / edit ------------------------------';

    BEGIN
        PERFORM pg_temp.stf('INSERT', c_tenant, c_school, NULL, 'ZZHR-000', '   ', NULL, NULL,
                            'Teacher', NULL, 'Teaching', DATE '2024-01-01', 'Active', 20000);
        PERFORM pg_temp.chk('STF-01 blank full name refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('STF-01 blank full name refused', TRUE, SQLERRM);
    END;

    -- The form sends whatever Staff Type the browser had; the proc derives it from
    -- the designation so a "Teacher" can never be filed as Support staff.
    v_t1 := pg_temp.stf('INSERT', c_tenant, c_school, NULL, 'ZZHR-001', 'ZZ HR Teacher', '9000000001', NULL,
                        'Teacher', 'Support', 'Teaching', DATE '2024-01-01', 'Active', 27000);
    PERFORM pg_temp.chk('STF-02 a valid teacher is created', v_t1 IS NOT NULL, format('staff_id=%s', v_t1));
    SELECT staff_type INTO v_txt FROM core.staff WHERE staff_id = v_t1;
    PERFORM pg_temp.chk('STF-03 staff type comes from the designation', v_txt = 'Teaching',
                        format('sent Support, stored %s', v_txt));

    BEGIN
        PERFORM pg_temp.stf('INSERT', c_tenant, c_school, NULL, 'ZZHR-001', 'ZZ HR Dup', NULL, NULL,
                            'Teacher', NULL, 'Teaching', DATE '2024-01-01', 'Active', 1);
        PERFORM pg_temp.chk('STF-04 duplicate employee code refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('STF-04 duplicate employee code refused', TRUE, SQLERRM);
    END;

    BEGIN
        PERFORM pg_temp.stf('INSERT', c_tenant, c_school, NULL, '  ZZHR-001 ', 'ZZ HR Dup', NULL, NULL,
                            'Teacher', NULL, 'Teaching', DATE '2024-01-01', 'Active', 1);
        PERFORM pg_temp.chk('STF-04b padded duplicate code refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('STF-04b padded duplicate code refused', TRUE, SQLERRM);
    END;

    -- "zzhr-001" and "ZZHR-001" are the same badge to every human in the office.
    BEGIN
        PERFORM pg_temp.stf('INSERT', c_tenant, c_school, NULL, 'zzhr-001', 'ZZ HR Dup', NULL, NULL,
                            'Teacher', NULL, 'Teaching', DATE '2024-01-01', 'Active', 1);
        PERFORM pg_temp.chk('STF-05 code differing only by case refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('STF-05 code differing only by case refused', TRUE, SQLERRM);
    END;

    -- A negative salary is not a salary; payroll would book a negative gross.
    BEGIN
        PERFORM pg_temp.stf('INSERT', c_tenant, c_school, NULL, 'ZZHR-NEG', 'ZZ HR Negative', NULL, NULL,
                            'Teacher', NULL, 'Teaching', DATE '2024-01-01', 'Active', -5000);
        PERFORM pg_temp.chk('STF-06 negative monthly salary refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('STF-06 negative monthly salary refused', TRUE, SQLERRM);
    END;

    -- Payroll pays only status = 'Active'; any other word silently drops the
    -- person from payroll, so the proc should only accept the statuses it knows.
    BEGIN
        PERFORM pg_temp.stf('INSERT', c_tenant, c_school, NULL, 'ZZHR-STS', 'ZZ HR Odd Status', NULL, NULL,
                            'Teacher', NULL, 'Teaching', DATE '2024-01-01', 'Resigned-ish', 1000);
        PERFORM pg_temp.chk('STF-07 an unknown status word refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('STF-07 an unknown status word refused', TRUE, SQLERRM);
    END;

    -- Editing keeps the public id (the URL) stable and records who edited.
    DECLARE v_pub uuid; v_pub2 uuid;
    BEGIN
        SELECT public_id INTO v_pub FROM core.staff WHERE staff_id = v_t1;
        PERFORM pg_temp.stf('UPDATE', c_tenant, c_school, v_t1, 'ZZHR-001', 'ZZ HR Teacher', '9000000001', NULL,
                            'Teacher', NULL, 'Teaching', DATE '2024-01-01', 'Active', 27000);
        SELECT public_id, updated_by INTO v_pub2, v_n FROM core.staff WHERE staff_id = v_t1;
        PERFORM pg_temp.chk('STF-08 edit keeps the public id', v_pub = v_pub2, v_pub2::text);
        PERFORM pg_temp.chk_eq('STF-08b edit records who changed it', v_n, c_user);
    END;

    -- ── Logins ──
    v_lg1 := pg_temp.stf('INSERT', c_tenant, c_school, NULL, 'ZZHR-LG1', 'ZZ HR Login One', '9000011111',
                         'ZZ.HR.Login1@Test.Local', 'Teacher', NULL, 'Teaching', DATE '2024-01-01', 'Active', 27000,
                         TRUE, c_hash, ARRAY[50]);
    SELECT u.email, u.must_change_password, u.tenant_id INTO r
      FROM core.staff s JOIN core.users u ON u.user_id = s.user_id WHERE s.staff_id = v_lg1;
    PERFORM pg_temp.chk('STF-09 login created and linked', r.email IS NOT NULL, format('email=%s', r.email));
    PERFORM pg_temp.chk('STF-09b login email stored lower-case', r.email = 'zz.hr.login1@test.local', r.email);
    PERFORM pg_temp.chk('STF-09c new login must change its password', r.must_change_password IS TRUE,
                        format('must_change_password=%s', r.must_change_password));
    SELECT COUNT(*) INTO v_n FROM core.user_roles ur JOIN core.staff s ON s.user_id = ur.user_id
     WHERE s.staff_id = v_lg1 AND ur.is_deleted = FALSE AND ur.is_primary;
    PERFORM pg_temp.chk_eq('STF-09d exactly one primary role', v_n, 1);

    BEGIN
        PERFORM pg_temp.stf('INSERT', c_tenant, c_school, NULL, 'ZZHR-LG2', 'ZZ HR Login Dup', '9000022222',
                            'zz.hr.login1@test.local', 'Teacher', NULL, 'Teaching', DATE '2024-01-01', 'Active', 1,
                            TRUE, c_hash, ARRAY[50]);
        PERFORM pg_temp.chk('STF-10 duplicate login email refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('STF-10 duplicate login email refused', TRUE, SQLERRM);
    END;

    BEGIN
        PERFORM pg_temp.stf('INSERT', c_tenant, c_school, NULL, 'ZZHR-LG3', 'ZZ HR Phone Dup', '9000011111',
                            'zz.hr.login3@test.local', 'Teacher', NULL, 'Teaching', DATE '2024-01-01', 'Active', 1,
                            TRUE, c_hash, ARRAY[50]);
        PERFORM pg_temp.chk('STF-11 duplicate login phone refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('STF-11 duplicate login phone refused', TRUE, SQLERRM);
    END;

    -- Role ids come from the browser. Role 1 is the platform SUPER_ADMIN, role 45
    -- belongs to tenant 23. Neither may be attached to a tenant-24 login.
    DECLARE v_s integer; v_uid integer; v_bad integer; v_usable integer;
    BEGIN
        BEGIN
            v_s := pg_temp.stf('INSERT', c_tenant, c_school, NULL, 'ZZHR-LG4', 'ZZ HR Foreign Role', '9000044444',
                               'zz.hr.login4@test.local', 'Teacher', NULL, 'Teaching', DATE '2024-01-01', 'Active', 1,
                               TRUE, c_hash, ARRAY[50, 1, 45]);
        EXCEPTION WHEN OTHERS THEN
            v_s := NULL;
            PERFORM pg_temp.chk('STF-12 roles outside this tenant refused', TRUE, SQLERRM);
        END;
        IF v_s IS NOT NULL THEN
            SELECT user_id INTO v_uid FROM core.staff WHERE staff_id = v_s;
            SELECT COUNT(*) INTO v_bad FROM core.user_roles
             WHERE user_id = v_uid AND is_deleted = FALSE AND role_id IN (1, 45);
            PERFORM pg_temp.chk('STF-12 roles outside this tenant refused', v_bad = 0,
                                format('%s foreign role row(s) stored (SUPER_ADMIN / tenant 23)', v_bad));
            -- The proc picks the lowest role_id as primary (= SUPER_ADMIN), and the
            -- login query only accepts a primary role of the user's own tenant.
            SELECT COUNT(*) INTO v_usable FROM core.user_roles ur
              JOIN config.roles ro ON ro.role_id = ur.role_id AND ro.tenant_id = ur.tenant_id
             WHERE ur.user_id = v_uid AND ur.is_deleted = FALSE AND ur.is_active AND ur.is_primary;
            PERFORM pg_temp.chk('STF-12b the login keeps a usable primary role', v_usable = 1,
                                format('%s primary role(s) in its own tenant -> cannot sign in', v_usable));
        END IF;
    END;

    -- Another school's admin, passing our staff id.
    DECLARE v_name text;
    BEGIN
        BEGIN
            PERFORM pg_temp.stf('UPDATE', 23, 33, v_t1, 'X', 'ZZ Hijacked', NULL, NULL,
                                'Teacher', NULL, 'Teaching', DATE '2024-01-01', 'Active', 99999);
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        SELECT full_name, monthly_salary INTO v_name, v_dec FROM core.staff WHERE staff_id = v_t1;
        PERFORM pg_temp.chk('STF-13 another school cannot edit our staff',
                            v_name = 'ZZ HR Teacher' AND v_dec = 27000, format('%s / %s', v_name, v_dec));
    END;

    -- Same call with "create login" ticked: the proc creates the login BEFORE it
    -- finds out the staff row is not in scope, leaving an orphan account.
    BEGIN
        BEGIN
            PERFORM pg_temp.stf('UPDATE', 23, 33, v_t1, 'X', 'ZZ Hijacked', '9000055555',
                                'zz.hr.orphan@test.local', 'Teacher', NULL, 'Teaching', DATE '2024-01-01', 'Active', 1,
                                TRUE, c_hash, ARRAY[46]);
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        SELECT COUNT(*) INTO v_n FROM core.users WHERE email = 'zz.hr.orphan@test.local';
        PERFORM pg_temp.chk('STF-14 out-of-scope edit creates no login', v_n = 0,
                            format('%s orphan login(s) created', v_n));
    END;

    c := 'a15';
    CALL core.sp_staff_manage('GET', 23, 33, c_user, v_t1, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
         NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, FALSE, NULL, NULL, NULL, NULL, c);
    v_n := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_n := v_n + 1; END LOOP;
    PERFORM pg_temp.chk_eq('STF-15 another school cannot read our staff', v_n, 0);

    DECLARE v_pub uuid;
    BEGIN
        SELECT public_id INTO v_pub FROM core.staff WHERE staff_id = v_t1;
        PERFORM pg_temp.chk_eq('STF-16 public id resolves in our school',
                               core.fn_public_id_to_id('staff', v_pub, c_tenant, c_school), v_t1);
        PERFORM pg_temp.chk('STF-16b ...and not in another school',
                            core.fn_public_id_to_id('staff', v_pub, 23, 33) IS NULL, '');
    END;

    -- List: search by mobile, total count, scope.
    c := 'a17';
    CALL core.sp_staff_list(c_tenant, c_school, c_user, '9000000001', NULL, NULL, NULL, 1, 10, NULL, 'asc', c);
    FETCH c INTO r;
    PERFORM pg_temp.chk('STF-17 list finds staff by mobile', r.staff_id = v_t1 AND r.total_count = 1,
                        format('staff %s, total %s', r.staff_id, r.total_count));
    c := 'a17b';
    CALL core.sp_staff_list(23, 33, c_user, 'ZZ HR', NULL, NULL, NULL, 1, 50, NULL, 'asc', c);
    FETCH c INTO r;
    PERFORM pg_temp.chk('STF-17b another school''s list shows none of ours', r.staff_id IS NULL,
                        format('first row %s', r.staff_id));
    c := 'a17c';
    CALL core.sp_staff_list(1, 0, c_user, NULL, NULL, NULL, NULL, 1, 50, NULL, 'asc', c);
    FETCH c INTO r;
    PERFORM pg_temp.chk('STF-17c platform scope list is empty', r IS NULL, '');

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- B. Status changes and the teacher pools -------------';

    PERFORM pg_temp.chk('STF-20 an active teacher is in the class-teacher pool', pg_temp.in_ct_pool(v_lg1), '');
    PERFORM pg_temp.chk('STF-20b ...and in the timetable pool', pg_temp.in_tt_pool(v_lg1), '');

    PERFORM pg_temp.stf('DELETE', c_tenant, c_school, v_lg1, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
    SELECT status, is_active, status_changed_at INTO r FROM core.staff WHERE staff_id = v_lg1;
    PERFORM pg_temp.chk('STF-21 deactivate sets Inactive + is_active false',
                        r.status = 'Inactive' AND r.is_active = FALSE, format('%s / %s', r.status, r.is_active));
    PERFORM pg_temp.chk('STF-21b ...and stamps when', r.status_changed_at IS NOT NULL, '');
    SELECT last_working_date INTO v_txt FROM core.staff WHERE staff_id = v_lg1;
    PERFORM pg_temp.chk('STF-21c ...and records the last working day (default today)',
                        v_txt = to_char(CURRENT_DATE, 'YYYY-MM-DD'), COALESCE(v_txt, 'NULL'));
    BEGIN
        PERFORM pg_temp.stf('DELETE', c_tenant, c_school, v_lg1, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
        PERFORM pg_temp.chk('STF-21d deactivating twice refused (keeps the first date)', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('STF-21d deactivating twice refused (keeps the first date)', TRUE, SQLERRM);
    END;
    PERFORM pg_temp.chk('STF-22 deactivated teacher leaves the class-teacher pool', NOT pg_temp.in_ct_pool(v_lg1), '');
    PERFORM pg_temp.chk('STF-22b ...and the timetable pool', NOT pg_temp.in_tt_pool(v_lg1), '');

    -- THE ONE THAT MATTERS for security: a person who has left must not keep
    -- signing in. The Inactive page even says "reactivate to restore access".
    SELECT u.is_active INTO v_b FROM core.staff s JOIN core.users u ON u.user_id = s.user_id
     WHERE s.staff_id = v_lg1;
    PERFORM pg_temp.chk('STF-23 deactivating staff disables their login', v_b IS FALSE,
                        format('users.is_active = %s after deactivation', v_b));

    PERFORM pg_temp.stf('REACTIVATE', c_tenant, c_school, v_lg1, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
    SELECT status, is_active INTO r FROM core.staff WHERE staff_id = v_lg1;
    PERFORM pg_temp.chk('STF-24 reactivate restores Active + is_active',
                        r.status = 'Active' AND r.is_active, format('%s / %s', r.status, r.is_active));
    SELECT u.is_active, s.last_working_date INTO r FROM core.staff s JOIN core.users u ON u.user_id = s.user_id
     WHERE s.staff_id = v_lg1;
    PERFORM pg_temp.chk('STF-24b ...switches the login back on and clears the last working day',
                        r.is_active AND r.last_working_date IS NULL,
                        format('login %s, last working day %s', r.is_active, COALESCE(r.last_working_date, 'NULL')));

    BEGIN
        PERFORM pg_temp.stf('DELETE', 23, 33, v_lg1, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    SELECT status INTO v_txt FROM core.staff WHERE staff_id = v_lg1;
    PERFORM pg_temp.chk('STF-25 another school cannot deactivate our staff', v_txt = 'Active', v_txt);

    -- The Edit Staff form has its own Status dropdown (Active / On Leave /
    -- Inactive). Choosing Inactive there must behave exactly like Deactivate.
    v_ein := pg_temp.stf('INSERT', c_tenant, c_school, NULL, 'ZZHR-EIN', 'ZZ HR Edit Inactive', NULL, NULL,
                         'Teacher', NULL, 'Teaching', DATE '2024-01-01', 'Active', 20000);
    PERFORM pg_temp.stf('UPDATE', c_tenant, c_school, v_ein, 'ZZHR-EIN', 'ZZ HR Edit Inactive', NULL, NULL,
                        'Teacher', NULL, 'Teaching', DATE '2024-01-01', 'Inactive', 20000);
    SELECT status, is_active, status_changed_at INTO r FROM core.staff WHERE staff_id = v_ein;
    PERFORM pg_temp.chk('STF-26 edit-form Inactive also clears is_active',
                        r.status = 'Inactive' AND r.is_active = FALSE AND r.status_changed_at IS NOT NULL,
                        format('status %s, is_active %s, status_changed_at %s', r.status, r.is_active,
                               COALESCE(r.status_changed_at::text, 'NULL')));
    PERFORM pg_temp.chk('STF-27 edit-form Inactive teacher leaves class-teacher pool',
                        NOT pg_temp.in_ct_pool(v_ein), 'still offered as class teacher');
    PERFORM pg_temp.chk('STF-27b ...and the timetable pool', NOT pg_temp.in_tt_pool(v_ein),
                        'still offered in the timetable');
    -- ...and back to Active on the form = Reactivate.
    PERFORM pg_temp.stf('UPDATE', c_tenant, c_school, v_ein, 'ZZHR-EIN', 'ZZ HR Edit Inactive', NULL, NULL,
                        'Teacher', NULL, 'Teaching', DATE '2024-01-01', 'Active', 20000);
    SELECT status, is_active, last_working_date INTO r FROM core.staff WHERE staff_id = v_ein;
    PERFORM pg_temp.chk('STF-27c edit-form Active again restores is_active, clears the leaving date',
                        r.status = 'Active' AND r.is_active AND r.last_working_date IS NULL,
                        format('%s / %s / %s', r.status, r.is_active, COALESCE(r.last_working_date, 'NULL')));
    PERFORM pg_temp.chk('STF-27d ...and the teacher is back in the class-teacher pool', pg_temp.in_ct_pool(v_ein), '');

    -- A new staff member cannot start Inactive, and a leaving date cannot be in the future.
    BEGIN
        PERFORM pg_temp.stf('INSERT', c_tenant, c_school, NULL, 'ZZHR-NIN', 'ZZ HR New Inactive', NULL, NULL,
                            'Teacher', NULL, 'Teaching', DATE '2024-01-01', 'Inactive', 1000);
        PERFORM pg_temp.chk('STF-07b a new staff member created Inactive refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('STF-07b a new staff member created Inactive refused', TRUE, SQLERRM);
    END;
    BEGIN
        PERFORM pg_temp.stf('DELETE', c_tenant, c_school, v_ein, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
                            FALSE, NULL, NULL, CURRENT_DATE + 5);
        PERFORM pg_temp.chk('STF-29b a last working day in the future refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('STF-29b a last working day in the future refused', TRUE, SQLERRM);
    END;
    BEGIN
        PERFORM pg_temp.stf('DELETE', c_tenant, c_school, v_ein, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
                            FALSE, NULL, NULL, DATE '2023-12-31');
        PERFORM pg_temp.chk('STF-29c a last working day before joining refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('STF-29c a last working day before joining refused', TRUE, SQLERRM);
    END;

    -- Non-teaching staff: the class-teacher pool filters them out, the timetable
    -- pool does not.
    v_cln := pg_temp.stf('INSERT', c_tenant, c_school, NULL, 'ZZHR-CLN', 'ZZ HR Cleaner', NULL, NULL,
                         'Cleaner', NULL, 'Cleaning', DATE '2024-01-01', 'Active', 12000);
    PERFORM pg_temp.chk('STF-28 a cleaner is not offered as class teacher', NOT pg_temp.in_ct_pool(v_cln), '');
    PERFORM pg_temp.chk('STF-28b a cleaner is not offered in the timetable', NOT pg_temp.in_tt_pool(v_cln),
                        'non-teaching staff can be booked to teach a period');

    -- Resignation: the last working day is recorded (payroll pro-rates the final
    -- month from it -- see PAY-04).
    SELECT COUNT(*) INTO v_n FROM information_schema.columns
     WHERE table_schema = 'core' AND table_name = 'staff'
       AND column_name ~ '(leav|relie|exit|resign|last_working|separation)';
    PERFORM pg_temp.chk('STF-29 staff record can hold a last working day', v_n > 0,
                        format('%s leaving-date column(s) on core.staff', v_n));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- C. Staff masters ------------------------------------';

    BEGIN
        c := 'c1';
        CALL config.sp_staff_masters_manage('SaveDesignation', c_tenant, c_school, c_user, NULL, '  ', 'Teaching', NULL, 0, NULL, c);
        PERFORM pg_temp.chk('SM-01 blank designation refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('SM-01 blank designation refused', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'c2';
        CALL config.sp_staff_masters_manage('SaveDesignation', c_tenant, c_school, c_user, NULL, 'ZZ Wizard', 'Magic', NULL, 0, NULL, c);
        PERFORM pg_temp.chk('SM-02 invalid staff type refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('SM-02 invalid staff type refused', TRUE, SQLERRM);
    END;

    c := 'c3';
    CALL config.sp_staff_masters_manage('SaveDesignation', c_tenant, c_school, c_user, NULL, 'ZZ Desig Plain', NULL, NULL, 0, NULL, c);
    SELECT staff_type INTO v_txt FROM config.designations WHERE tenant_id = c_tenant AND name = 'ZZ Desig Plain';
    PERFORM pg_temp.chk('SM-03 no staff type defaults to Non-Teaching', v_txt = 'Non-Teaching', v_txt);

    BEGIN
        c := 'c4';
        CALL config.sp_staff_masters_manage('SaveDesignation', c_tenant, c_school, c_user, NULL, 'zz desig PLAIN', 'Teaching', NULL, 0, NULL, c);
        PERFORM pg_temp.chk('SM-04 duplicate designation (any case) refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('SM-04 duplicate designation (any case) refused', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'c5';
        CALL config.sp_staff_masters_manage('SaveDepartment', c_tenant, c_school, c_user, NULL, '', NULL, NULL, 0, NULL, c);
        PERFORM pg_temp.chk('SM-05 blank department refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('SM-05 blank department refused', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'c6';
        CALL config.sp_staff_masters_manage('SaveDepartment', c_tenant, c_school, c_user, NULL, 'TEACHING', NULL, NULL, 0, NULL, c);
        PERFORM pg_temp.chk('SM-06 duplicate department (any case) refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('SM-06 duplicate department (any case) refused', TRUE, SQLERRM);
    END;

    -- In-use designation and department, then rename them.
    DECLARE v_dg integer; v_dp integer; v_s integer; v_cnt integer;
    BEGIN
        c := 'c7a';
        CALL config.sp_staff_masters_manage('SaveDepartment', c_tenant, c_school, c_user, NULL, 'ZZ Dept R', NULL, NULL, 3, NULL, c);
        SELECT department_id INTO v_dp FROM config.departments WHERE tenant_id = c_tenant AND name = 'ZZ Dept R';
        c := 'c7b';
        CALL config.sp_staff_masters_manage('SaveDesignation', c_tenant, c_school, c_user, NULL, 'ZZ Desig R', 'Teaching', 'ZZ Dept R', 5, NULL, c);
        SELECT designation_id INTO v_dg FROM config.designations WHERE tenant_id = c_tenant AND name = 'ZZ Desig R';
        v_s := pg_temp.stf('INSERT', c_tenant, c_school, NULL, 'ZZHR-DSG', 'ZZ HR Masters User', NULL, NULL,
                           'ZZ Desig R', NULL, 'ZZ Dept R', DATE '2024-01-01', 'Active', 10000);

        BEGIN
            c := 'c7';
            CALL config.sp_staff_masters_manage('DeleteDesignation', c_tenant, c_school, c_user, v_dg, NULL, NULL, NULL, 0, NULL, c);
            PERFORM pg_temp.chk('SM-07 deleting an in-use designation refused', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('SM-07 deleting an in-use designation refused', TRUE, SQLERRM);
        END;

        BEGIN
            c := 'c7c';
            CALL config.sp_staff_masters_manage('DeleteDepartment', c_tenant, c_school, c_user, v_dp, NULL, NULL, NULL, 0, NULL, c);
            PERFORM pg_temp.chk('SM-07b deleting an in-use department refused', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('SM-07b deleting an in-use department refused', TRUE, SQLERRM);
        END;

        -- What the page sends on Edit: id, name, staffType, defaultDepartment. No
        -- sortOrder, so the service passes 0 -- and the proc stores it.
        c := 'c8';
        CALL config.sp_staff_masters_manage('SaveDesignation', c_tenant, c_school, c_user, v_dg, 'ZZ Desig R', 'Teaching', 'ZZ Dept R', 0, NULL, c);
        SELECT sort_order INTO v_n FROM config.designations WHERE designation_id = v_dg;
        PERFORM pg_temp.chk('SM-08 editing a designation keeps its sort order', v_n = 5,
                            format('sort_order %s, was 5', v_n));

        -- Rename while in use. staff.designation is free text, so the staff row
        -- keeps the old name, which no longer exists in the master.
        c := 'c9';
        CALL config.sp_staff_masters_manage('SaveDesignation', c_tenant, c_school, c_user, v_dg, 'ZZ Desig R2', 'Teaching', 'ZZ Dept R', 5, NULL, c);
        SELECT COUNT(*) INTO v_cnt FROM core.staff s
         WHERE s.staff_id = v_s
           AND EXISTS (SELECT 1 FROM config.designations d WHERE d.tenant_id = c_tenant
                         AND COALESCE(d.is_deleted, FALSE) = FALSE AND LOWER(d.name) = LOWER(s.designation));
        PERFORM pg_temp.chk('SM-09 renaming a designation keeps staff on a real one', v_cnt = 1,
                            format('staff still says "%s"', (SELECT designation FROM core.staff WHERE staff_id = v_s)));

        -- ...and now the delete guard looks for the NEW name, finds nobody, and lets it go.
        BEGIN
            c := 'c9b';
            CALL config.sp_staff_masters_manage('DeleteDesignation', c_tenant, c_school, c_user, v_dg, NULL, NULL, NULL, 0, NULL, c);
            SELECT COUNT(*) INTO v_cnt FROM config.designations WHERE designation_id = v_dg AND is_deleted = FALSE;
            PERFORM pg_temp.chk('SM-09b a renamed in-use designation cannot be deleted', v_cnt = 1,
                                'deleted although a staff member still holds it');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('SM-09b a renamed in-use designation cannot be deleted', TRUE, SQLERRM);
        END;

        c := 'c10';
        CALL config.sp_staff_masters_manage('SaveDepartment', c_tenant, c_school, c_user, v_dp, 'ZZ Dept R2', NULL, NULL, 3, NULL, c);
        SELECT department INTO v_txt FROM core.staff WHERE staff_id = v_s;
        PERFORM pg_temp.chk('SM-10 renaming a department follows through to staff', v_txt = 'ZZ Dept R2',
                            format('staff still in "%s"', v_txt));

        -- Another tenant editing / deleting our row by id.
        -- The renamed department is also what designations default to.
        SELECT default_department INTO v_txt FROM config.designations WHERE designation_id = v_dg;
        PERFORM pg_temp.chk('SM-10b ...and to designations defaulting to it', v_txt = 'ZZ Dept R2', COALESCE(v_txt, 'NULL'));

        DECLARE v_msg text; v_ok boolean;
        BEGIN
            BEGIN
                c := 'c11';
                CALL config.sp_staff_masters_manage('SaveDepartment', 23, 33, c_user, v_dp, 'ZZ Stolen Dept', NULL, NULL, 0, NULL, c);
                FETCH c INTO r;
                v_ok := r.success; v_msg := r.message;
            EXCEPTION WHEN OTHERS THEN
                v_ok := FALSE; v_msg := SQLERRM;
            END;
            SELECT name INTO v_txt FROM config.departments WHERE department_id = v_dp;
            PERFORM pg_temp.chk('SM-11 another tenant cannot rename our department', v_txt = 'ZZ Dept R2', v_txt);
            PERFORM pg_temp.chk('SM-12 ...and is told it failed, not "saved"', v_ok IS NOT TRUE,
                                format('success=%s, message=%s', v_ok, v_msg));
        END;

        BEGIN
            c := 'c13';
            CALL config.sp_staff_masters_manage('DeleteDepartment', 23, 33, c_user, v_dp, NULL, NULL, NULL, 0, NULL, c);
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        SELECT COUNT(*) INTO v_cnt FROM config.departments WHERE department_id = v_dp AND is_deleted = FALSE;
        PERFORM pg_temp.chk_eq('SM-13 another tenant cannot delete our department', v_cnt, 1);

        -- Changing a designation's staff type follows through to its staff (the
        -- staff form derives the type from the designation).
        c := 'c13b';
        CALL config.sp_staff_masters_manage('SaveDesignation', c_tenant, c_school, c_user, v_dg, 'ZZ Desig R2', 'Support', 'ZZ Dept R2', 0, NULL, c);
        SELECT staff_type INTO v_txt FROM core.staff WHERE staff_id = v_s;
        PERFORM pg_temp.chk('SM-13b a designation''s new staff type follows to its staff', v_txt = 'Support', COALESCE(v_txt, 'NULL'));
    END;

    -- Delete an unused designation, re-add the same name.
    DECLARE v_dg integer;
    BEGIN
        SELECT designation_id INTO v_dg FROM config.designations WHERE tenant_id = c_tenant AND name = 'ZZ Desig Plain';
        c := 'c14';
        CALL config.sp_staff_masters_manage('DeleteDesignation', c_tenant, c_school, c_user, v_dg, NULL, NULL, NULL, 0, NULL, c);
        SELECT COUNT(*) INTO v_n FROM config.designations WHERE designation_id = v_dg AND is_deleted;
        PERFORM pg_temp.chk_eq('SM-14 an unused designation can be deleted', v_n, 1);
        -- The proc's duplicate check skips deleted rows, but the unique index
        -- uq_designation_name (tenant_id, name) does not -- so re-adding a name
        -- that was deleted dies on a raw constraint error.
        BEGIN
            c := 'c14b';
            CALL config.sp_staff_masters_manage('SaveDesignation', c_tenant, c_school, c_user, NULL, 'ZZ Desig Plain', 'Support', NULL, 0, NULL, c);
            SELECT COUNT(*) INTO v_n FROM config.designations
             WHERE tenant_id = c_tenant AND name = 'ZZ Desig Plain' AND is_deleted = FALSE;
            PERFORM pg_temp.chk_eq('SM-14b a deleted designation name can be added again', v_n, 1);
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('SM-14b a deleted designation name can be added again', FALSE, SQLERRM);
        END;

        DECLARE v_dp integer;
        BEGIN
            c := 'c14c';
            CALL config.sp_staff_masters_manage('SaveDepartment', c_tenant, c_school, c_user, NULL, 'ZZ Dept Gone', NULL, NULL, 0, NULL, c);
            SELECT department_id INTO v_dp FROM config.departments WHERE tenant_id = c_tenant AND name = 'ZZ Dept Gone';
            c := 'c14d';
            CALL config.sp_staff_masters_manage('DeleteDepartment', c_tenant, c_school, c_user, v_dp, NULL, NULL, NULL, 0, NULL, c);
            c := 'c14e';
            CALL config.sp_staff_masters_manage('SaveDepartment', c_tenant, c_school, c_user, NULL, 'ZZ Dept Gone', NULL, NULL, 0, NULL, c);
            PERFORM pg_temp.chk('SM-14c a deleted department name can be added again', TRUE, '');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('SM-14c a deleted department name can be added again', FALSE, SQLERRM);
        END;

        -- A deactivated designation disappears from the Add Staff dropdown.
        c := 'c15a';
        CALL config.sp_staff_masters_manage('SaveDesignation', c_tenant, c_school, c_user, NULL, 'ZZ Desig Toggle', 'Support', NULL, 0, NULL, c);
        SELECT designation_id INTO v_dg FROM config.designations
         WHERE tenant_id = c_tenant AND name = 'ZZ Desig Toggle' AND is_deleted = FALSE;
        c := 'c15';
        CALL config.sp_staff_masters_manage('ToggleDesignation', c_tenant, c_school, c_user, v_dg, NULL, NULL, NULL, 0, NULL, c);
        DECLARE d1 refcursor := 'c15d1'; d2 refcursor := 'c15d2'; d3 refcursor := 'c15d3';
        BEGIN
            CALL config.sp_staff_dropdowns(c_tenant, c_school, d1, d2, d3);
            v_n := 0;
            LOOP FETCH d2 INTO r; EXIT WHEN NOT FOUND; IF r.name = 'ZZ Desig Toggle' THEN v_n := v_n + 1; END IF; END LOOP;
            PERFORM pg_temp.chk_eq('SM-15 a deactivated designation leaves the dropdown', v_n, 0);
            v_n := 0;
            LOOP FETCH d3 INTO r; EXIT WHEN NOT FOUND; IF r.role_id IN (1, 45) THEN v_n := v_n + 1; END IF; END LOOP;
            PERFORM pg_temp.chk_eq('SM-15b role dropdown offers only this tenant''s roles', v_n, 0);
        END;
    END;

    BEGIN
        c := 'c16';
        CALL config.sp_staff_masters_manage('SaveDepartment', 1, 0, c_user, NULL, 'ZZ Platform Dept', NULL, NULL, 0, NULL, c);
        PERFORM pg_temp.chk('SM-16 platform scope master write refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('SM-16 platform scope master write refused', TRUE, SQLERRM);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- D. Leave --------------------------------------------';

    v_l1 := pg_temp.stf('INSERT', c_tenant, c_school, NULL, 'ZZHR-L1', 'ZZ HR Leave Cancel', NULL, NULL,
                        'Teacher', NULL, 'Teaching', DATE '2024-01-01', 'Active', 27000);
    v_l2 := pg_temp.stf('INSERT', c_tenant, c_school, NULL, 'ZZHR-L2', 'ZZ HR Leave Calendar', NULL, NULL,
                        'Teacher', NULL, 'Teaching', DATE '2024-01-01', 'Active', 27000);
    v_l3 := pg_temp.stf('INSERT', c_tenant, c_school, NULL, 'ZZHR-L3', 'ZZ HR Leave Balance', NULL, NULL,
                        'Teacher', NULL, 'Teaching', DATE '2024-01-01', 'Active', 27000);
    v_l4 := pg_temp.stf('INSERT', c_tenant, c_school, NULL, 'ZZHR-L4', 'ZZ HR Leave Gone', NULL, NULL,
                        'Teacher', NULL, 'Teaching', DATE '2024-01-01', 'Active', 27000);
    v_p2 := pg_temp.stf('INSERT', c_tenant, c_school, NULL, 'ZZHR-P2', 'ZZ HR Joined Mid July', NULL, NULL,
                        'Teacher', NULL, 'Teaching', DATE '2025-07-15', 'Active', 27000);

    -- A staff member who changes their mind before anyone decides can withdraw:
    -- the request is Cancelled (not "Rejected", a refusal that never happened).
    v_id := pg_temp.lv_apply(v_l1, 'Casual', DATE '2025-07-01', DATE '2025-07-02');
    BEGIN
        c := 'd1';
        CALL core.sp_staff_leave_manage('CANCEL', c_tenant, c_school, c_user, v_id, NULL, NULL, NULL, NULL, NULL, NULL, 'plans changed', c);
        SELECT status INTO v_txt FROM core.staff_leave WHERE leave_id = v_id;
        PERFORM pg_temp.chk('LV-01 a pending request can be cancelled', v_txt IN ('Cancelled', 'Withdrawn'),
                            format('status %s', v_txt));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('LV-01 a pending request can be cancelled', FALSE, SQLERRM);
    END;
    SELECT cancelled_by, cancelled_at, cancel_reason INTO r FROM core.staff_leave WHERE leave_id = v_id;
    PERFORM pg_temp.chk('LV-01b who, when and why are kept',
                        r.cancelled_by = c_user AND r.cancelled_at IS NOT NULL AND r.cancel_reason = 'plans changed',
                        COALESCE(r.cancel_reason, 'NULL'));
    -- The cancelled dates are free again.
    BEGIN
        v_id := pg_temp.lv_apply(v_l1, 'Casual', DATE '2025-07-01', DATE '2025-07-02');
        PERFORM pg_temp.chk('LV-01c cancelled dates can be applied for again', v_id IS NOT NULL, format('leave %s', v_id));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('LV-01c cancelled dates can be applied for again', FALSE, SQLERRM);
    END;
    -- An APPROVED leave that has already started cannot be cancelled (it may be
    -- in a payslip); a reason is required.
    PERFORM pg_temp.lv_decide(v_id, 'Approved');
    BEGIN
        c := 'd1d';
        CALL core.sp_staff_leave_manage('CANCEL', c_tenant, c_school, c_user, v_id, NULL, NULL, NULL, NULL, NULL, NULL, 'too late', c);
        PERFORM pg_temp.chk('LV-01d an approved leave already taken cannot be cancelled', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('LV-01d an approved leave already taken cannot be cancelled', TRUE, SQLERRM);
    END;
    DECLARE v_fut integer;
    BEGIN
        v_fut := pg_temp.lv_apply(v_l1, 'Casual', CURRENT_DATE + 20, CURRENT_DATE + 21);
        BEGIN
            c := 'd1e';
            CALL core.sp_staff_leave_manage('CANCEL', c_tenant, c_school, c_user, v_fut, NULL, NULL, NULL, NULL, NULL, NULL, '  ', c);
            PERFORM pg_temp.chk('LV-01e cancelling without a reason refused', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('LV-01e cancelling without a reason refused', TRUE, SQLERRM);
        END;
        PERFORM pg_temp.lv_decide(v_fut, 'Approved');
        c := 'd1f';
        CALL core.sp_staff_leave_manage('CANCEL', c_tenant, c_school, c_user, v_fut, NULL, NULL, NULL, NULL, NULL, NULL, 'trip off', c);
        SELECT status, decided_by INTO r FROM core.staff_leave WHERE leave_id = v_fut;
        PERFORM pg_temp.chk('LV-01f an approved FUTURE leave can be cancelled, approval kept',
                            r.status = 'Cancelled' AND r.decided_by = c_user, format('%s / decided_by %s', r.status, r.decided_by));
    END;

    -- School Calendar: 8 Jul 2025 (Tue) is a declared holiday.
    INSERT INTO academic.school_calendar(tenant_id, school_id, calendar_date, day_type, title, created_by)
    VALUES (c_tenant, c_school, '2025-07-08', 'holiday', 'ZZ Holiday', c_user);
    v_id := pg_temp.lv_apply(v_l2, 'Casual', DATE '2025-07-07', DATE '2025-07-09');
    SELECT days INTO v_n FROM core.staff_leave WHERE leave_id = v_id;
    PERFORM pg_temp.chk_eq('LV-02 a school holiday is not a leave day (Mon-Wed, Tue off)', v_n, 2);

    -- School Calendar: the school runs a 5-day week (Sat + Sun off).
    UPDATE academic.school_calendar_settings SET weekly_off_days = '{0,6}'
     WHERE tenant_id = c_tenant AND school_id = c_school;
    v_id := pg_temp.lv_apply(v_l2, 'Casual', DATE '2025-07-11', DATE '2025-07-12');
    SELECT days INTO v_n FROM core.staff_leave WHERE leave_id = v_id;
    PERFORM pg_temp.chk_eq('LV-03 the school''s weekly off is not a leave day (Fri-Sat)', v_n, 1);
    UPDATE academic.school_calendar_settings SET weekly_off_days = '{0}'
     WHERE tenant_id = c_tenant AND school_id = c_school;

    -- School Calendar: a Sunday declared a working day (exam day).
    INSERT INTO academic.school_calendar(tenant_id, school_id, calendar_date, day_type, title, created_by)
    VALUES (c_tenant, c_school, '2025-07-13', 'working', 'ZZ Working Sunday', c_user);
    BEGIN
        v_id := pg_temp.lv_apply(v_l2, 'Casual', DATE '2025-07-13', DATE '2025-07-13');
        SELECT days INTO v_n FROM core.staff_leave WHERE leave_id = v_id;
        PERFORM pg_temp.chk_eq('LV-04 leave on a declared working Sunday counts 1 day', v_n, 1);
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('LV-04 leave on a declared working Sunday counts 1 day', FALSE, SQLERRM);
    END;

    -- Payroll below must see a plain Mon-Sat month.
    DELETE FROM academic.school_calendar
     WHERE tenant_id = c_tenant AND school_id = c_school AND calendar_date IN ('2025-07-08', '2025-07-13');

    -- Overlap edges.
    v_id := pg_temp.lv_apply(v_l2, 'Sick', DATE '2025-07-14', DATE '2025-07-16');
    PERFORM pg_temp.lv_decide(v_id, 'Approved', 'get well');
    SELECT decision_remark, decided_at INTO r FROM core.staff_leave WHERE leave_id = v_id;
    PERFORM pg_temp.chk('LV-05 the decision remark and time are recorded',
                        r.decision_remark = 'get well' AND r.decided_at IS NOT NULL, COALESCE(r.decision_remark, 'NULL'));
    BEGIN
        PERFORM pg_temp.lv_apply(v_l2, 'Casual', DATE '2025-07-16', DATE '2025-07-17');
        PERFORM pg_temp.chk('LV-06 sharing just one day with approved leave refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('LV-06 sharing just one day with approved leave refused', TRUE, SQLERRM);
    END;

    v_id := pg_temp.lv_apply(v_l2, 'Casual', DATE '2025-07-21', DATE '2025-07-21');
    PERFORM pg_temp.lv_decide(v_id, 'Rejected', 'busy week');
    BEGIN
        v_id := pg_temp.lv_apply(v_l2, 'Casual', DATE '2025-07-21', DATE '2025-07-21');
        PERFORM pg_temp.chk('LV-07 a rejected day can be applied for again', v_id IS NOT NULL, format('leave %s', v_id));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('LV-07 a rejected day can be applied for again', FALSE, SQLERRM);
    END;

    -- Leave types are free text in the proc. Payroll only charges the exact word
    -- "Unpaid", so a type like "LOP" is accepted and silently paid in full.
    BEGIN
        PERFORM pg_temp.lv_apply(v_l2, 'LOP', DATE '2025-07-22', DATE '2025-07-22');
        PERFORM pg_temp.chk('LV-08 an unknown leave type refused', FALSE, '"LOP" accepted (payroll will not charge it)');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('LV-08 an unknown leave type refused', TRUE, SQLERRM);
    END;

    -- Entitlement: the Leave page advertises "Casual 12/yr". 1-15 Aug 2025 is 13
    -- working days of Casual (paid) leave.
    BEGIN
        v_id := pg_temp.lv_apply(v_l3, 'Casual', DATE '2025-08-01', DATE '2025-08-15');
        SELECT days INTO v_n FROM core.staff_leave WHERE leave_id = v_id;
        PERFORM pg_temp.chk('LV-09 casual leave beyond the 12/yr entitlement refused', FALSE,
                            format('%s days of paid casual leave accepted', v_n));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('LV-09 casual leave beyond the 12/yr entitlement refused', TRUE, SQLERRM);
    END;
    -- Exactly the entitlement is fine (1-14 Aug = 12 days); pending days count,
    -- so one more Casual day is refused while that request is still pending.
    v_id := pg_temp.lv_apply(v_l3, 'Casual', DATE '2025-08-01', DATE '2025-08-14');
    PERFORM pg_temp.chk_eq('LV-09b the full 12 days of casual leave accepted',
                           (SELECT days FROM core.staff_leave WHERE leave_id = v_id), 12);
    BEGIN
        PERFORM pg_temp.lv_apply(v_l3, 'Casual', DATE '2025-08-18', DATE '2025-08-18');
        PERFORM pg_temp.chk('LV-09c pending days count against the balance', FALSE, 'a 13th day was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('LV-09c pending days count against the balance', TRUE, SQLERRM);
    END;
    BEGIN
        v_id := pg_temp.lv_apply(v_l3, 'unpaid', DATE '2025-08-18', DATE '2025-08-18');
        SELECT leave_type INTO v_txt FROM core.staff_leave WHERE leave_id = v_id;
        PERFORM pg_temp.chk('LV-09d the rest can go as Unpaid (stored as "Unpaid")', v_txt = 'Unpaid', v_txt);
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('LV-09d the rest can go as Unpaid (stored as "Unpaid")', FALSE, SQLERRM);
    END;
    DECLARE cb refcursor := 'd9b';
    BEGIN
        CALL core.sp_staff_leave_manage('BALANCE', c_tenant, c_school, c_user, NULL, v_l3, NULL, DATE '2025-03-01',
                                        NULL, NULL, NULL, NULL, cb);
        LOOP FETCH cb INTO r; EXIT WHEN NOT FOUND;
            IF r.leave_type = 'Casual' THEN
                PERFORM pg_temp.chk('LV-09e balance: Casual 12 entitled, 12 pending, 0 left',
                                    r.entitled = 12 AND r.pending = 12 AND r.remaining = 0 AND r.taken = 0,
                                    format('entitled %s taken %s pending %s left %s', r.entitled, r.taken, r.pending, r.remaining));
            END IF;
        END LOOP;
        CLOSE cb;
    END;

    -- A deactivated staff member (not shown in the picker) can still be given leave.
    PERFORM pg_temp.stf('DELETE', c_tenant, c_school, v_l4, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
    BEGIN
        PERFORM pg_temp.lv_apply(v_l4, 'Casual', DATE '2025-07-01', DATE '2025-07-01');
        PERFORM pg_temp.chk('LV-10 leave for a deactivated staff member refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('LV-10 leave for a deactivated staff member refused', TRUE, SQLERRM);
    END;

    -- Leave dated before the person joined.
    BEGIN
        PERFORM pg_temp.lv_apply(v_p2, 'Casual', DATE '2025-07-01', DATE '2025-07-02');
        PERFORM pg_temp.chk('LV-11 leave before the joining date refused', FALSE, 'joined 15 Jul, leave on 1-2 Jul accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('LV-11 leave before the joining date refused', TRUE, SQLERRM);
    END;

    -- Half a day: days is numeric, and a half-day request counts 0.5.
    SELECT data_type INTO v_txt FROM information_schema.columns
     WHERE table_schema = 'core' AND table_name = 'staff_leave' AND column_name = 'days';
    PERFORM pg_temp.chk('LV-12 a half-day leave can be recorded', v_txt IN ('numeric', 'real', 'double precision'),
                        format('staff_leave.days is %s', v_txt));
    DECLARE v_h integer;
    BEGIN
        v_h := pg_temp.lv_apply(v_l3, 'Unpaid', DATE '2025-07-24', DATE '2025-07-24', 24, 34, TRUE);
        PERFORM pg_temp.lv_decide(v_h, 'Approved');
        PERFORM pg_temp.chk_eq('LV-12b a half-day request counts 0.5 day',
                               (SELECT days FROM core.staff_leave WHERE leave_id = v_h), 0.5);
    END;
    BEGIN
        PERFORM pg_temp.lv_apply(v_l3, 'Sick', DATE '2025-07-25', DATE '2025-07-26', 24, 34, TRUE);
        PERFORM pg_temp.chk('LV-12c a half day spanning two dates refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('LV-12c a half day spanning two dates refused', TRUE, SQLERRM);
    END;
    -- The form's preview counts exactly what APPLY will.
    DECLARE cd refcursor := 'd12d';
    BEGIN
        INSERT INTO academic.school_calendar(tenant_id, school_id, calendar_date, day_type, title, created_by)
        VALUES (c_tenant, c_school, '2025-07-29', 'holiday', 'ZZ Preview Holiday', c_user);
        CALL core.sp_staff_leave_manage('DAYS', c_tenant, c_school, c_user, NULL, NULL, NULL,
                                        DATE '2025-07-28', DATE '2025-08-03', NULL, NULL, NULL, cd);
        FETCH cd INTO r; CLOSE cd;
        PERFORM pg_temp.chk_eq('LV-12d day preview follows the School Calendar (Mon-Sun, Tue holiday)', r.days, 5);
        DELETE FROM academic.school_calendar
         WHERE tenant_id = c_tenant AND school_id = c_school AND calendar_date = '2025-07-29';
    END;

    BEGIN
        PERFORM pg_temp.lv_decide(v_id, NULL);
        PERFORM pg_temp.chk('LV-13 a NULL decision refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('LV-13 a NULL decision refused', TRUE, SQLERRM);
    END;

    -- Another school deciding our leave by id.
    v_id := pg_temp.lv_apply(v_l2, 'Casual', DATE '2025-07-23', DATE '2025-07-23');
    BEGIN
        PERFORM pg_temp.lv_decide(v_id, 'Approved', 'not yours', 23, 33);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    SELECT status INTO v_txt FROM core.staff_leave WHERE leave_id = v_id;
    PERFORM pg_temp.chk('LV-14 another school cannot decide our leave', v_txt = 'Pending', v_txt);

    c := 'd15';
    CALL core.sp_staff_leave_manage('LIST', 23, 33, c_user, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, c);
    v_n := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
        IF r.staff_id IN (v_l1, v_l2, v_l3, v_p2) THEN v_n := v_n + 1; END IF;
    END LOOP;
    PERFORM pg_temp.chk_eq('LV-15 another school''s leave list shows none of ours', v_n, 0);

    -- "On leave today" comes from the proc.
    v_id := pg_temp.lv_apply(v_l1, 'Sick', CURRENT_DATE, CURRENT_DATE + 1);
    PERFORM pg_temp.lv_decide(v_id, 'Approved');
    c := 'd16';
    CALL core.sp_staff_leave_manage('LIST', c_tenant, c_school, c_user, NULL, v_l1, NULL, NULL, NULL, NULL, 'Approved', NULL, c);
    v_b := FALSE;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.leave_id = v_id THEN v_b := r.on_leave_today; END IF; END LOOP;
    PERFORM pg_temp.chk('LV-16 approved leave covering today is flagged on-leave-today', v_b, '');

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- E. Payroll ------------------------------------------';

    v_p1 := pg_temp.stf('INSERT', c_tenant, c_school, NULL, 'ZZHR-P1', 'ZZ HR Pay Full', NULL, NULL,
                        'Teacher', NULL, 'Teaching', DATE '2024-01-01', 'Active', 27000);
    v_p3 := pg_temp.stf('INSERT', c_tenant, c_school, NULL, 'ZZHR-P3', 'ZZ HR Joins September', NULL, NULL,
                        'Teacher', NULL, 'Teaching', DATE '2025-09-01', 'Active', 27000);
    v_p4 := pg_temp.stf('INSERT', c_tenant, c_school, NULL, 'ZZHR-P4', 'ZZ HR Left 20 July', NULL, NULL,
                        'Teacher', NULL, 'Teaching', DATE '2024-01-01', 'Active', 27000);
    v_p5 := pg_temp.stf('INSERT', c_tenant, c_school, NULL, 'ZZHR-P5', 'ZZ HR On Leave Status', NULL, NULL,
                        'Teacher', NULL, 'Teaching', DATE '2024-01-01', 'Active', 27000);
    v_p7 := pg_temp.stf('INSERT', c_tenant, c_school, NULL, 'ZZHR-P7', 'ZZ HR All Unpaid', NULL, NULL,
                        'Teacher', NULL, 'Teaching', DATE '2024-01-01', 'Active', 30000);
    v_p8 := pg_temp.stf('INSERT', c_tenant, c_school, NULL, 'ZZHR-P8', 'ZZ HR Left After Run', NULL, NULL,
                        'Teacher', NULL, 'Teaching', DATE '2024-01-01', 'Active', 27000);

    -- P1: 3 unpaid days (Wed 2 - Fri 4 Jul) + unpaid Wed 30 Jul - Sat 2 Aug
    -- (2 days in July, 2 in August).
    v_id := pg_temp.lv_apply(v_p1, 'Unpaid', DATE '2025-07-02', DATE '2025-07-04');
    PERFORM pg_temp.lv_decide(v_id, 'Approved');
    v_id := pg_temp.lv_apply(v_p1, 'Unpaid', DATE '2025-07-30', DATE '2025-08-02');
    PERFORM pg_temp.lv_decide(v_id, 'Approved');
    PERFORM pg_temp.chk_eq('PAY-00 the month-end leave is 4 working days', (SELECT days FROM core.staff_leave WHERE leave_id = v_id), 4);

    -- P7: every working day of July unpaid.
    v_id := pg_temp.lv_apply(v_p7, 'Unpaid', DATE '2025-07-01', DATE '2025-07-31');
    PERFORM pg_temp.lv_decide(v_id, 'Approved');

    -- P4's last working day was Sat 19 Jul; deactivated before payroll was run.
    PERFORM pg_temp.stf('DELETE', c_tenant, c_school, v_p4, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
                        FALSE, NULL, NULL, DATE '2025-07-19');
    -- P5 was put "On Leave" from the edit form (e.g. maternity).
    PERFORM pg_temp.stf('UPDATE', c_tenant, c_school, v_p5, 'ZZHR-P5', 'ZZ HR On Leave Status', NULL, NULL,
                        'Teacher', NULL, 'Teaching', DATE '2024-01-01', 'On Leave', 27000);

    PERFORM pg_temp.pay_run(7, 2025);

    SELECT * INTO r FROM core.staff_payroll WHERE staff_id = v_p1 AND pay_month = 7 AND pay_year = 2025;
    PERFORM pg_temp.chk_eq('PAY-01 LOP inside July = 3 + 2 (month-end leave split)', r.lop_days, 5);
    PERFORM pg_temp.chk_eq('PAY-01b LOP amount = 5 x 1000', r.lop_amount, 5000);
    PERFORM pg_temp.chk_eq('PAY-01c net = 27000 - 5000', r.net_pay, 22000);
    PERFORM pg_temp.chk('PAY-01d the run records who generated it and when',
                        r.generated_by = c_user AND r.generated_at IS NOT NULL, format('generated_by %s', r.generated_by));
    PERFORM pg_temp.chk('PAY-01e a fresh payslip is Draft, not paid', r.status = 'Draft' AND r.paid_at IS NULL, r.status);

    -- Joined Tue 15 Jul: worked 15 of 27 working days.
    SELECT net_pay INTO v_dec FROM core.staff_payroll WHERE staff_id = v_p2 AND pay_month = 7 AND pay_year = 2025;
    PERFORM pg_temp.chk_eq('PAY-02 a mid-month joiner is paid pro-rata (15/27 days)', v_dec, 15000);

    -- Joins in September: not employed in July at all.
    SELECT net_pay INTO v_dec FROM core.staff_payroll WHERE staff_id = v_p3 AND pay_month = 7 AND pay_year = 2025;
    PERFORM pg_temp.chk('PAY-03 no salary for a month before the joining date', v_dec IS NULL,
                        format('July payslip net %s for someone joining 1 Sep', v_dec));

    -- Last worked Sat 19 Jul, deactivated before the run: 17 of 27 days -> 17000.
    DECLARE v_cnt integer; v_net numeric; v_days numeric;
    BEGIN
        SELECT COUNT(*), MAX(net_pay), MAX(paid_days) INTO v_cnt, v_net, v_days FROM core.staff_payroll
         WHERE staff_id = v_p4 AND pay_month = 7 AND pay_year = 2025;
        PERFORM pg_temp.chk('PAY-04 a leaver is paid for the days worked in the last month',
                            v_cnt = 1 AND v_net = 17000 AND v_days = 17,
                            format('%s payslip(s), net %s for %s days (1-19 Jul worked)', v_cnt, v_net, v_days));
    END;

    -- Half-day unpaid leave on 24 Jul (LV-12b) costs half a day: 500.
    SELECT lop_days, lop_amount INTO r FROM core.staff_payroll WHERE staff_id = v_l3 AND pay_month = 7 AND pay_year = 2025;
    PERFORM pg_temp.chk('PAY-04b a half-day LOP is 0.5 day = 500', r.lop_days = 0.5 AND r.lop_amount = 500,
                        format('LOP %s days = %s', r.lop_days, r.lop_amount));

    -- "On Leave" (long leave) still gets a payslip.
    SELECT COUNT(*) INTO v_n FROM core.staff_payroll WHERE staff_id = v_p5 AND pay_month = 7 AND pay_year = 2025;
    PERFORM pg_temp.chk('PAY-05 status "On Leave" still gets a payslip', v_n = 1,
                        format('%s payslip(s)', v_n));

    -- Every working day unpaid: LOP is worked from the salary, not from a rounded
    -- 1111.11 a day, so nothing is left over (it used to net 0.03).
    SELECT gross, lop_amount, net_pay INTO r FROM core.staff_payroll WHERE staff_id = v_p7 AND pay_month = 7 AND pay_year = 2025;
    PERFORM pg_temp.chk('PAY-06 a month that is all unpaid leave nets exactly 0', r.net_pay = 0,
                        format('gross %s - LOP %s = net %s', r.gross, r.lop_amount, r.net_pay));

    -- August: P1's 2 remaining days (Fri 1, Sat 2). August 2025 has 26 working days.
    PERFORM pg_temp.pay_run(8, 2025);
    SELECT lop_days INTO v_n FROM core.staff_payroll WHERE staff_id = v_p1 AND pay_month = 8 AND pay_year = 2025;
    PERFORM pg_temp.chk_eq('PAY-07 the August half of the month-end leave lands in August', v_n, 2);
    SELECT COUNT(*) INTO v_n FROM core.staff_payroll WHERE staff_id = v_p4 AND pay_month = 8 AND pay_year = 2025;
    PERFORM pg_temp.chk_eq('PAY-07b no payslip for the month after the last working day', v_n, 0);

    -- Deactivated AFTER the run (last working day today): the July draft stays.
    PERFORM pg_temp.stf('DELETE', c_tenant, c_school, v_p8, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
    PERFORM pg_temp.pay_run(7, 2025);
    SELECT net_pay INTO v_dec FROM core.staff_payroll WHERE staff_id = v_p8 AND pay_month = 7 AND pay_year = 2025;
    PERFORM pg_temp.chk_eq('PAY-08 deactivating after the run keeps the July draft', v_dec, 27000);

    -- ── Mark paid, then try every way of rewriting it ──
    DECLARE v_pid integer; v_before record; v_after record; v_lv integer;
    BEGIN
        SELECT payroll_id INTO v_pid FROM core.staff_payroll WHERE staff_id = v_p1 AND pay_month = 7 AND pay_year = 2025;

        -- Another school paying our payslip.
        BEGIN
            PERFORM pg_temp.pay_paid(v_pid, 23, 33);
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        SELECT status INTO v_txt FROM core.staff_payroll WHERE payroll_id = v_pid;
        PERFORM pg_temp.chk('PAY-09 another school cannot mark our payslip paid', v_txt = 'Draft', v_txt);

        -- A bank payment without its reference cannot be traced: refused.
        BEGIN
            PERFORM pg_temp.pay_paid(v_pid, 24, 34, 'Bank Transfer', '  ');
            PERFORM pg_temp.chk('PAY-17b a bank payment without a reference refused', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('PAY-17b a bank payment without a reference refused', TRUE, SQLERRM);
        END;
        BEGIN
            PERFORM pg_temp.pay_paid(v_pid, 24, 34, NULL, NULL);
            PERFORM pg_temp.chk('PAY-17c a payment without a mode refused', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('PAY-17c a payment without a mode refused', TRUE, SQLERRM);
        END;

        PERFORM pg_temp.pay_paid(v_pid);
        SELECT * INTO v_before FROM core.staff_payroll WHERE payroll_id = v_pid;
        PERFORM pg_temp.chk('PAY-10 paid: status, who and when recorded',
                            v_before.status = 'Paid' AND v_before.paid_by = c_user AND v_before.paid_at IS NOT NULL,
                            format('%s by %s', v_before.status, v_before.paid_by));
        PERFORM pg_temp.chk('PAY-17 a payment records its mode and reference',
                            v_before.payment_mode = 'Bank Transfer' AND v_before.payment_reference = 'UTR-ZZ-0001',
                            format('%s / %s', v_before.payment_mode, v_before.payment_reference));
        SELECT COUNT(*) INTO v_n FROM core.staff_payroll_history
         WHERE payroll_id = v_pid AND action = 'PAID' AND net_pay = 22000 AND action_by = c_user
           AND payment_reference = 'UTR-ZZ-0001';
        PERFORM pg_temp.chk_eq('PAY-17d the payment is in the money trail (amount, who, reference)', v_n, 1);

        -- Nothing may rewrite a paid slip, not even a direct UPDATE.
        BEGIN
            UPDATE core.staff_payroll SET net_pay = 1 WHERE payroll_id = v_pid;
            PERFORM pg_temp.chk('PAY-11d a direct UPDATE of a paid payslip refused', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('PAY-11d a direct UPDATE of a paid payslip refused', TRUE, SQLERRM);
        END;
        BEGIN
            UPDATE core.staff_payroll_history SET net_pay = 1 WHERE payroll_id = v_pid;
            PERFORM pg_temp.chk('PAY-11e the money trail cannot be edited', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('PAY-11e the money trail cannot be edited', TRUE, SQLERRM);
        END;

        -- After payment: salary is revised, and a further unpaid day in July is
        -- approved late. Then the month is re-run.
        PERFORM pg_temp.stf('UPDATE', c_tenant, c_school, v_p1, 'ZZHR-P1', 'ZZ HR Pay Full', NULL, NULL,
                            'Teacher', NULL, 'Teaching', DATE '2024-01-01', 'Active', 50000);
        v_lv := pg_temp.lv_apply(v_p1, 'Unpaid', DATE '2025-07-22', DATE '2025-07-22');
        PERFORM pg_temp.lv_decide(v_lv, 'Approved');
        DECLARE cr refcursor := 'e11run';
        BEGIN
            CALL core.sp_staff_payroll_manage('RUN', c_tenant, c_school, c_user, 7, 2025, NULL, NULL, cr);
            FETCH cr INTO r; CLOSE cr;
            PERFORM pg_temp.chk('PAY-11c the re-run reports the paid slip that now differs',
                                r.message LIKE '%paid payslip(s) differ%', r.message);
        END;

        SELECT * INTO v_after FROM core.staff_payroll WHERE payroll_id = v_pid;
        PERFORM pg_temp.chk('PAY-11 a re-run never rewrites a PAID payslip',
                            v_after.gross = v_before.gross AND v_after.lop_days = v_before.lop_days
                            AND v_after.lop_amount = v_before.lop_amount AND v_after.net_pay = v_before.net_pay
                            AND v_after.paid_at = v_before.paid_at AND v_after.paid_by = v_before.paid_by
                            AND v_after.generated_at = v_before.generated_at,
                            format('gross %s net %s lop %s (was %s / %s / %s)', v_after.gross, v_after.net_pay,
                                   v_after.lop_days, v_before.gross, v_before.net_pay, v_before.lop_days));
        SELECT COUNT(*) INTO v_n FROM core.staff_payroll WHERE staff_id = v_p1 AND pay_month = 7 AND pay_year = 2025;
        PERFORM pg_temp.chk_eq('PAY-11b still exactly one July payslip', v_n, 1);

        -- The paid slip of someone later deactivated is still listed (history).
        PERFORM pg_temp.stf('DELETE', c_tenant, c_school, v_p1, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
        c := 'e12';
        CALL core.sp_staff_payroll_manage('LIST', c_tenant, c_school, c_user, 7, 2025, NULL, NULL, c);
        v_b := FALSE;
        LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.payroll_id = v_pid THEN v_b := TRUE; END IF; END LOOP;
        PERFORM pg_temp.chk('PAY-12 a paid slip stays listed after the person leaves', v_b, '');
    END;

    -- Department filter is case-insensitive and scoped.
    c := 'e13';
    CALL core.sp_staff_payroll_manage('LIST', c_tenant, c_school, c_user, 7, 2025, NULL, 'teaching', c);
    v_n := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.staff_id = v_p2 THEN v_n := v_n + 1; END IF; END LOOP;
    PERFORM pg_temp.chk_eq('PAY-13 department filter matches any case', v_n, 1);

    c := 'e14';
    CALL core.sp_staff_payroll_manage('LIST', 23, 33, c_user, 7, 2025, NULL, NULL, c);
    v_n := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.staff_id IN (v_p1, v_p2, v_p7, v_p8) THEN v_n := v_n + 1; END IF; END LOOP;
    PERFORM pg_temp.chk_eq('PAY-14 another school''s payroll list shows none of ours', v_n, 0);

    BEGIN
        PERFORM pg_temp.pay_run(13, 2025);
        PERFORM pg_temp.chk('PAY-15 month 13 refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('PAY-15 month 13 refused', TRUE, SQLERRM);
    END;

    -- The page says "payroll is never run for a future month" -- only the page.
    DECLARE v_fm date := DATE_TRUNC('month', CURRENT_DATE + INTERVAL '2 months')::date;
    BEGIN
        BEGIN
            PERFORM pg_temp.pay_run(EXTRACT(MONTH FROM v_fm)::int, EXTRACT(YEAR FROM v_fm)::int);
            SELECT COUNT(*) INTO v_n FROM core.staff_payroll
             WHERE tenant_id = c_tenant AND school_id = c_school
               AND pay_month = EXTRACT(MONTH FROM v_fm) AND pay_year = EXTRACT(YEAR FROM v_fm);
            PERFORM pg_temp.chk('PAY-16 payroll for a future month refused', FALSE,
                                format('%s payslip(s) generated for %s', v_n, to_char(v_fm, 'Mon YYYY')));
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('PAY-16 payroll for a future month refused', TRUE, SQLERRM);
        END;
    END;

    -- Advances, deductions and additions: recorded as adjustments with who / when /
    -- why, picked up by the draft at once, never edited -- only voided.
    -- P2's July draft is 15000 (PAY-02).
    DECLARE v_add integer; v_adv integer; v_net numeric; v_pid2 integer;
    BEGIN
        v_add := pg_temp.pay_adj('ADD', NULL, v_p2, 7, 2025, 'Addition', 2000, 'July arrears');
        SELECT net_pay, other_add INTO r FROM core.staff_payroll WHERE staff_id = v_p2 AND pay_month = 7 AND pay_year = 2025;
        PERFORM pg_temp.chk('PAY-18 an addition is recorded and the draft picks it up (15000 + 2000)',
                            r.net_pay = 17000 AND r.other_add = 2000, format('net %s, additions %s', r.net_pay, r.other_add));

        v_adv := pg_temp.pay_adj('ADD', NULL, v_p2, 7, 2025, 'Advance', 5000, 'festival advance', 'Cash', NULL);
        SELECT net_pay, other_deduct INTO r FROM core.staff_payroll WHERE staff_id = v_p2 AND pay_month = 7 AND pay_year = 2025;
        PERFORM pg_temp.chk('PAY-18b an advance is deducted from that month (17000 - 5000)',
                            r.net_pay = 12000 AND r.other_deduct = 5000, format('net %s, deductions %s', r.net_pay, r.other_deduct));
        SELECT * INTO r FROM core.staff_payroll_adjustment WHERE adjustment_id = v_adv;
        PERFORM pg_temp.chk('PAY-18c the advance keeps who, when, mode and reason',
                            r.created_by = c_user AND r.created_at IS NOT NULL AND r.payment_mode = 'Cash'
                            AND r.reason = 'festival advance', format('%s / %s / %s', r.created_by, r.payment_mode, r.reason));

        BEGIN
            PERFORM pg_temp.pay_adj('ADD', NULL, v_p2, 7, 2025, 'Advance', 1000, 'no mode given');
            PERFORM pg_temp.chk('PAY-18d an advance without a payment mode refused', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('PAY-18d an advance without a payment mode refused', TRUE, SQLERRM);
        END;
        BEGIN
            PERFORM pg_temp.pay_adj('ADD', NULL, v_p2, 7, 2025, 'Deduction', 20000, 'more than the pay');
            PERFORM pg_temp.chk('PAY-18e a deduction larger than the pay left refused', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('PAY-18e a deduction larger than the pay left refused', TRUE, SQLERRM);
        END;
        BEGIN
            PERFORM pg_temp.pay_adj('ADD', NULL, v_p2, 7, 2025, 'Deduction', 100, '   ');
            PERFORM pg_temp.chk('PAY-18f an adjustment without a reason refused', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('PAY-18f an adjustment without a reason refused', TRUE, SQLERRM);
        END;
        -- July is PAID for P1: the correction must go to an unpaid month.
        BEGIN
            PERFORM pg_temp.pay_adj('ADD', NULL, v_p1, 7, 2025, 'Deduction', 1000, 'late LOP 22 Jul');
            PERFORM pg_temp.chk('PAY-18g an adjustment to a PAID month refused', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('PAY-18g an adjustment to a PAID month refused', TRUE, SQLERRM);
        END;
        v_id := pg_temp.pay_adj('ADD', NULL, v_p1, 8, 2025, 'Deduction', 1000, 'LOP 22 Jul approved after July was paid');
        PERFORM pg_temp.chk('PAY-18h ...and is accepted in the next unpaid month', v_id IS NOT NULL, format('adjustment %s', v_id));
        BEGIN
            PERFORM pg_temp.pay_adj('ADD', NULL, v_p3, 7, 2025, 'Addition', 100, 'not employed yet');
            PERFORM pg_temp.chk('PAY-18i an adjustment for a month before joining refused', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('PAY-18i an adjustment for a month before joining refused', TRUE, SQLERRM);
        END;

        -- Void the addition: the row stays (void, with reason), the draft drops back.
        PERFORM pg_temp.pay_adj('VOID', v_add, NULL, NULL, NULL, NULL, NULL, 'entered twice');
        SELECT net_pay INTO v_net FROM core.staff_payroll WHERE staff_id = v_p2 AND pay_month = 7 AND pay_year = 2025;
        SELECT * INTO r FROM core.staff_payroll_adjustment WHERE adjustment_id = v_add;
        PERFORM pg_temp.chk('PAY-18j a voided addition stays on record and leaves the draft (15000 - 5000)',
                            v_net = 10000 AND r.is_void AND r.void_reason = 'entered twice' AND r.voided_by = c_user,
                            format('net %s, void %s, reason %s', v_net, r.is_void, r.void_reason));

        -- Pay P2 in cash (no reference needed), then the trail tells the whole story.
        SELECT payroll_id INTO v_pid2 FROM core.staff_payroll WHERE staff_id = v_p2 AND pay_month = 7 AND pay_year = 2025;
        PERFORM pg_temp.pay_paid(v_pid2, 24, 34, 'Cash', NULL);
        SELECT string_agg(action, ',' ORDER BY history_id) INTO v_txt FROM core.staff_payroll_history
         WHERE staff_id = v_p2 AND pay_month = 7 AND pay_year = 2025;
        PERFORM pg_temp.chk('PAY-19 the money trail: generated, adjusted, regenerated, voided, paid',
                            v_txt LIKE 'GENERATED,%' AND v_txt LIKE '%ADJUSTMENT_ADDED%' AND v_txt LIKE '%REGENERATED%'
                            AND v_txt LIKE '%ADJUSTMENT_VOIDED%' AND v_txt LIKE '%,PAID', v_txt);
        BEGIN
            PERFORM pg_temp.pay_adj('VOID', v_adv, NULL, NULL, NULL, NULL, NULL, 'after payment');
            PERFORM pg_temp.chk('PAY-19b an adjustment in a paid month cannot be voided', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('PAY-19b an adjustment in a paid month cannot be voided', TRUE, SQLERRM);
        END;

        -- A re-run with nothing changed writes no new trail rows.
        -- (P1's August draft already took the 1000 correction when it was added.)
        SELECT COUNT(*) INTO v_n FROM core.staff_payroll WHERE staff_id = v_p1 AND pay_month = 8 AND pay_year = 2025
           AND other_deduct = 1000;
        PERFORM pg_temp.chk_eq('PAY-19c the August draft carries the correction for July', v_n, 1);
        SELECT COUNT(*) INTO v_n FROM core.staff_payroll_history WHERE tenant_id = c_tenant AND school_id = c_school;
        PERFORM pg_temp.pay_run(8, 2025);
        SELECT COUNT(*) - v_n INTO v_n FROM core.staff_payroll_history WHERE tenant_id = c_tenant AND school_id = c_school;
        PERFORM pg_temp.chk_eq('PAY-19d a re-run with nothing changed writes no new trail rows', v_n, 0);
    END;

    -- Pending payroll for a deleted/out-of-scope adjustment target: another school cannot add one.
    BEGIN
        DECLARE cx refcursor := 'pax';
        BEGIN
            CALL core.sp_staff_payroll_adjust('ADD', 23, 33, c_user, NULL, v_p8, 7, 2025, 'Addition', 100, 'not yours',
                                              NULL, NULL, cx);
        END;
        PERFORM pg_temp.chk('PAY-20 another school cannot adjust our staff''s pay', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('PAY-20 another school cannot adjust our staff''s pay', TRUE, SQLERRM);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- F. Leakage ------------------------------------------';

    SELECT COUNT(*) INTO v_n FROM core.staff
     WHERE (full_name LIKE 'ZZ HR%' OR employee_code LIKE 'ZZHR%') AND (tenant_id <> c_tenant OR school_id <> c_school);
    PERFORM pg_temp.chk_eq('LEAK-01 no ZZ staff landed in another school', v_n, 0);

    SELECT COUNT(*) INTO v_n FROM core.staff_payroll p JOIN core.staff s ON s.staff_id = p.staff_id
     WHERE s.full_name LIKE 'ZZ HR%' AND (p.tenant_id <> s.tenant_id OR p.school_id <> s.school_id);
    PERFORM pg_temp.chk_eq('LEAK-02 no payslip escaped its staff member''s school', v_n, 0);

    SELECT COUNT(*) INTO v_n FROM core.staff_leave l JOIN core.staff s ON s.staff_id = l.staff_id
     WHERE s.full_name LIKE 'ZZ HR%' AND (l.tenant_id <> s.tenant_id OR l.school_id <> s.school_id);
    PERFORM pg_temp.chk_eq('LEAK-03 no leave escaped its staff member''s school', v_n, 0);
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
