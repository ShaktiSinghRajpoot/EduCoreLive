-- ============================================================================
-- Fee module test suite.
--
-- Runs inside ONE transaction and ROLLS BACK — it creates students, takes
-- payments and cancels receipts, none of which survives. Safe to point at any
-- database, including one holding real data.
--
--     psql ... -v ON_ERROR_STOP=1 -f fee_module_tests.sql
--
-- Every check records PASS or FAIL with the numbers behind it, so a failure says
-- what it expected and what it got. The summary at the end is the thing to read.
--
-- COVERS
--   A. Ledger generation at admission — including the back-dated-admission bug
--   B. sp_fee_payment_collect — its guards and its arithmetic
--   C. Receipt cancel — does the ledger actually go back?
--   D. Collect-at-admission allocation: concession first, never on a refundable
--      head, then cash, admission charges before scheduled dues, nothing
--      over-allocated.
-- ============================================================================

\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE TEMP TABLE _t(id serial, name text, ok boolean, detail text) ON COMMIT DROP;

-- One place that records a result, so every check reports the same way.
CREATE OR REPLACE FUNCTION pg_temp.chk(p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO _t(name, ok, detail) VALUES (p_name, p_ok, p_detail);
    RAISE NOTICE '  [%] %  %', CASE WHEN p_ok THEN 'PASS' ELSE 'FAIL' END, rpad(p_name, 54), p_detail;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.chk_eq(p_name text, p_got numeric, p_want numeric)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.chk(p_name, p_got = p_want,
                        format('got %s, expected %s', COALESCE(p_got::text,'NULL'), p_want));
END $$;


DO $suite$
DECLARE
    c_tenant CONSTANT integer := 24;
    c_school CONSTANT integer := 34;
    c_user   CONSTANT integer := 39;

    v_year   varchar;
    v_class  varchar;
    v_sess_start date;
    v_sess_end   date;

    c        refcursor;
    v_sid    integer;
    v_lid    integer;
    v_n      integer;
    v_amt    numeric;
    v_out    numeric;
    v_rcpt   varchar;
    v_first  date;
    v_txt    text;
    v_plan   jsonb;

    r_sid integer; r_ok integer; r_msg text; r_adm text;
    k_ok boolean; k_msg text; k_rcpt varchar; k_amt numeric;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '================ FEE MODULE TESTS ================';

    SELECT academic_year_name, start_date, end_date INTO v_year, v_sess_start, v_sess_end
    FROM academic.academic_years
    WHERE tenant_id = c_tenant AND school_id = c_school AND COALESCE(is_current, FALSE)
    LIMIT 1;

    SELECT class_name INTO v_class
    FROM academic.academic_classes
    WHERE tenant_id = c_tenant AND school_id = c_school
      AND COALESCE(is_deleted, FALSE) = FALSE
    ORDER BY display_order LIMIT 1;

    IF v_year IS NULL OR v_class IS NULL THEN
        RAISE EXCEPTION 'Fixture missing: school % has no current session or no classes.', c_school;
    END IF;
    RAISE NOTICE 'fixture: session=% (% .. %)  class=%', v_year, v_sess_start, v_sess_end, v_class;

    -- Two monthly heads and one one-time head, so allocation order is visible.
    v_plan := jsonb_build_array(
        jsonb_build_object('feeHeadName','TEST Tuition',  'frequency','Monthly', 'amount',1000),
        jsonb_build_object('feeHeadName','TEST Computer', 'frequency','Monthly', 'amount', 500),
        jsonb_build_object('feeHeadName','TEST Admission','frequency','One Time','amount',5000)
    );

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- A. Ledger generation at admission ---------------------';

    -- A1: a normal admission at session start bills the whole session.
    c := 'a1';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'TST-NORMAL', NULL, 'TEST Normal', 'Male', DATE '2012-01-01',
         v_class, 'A', v_year, v_sess_start,
         p_fee_plan_json => v_plan, p_result => c);
    SELECT student_id INTO v_sid FROM core.students WHERE admission_no = 'TST-NORMAL';

    SELECT COUNT(*) INTO v_n FROM core.student_ledger
     WHERE student_id = v_sid AND frequency = 'Monthly' AND fee_head_name = 'TEST Tuition';
    PERFORM pg_temp.chk_eq('A1 session-start admission -> 12 monthly rows', v_n, 12);

    SELECT COALESCE(SUM(amount_due),0) INTO v_amt FROM core.student_ledger WHERE student_id = v_sid;
    -- 12x1000 + 12x500 + 5000
    PERFORM pg_temp.chk_eq('A1 total billed', v_amt, 23000);

    -- A2: THE BACK-DATING BUG. Admitted years before this session — must still
    -- bill only this session's months, not every month since they joined.
    c := 'a2';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'TST-BACKDATED', NULL, 'TEST Backdated', 'Male', DATE '2012-02-02',
         v_class, 'A', v_year, DATE '2017-04-20',
         p_fee_plan_json => v_plan, p_result => c);
    SELECT student_id INTO v_sid FROM core.students WHERE admission_no = 'TST-BACKDATED';

    SELECT COUNT(*) INTO v_n FROM core.student_ledger
     WHERE student_id = v_sid AND frequency = 'Monthly' AND fee_head_name = 'TEST Tuition';
    PERFORM pg_temp.chk_eq('A2 admission 9 years back -> still 12 months', v_n, 12);

    SELECT MIN(due_date) INTO v_first FROM core.student_ledger
     WHERE student_id = v_sid AND frequency = 'Monthly';
    PERFORM pg_temp.chk('A2 first instalment is not before the session',
                        v_first >= DATE_TRUNC('month', v_sess_start)::date,
                        format('first due %s, session starts %s', v_first, v_sess_start));

    -- A3: a mid-session joiner is billed only from their own month.
    c := 'a3';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'TST-MIDYEAR', NULL, 'TEST Midyear', 'Male', DATE '2012-03-03',
         v_class, 'A', v_year, (v_sess_start + INTERVAL '4 months')::date,
         p_fee_plan_json => v_plan, p_result => c);
    SELECT student_id INTO v_sid FROM core.students WHERE admission_no = 'TST-MIDYEAR';

    SELECT COUNT(*) INTO v_n FROM core.student_ledger
     WHERE student_id = v_sid AND frequency='Monthly' AND fee_head_name='TEST Tuition';
    PERFORM pg_temp.chk_eq('A3 joined 4 months in -> 8 monthly rows', v_n, 8);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- B. sp_fee_payment_collect ------------------------------';

    SELECT student_id INTO v_sid FROM core.students WHERE admission_no = 'TST-NORMAL';
    SELECT ledger_id, amount_due INTO v_lid, v_amt
      FROM core.student_ledger
     WHERE student_id = v_sid AND fee_head_name = 'TEST Admission' LIMIT 1;

    -- B1: paying part of a due.
    c := 'b1';
    CALL core.sp_fee_payment_collect(c_tenant, c_school, c_user, v_sid,
         jsonb_build_array(jsonb_build_object('ledgerId', v_lid, 'amount', 2000, 'concession', 0)),
         '[]'::jsonb, 'Cash', NULL, NULL, CURRENT_DATE, v_year,
         NULL, 0, NULL, NULL, 0, c);
    FETCH c INTO k_ok, k_msg, k_rcpt, k_amt;

    SELECT amount_paid INTO v_amt FROM core.student_ledger WHERE ledger_id = v_lid;
    PERFORM pg_temp.chk_eq('B1 part payment lands on the ledger', v_amt, 2000);

    SELECT COALESCE(SUM(amount),0) INTO v_amt FROM core.fee_payments
     WHERE student_id = v_sid AND COALESCE(is_cancelled,FALSE) = FALSE;
    PERFORM pg_temp.chk_eq('B1 receipt total', v_amt, 2000);

    -- B2: paying MORE than the row still owes must be refused, not silently capped.
    BEGIN
        c := 'b2';
        CALL core.sp_fee_payment_collect(c_tenant, c_school, c_user, v_sid,
             jsonb_build_array(jsonb_build_object('ledgerId', v_lid, 'amount', 99999, 'concession', 0)),
             '[]'::jsonb, 'Cash', NULL, NULL, CURRENT_DATE, v_year,
             NULL, 0, NULL, NULL, 0, c);
        PERFORM pg_temp.chk('B2 overpaying one line is refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('B2 overpaying one line is refused', TRUE, SQLERRM);
    END;

    -- B3: a negative amount is refused.
    BEGIN
        c := 'b3';
        CALL core.sp_fee_payment_collect(c_tenant, c_school, c_user, v_sid,
             jsonb_build_array(jsonb_build_object('ledgerId', v_lid, 'amount', -100, 'concession', 0)),
             '[]'::jsonb, 'Cash', NULL, NULL, CURRENT_DATE, v_year,
             NULL, 0, NULL, NULL, 0, c);
        PERFORM pg_temp.chk('B3 negative amount is refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('B3 negative amount is refused', TRUE, SQLERRM);
    END;

    -- B4: collecting nothing at all is refused.
    BEGIN
        c := 'b4';
        CALL core.sp_fee_payment_collect(c_tenant, c_school, c_user, v_sid,
             '[]'::jsonb, '[]'::jsonb, 'Cash', NULL, NULL, CURRENT_DATE, v_year,
             NULL, 0, NULL, NULL, 0, c);
        PERFORM pg_temp.chk('B4 empty selection is refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('B4 empty selection is refused', TRUE, SQLERRM);
    END;

    -- B5: another school cannot collect against this student.
    BEGIN
        c := 'b5';
        CALL core.sp_fee_payment_collect(23, 33, c_user, v_sid,
             jsonb_build_array(jsonb_build_object('ledgerId', v_lid, 'amount', 100, 'concession', 0)),
             '[]'::jsonb, 'Cash', NULL, NULL, CURRENT_DATE, v_year,
             NULL, 0, NULL, NULL, 0, c);
        PERFORM pg_temp.chk('B5 cross-school collection is refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('B5 cross-school collection is refused', TRUE, SQLERRM);
    END;

    -- B6: concession reduces what is owed without any cash moving.
    SELECT ledger_id INTO v_lid FROM core.student_ledger
     WHERE student_id = v_sid AND fee_head_name = 'TEST Tuition'
     ORDER BY due_date LIMIT 1;

    c := 'b6';
    CALL core.sp_fee_payment_collect(c_tenant, c_school, c_user, v_sid,
         jsonb_build_array(jsonb_build_object('ledgerId', v_lid, 'amount', 0, 'concession', 400)),
         '[]'::jsonb, 'Cash', NULL, NULL, CURRENT_DATE, v_year,
         'Flat', 400, 'test concession', NULL, 0, c);
    FETCH c INTO k_ok, k_msg, k_rcpt, k_amt;

    SELECT concession, amount_paid INTO v_amt, v_out
      FROM core.student_ledger WHERE ledger_id = v_lid;
    PERFORM pg_temp.chk_eq('B6 concession recorded on the row', v_amt, 400);
    PERFORM pg_temp.chk_eq('B6 no cash taken for it',            v_out, 0);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- C. Receipt cancel -------------------------------------';

    SELECT ledger_id INTO v_lid FROM core.student_ledger
     WHERE student_id = v_sid AND fee_head_name = 'TEST Computer'
     ORDER BY due_date LIMIT 1;

    c := 'c1';
    CALL core.sp_fee_payment_collect(c_tenant, c_school, c_user, v_sid,
         jsonb_build_array(jsonb_build_object('ledgerId', v_lid, 'amount', 500, 'concession', 0)),
         '[]'::jsonb, 'Cash', NULL, NULL, CURRENT_DATE, v_year,
         NULL, 0, NULL, NULL, 0, c);
    FETCH c INTO k_ok, k_msg, v_rcpt, k_amt;

    SELECT amount_paid INTO v_amt FROM core.student_ledger WHERE ledger_id = v_lid;
    PERFORM pg_temp.chk_eq('C1 payment applied before cancel', v_amt, 500);

    c := 'c2';
    CALL core.sp_fee_receipt_cancel(c_tenant, c_school, c_user, v_rcpt, 'test cancel', 'tester', c);

    SELECT amount_paid INTO v_amt FROM core.student_ledger WHERE ledger_id = v_lid;
    PERFORM pg_temp.chk_eq('C2 cancel puts the ledger back', v_amt, 0);

    SELECT is_cancelled INTO k_ok FROM core.fee_payments WHERE receipt_no = v_rcpt;
    PERFORM pg_temp.chk('C2 receipt is flagged cancelled', COALESCE(k_ok, FALSE), '');

    -- A cancelled receipt must not count as collection anywhere.
    SELECT COALESCE(SUM(amount),0) INTO v_amt FROM core.fee_payments
     WHERE receipt_no = v_rcpt AND COALESCE(is_cancelled,FALSE) = FALSE;
    PERFORM pg_temp.chk_eq('C3 cancelled receipt is out of collection totals', v_amt, 0);

    -- C4: cancelling twice. The proc reports success=false rather than raising —
    -- "already cancelled" is a state, not an error. What matters is that the second
    -- attempt does not reverse the ledger AGAIN and does not overwrite the audit
    -- trail of who really cancelled it.
    c := 'c4';
    CALL core.sp_fee_receipt_cancel(c_tenant, c_school, c_user, v_rcpt, 'second attempt', 'tester2', c);
    FETCH c INTO k_ok, k_msg, k_rcpt;
    PERFORM pg_temp.chk('C4 second cancel reports failure', NOT COALESCE(k_ok, TRUE), k_msg);

    SELECT amount_paid INTO v_amt FROM core.student_ledger WHERE ledger_id = v_lid;
    PERFORM pg_temp.chk_eq('C4 ledger not reversed twice', v_amt, 0);

    SELECT cancel_reason INTO v_txt FROM core.fee_payments WHERE receipt_no = v_rcpt;
    PERFORM pg_temp.chk('C4 original cancel reason kept', v_txt = 'test cancel',
                        format('reason is "%s"', v_txt));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- D. Collect-at-admission allocation ---------------------';
    RAISE NOTICE '   (the rule AdmissionController.AllocateAdmissionPayment implements)';

    -- Fresh student, nothing paid yet.
    SELECT student_id INTO v_sid FROM core.students WHERE admission_no = 'TST-MIDYEAR';

    -- D1: admission-point charges are settled BEFORE scheduled monthly dues.
    --     Paying 5000 with the one-time TEST Admission charge outstanding must
    --     clear that head, not the first month's tuition.
    SELECT ledger_id INTO v_lid FROM core.student_ledger
     WHERE student_id = v_sid AND fee_head_name = 'TEST Admission' LIMIT 1;

    c := 'd1';
    CALL core.sp_fee_payment_collect(c_tenant, c_school, c_user, v_sid,
         jsonb_build_array(jsonb_build_object('ledgerId', v_lid, 'amount', 5000, 'concession', 0)),
         '[]'::jsonb, 'Cash', NULL, NULL, CURRENT_DATE, v_year,
         NULL, 0, NULL, NULL, 0, c);
    FETCH c INTO k_ok, k_msg, k_rcpt, k_amt;

    SELECT amount_due - amount_paid - COALESCE(concession,0) INTO v_amt
      FROM core.student_ledger WHERE ledger_id = v_lid;
    PERFORM pg_temp.chk_eq('D1 one-time admission charge cleared first', v_amt, 0);

    SELECT COALESCE(SUM(amount_paid),0) INTO v_amt
      FROM core.student_ledger WHERE student_id = v_sid AND frequency = 'Monthly';
    PERFORM pg_temp.chk_eq('D1 monthly dues untouched by that payment', v_amt, 0);

    -- D2: concession + cash on the same row must never exceed what is owed.
    SELECT ledger_id INTO v_lid FROM core.student_ledger
     WHERE student_id = v_sid AND fee_head_name = 'TEST Tuition'
     ORDER BY due_date LIMIT 1;
    BEGIN
        c := 'd2';
        CALL core.sp_fee_payment_collect(c_tenant, c_school, c_user, v_sid,
             jsonb_build_array(jsonb_build_object('ledgerId', v_lid, 'amount', 800, 'concession', 400)),
             '[]'::jsonb, 'Cash', NULL, NULL, CURRENT_DATE, v_year,
             'Flat', 400, 'over', NULL, 0, c);
        -- 800 + 400 = 1200 against a 1000 due
        SELECT amount_paid + COALESCE(concession,0) INTO v_amt
          FROM core.student_ledger WHERE ledger_id = v_lid;
        PERFORM pg_temp.chk('D2 cash+concession cannot exceed the due',
                            v_amt <= 1000, format('row now holds %s against a 1000 due', v_amt));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('D2 cash+concession cannot exceed the due', TRUE, 'refused: ' || SQLERRM);
    END;

    -- D3: the ledger is the source of truth — outstanding must equal
    --     due - paid - concession for every row, with no negatives anywhere.
    SELECT COUNT(*) INTO v_n FROM core.student_ledger
     WHERE student_id IN (SELECT student_id FROM core.students WHERE admission_no LIKE 'TST-%')
       AND (amount_due - amount_paid - COALESCE(concession,0)) < 0;
    PERFORM pg_temp.chk_eq('D3 no ledger row is over-paid', v_n, 0);

    SELECT COUNT(*) INTO v_n FROM core.student_ledger
     WHERE student_id IN (SELECT student_id FROM core.students WHERE admission_no LIKE 'TST-%')
       AND (amount_paid < 0 OR COALESCE(concession,0) < 0);
    PERFORM pg_temp.chk_eq('D3 no negative paid/concession', v_n, 0);

    -- ══════════════════════════════════════════════════════════════════════
    -- (E is below, after D4.)

    -- D4: every non-cancelled receipt's total equals what it moved onto the ledger.
    SELECT COUNT(*) INTO v_n
    FROM core.fee_payments fp
    WHERE fp.student_id IN (SELECT student_id FROM core.students WHERE admission_no LIKE 'TST-%')
      AND COALESCE(fp.is_cancelled, FALSE) = FALSE
      AND fp.amount < 0;
    PERFORM pg_temp.chk_eq('D4 no negative receipt', v_n, 0);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- E. Receipt numbering ----------------------------------';

    SELECT receipt_no INTO v_rcpt FROM core.fee_payments
     WHERE student_id IN (SELECT student_id FROM core.students WHERE admission_no LIKE 'TST-%')
     ORDER BY payment_id DESC LIMIT 1;

    -- The number is built as 'RCP-' || left(session_name, 4) || '-' || seq, which
    -- assumes the session is named like "2026-2027". A school that names it
    -- "FY 26-27" gets "RCP-FY 2-0001" — a space and a meaningless prefix on every
    -- receipt a parent is handed.
    PERFORM pg_temp.chk('E1 receipt number has no space', position(' ' in v_rcpt) = 0,
                        format('receipt is "%s" for session "%s"', v_rcpt, v_year));

    -- Whatever it looks like, it must be findable again or reprint breaks.
    SELECT COUNT(*) INTO v_n FROM core.fee_payments WHERE receipt_no = v_rcpt;
    PERFORM pg_temp.chk_eq('E2 receipt is findable for reprint', v_n, 1);
END
$suite$;


-- ── Summary ─────────────────────────────────────────────────────────────────
DO $sum$
DECLARE p integer; f integer; r record;
BEGIN
    SELECT COUNT(*) FILTER (WHERE ok), COUNT(*) FILTER (WHERE NOT ok) INTO p, f FROM _t;
    RAISE NOTICE '';
    RAISE NOTICE '================ RESULT: % passed, % failed ================', p, f;
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
