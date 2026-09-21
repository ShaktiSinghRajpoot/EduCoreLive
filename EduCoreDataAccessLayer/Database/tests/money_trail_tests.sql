-- ============================================================================
-- MONEY TRAIL — one student, end to end.
--
-- The other suites test a module at a time. This one follows a single child
-- through the whole financial life of a school place — enquiry, registration
-- fee, admission, monthly fees, a concession, an overpayment, the bus, a
-- cancelled receipt, a refund, promotion into the next session, and finally
-- leaving with a Transfer Certificate — and after EVERY step it re-checks the
-- same four equations.
--
-- The four equations (pg_temp.balances, called at each stage):
--
--   1. LEDGER vs RECEIPTS   SUM(ledger.amount_paid) must equal the sum of the
--                           lines on receipts that are not cancelled. If these
--                           drift, the office and the cash book disagree.
--   2. CONCESSION           same, for concession. A concession is money the
--                           school chose not to collect; it must be visible in
--                           exactly one place and agree with the receipt.
--   3. WALLET               advance balance must equal credits minus uses over
--                           live receipts. This is the equation that was broken.
--   4. NOTHING NEGATIVE     no ledger row may show more paid than it was due,
--                           and the wallet may never go below zero.
--
-- Runs inside ONE transaction and ROLLS BACK.
--
--     psql ... -f money_trail_tests.sql
-- ============================================================================

\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE TEMP TABLE _t(id serial, name text, ok boolean, detail text) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.chk(p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO _t(name, ok, detail) VALUES (p_name, p_ok, p_detail);
    RAISE NOTICE '  [%] %  %', CASE WHEN p_ok THEN 'PASS' ELSE 'FAIL' END, rpad(p_name, 56), p_detail;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.chk_eq(p_name text, p_got numeric, p_want numeric)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.chk(p_name, ROUND(COALESCE(p_got,0),2) = ROUND(COALESCE(p_want,0),2),
                        format('got %s, expected %s', COALESCE(p_got::text,'NULL'), p_want));
END $$;

-- The four equations, re-checked after every step of the student's life.
CREATE OR REPLACE FUNCTION pg_temp.balances(p_stage text, p_student integer)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    l_paid numeric; r_paid numeric;
    l_conc numeric; r_conc numeric;
    w_bal  numeric; w_calc numeric;
    t_calc numeric; t_tender numeric;
    n_bad  integer;
BEGIN
    SELECT COALESCE(SUM(amount_paid),0), COALESCE(SUM(concession),0)
      INTO l_paid, l_conc
      FROM core.student_ledger WHERE student_id = p_student;

    SELECT COALESCE(SUM(d.amount),0), COALESCE(SUM(d.concession),0)
      INTO r_paid, r_conc
      FROM core.fee_payment_details d
      JOIN core.fee_payments p ON p.payment_id = d.payment_id
     WHERE p.student_id = p_student
       AND COALESCE(p.is_cancelled, FALSE) = FALSE
       AND d.ledger_id IS NOT NULL;

    SELECT COALESCE(balance,0) INTO w_bal
      FROM core.student_advance WHERE student_id = p_student;

    SELECT COALESCE(SUM(COALESCE(advance_credit,0) - COALESCE(advance_used,0)),0)
      INTO w_calc
      FROM core.fee_payments
     WHERE student_id = p_student AND COALESCE(is_cancelled, FALSE) = FALSE;

    SELECT COUNT(*) INTO n_bad
      FROM core.student_ledger
     WHERE student_id = p_student
       AND (amount_paid + COALESCE(concession,0)) > amount_due + 0.01;

    -- The till. fee_payments.amount is what was SETTLED on the ledger, not what
    -- crossed the counter — a parent handing over 2500 against a 1000 due leaves
    -- amount = 1000 and advance_credit = 1500. Real cash is therefore
    -- amount + credit - used, and day close counts the same money a second way,
    -- from the tender lines. If these two ever disagree the drawer will not
    -- reconcile, and nobody will know which figure to trust.
    SELECT COALESCE(SUM(amount + COALESCE(advance_credit,0) - COALESCE(advance_used,0)),0)
      INTO t_calc
      FROM core.fee_payments
     WHERE student_id = p_student AND COALESCE(is_cancelled, FALSE) = FALSE;

    SELECT COALESCE(SUM(v.amount),0) INTO t_tender
      FROM core.v_fee_tender_lines v
      JOIN core.fee_payments p ON p.payment_id = v.payment_id
     WHERE p.student_id = p_student
       AND COALESCE(v.is_cancelled, FALSE) = FALSE
       AND v.mode <> 'Advance';

    PERFORM pg_temp.chk(p_stage || ': ledger paid = receipts',
        ROUND(COALESCE(l_paid,0),2) = ROUND(COALESCE(r_paid,0),2),
        format('ledger %s vs receipts %s', l_paid, r_paid));

    PERFORM pg_temp.chk(p_stage || ': concession agrees',
        ROUND(COALESCE(l_conc,0),2) = ROUND(COALESCE(r_conc,0),2),
        format('ledger %s vs receipts %s', l_conc, r_conc));

    PERFORM pg_temp.chk(p_stage || ': wallet = credits - uses',
        ROUND(COALESCE(w_bal,0),2) = ROUND(COALESCE(w_calc,0),2),
        format('wallet %s vs receipts %s', COALESCE(w_bal,0), w_calc));

    PERFORM pg_temp.chk(p_stage || ': nothing over-collected, wallet >= 0',
        n_bad = 0 AND COALESCE(w_bal,0) >= 0,
        format('%s over-collected row(s), wallet %s', n_bad, COALESCE(w_bal,0)));

    PERFORM pg_temp.chk(p_stage || ': the till reconciles two ways',
        ROUND(COALESCE(t_calc,0),2) = ROUND(COALESCE(t_tender,0),2),
        format('receipts %s vs tenders %s', t_calc, t_tender));
END $$;


DO $suite$
DECLARE
    c_tenant CONSTANT integer := 24;
    c_school CONSTANT integer := 34;
    c_user   CONSTANT integer := 39;

    v_year   varchar;  v_start date;
    v_next   varchar;  v_nextid integer;  v_yearid integer;
    v_c1 varchar; v_c2 varchar; v_sec varchar;

    c  refcursor; c2 refcursor;
    v_eid   integer;
    v_sid   integer;
    v_lid   integer;
    v_lid2  integer;
    v_route integer; v_stop integer;
    v_n     integer;
    v_dec   numeric;
    v_txt   text;
    v_rcpt  varchar;
    v_reg   text;

    k_ok boolean; k_msg text; k_rcpt varchar; k_amt numeric;

    -- Running total of real cash the school has taken from this family.
    v_cash_in numeric := 0;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '============ MONEY TRAIL: ENQUIRY TO PASSOUT ============';

    SELECT academic_year_id, academic_year_name, start_date
      INTO v_yearid, v_year, v_start
      FROM academic.academic_years
     WHERE tenant_id = c_tenant AND school_id = c_school AND COALESCE(is_current, FALSE) LIMIT 1;

    SELECT section_name INTO v_sec
    FROM academic.academic_class_sections s
    JOIN academic.academic_classes ac ON ac.academic_class_id = s.academic_class_id
    WHERE s.tenant_id = c_tenant AND s.school_id = c_school
      AND s.academic_year_id = v_yearid AND COALESCE(s.is_deleted, FALSE) = FALSE
    GROUP BY section_name HAVING COUNT(DISTINCT ac.academic_class_id) >= 2
    ORDER BY COUNT(*) DESC LIMIT 1;

    SELECT class_name INTO v_c1 FROM academic.academic_classes ac
     WHERE ac.tenant_id = c_tenant AND ac.school_id = c_school
       AND ac.academic_year_id = v_yearid AND COALESCE(ac.is_deleted, FALSE) = FALSE
       AND EXISTS (SELECT 1 FROM academic.academic_class_sections x
                    WHERE x.academic_class_id = ac.academic_class_id AND x.section_name = v_sec)
     ORDER BY ac.display_order LIMIT 1;
    SELECT class_name INTO v_c2 FROM academic.academic_classes ac
     WHERE ac.tenant_id = c_tenant AND ac.school_id = c_school
       AND ac.academic_year_id = v_yearid AND COALESCE(ac.is_deleted, FALSE) = FALSE
       AND EXISTS (SELECT 1 FROM academic.academic_class_sections x
                    WHERE x.academic_class_id = ac.academic_class_id AND x.section_name = v_sec)
     ORDER BY ac.display_order OFFSET 1 LIMIT 1;

    RAISE NOTICE 'fixture: session % (from %)  classes % -> %  section %',
                 v_year, v_start, v_c1, v_c2, v_sec;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '── STEP 1. Enquiry, and the registration fee ─────────────';

    c := 's1';
    CALL core.sp_enquiry_crm_manage(
         p_operation => 'SaveEnquiry', p_tenant_id => c_tenant, p_school_id => c_school,
         p_action_user_id => c_user, p_student_name => 'ZZ Money Trail',
         p_gender => 'Male', p_dob => DATE '2015-06-06',
         p_class_name => v_c1, p_session => v_year, p_mobile => '9995550000',
         p_lead_source => 'Walk-in', p_status => 'New', p_result => c);
    SELECT enquiry_id INTO v_eid FROM core.enquiries
     WHERE student_name = 'ZZ Money Trail' ORDER BY enquiry_id DESC LIMIT 1;

    c := 's1b';
    CALL core.sp_enquiry_register(p_tenant_id => c_tenant, p_school_id => c_school,
         p_action_user_id => c_user, p_enquiry_id => v_eid, p_auto_generate => TRUE, p_result => c);
    FETCH c INTO k_ok, k_msg, v_reg;

    c := 's1c';
    CALL core.sp_registration_fee_record(
         p_tenant_id => c_tenant, p_school_id => c_school, p_action_user_id => c_user,
         p_enquiry_id => v_eid, p_amount => 500, p_payment_mode => 'Cash',
         p_payment_date => CURRENT_DATE, p_fin_year => v_year, p_result => c);
    FETCH c INTO k_ok, k_msg, v_rcpt;
    v_cash_in := v_cash_in + 500;

    PERFORM pg_temp.chk('1.1 registration fee taken', COALESCE(k_ok, FALSE), k_msg);

    -- The family has paid, but there is no student yet. That money must be
    -- booked against the ENQUIRY, not left floating.
    SELECT student_id, enquiry_id INTO v_n, v_sid FROM core.fee_payments WHERE receipt_no = v_rcpt;
    PERFORM pg_temp.chk('1.2 booked against the enquiry, not a student',
                        COALESCE(v_n, 0) = 0 AND v_sid = v_eid,
                        format('student_id %s, enquiry_id %s', COALESCE(v_n::text,'NULL'), v_sid));

    SELECT COALESCE(SUM(amount),0) INTO v_dec FROM core.fee_payments
     WHERE enquiry_id = v_eid AND COALESCE(is_cancelled, FALSE) = FALSE;
    PERFORM pg_temp.chk_eq('1.3 500 is on the books', v_dec, 500);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '── STEP 2. Admission: the year is billed ─────────────────';

    c := 's2';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-MONEY-1', NULL, 'ZZ Money Trail', 'Male', DATE '2015-06-06',
         v_c1, v_sec, v_year, v_start,
         p_enquiry_id => v_eid,
         p_fee_plan_json => jsonb_build_array(
             jsonb_build_object('feeHeadName','ZZ Tuition',  'frequency','Monthly', 'amount',1000),
             jsonb_build_object('feeHeadName','ZZ Admission','frequency','One Time','amount',5000)),
         p_result => c);
    SELECT student_id INTO v_sid FROM core.students WHERE admission_no = 'ZZ-MONEY-1';
    PERFORM pg_temp.chk('2.1 admitted from that enquiry', v_sid IS NOT NULL, format('student %s', v_sid));

    SELECT COALESCE(SUM(amount_due),0) INTO v_dec FROM core.student_ledger WHERE student_id = v_sid;
    -- 12 x 1000 + 5000
    PERFORM pg_temp.chk_eq('2.2 the whole year is billed: 12x1000 + 5000', v_dec, 17000);

    SELECT COALESCE(SUM(amount_paid),0) INTO v_dec FROM core.student_ledger WHERE student_id = v_sid;
    PERFORM pg_temp.chk_eq('2.3 nothing paid yet against the student', v_dec, 0);

    -- Admission points the registration receipt at the new student, so money the
    -- family already paid is visible on the child's record. It keeps its
    -- enquiry_id: the receipt really was taken against the enquiry, and that is
    -- where it came from.
    SELECT student_id, enquiry_id INTO v_n, v_txt FROM core.fee_payments
     WHERE enquiry_id = v_eid AND COALESCE(is_cancelled, FALSE) = FALSE;
    PERFORM pg_temp.chk_eq('2.4 the registration receipt now names the student', v_n, v_sid);
    PERFORM pg_temp.chk('2.4b ...and still names the enquiry it came from',
                        v_txt::int = v_eid, format('enquiry_id %s', v_txt));

    -- What it must NOT do is invent a ledger row. The registration fee was never
    -- a billed due on this student, and turning it into one would make it look
    -- like a tuition payment nobody can trace back to its receipt.
    SELECT COUNT(*) INTO v_n FROM core.fee_payment_details d
      JOIN core.fee_payments p ON p.payment_id = d.payment_id
     WHERE p.enquiry_id = v_eid AND d.ledger_id IS NOT NULL;
    PERFORM pg_temp.chk_eq('2.4c ...without inventing a ledger line for it', v_n, 0);

    PERFORM pg_temp.balances('2.5', v_sid);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '── STEP 3. First collection, with a concession ───────────';

    SELECT ledger_id INTO v_lid FROM core.student_ledger
     WHERE student_id = v_sid AND fee_head_name = 'ZZ Admission' LIMIT 1;

    -- 5000 admission fee: 4000 cash, 1000 written off as concession.
    c := 's3';
    CALL core.sp_fee_payment_collect(c_tenant, c_school, c_user, v_sid,
         jsonb_build_array(jsonb_build_object('ledgerId', v_lid, 'amount', 4000, 'concession', 1000)),
         '[]'::jsonb, 'Cash', NULL, NULL, CURRENT_DATE, v_year, NULL, 0, NULL, NULL, 0, c);
    FETCH c INTO k_ok, k_msg, k_rcpt, k_amt;
    v_cash_in := v_cash_in + 4000;

    PERFORM pg_temp.chk_eq('3.1 the receipt is for the CASH only, not the concession', k_amt, 4000);

    SELECT amount_paid, concession, status INTO v_dec, v_n, v_txt
      FROM core.student_ledger WHERE ledger_id = v_lid;
    PERFORM pg_temp.chk_eq('3.2 cash on the ledger', v_dec, 4000);
    PERFORM pg_temp.chk_eq('3.3 concession on the ledger', v_n, 1000);
    PERFORM pg_temp.chk('3.4 cash + concession settles it in full', v_txt = 'Paid',
                        format('status %s', v_txt));

    PERFORM pg_temp.balances('3.5', v_sid);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '── STEP 4. A parent pays ahead: the wallet ───────────────';

    SELECT ledger_id INTO v_lid2 FROM core.student_ledger
     WHERE student_id = v_sid AND frequency = 'Monthly' ORDER BY due_date LIMIT 1;

    -- Hands over 2500 against a 1000 month: 1500 should become credit.
    c := 's4';
    CALL core.sp_fee_payment_collect(c_tenant, c_school, c_user, v_sid,
         jsonb_build_array(jsonb_build_object('ledgerId', v_lid2, 'amount', 1000, 'concession', 0)),
         '[]'::jsonb, 'Cash', NULL, NULL, CURRENT_DATE, v_year, NULL, 0, NULL,
         jsonb_build_array(jsonb_build_object('mode','Cash','amount',2500)), 0, c);
    FETCH c INTO k_ok, k_msg, k_rcpt, k_amt;
    v_cash_in := v_cash_in + 2500;

    SELECT balance INTO v_dec FROM core.student_advance WHERE student_id = v_sid;
    PERFORM pg_temp.chk_eq('4.1 the surplus became wallet credit', v_dec, 1500);

    SELECT advance_credit INTO v_dec FROM core.fee_payments WHERE receipt_no = k_rcpt;
    PERFORM pg_temp.chk_eq('4.2 and the receipt says where it went', v_dec, 1500);

    PERFORM pg_temp.balances('4.3', v_sid);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '── STEP 5. Next month paid FROM the wallet ───────────────';

    SELECT ledger_id INTO v_lid2 FROM core.student_ledger
     WHERE student_id = v_sid AND frequency = 'Monthly' AND status = 'Pending'
     ORDER BY due_date LIMIT 1;

    c := 's5';
    CALL core.sp_fee_payment_collect(c_tenant, c_school, c_user, v_sid,
         jsonb_build_array(jsonb_build_object('ledgerId', v_lid2, 'amount', 1000, 'concession', 0)),
         '[]'::jsonb, 'Advance', NULL, NULL, CURRENT_DATE, v_year, NULL, 0, NULL,
         '[]'::jsonb, 1000, c);
    FETCH c INTO k_ok, k_msg, k_rcpt, k_amt;
    -- No new cash: this month was already paid for in step 4.

    SELECT balance INTO v_dec FROM core.student_advance WHERE student_id = v_sid;
    PERFORM pg_temp.chk_eq('5.1 the wallet paid for it (1500 - 1000)', v_dec, 500);

    SELECT amount_paid INTO v_dec FROM core.student_ledger WHERE ledger_id = v_lid2;
    PERFORM pg_temp.chk_eq('5.2 the month is settled', v_dec, 1000);

    -- The money crossed the counter once, in step 4. This receipt settles a
    -- month without taking a rupee, so the till must not move.
    SELECT COALESCE(SUM(amount + COALESCE(advance_credit,0) - COALESCE(advance_used,0)),0)
      INTO v_dec FROM core.fee_payments
     WHERE student_id = v_sid AND COALESCE(is_cancelled, FALSE) = FALSE;
    PERFORM pg_temp.chk_eq('5.3 the till did not move: no new cash', v_dec, 7000);

    SELECT COALESCE(SUM(amount),0) INTO v_dec FROM core.fee_payments
     WHERE student_id = v_sid AND COALESCE(is_cancelled, FALSE) = FALSE;
    PERFORM pg_temp.chk_eq('5.3b ...though 6500 is now settled on the ledger', v_dec, 6500);

    PERFORM pg_temp.balances('5.4', v_sid);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '── STEP 6. Cancelling the wallet-funded receipt ──────────';

    -- This is the step that used to destroy money: cancelling a receipt settled
    -- from the wallet left the ledger reversed and the wallet empty.
    c := 's6';
    CALL core.sp_fee_receipt_cancel(c_tenant, c_school, c_user, k_rcpt, 'entered on the wrong month', '39', c);

    SELECT balance INTO v_dec FROM core.student_advance WHERE student_id = v_sid;
    PERFORM pg_temp.chk_eq('6.1 the wallet got its 1000 back', v_dec, 1500);

    SELECT amount_paid INTO v_dec FROM core.student_ledger WHERE ledger_id = v_lid2;
    PERFORM pg_temp.chk_eq('6.2 and the month is unpaid again', v_dec, 0);

    -- Cancelling a receipt that took no cash must not change the till either.
    SELECT COALESCE(SUM(amount + COALESCE(advance_credit,0) - COALESCE(advance_used,0)),0)
      INTO v_dec FROM core.fee_payments
     WHERE student_id = v_sid AND COALESCE(is_cancelled, FALSE) = FALSE;
    PERFORM pg_temp.chk_eq('6.3 real cash taken is unchanged by this cancel', v_dec, 7000);

    PERFORM pg_temp.balances('6.4', v_sid);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '── STEP 7. Cancelling a CASH receipt ─────────────────────';

    -- Cancelling the step-4 overpayment must take back both the ledger entry
    -- AND the credit it created — otherwise the family keeps 1500 they never
    -- paid for.
    SELECT receipt_no INTO v_rcpt FROM core.fee_payments
     WHERE student_id = v_sid AND advance_credit > 0
       AND COALESCE(is_cancelled, FALSE) = FALSE LIMIT 1;

    c := 's7';
    CALL core.sp_fee_receipt_cancel(c_tenant, c_school, c_user, v_rcpt, 'cheque bounced', '39', c);

    SELECT balance INTO v_dec FROM core.student_advance WHERE student_id = v_sid;
    PERFORM pg_temp.chk_eq('7.1 the credit went with the cancelled receipt', v_dec, 0);

    SELECT COALESCE(SUM(amount),0) INTO v_dec FROM core.fee_payments
     WHERE student_id = v_sid AND COALESCE(is_cancelled, FALSE) = FALSE;
    PERFORM pg_temp.chk_eq('7.2 only the registration 500 and admission 4000 are live', v_dec, 4500);

    PERFORM pg_temp.balances('7.3', v_sid);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '── STEP 8. The bus: more dues appear ─────────────────────';

    c := 's8';
    CALL core.sp_transport_route_manage('SaveRoute', c_tenant, c_school, c_user,
         NULL, 'ZZ Money Route', 'trail',
         jsonb_build_array(jsonb_build_object('stopName','ZZ Stop','monthlyFare',600)), c);
    SELECT route_id INTO v_route FROM core.transport_routes
     WHERE tenant_id = c_tenant AND school_id = c_school AND route_name = 'ZZ Money Route';
    SELECT stop_id INTO v_stop FROM core.transport_stops WHERE route_id = v_route LIMIT 1;

    c := 's8b';
    CALL core.sp_transport_assign_manage('SaveAssignment', c_tenant, c_school, c_user,
         v_sid, v_route, v_stop, v_year, CURRENT_DATE, 4, c);

    SELECT COUNT(*), COALESCE(SUM(amount_due),0) INTO v_n, v_dec
      FROM core.student_ledger
     WHERE student_id = v_sid AND LOWER(fee_head_name) LIKE '%transport%';
    PERFORM pg_temp.chk_eq('8.1 four months of bus dues raised', v_n, 4);
    PERFORM pg_temp.chk_eq('8.2 at the stop fare (4 x 600)', v_dec, 2400);

    -- Adding a service must not touch a single rupee already collected.
    PERFORM pg_temp.balances('8.3', v_sid);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '── STEP 9. Pay one bus month, then leave the bus ─────────';

    SELECT ledger_id INTO v_lid2 FROM core.student_ledger
     WHERE student_id = v_sid AND LOWER(fee_head_name) LIKE '%transport%'
     ORDER BY due_date LIMIT 1;

    c := 's9';
    CALL core.sp_fee_payment_collect(c_tenant, c_school, c_user, v_sid,
         jsonb_build_array(jsonb_build_object('ledgerId', v_lid2, 'amount', 600, 'concession', 0)),
         '[]'::jsonb, 'Cash', NULL, NULL, CURRENT_DATE, v_year, NULL, 0, NULL, NULL, 0, c);
    v_cash_in := v_cash_in + 600;

    c := 's9b';
    CALL core.sp_transport_assign_manage('RemoveAssignment', c_tenant, c_school, c_user,
         v_sid, NULL, NULL, v_year, NULL, 0, c);

    SELECT COUNT(*) INTO v_n FROM core.student_ledger
     WHERE student_id = v_sid AND LOWER(fee_head_name) LIKE '%transport%'
       AND COALESCE(amount_paid,0) > 0;
    PERFORM pg_temp.chk_eq('9.1 the month they rode and PAID for survives', v_n, 1);

    SELECT COUNT(*) INTO v_n FROM core.student_ledger
     WHERE student_id = v_sid AND LOWER(fee_head_name) LIKE '%transport%'
       AND COALESCE(amount_paid,0) = 0;
    PERFORM pg_temp.chk_eq('9.2 the months they will not ride are dropped', v_n, 0);

    -- THE ONE THAT MATTERS HERE: dropping unpaid dues must not delete the
    -- RECEIPT for the month that was paid, or the cash book loses 600.
    SELECT COALESCE(SUM(amount),0) INTO v_dec FROM core.fee_payments
     WHERE student_id = v_sid AND COALESCE(is_cancelled, FALSE) = FALSE;
    PERFORM pg_temp.chk_eq('9.3 the bus payment is still in the cash book', v_dec, 5100);

    PERFORM pg_temp.balances('9.4', v_sid);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '── STEP 10. A refund ─────────────────────────────────────';

    SELECT ledger_id INTO v_lid2 FROM core.student_ledger
     WHERE student_id = v_sid AND LOWER(fee_head_name) LIKE '%transport%'
       AND COALESCE(amount_paid,0) > 0 LIMIT 1;

    c := 's10';
    CALL core.sp_fee_refund_record(c_tenant, c_school, c_user, v_sid, v_lid2,
         200, 'Cash', 'part of the bus month not used', '39', c);

    SELECT refund_amount INTO v_dec FROM core.student_ledger WHERE ledger_id = v_lid2;
    PERFORM pg_temp.chk_eq('10.1 the refund is recorded against the ledger row', v_dec, 200);

    SELECT COALESCE(SUM(amount),0) INTO v_dec FROM core.fee_refunds WHERE student_id = v_sid;
    PERFORM pg_temp.chk_eq('10.2 and in the refund register', v_dec, 200);

    -- A refund does NOT rewrite what was collected. The receipt still says 600
    -- was taken; the refund says 200 went back. Both are true and both are kept.
    SELECT COALESCE(SUM(amount),0) INTO v_dec FROM core.fee_payments
     WHERE student_id = v_sid AND COALESCE(is_cancelled, FALSE) = FALSE;
    PERFORM pg_temp.chk_eq('10.3 the original receipt is not rewritten', v_dec, 5100);

    -- Net cash the school is holding from this student.
    PERFORM pg_temp.chk_eq('10.4 net held = collected - refunded', v_dec - 200, 4900);

    PERFORM pg_temp.balances('10.5', v_sid);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '── STEP 11. Promotion: the debt follows ──────────────────';

    SELECT academic_year_id, academic_year_name INTO v_nextid, v_next
      FROM academic.academic_years
     WHERE tenant_id = c_tenant AND school_id = c_school AND start_date::date > v_start
     ORDER BY start_date LIMIT 1;

    IF v_next IS NULL THEN
        INSERT INTO academic.academic_years(tenant_id, school_id, academic_year_name,
                                            start_date, end_date, is_current, created_by)
        VALUES (c_tenant, c_school, 'ZZ MT NEXT', (v_start + INTERVAL '1 year')::date,
                (v_start + INTERVAL '2 years' - INTERVAL '1 day')::date, FALSE, c_user)
        RETURNING academic_year_id, academic_year_name INTO v_nextid, v_next;
    END IF;

    INSERT INTO academic.academic_classes(tenant_id, school_id, academic_year_id,
                                          class_name, display_order, created_by)
    SELECT c_tenant, c_school, v_nextid, class_name, display_order, c_user
    FROM academic.academic_classes
    WHERE tenant_id = c_tenant AND school_id = c_school AND academic_year_id = v_yearid
      AND COALESCE(is_deleted, FALSE) = FALSE
      AND class_name NOT IN (SELECT class_name FROM academic.academic_classes
                              WHERE academic_year_id = v_nextid);

    INSERT INTO academic.academic_class_sections(tenant_id, school_id, academic_year_id,
                                                 academic_class_id, section_name,
                                                 display_order, created_by)
    SELECT c_tenant, c_school, v_nextid, tc.academic_class_id, s.section_name, s.display_order, c_user
    FROM academic.academic_class_sections s
    JOIN academic.academic_classes sc ON sc.academic_class_id = s.academic_class_id
    JOIN academic.academic_classes tc ON tc.class_name = sc.class_name AND tc.academic_year_id = v_nextid
    WHERE s.academic_year_id = v_yearid AND COALESCE(s.is_deleted, FALSE) = FALSE
      AND NOT EXISTS (SELECT 1 FROM academic.academic_class_sections x
                       WHERE x.academic_year_id = v_nextid
                         AND x.academic_class_id = tc.academic_class_id
                         AND x.section_name = s.section_name);

    SELECT COALESCE(SUM(amount_due - amount_paid - COALESCE(concession,0)), 0)
      INTO v_dec FROM core.student_ledger WHERE student_id = v_sid;
    PERFORM pg_temp.chk('11.1 the family owes something going in', v_dec > 0,
                        format('outstanding %s', v_dec));

    c := 's11';
    CALL core.sp_student_promote(c_tenant, c_school, c_user, v_year, v_next,
         NULL, TRUE,
         jsonb_build_array(jsonb_build_object('studentId', v_sid, 'outcome', 'promote')), c);

    SELECT COALESCE(SUM(amount_due - amount_paid - COALESCE(concession,0)), 0)
      INTO v_n FROM core.student_ledger WHERE student_id = v_sid;
    PERFORM pg_temp.chk_eq('11.2 promotion did not wipe the debt', v_n, v_dec);

    SELECT COALESCE(SUM(amount),0) INTO v_dec FROM core.fee_payments
     WHERE student_id = v_sid AND COALESCE(is_cancelled, FALSE) = FALSE;
    PERFORM pg_temp.chk_eq('11.3 and did not disturb what was collected', v_dec, 5100);

    PERFORM pg_temp.balances('11.4', v_sid);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '── STEP 12. Leaving: the TC will not release the dues ────';

    c := 's12';
    CALL core.sp_student_exit('Exit', c_tenant, c_school, c_user, v_sid,
         'Transfer', CURRENT_DATE, 'relocating', c);

    BEGIN
        c := 's12b';
        CALL core.sp_tc_manage('Issue', c_tenant, c_school, c_user, NULL, v_sid,
             'Basic', 'Good', 'Pass', 'relocating', NULL, p_result_cur => c);
        PERFORM pg_temp.chk('12.1 TC refused while money is owed', FALSE, 'it was issued');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('12.1 TC refused while money is owed', TRUE, SQLERRM);
    END;

    -- Settle everything that is left, then the certificate can be issued.
    DECLARE r record; v_left numeric;
    BEGIN
        FOR r IN SELECT ledger_id, (amount_due - amount_paid - COALESCE(concession,0)) AS owed
                 FROM core.student_ledger
                 WHERE student_id = v_sid
                   AND (amount_due - amount_paid - COALESCE(concession,0)) > 0
        LOOP
            c := 's12c-' || r.ledger_id::text;
            CALL core.sp_fee_payment_collect(c_tenant, c_school, c_user, v_sid,
                 jsonb_build_array(jsonb_build_object('ledgerId', r.ledger_id,
                                                      'amount', r.owed, 'concession', 0)),
                 '[]'::jsonb, 'Cash', NULL, NULL, CURRENT_DATE, v_year, NULL, 0, NULL, NULL, 0, c);
            v_cash_in := v_cash_in + r.owed;
        END LOOP;

        SELECT COALESCE(SUM(amount_due - amount_paid - COALESCE(concession,0)), 0)
          INTO v_left FROM core.student_ledger WHERE student_id = v_sid;
        PERFORM pg_temp.chk_eq('12.2 the account is settled to zero', v_left, 0);
    END;

    c := 's12d';
    CALL core.sp_tc_manage('Issue', c_tenant, c_school, c_user, NULL, v_sid,
         'Basic', 'Good', 'Pass', 'relocating', NULL, p_result_cur => c);

    SELECT COUNT(*) INTO v_n FROM core.tc_register
     WHERE student_id = v_sid AND COALESCE(is_void, FALSE) = FALSE;
    PERFORM pg_temp.chk_eq('12.3 with a clear account the TC is issued', v_n, 1);

    PERFORM pg_temp.balances('12.4', v_sid);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '── STEP 13. The final reckoning ──────────────────────────';

    -- Everything the school ever charged this family.
    SELECT COALESCE(SUM(amount_due),0) INTO v_dec FROM core.student_ledger WHERE student_id = v_sid;

    DECLARE v_paid numeric; v_conc numeric; v_refund numeric; v_receipts numeric; v_wallet numeric;
    BEGIN
        SELECT COALESCE(SUM(amount_paid),0), COALESCE(SUM(concession),0),
               COALESCE(SUM(refund_amount),0)
          INTO v_paid, v_conc, v_refund
          FROM core.student_ledger WHERE student_id = v_sid;

        -- Only the receipts that actually settled a ledger line. The
        -- registration fee is money for something this ledger never billed, so
        -- counting it here would make the two sides disagree by exactly that
        -- amount — which is what happened when it was first linked.
        SELECT COALESCE(SUM(d.amount),0) INTO v_receipts
          FROM core.fee_payment_details d
          JOIN core.fee_payments p ON p.payment_id = d.payment_id
         WHERE p.student_id = v_sid AND COALESCE(p.is_cancelled, FALSE) = FALSE
           AND d.ledger_id IS NOT NULL;

        SELECT COALESCE(balance,0) INTO v_wallet FROM core.student_advance WHERE student_id = v_sid;

        RAISE NOTICE '    billed %, paid %, concession %, refunded %, receipts %, wallet %',
                     v_dec, v_paid, v_conc, v_refund, v_receipts, v_wallet;

        -- Every rupee billed was either paid, written off, or is still owed.
        PERFORM pg_temp.chk_eq('13.1 billed = paid + concession (nothing left owing)',
                               v_dec, v_paid + v_conc);

        -- Every rupee on a live receipt is on the ledger, and vice versa.
        PERFORM pg_temp.chk_eq('13.2 ledger-settling receipts = what the ledger says was paid',
                               v_receipts, v_paid);

        -- ...and the registration fee is accounted for beside it, not inside it.
        DECLARE v_nonledger numeric;
        BEGIN
            SELECT COALESCE(SUM(p.amount),0) INTO v_nonledger
              FROM core.fee_payments p
             WHERE p.student_id = v_sid AND COALESCE(p.is_cancelled, FALSE) = FALSE
               AND NOT EXISTS (SELECT 1 FROM core.fee_payment_details d
                               WHERE d.payment_id = p.payment_id AND d.ledger_id IS NOT NULL);
            PERFORM pg_temp.chk_eq('13.2b the registration fee sits outside the ledger',
                                   v_nonledger, 500);
        END;

        -- A wallet left with money at the end is money the school is holding
        -- for a student who has gone.
        PERFORM pg_temp.chk_eq('13.3 no wallet balance left behind', v_wallet, 0);

        PERFORM pg_temp.chk_eq('13.4 refunds are accounted for separately', v_refund, 200);
    END;

    -- Cancelled receipts stay on the record, and must not count as money.
    SELECT COUNT(*) INTO v_n FROM core.fee_payments
     WHERE student_id = v_sid AND COALESCE(is_cancelled, FALSE) = TRUE;
    PERFORM pg_temp.chk('13.5 cancelled receipts kept for audit, not counted',
                        v_n = 2, format('%s cancelled receipt(s) on file', v_n));

    -- And the registration fee from before there was a student is still its own
    -- receipt, traceable to the enquiry that paid it.
    SELECT COALESCE(SUM(amount),0) INTO v_dec FROM core.fee_payments
     WHERE enquiry_id = v_eid AND COALESCE(is_cancelled, FALSE) = FALSE;
    PERFORM pg_temp.chk_eq('13.6 the registration fee is still traceable', v_dec, 500);
END
$suite$;


DO $sum$
DECLARE p integer; f integer; r record;
BEGIN
    SELECT COUNT(*) FILTER (WHERE ok), COUNT(*) FILTER (WHERE NOT ok) INTO p, f FROM _t;
    RAISE NOTICE '';
    RAISE NOTICE '============ RESULT: % passed, % failed ============', p, f;
    IF f > 0 THEN
        RAISE NOTICE 'failures:';
        FOR r IN SELECT name, detail FROM _t WHERE NOT ok ORDER BY id LOOP
            RAISE NOTICE '   %  %', rpad(r.name, 56), r.detail;
        END LOOP;
    END IF;
    RAISE NOTICE '';
END
$sum$;

ROLLBACK;
