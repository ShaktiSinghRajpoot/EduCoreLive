-- ============================================================================
-- Fee collection core -- the MONEY HISTORY suite.
--
-- Wherever money is taken, given back, waived, carried forward or reversed,
-- there must be a durable record of who, when, how much, how (tender), which
-- receipt, which student and which fee head -- never silently deleted or
-- overwritten, and agreeing with day close and the reports.
--
-- The other fee suites (fee_module, fee_realworld, money_trail, admission_fee)
-- cover the happy path, the basic guards and one student's life. This one goes
-- after the edges: split tenders, partial pays, duplicate lines, spoofed
-- tenders, advance over-use, cancel-after-refund, cancel-after-spend, cancel
-- after day close, sub-paisa refunds, cross-school ids, and whether every event
-- is visible in history, on the receipt and in day close.
--
-- The collect / cancel / refund / reprint bugs this suite found are fixed
-- (fee_advance.sql, fee_receipt_cancel.sql, fee_refund.sql, fee_money_guards.sql)
-- and their checks now assert the fixed behaviour. A check still named
-- "BUG <id> ..." waits on a fix outside these files -- the day close and
-- collection register math (fee_day_close.sql / fee_reports.sql). Probes that
-- would corrupt the fixture if a bug came back run inside a sub-block that is
-- always rolled back (RAISE 'zz_undo'), so one bug cannot cascade.
--
-- Runs inside ONE transaction and ROLLS BACK.
--
--     psql ... -f money_fee_collection_tests.sql
--
-- COVERS
--   COL. Allocation and the collect engine's guards
--   RCP. Receipt numbers, reprint, what a receipt shows
--   CAN. Cancel / void
--   CON. Concession / discount
--   ADV. Advance wallet
--   REF. Refund
--   DAY. Day close and collection register agree with the till
--   SEC. Scope: another school can read nothing
--   TRL. Structural trail guarantees
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
    PERFORM pg_temp.chk(p_name, ROUND(COALESCE(p_got,0),2) = ROUND(COALESCE(p_want,0),2),
                        format('got %s, expected %s', COALESCE(p_got::text,'NULL'), p_want));
END $$;

-- One payment line, as the counter sends it.
CREATE OR REPLACE FUNCTION pg_temp.it(p_lid integer, p_amt numeric, p_conc numeric DEFAULT 0)
RETURNS jsonb LANGUAGE sql AS $$
    SELECT jsonb_build_object('ledgerId', p_lid, 'amount', p_amt, 'concession', p_conc)
$$;

-- The n-th (0-based) tuition month of a student, oldest first.
CREATE OR REPLACE FUNCTION pg_temp.mon(p_sid integer, p_n integer)
RETURNS integer LANGUAGE sql AS $$
    SELECT ledger_id FROM core.student_ledger
     WHERE student_id = p_sid AND fee_head_name = 'ZZ Tuition'
     ORDER BY due_date, ledger_id OFFSET p_n LIMIT 1
$$;

CREATE OR REPLACE FUNCTION pg_temp.head(p_sid integer, p_name text)
RETURNS integer LANGUAGE sql AS $$
    SELECT ledger_id FROM core.student_ledger
     WHERE student_id = p_sid AND fee_head_name = p_name LIMIT 1
$$;

CREATE OR REPLACE FUNCTION pg_temp.wallet(p_sid integer)
RETURNS numeric LANGUAGE sql AS $$
    SELECT COALESCE((SELECT balance FROM core.student_advance WHERE student_id = p_sid), 0)
$$;

-- Receipt counter for school 34, receipt year 2026.
CREATE OR REPLACE FUNCTION pg_temp.ctr()
RETURNS integer LANGUAGE sql AS $$
    SELECT COALESCE((SELECT last_seq FROM core.receipt_counters
                      WHERE tenant_id = 24 AND school_id = 34 AND fin_year = '2026'), 0)
$$;

CREATE OR REPLACE FUNCTION pg_temp.seq(p_rcpt text)
RETURNS integer LANGUAGE sql AS $$ SELECT split_part(p_rcpt, '-', 3)::integer $$;

-- Ledger fingerprint: what a cancel must restore exactly.
CREATE OR REPLACE FUNCTION pg_temp.snap(p_sid integer)
RETURNS text LANGUAGE sql AS $$
    SELECT string_agg(ledger_id || ':' || amount_paid || ':' || concession || ':' || refund_amount || ':' || status,
                      ',' ORDER BY ledger_id)
    FROM core.student_ledger WHERE student_id = p_sid
$$;

-- The collect engine exactly as FeePaymentService calls it (no payment date,
-- the session name as fin year). Returns the receipt number.
CREATE OR REPLACE FUNCTION pg_temp.collect(
    p_sid integer, p_items jsonb, p_tenders jsonb DEFAULT NULL, p_adv numeric DEFAULT 0,
    p_extras jsonb DEFAULT '[]'::jsonb, p_dtype text DEFAULT NULL, p_dval numeric DEFAULT 0,
    p_dreason text DEFAULT NULL, p_t integer DEFAULT 24, p_s integer DEFAULT 34,
    p_fin text DEFAULT 'current', p_client_ref text DEFAULT NULL, p_approver text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c refcursor; r record; v_fin text;
BEGIN
    v_fin := p_fin;
    IF v_fin = 'current' THEN
        SELECT academic_year_name INTO v_fin FROM academic.academic_years
         WHERE tenant_id = 24 AND school_id = 34 AND COALESCE(is_current, FALSE) LIMIT 1;
    END IF;
    CALL core.sp_fee_payment_collect(p_t, p_s, 39, p_sid, p_items, p_extras, 'Cash', NULL, NULL,
         NULL, v_fin, p_dtype, p_dval, p_dreason, p_tenders, p_adv, c, p_client_ref, p_approver);
    FETCH c INTO r; CLOSE c;
    RETURN r.receipt_no;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.cancel(p_rcpt text, p_reason text, p_auth text DEFAULT 'Principal',
                                          p_t integer DEFAULT 24, p_s integer DEFAULT 34)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE c refcursor; r record;
BEGIN
    CALL core.sp_fee_receipt_cancel(p_t, p_s, 39, p_rcpt, p_reason, p_auth, c);
    FETCH c INTO r; CLOSE c;
    RETURN r.success;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.refund(p_sid integer, p_lid integer, p_amt numeric, p_reason text,
                                          p_t integer DEFAULT 24, p_s integer DEFAULT 34)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE c refcursor; r record;
BEGIN
    CALL core.sp_fee_refund_record(p_t, p_s, 39, p_sid, p_lid, p_amt, 'Cash', p_reason, 'Principal', c);
    FETCH c INTO r; CLOSE c;
    RETURN to_jsonb(r);
END $$;

-- One field of the cashier's day summary (user 39, today), as Day Close reads it.
CREATE OR REPLACE FUNCTION pg_temp.day(p_field text)
RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE c1 refcursor; c2 refcursor; c3 refcursor; r record;
BEGIN
    CALL core.sp_fee_day_collection_get(24, 34, 39, CURRENT_DATE, p_summary => c1, p_modes => c2, p_history => c3);
    FETCH c1 INTO r; CLOSE c1; CLOSE c2; CLOSE c3;
    RETURN (to_jsonb(r)->>p_field)::numeric;
END $$;

-- Collection register mode panel for today: {mode: amount}.
CREATE OR REPLACE FUNCTION pg_temp.reg_modes()
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE c1 refcursor; c2 refcursor; c3 refcursor; r record; v jsonb := '{}'::jsonb;
BEGIN
    CALL core.sp_fee_collection_register(24, 34, 39, CURRENT_DATE, CURRENT_DATE, p_receipts => c1, p_modes => c2, p_heads => c3);
    LOOP FETCH c2 INTO r; EXIT WHEN NOT FOUND;
         v := v || jsonb_build_object(r.payment_mode, r.amount);
    END LOOP;
    CLOSE c1; CLOSE c2; CLOSE c3;
    RETURN v;
END $$;

-- Rows returned by a (tenant, school, user, student, cursor) read proc.
CREATE OR REPLACE FUNCTION pg_temp.nrows(p_proc text, p_t integer, p_s integer, p_sid integer)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE c refcursor; r record; n integer := 0;
BEGIN
    EXECUTE format('CALL %s($1, $2, $3, $4, NULL::refcursor)', p_proc) INTO c USING p_t, p_s, 39, p_sid;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; n := n + 1; END LOOP;
    CLOSE c;
    RETURN n;
EXCEPTION WHEN OTHERS THEN
    RETURN 0;
END $$;

-- First row of a read proc, as json (to see which columns the screen gets).
CREATE OR REPLACE FUNCTION pg_temp.row1(p_proc text, p_t integer, p_s integer, p_sid integer)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE c refcursor; r record;
BEGIN
    EXECUTE format('CALL %s($1, $2, $3, $4, NULL::refcursor)', p_proc) INTO c USING p_t, p_s, 39, p_sid;
    FETCH c INTO r; CLOSE c;
    RETURN to_jsonb(r);
END $$;

CREATE OR REPLACE FUNCTION pg_temp.admit(p_no text, p_name text, p_cls text, p_sec text,
                                         p_year text, p_start date)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE c refcursor; v integer;
BEGIN
    CALL core.sp_admission_manage('SaveAdmission', 24, 34, 39, NULL,
         p_no, NULL, p_name, 'Male', DATE '2015-01-01',
         p_cls, p_sec, p_year, p_start,
         p_fee_plan_json => jsonb_build_array(
             jsonb_build_object('feeHeadName','ZZ Tuition',  'frequency','Monthly', 'amount',1000),
             jsonb_build_object('feeHeadName','ZZ Admission','frequency','One Time','amount',5000),
             jsonb_build_object('feeHeadName','ZZ Deposit',  'frequency','One Time','amount',2000)),
         p_result => c);
    SELECT student_id INTO v FROM core.students WHERE tenant_id = 24 AND school_id = 34 AND admission_no = p_no;
    RETURN v;
END $$;


DO $suite$
DECLARE
    c_tenant CONSTANT integer := 24;
    c_school CONSTANT integer := 34;
    c_user   CONSTANT integer := 39;

    v_year varchar; v_yid integer; v_start date; v_cls varchar; v_sec varchar;
    s1 integer; s2 integer; s3 integer; s4 integer; s5 integer;
    v_x integer; v_xl integer; v_x_pay integer;

    c  refcursor; c2 refcursor;
    r  record;
    j  jsonb;
    v_n integer; v_n2 integer;
    v_dec numeric; v_dec2 numeric; v_dec3 numeric;
    v_txt text; v_txt2 text;
    v_ok boolean;
    v_probe text;
    v_ctr0 integer; v_ctr1 integer;
    k1 text; k2 text; k3 text; kc text; kr1 text; kr2 text; kA1 text; kd text; kt text; kD2 text;
    v_snap1 text; v_snap2 text;
    v_d0 numeric;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '========= FEE COLLECTION: MONEY HISTORY TESTS =========';

    SELECT academic_year_id, academic_year_name, start_date::date INTO v_yid, v_year, v_start
      FROM academic.academic_years
     WHERE tenant_id = c_tenant AND school_id = c_school AND COALESCE(is_current, FALSE) LIMIT 1;
    SELECT ac.class_name, s.section_name INTO v_cls, v_sec
      FROM academic.academic_classes ac
      JOIN academic.academic_class_sections s ON s.academic_class_id = ac.academic_class_id
     WHERE ac.tenant_id = c_tenant AND ac.school_id = c_school AND ac.academic_year_id = v_yid
       AND COALESCE(ac.is_deleted, FALSE) = FALSE AND COALESCE(s.is_deleted, FALSE) = FALSE
     ORDER BY ac.display_order LIMIT 1;
    IF v_year IS NULL OR v_cls IS NULL THEN
        RAISE EXCEPTION 'Fixture missing: school % has no current session or classes.', c_school;
    END IF;
    IF core.fn_receipt_year(c_tenant, c_school, v_year, CURRENT_DATE) <> '2026' THEN
        RAISE EXCEPTION 'Fixture assumption broken: receipt year of % is not 2026.', v_year;
    END IF;

    -- A refundable deposit head, so the refund and concession rules have one.
    c := 'fh';
    CALL core.sp_school_admin_fee_head_manage('SaveFeeHead', c_tenant, c_school, c_user, 0,
         'ZZ Deposit', 'One Time', 2000, 'Mandatory', 'Academic', 'Admission', TRUE, c);
    CLOSE c;

    s1 := pg_temp.admit('ZZ-COL-1', 'ZZ Counter One',   v_cls, v_sec, v_year, v_start);
    s2 := pg_temp.admit('ZZ-COL-2', 'ZZ Counter Sibling', v_cls, v_sec, v_year, v_start);
    s3 := pg_temp.admit('ZZ-COL-3', 'ZZ Counter Advance', v_cls, v_sec, v_year, v_start);
    s4 := pg_temp.admit('ZZ-COL-4', 'ZZ Counter Leaver',  v_cls, v_sec, v_year, v_start);
    s5 := pg_temp.admit('ZZ-COL-5', 'ZZ Counter Till',    v_cls, v_sec, v_year, v_start);

    -- Another school's student with a due of its own.
    SELECT student_id INTO v_x FROM core.students WHERE tenant_id = 23 AND school_id = 33 ORDER BY student_id LIMIT 1;
    INSERT INTO core.student_ledger(tenant_id, school_id, student_id, fee_head_name, frequency,
                                    installment_label, due_date, amount_due)
    VALUES (23, 33, v_x, 'ZZ X Tuition', 'Monthly', 'Apr', '2027-04-10', 1000)
    RETURNING ledger_id INTO v_xl;
    SELECT COUNT(*) INTO v_x_pay FROM core.fee_payments WHERE tenant_id = 23 AND school_id = 33;

    SELECT COUNT(*) INTO v_n FROM core.student_ledger WHERE student_id IN (s1,s2,s3,s4,s5);
    PERFORM pg_temp.chk('setup: five students billed 12 months + 2 one-time each',
                        v_n = 70 AND v_x IS NOT NULL,
                        format('session %s from %s, class %s/%s, %s ledger rows, foreign student %s',
                               v_year, v_start, v_cls, v_sec, v_n, v_x));

    v_ctr0 := pg_temp.ctr();

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- COL. Allocation and the collect engine ---------------';

    -- COL-01: a parent pays three months, 2000 cash + 1000 UPI.
    k1 := pg_temp.collect(s1,
          jsonb_build_array(pg_temp.it(pg_temp.mon(s1,0),1000), pg_temp.it(pg_temp.mon(s1,1),1000),
                            pg_temp.it(pg_temp.mon(s1,2),1000)),
          jsonb_build_array(jsonb_build_object('mode','Cash','amount',2000),
                            jsonb_build_object('mode','UPI','amount',1000,'reference','UPI-778899')));

    SELECT amount, payment_mode, created_by, created_at INTO r FROM core.fee_payments
     WHERE tenant_id = c_tenant AND school_id = c_school AND receipt_no = k1;
    PERFORM pg_temp.chk_eq('COL-01a three months -> receipt for 3000', r.amount, 3000);
    PERFORM pg_temp.chk('COL-01b split tender header reads Mixed', r.payment_mode = 'Mixed',
                        format('mode %s', r.payment_mode));
    PERFORM pg_temp.chk('COL-01c who and when are on the receipt', r.created_by = c_user AND r.created_at IS NOT NULL,
                        format('created_by %s at %s', r.created_by, r.created_at));

    SELECT COUNT(*), SUM(t.amount), MAX(t.reference) FILTER (WHERE t.mode = 'UPI')
      INTO v_n, v_dec, v_txt
      FROM core.fee_payment_tenders t JOIN core.fee_payments p ON p.payment_id = t.payment_id
     WHERE p.school_id = c_school AND p.receipt_no = k1;
    PERFORM pg_temp.chk('COL-01d each tender kept, summing to the receipt', v_n = 2 AND v_dec = 3000,
                        format('%s tender rows, total %s', v_n, v_dec));
    PERFORM pg_temp.chk('COL-01e the UPI reference is stored on its tender', v_txt = 'UPI-778899',
                        format('reference %s', COALESCE(v_txt,'NULL')));

    SELECT COUNT(*) INTO v_n FROM core.student_ledger
     WHERE ledger_id IN (pg_temp.mon(s1,0), pg_temp.mon(s1,1), pg_temp.mon(s1,2))
       AND status = 'Paid' AND amount_paid = 1000;
    PERFORM pg_temp.chk_eq('COL-01f exactly the three chosen months are Paid', v_n, 3);
    SELECT COUNT(*) INTO v_n FROM core.fee_payment_details d JOIN core.fee_payments p ON p.payment_id = d.payment_id
     WHERE p.school_id = c_school AND p.receipt_no = k1 AND d.line_type = 'Due' AND d.ledger_id IS NOT NULL;
    PERFORM pg_temp.chk_eq('COL-01g one receipt line per month, naming its ledger row', v_n, 3);

    -- COL-02
    PERFORM pg_temp.chk('COL-02 first receipt takes the next number', k1 = 'RCP-2026-' || lpad((v_ctr0+1)::text, 4, '0'),
                        format('%s after counter %s', k1, v_ctr0));

    -- COL-03: part payment, then the rest.
    k2 := pg_temp.collect(s1, jsonb_build_array(pg_temp.it(pg_temp.mon(s1,3), 400)));
    SELECT status, amount_due - amount_paid - concession INTO v_txt, v_dec FROM core.student_ledger WHERE ledger_id = pg_temp.mon(s1,3);
    PERFORM pg_temp.chk('COL-03a 400 of 1000 -> Partial with 600 left', v_txt = 'Partial' AND v_dec = 600,
                        format('%s, outstanding %s', v_txt, v_dec));
    k3 := pg_temp.collect(s1, jsonb_build_array(pg_temp.it(pg_temp.mon(s1,3), 600)));
    SELECT status INTO v_txt FROM core.student_ledger WHERE ledger_id = pg_temp.mon(s1,3);
    SELECT COUNT(DISTINCT d.payment_id), SUM(d.amount) INTO v_n, v_dec FROM core.fee_payment_details d
     WHERE d.ledger_id = pg_temp.mon(s1,3);
    PERFORM pg_temp.chk('COL-03b the rest settles it; both receipts trace to the row',
                        v_txt = 'Paid' AND v_n = 2 AND v_dec = 1000, format('%s, %s receipts, %s', v_txt, v_n, v_dec));
    PERFORM pg_temp.chk('COL-03c receipt numbers are consecutive',
                        pg_temp.seq(k2) = pg_temp.seq(k1)+1 AND pg_temp.seq(k3) = pg_temp.seq(k1)+2,
                        format('%s, %s, %s', k1, k2, k3));

    -- COL-04: the same ledger row twice in one request (a double-tick or a
    -- crafted POST). Each line is checked against the row as it was, so both pass.
    v_probe := NULL;
    BEGIN
        PERFORM pg_temp.collect(s1, jsonb_build_array(pg_temp.it(pg_temp.mon(s1,4),700), pg_temp.it(pg_temp.mon(s1,4),700)));
        SELECT amount_paid INTO v_dec FROM core.student_ledger WHERE ledger_id = pg_temp.mon(s1,4);
        v_probe := format('accepted: row of 1000 now shows %s paid', v_dec);
        RAISE EXCEPTION 'zz_undo';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'zz_undo' THEN PERFORM pg_temp.chk('COL-04a same due twice beyond what it owes refused', FALSE, v_probe);
        ELSE PERFORM pg_temp.chk('COL-04a same due twice beyond what it owes refused', TRUE, SQLERRM); END IF;
    END;

    -- ...while two lines that fit together are merged into one receipt line.
    v_txt := pg_temp.collect(s1, jsonb_build_array(pg_temp.it(pg_temp.mon(s1,4),300), pg_temp.it(pg_temp.mon(s1,4),400)));
    SELECT COUNT(*), SUM(d.amount) INTO v_n, v_dec FROM core.fee_payment_details d JOIN core.fee_payments p ON p.payment_id = d.payment_id
     WHERE p.school_id = c_school AND p.receipt_no = v_txt;
    SELECT amount_paid INTO v_dec2 FROM core.student_ledger WHERE ledger_id = pg_temp.mon(s1,4);
    PERFORM pg_temp.chk('COL-04b 300 + 400 on one due -> one merged line of 700',
                        v_n = 1 AND v_dec = 700 AND v_dec2 = 700, format('%s line(s), %s, row paid %s', v_n, v_dec, v_dec2));

    -- COL-05: a zero line rides along and is skipped, not recorded.
    v_txt := pg_temp.collect(s1, jsonb_build_array(pg_temp.it(pg_temp.mon(s1,5),1000), pg_temp.it(pg_temp.mon(s1,6),0,0)));
    SELECT COUNT(*) INTO v_n FROM core.fee_payment_details d JOIN core.fee_payments p ON p.payment_id = d.payment_id
     WHERE p.school_id = c_school AND p.receipt_no = v_txt;
    SELECT amount_paid INTO v_dec FROM core.student_ledger WHERE ledger_id = pg_temp.mon(s1,6);
    PERFORM pg_temp.chk('COL-05 a zero line is skipped, its due untouched', v_n = 1 AND v_dec = 0,
                        format('%s line(s), month 7 paid %s', v_n, v_dec));

    v_ctr1 := pg_temp.ctr();

    -- COL-06
    BEGIN
        PERFORM pg_temp.collect(s1, jsonb_build_array(pg_temp.it(pg_temp.mon(s1,6),0,0)));
        PERFORM pg_temp.chk('COL-06 a request that moves no money is refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('COL-06 a request that moves no money is refused', TRUE, SQLERRM);
    END;

    -- COL-08
    BEGIN
        PERFORM pg_temp.collect(s1, jsonb_build_array(pg_temp.it(pg_temp.mon(s1,6),10000000000000)));
        PERFORM pg_temp.chk('COL-08 an absurd amount is refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('COL-08 an absurd amount is refused', TRUE, SQLERRM);
    END;

    -- COL-09
    BEGIN
        PERFORM pg_temp.collect(s1, jsonb_build_array(pg_temp.it(pg_temp.mon(s1,6),1000)),
                                jsonb_build_array(jsonb_build_object('mode','Cash','amount',900)));
        PERFORM pg_temp.chk('COL-09 tenders short of the settled amount refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('COL-09 tenders short of the settled amount refused', TRUE, SQLERRM);
    END;

    -- COL-17: refused requests leave no hole in the receipt numbers.
    PERFORM pg_temp.chk_eq('COL-17 refused collections consumed no receipt number', pg_temp.ctr(), v_ctr1);

    -- COL-10: a negative tender. The controller drops it, the proc sums it.
    v_probe := NULL;
    BEGIN
        v_txt := pg_temp.collect(s1, jsonb_build_array(pg_temp.it(pg_temp.mon(s1,6),1000)),
                 jsonb_build_array(jsonb_build_object('mode','Cash','amount',2000),
                                   jsonb_build_object('mode','UPI','amount',-1000)));
        SELECT p.amount + p.advance_credit - p.advance_used,
               (SELECT SUM(amount) FROM core.fee_payment_tenders t WHERE t.payment_id = p.payment_id)
          INTO v_dec, v_dec2 FROM core.fee_payments p WHERE p.school_id = c_school AND p.receipt_no = v_txt;
        v_probe := format('accepted: receipt says %s taken, tender lines say %s', v_dec, v_dec2);
        RAISE EXCEPTION 'zz_undo';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'zz_undo' THEN PERFORM pg_temp.chk('COL-10 a negative tender amount is refused', FALSE, v_probe);
        ELSE PERFORM pg_temp.chk('COL-10 a negative tender amount is refused', TRUE, SQLERRM); END IF;
    END;

    -- COL-11: "Advance" sent as a tender mode, with an empty wallet.
    v_probe := NULL;
    BEGIN
        v_txt := pg_temp.collect(s1, jsonb_build_array(pg_temp.it(pg_temp.mon(s1,6),1000)),
                 jsonb_build_array(jsonb_build_object('mode','Advance','amount',1000)));
        SELECT amount_paid INTO v_dec FROM core.student_ledger WHERE ledger_id = pg_temp.mon(s1,6);
        v_probe := format('accepted: month settled (%s paid) from a wallet of %s, nothing debited', v_dec, pg_temp.wallet(s1));
        RAISE EXCEPTION 'zz_undo';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'zz_undo' THEN PERFORM pg_temp.chk('COL-11 "Advance" tender without a wallet refused', FALSE, v_probe);
        ELSE PERFORM pg_temp.chk('COL-11 "Advance" tender without a wallet refused', TRUE, SQLERRM); END IF;
    END;

    -- COL-12/13: an extras-only receipt never checks whose student it is.
    v_probe := NULL;
    BEGIN
        v_txt := pg_temp.collect(v_x, '[]'::jsonb, NULL, 0, '[{"label":"ZZ fine","amount":100}]'::jsonb);
        v_probe := format('accepted: %s issued by school 34 for school 33''s student %s', v_txt, v_x);
        RAISE EXCEPTION 'zz_undo';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'zz_undo' THEN PERFORM pg_temp.chk('COL-12 receipt for another school''s student refused', FALSE, v_probe);
        ELSE PERFORM pg_temp.chk('COL-12 receipt for another school''s student refused', TRUE, SQLERRM); END IF;
    END;

    v_probe := NULL;
    BEGIN
        v_txt := pg_temp.collect(2147483000, '[]'::jsonb, NULL, 0, '[{"label":"ZZ fine","amount":100}]'::jsonb);
        v_probe := format('accepted: %s issued for a student that does not exist', v_txt);
        RAISE EXCEPTION 'zz_undo';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'zz_undo' THEN PERFORM pg_temp.chk('COL-13 receipt for a non-existent student refused', FALSE, v_probe);
        ELSE PERFORM pg_temp.chk('COL-13 receipt for a non-existent student refused', TRUE, SQLERRM); END IF;
    END;

    -- COL-14: ledger rows from the wrong school / wrong student.
    BEGIN
        PERFORM pg_temp.collect(s1, jsonb_build_array(pg_temp.it(v_xl, 100)));
        PERFORM pg_temp.chk('COL-14a another school''s due on our student refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('COL-14a another school''s due on our student refused', TRUE, SQLERRM);
    END;
    BEGIN
        PERFORM pg_temp.collect(v_x, jsonb_build_array(pg_temp.it(v_xl, 100)));
        PERFORM pg_temp.chk('COL-14b another school''s due under our scope refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('COL-14b another school''s due under our scope refused', TRUE, SQLERRM);
    END;
    BEGIN
        PERFORM pg_temp.collect(s1, jsonb_build_array(pg_temp.it(pg_temp.mon(s1,6), 100)), NULL, 0, '[]'::jsonb,
                                NULL, 0, NULL, 23, 33);
        PERFORM pg_temp.chk('COL-14c school 33 cannot collect on our due', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('COL-14c school 33 cannot collect on our due', TRUE, SQLERRM);
    END;
    BEGIN
        PERFORM pg_temp.collect(s2, jsonb_build_array(pg_temp.it(pg_temp.mon(s1,6), 100)));
        PERFORM pg_temp.chk('COL-14d a sibling''s receipt cannot settle another child''s due', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('COL-14d a sibling''s receipt cannot settle another child''s due', TRUE, SQLERRM);
    END;

    -- COL-15
    BEGIN
        PERFORM pg_temp.collect(s1, jsonb_build_array(pg_temp.it(pg_temp.mon(s1,6), 100)), NULL, 0, '[]'::jsonb,
                                NULL, 0, NULL, 1, 0);
        PERFORM pg_temp.chk('COL-15 platform scope cannot collect', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('COL-15 platform scope cannot collect', TRUE, SQLERRM);
    END;

    -- COL-16: a due plus an extra charge with no name.
    v_txt := pg_temp.collect(s1, jsonb_build_array(pg_temp.it(pg_temp.mon(s1,6),1000)), NULL, 0,
                             '[{"label":"","amount":50}]'::jsonb);
    SELECT p.amount, d.fee_head_name, d.ledger_id INTO v_dec, v_txt2, v_n
      FROM core.fee_payments p JOIN core.fee_payment_details d ON d.payment_id = p.payment_id AND d.line_type = 'Extra'
     WHERE p.school_id = c_school AND p.receipt_no = v_txt;
    PERFORM pg_temp.chk('COL-16 extra charge is its own line, off the ledger',
                        v_dec = 1050 AND v_txt2 = 'Extra Charge' AND v_n IS NULL,
                        format('receipt %s, line "%s", ledger %s', v_dec, v_txt2, COALESCE(v_n::text,'NULL')));

    -- COL-19: a retried request (same settlement id) returns the first receipt.
    v_ctr1 := pg_temp.ctr();
    v_txt  := pg_temp.collect(s2, jsonb_build_array(pg_temp.it(pg_temp.mon(s2,7),1000)), NULL, 0, '[]'::jsonb,
                              p_client_ref => 'zz-settle-1');
    v_txt2 := pg_temp.collect(s2, jsonb_build_array(pg_temp.it(pg_temp.mon(s2,7),1000)), NULL, 0, '[]'::jsonb,
                              p_client_ref => 'zz-settle-1');
    SELECT amount_paid INTO v_dec FROM core.student_ledger WHERE ledger_id = pg_temp.mon(s2,7);
    PERFORM pg_temp.chk('COL-19 a retried collect returns the same receipt, takes nothing twice',
                        v_txt = v_txt2 AND pg_temp.ctr() = v_ctr1 + 1 AND v_dec = 1000,
                        format('%s / %s, counter +%s, row paid %s', v_txt, v_txt2, pg_temp.ctr() - v_ctr1, v_dec));
    BEGIN
        PERFORM pg_temp.collect(s1, '[]'::jsonb, NULL, 0, '[{"label":"ZZ fine","amount":10}]'::jsonb,
                                p_client_ref => 'zz-settle-1');
        PERFORM pg_temp.chk('COL-19b a settlement id cannot be reused for another student', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('COL-19b a settlement id cannot be reused for another student', TRUE, SQLERRM);
    END;

    -- COL-24: a cheque needs its number.
    BEGIN
        PERFORM pg_temp.collect(s1, '[]'::jsonb, jsonb_build_array(jsonb_build_object('mode','Cheque','amount',50)), 0,
                                '[{"label":"ZZ fine","amount":50}]'::jsonb);
        PERFORM pg_temp.chk('COL-24 a cheque tender without its number refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('COL-24 a cheque tender without its number refused', TRUE, SQLERRM);
    END;

    -- COL-25: an extra charge's note is kept on its line; extras-only works.
    v_txt := pg_temp.collect(s1, '[]'::jsonb, NULL, 0, '[{"label":"ZZ Library","amount":75,"note":"lost book: Panchatantra"}]'::jsonb);
    SELECT d.fee_head_name, d.installment_label INTO v_txt2, v_probe
      FROM core.fee_payment_details d JOIN core.fee_payments p ON p.payment_id = d.payment_id
     WHERE p.school_id = c_school AND p.receipt_no = v_txt;
    PERFORM pg_temp.chk('COL-25 extras-only receipt keeps the cashier''s note',
                        v_txt2 = 'ZZ Library' AND v_probe = 'lost book: Panchatantra', format('%s / %s', v_txt2, v_probe));

    -- COL-07: rounding. What the ledger, the line and the header hold must agree.
    v_txt := pg_temp.collect(s1, jsonb_build_array(pg_temp.it(pg_temp.mon(s1,7),333.335)));
    SELECT amount INTO v_dec FROM core.fee_payments WHERE school_id = c_school AND receipt_no = v_txt;
    SELECT amount_paid INTO v_dec2 FROM core.student_ledger WHERE ledger_id = pg_temp.mon(s1,7);
    SELECT d.amount INTO v_dec3 FROM core.fee_payment_details d JOIN core.fee_payments p ON p.payment_id = d.payment_id
     WHERE p.school_id = c_school AND p.receipt_no = v_txt;
    PERFORM pg_temp.chk('COL-07 sub-paisa amount rounds the same everywhere',
                        v_dec = v_dec2 AND v_dec2 = v_dec3 AND v_dec = 333.34,
                        format('header %s, ledger %s, line %s', v_dec, v_dec2, v_dec3));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- RCP. Receipts ----------------------------------------';

    SELECT COUNT(*) INTO v_n FROM pg_constraint
     WHERE conrelid = 'core.fee_payments'::regclass AND contype = 'u'
       AND pg_get_constraintdef(oid) ILIKE '%(tenant_id, school_id, receipt_no)%';
    PERFORM pg_temp.chk_eq('RCP-01 receipt number is unique per school (constraint)', v_n, 1);

    -- RCP-08: no fin year passed -> year from the date -> same counter, no clash.
    v_txt := pg_temp.collect(s1, jsonb_build_array(pg_temp.it(pg_temp.mon(s1,8),1000)), NULL, 0, '[]'::jsonb,
                             NULL, 0, NULL, 24, 34, NULL);
    PERFORM pg_temp.chk('RCP-08 no session given -> same RCP-2026 sequence', pg_temp.seq(v_txt) = pg_temp.ctr()
                        AND v_txt LIKE 'RCP-2026-%', v_txt);

    SELECT COUNT(*), COUNT(DISTINCT receipt_no), MAX(pg_temp.seq(receipt_no)) INTO v_n, v_n2, v_dec
      FROM core.fee_payments WHERE tenant_id = c_tenant AND school_id = c_school AND receipt_no LIKE 'RCP-2026-%';
    PERFORM pg_temp.chk('RCP-02 numbers are gapless and unique: 1..counter',
                        v_n = pg_temp.ctr() AND v_n2 = v_n AND v_dec = v_n,
                        format('%s receipts, %s distinct, max %s, counter %s', v_n, v_n2, v_dec, pg_temp.ctr()));

    -- RCP-03: reprint reads back exactly what was issued.
    c := NULL; c2 := NULL;
    CALL core.sp_fee_receipt_get(c_tenant, c_school, c_user, k1, c, c2);
    FETCH c INTO r; j := to_jsonb(r); CLOSE c;
    v_n := 0; v_dec := 0;
    LOOP FETCH c2 INTO r; EXIT WHEN NOT FOUND; v_n := v_n + 1; v_dec := v_dec + r.amount; END LOOP;
    CLOSE c2;
    PERFORM pg_temp.chk('RCP-03 reprint: 3 lines summing to the 3000 header',
                        v_n = 3 AND v_dec = 3000 AND (j->>'amount')::numeric = 3000,
                        format('%s lines, %s, header %s', v_n, v_dec, j->>'amount'));
    -- A reprint of a voided receipt must say so (checked on a cancelled one in
    -- CAN-02c); a live one says it is not.
    PERFORM pg_temp.chk('RCP-04 reprint carries the cancelled flag (live receipt: false)',
                        j ? 'is_cancelled' AND (j->>'is_cancelled')::boolean = FALSE,
                        format('is_cancelled %s', COALESCE(j->>'is_cancelled', 'missing')));
    PERFORM pg_temp.chk('RCP-05 reprint names the cashier who took the money',
                        (j->>'created_by')::integer = c_user AND NULLIF(j->>'collected_by', '') IS NOT NULL,
                        format('created_by %s, collected_by %s', j->>'created_by', j->>'collected_by'));
    -- The split, mode by mode, with the UPI reference.
    v_n := jsonb_array_length((j->>'tenders')::jsonb);
    SELECT COUNT(*) INTO v_n2 FROM jsonb_array_elements((j->>'tenders')::jsonb) t
     WHERE t->>'mode' = 'UPI' AND (t->>'amount')::numeric = 1000 AND t->>'reference' = 'UPI-778899';
    PERFORM pg_temp.chk('RCP-06 reprint returns the tender split with references', v_n = 2 AND v_n2 = 1,
                        COALESCE(j->>'tenders', 'missing'));
    PERFORM pg_temp.chk('RCP-06b ...and the header reference names the UPI ref', j->>'reference_no' = 'UPI-778899',
                        format('reference_no %s', COALESCE(j->>'reference_no', 'NULL')));
    PERFORM pg_temp.chk('RCP-09 reprint returns discount_amount (registration discount)',
                        j ? 'discount_amount', format('discount_amount %s', COALESCE(j->>'discount_amount', 'missing')));

    BEGIN
        c := NULL; c2 := NULL;
        CALL core.sp_fee_receipt_get(23, 33, c_user, k1, c, c2);
        PERFORM pg_temp.chk('RCP-07 another school cannot reprint our receipt', FALSE, 'it was returned');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('RCP-07 another school cannot reprint our receipt', TRUE, SQLERRM);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- CAN. Cancel / void -----------------------------------';

    -- CAN-01: a receipt with a cash line, a cash+concession line and an extra.
    v_snap1 := pg_temp.snap(s1);
    kc := pg_temp.collect(s1,
          jsonb_build_array(pg_temp.it(pg_temp.mon(s1,9),600), pg_temp.it(pg_temp.head(s1,'ZZ Admission'),4000,1000)),
          jsonb_build_array(jsonb_build_object('mode','Cheque','amount',4700,'reference','CHQ 004512')),
          0, '[{"label":"ZZ ID card","amount":100}]'::jsonb, 'Flat', 1000, 'staff ward');
    v_ok := pg_temp.cancel(kc, 'cheque bounced', 'Principal');
    v_snap2 := pg_temp.snap(s1);
    PERFORM pg_temp.chk('CAN-01 cancel restores every ledger row exactly', v_ok AND v_snap1 = v_snap2,
                        CASE WHEN v_snap1 = v_snap2 THEN 'identical' ELSE 'ledger differs after cancel' END);

    SELECT is_cancelled, cancel_reason, cancelled_by, cancelled_at, cancel_authorized_by, amount, concession_total,
           discount_reason,
           (SELECT COUNT(*) FROM core.fee_payment_details d WHERE d.payment_id = p.payment_id) AS n_lines,
           (SELECT COUNT(*) FROM core.fee_payment_tenders t WHERE t.payment_id = p.payment_id) AS n_tenders
      INTO r FROM core.fee_payments p WHERE school_id = c_school AND receipt_no = kc;
    PERFORM pg_temp.chk('CAN-02a cancelled receipt kept: reason, who, when, authoriser',
                        r.is_cancelled AND r.cancel_reason = 'cheque bounced' AND r.cancelled_by = c_user
                        AND r.cancelled_at IS NOT NULL AND r.cancel_authorized_by = 'Principal',
                        format('%s / %s / %s / %s', r.cancel_reason, r.cancelled_by, r.cancelled_at, r.cancel_authorized_by));
    PERFORM pg_temp.chk('CAN-02b ...with its amounts, lines and tenders intact',
                        r.amount = 4700 AND r.concession_total = 1000 AND r.discount_reason = 'staff ward'
                        AND r.n_lines = 3 AND r.n_tenders = 1,
                        format('amount %s, conc %s, %s lines, %s tenders', r.amount, r.concession_total, r.n_lines, r.n_tenders));

    -- CAN-02c: the reprint of a voided receipt says so, and who/when/why.
    c := NULL; c2 := NULL;
    CALL core.sp_fee_receipt_get(c_tenant, c_school, c_user, kc, c, c2);
    FETCH c INTO r; j := to_jsonb(r); CLOSE c; CLOSE c2;
    PERFORM pg_temp.chk('CAN-02c reprint of a cancelled receipt is marked CANCELLED',
                        (j->>'is_cancelled')::boolean AND j->>'cancel_reason' = 'cheque bounced'
                        AND NULLIF(j->>'cancelled_by_name', '') IS NOT NULL AND j->>'cancelled_at' IS NOT NULL
                        AND j->>'cancel_authorized_by' = 'Principal',
                        format('%s / %s / %s / %s', j->>'is_cancelled', j->>'cancel_reason', j->>'cancelled_by_name', j->>'cancelled_at'));
    PERFORM pg_temp.chk('CAN-02d ...and keeps the cheque number on its tender',
                        (j->>'tenders')::jsonb -> 0 ->> 'reference' = 'CHQ 004512', COALESCE(j->>'tenders', 'missing'));

    BEGIN
        PERFORM pg_temp.cancel(k2, '   ');
        PERFORM pg_temp.chk('CAN-03 cancel without a reason refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CAN-03 cancel without a reason refused', TRUE, SQLERRM);
    END;

    v_ok := pg_temp.cancel(kc, 'again');
    SELECT cancel_reason INTO v_txt FROM core.fee_payments WHERE school_id = c_school AND receipt_no = kc;
    PERFORM pg_temp.chk('CAN-04 second cancel refused, nothing reversed twice',
                        NOT v_ok AND pg_temp.snap(s1) = v_snap1 AND v_txt = 'cheque bounced',
                        format('success %s, reason kept "%s"', v_ok, v_txt));

    v_ok := pg_temp.cancel(k1, 'not ours', 'Principal', 23, 33);
    SELECT is_cancelled INTO v_ok FROM core.fee_payments WHERE school_id = c_school AND receipt_no = k1;
    PERFORM pg_temp.chk('CAN-05 school 33 cannot cancel our receipt', NOT v_ok, format('is_cancelled %s', v_ok));

    -- CAN-06: two receipts on one row, cancel the first.
    kr1 := pg_temp.collect(s1, jsonb_build_array(pg_temp.it(pg_temp.mon(s1,10),400)));
    kr2 := pg_temp.collect(s1, jsonb_build_array(pg_temp.it(pg_temp.mon(s1,10),300)));
    PERFORM pg_temp.cancel(kr1, 'wrong amount');
    SELECT amount_paid, status INTO v_dec, v_txt FROM core.student_ledger WHERE ledger_id = pg_temp.mon(s1,10);
    PERFORM pg_temp.chk('CAN-06 cancelling one receipt leaves the other''s money', v_dec = 300 AND v_txt = 'Partial',
                        format('paid %s, %s', v_dec, v_txt));

    -- CAN-11: a cancelled number is never handed out again.
    v_txt := pg_temp.collect(s1, jsonb_build_array(pg_temp.it(pg_temp.mon(s1,11),1000)));
    SELECT COUNT(*) INTO v_n FROM core.fee_payments WHERE school_id = c_school AND receipt_no IN (kc, kr1) AND is_cancelled;
    PERFORM pg_temp.chk('CAN-11 cancelled numbers stay taken; next is new',
                        v_n = 2 AND pg_temp.seq(v_txt) > pg_temp.seq(kr2), format('next %s, %s cancelled kept', v_txt, v_n));

    -- CAN-07/08: what the Payment History tab receives.
    v_n := pg_temp.nrows('core.sp_fee_payment_history_get', c_tenant, c_school, s1);
    SELECT COUNT(*) INTO v_n2 FROM core.fee_payments WHERE student_id = s1;
    PERFORM pg_temp.chk('CAN-07 history lists every receipt, cancelled included', v_n = v_n2,
                        format('history %s rows, %s receipts on file', v_n, v_n2));
    -- CAN-08: the cancelled receipt's history row says who took it, who voided it and when.
    v_ok := FALSE;
    c := NULL;
    CALL core.sp_fee_payment_history_get(c_tenant, c_school, c_user, s1, c);
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
         IF r.receipt_no = kc THEN
             j := to_jsonb(r);
             v_ok := r.is_cancelled AND r.cancelled_by = c_user AND r.cancelled_at IS NOT NULL
                     AND NULLIF(r.collected_by, '') IS NOT NULL AND NULLIF(r.cancelled_by_name, '') IS NOT NULL
                     AND r.cancel_authorized_by = 'Principal';
         END IF;
    END LOOP;
    CLOSE c;
    PERFORM pg_temp.chk('CAN-08 history shows who collected / who cancelled and when', v_ok,
                        format('collected_by %s, cancelled_by %s at %s', j->>'collected_by', j->>'cancelled_by_name', j->>'cancelled_at'));

    -- CAN-14/15: cancelling a REGISTRATION receipt. Before admission the
    -- enquiry's paid flag must drop; after admission the money must come back
    -- as a due on the student, or nobody chases it.
    DECLARE v_e integer; v_reg text; v_rr text; v_sid integer; k_ok boolean; k_msg text;
    BEGIN
        c := NULL;
        CALL core.sp_enquiry_crm_manage(p_operation => 'SaveEnquiry', p_tenant_id => c_tenant, p_school_id => c_school,
             p_action_user_id => c_user, p_student_name => 'ZZ Reg Cancel A', p_gender => 'Male',
             p_dob => DATE '2016-02-02', p_class_name => v_cls, p_session => v_year, p_mobile => '9995551111',
             p_lead_source => 'Walk-in', p_status => 'New', p_result => c);
        CLOSE c;
        SELECT enquiry_id INTO v_e FROM core.enquiries WHERE tenant_id = c_tenant AND school_id = c_school
           AND student_name = 'ZZ Reg Cancel A' ORDER BY enquiry_id DESC LIMIT 1;
        c := NULL;
        CALL core.sp_enquiry_register(p_tenant_id => c_tenant, p_school_id => c_school, p_action_user_id => c_user,
             p_enquiry_id => v_e, p_auto_generate => TRUE, p_result => c);
        CLOSE c;
        c := NULL;
        CALL core.sp_registration_fee_record(p_tenant_id => c_tenant, p_school_id => c_school, p_action_user_id => c_user,
             p_enquiry_id => v_e, p_amount => 500, p_payment_mode => 'Cash', p_payment_date => CURRENT_DATE,
             p_fin_year => v_year, p_result => c);
        FETCH c INTO r; v_rr := r.receipt_no; CLOSE c;

        -- CAN-15 first, on a second receipt of a second enquiry: before admission.
        DECLARE v_e2 integer; v_rr2 text; v_flag boolean;
        BEGIN
            c := NULL;
            CALL core.sp_enquiry_crm_manage(p_operation => 'SaveEnquiry', p_tenant_id => c_tenant, p_school_id => c_school,
                 p_action_user_id => c_user, p_student_name => 'ZZ Reg Cancel B', p_gender => 'Female',
                 p_dob => DATE '2016-03-03', p_class_name => v_cls, p_session => v_year, p_mobile => '9995552222',
                 p_lead_source => 'Walk-in', p_status => 'New', p_result => c);
            CLOSE c;
            SELECT enquiry_id INTO v_e2 FROM core.enquiries WHERE tenant_id = c_tenant AND school_id = c_school
               AND student_name = 'ZZ Reg Cancel B' ORDER BY enquiry_id DESC LIMIT 1;
            c := NULL;
            CALL core.sp_enquiry_register(p_tenant_id => c_tenant, p_school_id => c_school, p_action_user_id => c_user,
                 p_enquiry_id => v_e2, p_auto_generate => TRUE, p_result => c);
            CLOSE c;
            c := NULL;
            CALL core.sp_registration_fee_record(p_tenant_id => c_tenant, p_school_id => c_school, p_action_user_id => c_user,
                 p_enquiry_id => v_e2, p_amount => 500, p_payment_mode => 'Cash', p_payment_date => CURRENT_DATE,
                 p_fin_year => v_year, p_result => c);
            FETCH c INTO r; v_rr2 := r.receipt_no; CLOSE c;
            PERFORM pg_temp.cancel(v_rr2, 'wrong family');
            SELECT registration_fee_paid INTO v_flag FROM core.enquiries WHERE enquiry_id = v_e2;
            PERFORM pg_temp.chk('CAN-15 cancelled registration receipt clears the enquiry''s paid flag',
                                v_flag = FALSE, format('registration_fee_paid %s', v_flag));
        END;

        c := NULL;
        CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
             'ZZ-COL-REG', NULL, 'ZZ Reg Cancel A', 'Male', DATE '2016-02-02',
             v_cls, v_sec, v_year, v_start, p_enquiry_id => v_e,
             p_fee_plan_json => jsonb_build_array(
                 jsonb_build_object('feeHeadName','ZZ Tuition','frequency','Monthly','amount',1000)),
             p_result => c);
        CLOSE c;
        SELECT student_id INTO v_sid FROM core.students WHERE tenant_id = c_tenant AND school_id = c_school
           AND admission_no = 'ZZ-COL-REG';

        PERFORM pg_temp.cancel(v_rr, 'cash was counterfeit');
        SELECT COUNT(*), COALESCE(SUM(amount_due), 0) INTO v_n, v_dec FROM core.student_ledger
         WHERE student_id = v_sid AND installment_label = 'Reversed ' || v_rr AND amount_paid = 0;
        PERFORM pg_temp.chk('CAN-14 cancelled registration receipt after admission becomes a 500 due',
                            v_sid IS NOT NULL AND v_n = 1 AND v_dec = 500,
                            format('student %s, %s reversal due(s) of %s', v_sid, v_n, v_dec));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CAN-14 cancelled registration receipt after admission becomes a 500 due', FALSE, SQLERRM);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- CON. Concession / discount ---------------------------';

    -- CON-01: sibling concession, 300 flat across three months (oldest first).
    v_txt := pg_temp.collect(s2,
             jsonb_build_array(pg_temp.it(pg_temp.mon(s2,0),700,300), pg_temp.it(pg_temp.mon(s2,1),1000),
                               pg_temp.it(pg_temp.mon(s2,2),1000)),
             jsonb_build_array(jsonb_build_object('mode','Cash','amount',2700)), 0, '[]'::jsonb,
             'Flat', 300, 'Sibling concession', p_approver => 'Principal');
    SELECT amount, concession_total, discount_type, discount_value, discount_reason, discount_approved_by INTO r
      FROM core.fee_payments WHERE school_id = c_school AND receipt_no = v_txt;
    PERFORM pg_temp.chk('CON-01a receipt is cash only; concession and why are stored',
                        r.amount = 2700 AND r.concession_total = 300 AND r.discount_type = 'Flat'
                        AND r.discount_value = 300 AND r.discount_reason = 'Sibling concession',
                        format('%s / %s / %s %s / %s', r.amount, r.concession_total, r.discount_type, r.discount_value, r.discount_reason));
    PERFORM pg_temp.chk('CON-03 a concession records who approved it', r.discount_approved_by = 'Principal',
                        format('discount_approved_by %s', COALESCE(r.discount_approved_by, 'NULL')));
    SELECT concession, status INTO v_dec, v_txt2 FROM core.student_ledger WHERE ledger_id = pg_temp.mon(s2,0);
    PERFORM pg_temp.chk('CON-01b concession sits on the ledger row it waived', v_dec = 300 AND v_txt2 = 'Paid',
                        format('concession %s, %s', v_dec, v_txt2));
    c := NULL; c2 := NULL; v_n := 0;
    CALL core.sp_fee_concession_cancel_register(c_tenant, c_school, c_user, CURRENT_DATE, CURRENT_DATE, c, c2);
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
         IF r.receipt_no = v_txt AND r.discount_reason = 'Sibling concession' THEN v_n := v_n + 1; END IF;
    END LOOP;
    CLOSE c; CLOSE c2;
    PERFORM pg_temp.chk_eq('CON-01c the concession register lists it with its reason', v_n, 1);

    v_probe := NULL;
    BEGIN
        v_txt := pg_temp.collect(s2, jsonb_build_array(pg_temp.it(pg_temp.mon(s2,3),900,100)));
        SELECT concession_total, discount_reason INTO v_dec, v_txt2 FROM core.fee_payments WHERE school_id = c_school AND receipt_no = v_txt;
        v_probe := format('accepted: %s waived, reason %s', v_dec, COALESCE(v_txt2,'NULL'));
        RAISE EXCEPTION 'zz_undo';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'zz_undo' THEN PERFORM pg_temp.chk('CON-02 a concession without a reason is refused', FALSE, v_probe);
        ELSE PERFORM pg_temp.chk('CON-02 a concession without a reason is refused', TRUE, SQLERRM); END IF;
    END;

    v_txt := pg_temp.collect(s2, jsonb_build_array(pg_temp.it(pg_temp.mon(s2,4),0,1000)), NULL, 0, '[]'::jsonb,
                             'Flat', 1000, 'Fee waiver - hardship');
    SELECT p.amount, p.concession_total, (SELECT COUNT(*) FROM core.fee_payment_tenders t WHERE t.payment_id = p.payment_id)
      INTO v_dec, v_dec2, v_n FROM core.fee_payments p WHERE school_id = c_school AND receipt_no = v_txt;
    PERFORM pg_temp.chk('CON-04 a full waiver is still a receipt (0 cash, 1000 waived)',
                        v_dec = 0 AND v_dec2 = 1000 AND v_n = 0, format('cash %s, concession %s, %s tenders', v_dec, v_dec2, v_n));

    BEGIN
        PERFORM pg_temp.collect(s2, jsonb_build_array(pg_temp.it(pg_temp.mon(s2,5),0,1500)), NULL, 0, '[]'::jsonb,
                                'Flat', 1500, 'too much');
        PERFORM pg_temp.chk('CON-05 concession beyond the due refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CON-05 concession beyond the due refused', TRUE, SQLERRM);
    END;

    -- CON-06: the admission path never waives a refundable deposit; the counter does.
    v_probe := NULL;
    BEGIN
        v_txt := pg_temp.collect(s2, jsonb_build_array(pg_temp.it(pg_temp.head(s2,'ZZ Deposit'),1500,500)), NULL, 0,
                                 '[]'::jsonb, 'Flat', 500, 'sibling');
        SELECT concession INTO v_dec FROM core.student_ledger WHERE ledger_id = pg_temp.head(s2,'ZZ Deposit');
        v_probe := format('accepted: %s concession on a refundable deposit', v_dec);
        RAISE EXCEPTION 'zz_undo';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'zz_undo' THEN PERFORM pg_temp.chk('CON-06 no concession on a refundable deposit', FALSE, v_probe);
        ELSE PERFORM pg_temp.chk('CON-06 no concession on a refundable deposit', TRUE, SQLERRM); END IF;
    END;

    v_txt := pg_temp.collect(s2, jsonb_build_array(pg_temp.it(pg_temp.mon(s2,6),1000)), NULL, 0, '[]'::jsonb,
                             'Flat', 500, 'leftover');
    SELECT discount_type, discount_value INTO v_txt2, v_dec FROM core.fee_payments WHERE school_id = c_school AND receipt_no = v_txt;
    PERFORM pg_temp.chk('CON-07 no concession -> no phantom discount on the receipt', v_txt2 IS NULL AND v_dec = 0,
                        format('%s %s', COALESCE(v_txt2,'NULL'), v_dec));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- ADV. Advance wallet ----------------------------------';

    kA1 := pg_temp.collect(s3, jsonb_build_array(pg_temp.it(pg_temp.mon(s3,0),1000)),
                           jsonb_build_array(jsonb_build_object('mode','Cash','amount',2500)));
    SELECT advance_credit INTO v_dec FROM core.fee_payments WHERE school_id = c_school AND receipt_no = kA1;
    PERFORM pg_temp.chk('ADV-01 overpay 1500 -> credit on the receipt and in the wallet',
                        v_dec = 1500 AND pg_temp.wallet(s3) = 1500, format('credit %s, wallet %s', v_dec, pg_temp.wallet(s3)));

    v_txt := pg_temp.collect(s3, jsonb_build_array(pg_temp.it(pg_temp.mon(s3,1),1000)), NULL, 1000);
    SELECT p.payment_mode, p.advance_used, t.mode, t.amount INTO r
      FROM core.fee_payments p JOIN core.fee_payment_tenders t ON t.payment_id = p.payment_id
     WHERE p.school_id = c_school AND p.receipt_no = v_txt;
    PERFORM pg_temp.chk('ADV-02 next month from the wallet: Advance tender, wallet 500',
                        r.payment_mode = 'Advance' AND r.advance_used = 1000 AND r.mode = 'Advance' AND pg_temp.wallet(s3) = 500,
                        format('%s / used %s / tender %s %s / wallet %s', r.payment_mode, r.advance_used, r.mode, r.amount, pg_temp.wallet(s3)));

    BEGIN
        PERFORM pg_temp.collect(s3, jsonb_build_array(pg_temp.it(pg_temp.mon(s3,2),600)), NULL, 600);
        PERFORM pg_temp.chk('ADV-03 using more than the wallet holds refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('ADV-03 using more than the wallet holds refused', TRUE, SQLERRM);
    END;

    v_probe := NULL;
    BEGIN
        PERFORM pg_temp.collect(s3, jsonb_build_array(pg_temp.it(pg_temp.mon(s3,2),300)), NULL, 500);
        v_probe := format('accepted: a 300 bill took 500 from the wallet, now %s (should be 200)', pg_temp.wallet(s3));
        RAISE EXCEPTION 'zz_undo';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'zz_undo' THEN PERFORM pg_temp.chk('ADV-04 advance used beyond the bill is refused', FALSE, v_probe);
        ELSE PERFORM pg_temp.chk('ADV-04 advance used beyond the bill is refused', TRUE, SQLERRM); END IF;
    END;

    -- ADV-05 / DAY-03: 400 from the wallet + 600 cash.
    v_d0 := pg_temp.day('cash_collected');
    v_txt := pg_temp.collect(s3, jsonb_build_array(pg_temp.it(pg_temp.mon(s3,2),1000)),
                             jsonb_build_array(jsonb_build_object('mode','Cash','amount',600)), 400);
    SELECT string_agg(t.mode || ' ' || t.amount, ', ' ORDER BY t.mode) INTO v_txt2
      FROM core.fee_payment_tenders t JOIN core.fee_payments p ON p.payment_id = t.payment_id
     WHERE p.school_id = c_school AND p.receipt_no = v_txt;
    PERFORM pg_temp.chk('ADV-05 wallet + cash: both tenders recorded, wallet 100',
                        v_txt2 = 'Advance 400.00, Cash 600.00' AND pg_temp.wallet(s3) = 100,
                        format('%s, wallet %s', v_txt2, pg_temp.wallet(s3)));
    PERFORM pg_temp.chk_eq('DAY-03 day close counts only the 600 that was cash',
                           pg_temp.day('cash_collected') - v_d0, 600);

    SELECT COALESCE(SUM(advance_credit - advance_used), 0) INTO v_dec
      FROM core.fee_payments WHERE student_id = s3 AND NOT is_cancelled;
    PERFORM pg_temp.chk_eq('ADV-07 wallet = credits - uses over live receipts', pg_temp.wallet(s3), v_dec);

    -- ADV-06: cancel the overpayment whose credit has already been spent.
    v_probe := NULL;
    BEGIN
        v_ok := pg_temp.cancel(kA1, 'cheque bounced');
        v_probe := format('accepted (success %s): wallet now %s', v_ok, pg_temp.wallet(s3));
        IF v_ok AND pg_temp.wallet(s3) >= 0 THEN v_probe := 'ok:' || v_probe; END IF;
        RAISE EXCEPTION 'zz_undo';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'zz_undo' THEN
            PERFORM pg_temp.chk('ADV-06 cancelling spent credit cannot drive the wallet negative',
                                v_probe LIKE 'ok:%' OR v_probe LIKE 'accepted (success f)%', v_probe);
        ELSE PERFORM pg_temp.chk('ADV-06 cancelling spent credit cannot drive the wallet negative', TRUE, SQLERRM); END IF;
    END;

    SELECT COUNT(*) INTO v_n FROM pg_constraint
     WHERE conrelid = 'core.student_advance'::regclass AND contype = 'c'
       AND pg_get_constraintdef(oid) ILIKE '%balance%';
    PERFORM pg_temp.chk('ADV-08 database refuses a negative wallet (CHECK)', v_n > 0,
                        format('%s balance check constraint(s)', v_n));

    -- ADV-09: the wallet is offered for refund at exit, and can be refunded.
    c := NULL; v_n := 0; v_dec := NULL;
    CALL core.sp_student_refundables_get(c_tenant, c_school, c_user, s3, c);
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
         IF r.ledger_id IS NULL AND r.fee_head_name = 'Advance balance' THEN v_n := v_n + 1; v_dec := r.refundable; END IF;
    END LOOP;
    CLOSE c;
    PERFORM pg_temp.chk('ADV-09a refundables offer the wallet balance (100)', v_n = 1 AND v_dec = 100,
                        format('%s wallet row(s), refundable %s', v_n, v_dec));

    j := pg_temp.refund(s3, 0, 150, 'leaving - advance returned');
    PERFORM pg_temp.chk('ADV-09b refunding more than the wallet holds refused', NOT (j->>'success')::boolean, j->>'message');

    j := pg_temp.refund(s3, 0, 60, 'leaving - advance returned');
    SELECT ledger_id, amount, refund_mode, refunded_by INTO r FROM core.fee_refunds
     WHERE tenant_id = c_tenant AND school_id = c_school AND refund_no = j->>'refund_no';
    PERFORM pg_temp.chk('ADV-09c wallet refund: voucher with no ledger row, wallet 100 -> 40',
                        (j->>'success')::boolean AND r.ledger_id IS NULL AND r.amount = 60
                        AND r.refunded_by = c_user AND pg_temp.wallet(s3) = 40,
                        format('%s %s, wallet %s', j->>'refund_no', j->>'message', pg_temp.wallet(s3)));

    -- ADV-10: credits - uses - wallet refunds still explains the balance.
    SELECT COALESCE(SUM(advance_credit - advance_used), 0)
         - (SELECT COALESCE(SUM(amount), 0) FROM core.fee_refunds WHERE student_id = s3 AND ledger_id IS NULL)
      INTO v_dec FROM core.fee_payments WHERE student_id = s3 AND NOT is_cancelled;
    PERFORM pg_temp.chk_eq('ADV-10 wallet = credits - uses - wallet refunds', pg_temp.wallet(s3), v_dec);

    v_n := 0;
    c := NULL;
    CALL core.sp_fee_refund_history_get(c_tenant, c_school, c_user, s3, c);
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
         IF r.against = 'Advance balance' AND r.amount = 60 THEN v_n := v_n + 1; END IF;
    END LOOP;
    CLOSE c;
    PERFORM pg_temp.chk_eq('ADV-11 the wallet refund shows in the student''s refund history', v_n, 1);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- REF. Refund ------------------------------------------';

    kd := pg_temp.collect(s4, jsonb_build_array(pg_temp.it(pg_temp.head(s4,'ZZ Deposit'),2000)));
    kt := pg_temp.collect(s4, jsonb_build_array(pg_temp.it(pg_temp.mon(s4,0),1000)));

    c := NULL;
    CALL core.sp_student_refundables_get(c_tenant, c_school, c_user, s4, c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('REF-01 refundables: the deposit first, 2000, flagged refundable',
                        r.fee_head_name = 'ZZ Deposit' AND r.refundable = 2000 AND r.is_refundable,
                        format('%s %s %s', r.fee_head_name, r.refundable, r.is_refundable));

    j := pg_temp.refund(s4, pg_temp.head(s4,'ZZ Deposit'), 2500, 'TC issued');
    PERFORM pg_temp.chk('REF-02 refunding more than was paid refused', NOT (j->>'success')::boolean, j->>'message');

    BEGIN
        PERFORM pg_temp.refund(s4, pg_temp.head(s4,'ZZ Deposit'), 0, 'TC issued');
        PERFORM pg_temp.chk('REF-03a zero refund refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('REF-03a zero refund refused', TRUE, SQLERRM); END;
    BEGIN
        PERFORM pg_temp.refund(s4, pg_temp.head(s4,'ZZ Deposit'), -50, 'TC issued');
        PERFORM pg_temp.chk('REF-03b negative refund refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('REF-03b negative refund refused', TRUE, SQLERRM); END;
    BEGIN
        PERFORM pg_temp.refund(s4, pg_temp.head(s4,'ZZ Deposit'), 100, '  ');
        PERFORM pg_temp.chk('REF-03c refund without a reason refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('REF-03c refund without a reason refused', TRUE, SQLERRM); END;

    v_d0 := pg_temp.day('cash_refunded');
    j := pg_temp.refund(s4, pg_temp.head(s4,'ZZ Deposit'), 1500, 'TC issued - deposit returned');
    SELECT * INTO r FROM core.fee_refunds WHERE tenant_id = c_tenant AND school_id = c_school AND refund_no = j->>'refund_no';
    PERFORM pg_temp.chk('REF-04a voucher: number, amount, mode, reason, who, when, authoriser',
                        r.refund_no LIKE 'RFD-2026-%' AND r.amount = 1500 AND r.refund_mode = 'Cash'
                        AND r.reason = 'TC issued - deposit returned' AND r.refunded_by = c_user
                        AND r.refunded_at IS NOT NULL AND r.authorized_by = 'Principal' AND r.student_id = s4,
                        format('%s %s %s by %s', r.refund_no, r.amount, r.refund_mode, r.refunded_by));
    SELECT refund_amount INTO v_dec FROM core.student_ledger WHERE ledger_id = pg_temp.head(s4,'ZZ Deposit');
    PERFORM pg_temp.chk_eq('REF-04b the ledger row remembers what went back', v_dec, 1500);
    PERFORM pg_temp.chk_eq('REF-11 a cash refund comes off the day''s expected cash',
                           pg_temp.day('cash_refunded') - v_d0, 1500);

    j := pg_temp.refund(s4, pg_temp.head(s4,'ZZ Deposit'), 600, 'rest');
    PERFORM pg_temp.chk('REF-05a only the 500 still held can follow', NOT (j->>'success')::boolean, j->>'message');
    j := pg_temp.refund(s4, pg_temp.head(s4,'ZZ Deposit'), 500, 'rest of deposit');
    SELECT amount_paid - refund_amount INTO v_dec FROM core.student_ledger WHERE ledger_id = pg_temp.head(s4,'ZZ Deposit');
    PERFORM pg_temp.chk('REF-05b remaining 500 refunded, nothing left to refund',
                        (j->>'success')::boolean AND v_dec = 0, format('retained %s', v_dec));

    SELECT status, amount_due - amount_paid - concession INTO v_txt, v_dec FROM core.student_ledger
     WHERE ledger_id = pg_temp.head(s4,'ZZ Deposit');
    SELECT amount, is_cancelled INTO v_dec2, v_ok FROM core.fee_payments WHERE school_id = c_school AND receipt_no = kd;
    PERFORM pg_temp.chk('REF-06 refund neither re-opens the due nor rewrites the receipt',
                        v_txt = 'Paid' AND v_dec = 0 AND v_dec2 = 2000 AND NOT v_ok,
                        format('%s, owing %s, receipt %s, cancelled %s', v_txt, v_dec, v_dec2, v_ok));

    j := pg_temp.refund(s4, pg_temp.mon(s4,0), 100, 'x', 23, 33);
    PERFORM pg_temp.chk('REF-07a school 33 cannot refund our ledger row', NOT (j->>'success')::boolean, j->>'message');
    j := pg_temp.refund(s1, pg_temp.mon(s4,0), 100, 'x');
    PERFORM pg_temp.chk('REF-07b a refund under the wrong student refused', NOT (j->>'success')::boolean, j->>'message');

    v_probe := NULL;
    BEGIN
        j := pg_temp.refund(s4, pg_temp.mon(s4,0), 0.004, 'rounding');
        SELECT amount INTO v_dec FROM core.fee_refunds WHERE school_id = c_school AND refund_no = j->>'refund_no';
        v_probe := format('accepted (success %s): voucher %s for %s', j->>'success', j->>'refund_no', COALESCE(v_dec::text,'-'));
        RAISE EXCEPTION 'zz_undo';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'zz_undo' THEN
            PERFORM pg_temp.chk('REF-08 a sub-paisa refund (0.004) is refused', NOT (j->>'success')::boolean, v_probe);
        ELSE PERFORM pg_temp.chk('REF-08 a sub-paisa refund (0.004) is refused', TRUE, SQLERRM); END IF;
    END;

    -- REF-09: the deposit receipt is cancelled AFTER its money was refunded.
    v_probe := NULL;
    BEGIN
        v_ok := pg_temp.cancel(kd, 'entered twice');
        SELECT amount_paid, refund_amount INTO v_dec, v_dec2 FROM core.student_ledger WHERE ledger_id = pg_temp.head(s4,'ZZ Deposit');
        v_probe := format('cancel success %s: row now paid %s, refunded %s', v_ok, v_dec, v_dec2);
        RAISE EXCEPTION 'zz_undo';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'zz_undo' THEN
            PERFORM pg_temp.chk('REF-09 a refunded receipt cannot be cancelled', NOT v_ok, v_probe);
        ELSE PERFORM pg_temp.chk('REF-09 a refunded receipt cannot be cancelled', TRUE, SQLERRM); END IF;
    END;

    -- REF-10: the Payment History tab reads receipts AND refund vouchers.
    v_n := pg_temp.nrows('core.sp_fee_payment_history_get', c_tenant, c_school, s4)
         + pg_temp.nrows('core.sp_fee_refund_history_get', c_tenant, c_school, s4);
    SELECT (SELECT COUNT(*) FROM core.fee_payments WHERE student_id = s4)
         + (SELECT COUNT(*) FROM core.fee_refunds WHERE student_id = s4) INTO v_n2;
    j := pg_temp.row1('core.sp_fee_refund_history_get', c_tenant, c_school, s4);
    PERFORM pg_temp.chk('REF-10 student history shows refunds as well as receipts',
                        v_n = v_n2 AND j->>'against' LIKE 'ZZ Deposit%' AND NULLIF(j->>'refunded_by_name', '') IS NOT NULL
                        AND j->>'reason' IS NOT NULL AND j->>'authorized_by' = 'Principal',
                        format('history %s rows; %s receipts + refunds exist; latest %s against %s by %s',
                               v_n, v_n2, j->>'refund_no', j->>'against', j->>'refunded_by_name'));

    -- REF-14: voucher numbers are one gapless sequence for this school and year.
    SELECT COUNT(*), MAX(split_part(refund_no, '-', 3)::integer), MIN(split_part(refund_no, '-', 3)::integer)
      INTO v_n, v_n2, v_dec
      FROM core.fee_refunds WHERE tenant_id = c_tenant AND school_id = c_school AND refund_no LIKE 'RFD-2026-%';
    PERFORM pg_temp.chk('REF-14 refund vouchers RFD-2026-0001..N, gapless per school',
                        v_n > 0 AND v_dec = 1 AND v_n2 = v_n,
                        format('%s vouchers, numbers %s..%s', v_n, v_dec, v_n2));

    -- REF-12: a leaver still owes; the counter must still be able to take it.
    c := 'ex';
    CALL core.sp_student_exit('Exit', c_tenant, c_school, c_user, s4, 'Transfer', CURRENT_DATE, 'relocating', c);
    CLOSE c;
    BEGIN
        v_txt := pg_temp.collect(s4, jsonb_build_array(pg_temp.it(pg_temp.mon(s4,1),1000)));
        PERFORM pg_temp.chk('REF-12 dues of an exited student can still be collected', v_txt IS NOT NULL, v_txt);
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('REF-12 dues of an exited student can still be collected', FALSE, SQLERRM);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- DAY. Day close and the register agree with the till --';

    v_d0 := pg_temp.day('cash_collected');
    PERFORM pg_temp.collect(s5,
            jsonb_build_array(pg_temp.it(pg_temp.mon(s5,0),1000), pg_temp.it(pg_temp.mon(s5,1),1000),
                              pg_temp.it(pg_temp.mon(s5,2),1000)),
            jsonb_build_array(jsonb_build_object('mode','Cash','amount',2000),
                              jsonb_build_object('mode','UPI','amount',1000)));
    PERFORM pg_temp.chk_eq('DAY-01 the cash half of a Cash+UPI receipt is expected in the drawer',
                           pg_temp.day('cash_collected') - v_d0, 2000);

    v_d0 := pg_temp.day('cash_collected');
    kD2 := pg_temp.collect(s5, jsonb_build_array(pg_temp.it(pg_temp.mon(s5,3),1000)),
                           jsonb_build_array(jsonb_build_object('mode','Cash','amount',2500)));
    PERFORM pg_temp.chk_eq('DAY-02 all 2500 cash of an overpayment is expected in the drawer',
                           pg_temp.day('cash_collected') - v_d0, 2500);

    j := pg_temp.reg_modes();
    PERFORM pg_temp.chk('DAY-04 collection register splits by the true mode, not "Mixed"', NOT (j ? 'Mixed'),
                        j::text);

    v_d0 := pg_temp.day('total_collected');
    v_txt := pg_temp.collect(s5, jsonb_build_array(pg_temp.it(pg_temp.mon(s5,4),1000)));
    PERFORM pg_temp.cancel(v_txt, 'wrong student');
    PERFORM pg_temp.chk_eq('DAY-05 a cancelled receipt drops out of the day total', pg_temp.day('total_collected'), v_d0);

    -- DAY-06: closing the same day twice.
    c := NULL;
    CALL core.sp_fee_day_close(c_tenant, c_school, c_user, CURRENT_DATE, 100, 'first count', c); CLOSE c;
    -- A second close may be refused outright (that also keeps the first count).
    BEGIN
        c := NULL;
        CALL core.sp_fee_day_close(c_tenant, c_school, c_user, CURRENT_DATE, 200, 'recount', c); CLOSE c;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    SELECT COUNT(*) FILTER (WHERE counted_cash = 100), COUNT(*) INTO v_n, v_n2 FROM core.fee_day_close
     WHERE tenant_id = c_tenant AND school_id = c_school AND cashier_id = c_user AND close_date::date = CURRENT_DATE;
    PERFORM pg_temp.chk('DAY-06 a re-close keeps the first count on record', v_n > 0,
                        format('%s close row(s); the 100 first count survives in %s', v_n2, v_n));

    -- DAY-07: once this counter has closed today, it cannot keep collecting.
    v_probe := NULL;
    BEGIN
        v_txt := pg_temp.collect(s5, jsonb_build_array(pg_temp.it(pg_temp.mon(s5,6),1000)));
        v_probe := format('accepted: %s taken after the day was closed', v_txt);
        RAISE EXCEPTION 'zz_undo';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'zz_undo' THEN
            PERFORM pg_temp.chk('DAY-07 collecting after this counter closed today is refused', FALSE,
                                v_probe || CASE WHEN to_regprocedure('core.fn_fee_day_closed(integer,integer,integer,date)') IS NULL
                                                THEN ' (core.fn_fee_day_closed does not exist yet)' ELSE '' END);
        ELSE PERFORM pg_temp.chk('DAY-07 collecting after this counter closed today is refused',
                                 SQLERRM LIKE 'Today is already closed%', SQLERRM); END IF;
    END;

    -- CAN-12: a reversal belongs to the day it is made. The cashier whose today
    -- is closed cannot cancel or refund into it ...
    BEGIN
        PERFORM pg_temp.cancel(kD2, 'cheque bounced after close');
        PERFORM pg_temp.chk('CAN-12a a cashier whose today is closed cannot cancel', FALSE, 'it was cancelled');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CAN-12a a cashier whose today is closed cannot cancel', SQLERRM LIKE 'Today is already closed%', SQLERRM);
    END;
    BEGIN
        PERFORM pg_temp.refund(s4, pg_temp.mon(s4,0), 10, 'after close');
        PERFORM pg_temp.chk('CAN-12b ...nor refund', FALSE, 'it was refunded');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CAN-12b ...nor refund', SQLERRM LIKE 'Today is already closed%', SQLERRM);
    END;
    -- ... but another cashier with an open drawer can cancel the old receipt,
    -- and the reversal is stamped with that day and that user.
    BEGIN
        c := NULL;
        CALL core.sp_fee_receipt_cancel(c_tenant, c_school, 40, kD2, 'cheque bounced after close', 'Principal', c);
        FETCH c INTO r; CLOSE c;
        SELECT cancelled_at::date, cancelled_by INTO v_txt, v_n FROM core.fee_payments
         WHERE school_id = c_school AND receipt_no = kD2;
        PERFORM pg_temp.chk('CAN-12c another cashier can cancel it; stamped with the cancel day and user',
                            r.success AND v_txt::date = CURRENT_DATE AND v_n = 40,
                            format('success %s, cancelled_at %s by %s', r.success, v_txt, v_n));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CAN-12c another cashier can cancel it; stamped with the cancel day and user', FALSE, SQLERRM);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- SEC. Another school reads nothing --------------------';

    PERFORM pg_temp.chk_eq('SEC-01 school 33 sees none of our dues',
                           pg_temp.nrows('core.sp_student_dues_get', 23, 33, s1), 0);
    PERFORM pg_temp.chk_eq('SEC-02 school 33 sees none of our receipts',
                           pg_temp.nrows('core.sp_fee_payment_history_get', 23, 33, s1), 0);
    PERFORM pg_temp.chk_eq('SEC-03 school 33 sees no wallet balance',
                           (pg_temp.row1('core.sp_student_advance_get', 23, 33, s3)->>'balance')::numeric, 0);
    PERFORM pg_temp.chk_eq('SEC-04 school 33 sees nothing refundable',
                           pg_temp.nrows('core.sp_student_refundables_get', 23, 33, s4), 0);
    PERFORM pg_temp.chk_eq('SEC-05 school 33 sees none of our refund vouchers',
                           pg_temp.nrows('core.sp_fee_refund_history_get', 23, 33, s4), 0);
    j := pg_temp.refund(s3, 0, 10, 'x', 23, 33);
    PERFORM pg_temp.chk('SEC-06 school 33 cannot refund our student''s wallet',
                        NOT (j->>'success')::boolean AND pg_temp.wallet(s3) = 40, j->>'message');

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- TRL. Trail guarantees --------------------------------';

    SELECT string_agg(DISTINCT p.proname, ',') INTO v_txt
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND p.prokind IN ('p','f')
       AND p.proname <> 'sp_school_purge'
       AND pg_get_functiondef(p.oid) ~* 'delete\s+from\s+core\.(fee_payments|fee_payment_details|fee_payment_tenders|fee_refunds)\M';
    PERFORM pg_temp.chk('TRL-01 no routine (bar school purge) deletes receipts or refunds', v_txt IS NULL,
                        COALESCE(v_txt, 'none'));

    -- Receipt lines/tenders still cascade from their header on purpose (only
    -- sp_school_purge deletes a header, and relies on it). What must not
    -- cascade is a STUDENT delete wiping their ledger or wallet.
    SELECT string_agg(conrelid::regclass || '->' || confrelid::regclass, ', ') INTO v_txt FROM pg_constraint
     WHERE contype = 'f' AND confdeltype = 'c'
       AND conrelid IN ('core.student_ledger'::regclass, 'core.student_advance'::regclass);
    v_probe := NULL;
    BEGIN
        DELETE FROM core.students WHERE student_id = s3;
        v_probe := 'the student row was deleted';
        RAISE EXCEPTION 'zz_undo';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'zz_undo' THEN v_probe := v_probe; ELSE v_probe := 'refused: ' || SQLERRM; END IF;
    END;
    PERFORM pg_temp.chk('TRL-02 deleting a student cannot erase their ledger or wallet',
                        v_txt IS NULL AND v_probe LIKE 'refused:%',
                        'cascade: ' || COALESCE(v_txt, 'none') || '; ' || v_probe);

    v_probe := NULL;
    BEGIN
        UPDATE core.student_ledger SET amount_paid = amount_due + 1 WHERE ledger_id = pg_temp.mon(s1,11);
        v_probe := 'over-paid row written';
        RAISE EXCEPTION 'zz_undo';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'zz_undo' THEN v_probe := v_probe; ELSE v_probe := 'refused: ' || SQLERRM; END IF;
    END;
    PERFORM pg_temp.chk('TRL-03a the database refuses a row paid beyond its due', v_probe LIKE 'refused:%chk_student_ledger_amounts%', v_probe);

    v_probe := NULL;
    BEGIN
        UPDATE core.student_advance SET balance = -1 WHERE student_id = s3;
        v_probe := 'negative wallet written';
        RAISE EXCEPTION 'zz_undo';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'zz_undo' THEN v_probe := v_probe; ELSE v_probe := 'refused: ' || SQLERRM; END IF;
    END;
    PERFORM pg_temp.chk('TRL-03b the database refuses a negative wallet', v_probe LIKE 'refused:%chk_student_advance_balance%', v_probe);

    SELECT COUNT(*) INTO v_n FROM core.fee_payments p
     WHERE p.tenant_id = c_tenant AND p.school_id = c_school AND p.student_id IN (s1,s2,s3,s4,s5)
       AND p.amount <> (SELECT COALESCE(SUM(d.amount),0) FROM core.fee_payment_details d WHERE d.payment_id = p.payment_id);
    PERFORM pg_temp.chk_eq('TRL-04 every receipt header equals the sum of its lines', v_n, 0);

    SELECT COUNT(*) INTO v_n FROM (
        SELECT l.student_id
          FROM core.student_ledger l WHERE l.student_id IN (s1,s2,s3,s4,s5)
         GROUP BY l.student_id
        HAVING SUM(l.amount_paid) <> (SELECT COALESCE(SUM(d.amount),0) FROM core.fee_payment_details d
                                        JOIN core.fee_payments p ON p.payment_id = d.payment_id
                                       WHERE p.student_id = l.student_id AND NOT p.is_cancelled AND d.ledger_id IS NOT NULL)
            OR SUM(l.concession) <> (SELECT COALESCE(SUM(d.concession),0) FROM core.fee_payment_details d
                                       JOIN core.fee_payments p ON p.payment_id = d.payment_id
                                      WHERE p.student_id = l.student_id AND NOT p.is_cancelled AND d.ledger_id IS NOT NULL)) x;
    PERFORM pg_temp.chk_eq('TRL-05 ledger paid & concession = live receipt lines, every student', v_n, 0);

    SELECT COUNT(*) INTO v_n FROM core.fee_payments p
     WHERE p.student_id IN (s1,s2,s3,s4,s5) AND NOT p.is_cancelled
       AND (p.amount + p.advance_credit - p.advance_used) <>
           (SELECT COALESCE(SUM(v.amount),0) FROM core.v_fee_tender_lines v WHERE v.payment_id = p.payment_id AND v.mode <> 'Advance');
    PERFORM pg_temp.chk_eq('TRL-06 money in = tender lines, receipt by receipt', v_n, 0);

    SELECT COUNT(*) INTO v_n FROM core.fee_payments WHERE tenant_id = 23 AND school_id = 33;
    PERFORM pg_temp.chk_eq('TRL-07 nothing was written into school 33', v_n, v_x_pay);
END
$suite$;


DO $sum$
DECLARE p integer; f integer; b integer; r record;
BEGIN
    SELECT COUNT(*) FILTER (WHERE ok), COUNT(*) FILTER (WHERE NOT ok),
           COUNT(*) FILTER (WHERE NOT ok AND name LIKE 'BUG %') INTO p, f, b FROM _t;
    RAISE NOTICE '';
    RAISE NOTICE '========== RESULT: % passed, % failed (% of them BUG-marked) ==========', p, f, b;
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
