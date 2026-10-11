-- ============================================================================
-- Staff self-service test suite (staff_self_service.sql): My Leave, My Payslip.
--
-- A member of staff sees and acts on their OWN leave and payslips only. The
-- staff id always comes from the signed-in user, never from the request, so
-- the rules worth testing are: the figures match HR's, an application behaves
-- exactly like an HR-entered one, and nothing of anyone else is reachable.
--
-- Runs inside ONE transaction and ROLLS BACK.
--
--     psql ... -f staff_self_service_tests.sql
--
-- Fixture: tenant 24 / school 34 / admin user 39 (no staff record). The suite
-- creates its own users and staff: "me", a colleague, an inactive member of
-- staff, and one member of staff of school 23 / 33. Dates are in Jan-Mar 2027
-- (the future), on a Mon-Sat week the suite sets for itself. 1 Jan 2027 is a
-- Friday, so Mon 4 - Sat 16 Jan 2027 holds 12 working days.
--
-- COVERS
--   A. Who am I (ME), and a user with no staff record
--   B. Apply: Pending, visible to HR and on the dashboard; caps, Unpaid, overlap, half day
--   C. Balance matches HR's figures
--   D. Cancel: own pending, someone else's, approved (future / started / paid month)
--   E. Inactive staff
--   F. Payslips: own only, never a colleague's or another school's; no reference
--   G. Scope and leakage
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

-- ── Wrappers: every row of the cursor as a jsonb array (raise when refused) ──
CREATE OR REPLACE FUNCTION pg_temp.ml(p_op text, p_t int, p_s int, p_u int,
                                      p_leave int DEFAULT NULL, p_type text DEFAULT NULL,
                                      p_from date DEFAULT NULL, p_to date DEFAULT NULL,
                                      p_half boolean DEFAULT FALSE, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'ml'; r record; v jsonb := '[]'::jsonb;
BEGIN
    CALL core.sp_staff_my_leave(p_op, p_t, p_s, p_u, p_leave, p_type, p_from, p_to, p_half, p_reason, c);
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v := v || jsonb_build_array(to_jsonb(r)); END LOOP;
    CLOSE c;
    RETURN v;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.mp(p_op text, p_t int, p_s int, p_u int, p_id int DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'mp'; r record; v jsonb := '[]'::jsonb;
BEGIN
    CALL core.sp_staff_my_payslip(p_op, p_t, p_s, p_u, p_id, c);
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v := v || jsonb_build_array(to_jsonb(r)); END LOOP;
    CLOSE c;
    RETURN v;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.hr(p_op text, p_t int, p_s int, p_u int,
                                      p_leave int DEFAULT NULL, p_staff int DEFAULT NULL,
                                      p_type text DEFAULT NULL, p_from date DEFAULT NULL,
                                      p_to date DEFAULT NULL, p_status text DEFAULT NULL,
                                      p_remark text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'hr'; r record; v jsonb := '[]'::jsonb;
BEGIN
    CALL core.sp_staff_leave_manage(p_op, p_t, p_s, p_u, p_leave, p_staff, p_type, p_from, p_to,
                                    NULL, p_status, p_remark, c, FALSE);
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v := v || jsonb_build_array(to_jsonb(r)); END LOOP;
    CLOSE c;
    RETURN v;
END $$;


DO $suite$
DECLARE
    c_tenant CONSTANT integer := 24;
    c_school CONSTANT integer := 34;
    c_admin  CONSTANT integer := 39;    -- school admin, no staff record
    c_xt     CONSTANT integer := 23;
    c_xs     CONSTANT integer := 33;

    u_me  integer;  s_me  integer;      -- "me"
    u_col integer;  s_col integer;      -- a colleague
    u_ina integer;  s_ina integer;      -- inactive staff
    u_x   integer;  s_x   integer;      -- staff of school 23 / 33

    v      jsonb;
    v2     jsonb;
    v_n    integer;
    v_dec  numeric;
    v_txt  text;
    v_id   integer;
    v_l1   integer;   -- my pending casual 4-16 Jan
    v_lc   integer;   -- colleague's pending
    v_la   integer;   -- my approved future leave (Feb)
    v_lp   integer;   -- my approved leave in an already-paid month (Mar)
    v_ls   integer;   -- my approved leave that already started
    p_p    integer;   -- my paid payslip
    p_col  integer;   -- colleague's payslip
    p_x    integer;   -- other school's payslip
    r      record;
    k  refcursor := 'db_kpi';        t  refcursor := 'db_trend';
    cl refcursor := 'db_classes';    m  refcursor := 'db_modes';
    df refcursor := 'db_defaulters'; rc refcursor := 'db_recent';
    ap refcursor := 'db_approvals';  ev refcursor := 'db_events';
    bd refcursor := 'db_birthdays';
    v_before_x integer;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '========= STAFF SELF-SERVICE TESTS =========';

    SELECT COUNT(*) INTO v_before_x FROM core.staff_leave WHERE tenant_id = c_xt;

    -- The suite owns Jan-Mar 2027 on this school's calendar while it runs.
    DELETE FROM academic.school_calendar
     WHERE tenant_id = c_tenant AND school_id = c_school AND calendar_date LIKE '2027-0%';
    UPDATE academic.school_calendar_settings SET weekly_off_days = '{0}'
     WHERE tenant_id = c_tenant AND school_id = c_school;

    -- ── Fixture: users and staff ────────────────────────────────────────────
    INSERT INTO core.users(tenant_id, school_id, email, password_hash)
    VALUES (c_tenant, c_school, 'zz.self.me@local.test', 'x') RETURNING user_id INTO u_me;
    INSERT INTO core.users(tenant_id, school_id, email, password_hash)
    VALUES (c_tenant, c_school, 'zz.self.col@local.test', 'x') RETURNING user_id INTO u_col;
    INSERT INTO core.users(tenant_id, school_id, email, password_hash)
    VALUES (c_tenant, c_school, 'zz.self.ina@local.test', 'x') RETURNING user_id INTO u_ina;
    INSERT INTO core.users(tenant_id, school_id, email, password_hash)
    VALUES (c_xt, c_xs, 'zz.self.x@local.test', 'x') RETURNING user_id INTO u_x;

    INSERT INTO core.staff(tenant_id, school_id, employee_code, full_name, designation, department,
                           joining_date, status, monthly_salary, user_id)
    VALUES (c_tenant, c_school, 'ZZSS-01', 'ZZ Self Me', 'Teacher', 'Teaching', '2025-01-01', 'Active', 27000, u_me)
    RETURNING staff_id INTO s_me;
    INSERT INTO core.staff(tenant_id, school_id, employee_code, full_name, designation, department,
                           joining_date, status, monthly_salary, user_id)
    VALUES (c_tenant, c_school, 'ZZSS-02', 'ZZ Self Colleague', 'Teacher', 'Teaching', '2025-01-01', 'Active', 54000, u_col)
    RETURNING staff_id INTO s_col;
    INSERT INTO core.staff(tenant_id, school_id, employee_code, full_name, designation, department,
                           joining_date, status, is_active, monthly_salary, user_id, last_working_date)
    VALUES (c_tenant, c_school, 'ZZSS-03', 'ZZ Self Inactive', 'Teacher', 'Teaching', '2025-01-01', 'Inactive', FALSE, 20000, u_ina, '2026-09-30')
    RETURNING staff_id INTO s_ina;
    INSERT INTO core.staff(tenant_id, school_id, employee_code, full_name, designation, department,
                           joining_date, status, monthly_salary, user_id)
    VALUES (c_xt, c_xs, 'ZZSS-X1', 'ZZ Self Other School', 'Teacher', 'Teaching', '2025-01-01', 'Active', 40000, u_x)
    RETURNING staff_id INTO s_x;

    RAISE NOTICE 'fixture: me %/% colleague %/% inactive %/% other school %/%',
                 u_me, s_me, u_col, s_col, u_ina, s_ina, u_x, s_x;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- A. Who am I -------------------------------------------';

    v := pg_temp.ml('ME', c_tenant, c_school, u_me);
    PERFORM pg_temp.chk('SS-A1 ME returns my own staff row',
                        jsonb_array_length(v) = 1 AND (v->0->>'staff_id')::int = s_me, v::text);

    v := pg_temp.ml('ME', c_tenant, c_school, c_admin);
    PERFORM pg_temp.chk_eq('SS-A2 a user with no staff record: ME is empty', jsonb_array_length(v), 0);
    v := pg_temp.ml('LIST', c_tenant, c_school, c_admin);
    PERFORM pg_temp.chk_eq('SS-A3 ...and LIST is empty', jsonb_array_length(v), 0);
    v := pg_temp.mp('LIST', c_tenant, c_school, c_admin);
    PERFORM pg_temp.chk_eq('SS-A4 ...and has no payslips', jsonb_array_length(v), 0);
    BEGIN
        v := pg_temp.ml('APPLY', c_tenant, c_school, c_admin, NULL, 'Casual', DATE '2027-01-04', DATE '2027-01-04');
        PERFORM pg_temp.chk('SS-A5 ...and cannot apply', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('SS-A5 ...and cannot apply', SQLERRM LIKE '%staff record%', SQLERRM);
    END;
    BEGIN
        v := pg_temp.ml('BALANCE', c_tenant, c_school, c_admin);
        PERFORM pg_temp.chk('SS-A6 ...and has no balance', FALSE, 'returned rows');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('SS-A6 ...and has no balance', TRUE, SQLERRM);
    END;

    -- The procs have no staff id parameter at all: there is nothing to post.
    SELECT COUNT(*) INTO v_n FROM pg_proc pr JOIN pg_namespace n ON n.oid = pr.pronamespace
     WHERE n.nspname = 'core' AND pr.proname IN ('sp_staff_my_leave', 'sp_staff_my_payslip')
       AND 'p_staff_id' = ANY (pr.proargnames);
    PERFORM pg_temp.chk_eq('SS-A7 no staff id parameter on the self-service procs', v_n, 0);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- B. Apply ----------------------------------------------';

    v := pg_temp.ml('DAYS', c_tenant, c_school, u_me, NULL, NULL, DATE '2027-01-04', DATE '2027-01-16');
    PERFORM pg_temp.chk_eq('SS-B1 preview: 4-16 Jan 2027 = 12 working days', (v->0->>'days')::numeric, 12);

    v := pg_temp.ml('APPLY', c_tenant, c_school, u_me, NULL, 'casual', DATE '2027-01-04', DATE '2027-01-16',
                    FALSE, 'Family function');
    v_l1 := (v->0->>'leave_id')::int;
    PERFORM pg_temp.chk_eq('SS-B2 apply for myself: 12 days', (v->0->>'days')::numeric, 12);

    SELECT COUNT(*) INTO v_n FROM core.staff_leave
     WHERE leave_id = v_l1 AND staff_id = s_me AND status = 'Pending' AND applied_by = u_me
       AND leave_type = 'Casual' AND tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk_eq('SS-B3 ...stored Pending, mine, applied by me, canonical type', v_n, 1);

    v := pg_temp.hr('LIST', c_tenant, c_school, c_admin, p_status => 'Pending');
    SELECT COUNT(*) INTO v_n FROM jsonb_array_elements(v) e WHERE (e->>'leave_id')::int = v_l1;
    PERFORM pg_temp.chk_eq('SS-B4 ...visible on HR Leave Management (Pending)', v_n, 1);

    CALL core.sp_dashboard_summary(c_tenant, c_school, c_admin, k, t, cl, m, df, rc, ap, ev, bd);
    v_n := 0;
    LOOP FETCH ap INTO r; EXIT WHEN NOT FOUND; IF r.leave_id = v_l1 THEN v_n := v_n + 1; END IF; END LOOP;
    CLOSE k; CLOSE t; CLOSE cl; CLOSE m; CLOSE df; CLOSE rc; CLOSE ap; CLOSE ev; CLOSE bd;
    PERFORM pg_temp.chk_eq('SS-B5 ...and in the dashboard Pending Approvals', v_n, 1);

    BEGIN
        v := pg_temp.ml('APPLY', c_tenant, c_school, u_me, NULL, 'Casual', DATE '2027-01-18', DATE '2027-01-18');
        PERFORM pg_temp.chk('SS-B6 13th casual day refused (cap 12, pending counts)', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('SS-B6 13th casual day refused (cap 12, pending counts)', SQLERRM LIKE '%Unpaid%', SQLERRM);
    END;

    v := pg_temp.ml('APPLY', c_tenant, c_school, u_me, NULL, 'Unpaid', DATE '2027-01-18', DATE '2027-01-18');
    PERFORM pg_temp.chk_eq('SS-B7 ...the same day as Unpaid is accepted', (v->0->>'days')::numeric, 1);

    BEGIN
        v := pg_temp.ml('APPLY', c_tenant, c_school, u_me, NULL, 'Sick', DATE '2027-01-15', DATE '2027-01-19');
        PERFORM pg_temp.chk('SS-B8 overlapping my own request refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('SS-B8 overlapping my own request refused', SQLERRM LIKE '%overlapping%', SQLERRM);
    END;

    v := pg_temp.ml('APPLY', c_tenant, c_school, u_me, NULL, 'Sick', DATE '2027-01-20', DATE '2027-01-20', TRUE);
    PERFORM pg_temp.chk_eq('SS-B9 half day counts 0.5', (v->0->>'days')::numeric, 0.5);

    BEGIN
        v := pg_temp.ml('APPLY', c_tenant, c_school, u_me, NULL, 'Sick', DATE '2027-01-24', DATE '2027-01-24');
        PERFORM pg_temp.chk('SS-B10 a Sunday alone (weekly off) refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('SS-B10 a Sunday alone (weekly off) refused', SQLERRM LIKE '%no working days%', SQLERRM);
    END;

    BEGIN
        v := pg_temp.ml('APPLY', c_tenant, c_school, u_me, NULL, 'LOP', DATE '2027-01-25', DATE '2027-01-25');
        PERFORM pg_temp.chk('SS-B11 unknown leave type refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('SS-B11 unknown leave type refused', TRUE, SQLERRM);
    END;

    BEGIN
        v := pg_temp.ml('APPLY', c_tenant, c_school, u_me, NULL, 'Sick', DATE '2024-12-30', DATE '2024-12-31');
        PERFORM pg_temp.chk('SS-B12 before my joining date refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('SS-B12 before my joining date refused', SQLERRM LIKE '%joining%', SQLERRM);
    END;

    -- My colleague's request goes to the colleague, whatever I do.
    v := pg_temp.ml('APPLY', c_tenant, c_school, u_col, NULL, 'Casual', DATE '2027-01-04', DATE '2027-01-05');
    v_lc := (v->0->>'leave_id')::int;
    SELECT staff_id INTO v_id FROM core.staff_leave WHERE leave_id = v_lc;
    PERFORM pg_temp.chk_eq('SS-B13 a colleague''s own request lands on the colleague', v_id, s_col);

    v := pg_temp.ml('LIST', c_tenant, c_school, u_me);
    SELECT COUNT(*) INTO v_n FROM jsonb_array_elements(v) e WHERE (e->>'leave_id')::int = v_lc;
    PERFORM pg_temp.chk_eq('SS-B14 my LIST never shows a colleague''s request', v_n, 0);
    PERFORM pg_temp.chk_eq('SS-B15 my LIST shows my 3 requests', jsonb_array_length(v), 3);
    PERFORM pg_temp.chk('SS-B16 LIST says who applied',
                        (SELECT bool_and(e->>'applied_by_name' = 'zz.self.me@local.test') FROM jsonb_array_elements(v) e),
                        v->0->>'applied_by_name');

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- C. Balance matches HR ---------------------------------';

    v  := pg_temp.ml('BALANCE', c_tenant, c_school, u_me, NULL, NULL, DATE '2027-03-01');
    v2 := pg_temp.hr('BALANCE', c_tenant, c_school, c_admin, NULL, s_me, NULL, DATE '2027-03-01');
    PERFORM pg_temp.chk('SS-C1 my balance = HR''s balance for me (every type, every figure)',
                        v = v2 AND jsonb_array_length(v) = 6, v::text);
    SELECT (e->>'remaining')::numeric INTO v_dec FROM jsonb_array_elements(v) e WHERE e->>'leave_type' = 'Casual';
    PERFORM pg_temp.chk_eq('SS-C2 Casual left in 2027 = 0 (12 pending)', v_dec, 0);
    SELECT (e->>'pending')::numeric INTO v_dec FROM jsonb_array_elements(v) e WHERE e->>'leave_type' = 'Sick';
    PERFORM pg_temp.chk_eq('SS-C3 Sick pending 0.5', v_dec, 0.5);

    -- No date = the current calendar year (same as HR's default).
    v := pg_temp.ml('BALANCE', c_tenant, c_school, u_me);
    PERFORM pg_temp.chk_eq('SS-C4 default year is this year',
                           (v->0->>'year')::int, EXTRACT(YEAR FROM CURRENT_DATE)::int);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- D. Cancel ---------------------------------------------';

    BEGIN
        v := pg_temp.ml('CANCEL', c_tenant, c_school, u_me, v_lc, NULL, NULL, NULL, FALSE, 'not mine');
        PERFORM pg_temp.chk('SS-D1 I cannot cancel a colleague''s request', FALSE, 'cancelled');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('SS-D1 I cannot cancel a colleague''s request', SQLERRM LIKE '%not found%', SQLERRM);
    END;
    SELECT status INTO v_txt FROM core.staff_leave WHERE leave_id = v_lc;
    PERFORM pg_temp.chk('SS-D1b ...it is still Pending', v_txt = 'Pending', v_txt);

    BEGIN
        v := pg_temp.ml('CANCEL', c_tenant, c_school, u_me, v_l1, NULL, NULL, NULL, FALSE, '   ');
        PERFORM pg_temp.chk('SS-D2 cancel needs a reason', FALSE, 'cancelled');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('SS-D2 cancel needs a reason', SQLERRM LIKE '%reason%', SQLERRM);
    END;

    v := pg_temp.ml('CANCEL', c_tenant, c_school, u_me, v_l1, NULL, NULL, NULL, FALSE, 'Function postponed');
    SELECT COUNT(*) INTO v_n FROM core.staff_leave
     WHERE leave_id = v_l1 AND status = 'Cancelled' AND cancelled_by = u_me
       AND cancel_reason = 'Function postponed' AND cancelled_at IS NOT NULL;
    PERFORM pg_temp.chk_eq('SS-D3 I cancel my own pending request (who/when/why kept)', v_n, 1);

    BEGIN
        v := pg_temp.ml('CANCEL', c_tenant, c_school, u_me, v_l1, NULL, NULL, NULL, FALSE, 'again');
        PERFORM pg_temp.chk('SS-D4 a cancelled request cannot be cancelled again', FALSE, 'cancelled');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('SS-D4 a cancelled request cannot be cancelled again', TRUE, SQLERRM);
    END;

    -- Approved, starts in the future: cancellable; the approval stays on record.
    v := pg_temp.ml('APPLY', c_tenant, c_school, u_me, NULL, 'Earned', DATE '2027-02-08', DATE '2027-02-09');
    v_la := (v->0->>'leave_id')::int;
    v := pg_temp.hr('DECIDE', c_tenant, c_school, c_admin, v_la, p_status => 'Approved');

    -- Approved in a month whose salary is already paid: not cancellable.
    v := pg_temp.ml('APPLY', c_tenant, c_school, u_me, NULL, 'Earned', DATE '2027-03-08', DATE '2027-03-08');
    v_lp := (v->0->>'leave_id')::int;
    v := pg_temp.hr('DECIDE', c_tenant, c_school, c_admin, v_lp, p_status => 'Approved');
    INSERT INTO core.staff_payroll(tenant_id, school_id, staff_id, pay_month, pay_year, gross, net_pay,
                                   status, paid_at, paid_by, payment_mode, payment_reference,
                                   monthly_salary, working_days, paid_days)
    VALUES (c_tenant, c_school, s_me, 3, 2027, 27000, 27000, 'Paid', now(), c_admin, 'Cash', NULL, 27000, 26, 26);

    -- Approved, already started (recorded by HR for earlier this week): not cancellable.
    v := pg_temp.hr('APPLY', c_tenant, c_school, c_admin, NULL, s_me, 'Sick',
                    CURRENT_DATE - 3, CURRENT_DATE - 2);
    v_ls := (v->0->>'leave_id')::int;
    v := pg_temp.hr('DECIDE', c_tenant, c_school, c_admin, v_ls, p_status => 'Approved');

    v := pg_temp.ml('LIST', c_tenant, c_school, u_me);
    PERFORM pg_temp.chk('SS-D5 LIST offers cancel only where the rule allows',
        (SELECT bool_and((e->>'can_cancel')::boolean = ((e->>'leave_id')::int = v_la
                                                         OR e->>'status' = 'Pending'))
         FROM jsonb_array_elements(v) e),
        (SELECT string_agg((e->>'leave_id') || ':' || (e->>'status') || ':' || (e->>'can_cancel'), ' ')
         FROM jsonb_array_elements(v) e));
    SELECT COUNT(*) INTO v_n FROM jsonb_array_elements(v) e
     WHERE (e->>'leave_id')::int = v_ls AND e->>'decided_by_name' <> '';
    PERFORM pg_temp.chk_eq('SS-D5b LIST says who decided an HR-entered leave', v_n, 1);

    BEGIN
        v := pg_temp.ml('CANCEL', c_tenant, c_school, u_me, v_ls, NULL, NULL, NULL, FALSE, 'changed my mind');
        PERFORM pg_temp.chk('SS-D6 approved leave that already started: refused', FALSE, 'cancelled');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('SS-D6 approved leave that already started: refused', SQLERRM LIKE '%started%', SQLERRM);
    END;

    BEGIN
        v := pg_temp.ml('CANCEL', c_tenant, c_school, u_me, v_lp, NULL, NULL, NULL, FALSE, 'changed my mind');
        PERFORM pg_temp.chk('SS-D7 approved leave in a paid month: refused', FALSE, 'cancelled');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('SS-D7 approved leave in a paid month: refused', SQLERRM LIKE '%paid%', SQLERRM);
    END;

    v := pg_temp.ml('CANCEL', c_tenant, c_school, u_me, v_la, NULL, NULL, NULL, FALSE, 'Trip cancelled');
    SELECT COUNT(*) INTO v_n FROM core.staff_leave
     WHERE leave_id = v_la AND status = 'Cancelled' AND decided_by = c_admin AND decided_at IS NOT NULL;
    PERFORM pg_temp.chk_eq('SS-D8 approved future leave: cancelled, approval kept', v_n, 1);

    -- Another school cannot reach my request even with my user id.
    BEGIN
        v := pg_temp.ml('CANCEL', c_xt, c_xs, u_me, v_lp, NULL, NULL, NULL, FALSE, 'x');
        PERFORM pg_temp.chk('SS-D9 my request is not reachable from another school', FALSE, 'cancelled');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('SS-D9 my request is not reachable from another school', TRUE, SQLERRM);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- E. Inactive staff -------------------------------------';

    BEGIN
        v := pg_temp.ml('APPLY', c_tenant, c_school, u_ina, NULL, 'Casual', DATE '2026-09-01', DATE '2026-09-01');
        PERFORM pg_temp.chk('SS-E1 inactive staff cannot apply', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('SS-E1 inactive staff cannot apply', SQLERRM LIKE '%inactive%', SQLERRM);
    END;
    SELECT COUNT(*) INTO v_n FROM core.staff_leave WHERE staff_id = s_ina;
    PERFORM pg_temp.chk_eq('SS-E2 ...nothing was written', v_n, 0);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- F. Payslips -------------------------------------------';

    INSERT INTO core.staff_payroll(tenant_id, school_id, staff_id, pay_month, pay_year, gross, lop_days, lop_amount,
                                   net_pay, status, monthly_salary, working_days, paid_days)
    VALUES (c_tenant, c_school, s_me, 9, 2026, 27000, 1, 1000, 26000, 'Draft', 27000, 27, 27);
    INSERT INTO core.staff_payroll(tenant_id, school_id, staff_id, pay_month, pay_year, gross, net_pay,
                                   status, paid_at, paid_by, payment_mode, payment_reference,
                                   monthly_salary, working_days, paid_days)
    VALUES (c_tenant, c_school, s_me, 8, 2026, 27000, 27000, 'Paid', now(), c_admin, 'Bank Transfer', 'UTR-ZZ-SECRET', 27000, 26, 26)
    RETURNING payroll_id INTO p_p;
    INSERT INTO core.staff_payroll(tenant_id, school_id, staff_id, pay_month, pay_year, gross, net_pay,
                                   status, paid_at, paid_by, payment_mode, payment_reference,
                                   monthly_salary, working_days, paid_days)
    VALUES (c_tenant, c_school, s_col, 8, 2026, 54000, 54000, 'Paid', now(), c_admin, 'Bank Transfer', 'UTR-ZZ-COL', 54000, 26, 26)
    RETURNING payroll_id INTO p_col;
    INSERT INTO core.staff_payroll(tenant_id, school_id, staff_id, pay_month, pay_year, gross, net_pay,
                                   status, paid_at, paid_by, payment_mode, payment_reference,
                                   monthly_salary, working_days, paid_days)
    VALUES (c_xt, c_xs, s_x, 8, 2026, 40000, 40000, 'Paid', now(), 38, 'Cash', NULL, 40000, 26, 26)
    RETURNING payroll_id INTO p_x;

    v := pg_temp.mp('LIST', c_tenant, c_school, u_me);
    PERFORM pg_temp.chk_eq('SS-F1 my LIST: my 3 payslips', jsonb_array_length(v), 3);
    PERFORM pg_temp.chk('SS-F2 ...newest first, Draft / Paid status',
                        (v->0->>'pay_year') = '2027' AND (v->1->>'status') = 'Draft' AND (v->2->>'status') = 'Paid',
                        v::text);
    PERFORM pg_temp.chk('SS-F3 ...no colleague''s or other school''s slip',
                        NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) e
                                    WHERE (e->>'payroll_id')::int IN (p_col, p_x)), '');
    PERFORM pg_temp.chk('SS-F4 ...no payment reference / payer returned',
                        NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) e
                                    WHERE e ? 'payment_reference' OR e ? 'paid_by'
                                       OR e::text LIKE '%UTR-ZZ%'), '');
    PERFORM pg_temp.chk('SS-F5 ...the mode is shown',
                        EXISTS (SELECT 1 FROM jsonb_array_elements(v) e
                                WHERE (e->>'payroll_id')::int = p_p AND e->>'payment_mode' = 'Bank Transfer'), '');

    v := pg_temp.mp('GET', c_tenant, c_school, u_me, p_p);
    PERFORM pg_temp.chk('SS-F6 GET my own payslip',
                        jsonb_array_length(v) = 1 AND (v->0->>'net_pay')::numeric = 27000
                        AND v->0->>'full_name' = 'ZZ Self Me' AND COALESCE(v->0->>'school_name', '') <> '',
                        v::text);
    v := pg_temp.mp('GET', c_tenant, c_school, u_me, p_col);
    PERFORM pg_temp.chk_eq('SS-F7 GET a colleague''s payslip id: nothing', jsonb_array_length(v), 0);
    v := pg_temp.mp('GET', c_tenant, c_school, u_me, p_x);
    PERFORM pg_temp.chk_eq('SS-F8 GET another school''s payslip id: nothing', jsonb_array_length(v), 0);
    v := pg_temp.mp('GET', c_xt, c_xs, u_me, p_x);
    PERFORM pg_temp.chk_eq('SS-F9 my user under another school''s scope: nothing', jsonb_array_length(v), 0);
    v := pg_temp.mp('GET', c_tenant, c_school, u_x, p_p);
    PERFORM pg_temp.chk_eq('SS-F10 other school''s staff under our scope: nothing', jsonb_array_length(v), 0);
    v := pg_temp.mp('LIST', c_xt, c_xs, u_x);
    PERFORM pg_temp.chk('SS-F11 other school''s staff sees only their own slip',
                        jsonb_array_length(v) = 1 AND (v->0->>'payroll_id')::int = p_x, v::text);
    v := pg_temp.mp('LIST', c_tenant, c_school, u_col);
    PERFORM pg_temp.chk('SS-F12 colleague sees only their own slip',
                        jsonb_array_length(v) = 1 AND (v->0->>'payroll_id')::int = p_col, v::text);
    v := pg_temp.mp('GET', c_tenant, c_school, c_admin, p_p);
    PERFORM pg_temp.chk_eq('SS-F13 the admin (no staff record) gets nothing here', jsonb_array_length(v), 0);

    -- A deleted staff row is no longer "me".
    UPDATE core.staff SET is_deleted = TRUE WHERE staff_id = s_col;
    v := pg_temp.mp('LIST', c_tenant, c_school, u_col);
    PERFORM pg_temp.chk_eq('SS-F14 deleted staff row: no payslips', jsonb_array_length(v), 0);
    UPDATE core.staff SET is_deleted = FALSE WHERE staff_id = s_col;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- G. Scope ----------------------------------------------';

    BEGIN
        v := pg_temp.ml('LIST', 1, 0, u_me);
        PERFORM pg_temp.chk('SS-G1 platform scope refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('SS-G1 platform scope refused', TRUE, SQLERRM);
    END;
    BEGIN
        v := pg_temp.mp('LIST', 1, 0, u_me);
        PERFORM pg_temp.chk('SS-G2 platform scope refused (payslips)', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('SS-G2 platform scope refused (payslips)', TRUE, SQLERRM);
    END;
    v := pg_temp.ml('LIST', c_xt, c_xs, u_me);
    PERFORM pg_temp.chk_eq('SS-G3 my user under another school sees no leave', jsonb_array_length(v), 0);

    SELECT COUNT(*) INTO v_n FROM core.staff_leave WHERE tenant_id = c_xt;
    PERFORM pg_temp.chk_eq('SS-G4 nothing leaked into school 23/33', v_n, v_before_x);
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
