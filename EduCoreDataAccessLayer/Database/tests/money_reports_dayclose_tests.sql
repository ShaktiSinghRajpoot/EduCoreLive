-- ============================================================================
-- Money reports + Day Close test suite.
--
-- Every other money suite proves the LEDGER is right. This one proves that the
-- SCREENS that read it tell the same story: Day Close, the Collection Register,
-- the Refund register, the Concession & Cancellation register, Defaulters, the
-- Fee Due / Reminders list, and the Dashboard money tiles.
--
-- One working day is built from scratch inside the transaction -- collections in
-- several tenders, a part payment, an overpayment into the wallet, a payment
-- from the wallet, a cancel, two refunds, a concession, a registration fee, a fee
-- taken at admission, a second cashier, and one receipt dated yesterday -- and
-- then every figure on every screen is compared with every other figure that
-- must equal it.
--
-- The rules these checks hold the app to (fee_day_close.sql):
--   * money is read from the TENDERS (core.fn_fee_money_lines), never the
--     receipt header, so cash in the drawer is the cash that was handed over;
--   * a cancellation counts on the day it was CANCELLED, so a closed day never
--     changes afterwards;
--   * a closed day is locked (core.fn_fee_day_closed); a re-open needs a reason
--     and every close / re-open is kept;
--   * "outstanding" is what has FALLEN DUE, one rule for Defaulters, the Fee Due
--     list and the Dashboard, including for students who have left.
--
-- First run (2026-10-10) found 31 bugs here; they are fixed and these checks now
-- assert the corrected behaviour.
--
-- Runs inside ONE transaction and ROLLS BACK.
--
--     psql ... -f money_reports_dayclose_tests.sql
--
-- COVERS
--   A. Fixture and the day's money movements
--   B. Day Close (per cashier) -- totals, tenders, cash expected
--   C. Collection register, refund register, concession & cancel register
--   D. Dashboard money tiles
--   E. Defaulters / Fee Due list -- fallen due, paid-up, exited
--   F. Reminders -- logged who / when / what
--   G. A closed day is locked; cancel counts on the cancel day; re-open
--   H. Day boundary on the school's clock
--   I. Scope -- tenant isolation and platform tenant
--   J. Things that only show up with more data
-- ============================================================================

\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE TEMP TABLE _t(id serial, name text, ok boolean, detail text) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.chk(p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO _t(name, ok, detail) VALUES (p_name, COALESCE(p_ok, FALSE), p_detail);
    RAISE NOTICE '  [%] %  %', CASE WHEN COALESCE(p_ok, FALSE) THEN 'PASS' ELSE 'FAIL' END, rpad(p_name, 62), p_detail;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.chk_eq(p_name text, p_got numeric, p_want numeric)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.chk(p_name, ROUND(p_got, 2) IS NOT DISTINCT FROM ROUND(p_want, 2),
                        format('got %s, expected %s', COALESCE(p_got::text,'NULL'), p_want));
END $$;

-- ── Readers: call a report proc exactly as the service does, FETCH every
--    cursor, and hand back jsonb. A refcursor proc does nothing until it is
--    read, so every helper reads every row.
CREATE OR REPLACE FUNCTION pg_temp.rows(p_cur refcursor)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r record; a jsonb := '[]'::jsonb;
BEGIN
    LOOP
        FETCH p_cur INTO r;
        EXIT WHEN NOT FOUND;
        a := a || jsonb_build_array(to_jsonb(r));
    END LOOP;
    CLOSE p_cur;
    RETURN a;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.j_day(t int, s int, u int, d date)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := 'jd_sum'; c2 refcursor := 'jd_modes'; c3 refcursor := 'jd_hist'; sm jsonb; md jsonb;
BEGIN
    CALL core.sp_fee_day_collection_get(t, s, u, d, c1, c2, c3);
    sm := pg_temp.rows(c1) -> 0;
    md := pg_temp.rows(c2);
    RETURN sm || jsonb_build_object('modes', md, 'history', pg_temp.rows(c3));
END $$;

CREATE OR REPLACE FUNCTION pg_temp.j_reg(t int, s int, u int, f date, tt date, cls text DEFAULT NULL, sec text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := 'jr_r'; c2 refcursor := 'jr_m'; c3 refcursor := 'jr_h'; a jsonb; b jsonb; h jsonb;
BEGIN
    CALL core.sp_fee_collection_register(t, s, u, f, tt, cls, sec, c1, c2, c3);
    a := pg_temp.rows(c1); b := pg_temp.rows(c2); h := pg_temp.rows(c3);
    RETURN jsonb_build_object('receipts', a, 'modes', b, 'heads', h,
        'total', (SELECT COALESCE(SUM((e->>'amount')::numeric),0) FROM jsonb_array_elements(a) e));
END $$;

CREATE OR REPLACE FUNCTION pg_temp.j_refunds(t int, s int, u int, f date, tt date)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := 'jf_r'; c2 refcursor := 'jf_m'; a jsonb; b jsonb;
BEGIN
    CALL core.sp_fee_refund_register(t, s, u, f, tt, c1, c2);
    a := pg_temp.rows(c1); b := pg_temp.rows(c2);
    RETURN jsonb_build_object('rows', a, 'modes', b,
        'total', (SELECT COALESCE(SUM((e->>'amount')::numeric),0) FROM jsonb_array_elements(a) e));
END $$;

CREATE OR REPLACE FUNCTION pg_temp.j_cc(t int, s int, u int, f date, tt date)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := 'jc_c'; c2 refcursor := 'jc_x'; a jsonb; b jsonb;
BEGIN
    CALL core.sp_fee_concession_cancel_register(t, s, u, f, tt, c1, c2);
    a := pg_temp.rows(c1); b := pg_temp.rows(c2);
    RETURN jsonb_build_object('conc', a, 'canc', b);
END $$;

CREATE OR REPLACE FUNCTION pg_temp.j_def(t int, s int, u int, cls text, sec text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := 'jdf';
BEGIN
    CALL core.sp_fee_defaulters_get(t, s, u, cls, sec, c1);
    RETURN pg_temp.rows(c1);
END $$;

CREATE OR REPLACE FUNCTION pg_temp.j_due(t int, s int, u int, srch text, cls text, bucket text,
                                         pg int, sz int, col text, dir text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := 'jdu';
BEGIN
    CALL core.sp_fee_due_list(t, s, u, srch, cls, bucket, pg, sz, col, dir, c1);
    RETURN pg_temp.rows(c1);
END $$;

CREATE OR REPLACE FUNCTION pg_temp.j_dash(t int, s int, u int)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE k refcursor := 'jb_k'; tr refcursor := 'jb_t'; cl refcursor := 'jb_c'; md refcursor := 'jb_m';
        df refcursor := 'jb_d'; rc refcursor := 'jb_r'; ap refcursor := 'jb_a'; ev refcursor := 'jb_e';
        bd refcursor := 'jb_b'; j jsonb;
BEGIN
    CALL core.sp_dashboard_summary(t, s, u, k, tr, cl, md, df, rc, ap, ev, bd);
    j := jsonb_build_object('kpi', pg_temp.rows(k) -> 0, 'trend', pg_temp.rows(tr),
                            'classes', pg_temp.rows(cl), 'modes', pg_temp.rows(md),
                            'defaulters', pg_temp.rows(df), 'recent', pg_temp.rows(rc));
    PERFORM pg_temp.rows(ap); PERFORM pg_temp.rows(ev); PERFORM pg_temp.rows(bd);
    RETURN j;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.j_rem(t int, s int, u int, take int)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := 'jm_r'; c2 refcursor := 'jm_s'; a jsonb;
BEGIN
    CALL core.sp_fee_reminder_history(t, s, u, take, c1, c2);
    a := pg_temp.rows(c1);
    RETURN jsonb_build_object('rows', a, 'stats', pg_temp.rows(c2) -> 0);
END $$;

-- Sum of a numeric field over a jsonb array, optionally only where key = value.
CREATE OR REPLACE FUNCTION pg_temp.jsum(a jsonb, fld text, k text DEFAULT NULL, v text DEFAULT NULL)
RETURNS numeric LANGUAGE sql AS $$
    SELECT COALESCE(SUM((e->>fld)::numeric), 0) FROM jsonb_array_elements(COALESCE(a,'[]'::jsonb)) e
    WHERE k IS NULL OR e->>k = v
$$;

-- Number of elements whose key = value.
CREATE OR REPLACE FUNCTION pg_temp.jcount(a jsonb, k text, v text)
RETURNS integer LANGUAGE sql AS $$
    SELECT COUNT(*)::int FROM jsonb_array_elements(COALESCE(a,'[]'::jsonb)) e WHERE e->>k = v
$$;

-- The one element of an array whose key = value (and optionally k2 = v2).
CREATE OR REPLACE FUNCTION pg_temp.jfind(a jsonb, k text, v text, k2 text DEFAULT NULL, v2 text DEFAULT NULL)
RETURNS jsonb LANGUAGE sql AS $$
    SELECT e FROM jsonb_array_elements(COALESCE(a,'[]'::jsonb)) e
    WHERE e->>k = v AND (k2 IS NULL OR e->>k2 = v2) LIMIT 1
$$;

-- Collect through the real engine. Returns the receipt number.
CREATE OR REPLACE FUNCTION pg_temp.collect(u int, sid int, items jsonb, tenders jsonb,
                                           adv numeric DEFAULT 0, pdate date DEFAULT NULL,
                                           dtype text DEFAULT NULL, dval numeric DEFAULT 0, dreason text DEFAULT NULL)
RETURNS varchar LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'jcol'; r record;
BEGIN
    CALL core.sp_fee_payment_collect(24, 34, u, sid, items, '[]'::jsonb, 'Cash', NULL, NULL,
         pdate, NULL, dtype, dval, dreason, tenders, adv, c);
    FETCH c INTO r; CLOSE c;
    RETURN r.receipt_no;
END $$;

-- Cancel through the real proc. Returns success (a refusal by RAISE is FALSE).
CREATE OR REPLACE FUNCTION pg_temp.cancel(u int, rcpt varchar, why text)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'jcan'; r record;
BEGIN
    CALL core.sp_fee_receipt_cancel(24, 34, u, rcpt, why, 'Principal', c);
    FETCH c INTO r; CLOSE c;
    RETURN CASE WHEN COALESCE(r.success, FALSE) THEN 'ok' ELSE 'refused: ' || COALESCE(r.message, '') END;
EXCEPTION WHEN OTHERS THEN
    RETURN 'refused: ' || SQLERRM;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.lid(sid int, head text, lbl text DEFAULT NULL)
RETURNS int LANGUAGE sql AS $$
    SELECT ledger_id FROM core.student_ledger
    WHERE student_id = sid AND fee_head_name = head AND (lbl IS NULL OR installment_label = lbl)
    ORDER BY due_date, ledger_id LIMIT 1
$$;

-- What a student really owes, straight off the ledger. only_due = what has
-- fallen due (no date counts as due), which is what every screen reports.
CREATE OR REPLACE FUNCTION pg_temp.owed(sid int, only_due boolean DEFAULT FALSE)
RETURNS numeric LANGUAGE sql AS $$
    SELECT COALESCE(SUM(amount_due - amount_paid - COALESCE(concession,0)), 0)
    FROM core.student_ledger
    WHERE student_id = sid AND amount_due > amount_paid + COALESCE(concession,0)
      AND (NOT only_due OR due_date IS NULL OR due_date::date <= CURRENT_DATE)
$$;


DO $suite$
DECLARE
    c_tenant CONSTANT integer := 24;
    c_school CONSTANT integer := 34;
    c_user   CONSTANT integer := 39;        -- cashier A
    c_user2  CONSTANT integer := 990039;    -- cashier B (same school, own drawer)
    c_today  CONSTANT date    := CURRENT_DATE;
    c_yday   CONSTANT date    := CURRENT_DATE - 1;

    v_year varchar; v_yearid integer; v_start date; v_cls varchar; v_sec varchar; v_sec2 varchar;
    s1 int; s2 int; s3 int; s4 int; s5 int; s6 int; e1 int;
    m1 varchar; m2 varchar; m3 varchar; m4 varchar; m5 varchar; m6 varchar; m7 varchar;
    m8 varchar; m9 varchar; m10 varchar; m11 varchar; m12 varchar; m13 varchar; m14 varchar;

    c refcursor; r record;
    v_n int; v_dec numeric; v_dec2 numeric; v_txt text; v_ok boolean;
    j jsonb; j2 jsonb; j3 jsonb; e jsonb;

    -- baselines, so the suite is right on a database that already has money
    b_reg_today numeric; b_reg_yday numeric; b_dash_today numeric; b_dash_yday numeric;
    b_refund_today numeric; b_a_total numeric; b_a_cnt int; b_a_canc int; b_b_total numeric;
    b_a_cash numeric; b_rem_today int;

    v_true_cash numeric; v_a_total numeric; v_a_name text; v_reghead text;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '========= MONEY REPORTS + DAY CLOSE TESTS =========';

    SELECT academic_year_id, academic_year_name, start_date INTO v_yearid, v_year, v_start
    FROM academic.academic_years
    WHERE tenant_id = c_tenant AND school_id = c_school AND COALESCE(is_current, FALSE)
      AND COALESCE(is_deleted, FALSE) = FALSE LIMIT 1;

    SELECT ac.class_name INTO v_cls
    FROM academic.academic_classes ac
    WHERE ac.tenant_id = c_tenant AND ac.school_id = c_school AND ac.academic_year_id = v_yearid
      AND COALESCE(ac.is_deleted, FALSE) = FALSE
      AND (SELECT COUNT(*) FROM academic.academic_class_sections x
            WHERE x.academic_class_id = ac.academic_class_id AND COALESCE(x.is_deleted,FALSE) = FALSE) >= 2
    ORDER BY ac.display_order LIMIT 1;

    SELECT MIN(section_name), MAX(section_name) INTO v_sec, v_sec2
    FROM academic.academic_class_sections x
    JOIN academic.academic_classes ac ON ac.academic_class_id = x.academic_class_id
    WHERE ac.tenant_id = c_tenant AND ac.school_id = c_school AND ac.academic_year_id = v_yearid
      AND ac.class_name = v_cls AND COALESCE(x.is_deleted, FALSE) = FALSE;

    IF v_year IS NULL OR v_cls IS NULL OR v_sec = v_sec2 THEN
        RAISE EXCEPTION 'Fixture missing: school % needs a current session and a class with two sections.', c_school;
    END IF;
    v_a_name  := core.fn_user_display_name(c_user);
    v_reghead := core.fn_registration_fee_head_name(c_tenant, c_school);
    RAISE NOTICE 'fixture: session=% (from %)  class=%  sections=%/%  today=%', v_year, v_start, v_cls, v_sec, v_sec2, c_today;

    -- Baselines BEFORE anything is created.
    j := pg_temp.j_reg(c_tenant, c_school, c_user, c_today, c_today);  b_reg_today := (j->>'total')::numeric;
    j := pg_temp.j_reg(c_tenant, c_school, c_user, c_yday,  c_yday);   b_reg_yday  := (j->>'total')::numeric;
    j := pg_temp.j_refunds(c_tenant, c_school, c_user, c_today, c_today); b_refund_today := (j->>'total')::numeric;
    j := pg_temp.j_day(c_tenant, c_school, c_user, c_today);
    b_a_total := (j->>'total_collected')::numeric; b_a_cnt := (j->>'receipt_count')::int;
    b_a_canc := (j->>'cancelled_count')::int; b_a_cash := (j->>'cash_collected')::numeric;
    j := pg_temp.j_day(c_tenant, c_school, c_user2, c_today);          b_b_total := (j->>'total_collected')::numeric;
    j := pg_temp.j_dash(c_tenant, c_school, c_user);
    b_dash_today := (j->'kpi'->>'today_collection')::numeric;
    b_dash_yday  := (j->'kpi'->>'yesterday_collection')::numeric;
    j := pg_temp.j_rem(c_tenant, c_school, c_user, 10); b_rem_today := (j->'stats'->>'sent_today')::int;

    IF core.fn_fee_day_closed(c_tenant, c_school, c_user, c_today)
       OR core.fn_fee_day_closed(c_tenant, c_school, c_user, c_yday) THEN
        RAISE EXCEPTION 'Fixture: cashier % already has today or yesterday closed in school %.', c_user, c_school;
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- A. Fixture: six students and one working day --------------';

    -- Admitted at session start: monthly rows Apr..Mar, one-time rows due on day one.
    c := 'fa1';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-MRD-1', NULL, 'ZZ MRD One', 'Male', DATE '2015-01-01', v_cls, v_sec, v_year, v_start,
         p_fee_plan_json => jsonb_build_array(
             jsonb_build_object('feeHeadName','ZZ MR Tuition',  'frequency','Monthly', 'amount',1000),
             jsonb_build_object('feeHeadName','ZZ MR Admission','frequency','One Time','amount',5000)),
         p_result => c);
    c := 'fa2';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-MRD-2', NULL, 'ZZ MRD Two', 'Female', DATE '2015-01-02', v_cls, v_sec, v_year, v_start,
         p_fee_plan_json => jsonb_build_array(
             jsonb_build_object('feeHeadName','ZZ MR Tuition',  'frequency','Monthly', 'amount',1000),
             jsonb_build_object('feeHeadName','ZZ MR Admission','frequency','One Time','amount',5000)),
         p_result => c);
    c := 'fa3';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-MRD-3', NULL, 'ZZ MRD Three', 'Male', DATE '2015-01-03', v_cls, v_sec2, v_year, v_start,
         p_fee_plan_json => jsonb_build_array(
             jsonb_build_object('feeHeadName','ZZ MR Tuition','frequency','Monthly', 'amount',1000),
             jsonb_build_object('feeHeadName','ZZ MR Deposit','frequency','One Time','amount',2000)),
         p_result => c);
    c := 'fa4';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-MRD-4', NULL, 'ZZ MRD Four', 'Female', DATE '2015-01-04', v_cls, v_sec, v_year, v_start,
         p_fee_plan_json => jsonb_build_array(
             jsonb_build_object('feeHeadName','ZZ MR Admission','frequency','One Time','amount',3000)),
         p_result => c);
    c := 'fa5';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-MRD-5', NULL, 'ZZ MRD Five', 'Male', DATE '2015-01-05', v_cls, v_sec, v_year, v_start,
         p_fee_plan_json => jsonb_build_array(
             jsonb_build_object('feeHeadName','ZZ MR Tuition','frequency','Monthly','amount',1000)),
         p_result => c);
    c := 'fa6';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-MRD-6', NULL, 'ZZ MRD Six', 'Female', DATE '2015-01-06', v_cls, v_sec, v_year, v_start,
         p_fee_plan_json => jsonb_build_array(
             jsonb_build_object('feeHeadName','ZZ MR Tuition','frequency','Monthly','amount',1000)),
         p_result => c);

    SELECT student_id INTO s1 FROM core.students WHERE tenant_id = c_tenant AND school_id = c_school AND admission_no = 'ZZ-MRD-1';
    SELECT student_id INTO s2 FROM core.students WHERE tenant_id = c_tenant AND school_id = c_school AND admission_no = 'ZZ-MRD-2';
    SELECT student_id INTO s3 FROM core.students WHERE tenant_id = c_tenant AND school_id = c_school AND admission_no = 'ZZ-MRD-3';
    SELECT student_id INTO s4 FROM core.students WHERE tenant_id = c_tenant AND school_id = c_school AND admission_no = 'ZZ-MRD-4';
    SELECT student_id INTO s5 FROM core.students WHERE tenant_id = c_tenant AND school_id = c_school AND admission_no = 'ZZ-MRD-5';
    SELECT student_id INTO s6 FROM core.students WHERE tenant_id = c_tenant AND school_id = c_school AND admission_no = 'ZZ-MRD-6';
    PERFORM pg_temp.chk('A1 six fixture students admitted',
        s1 IS NOT NULL AND s2 IS NOT NULL AND s3 IS NOT NULL AND s4 IS NOT NULL AND s5 IS NOT NULL AND s6 IS NOT NULL,
        format('%s %s %s %s %s %s', s1, s2, s3, s4, s5, s6));

    -- M12 + M14 first: cashier A, dated YESTERDAY: Jun and Jul 1000 Cash each
    -- (used by the lock tests: B cancels one, A tries to cancel the other).
    m12 := pg_temp.collect(c_user, s1, jsonb_build_array(jsonb_build_object('ledgerId', pg_temp.lid(s1,'ZZ MR Tuition','Jun 2026'), 'amount', 1000, 'concession', 0)),
                           jsonb_build_array(jsonb_build_object('mode','Cash','amount',1000)), 0, c_yday);
    m14 := pg_temp.collect(c_user, s1, jsonb_build_array(jsonb_build_object('ledgerId', pg_temp.lid(s1,'ZZ MR Tuition','Jul 2026'), 'amount', 1000, 'concession', 0)),
                           jsonb_build_array(jsonb_build_object('mode','Cash','amount',1000)), 0, c_yday);
    -- M1  fee taken at admission: 5000 Cash against the admission charge.
    m1 := pg_temp.collect(c_user, s1, jsonb_build_array(jsonb_build_object('ledgerId', pg_temp.lid(s1,'ZZ MR Admission'), 'amount', 5000, 'concession', 0)),
                          jsonb_build_array(jsonb_build_object('mode','Cash','amount',5000)));
    -- M2  split tender: Apr+May tuition 2000 = 1200 Cash + 800 UPI.
    m2 := pg_temp.collect(c_user, s1, jsonb_build_array(
                              jsonb_build_object('ledgerId', pg_temp.lid(s1,'ZZ MR Tuition','Apr 2026'), 'amount', 1000, 'concession', 0),
                              jsonb_build_object('ledgerId', pg_temp.lid(s1,'ZZ MR Tuition','May 2026'), 'amount', 1000, 'concession', 0)),
                          jsonb_build_array(jsonb_build_object('mode','Cash','amount',1200), jsonb_build_object('mode','UPI','amount',800)));
    -- M3  part payment + concession: admission 5000 -> 3000 Cheque, 500 concession, 1500 left.
    m3 := pg_temp.collect(c_user, s2, jsonb_build_array(jsonb_build_object('ledgerId', pg_temp.lid(s2,'ZZ MR Admission'), 'amount', 3000, 'concession', 500)),
                          jsonb_build_array(jsonb_build_object('mode','Cheque','amount',3000,'reference','CHQ-778899')),
                          0, NULL, 'Flat', 500, 'sibling discount');
    -- M4  overpayment: Apr 1000 paid with 1500 Cash -> 500 to the wallet.
    m4 := pg_temp.collect(c_user, s2, jsonb_build_array(jsonb_build_object('ledgerId', pg_temp.lid(s2,'ZZ MR Tuition','Apr 2026'), 'amount', 1000, 'concession', 0)),
                          jsonb_build_array(jsonb_build_object('mode','Cash','amount',1500)));
    -- M5  from the wallet: May 1000 = 700 Cash + 300 advance.
    m5 := pg_temp.collect(c_user, s2, jsonb_build_array(jsonb_build_object('ledgerId', pg_temp.lid(s2,'ZZ MR Tuition','May 2026'), 'amount', 1000, 'concession', 0)),
                          jsonb_build_array(jsonb_build_object('mode','Cash','amount',700)), 300);
    -- M6  cancelled the same day: Apr 1000 Cash.
    m6 := pg_temp.collect(c_user, s3, jsonb_build_array(jsonb_build_object('ledgerId', pg_temp.lid(s3,'ZZ MR Tuition','Apr 2026'), 'amount', 1000, 'concession', 0)),
                          jsonb_build_array(jsonb_build_object('mode','Cash','amount',1000)));
    v_txt := pg_temp.cancel(c_user, m6, 'collected from the wrong child');
    -- M7  deposit 2000 Cash, then 500 Cash + 200 UPI refunded.
    m7 := pg_temp.collect(c_user, s3, jsonb_build_array(jsonb_build_object('ledgerId', pg_temp.lid(s3,'ZZ MR Deposit'), 'amount', 2000, 'concession', 0)),
                          jsonb_build_array(jsonb_build_object('mode','Cash','amount',2000)));
    c := 'fr1';
    CALL core.sp_fee_refund_record(c_tenant, c_school, c_user, s3, pg_temp.lid(s3,'ZZ MR Deposit'), 500, 'Cash', 'part deposit returned', 'Accounts', c);
    c := 'fr2';
    CALL core.sp_fee_refund_record(c_tenant, c_school, c_user, s3, pg_temp.lid(s3,'ZZ MR Deposit'), 200, 'UPI', 'part deposit returned', 'Accounts', c);
    -- M8  registration fee on an enquiry (not admitted): fee 1000 = 900 Cash + 100 discount.
    c := 'fe1';
    CALL core.sp_enquiry_crm_manage(
         p_operation => 'SaveEnquiry', p_tenant_id => c_tenant, p_school_id => c_school,
         p_action_user_id => c_user, p_student_name => 'ZZ MRD Enquiry',
         p_gender => 'Male', p_dob => DATE '2016-06-06',
         p_class_name => v_cls, p_session => v_year, p_mobile => '9995551111',
         p_lead_source => 'Walk-in', p_status => 'New', p_result => c);
    SELECT enquiry_id INTO e1 FROM core.enquiries
     WHERE tenant_id = c_tenant AND school_id = c_school AND student_name = 'ZZ MRD Enquiry' ORDER BY enquiry_id DESC LIMIT 1;
    c := 'fe2';
    CALL core.sp_enquiry_register(p_tenant_id => c_tenant, p_school_id => c_school,
         p_action_user_id => c_user, p_enquiry_id => e1, p_auto_generate => TRUE, p_result => c);
    c := 'fe3';
    CALL core.sp_registration_fee_record(c_tenant, c_school, c_user, e1, 900, 'Cash', NULL, NULL, NULL, v_year,
         100, 'Flat', 'staff ward', 1000, c);
    FETCH c INTO r; m8 := r.receipt_no; CLOSE c;
    -- M9  cashier B: part of May 700 Cash.
    m9 := pg_temp.collect(c_user2, s3, jsonb_build_array(jsonb_build_object('ledgerId', pg_temp.lid(s3,'ZZ MR Tuition','May 2026'), 'amount', 700, 'concession', 0)),
                          jsonb_build_array(jsonb_build_object('mode','Cash','amount',700)));
    -- M10 S4 pays everything it owes (UPI 3000) -> paid up.
    m10 := pg_temp.collect(c_user, s4, jsonb_build_array(jsonb_build_object('ledgerId', pg_temp.lid(s4,'ZZ MR Admission'), 'amount', 3000, 'concession', 0)),
                           jsonb_build_array(jsonb_build_object('mode','UPI','amount',3000)));
    -- M11 S5 pays every instalment that has fallen due (Card) -> nothing overdue.
    SELECT jsonb_agg(jsonb_build_object('ledgerId', ledger_id, 'amount', amount_due, 'concession', 0)), SUM(amount_due)
      INTO j, v_dec
      FROM core.student_ledger WHERE student_id = s5 AND due_date::date <= c_today;
    m11 := pg_temp.collect(c_user, s5, j, jsonb_build_array(jsonb_build_object('mode','Card','amount',v_dec)));

    PERFORM pg_temp.chk('A2 every movement produced a receipt',
        m1 IS NOT NULL AND m2 IS NOT NULL AND m3 IS NOT NULL AND m4 IS NOT NULL AND m5 IS NOT NULL AND m6 IS NOT NULL
        AND m7 IS NOT NULL AND m8 IS NOT NULL AND m9 IS NOT NULL AND m10 IS NOT NULL AND m11 IS NOT NULL AND m12 IS NOT NULL
        AND m14 IS NOT NULL,
        format('%s .. %s', m12, m11));
    PERFORM pg_temp.chk('A2b same-day cancel of M6 accepted', v_txt = 'ok', v_txt);

    -- Independent truth, computed from the receipts themselves, not from a report.
    SELECT COALESCE(SUM(amount),0) INTO v_a_total FROM core.fee_payments
     WHERE tenant_id = c_tenant AND school_id = c_school AND created_by = c_user
       AND payment_date::date = c_today AND NOT is_cancelled;
    v_a_total := v_a_total - b_a_total;
    PERFORM pg_temp.chk_eq('A3 cashier A settled today (5000+2000+3000+1000+1000+2000+900+3000+S5)',
        v_a_total, 17900 + v_dec);

    SELECT COALESCE(SUM(v.amount),0) INTO v_true_cash FROM core.v_fee_tender_lines v
     WHERE v.tenant_id = c_tenant AND v.school_id = c_school AND v.created_by = c_user
       AND v.payment_date::date = c_today AND NOT v.is_cancelled AND v.mode = 'Cash';
    v_true_cash := v_true_cash - b_a_cash;
    -- 5000 + 1200 + 1500 + 700 + 2000 + 900 (registration, no tender row -> header) = 11300
    PERFORM pg_temp.chk_eq('A4 cash physically handed to cashier A today', v_true_cash, 11300);

    SELECT balance INTO v_dec2 FROM core.student_advance WHERE student_id = s2;
    PERFORM pg_temp.chk_eq('A5 S2 wallet = 500 credited - 300 used', v_dec2, 200);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- B. Day Close (one cashier''s drawer) ----------------------';

    j := pg_temp.j_day(c_tenant, c_school, c_user, c_today);
    PERFORM pg_temp.chk_eq('DC-01 A: Collected = sum of A''s live receipts today',
        (j->>'total_collected')::numeric - b_a_total, v_a_total);
    PERFORM pg_temp.chk_eq('DC-02 A: receipts issued today (M6 included)', (j->>'receipt_count')::int - b_a_cnt, 10);
    PERFORM pg_temp.chk_eq('DC-03 A: one cancellation made today (M6)', (j->>'cancelled_count')::int - b_a_canc, 1);
    PERFORM pg_temp.chk_eq('DC-03b A: ...worth 1000', (j->>'cancelled_amount')::numeric, 1000);
    PERFORM pg_temp.chk_eq('DC-04 A: refunds out = 500 + 200', (j->>'total_refunded')::numeric, 700);
    PERFORM pg_temp.chk_eq('DC-05 A: cash refunded = the Cash refund only', (j->>'cash_refunded')::numeric, 500);
    PERFORM pg_temp.chk_eq('DC-06 A: mode table sums to Collected',
        pg_temp.jsum(j->'modes','amount'), (j->>'total_collected')::numeric);

    j2 := pg_temp.j_day(c_tenant, c_school, c_user2, c_today);
    PERFORM pg_temp.chk_eq('DC-07 B sees only B''s own receipt', (j2->>'total_collected')::numeric - b_b_total, 700);
    j3 := pg_temp.j_reg(c_tenant, c_school, c_user, c_today, c_today);
    PERFORM pg_temp.chk_eq('DC-08 A + B drawers = school_collected on the page',
        (j->>'total_collected')::numeric + (j2->>'total_collected')::numeric, (j->>'school_collected')::numeric);
    PERFORM pg_temp.chk_eq('DC-09 school_collected = Collection Register total',
        (j->>'school_collected')::numeric, (j3->>'total')::numeric);

    -- The drawer: M2 put 1200 Cash in (UPI 800 elsewhere), M4 put 1500 in (500
    -- of it to the wallet), M5 put 700 in (300 came from the wallet).
    PERFORM pg_temp.chk_eq('DC-10 cash collected = cash actually tendered',
        (j->>'cash_collected')::numeric - b_a_cash, v_true_cash);
    PERFORM pg_temp.chk('DC-11 mode table is the true split (no "Mixed")',
        pg_temp.jfind(j->'modes','payment_mode','Mixed') IS NULL
          AND (pg_temp.jfind(j->'modes','payment_mode','UPI')->>'amount')::numeric >= 3800,
        format('modes: %s', (SELECT string_agg((x->>'payment_mode') || '=' || (x->>'amount'), ', ')
                             FROM jsonb_array_elements(j->'modes') x)));
    PERFORM pg_temp.chk_eq('DC-11b wallet lines: 300 used, 500 saved',
        COALESCE((pg_temp.jfind(j->'modes','payment_mode','Advance')->>'amount')::numeric, 0)
        + COALESCE((pg_temp.jfind(j->'modes','payment_mode','To wallet')->>'amount')::numeric, 0), -200);

    -- Close it with the RIGHT count: 11300 cash in - 500 cash out = 10800.
    c := 'dc_close';
    CALL core.sp_fee_day_close(c_tenant, c_school, c_user, c_today, 10800 + b_a_cash, 'end of shift', c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('DC-12 day close succeeds', COALESCE(r.success, FALSE), r.message);
    PERFORM pg_temp.chk_eq('DC-13 a correct cash count closes with difference 0', r.difference, 0);
    PERFORM pg_temp.chk('DC-13b the day now reads as closed (fn_fee_day_closed)',
        core.fn_fee_day_closed(c_tenant, c_school, c_user, c_today), '');

    SELECT * INTO r FROM core.fee_day_close
     WHERE tenant_id = c_tenant AND school_id = c_school AND cashier_id = c_user AND close_date = to_char(c_today,'YYYY-MM-DD');
    PERFORM pg_temp.chk_eq('DC-14 stored close: total collected = page total', r.total_collected, (j->>'total_collected')::numeric);
    PERFORM pg_temp.chk_eq('DC-15 stored close: total refunded', r.total_refunded, 700);
    PERFORM pg_temp.chk_eq('DC-16 stored close: mode breakup sums to total',
        (SELECT COALESCE(SUM((x->>'amount')::numeric),0) FROM jsonb_array_elements(r.mode_breakup) x), r.total_collected);
    PERFORM pg_temp.chk('DC-17 stored close records who and when',
        r.closed_by = c_user AND r.closed_at IS NOT NULL, format('closed_by %s at %s', r.closed_by, r.closed_at));
    j := pg_temp.j_day(c_tenant, c_school, c_user, c_today);
    PERFORM pg_temp.chk('DC-18 page reports the day as closed with the count',
        (j->>'is_closed')::boolean AND (j->>'counted_cash')::numeric = 10800 + b_a_cash,
        format('is_closed %s counted %s', j->>'is_closed', j->>'counted_cash'));
    PERFORM pg_temp.chk('DC-18b the close is in the history with who and the count',
        jsonb_array_length(j->'history') = 1 AND j->'history'->0->>'action' = 'Close'
          AND j->'history'->0->>'action_by_name' = v_a_name
          AND (j->'history'->0->>'counted_cash')::numeric = 10800 + b_a_cash,
        COALESCE((j->'history')::text, 'none'));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- C. Registers ----------------------------------------------';

    j := pg_temp.j_reg(c_tenant, c_school, c_user, c_today, c_today);
    PERFORM pg_temp.chk_eq('RPT-01 register: today''s total = A + B', (j->>'total')::numeric - b_reg_today, v_a_total + 700);
    SELECT COUNT(*) INTO v_n FROM jsonb_array_elements(j->'receipts') x
     WHERE x->>'entry' = 'Receipt' AND x->>'receipt_no' IN (m1,m2,m3,m4,m5,m6,m7,m8,m9,m10,m11);
    PERFORM pg_temp.chk_eq('RPT-02 register lists all eleven receipts issued today', v_n, 11);
    PERFORM pg_temp.chk('RPT-03 M6: a receipt (flagged cancelled) and a -1000 cancellation, net 0',
        (pg_temp.jfind(j->'receipts','receipt_no',m6,'entry','Receipt')->>'is_cancelled')::boolean
          AND (pg_temp.jfind(j->'receipts','receipt_no',m6,'entry','Cancellation')->>'amount')::numeric = -1000
          AND pg_temp.jsum(j->'receipts','amount','receipt_no',m6) = 0, '');
    PERFORM pg_temp.chk('RPT-04 yesterday''s M12 is not in today''s register',
        pg_temp.jfind(j->'receipts','receipt_no',m12) IS NULL, m12);
    PERFORM pg_temp.chk_eq('RPT-05 by-head panel sums to the receipts total',
        pg_temp.jsum(j->'heads','amount'), (j->>'total')::numeric);
    PERFORM pg_temp.chk_eq('RPT-06 by-mode panel sums to the receipts total',
        pg_temp.jsum(j->'modes','amount'), (j->>'total')::numeric);
    PERFORM pg_temp.chk('RPT-07 by-mode panel shows the true split, no "Mixed"',
        pg_temp.jfind(j->'modes','payment_mode','Mixed') IS NULL,
        format('Cash = %s', pg_temp.jfind(j->'modes','payment_mode','Cash')->>'amount'));
    -- Collected = what was settled; tenders = what crossed the counter. They differ
    -- by exactly the wallet movement, and that identity is what lets the books tie.
    SELECT COALESCE(SUM(v.amount),0) INTO v_dec FROM core.v_fee_tender_lines v
     WHERE v.tenant_id = c_tenant AND v.school_id = c_school AND v.payment_date::date = c_today
       AND NOT v.is_cancelled AND v.mode <> 'Advance';
    SELECT COALESCE(SUM(advance_credit - advance_used),0) INTO v_dec2 FROM core.fee_payments
     WHERE tenant_id = c_tenant AND school_id = c_school AND payment_date::date = c_today AND NOT is_cancelled;
    PERFORM pg_temp.chk_eq('RPT-08 register total + wallet credit - used = sum of tenders',
        (j->>'total')::numeric + v_dec2, v_dec);
    e := pg_temp.jfind(j->'receipts','receipt_no',m8);
    PERFORM pg_temp.chk('RPT-09 registration receipt: enquiry name, type, the school''s head name',
        e->>'student_name' = 'ZZ MRD Enquiry' AND e->>'payment_type' = 'Registration' AND e->>'fee_heads' = v_reghead,
        format('%s / %s / %s', e->>'student_name', e->>'payment_type', e->>'fee_heads'));
    PERFORM pg_temp.chk_eq('RPT-10 register discount column: M3 concession 500', (pg_temp.jfind(j->'receipts','receipt_no',m3)->>'discount_total')::numeric, 500);
    PERFORM pg_temp.chk_eq('RPT-11 register discount column: registration discount 100', (e->>'discount_total')::numeric, 100);
    PERFORM pg_temp.chk_eq('RPT-12 M5 (part wallet) shows the settled 1000', (pg_temp.jfind(j->'receipts','receipt_no',m5)->>'amount')::numeric, 1000);
    PERFORM pg_temp.chk('RPT-12b M2 shows its real split, not "Mixed"',
        pg_temp.jfind(j->'receipts','receipt_no',m2)->>'payment_mode' = 'Cash 1200.00 + UPI 800.00',
        pg_temp.jfind(j->'receipts','receipt_no',m2)->>'payment_mode');
    j2 := pg_temp.j_reg(c_tenant, c_school, c_user, c_today, c_today, v_cls, v_sec2);
    PERFORM pg_temp.chk('RPT-12c class+section filter: S3''s receipts only',
        pg_temp.jfind(j2->'receipts','receipt_no',m7) IS NOT NULL AND pg_temp.jfind(j2->'receipts','receipt_no',m1) IS NULL
          AND pg_temp.jfind(j2->'receipts','receipt_no',m8) IS NULL, format('%s line(s)', jsonb_array_length(j2->'receipts')));
    PERFORM pg_temp.chk_eq('RPT-12d filtered heads and modes still sum to the filtered total',
        pg_temp.jsum(j2->'heads','amount') + pg_temp.jsum(j2->'modes','amount'), 2 * (j2->>'total')::numeric);

    -- Refund register
    j2 := pg_temp.j_refunds(c_tenant, c_school, c_user, c_today, c_today);
    PERFORM pg_temp.chk_eq('RPT-13 refund register: today''s refunds 700', (j2->>'total')::numeric - b_refund_today, 700);
    SELECT COUNT(*) INTO v_n FROM jsonb_array_elements(j2->'rows') x
     WHERE x->>'student_name' = 'ZZ MRD Three' AND x->>'fee_head_name' = 'ZZ MR Deposit'
       AND x->>'reason' = 'part deposit returned' AND x->>'authorized_by' = 'Accounts' AND x->>'refund_no' LIKE 'RFD-%';
    PERFORM pg_temp.chk_eq('RPT-14 each refund names student, head, reason, authoriser', v_n, 2);
    PERFORM pg_temp.chk_eq('RPT-15 refund modes: Cash 500', pg_temp.jsum(j2->'modes','amount','refund_mode','Cash')
        - (SELECT COALESCE(SUM(amount),0) FROM core.fee_refunds WHERE tenant_id=c_tenant AND school_id=c_school
             AND refunded_at::date = c_today AND refund_mode='Cash' AND student_id <> s3), 500);
    PERFORM pg_temp.chk_eq('RPT-16 net = collected - refunded',
        ((j->>'total')::numeric - b_reg_today) - ((j2->>'total')::numeric - b_refund_today), v_a_total + 700 - 700);
    PERFORM pg_temp.chk_eq('RPT-17 the refund did not rewrite the deposit receipt',
        (pg_temp.jfind(j->'receipts','receipt_no',m7)->>'amount')::numeric, 2000);
    SELECT amount_paid - refund_amount INTO v_dec FROM core.student_ledger WHERE ledger_id = pg_temp.lid(s3,'ZZ MR Deposit');
    PERFORM pg_temp.chk_eq('RPT-18 school still holds 2000 - 700 of the deposit', v_dec, 1300);

    -- Concession & cancellation register
    j3 := pg_temp.j_cc(c_tenant, c_school, c_user, c_today, c_today);
    e := pg_temp.jfind(j3->'conc','receipt_no',m3);
    PERFORM pg_temp.chk('RPT-19 concession register lists M3 with type and reason',
        e IS NOT NULL AND (e->>'concession_amount')::numeric = 500 AND e->>'discount_type' = 'Flat' AND e->>'discount_reason' = 'sibling discount',
        COALESCE(e::text, 'absent'));
    e := pg_temp.jfind(j3->'conc','receipt_no',m8);
    PERFORM pg_temp.chk('RPT-20 concession register lists the registration discount (100)',
        e IS NOT NULL AND (e->>'concession_amount')::numeric = 100 AND e->>'payment_type' = 'Registration'
          AND e->>'discount_reason' = 'staff ward', COALESCE(e::text, 'absent'));
    e := pg_temp.jfind(j3->'canc','receipt_no',m6);
    PERFORM pg_temp.chk('RPT-21 cancel register: M6 with why, authoriser and when',
        e IS NOT NULL AND e->>'cancel_reason' = 'collected from the wrong child'
          AND e->>'cancel_authorized_by' = 'Principal' AND e->>'cancelled_at' IS NOT NULL
          AND (e->>'amount')::numeric = 1000,
        COALESCE(e::text, 'absent'));
    PERFORM pg_temp.chk('RPT-22 cancel register names the USER who cancelled and who collected',
        e->>'cancelled_by_name' = v_a_name AND e->>'collected_by_name' = v_a_name,
        format('%s / %s', e->>'cancelled_by_name', e->>'collected_by_name'));
    PERFORM pg_temp.chk('RPT-23 refund register names the USER who refunded',
        pg_temp.jfind(j2->'rows','student_name','ZZ MRD Three')->>'refunded_by_name' = v_a_name,
        pg_temp.jfind(j2->'rows','student_name','ZZ MRD Three')->>'refunded_by_name');
    PERFORM pg_temp.chk('RPT-24 concession register names the USER who gave it',
        pg_temp.jfind(j3->'conc','receipt_no',m3)->>'given_by_name' = v_a_name,
        pg_temp.jfind(j3->'conc','receipt_no',m3)->>'given_by_name');
    SELECT cancelled_by INTO v_n FROM core.fee_payments WHERE tenant_id = c_tenant AND school_id = c_school AND receipt_no = m6;
    PERFORM pg_temp.chk_eq('RPT-25 ...and the cancelling user id is stored', v_n, c_user);

    -- Date range: inclusive on both ends, and backwards is empty, not an error.
    j := pg_temp.j_reg(c_tenant, c_school, c_user, c_yday, c_today);
    PERFORM pg_temp.chk('RPT-26 range yesterday..today includes M12 and M1',
        pg_temp.jfind(j->'receipts','receipt_no',m12) IS NOT NULL AND pg_temp.jfind(j->'receipts','receipt_no',m1) IS NOT NULL, '');
    j := pg_temp.j_reg(c_tenant, c_school, c_user, c_yday, c_yday);
    PERFORM pg_temp.chk_eq('RPT-27 range yesterday..yesterday = only yesterday''s money',
        (j->>'total')::numeric - b_reg_yday, 2000);
    j := pg_temp.j_reg(c_tenant, c_school, c_user, c_today, c_yday);
    PERFORM pg_temp.chk_eq('RPT-28 from after to returns nothing', jsonb_array_length(j->'receipts'), 0);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- D. Dashboard money tiles ----------------------------------';

    j := pg_temp.j_dash(c_tenant, c_school, c_user);
    j2 := pg_temp.j_reg(c_tenant, c_school, c_user, c_today, c_today);
    PERFORM pg_temp.chk_eq('DASH-01 "Today''s Collection" = register today',
        (j->'kpi'->>'today_collection')::numeric - b_dash_today, (j2->>'total')::numeric - b_reg_today);
    PERFORM pg_temp.chk_eq('DASH-02 trend''s last bar = Today''s Collection',
        ((j->'trend'->-1)->>'amount')::numeric, (j->'kpi'->>'today_collection')::numeric);
    PERFORM pg_temp.chk_eq('DASH-03 "yesterday" = register yesterday',
        (j->'kpi'->>'yesterday_collection')::numeric - b_dash_yday, 2000);
    PERFORM pg_temp.chk('DASH-04 "Collection by mode" chart has no "Mixed" slice',
        pg_temp.jfind(j->'modes','mode','Mixed') IS NULL AND pg_temp.jfind(j->'modes','mode','UPI') IS NOT NULL, '');
    PERFORM pg_temp.chk('DASH-05 recent receipts include the registration receipt, named',
        pg_temp.jfind(j->'recent','receipt_no',m8)->>'student_name' = 'ZZ MRD Enquiry', '');
    e := pg_temp.jfind(j->'defaulters','student_id',s1::text);
    PERFORM pg_temp.chk_eq('DASH-06 "Highest outstanding": S1 due = ledger fallen due',
        (e->>'due')::numeric, pg_temp.owed(s1, TRUE));
    PERFORM pg_temp.chk_eq('DASH-07 "Highest outstanding": S1 paid = ledger paid',
        (e->>'paid')::numeric, (SELECT SUM(amount_paid) FROM core.student_ledger WHERE student_id = s1));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- E. Defaulters / Fee Due list ------------------------------';

    -- S6 leaves with Apr..today unpaid.
    c := 'ex6';
    CALL core.sp_student_exit('Exit', c_tenant, c_school, c_user, s6, 'Transfer', c_today, 'relocating', c);

    j  := pg_temp.j_def(c_tenant, c_school, c_user, NULL, NULL);
    j2 := pg_temp.j_due(c_tenant, c_school, c_user, NULL, NULL, NULL, 1, 1000, NULL, 'desc');

    v_ok := TRUE; v_txt := '';
    FOREACH v_n IN ARRAY ARRAY[s1, s2, s3] LOOP
        e := pg_temp.jfind(j,'student_id',v_n::text);
        IF e IS NULL OR ROUND((e->>'total_outstanding')::numeric,2) <> ROUND(pg_temp.owed(v_n, TRUE),2) THEN
            v_ok := FALSE; v_txt := v_txt || format('s%s def=%s ledger=%s; ', v_n, e->>'total_outstanding', pg_temp.owed(v_n, TRUE));
        END IF;
        e := pg_temp.jfind(j2,'student_id',v_n::text);
        IF e IS NULL OR ROUND((e->>'total_outstanding')::numeric,2) <> ROUND(pg_temp.owed(v_n, TRUE),2) THEN
            v_ok := FALSE; v_txt := v_txt || format('s%s due=%s ledger=%s; ', v_n, e->>'total_outstanding', pg_temp.owed(v_n, TRUE));
        END IF;
    END LOOP;
    PERFORM pg_temp.chk('DEF-01 defaulters and due list = ledger fallen due - paid - conc', v_ok, v_txt);

    PERFORM pg_temp.chk_eq('DEF-02 S2''s part-paid admission row still owes 1500',
        (SELECT amount_due - amount_paid - concession FROM core.student_ledger WHERE ledger_id = pg_temp.lid(s2,'ZZ MR Admission')), 1500);
    PERFORM pg_temp.chk_eq('DEF-03 S3: cancelled Apr is owed again; refunded deposit is not',
        (SELECT SUM(amount_due - amount_paid - concession) FROM core.student_ledger
          WHERE student_id = s3 AND (installment_label = 'Apr 2026' OR fee_head_name = 'ZZ MR Deposit')), 1000);

    v_ok := TRUE; v_txt := '';
    FOR e IN SELECT x FROM jsonb_array_elements(j) x WHERE (x->>'student_id')::int IN (s1,s2,s3,s6) LOOP
        IF ROUND((e->>'d0_30')::numeric + (e->>'d31_60')::numeric + (e->>'d60_plus')::numeric, 2)
           <> ROUND((e->>'total_outstanding')::numeric, 2)
           OR ROUND((e->>'not_due')::numeric, 2) <> ROUND(pg_temp.owed((e->>'student_id')::int) - pg_temp.owed((e->>'student_id')::int, TRUE), 2) THEN
            v_ok := FALSE; v_txt := v_txt || (e->>'student_name') || ' ';
        END IF;
    END LOOP;
    PERFORM pg_temp.chk('DEF-04 aging adds up to Outstanding; Not due = future instalments', v_ok, v_txt);

    PERFORM pg_temp.chk('DEF-05 paid-up S4 is on neither list',
        pg_temp.jfind(j,'student_id',s4::text) IS NULL AND pg_temp.jfind(j2,'student_id',s4::text) IS NULL, '');

    -- S5 has paid every instalment that has fallen due. Owing next month's fee
    -- in advance is not defaulting.
    SELECT COUNT(*) INTO v_n FROM core.student_ledger WHERE student_id = s5 AND due_date::date > c_today;
    PERFORM pg_temp.chk('DEF-06 up-to-date S5 is not listed as a defaulter',
        pg_temp.jfind(j,'student_id',s5::text) IS NULL,
        format('%s future instalment(s); listed: %s', v_n, pg_temp.jfind(j,'student_id',s5::text) IS NOT NULL));
    e := pg_temp.jfind(j2,'student_id',s5::text);
    PERFORM pg_temp.chk_eq('REM-01 reminder {due_amount} for S5 = what has fallen due (0, not listed)',
        COALESCE((e->>'total_outstanding')::numeric, 0), pg_temp.owed(s5, TRUE));
    e := pg_temp.jfind(j2,'student_id',s1::text);
    PERFORM pg_temp.chk_eq('REM-02 reminder {due_amount} for S1 excludes Nov..Mar',
        (e->>'total_outstanding')::numeric, pg_temp.owed(s1, TRUE));

    -- Exited S6: one rule on both lists.
    e := pg_temp.jfind(j,'student_id',s6::text);
    PERFORM pg_temp.chk('DEF-07 exited S6 with unpaid fees is on Defaulters, marked as left',
        e IS NOT NULL AND e->>'student_status' = 'Transfer', COALESCE(e->>'student_status', 'absent'));
    e := pg_temp.jfind(j2,'student_id',s6::text);
    PERFORM pg_temp.chk('DEF-08 ...and on the Fee Due / reminders list too',
        e IS NOT NULL AND e->>'student_status' = 'Transfer', COALESCE(e->>'student_status', 'absent'));
    PERFORM pg_temp.chk_eq('DEF-09 exited S6 is reported only for what fell due',
        (pg_temp.jfind(j,'student_id',s6::text)->>'total_outstanding')::numeric, pg_temp.owed(s6, TRUE));

    -- One school, three "outstanding" figures (student rows; registration
    -- balances are listed on Defaulters as their own rows, see DEF-20).
    j3 := pg_temp.j_dash(c_tenant, c_school, c_user);
    PERFORM pg_temp.chk_eq('DEF-10 dashboard Outstanding = Defaulters (students)',
        (j3->'kpi'->>'outstanding')::numeric, pg_temp.jsum(j,'total_outstanding','entry','Student'));
    PERFORM pg_temp.chk_eq('DEF-11 Fee Due list total = Defaulters (students)',
        COALESCE((j2->0->>'sum_outstanding')::numeric,0), pg_temp.jsum(j,'total_outstanding','entry','Student'));
    PERFORM pg_temp.chk_eq('DEF-12 dashboard "students pending" = Defaulters count',
        (j3->'kpi'->>'due_students')::int, pg_temp.jcount(j,'entry','Student'));
    PERFORM pg_temp.chk_eq('DEF-13 Fee Due list count = Defaulters count',
        COALESCE((j2->0->>'total_count')::int,0), pg_temp.jcount(j,'entry','Student'));
    PERFORM pg_temp.chk('DEF-13b dashboard "Highest outstanding" includes the exited debtor rule',
        NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j3->'defaulters') x
                    WHERE (x->>'due')::numeric <> COALESCE((pg_temp.jfind(j,'student_id',x->>'student_id')->>'total_outstanding')::numeric, -1)), '');

    -- Filters
    j3 := pg_temp.j_def(c_tenant, c_school, c_user, v_cls, NULL);
    PERFORM pg_temp.chk('DEF-14 class filter keeps the class',
        pg_temp.jfind(j3,'student_id',s1::text) IS NOT NULL AND pg_temp.jfind(j3,'student_id',s3::text) IS NOT NULL, '');
    j3 := pg_temp.j_def(c_tenant, c_school, c_user, 'ZZ No Such Class', NULL);
    PERFORM pg_temp.chk_eq('DEF-15 unknown class returns nobody', jsonb_array_length(j3), 0);
    j3 := pg_temp.j_def(c_tenant, c_school, c_user, v_cls, lower(v_sec2));
    PERFORM pg_temp.chk('DEF-16 section filter (any case): S3 in, S1 out',
        pg_temp.jfind(j3,'student_id',s3::text) IS NOT NULL AND pg_temp.jfind(j3,'student_id',s1::text) IS NULL, '');
    j3 := pg_temp.j_due(c_tenant, c_school, c_user, NULL, v_cls, NULL, 1, 1000, NULL, 'desc');
    PERFORM pg_temp.chk('DEF-17 due list class filter', pg_temp.jfind(j3,'student_id',s1::text) IS NOT NULL, '');
    j3 := pg_temp.j_due(c_tenant, c_school, c_user, 'ZZ-MRD-2', NULL, NULL, 1, 1000, NULL, 'desc');
    PERFORM pg_temp.chk('DEF-18 due list search by admission no finds only S2',
        jsonb_array_length(j3) = 1 AND (j3->0->>'student_id')::int = s2, format('%s row(s)', jsonb_array_length(j3)));
    j3 := pg_temp.j_due(c_tenant, c_school, c_user, NULL, NULL, '0-30', 1, 1000, NULL, 'desc');
    PERFORM pg_temp.chk('DEF-19 bucket filter: nobody in 0-30 has an older overdue',
        NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j3) x WHERE (x->>'overdue_days')::int > 30), '');

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- F. Reminders ----------------------------------------------';

    c := 'rm1';
    CALL core.sp_fee_reminder_record(c_tenant, c_school, c_user, s1, 'Email', 'Email', 'p1@zz.test', '9990001111',
         'Dear parent, ZZ MRD One owes 12000.', 12000, 'Sent', c);
    FETCH c INTO r; CLOSE c;
    SELECT * INTO r FROM core.fee_reminder_log WHERE reminder_id = r.reminder_id;
    PERFORM pg_temp.chk('REM-03 a sent reminder is logged: who, when, what, to whom, amount',
        r.sent_by = c_user AND r.sent_at::date = c_today AND r.message LIKE 'Dear parent%'
          AND r.to_email = 'p1@zz.test' AND r.outstanding = 12000 AND r.status = 'Sent' AND r.channels_delivered = 'Email',
        format('by %s at %s status %s', r.sent_by, r.sent_at, r.status));
    c := 'rm2';
    CALL core.sp_fee_reminder_record(c_tenant, c_school, c_user, s2, 'Sms', '', NULL, '9990002222',
         'Dear parent, ZZ MRD Two owes.', 11500, 'Failed', c);
    CLOSE c;
    j := pg_temp.j_rem(c_tenant, c_school, c_user, 10);
    -- Both rows carry the same sent_at here (now() is the transaction start), so
    -- only presence and names are asserted; the proc orders by sent_at DESC.
    PERFORM pg_temp.chk('REM-04 history shows both attempts, with names and status',
        pg_temp.jfind(j->'rows','student_name','ZZ MRD Two')->>'status' = 'Failed'
          AND pg_temp.jfind(j->'rows','student_name','ZZ MRD One')->>'status' = 'Sent', '');
    PERFORM pg_temp.chk_eq('REM-05 "sent today" counts only the delivered one',
        (j->'stats'->>'sent_today')::int - b_rem_today, 1);
    j2 := pg_temp.j_due(c_tenant, c_school, c_user, NULL, NULL, NULL, 1, 1000, NULL, 'desc');
    PERFORM pg_temp.chk('REM-06 due list "Last reminder": S1 set, S2 (failed) blank',
        pg_temp.jfind(j2,'student_id',s1::text)->>'last_reminder_at' IS NOT NULL
          AND pg_temp.jfind(j2,'student_id',s2::text)->>'last_reminder_at' IS NULL, '');

    DECLARE v_other int;
    BEGIN
        SELECT student_id INTO v_other FROM core.students
         WHERE NOT (tenant_id = c_tenant AND school_id = c_school) ORDER BY student_id LIMIT 1;
        BEGIN
            c := 'rm3';
            CALL core.sp_fee_reminder_record(c_tenant, c_school, c_user, v_other, 'Email', 'Email', 'x@zz.test', NULL,
                 'cross-school', 1, 'Sent', c);
            CLOSE c;
            PERFORM pg_temp.chk('REM-07 reminder log refuses another school''s student', FALSE,
                format('student %s of another school was logged under school %s', v_other, c_school));
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('REM-07 reminder log refuses another school''s student', TRUE, SQLERRM);
        END;
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- G. A closed day is locked ---------------------------------';

    -- Cashier A closed today in B. No more money goes into it (the collect
    -- procedure asks core.fn_fee_day_closed).
    BEGIN
        m13 := pg_temp.collect(c_user, s1, jsonb_build_array(jsonb_build_object('ledgerId', pg_temp.lid(s1,'ZZ MR Tuition','Sep 2026'), 'amount', 1000, 'concession', 0)),
                               jsonb_build_array(jsonb_build_object('mode','Cash','amount',1000)));
        PERFORM pg_temp.chk('DC-19 money cannot be collected into a closed day', FALSE,
                            format('%s accepted after the close', m13));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('DC-19 money cannot be collected into a closed day', TRUE, SQLERRM);
    END;

    SELECT total_collected INTO v_dec FROM core.fee_day_close
     WHERE tenant_id = c_tenant AND school_id = c_school AND cashier_id = c_user AND close_date = to_char(c_today,'YYYY-MM-DD');
    j := pg_temp.j_day(c_tenant, c_school, c_user, c_today);
    PERFORM pg_temp.chk_eq('DC-20 closed day''s page total = what was closed',
        (j->>'total_collected')::numeric, v_dec);

    -- Yesterday: close it, then deal with its receipt today.
    c := 'dc_y';
    CALL core.sp_fee_day_close(c_tenant, c_school, c_user, c_yday, 2000, 'yesterday', c);
    CLOSE c;
    SELECT total_collected INTO v_dec FROM core.fee_day_close
     WHERE tenant_id = c_tenant AND school_id = c_school AND cashier_id = c_user AND close_date = to_char(c_yday,'YYYY-MM-DD');
    PERFORM pg_temp.chk_eq('DC-20b yesterday closed at 2000', v_dec, 2000);

    -- A cannot cancel anything today: A's own today is closed (the cancel
    -- procedure asks core.fn_fee_day_closed for the canceller's today).
    SELECT total_collected INTO v_dec2 FROM core.fee_day_close
     WHERE tenant_id = c_tenant AND school_id = c_school AND cashier_id = c_user AND close_date = to_char(c_today,'YYYY-MM-DD');
    v_txt := pg_temp.cancel(c_user, m14, 'late correction by A');
    PERFORM pg_temp.chk('DC-21 a cashier whose day is closed cannot cancel into it', v_txt LIKE 'refused%', v_txt);
    j := pg_temp.j_day(c_tenant, c_school, c_user, c_today);
    PERFORM pg_temp.chk_eq('DC-21a ...so A''s closed today still reads what was closed',
        (j->>'total_collected')::numeric, v_dec2);

    -- B (open drawer) cancels yesterday's M12 today: it is a reversal TODAY.
    j2 := pg_temp.j_day(c_tenant, c_school, c_user2, c_today);
    v_txt := pg_temp.cancel(c_user2, m12, 'late correction');
    PERFORM pg_temp.chk('DC-21b B cancels yesterday''s receipt today', v_txt = 'ok', v_txt);
    j := pg_temp.j_day(c_tenant, c_school, c_user, c_yday);
    PERFORM pg_temp.chk_eq('DC-22 a closed day''s figure never changes afterwards',
        (j->>'total_collected')::numeric, v_dec);
    j3 := pg_temp.j_day(c_tenant, c_school, c_user2, c_today);
    PERFORM pg_temp.chk_eq('DC-22b the cancel is -1000 in B''s drawer today',
        (j3->>'total_collected')::numeric - (j2->>'total_collected')::numeric, -1000);
    PERFORM pg_temp.chk_eq('DC-22c ...and -1000 cash (it went back over B''s counter)',
        (j3->>'cash_collected')::numeric - (j2->>'cash_collected')::numeric, -1000);
    j := pg_temp.j_reg(c_tenant, c_school, c_user, c_yday, c_yday);
    PERFORM pg_temp.chk_eq('DC-22d yesterday''s register still reads 2000',
        (j->>'total')::numeric - b_reg_yday, 2000);
    j := pg_temp.j_reg(c_tenant, c_school, c_user, c_today, c_today);
    PERFORM pg_temp.chk_eq('DC-22e today''s register carries the -1000 reversal for M12',
        (pg_temp.jfind(j->'receipts','receipt_no',m12,'entry','Cancellation')->>'amount')::numeric, -1000);
    j := pg_temp.j_cc(c_tenant, c_school, c_user, c_today, c_today);
    PERFORM pg_temp.chk('DC-23 the late cancel is in TODAY''s cancel register, by B',
        pg_temp.jfind(j->'canc','receipt_no',m12)->>'cancelled_by_name' = core.fn_user_display_name(c_user2),
        COALESCE(pg_temp.jfind(j->'canc','receipt_no',m12)->>'cancelled_by_name', 'absent'));

    -- Closing a closed day again is refused; re-open needs a reason; re-close
    -- writes a new count and the first one is kept.
    BEGIN
        c := 'dc_again';
        CALL core.sp_fee_day_close(c_tenant, c_school, c_user, c_today, 1, 'recount', c);
        CLOSE c;
        PERFORM pg_temp.chk('DC-24 closing a closed day again is refused', FALSE, 'it was overwritten');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('DC-24 closing a closed day again is refused', TRUE, SQLERRM);
    END;
    BEGIN
        c := 'dc_rno';
        CALL core.sp_fee_day_reopen(c_tenant, c_school, c_user, c_user, c_today, '  ', c);
        CLOSE c;
        PERFORM pg_temp.chk('DC-24b re-open without a reason is refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('DC-24b re-open without a reason is refused', TRUE, SQLERRM);
    END;
    c := 'dc_ro';
    CALL core.sp_fee_day_reopen(c_tenant, c_school, c_user, c_user, c_today, 'recount the drawer', c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('DC-24c re-open with a reason succeeds and unlocks the day',
        COALESCE(r.success, FALSE) AND NOT core.fn_fee_day_closed(c_tenant, c_school, c_user, c_today), r.message);
    c := 'dc_rc';
    -- Count 50 less than the drawer should hold right now.
    j := pg_temp.j_day(c_tenant, c_school, c_user, c_today);
    v_dec := (j->>'cash_collected')::numeric - (j->>'cash_refunded')::numeric;
    CALL core.sp_fee_day_close(c_tenant, c_school, c_user, c_today, v_dec - 50, 'recounted, 50 short', c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk_eq('DC-24d re-close records the new count (50 short)', r.difference, -50);
    j := pg_temp.j_day(c_tenant, c_school, c_user, c_today);
    PERFORM pg_temp.chk('DC-24e history keeps Close, Re-open (with reason) and the new Close',
        jsonb_array_length(j->'history') = 3
          AND pg_temp.jcount(j->'history','action','Close') = 2
          AND pg_temp.jfind(j->'history','action','Reopen')->>'note' = 'recount the drawer'
          AND EXISTS (SELECT 1 FROM jsonb_array_elements(j->'history') x
                      WHERE x->>'action' = 'Close' AND (x->>'counted_cash')::numeric = 10800 + b_a_cash),
        COALESCE((j->'history')::text, 'none'));
    PERFORM pg_temp.chk('DC-24f the day is closed again', core.fn_fee_day_closed(c_tenant, c_school, c_user, c_today)
        AND (j->>'is_closed')::boolean, '');
    c := 'dc_ro2';
    CALL core.sp_fee_day_reopen(c_tenant, c_school, c_user, c_user, c_today - 30, 'never closed', c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('DC-24g re-opening a day that is not closed says so', NOT COALESCE(r.success, TRUE), r.message);

    BEGIN
        c := 'dc_f';
        CALL core.sp_fee_day_close(c_tenant, c_school, c_user, c_today + 1, 0, 'future', c);
        CLOSE c;
        PERFORM pg_temp.chk('DC-25 a future day cannot be closed', FALSE, 'tomorrow closed with 0');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('DC-25 a future day cannot be closed', TRUE, SQLERRM);
    END;
    BEGIN
        c := 'dc_n';
        CALL core.sp_fee_day_close(c_tenant, c_school, c_user2, c_today, -500, 'negative', c);
        CLOSE c;
        PERFORM pg_temp.chk('DC-26 negative counted cash is refused', FALSE, 'accepted -500');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('DC-26 negative counted cash is refused', TRUE, SQLERRM);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- H. Day boundary on the school''s clock ---------------------';

    PERFORM pg_temp.chk('TZ-01 session clock is Asia/Kolkata',
        current_setting('TimeZone') IN ('Asia/Kolkata','Asia/Calcutta'), current_setting('TimeZone'));
    PERFORM pg_temp.chk('TZ-02 the database itself is pinned to it (not just this session)',
        EXISTS (SELECT 1 FROM pg_db_role_setting rs JOIN pg_database d ON d.oid = rs.setdatabase
                 WHERE d.datname = current_database() AND rs.setrole = 0
                   AND (rs.setconfig::text ILIKE '%TimeZone=Asia/Kolkata%' OR rs.setconfig::text ILIKE '%TimeZone=Asia/Calcutta%')), '');
    PERFORM pg_temp.chk('TZ-03 CURRENT_DATE is the India date',
        CURRENT_DATE = (now() AT TIME ZONE 'Asia/Kolkata')::date, CURRENT_DATE::text);
    SELECT payment_date INTO v_txt FROM core.fee_payments WHERE tenant_id = c_tenant AND school_id = c_school AND receipt_no = m1;
    PERFORM pg_temp.chk('TZ-04 a receipt is stamped with the school date', v_txt = to_char(c_today,'YYYY-MM-DD'), v_txt);

    -- Two refunds on either side of midnight IST, by cashier B.
    DECLARE r_late int; r_early int; v_late timestamptz; v_early timestamptz;
    BEGIN
        v_late  := (c_yday::timestamp  + time '23:30') AT TIME ZONE 'Asia/Kolkata';
        v_early := (c_today::timestamp + time '00:15') AT TIME ZONE 'Asia/Kolkata';
        c := 'tz1';
        CALL core.sp_fee_refund_record(c_tenant, c_school, c_user2, s3, pg_temp.lid(s3,'ZZ MR Deposit'), 50, 'Cash', 'tz late', NULL, c);
        CLOSE c;
        c := 'tz2';
        CALL core.sp_fee_refund_record(c_tenant, c_school, c_user2, s3, pg_temp.lid(s3,'ZZ MR Deposit'), 60, 'Cash', 'tz early', NULL, c);
        CLOSE c;
        SELECT refund_id INTO r_late  FROM core.fee_refunds WHERE tenant_id = c_tenant AND school_id = c_school AND reason = 'tz late';
        SELECT refund_id INTO r_early FROM core.fee_refunds WHERE tenant_id = c_tenant AND school_id = c_school AND reason = 'tz early';
        UPDATE core.fee_refunds SET refunded_at = v_late  WHERE refund_id = r_late;
        UPDATE core.fee_refunds SET refunded_at = v_early WHERE refund_id = r_early;

        j := pg_temp.j_refunds(c_tenant, c_school, c_user, c_yday, c_yday);
        j2 := pg_temp.j_refunds(c_tenant, c_school, c_user, c_today, c_today);
        PERFORM pg_temp.chk('TZ-05 refund at 23:30 IST is on YESTERDAY''s register',
            pg_temp.jfind(j->'rows','reason','tz late') IS NOT NULL AND pg_temp.jfind(j2->'rows','reason','tz late') IS NULL, v_late::text);
        PERFORM pg_temp.chk('TZ-06 refund at 00:15 IST is on TODAY''s register',
            pg_temp.jfind(j2->'rows','reason','tz early') IS NOT NULL AND pg_temp.jfind(j->'rows','reason','tz early') IS NULL, v_early::text);
        j := pg_temp.j_day(c_tenant, c_school, c_user2, c_yday);
        PERFORM pg_temp.chk_eq('TZ-07 B''s yesterday drawer carries the 23:30 refund', (j->>'cash_refunded')::numeric
            - (SELECT COALESCE(SUM(amount),0) FROM core.fee_refunds WHERE tenant_id=c_tenant AND school_id=c_school
                 AND refunded_by=c_user2 AND refund_mode='Cash' AND refunded_at::date = c_yday AND refund_id <> r_late), 50);

        -- The same rows read by a connection on UTC: the 00:15 refund slides to
        -- yesterday. Safe only because the DATABASE default is IST (TZ-02).
        SET LOCAL TimeZone = 'UTC';
        SELECT refunded_at::date INTO v_txt FROM core.fee_refunds WHERE refund_id = r_early;
        SET LOCAL TimeZone = 'Asia/Kolkata';
        PERFORM pg_temp.chk('TZ-08 (fragility) on a UTC session 00:15 IST reads as yesterday',
            v_txt::date = c_yday, format('UTC session date %s -- correct only via the DB-level setting', v_txt));
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- I. Scope --------------------------------------------------';

    j := pg_temp.j_reg(23, 33, c_user, c_yday, c_today);
    PERFORM pg_temp.chk('SC-01 another school''s register has none of our receipts',
        NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j->'receipts') x WHERE x->>'receipt_no' IN (m1,m2,m3,m8)
                      AND x->>'student_name' LIKE 'ZZ MRD%'), '');
    j := pg_temp.j_def(23, 33, c_user, NULL, NULL);
    PERFORM pg_temp.chk('SC-02 another school''s defaulters has none of ours',
        NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j) x WHERE (x->>'student_id')::int IN (s1,s2,s3,s6)
                      OR x->>'student_name' LIKE 'ZZ MRD%'), '');
    j := pg_temp.j_due(23, 33, c_user, NULL, NULL, NULL, 1, 1000, NULL, 'desc');
    PERFORM pg_temp.chk('SC-03 another school''s due list has none of ours',
        NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j) x WHERE (x->>'student_id')::int IN (s1,s2,s3,s6)), '');
    j := pg_temp.j_day(23, 33, c_user, c_today);
    PERFORM pg_temp.chk_eq('SC-04 another school''s day close sees 0 for our cashier', (j->>'total_collected')::numeric, 0);
    PERFORM pg_temp.chk('SC-04b our close does not lock another school',
        NOT core.fn_fee_day_closed(23, 33, c_user, c_today), '');
    j := pg_temp.j_refunds(23, 33, c_user, c_yday, c_today);
    PERFORM pg_temp.chk('SC-05 another school''s refund register has none of ours',
        NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j->'rows') x WHERE x->>'student_name' LIKE 'ZZ MRD%'), '');
    j := pg_temp.j_cc(23, 33, c_user, c_yday, c_today);
    PERFORM pg_temp.chk('SC-06 another school''s cancel register has none of ours',
        NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j->'canc') x WHERE x->>'student_name' LIKE 'ZZ MRD%'), '');
    j := pg_temp.j_rem(23, 33, c_user, 50);
    PERFORM pg_temp.chk('SC-07 another school''s reminder history has none of ours',
        NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j->'rows') x WHERE (x->>'student_id')::int IN (s1,s2)), '');

    v_n := 0;
    BEGIN PERFORM pg_temp.j_reg(1, 0, c_user, c_today, c_today); EXCEPTION WHEN OTHERS THEN v_n := v_n + 1; END;
    BEGIN PERFORM pg_temp.j_day(1, 0, c_user, c_today);          EXCEPTION WHEN OTHERS THEN v_n := v_n + 1; END;
    BEGIN PERFORM pg_temp.j_def(1, 0, c_user, NULL, NULL);       EXCEPTION WHEN OTHERS THEN v_n := v_n + 1; END;
    BEGIN PERFORM pg_temp.j_due(1, 0, c_user, NULL, NULL, NULL, 1, 10, NULL, 'desc'); EXCEPTION WHEN OTHERS THEN v_n := v_n + 1; END;
    BEGIN PERFORM pg_temp.j_refunds(1, 0, c_user, c_today, c_today); EXCEPTION WHEN OTHERS THEN v_n := v_n + 1; END;
    BEGIN PERFORM pg_temp.j_cc(1, 0, c_user, c_today, c_today);  EXCEPTION WHEN OTHERS THEN v_n := v_n + 1; END;
    BEGIN PERFORM pg_temp.j_rem(1, 0, c_user, 10);               EXCEPTION WHEN OTHERS THEN v_n := v_n + 1; END;
    BEGIN c := 'sc_dc'; CALL core.sp_fee_day_close(1, 0, c_user, c_today, 0, NULL, c); EXCEPTION WHEN OTHERS THEN v_n := v_n + 1; END;
    BEGIN c := 'sc_ro'; CALL core.sp_fee_day_reopen(1, 0, c_user, c_user, c_today, 'x', c); EXCEPTION WHEN OTHERS THEN v_n := v_n + 1; END;
    PERFORM pg_temp.chk_eq('SC-08 platform tenant is refused by all 9 report/close procs', v_n, 9);
    j := pg_temp.j_dash(1, 0, c_user);
    PERFORM pg_temp.chk_eq('SC-09 platform tenant dashboard shows 0 collection', (j->'kpi'->>'today_collection')::numeric, 0);
    -- Another school cannot re-open our day.
    c := 'sc_ro2';
    CALL core.sp_fee_day_reopen(23, 33, c_user, c_user, c_today, 'not mine', c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('SC-09b another school cannot re-open our day',
        NOT COALESCE(r.success, TRUE) AND core.fn_fee_day_closed(c_tenant, c_school, c_user, c_today), r.message);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- J. Edge cases that need more data -------------------------';

    -- A blank range means the same period (month to date) in both registers,
    -- because the controller nets one against the other.
    IF date_trunc('month', c_today)::date < c_yday THEN
        DECLARE v_ms date := date_trunc('month', c_today)::date;
        BEGIN
            c := 'j1';
            CALL core.sp_fee_refund_record(c_tenant, c_school, c_user2, s3, pg_temp.lid(s3,'ZZ MR Deposit'), 10, 'Cash', 'month start', NULL, c);
            CLOSE c;
            UPDATE core.fee_refunds SET refunded_at = (v_ms::timestamp + time '10:00') AT TIME ZONE 'Asia/Kolkata'
             WHERE tenant_id = c_tenant AND school_id = c_school AND reason = 'month start';
            -- ...and a receipt on the same month-start day (cashier B, whose
            -- month-start day is not closed).
            m13 := pg_temp.collect(c_user2, s1, jsonb_build_array(jsonb_build_object('ledgerId', pg_temp.lid(s1,'ZZ MR Tuition','Aug 2026'), 'amount', 100, 'concession', 0)),
                                   jsonb_build_array(jsonb_build_object('mode','Cash','amount',100)), 0, v_ms);
            j  := pg_temp.j_refunds(c_tenant, c_school, c_user, NULL, NULL);
            j2 := pg_temp.j_reg(c_tenant, c_school, c_user, NULL, NULL);
            PERFORM pg_temp.chk('RPT-29 blank range means the same period in both registers',
                pg_temp.jfind(j->'rows','reason','month start') IS NOT NULL
                  AND pg_temp.jfind(j2->'receipts','receipt_no',m13) IS NOT NULL,
                format('month-start refund listed: %s; month-start receipt listed: %s',
                       pg_temp.jfind(j->'rows','reason','month start') IS NOT NULL,
                       pg_temp.jfind(j2->'receipts','receipt_no',m13) IS NOT NULL));
        END;
    ELSE
        PERFORM pg_temp.chk('RPT-29 blank range means the same period in both registers', TRUE, 'skipped: too early in the month');
    END IF;

    -- A registration fee part-paid before admission is owed money: it is on
    -- Defaulters as its own row.
    DECLARE e2 int;
    BEGIN
        c := 'j2a';
        CALL core.sp_enquiry_crm_manage(
             p_operation => 'SaveEnquiry', p_tenant_id => c_tenant, p_school_id => c_school,
             p_action_user_id => c_user, p_student_name => 'ZZ MRD Enquiry Two',
             p_gender => 'Female', p_dob => DATE '2016-07-07',
             p_class_name => v_cls, p_session => v_year, p_mobile => '9995552222',
             p_lead_source => 'Walk-in', p_status => 'New', p_result => c);
        SELECT enquiry_id INTO e2 FROM core.enquiries
         WHERE tenant_id = c_tenant AND school_id = c_school AND student_name = 'ZZ MRD Enquiry Two' ORDER BY enquiry_id DESC LIMIT 1;
        c := 'j2b';
        CALL core.sp_enquiry_register(p_tenant_id => c_tenant, p_school_id => c_school,
             p_action_user_id => c_user, p_enquiry_id => e2, p_auto_generate => TRUE, p_result => c);
        c := 'j2c';
        CALL core.sp_registration_fee_record(c_tenant, c_school, c_user2, e2, 600, 'Cash', NULL, NULL, NULL, v_year, 0, NULL, NULL, 1000, c);
        CLOSE c;
        j  := pg_temp.j_def(c_tenant, c_school, c_user, NULL, NULL);
        e  := pg_temp.jfind(j,'student_name','ZZ MRD Enquiry Two');
        PERFORM pg_temp.chk('DEF-20 a part-paid registration balance (400) is on Defaulters',
            e IS NOT NULL AND e->>'entry' = 'Registration' AND (e->>'total_outstanding')::numeric = 400,
            COALESCE(e::text, 'absent'));
        PERFORM pg_temp.chk('DEF-20b the fully paid registration (M8) is not',
            pg_temp.jfind(j,'student_name','ZZ MRD Enquiry') IS NULL, '');
    END;

    -- Cancelling a receipt whose money was already partly refunded. Cashier B
    -- does it, so A's closed day is not what refuses it.
    DECLARE v_ret numeric;
    BEGIN
        v_txt := pg_temp.cancel(c_user2, m7, 'cheque bounced');
        SELECT amount_paid - refund_amount INTO v_ret FROM core.student_ledger WHERE ledger_id = pg_temp.lid(s3,'ZZ MR Deposit');
        PERFORM pg_temp.chk('RPT-30 a receipt whose money was refunded cannot be cancelled',
            v_txt LIKE 'refused%', format('%s; school holds %s on the deposit', v_txt, v_ret));
    END;

    -- SendReminders now reads the WHOLE due list, 200 rows a page (the C#
    -- LoadAllDuesAsync), so a selected student who owes little is always found.
    -- 52 bigger debtors used to push them out of a first-page window.
    DECLARE t_sid int; i int; pg int := 1; got int := 0; tot int := 0; found boolean := FALSE;
    BEGIN
        c := 'j4t';
        CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
             'ZZ-MRD-T', NULL, 'ZZ MRD Small Debtor', 'Male', DATE '2015-02-02', v_cls, v_sec, v_year, v_start,
             p_fee_plan_json => jsonb_build_array(jsonb_build_object('feeHeadName','ZZ MR Lab','frequency','One Time','amount',100)),
             p_result => c);
        SELECT student_id INTO t_sid FROM core.students WHERE tenant_id = c_tenant AND school_id = c_school AND admission_no = 'ZZ-MRD-T';
        FOR i IN 1..52 LOOP
            c := 'j4b' || i;
            CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
                 'ZZ-MRD-B' || lpad(i::text, 2, '0'), NULL, 'ZZ MRD Bulk ' || i, 'Female', DATE '2015-03-03', v_cls, v_sec, v_year, v_start,
                 p_fee_plan_json => jsonb_build_array(jsonb_build_object('feeHeadName','ZZ MR Bulk','frequency','One Time','amount',9000)),
                 p_result => c);
        END LOOP;
        j := pg_temp.j_due(c_tenant, c_school, c_user, NULL, NULL, NULL, 1, 1 + 50, NULL, 'asc');
        PERFORM pg_temp.chk('REM-08a (the old first-page window really would miss them)',
            pg_temp.jfind(j,'student_id',t_sid::text) IS NULL, format('%s rows in the window', jsonb_array_length(j)));
        LOOP
            j := pg_temp.j_due(c_tenant, c_school, c_user, NULL, NULL, NULL, pg, 200, NULL, 'asc');
            EXIT WHEN jsonb_array_length(j) = 0;
            tot := (j->0->>'total_count')::int;
            got := got + jsonb_array_length(j);
            found := found OR pg_temp.jfind(j,'student_id',t_sid::text) IS NOT NULL;
            EXIT WHEN got >= tot;
            pg := pg + 1;
        END LOOP;
        PERFORM pg_temp.chk('REM-08 reading every page finds the selected small debtor',
            found AND got = tot, format('%s of %s rows read in %s page(s)', got, tot, pg));
    END;

    -- Nothing we made is visible to another school.
    SELECT COUNT(*) INTO v_n FROM core.fee_payments
     WHERE receipt_no IN (m1,m2,m3,m4,m5,m6,m7,m8,m9,m10,m11,m12,m14) AND NOT (tenant_id = c_tenant AND school_id = c_school)
       AND (student_id IN (s1,s2,s3,s4,s5,s6) OR enquiry_id = e1);
    PERFORM pg_temp.chk_eq('SC-10 every fixture receipt is on our school', v_n, 0);
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
            RAISE NOTICE '   %  %', rpad(r.name, 62), r.detail;
        END LOOP;
    END IF;
    RAISE NOTICE '';
END
$sum$;

ROLLBACK;
