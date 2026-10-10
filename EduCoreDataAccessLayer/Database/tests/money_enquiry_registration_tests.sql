-- ============================================================================
-- MONEY HISTORY — Enquiry + Registration.
--
-- enquiry_registration_tests.sql proves the CRM works; money_trail_tests.sql
-- follows one fully-paid registration fee to TC. This suite goes after the
-- edges of the registration fee itself: part payments, discounts, the
-- "fee paid" flag, cancelling a receipt, withdrawing a registration,
-- re-registering, deleting the enquiry, and what admission does with the
-- money. The rule under test everywhere: every rupee taken, waived or reversed
-- leaves a durable record (who / when / how much / mode / receipt / for whom),
-- nothing is silently overwritten, and the reports agree.
--
-- Checks are named after the CORRECT behaviour. Ids in the catalog
-- educore/docs/test-cases/money_enquiry_registration.md. The first run found
-- 27 bugs. All are fixed (some in procs owned elsewhere: receipt cancel,
-- reports, admission) and every check now asserts the corrected behaviour.
--
-- An expected refusal is checked against the refusal MESSAGE, not just "it
-- raised", so a check cannot pass on an unrelated error.
--
-- Probes of a refusal that turns out NOT to happen are run inside a
-- subtransaction that is undone afterwards (sentinel '__undo__'), so a bug in
-- one check cannot poison the state the next check reads.
--
-- Runs inside ONE transaction and ROLLS BACK.
--
--     psql ... -f money_enquiry_registration_tests.sql
--
-- COVERS
--   A. Part payment: Rs 500 = 300 Cash + 200 UPI, receipts, reports
--   B. Discounts and waivers
--   C. The "registration fee paid" flag + cancelling a receipt
--   D. Withdrawing a registration, and re-registering
--   E. Deleting an enquiry that holds money
--   F. Admission: carried balance, double charge, post-admission cancel
--   G. Scope, validation, receipt numbering
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
    PERFORM pg_temp.chk(p_name, p_got IS NOT DISTINCT FROM p_want,
                        format('got %s, expected %s', COALESCE(p_got::text,'NULL'), p_want));
END $$;

-- ── fixture helpers ─────────────────────────────────────────────────────────
-- Create an enquiry and register it (auto number). Returns enquiry_id.
CREATE OR REPLACE FUNCTION pg_temp.mk_enq(p_name text, p_class text, p_year text, p_register boolean DEFAULT TRUE)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'mk_c'; v_eid integer;
BEGIN
    CALL core.sp_enquiry_crm_manage(
         p_operation => 'SaveEnquiry', p_tenant_id => 24, p_school_id => 34,
         p_action_user_id => 39, p_student_name => p_name, p_gender => 'Male',
         p_dob => DATE '2018-05-05', p_class_name => p_class, p_session => p_year,
         p_parent_name => 'ZZ Parent', p_mobile => '9990001111',
         p_lead_source => 'Walk-in', p_status => 'New', p_result => c);
    CLOSE c;
    SELECT enquiry_id INTO v_eid FROM core.enquiries
     WHERE tenant_id = 24 AND school_id = 34 AND student_name = p_name
     ORDER BY enquiry_id DESC LIMIT 1;
    IF p_register THEN
        c := 'mk_r';
        CALL core.sp_enquiry_register(p_tenant_id => 24, p_school_id => 34, p_action_user_id => 39,
             p_enquiry_id => v_eid, p_auto_generate => TRUE, p_result => c);
        CLOSE c;
    END IF;
    RETURN v_eid;
END $$;

-- Record a registration payment. Raises whatever the proc raises.
CREATE OR REPLACE FUNCTION pg_temp.pay(p_eid integer, p_amt numeric, p_mode text, p_fee numeric,
                                       p_disc numeric DEFAULT 0, p_dtype text DEFAULT NULL,
                                       p_dreason text DEFAULT NULL, p_ref text DEFAULT NULL,
                                       p_date date DEFAULT NULL, p_t integer DEFAULT 24, p_s integer DEFAULT 34)
RETURNS varchar LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'pay_c'; r record; v_fy varchar;
BEGIN
    SELECT session INTO v_fy FROM core.enquiries WHERE enquiry_id = p_eid;
    CALL core.sp_registration_fee_record(
         p_tenant_id => p_t, p_school_id => p_s, p_action_user_id => 39,
         p_enquiry_id => p_eid, p_amount => p_amt, p_payment_mode => p_mode,
         p_reference_no => p_ref, p_remarks => 'Registration fee', p_payment_date => p_date,
         p_fin_year => v_fy,
         p_discount_amount => p_disc, p_discount_type => p_dtype, p_discount_reason => p_dreason,
         p_fee_amount => p_fee, p_result => c);
    FETCH c INTO r;
    CLOSE c;
    RETURN r.receipt_no;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.bal(p_eid integer) RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'bal_c'; r record;
BEGIN
    CALL core.sp_registration_fee_summary(24, 34, p_eid, c);
    FETCH c INTO r; CLOSE c;
    RETURN r.balance_amount;
END $$;

-- What every screen shows: paid, derived from the money.
CREATE OR REPLACE FUNCTION pg_temp.flag(p_eid integer) RETURNS boolean LANGUAGE sql AS $$
    SELECT COALESCE(core.fn_registration_fee_is_paid(24, 34, p_eid), FALSE);
$$;

-- The stored column, now only a cache kept in step where it is written.
CREATE OR REPLACE FUNCTION pg_temp.cached(p_eid integer) RETURNS boolean LANGUAGE sql AS $$
    SELECT COALESCE(registration_fee_paid, FALSE) FROM core.enquiries WHERE enquiry_id = p_eid;
$$;

CREATE OR REPLACE FUNCTION pg_temp.live_rcpts(p_eid integer) RETURNS integer LANGUAGE sql AS $$
    SELECT COUNT(*)::int FROM core.fee_payments
     WHERE enquiry_id = p_eid AND payment_type = 'Registration' AND is_cancelled = FALSE;
$$;

-- Collection register (today): amount by mode / by head / receipt present.
CREATE OR REPLACE FUNCTION pg_temp.reg_mode(p_mode text) RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := 'cr_r'; c2 refcursor := 'cr_m'; c3 refcursor := 'cr_h'; r record; v numeric := 0;
BEGIN
    CALL core.sp_fee_collection_register(p_tenant_id => 24, p_school_id => 34, p_action_user_id => 39,
         p_from => CURRENT_DATE, p_to => CURRENT_DATE, p_receipts => c1, p_modes => c2, p_heads => c3);
    LOOP FETCH c2 INTO r; EXIT WHEN NOT FOUND;
        IF r.payment_mode = p_mode THEN v := v + r.amount; END IF; END LOOP;
    CLOSE c1; CLOSE c2; CLOSE c3;
    RETURN v;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.reg_head(p_head text) RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := 'cr_r'; c2 refcursor := 'cr_m'; c3 refcursor := 'cr_h'; r record; v numeric := 0;
BEGIN
    CALL core.sp_fee_collection_register(p_tenant_id => 24, p_school_id => 34, p_action_user_id => 39,
         p_from => CURRENT_DATE, p_to => CURRENT_DATE, p_receipts => c1, p_modes => c2, p_heads => c3);
    LOOP FETCH c3 INTO r; EXIT WHEN NOT FOUND;
        IF r.fee_head_name = p_head THEN v := v + r.amount; END IF; END LOOP;
    CLOSE c1; CLOSE c2; CLOSE c3;
    RETURN v;
END $$;

-- Returns the register's RECEIPT line for a receipt as jsonb (NULL when not
-- listed). The register also shows a cancellation as its own negative line.
CREATE OR REPLACE FUNCTION pg_temp.reg_row(p_rcpt text, p_t integer DEFAULT 24, p_s integer DEFAULT 34)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := 'cr_r'; c2 refcursor := 'cr_m'; c3 refcursor := 'cr_h'; r record; v jsonb;
BEGIN
    CALL core.sp_fee_collection_register(p_tenant_id => p_t, p_school_id => p_s, p_action_user_id => 39,
         p_from => CURRENT_DATE, p_to => CURRENT_DATE, p_receipts => c1, p_modes => c2, p_heads => c3);
    LOOP FETCH c1 INTO r; EXIT WHEN NOT FOUND;
        IF r.receipt_no = p_rcpt AND COALESCE(to_jsonb(r)->>'entry', 'Receipt') = 'Receipt' THEN v := to_jsonb(r); END IF; END LOOP;
    CLOSE c1; CLOSE c2; CLOSE c3;
    RETURN v;
END $$;

-- Net amount the register shows for a receipt today (receipt + cancellation lines).
CREATE OR REPLACE FUNCTION pg_temp.reg_net(p_rcpt text) RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := 'cr_r'; c2 refcursor := 'cr_m'; c3 refcursor := 'cr_h'; r record; v numeric := 0; k integer := 0;
BEGIN
    CALL core.sp_fee_collection_register(p_tenant_id => 24, p_school_id => 34, p_action_user_id => 39,
         p_from => CURRENT_DATE, p_to => CURRENT_DATE, p_receipts => c1, p_modes => c2, p_heads => c3);
    LOOP FETCH c1 INTO r; EXIT WHEN NOT FOUND;
        IF r.receipt_no = p_rcpt THEN v := v + r.amount; k := k + 1; END IF; END LOOP;
    CLOSE c1; CLOSE c2; CLOSE c3;
    RETURN CASE WHEN k = 0 THEN NULL ELSE v END;
END $$;

-- Day collection (this cashier, today): one summary field.
CREATE OR REPLACE FUNCTION pg_temp.day(p_field text) RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := 'dc_s'; c2 refcursor := 'dc_m'; c3 refcursor := 'dc_h'; r record;
BEGIN
    CALL core.sp_fee_day_collection_get(p_tenant_id => 24, p_school_id => 34, p_action_user_id => 39,
         p_date => CURRENT_DATE, p_summary => c1, p_modes => c2, p_history => c3);
    FETCH c1 INTO r;
    CLOSE c1; CLOSE c2; CLOSE c3;
    RETURN (to_jsonb(r) ->> p_field)::numeric;
END $$;

-- Concessions & Cancellations register: is the receipt listed in the given tab?
CREATE OR REPLACE FUNCTION pg_temp.cc_has(p_rcpt text, p_tab text) RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := 'cc_c'; c2 refcursor := 'cc_x'; r record; v boolean := FALSE;
BEGIN
    CALL core.sp_fee_concession_cancel_register(24, 34, 39, CURRENT_DATE, CURRENT_DATE, c1, c2);
    IF p_tab = 'concessions' THEN
        LOOP FETCH c1 INTO r; EXIT WHEN NOT FOUND; IF r.receipt_no = p_rcpt THEN v := TRUE; END IF; END LOOP;
    ELSE
        LOOP FETCH c2 INTO r; EXIT WHEN NOT FOUND; IF r.receipt_no = p_rcpt THEN v := TRUE; END IF; END LOOP;
    END IF;
    CLOSE c1; CLOSE c2;
    RETURN v;
END $$;

-- Registration list: the row for an enquiry as jsonb (NULL when not listed).
CREATE OR REPLACE FUNCTION pg_temp.reglist(p_eid integer) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'rl_c'; r record; v jsonb;
BEGIN
    CALL core.sp_registration_manage(p_operation => 'List', p_tenant_id => 24, p_school_id => 34,
         p_action_user_id => 39, p_page => 1, p_page_size => 5000, p_result => c);
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
        IF r.enquiry_id = p_eid THEN v := to_jsonb(r); END IF; END LOOP;
    CLOSE c;
    RETURN v;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.ctx(p_rcpt text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'cx_c'; r record;
BEGIN
    CALL core.sp_registration_receipt_context(24, 34, p_rcpt, c);
    FETCH c INTO r; CLOSE c;
    RETURN to_jsonb(r);
END $$;

CREATE OR REPLACE FUNCTION pg_temp.seq(p_rcpt text) RETURNS integer LANGUAGE sql AS $$
    SELECT split_part(p_rcpt, '-', 3)::int;
$$;


DO $suite$
DECLARE
    c_tenant CONSTANT integer := 24;
    c_school CONSTANT integer := 34;
    c_user   CONSTANT integer := 39;

    v_year  varchar; v_yearid integer; v_start date;
    v_cls   varchar; v_sec varchar;

    c   refcursor; c2 refcursor;
    r   record;
    j   jsonb;
    v_eid integer; v_e2 integer; v_e3 integer; v_e4 integer; v_e5 integer; v_e6 integer;
    v_sid integer; v_lid integer;
    v_r1 varchar; v_r2 varchar; v_r3 varchar;
    v_n integer; v_n2 integer;
    v_dec numeric; v_dec2 numeric;
    v_txt text;
    v_ok boolean; v_det text;

    b_cash numeric; b_upi numeric; b_head numeric; b_daycash numeric; b_daytot numeric; b_daycxl numeric;

    k_ok boolean; k_msg text; k_rcpt varchar; k_amt numeric;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '========= MONEY HISTORY: ENQUIRY + REGISTRATION =========';

    SELECT academic_year_id, academic_year_name, start_date INTO v_yearid, v_year, v_start
      FROM academic.academic_years
     WHERE tenant_id = c_tenant AND school_id = c_school AND COALESCE(is_current, FALSE) LIMIT 1;

    SELECT ac.class_name, s.section_name INTO v_cls, v_sec
      FROM academic.academic_classes ac
      JOIN academic.academic_class_sections s ON s.academic_class_id = ac.academic_class_id
     WHERE ac.tenant_id = c_tenant AND ac.school_id = c_school AND ac.academic_year_id = v_yearid
       AND COALESCE(ac.is_deleted, FALSE) = FALSE AND COALESCE(s.is_deleted, FALSE) = FALSE
     ORDER BY ac.display_order LIMIT 1;

    IF v_year IS NULL OR v_cls IS NULL THEN
        RAISE EXCEPTION 'Fixture missing: school % has no current session / class with a section.', c_school;
    END IF;
    RAISE NOTICE 'fixture: session=%  class=%  section=%', v_year, v_cls, v_sec;

    -- One Registration-point fee head, so admission names a carried balance by it.
    INSERT INTO core.school_fee_heads (tenant_id, school_id, fee_head_name, frequency, default_amount,
                                       fee_type, created_by, collection_point)
    VALUES (c_tenant, c_school, 'ZZ Reg Charges', 'One Time', 500, 'Mandatory', c_user, 'Registration');

    -- Report baselines (deltas, so other data on the day cannot skew them).
    b_cash := pg_temp.reg_mode('Cash');  b_upi := pg_temp.reg_mode('UPI');
    -- Registration money is reported under the school's own Registration head.
    b_head := pg_temp.reg_head(core.fn_registration_fee_head_name(c_tenant, c_school));
    b_daycash := pg_temp.day('cash_collected'); b_daytot := pg_temp.day('total_collected');

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- A. Part payment: 500 = 300 Cash + 200 UPI ---------------------';

    v_eid := pg_temp.mk_enq('ZZ Aarav Money', v_cls, v_year);

    c := 'a1';
    CALL core.sp_registration_fee_record(
         p_tenant_id => c_tenant, p_school_id => c_school, p_action_user_id => c_user,
         p_enquiry_id => v_eid, p_amount => 300, p_payment_mode => 'Cash',
         p_remarks => 'Registration fee', p_fin_year => v_year, p_fee_amount => 500, p_result => c);
    FETCH c INTO r; CLOSE c;
    v_r1 := r.receipt_no;
    PERFORM pg_temp.chk('A1 part payment of 300 accepted', r.success, r.message);
    PERFORM pg_temp.chk_eq('A2 balance 200 reported back', r.balance_amount, 200);
    PERFORM pg_temp.chk('A3 message tells the counter what is outstanding',
                        r.message ILIKE '%outstanding%', r.message);
    PERFORM pg_temp.chk('A4 not flagged paid while 200 is owed', NOT pg_temp.flag(v_eid), '');
    SELECT registration_fee_amount INTO v_dec FROM core.enquiries WHERE enquiry_id = v_eid;
    PERFORM pg_temp.chk_eq('A5 agreed fee frozen on the enquiry', v_dec, 500);

    SELECT * INTO r FROM core.fee_payments WHERE receipt_no = v_r1 AND tenant_id = c_tenant;
    PERFORM pg_temp.chk('A6 receipt records who/when/mode/amount/for whom',
                        r.created_by = c_user AND r.payment_mode = 'Cash' AND r.amount = 300
                        AND r.payment_type = 'Registration' AND r.enquiry_id = v_eid
                        AND r.payment_date = to_char(CURRENT_DATE,'YYYY-MM-DD') AND r.created_at IS NOT NULL,
                        format('by %s, %s %s on %s', r.created_by, r.payment_mode, r.amount, r.payment_date));

    BEGIN
        PERFORM pg_temp.pay(v_eid, 201, 'UPI', 500);
        PERFORM pg_temp.chk('A7 more than the balance is refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('A7 more than the balance is refused', TRUE, SQLERRM);
    END;

    v_r2 := pg_temp.pay(v_eid, 200, 'UPI', 500, p_ref => 'UPI-REF-1');
    PERFORM pg_temp.chk_eq('A8 refused payment burned no receipt number (consecutive)',
                           pg_temp.seq(v_r2), pg_temp.seq(v_r1) + 1);
    PERFORM pg_temp.chk_eq('A9 balance cleared', pg_temp.bal(v_eid), 0);
    PERFORM pg_temp.chk('A10 flagged paid once nothing is owed', pg_temp.flag(v_eid), '');
    SELECT reference_no, payment_mode INTO v_txt, k_msg FROM core.fee_payments WHERE receipt_no = v_r2 AND tenant_id = c_tenant;
    PERFORM pg_temp.chk('A11 UPI receipt keeps its mode and reference',
                        v_txt = 'UPI-REF-1' AND k_msg = 'UPI', format('%s / %s', k_msg, v_txt));
    PERFORM pg_temp.chk_eq('A12 both receipts stay live (nothing overwritten)', pg_temp.live_rcpts(v_eid), 2);

    BEGIN
        PERFORM pg_temp.pay(v_eid, 100, 'Cash', 600);
        PERFORM pg_temp.chk('A13 a settled fee is not re-opened by a higher fee figure', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('A13 a settled fee is not re-opened by a higher fee figure', TRUE, SQLERRM);
    END;

    j := pg_temp.ctx(v_r1);
    PERFORM pg_temp.chk('A14 first receipt prints: before 0, this 300, left 200',
                        (j->>'paid_before')::numeric = 0 AND (j->>'this_receipt')::numeric = 300
                        AND (j->>'balance_after')::numeric = 200, j::text);
    j := pg_temp.ctx(v_r2);
    PERFORM pg_temp.chk('A15 second receipt prints: before 300, this 200, left 0',
                        (j->>'paid_before')::numeric = 300 AND (j->>'this_receipt')::numeric = 200
                        AND (j->>'balance_after')::numeric = 0, j::text);

    c := 'a16'; c2 := 'a16l';
    CALL core.sp_fee_receipt_get(c_tenant, c_school, c_user, v_r1, c, c2);
    FETCH c INTO r; CLOSE c; CLOSE c2;
    PERFORM pg_temp.chk('A16 receipt reprints for the enquiry (name, enquiry id)',
                        r.student_name = 'ZZ Aarav Money' AND r.enquiry_id = v_eid, r.student_name);

    PERFORM pg_temp.chk('A17 both receipts in the Collection Register',
                        pg_temp.reg_row(v_r1) IS NOT NULL AND pg_temp.reg_row(v_r2) IS NOT NULL, '');
    PERFORM pg_temp.chk_eq('A18 register by mode: Cash +300', pg_temp.reg_mode('Cash') - b_cash, 300);
    PERFORM pg_temp.chk_eq('A19 register by mode: UPI +200',  pg_temp.reg_mode('UPI')  - b_upi, 200);
    PERFORM pg_temp.chk_eq('A20 register by head: the Registration head +500',
                           pg_temp.reg_head(core.fn_registration_fee_head_name(c_tenant, c_school)) - b_head, 500);
    PERFORM pg_temp.chk_eq('A21 day close: cash +300', pg_temp.day('cash_collected') - b_daycash, 300);
    PERFORM pg_temp.chk_eq('A22 day close: total +500', pg_temp.day('total_collected') - b_daytot, 500);

    -- The Registration list is the only place a pre-admission receipt can be
    -- reprinted, and it exposes ONE receipt_no (LIMIT 1, newest).
    j := pg_temp.reglist(v_eid);
    PERFORM pg_temp.chk('A23 every part-payment receipt reachable from Registration list',
                        jsonb_array_length(j->'receipts') = 2
                        AND (j->'receipts') @> jsonb_build_array(jsonb_build_object('receiptNo', v_r1))
                        AND (j->'receipts') @> jsonb_build_array(jsonb_build_object('receiptNo', v_r2)),
                        format('list receipts: %s', j->'receipts'));
    PERFORM pg_temp.chk('A24 list shows fee / settled / balance from the receipts',
                        (j->>'fee_amount')::numeric = 500 AND (j->>'settled_amount')::numeric = 500
                        AND (j->>'balance_amount')::numeric = 0 AND (j->>'registration_fee_paid')::boolean,
                        format('%s / %s / %s', j->>'fee_amount', j->>'settled_amount', j->>'balance_amount'));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- B. Discounts and waivers -------------------------------------';

    v_e2 := pg_temp.mk_enq('ZZ Discount Kid', v_cls, v_year);
    v_r3 := pg_temp.pay(v_e2, 400, 'Cash', 500, 100, 'Fixed', 'Sibling discount');
    SELECT * INTO r FROM core.fee_payments WHERE receipt_no = v_r3 AND tenant_id = c_tenant;
    PERFORM pg_temp.chk('B1 400 cash + 100 discount settles 500',
                        pg_temp.bal(v_e2) = 0 AND pg_temp.flag(v_e2), format('balance %s', pg_temp.bal(v_e2)));
    PERFORM pg_temp.chk('B2 discount amount, type and reason stored',
                        r.discount_amount = 100 AND r.discount_type = 'Fixed' AND r.discount_reason = 'Sibling discount',
                        format('%s %s "%s"', r.discount_type, r.discount_amount, r.discount_reason));
    PERFORM pg_temp.chk_eq('B3 receipt amount is the cash only', r.amount, 400);
    PERFORM pg_temp.chk_eq('B4 Collection Register shows the 100 discount',
                           (pg_temp.reg_row(v_r3)->>'discount_total')::numeric, 100);
    PERFORM pg_temp.chk('B5 registration discount listed in Concessions report',
                        pg_temp.cc_has(v_r3, 'concessions'),
                        format('discount %s', r.discount_amount));

    c := 'b6'; c2 := 'b6l';
    CALL core.sp_fee_receipt_get(c_tenant, c_school, c_user, v_r3, c, c2);
    FETCH c INTO r; CLOSE c; CLOSE c2;
    j := to_jsonb(r);
    PERFORM pg_temp.chk('B6 printed receipt carries the discount amount',
                        (j ? 'discount_amount') OR COALESCE((j->>'concession_total')::numeric,0) = 100,
                        format('discount_amount=%s concession_total=%s', j->>'discount_amount', j->>'concession_total'));
    j := pg_temp.ctx(v_r3);
    PERFORM pg_temp.chk_eq('B7 "Paid on this receipt" is the cash, not cash+discount',
                           (j->>'this_receipt')::numeric, 400);
    PERFORM pg_temp.chk_eq('B7b ...and the discount comes back on its own',
                           (j->>'this_discount')::numeric, 100);
    SELECT discount_value INTO v_dec FROM core.fee_payments
     WHERE enquiry_id = v_e2 AND tenant_id = c_tenant AND discount_amount > 0;
    PERFORM pg_temp.chk_eq('B7c a Fixed discount records its value', v_dec, 100);

    -- A discount without a reason: the controller checks, the proc does not.
    v_e3 := pg_temp.mk_enq('ZZ NoReason Kid', v_cls, v_year);
    BEGIN
        PERFORM pg_temp.pay(v_e3, 400, 'Cash', 500, 100, 'Fixed', NULL);
        PERFORM pg_temp.chk('B8 proc refuses a discount with no reason', FALSE, 'accepted with no reason');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('B8 proc refuses a discount with no reason', SQLERRM ILIKE '%reason%', SQLERRM);
    END;

    -- 100% waiver: a zero-cash receipt still exists, so the waiver is on record.
    v_r3 := pg_temp.pay(v_e3, 0, 'Cash', 500, 500, 'Percentage', 'Staff ward');
    SELECT amount, discount_amount INTO v_dec, v_dec2 FROM core.fee_payments WHERE receipt_no = v_r3 AND tenant_id = c_tenant;
    PERFORM pg_temp.chk('B9 full waiver leaves a 0-cash receipt with 500 discount',
                        v_dec = 0 AND v_dec2 = 500 AND pg_temp.flag(v_e3), format('cash %s disc %s', v_dec, v_dec2));
    SELECT discount_value, discount_type INTO v_dec, v_txt FROM core.fee_payments WHERE receipt_no = v_r3 AND tenant_id = c_tenant;
    PERFORM pg_temp.chk('B10 a percentage discount records the percentage',
                        v_dec = 100 AND v_txt = 'Percentage', format('%s %s', v_txt, v_dec));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- C. The fee-paid flag, and cancelling a receipt ----------------';

    -- C1: the old MarkFeePaid operation (set the flag, receipt maybe later) is gone.
    v_e4 := pg_temp.mk_enq('ZZ Flag Kid', v_cls, v_year);
    BEGIN
        c := 'c1';
        CALL core.sp_registration_manage(p_operation => 'MarkFeePaid', p_tenant_id => c_tenant,
             p_school_id => c_school, p_action_user_id => c_user, p_enquiry_id => v_e4, p_result => c);
        PERFORM pg_temp.chk('C1 nothing can mark a fee paid without a receipt (MarkFeePaid gone)', FALSE,
                            format('accepted: flag=%s cached=%s', pg_temp.flag(v_e4), pg_temp.cached(v_e4)));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C1 nothing can mark a fee paid without a receipt (MarkFeePaid gone)',
                            SQLERRM ILIKE '%Invalid operation%' AND NOT pg_temp.flag(v_e4) AND NOT pg_temp.cached(v_e4), SQLERRM);
    END;

    -- C2: a refused collect leaves the flag where the money is.
    PERFORM pg_temp.pay(v_e4, 300, 'Cash', 500);
    BEGIN
        PERFORM pg_temp.pay(v_e4, 300, 'Cash', 500);   -- only 200 owed: refused
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    PERFORM pg_temp.chk('C2 flag agrees with balance after a refused collect',
                        NOT pg_temp.flag(v_e4) AND NOT pg_temp.cached(v_e4) AND pg_temp.bal(v_e4) = 200,
                        format('flag=%s cached=%s balance=%s', pg_temp.flag(v_e4), pg_temp.cached(v_e4), pg_temp.bal(v_e4)));

    -- C3: the browser's "fee paid" tick is ignored by sp_enquiry_register.
    v_e5 := pg_temp.mk_enq('ZZ Trust Kid', v_cls, v_year, FALSE);
    c := 'c3';
    CALL core.sp_enquiry_register(p_tenant_id => c_tenant, p_school_id => c_school, p_action_user_id => c_user,
         p_enquiry_id => v_e5, p_registration_fee_paid => TRUE, p_auto_generate => TRUE, p_result => c);
    CLOSE c;
    PERFORM pg_temp.chk('C3 register does not flag paid without a receipt',
                        NOT pg_temp.flag(v_e5) AND NOT pg_temp.cached(v_e5),
                        format('flag=%s cached=%s receipts=%s', pg_temp.flag(v_e5), pg_temp.cached(v_e5), pg_temp.live_rcpts(v_e5)));
    -- Even a stale stored flag (old data) does not make a screen say Paid.
    UPDATE core.enquiries SET registration_fee_paid = TRUE WHERE enquiry_id = v_e5;
    PERFORM pg_temp.chk('C3b a stale stored flag is not what the screens read',
                        NOT COALESCE((pg_temp.reglist(v_e5)->>'registration_fee_paid')::boolean, TRUE), '');
    UPDATE core.enquiries SET registration_fee_paid = FALSE WHERE enquiry_id = v_e5;

    -- Cancel a registration receipt (pre-admission).
    v_e6 := pg_temp.mk_enq('ZZ Cancel Kid', v_cls, v_year);
    v_r1 := pg_temp.pay(v_e6, 500, 'Cash', 500);
    b_daycxl := pg_temp.day('cancelled_count');
    c := 'c4';
    CALL core.sp_fee_receipt_cancel(c_tenant, c_school, c_user, v_r1, 'Wrong child', 'Principal', c);
    FETCH c INTO k_ok, k_msg, k_rcpt; CLOSE c;
    PERFORM pg_temp.chk('C4 registration receipt can be cancelled', k_ok, k_msg);
    SELECT * INTO r FROM core.fee_payments WHERE receipt_no = v_r1 AND tenant_id = c_tenant;
    PERFORM pg_temp.chk('C5 cancelled receipt kept with reason/authoriser/who/when',
                        r.is_cancelled AND r.cancel_reason = 'Wrong child' AND r.cancel_authorized_by = 'Principal'
                        AND r.cancelled_by = c_user AND r.cancelled_at IS NOT NULL AND r.amount = 500, '');
    PERFORM pg_temp.chk_eq('C6 balance back to 500', pg_temp.bal(v_e6), 500);
    PERFORM pg_temp.chk('C6b not paid once the paying receipt is cancelled',
                        NOT pg_temp.flag(v_e6), format('flag=%s, balance=%s', pg_temp.flag(v_e6), pg_temp.bal(v_e6)));
    PERFORM pg_temp.chk('C6c stored flag cache cleared by the cancel (fee_receipt_cancel.sql)',
                        NOT pg_temp.cached(v_e6), format('cached=%s', pg_temp.cached(v_e6)));
    j := pg_temp.reglist(v_e6);
    PERFORM pg_temp.chk('C6d Registration list does not say Paid with no live receipt',
                        NOT COALESCE((j->>'registration_fee_paid')::boolean, FALSE),
                        format('list: paid=%s receipt=%s', j->>'registration_fee_paid', COALESCE(j->>'receipt_no','none')));
    PERFORM pg_temp.chk_eq('C7 cancelled receipt nets to 0 in the Collection Register (+ and - lines)',
                           pg_temp.reg_net(v_r1), 0);
    PERFORM pg_temp.chk('C8 cancelled receipt in the Cancellations report', pg_temp.cc_has(v_r1, 'cancels'), '');
    PERFORM pg_temp.chk_eq('C9 day close counts the cancellation', pg_temp.day('cancelled_count') - b_daycxl, 1);
    v_r2 := pg_temp.pay(v_e6, 500, 'Cash', 500);
    PERFORM pg_temp.chk('C10 re-collection gets a NEW receipt number', v_r2 <> v_r1, format('%s -> %s', v_r1, v_r2));
    c := 'c11';
    CALL core.sp_fee_receipt_cancel(c_tenant, c_school, c_user, v_r1, 'again', NULL, c);
    FETCH c INTO k_ok, k_msg, k_rcpt; CLOSE c;
    PERFORM pg_temp.chk('C11 a cancelled receipt cannot be cancelled twice', NOT k_ok, k_msg);
    BEGIN
        c := 'c12';
        CALL core.sp_fee_receipt_cancel(c_tenant, c_school, c_user, v_r2, '  ', NULL, c);
        PERFORM pg_temp.chk('C12 cancel without a reason refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C12 cancel without a reason refused', TRUE, SQLERRM);
    END;

    -- C13: a printed receipt states the balance AS OF itself. Pay 300 then 200,
    -- then cancel the 300 "next week": the 200 slip must still read
    -- "received earlier 300, balance 0" -- it was true when it was handed over.
    v_e3 := pg_temp.mk_enq('ZZ Snapshot Kid', v_cls, v_year);
    v_r3 := pg_temp.pay(v_e3, 300, 'Cash', 500);
    v_txt := pg_temp.pay(v_e3, 200, 'Cash', 500);
    c := 'c13';
    CALL core.sp_fee_receipt_cancel(c_tenant, c_school, c_user, v_r3, 'Cheque bounced', NULL, c);
    CLOSE c;
    -- Everything in this suite shares one transaction timestamp; push the cancel
    -- a week on, as it would be in real life.
    UPDATE core.fee_payments SET cancelled_at = cancelled_at + INTERVAL '7 days'
     WHERE receipt_no = v_r3 AND tenant_id = c_tenant;
    j := pg_temp.ctx(v_txt);
    PERFORM pg_temp.chk('C13 an old slip keeps the balance it was printed with',
                        (j->>'paid_before')::numeric = 300 AND (j->>'balance_after')::numeric = 0, j::text);
    PERFORM pg_temp.chk_eq('C14 ...while the live balance re-opens', pg_temp.bal(v_e3), 300);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- D. Withdraw the registration, then re-register ---------------';

    -- v_e6 is fully paid (500, live receipt v_r2).
    SELECT registration_number INTO v_txt FROM core.enquiries WHERE enquiry_id = v_e6;
    SELECT COUNT(*) INTO v_n FROM core.enquiry_status_history WHERE enquiry_id = v_e6;
    c := 'd1';
    CALL core.sp_registration_manage(p_operation => 'Cancel', p_tenant_id => c_tenant, p_school_id => c_school,
         p_action_user_id => c_user, p_enquiry_id => v_e6, p_reason => 'Changed Mind', p_result => c);
    FETCH c INTO k_ok, k_msg; CLOSE c;
    SELECT * INTO r FROM core.enquiries WHERE enquiry_id = v_e6;
    PERFORM pg_temp.chk('D1 withdrawn: Not Interested with the reason',
                        r.status = 'Not Interested' AND r.lost_reason = 'Changed Mind', r.status);
    SELECT change_note INTO k_msg FROM core.enquiry_status_history WHERE enquiry_id = v_e6 ORDER BY 1 DESC LIMIT 1;
    PERFORM pg_temp.chk('D2 history row says the fee was retained',
                        (SELECT COUNT(*) FROM core.enquiry_status_history WHERE enquiry_id = v_e6) = v_n + 1
                        AND EXISTS (SELECT 1 FROM core.enquiry_status_history WHERE enquiry_id = v_e6
                                     AND change_note ILIKE '%fee retained%'), '');
    PERFORM pg_temp.chk('D3 receipt untouched and still live', pg_temp.live_rcpts(v_e6) = 1
                        AND pg_temp.reg_row(v_r2) IS NOT NULL, '');
    PERFORM pg_temp.chk('D4 registration number kept', r.registration_number = v_txt, r.registration_number);
    PERFORM pg_temp.chk('D5 still listed (and reprintable) on Registrations',
                        (pg_temp.reglist(v_e6)->>'receipt_no') = v_r2, '');

    -- A part-paid registration that is withdrawn: the proc still takes money.
    v_e3 := pg_temp.mk_enq('ZZ Withdraw Part', v_cls, v_year);
    PERFORM pg_temp.pay(v_e3, 300, 'Cash', 500);
    c := 'd6';
    CALL core.sp_registration_manage(p_operation => 'Cancel', p_tenant_id => c_tenant, p_school_id => c_school,
         p_action_user_id => c_user, p_enquiry_id => v_e3, p_reason => 'Distance', p_result => c);
    CLOSE c;
    BEGIN
        PERFORM pg_temp.pay(v_e3, 200, 'Cash', 500);
        PERFORM pg_temp.chk('D6 no registration money taken after withdrawal', FALSE, 'collected on a withdrawn registration');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('D6 no registration money taken after withdrawal', SQLERRM ILIKE '%withdrawn%', SQLERRM);
    END;

    -- Revive (allowed: Not Interested is not action-driven), then re-register as
    -- the CRM modal does with the fee box unticked.
    c := 'd7';
    CALL core.sp_enquiry_crm_manage(p_operation => 'UpdateStatus', p_tenant_id => c_tenant, p_school_id => c_school,
         p_action_user_id => c_user, p_enquiry_id => v_e6, p_status => 'Interested', p_notes => 'came back', p_result => c);
    CLOSE c;
    c := 'd8';
    CALL core.sp_enquiry_register(p_tenant_id => c_tenant, p_school_id => c_school, p_action_user_id => c_user,
         p_enquiry_id => v_e6, p_registration_fee_paid => FALSE, p_auto_generate => TRUE, p_result => c);
    FETCH c INTO k_ok, k_msg, v_txt; CLOSE c;
    PERFORM pg_temp.chk('D8 re-registration keeps the same number',
                        v_txt = r.registration_number, format('%s vs %s', v_txt, r.registration_number));
    PERFORM pg_temp.chk_eq('D9 re-registration creates no money', pg_temp.live_rcpts(v_e6), 1);
    BEGIN
        PERFORM pg_temp.pay(v_e6, 500, 'Cash', 500);
        PERFORM pg_temp.chk('D10 paid fee is not charged again after re-registration', FALSE, 'charged twice');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('D10 paid fee is not charged again after re-registration', TRUE, SQLERRM);
    END;
    PERFORM pg_temp.chk('D11 re-registration keeps a paid fee flagged paid',
                        pg_temp.flag(v_e6) AND pg_temp.cached(v_e6),
                        format('flag=%s cached=%s balance=%s', pg_temp.flag(v_e6), pg_temp.cached(v_e6), pg_temp.bal(v_e6)));

    -- Replaying Register on an already-registered enquiry (double click).
    SELECT COUNT(*) INTO v_n FROM core.enquiry_status_history WHERE enquiry_id = v_e6;
    c := 'd12';
    CALL core.sp_enquiry_register(p_tenant_id => c_tenant, p_school_id => c_school, p_action_user_id => c_user,
         p_enquiry_id => v_e6, p_registration_fee_paid => TRUE, p_auto_generate => TRUE, p_result => c);
    FETCH c INTO k_ok, k_msg, v_txt; CLOSE c;
    SELECT COUNT(*) INTO v_n2 FROM core.enquiry_status_history WHERE enquiry_id = v_e6;
    PERFORM pg_temp.chk_eq('D12 replayed Register adds no duplicate history row', v_n2, v_n);
    PERFORM pg_temp.chk('D13 ...and answers with the number it already has',
                        k_ok AND v_txt = r.registration_number, format('%s %s', k_msg, v_txt));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- E. Deleting an enquiry that holds money ----------------------';

    v_e5 := pg_temp.mk_enq('ZZ Delete Kid', v_cls, v_year);
    v_r1 := pg_temp.pay(v_e5, 500, 'Cash', 500);
    c := 'e1';
    CALL core.sp_enquiry_crm_manage(p_operation => 'DeleteEnquiry', p_tenant_id => c_tenant, p_school_id => c_school,
         p_action_user_id => c_user, p_enquiry_id => v_e5, p_result => c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('E1 enquiry holding a receipt cannot be deleted',
                        (SELECT is_active FROM core.enquiries WHERE enquiry_id = v_e5) AND r.success = 0
                        AND r.message ILIKE '%receipt%', r.message);
    PERFORM pg_temp.chk('E2 receipt is not hard-deleted', pg_temp.live_rcpts(v_e5) = 1, '');
    PERFORM pg_temp.chk('E3 receipt still in the Collection Register', pg_temp.reg_row(v_r1) IS NOT NULL, '');
    PERFORM pg_temp.chk('E4 its receipt is still reprintable from Registrations',
                        pg_temp.reglist(v_e5) IS NOT NULL, '');

    -- A cancelled receipt is still money history: the enquiry stays.
    v_e4 := pg_temp.mk_enq('ZZ Delete Cancelled', v_cls, v_year);
    v_r2 := pg_temp.pay(v_e4, 500, 'Cash', 500);
    c := 'e5a';
    CALL core.sp_fee_receipt_cancel(c_tenant, c_school, c_user, v_r2, 'Wrong child', NULL, c);
    CLOSE c;
    c := 'e5b';
    CALL core.sp_enquiry_crm_manage(p_operation => 'DeleteEnquiry', p_tenant_id => c_tenant, p_school_id => c_school,
         p_action_user_id => c_user, p_enquiry_id => v_e4, p_result => c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('E5 an enquiry with only a cancelled receipt cannot be deleted either',
                        (SELECT is_active FROM core.enquiries WHERE enquiry_id = v_e4) AND r.success = 0, r.message);

    -- A plain lead with no money can be deleted, and the delete is on record.
    v_e3 := pg_temp.mk_enq('ZZ Plain Lead', v_cls, v_year, FALSE);
    c := 'e6';
    CALL core.sp_enquiry_crm_manage(p_operation => 'DeleteEnquiry', p_tenant_id => c_tenant, p_school_id => c_school,
         p_action_user_id => c_user, p_enquiry_id => v_e3, p_result => c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('E6 a lead with no money can be deleted (soft)',
                        r.success = 1 AND NOT (SELECT is_active FROM core.enquiries WHERE enquiry_id = v_e3), r.message);
    SELECT changed_by INTO v_n FROM core.enquiry_status_history
     WHERE enquiry_id = v_e3 AND status_to = 'Deleted';
    PERFORM pg_temp.chk_eq('E7 delete leaves a history row naming who did it', v_n, c_user);

    -- Rows soft-deleted before the guard existed: no money may be taken on them.
    v_e4 := pg_temp.mk_enq('ZZ Old Deleted', v_cls, v_year);
    PERFORM pg_temp.pay(v_e4, 100, 'Cash', 500);
    UPDATE core.enquiries SET is_active = FALSE WHERE enquiry_id = v_e4;
    BEGIN
        PERFORM pg_temp.pay(v_e4, 100, 'Cash', 500);
        PERFORM pg_temp.chk('E8 no registration money taken on a deleted enquiry', FALSE, 'it was taken');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('E8 no registration money taken on a deleted enquiry', SQLERRM ILIKE '%not found%', SQLERRM);
    END;
    BEGIN
        c := 'e9';
        CALL core.sp_enquiry_register(p_tenant_id => c_tenant, p_school_id => c_school, p_action_user_id => c_user,
             p_enquiry_id => v_e4, p_auto_generate => TRUE, p_result => c);
        PERFORM pg_temp.chk('E9 a deleted enquiry cannot be registered', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('E9 a deleted enquiry cannot be registered', SQLERRM ILIKE '%not found%', SQLERRM);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- F. Admission: carried balance and double charge --------------';

    v_eid := pg_temp.mk_enq('ZZ Admit Kid', v_cls, v_year);
    v_r1 := pg_temp.pay(v_eid, 300, 'Cash', 500);

    c := 'f1';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-MER-1', NULL, 'ZZ Admit Kid', 'Male', DATE '2018-05-05',
         v_cls, v_sec, v_year, v_start, p_enquiry_id => v_eid, p_result => c);
    FETCH c INTO r; CLOSE c;
    v_sid := r.student_id;
    PERFORM pg_temp.chk('F1 admitted from the part-paid enquiry', r.success = 1, r.message);

    SELECT student_id, enquiry_id INTO v_n, v_n2 FROM core.fee_payments WHERE receipt_no = v_r1 AND tenant_id = c_tenant;
    PERFORM pg_temp.chk('F2 registration receipt now names the student and keeps the enquiry',
                        v_n = v_sid AND v_n2 = v_eid, format('student %s enquiry %s', v_n, v_n2));
    SELECT ledger_id, amount_due, fee_head_name INTO v_lid, v_dec, v_txt FROM core.student_ledger
     WHERE student_id = v_sid AND installment_label = 'Registration';
    PERFORM pg_temp.chk('F3 unpaid 200 carried as a ledger due under the fee head name',
                        v_dec = 200 AND v_txt = 'ZZ Reg Charges', format('%s %s', v_txt, v_dec));
    PERFORM pg_temp.chk('F4 carry is audited', EXISTS (SELECT 1 FROM core.admission_audit
                        WHERE student_id = v_sid AND action = 'RegistrationBalanceCarried'), '');
    c := 'f5';
    CALL core.sp_fee_payment_history_get(c_tenant, c_school, c_user, v_sid, c);
    v_n := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.receipt_no = v_r1 THEN v_n := v_n + 1; END IF; END LOOP;
    CLOSE c;
    PERFORM pg_temp.chk_eq('F5 registration receipt in the student Payment History', v_n, 1);

    -- The 200 is now a ledger due. Taking it again against the enquiry doubles it.
    BEGIN
        PERFORM pg_temp.pay(v_eid, 200, 'Cash', 500);
        PERFORM pg_temp.chk('F6 admitted enquiry refuses registration money (no double charge)', FALSE,
                            'accepted: 200 owed on the ledger AND collected on the enquiry');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('F6 admitted enquiry refuses registration money (no double charge)',
                            SQLERRM ILIKE '%admitted%', SQLERRM);
    END;

    -- Same enquiry admitted a second time (different name dodges the dup guard).
    v_ok := NULL;
    BEGIN
        c := 'f7';
        CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
             'ZZ-MER-2', NULL, 'ZZ Admit Kid Twin', 'Male', DATE '2018-05-05',
             v_cls, v_sec, v_year, v_start, p_enquiry_id => v_eid, p_result => c);
        FETCH c INTO r; CLOSE c;
        SELECT COUNT(*) INTO v_n FROM core.student_ledger l JOIN core.students s ON s.student_id = l.student_id
         WHERE s.admission_no = 'ZZ-MER-2' AND l.installment_label = 'Registration';
        v_ok := NOT (r.success = 1);
        v_det := format('second admission success=%s, carried rows on it=%s', r.success, v_n);
        RAISE EXCEPTION '__undo__';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> '__undo__' THEN v_ok := TRUE; v_det := SQLERRM; END IF;
    END;
    PERFORM pg_temp.chk('F7 an already-admitted enquiry cannot be admitted again', v_ok, v_det);

    -- An admitted enquiry can be deleted from the CRM.
    c := 'f8';
    CALL core.sp_enquiry_crm_manage(p_operation => 'DeleteEnquiry', p_tenant_id => c_tenant, p_school_id => c_school,
         p_action_user_id => c_user, p_enquiry_id => v_eid, p_result => c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('F8 an admitted enquiry cannot be deleted',
                        (SELECT is_active FROM core.enquiries WHERE enquiry_id = v_eid) AND r.success = 0
                        AND r.message ILIKE '%admitted%', r.message);

    -- Pay the carried due at the fee counter.
    b_head := pg_temp.reg_head('ZZ Reg Charges');
    c := 'f9';
    CALL core.sp_fee_payment_collect(c_tenant, c_school, c_user, v_sid,
         jsonb_build_array(jsonb_build_object('ledgerId', v_lid, 'amount', 200, 'concession', 0)),
         '[]'::jsonb, 'Cash', NULL, NULL, CURRENT_DATE, v_year, NULL, 0, NULL, NULL, 0, c);
    FETCH c INTO k_ok, k_msg, k_rcpt, k_amt; CLOSE c;
    SELECT status INTO v_txt FROM core.student_ledger WHERE ledger_id = v_lid;
    PERFORM pg_temp.chk('F9 carried due paid at the counter', k_ok AND v_txt = 'Paid', format('%s %s', k_msg, v_txt));
    PERFORM pg_temp.chk('F10 registration shows settled once the carried due is paid',
                        pg_temp.flag(v_eid) AND pg_temp.bal(v_eid) = 0,
                        format('enquiry still says flag=%s balance=%s', pg_temp.flag(v_eid), pg_temp.bal(v_eid)));
    PERFORM pg_temp.chk('F11 one registration fee, one head name in the register',
                        NOT (pg_temp.reg_head('ZZ Reg Charges') - b_head > 0 AND pg_temp.reg_head('Registration Fee') > 0),
                        format('"Registration Fee" %s and "ZZ Reg Charges" %s',
                               pg_temp.reg_head('Registration Fee'), pg_temp.reg_head('ZZ Reg Charges') - b_head));

    -- Cancel the 300 registration receipt after admission: who owes it now?
    SELECT COALESCE(SUM(amount_due - amount_paid - concession),0) INTO v_dec FROM core.student_ledger WHERE student_id = v_sid;
    c := 'f12';
    CALL core.sp_fee_receipt_cancel(c_tenant, c_school, c_user, v_r1, 'Cheque bounced', 'Principal', c);
    FETCH c INTO k_ok, k_msg, k_rcpt; CLOSE c;
    PERFORM pg_temp.chk('F12 post-admission registration receipt can be cancelled', k_ok, k_msg);
    SELECT COALESCE(SUM(amount_due - amount_paid - concession),0) INTO v_dec2 FROM core.student_ledger WHERE student_id = v_sid;
    PERFORM pg_temp.chk_eq('F13 reversed 300 becomes a collectible student due', v_dec2 - v_dec, 300);

    -- Fully paid before admission: nothing carried.
    c := 'f14';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-MER-3', NULL, 'ZZ Discount Kid', 'Male', DATE '2018-05-05',
         v_cls, v_sec, v_year, v_start, p_enquiry_id => v_e2, p_result => c);
    FETCH c INTO r; CLOSE c;
    SELECT COUNT(*) INTO v_n FROM core.student_ledger WHERE student_id = r.student_id AND installment_label = 'Registration';
    PERFORM pg_temp.chk_eq('F14 fully-settled registration carries nothing', v_n, 0);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- G. Scope, validation, numbering ------------------------------';

    v_e3 := pg_temp.mk_enq('ZZ Scope Kid', v_cls, v_year);
    v_r1 := pg_temp.pay(v_e3, 100, 'Cash', 500);

    BEGIN
        PERFORM pg_temp.pay(v_e3, 100, 'Cash', 500, p_t => 23, p_s => 33);
        PERFORM pg_temp.chk('G1 another school cannot take money on our enquiry', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('G1 another school cannot take money on our enquiry', TRUE, SQLERRM);
    END;

    c := 'g2';
    CALL core.sp_registration_fee_summary(23, 33, v_e3, c);
    FETCH c INTO r; v_ok := NOT FOUND; CLOSE c;
    PERFORM pg_temp.chk('G2 another school sees no fee summary', v_ok, '');

    BEGIN
        c := 'g3'; c2 := 'g3l';
        CALL core.sp_fee_receipt_get(23, 33, c_user, v_r1, c, c2);
        PERFORM pg_temp.chk('G3 another school cannot reprint our receipt', FALSE, 'it was returned');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('G3 another school cannot reprint our receipt', TRUE, SQLERRM);
    END;

    c := 'g4';
    CALL core.sp_registration_receipt_context(23, 33, v_r1, c);
    FETCH c INTO r; v_ok := NOT FOUND; CLOSE c;
    PERFORM pg_temp.chk('G4 another school gets no receipt context', v_ok, '');

    BEGIN
        c := 'g5';
        CALL core.sp_registration_manage(p_operation => 'MarkFeePaid', p_tenant_id => 23, p_school_id => 33,
             p_action_user_id => c_user, p_enquiry_id => v_e3, p_result => c);
        PERFORM pg_temp.chk('G5 another school cannot mark our fee paid', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('G5 another school cannot mark our fee paid', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'g6';
        CALL core.sp_registration_manage(p_operation => 'Cancel', p_tenant_id => 23, p_school_id => 33,
             p_action_user_id => c_user, p_enquiry_id => v_e3, p_reason => 'x', p_result => c);
        PERFORM pg_temp.chk('G6 another school cannot cancel our registration', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('G6 another school cannot cancel our registration', TRUE, SQLERRM);
    END;

    c := 'g7';
    CALL core.sp_enquiry_crm_manage(p_operation => 'DeleteEnquiry', p_tenant_id => 23, p_school_id => 33,
         p_action_user_id => c_user, p_enquiry_id => v_e3, p_result => c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('G7 another school cannot delete our enquiry',
                        (SELECT is_active FROM core.enquiries WHERE enquiry_id = v_e3), '');
    PERFORM pg_temp.chk('G8 cross-school delete reports failure, not success',
                        COALESCE(r.success, 0) = 0, format('success=%s "%s"', r.success, r.message));

    PERFORM pg_temp.chk('G9 our receipt not in the other school''s register', pg_temp.reg_row(v_r1, 23, 33) IS NULL, '');

    BEGIN
        PERFORM pg_temp.pay(v_e3, 100, 'Cash', 500, p_t => 1, p_s => 0);
        PERFORM pg_temp.chk('G10 platform scope refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('G10 platform scope refused', TRUE, SQLERRM);
    END;
    BEGIN
        PERFORM pg_temp.pay(v_e3, -50, 'Cash', 500);
        PERFORM pg_temp.chk('G11 negative amount refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('G11 negative amount refused', TRUE, SQLERRM);
    END;
    BEGIN
        PERFORM pg_temp.pay(v_e3, 0, 'Cash', 500);
        PERFORM pg_temp.chk('G12 zero amount (no discount) refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('G12 zero amount (no discount) refused', TRUE, SQLERRM);
    END;
    BEGIN
        PERFORM pg_temp.pay(v_e3, 100, 'Cash', 500, -10, 'Fixed', 'x');
        PERFORM pg_temp.chk('G13 negative discount refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('G13 negative discount refused', TRUE, SQLERRM);
    END;

    -- Mode: one spelling per mode (Day Close counts payment_mode = 'Cash').
    v_r2 := pg_temp.pay(v_e3, 10, '  cash ', 500);
    SELECT payment_mode INTO v_txt FROM core.fee_payments WHERE receipt_no = v_r2 AND tenant_id = c_tenant;
    PERFORM pg_temp.chk('G14 a mis-cased mode is stored in its one spelling', v_txt = 'Cash', v_txt);
    BEGIN
        PERFORM pg_temp.pay(v_e3, 10, 'Bitcoin', 500);
        PERFORM pg_temp.chk('G14b an unknown payment mode is refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('G14b an unknown payment mode is refused', SQLERRM ILIKE '%payment mode%', SQLERRM);
    END;

    BEGIN
        PERFORM pg_temp.pay(v_e3, 10, 'Cash', 500, p_date => CURRENT_DATE + 30);
        PERFORM pg_temp.chk('G15 future payment date refused', FALSE, 'future-dated receipt accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('G15 future payment date refused', SQLERRM ILIKE '%future%', SQLERRM);
    END;

    v_e4 := pg_temp.mk_enq('ZZ Unregistered Kid', v_cls, v_year, FALSE);
    BEGIN
        PERFORM pg_temp.pay(v_e4, 500, 'Cash', 500);
        PERFORM pg_temp.chk('G16 registration fee only on a registered enquiry', FALSE, 'fee taken with no registration');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('G16 registration fee only on a registered enquiry', SQLERRM ILIKE '%Register the enquiry%', SQLERRM);
    END;

    -- Two cashiers at once: the collect locks the enquiry row before it reads
    -- what is settled. (Needs two sessions to race; checked on the live body.)
    PERFORM pg_temp.chk('G17 the collect locks the enquiry row (FOR UPDATE) before checking the balance',
                        pg_get_functiondef('core.sp_registration_fee_record'::regproc) ~* 'FROM core\.enquiries\s+WHERE[^;]*FOR UPDATE', '');

    -- Numbering: registration and counter receipts share one gap-free sequence.
    SELECT COUNT(*), COUNT(DISTINCT receipt_no), MAX(pg_temp.seq(receipt_no)), MIN(pg_temp.seq(receipt_no))
      INTO v_n, v_n2, k_amt, v_dec
      FROM core.fee_payments WHERE tenant_id = c_tenant AND school_id = c_school
       AND receipt_no LIKE 'RCP-' || core.fn_receipt_year(c_tenant, c_school, v_year, CURRENT_DATE) || '-%';
    PERFORM pg_temp.chk('G18 receipt numbers unique across registration + fee receipts', v_n = v_n2,
                        format('%s receipts, %s distinct', v_n, v_n2));
    PERFORM pg_temp.chk('G19 receipt numbers gap-free (refusals/rollbacks burn none)',
                        k_amt - v_dec + 1 = v_n, format('seq %s..%s for %s receipts', v_dec, k_amt, v_n));
END
$suite$;


DO $sum$
DECLARE p integer; f integer; b integer; r record;
BEGIN
    SELECT COUNT(*) FILTER (WHERE ok), COUNT(*) FILTER (WHERE NOT ok),
           COUNT(*) FILTER (WHERE NOT ok AND name LIKE 'BUG %') INTO p, f, b FROM _t;
    RAISE NOTICE '';
    RAISE NOTICE '========== RESULT: % passed, % failed (% are named BUG) ==========', p, f, b;
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
