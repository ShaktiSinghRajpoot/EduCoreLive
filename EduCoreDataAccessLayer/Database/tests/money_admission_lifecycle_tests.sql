-- ============================================================================
-- MONEY ACROSS ADMISSION AND THE STUDENT LIFECYCLE.
--
-- The rule under test: wherever money is charged, taken, discounted, refunded,
-- cancelled or dropped, there is a durable record of who, when, how much, which
-- mode, which receipt, which student and which fee head -- never a silent
-- delete or overwrite -- and the reports / day close agree with it.
--
-- This suite goes DEEPER than admission_fee_tests, admission_validation_tests,
-- promotion_tests, transport_tc_tests, money_trail_tests and
-- workflow_billing_tests; it does not repeat what they cover.
--
-- Every check states the CORRECT behaviour. The phase-1 run found 26 bugs
-- (named "BUG <id>" then); they were fixed in phase 2 and the checks renamed.
-- The catalog is educore/docs/test-cases/money_admission_lifecycle.md.
--
-- Runs inside ONE transaction and ROLLS BACK.
--
--     psql ... -f money_admission_lifecycle_tests.sql
--
-- COVERS
--   A. Ledger generated from the fee plan (mid-session joiner)
--   B. Admission atomicity, double submit, admission numbers
--   C. Money taken at admission: receipt, partial, concession, reports
--   D. Security deposit and its refund trail
--   E. Transport: assign, change, remove, scope
--   F. Exit, reactivate, TC
--   G. Promotion and the new session's money
--   H. Class change
--   I. Scope / tenant isolation
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
    PERFORM pg_temp.chk(p_name, ROUND(COALESCE(p_got,0),2) = ROUND(COALESCE(p_want,0),2),
                        format('got %s, expected %s', COALESCE(p_got::text,'NULL'), p_want));
END $$;

-- Admit one student the way SaveAdmission does (fee plan JSON included) and
-- return the new student_id (NULL when the proc refused).
CREATE OR REPLACE FUNCTION pg_temp.admit(p_no text, p_name text, p_class text, p_sec text,
                                         p_year text, p_plan jsonb,
                                         p_date date DEFAULT CURRENT_DATE,
                                         p_mobile text DEFAULT NULL,
                                         p_conc numeric DEFAULT 0)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'admit_' || md5(random()::text); r record;
BEGIN
    CALL core.sp_admission_manage('SaveAdmission', 24, 34, 39, NULL,
         p_no, NULL, p_name, 'Male', DATE '2016-05-05',
         p_class, p_sec, p_year, p_date,
         p_mobile => p_mobile,
         p_concession_amount => p_conc,
         p_concession_reason => CASE WHEN p_conc > 0 THEN 'suite concession' END,
         p_fee_plan_json => p_plan, p_result => c);
    FETCH c INTO r;
    CLOSE c;
    RETURN CASE WHEN r.success = 1 THEN r.student_id END;
END $$;

-- Collect against ledger rows (the call AdmissionController makes); returns receipt_no.
CREATE OR REPLACE FUNCTION pg_temp.collect(p_sid integer, p_items jsonb,
                                           p_mode text DEFAULT 'Cash', p_ref text DEFAULT NULL,
                                           p_reason text DEFAULT NULL, p_tenders jsonb DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'col_' || md5(random()::text); r record;
BEGIN
    CALL core.sp_fee_payment_collect(24, 34, 39, p_sid, p_items, '[]'::jsonb, p_mode, p_ref,
         NULL, CURRENT_DATE, NULL, CASE WHEN p_reason IS NOT NULL THEN 'Flat' END, 0, p_reason,
         p_tenders, 0, c);
    FETCH c INTO r;
    CLOSE c;
    RETURN r.receipt_no;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.outstanding(p_sid integer)
RETURNS numeric LANGUAGE sql AS $$
    SELECT COALESCE(SUM(amount_due - amount_paid - COALESCE(concession,0)), 0)
      FROM core.student_ledger WHERE student_id = p_sid;
$$;


DO $suite$
DECLARE
    c_tenant CONSTANT integer := 24;
    c_school CONSTANT integer := 34;
    c_user   CONSTANT integer := 39;

    v_year   varchar;
    v_yid    integer;
    v_start  date;
    v_end    date;
    v_class  varchar := '3';
    v_sec    varchar := 'A';

    c   refcursor;
    c2  refcursor;
    c3  refcursor;
    c4  refcursor;
    r   record;
    v_n integer;
    v_dec numeric;
    v_dec2 numeric;
    v_txt text;
    v_sid integer;
    v_sid2 integer;
    v_lid integer;
    v_rcpt text;
    v_rcpt2 text;
    v_route integer;
    v_stop_near integer;
    v_stop_far integer;
    v_before numeric;
    v_ok boolean;
    v_other integer;   -- a student of tenant 23 / school 33
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '========= MONEY: ADMISSION + LIFECYCLE =========';

    SELECT academic_year_id, academic_year_name, start_date, end_date
      INTO v_yid, v_year, v_start, v_end
      FROM academic.academic_years
     WHERE tenant_id = c_tenant AND school_id = c_school AND COALESCE(is_current, FALSE) LIMIT 1;

    IF v_year IS NULL OR NOT EXISTS (
        SELECT 1 FROM academic.academic_classes
         WHERE tenant_id = c_tenant AND school_id = c_school AND academic_year_id = v_yid
           AND class_name = v_class AND COALESCE(is_deleted, FALSE) = FALSE) THEN
        RAISE EXCEPTION 'Fixture missing: school % needs class % in its current session.', c_school, v_class;
    END IF;

    SELECT student_id INTO v_other FROM core.students
     WHERE tenant_id = 23 AND school_id = 33 ORDER BY student_id LIMIT 1;

    RAISE NOTICE 'fixture: session % (% .. %)  class %/%  today %  other-school student %',
                 v_year, v_start, v_end, v_class, v_sec, CURRENT_DATE, v_other;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- A. Ledger from the fee plan (mid-session joiner) ------';

    v_sid := pg_temp.admit('ZZ-MAL-A1', 'ZZ Mal Ledger', v_class, v_sec, v_year,
        jsonb_build_array(
            jsonb_build_object('feeHeadName','ZZ Tuition',  'frequency','Monthly',    'amount',1000),
            jsonb_build_object('feeHeadName','ZZ Exam',     'frequency','Quarterly',  'amount',600),
            jsonb_build_object('feeHeadName','ZZ Activity', 'frequency','Half Yearly','amount',2000),
            jsonb_build_object('feeHeadName','ZZ Annual',   'frequency','Yearly',     'amount',3000),
            jsonb_build_object('feeHeadName','ZZ Admission','frequency','One Time',   'amount',5000)));
    PERFORM pg_temp.chk('A0 admitted with a five-head plan', v_sid IS NOT NULL, format('student %s', v_sid));

    -- Monthly from the admission month to the session end month.
    SELECT COUNT(*) INTO v_n FROM core.student_ledger WHERE student_id = v_sid AND fee_head_name = 'ZZ Tuition';
    PERFORM pg_temp.chk_eq('A1 monthly rows = admission month .. session end',
        v_n, (EXTRACT(YEAR FROM age(date_trunc('month', v_end), date_trunc('month', CURRENT_DATE))) * 12
              + EXTRACT(MONTH FROM age(date_trunc('month', v_end), date_trunc('month', CURRENT_DATE))) + 1));

    SELECT MIN(due_date::date) INTO v_txt FROM core.student_ledger
     WHERE student_id = v_sid AND fee_head_name = 'ZZ Tuition';
    PERFORM pg_temp.chk('A2 first monthly due is the admission month',
        v_txt::date = date_trunc('month', CURRENT_DATE)::date, format('first due %s', v_txt));

    SELECT COUNT(*) INTO v_n FROM core.student_ledger
     WHERE student_id = v_sid AND due_date::date > v_end;
    PERFORM pg_temp.chk_eq('A3 nothing is billed after the session ends', v_n, 0);

    -- Quarterly snaps to the school's quarter the joiner lands in.
    SELECT COUNT(*), MIN(due_date::date) INTO v_n, v_txt FROM core.student_ledger
     WHERE student_id = v_sid AND fee_head_name = 'ZZ Exam';
    PERFORM pg_temp.chk('A4 quarterly starts on the session quarter boundary',
        ((EXTRACT(YEAR FROM v_txt::date)*12 + EXTRACT(MONTH FROM v_txt::date))
         - (EXTRACT(YEAR FROM v_start)*12 + EXTRACT(MONTH FROM v_start)))::int % 3 = 0,
        format('%s row(s), first %s', v_n, v_txt));

    SELECT COUNT(*) INTO v_n FROM core.student_ledger
     WHERE student_id = v_sid AND fee_head_name = 'ZZ Activity';
    PERFORM pg_temp.chk('A5 half-yearly billed only for halves left (1 or 2)', v_n BETWEEN 1 AND 2,
        format('%s row(s)', v_n));

    SELECT COUNT(*), MAX(installment_label) INTO v_n, v_txt FROM core.student_ledger
     WHERE student_id = v_sid AND fee_head_name = 'ZZ Annual';
    PERFORM pg_temp.chk('A6 yearly is one Annual row', v_n = 1 AND v_txt = 'Annual', format('%s / %s', v_n, v_txt));

    SELECT COUNT(*), MAX(installment_label) INTO v_n, v_txt FROM core.student_ledger
     WHERE student_id = v_sid AND fee_head_name = 'ZZ Admission';
    PERFORM pg_temp.chk('A7 one-time is one Admission row', v_n = 1 AND v_txt = 'Admission', format('%s / %s', v_n, v_txt));

    SELECT COUNT(*) INTO v_n FROM core.student_ledger
     WHERE student_id = v_sid AND (amount_paid <> 0 OR concession <> 0 OR status <> 'Pending');
    PERFORM pg_temp.chk_eq('A8 a fresh ledger starts unpaid, no concession', v_n, 0);

    SELECT COUNT(*) INTO v_n FROM core.student_fee_plan WHERE student_id = v_sid;
    PERFORM pg_temp.chk_eq('A9 the plan is frozen per head (5 rows)', v_n, 5);

    SELECT COUNT(*) INTO v_n FROM core.admission_audit
     WHERE student_id = v_sid AND action = 'AdmissionCreated' AND action_by = c_user;
    PERFORM pg_temp.chk_eq('A10 admission audited with who did it', v_n, 1);

    -- The plan comes from the browser (LedgerPreviewJson). The proc must not
    -- write charges the school never configured.
    v_sid2 := pg_temp.admit('ZZ-MAL-A11', 'ZZ Mal Negative', v_class, v_sec, v_year,
        jsonb_build_array(jsonb_build_object('feeHeadName','ZZ Tuition','frequency','One Time','amount',-5000)));
    SELECT COUNT(*) INTO v_n FROM core.student_ledger WHERE student_id = v_sid2 AND amount_due < 0;
    PERFORM pg_temp.chk('A11 a negative fee-plan amount is refused',
        v_sid2 IS NULL OR v_n = 0, format('student %s, %s negative due row(s)', v_sid2, v_n));

    v_sid2 := pg_temp.admit('ZZ-MAL-A12', 'ZZ Mal Dup Head', v_class, v_sec, v_year,
        jsonb_build_array(
            jsonb_build_object('feeHeadName','ZZ Admission','frequency','One Time','amount',5000),
            jsonb_build_object('feeHeadName','ZZ Admission','frequency','One Time','amount',5000)));
    SELECT COUNT(*) INTO v_n FROM core.student_ledger WHERE student_id = v_sid2;
    PERFORM pg_temp.chk('A12 the same head twice is refused, not billed twice',
        v_sid2 IS NULL OR v_n <= 1, format('%s row(s) for one head', v_n));

    -- A refused plan leaves nothing behind. (Which heads and amounts are billed
    -- is decided in AdmissionController.BuildAdmissionFeesAsync from the fee
    -- structure; the browser no longer supplies amounts. Static check.)
    SELECT COUNT(*) INTO v_n FROM core.students WHERE student_name IN ('ZZ Mal Negative', 'ZZ Mal Dup Head');
    PERFORM pg_temp.chk_eq('A13 a refused plan leaves no student behind', v_n, 0);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- B. Atomicity, double submit, admission numbers -------';

    -- B1: the exact same form posted twice (double click / retry after a timeout).
    v_sid := pg_temp.admit(NULL, 'ZZ Mal Twice', v_class, v_sec, v_year,
        jsonb_build_array(jsonb_build_object('feeHeadName','ZZ Admission','frequency','One Time','amount',5000)),
        CURRENT_DATE, '9000000001');
    v_sid2 := pg_temp.admit(NULL, 'ZZ  mal twice', v_class, v_sec, v_year,
        jsonb_build_array(jsonb_build_object('feeHeadName','ZZ Admission','frequency','One Time','amount',5000)),
        CURRENT_DATE, '9000000001');
    PERFORM pg_temp.chk('B1 a second identical submit is refused', v_sid IS NOT NULL AND v_sid2 IS NULL,
        format('first %s, second %s', v_sid, v_sid2));
    SELECT COUNT(*) INTO v_n FROM core.student_ledger l JOIN core.students s ON s.student_id = l.student_id
     WHERE s.tenant_id = c_tenant AND s.school_id = c_school AND s.mobile = '9000000001';
    PERFORM pg_temp.chk_eq('B2 ...and billed only once', v_n, 1);

    -- B3: auto numbers are distinct and consecutive.
    DECLARE a1 text; a2 text;
    BEGIN
        SELECT admission_no INTO a1 FROM core.students WHERE student_id = v_sid;
        v_sid2 := pg_temp.admit(NULL, 'ZZ Mal Next No', v_class, v_sec, v_year, NULL, CURRENT_DATE, '9000000002');
        SELECT admission_no INTO a2 FROM core.students WHERE student_id = v_sid2;
        PERFORM pg_temp.chk('B3 two auto numbers are consecutive and distinct',
            a1 <> a2 AND split_part(a2,'-',3)::int = split_part(a1,'-',3)::int + 1, a1 || ' -> ' || a2);
    END;

    -- B4: a refused admission leaves NOTHING behind: no student, no plan, no ledger, no audit.
    v_sid2 := pg_temp.admit('ZZ-MAL-B4', 'ZZ Mal Refused', v_class, v_sec, v_year,
        jsonb_build_array(jsonb_build_object('feeHeadName','ZZ Admission','frequency','One Time','amount',5000)),
        CURRENT_DATE + 1);
    SELECT (SELECT COUNT(*) FROM core.students WHERE admission_no = 'ZZ-MAL-B4')
         + (SELECT COUNT(*) FROM core.admission_audit WHERE detail LIKE '%ZZ-MAL-B4%')
      INTO v_n;
    PERFORM pg_temp.chk('B4 a refused admission writes no student/plan/ledger/audit',
        v_sid2 IS NULL AND v_n = 0, format('student %s, %s leftover row(s)', v_sid2, v_n));

    -- B5: a typed number that collides is refused and bills nobody.
    v_sid2 := pg_temp.admit('zz-mal-a1', 'ZZ Mal Collide', v_class, v_sec, v_year,
        jsonb_build_array(jsonb_build_object('feeHeadName','ZZ Admission','frequency','One Time','amount',5000)));
    SELECT COUNT(*) INTO v_n FROM core.students WHERE student_name = 'ZZ Mal Collide';
    PERFORM pg_temp.chk('B5 a colliding admission number is refused, nobody billed',
        v_sid2 IS NULL AND v_n = 0, format('student %s', v_sid2));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- C. Money taken at admission ---------------------------';

    v_sid := pg_temp.admit('ZZ-MAL-C1', 'ZZ Mal Counter', v_class, v_sec, v_year,
        jsonb_build_array(
            jsonb_build_object('feeHeadName','ZZ Admission','frequency','One Time','amount',5000),
            jsonb_build_object('feeHeadName','ZZ Tuition',  'frequency','Monthly', 'amount',1000)));
    SELECT ledger_id INTO v_lid FROM core.student_ledger WHERE student_id = v_sid AND fee_head_name = 'ZZ Admission';

    c := 'dc0'; c2 := 'dc0m';
    c4 := c || 'h';
    CALL core.sp_fee_day_collection_get(c_tenant, c_school, c_user, CURRENT_DATE, c, c2, c4); CLOSE c4;
    FETCH c INTO r; CLOSE c; CLOSE c2;
    v_before := r.school_collected;
    v_dec2   := r.cash_collected;

    -- Part payment at admission: 3000 of 5000, by UPI with a reference.
    v_rcpt := pg_temp.collect(v_sid, jsonb_build_array(jsonb_build_object('ledgerId', v_lid, 'amount', 3000, 'concession', 0)),
                              'UPI', 'UPI-REF-77');
    SELECT * INTO r FROM core.fee_payments WHERE receipt_no = v_rcpt AND tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk('C1 receipt records student, amount, mode, ref, cashier, date',
        r.student_id = v_sid AND r.amount = 3000 AND r.payment_mode = 'UPI' AND r.reference_no = 'UPI-REF-77'
        AND r.created_by = c_user AND r.payment_date::date = CURRENT_DATE AND v_rcpt LIKE 'RCP-%',
        format('%s %s %s by %s', v_rcpt, r.amount, r.payment_mode, r.created_by));

    SELECT COUNT(*) INTO v_n FROM core.fee_payment_details d
     WHERE d.payment_id = r.payment_id AND d.ledger_id = v_lid AND d.fee_head_name = 'ZZ Admission' AND d.amount = 3000;
    PERFORM pg_temp.chk_eq('C2 the receipt line names the fee head and ledger row', v_n, 1);

    c := 'c3';
    CALL core.sp_student_dues_get(c_tenant, c_school, c_user, v_sid, c);
    v_dec := NULL;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
        IF r.ledger_id = v_lid THEN v_dec := r.outstanding; END IF;
    END LOOP; CLOSE c;
    PERFORM pg_temp.chk_eq('C3 the remaining 2000 is still a visible due', v_dec, 2000);

    c := 'c4';
    CALL core.sp_fee_defaulters_get(c_tenant, c_school, c_user, NULL, NULL, c);
    v_ok := FALSE;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
        IF r.student_id = v_sid AND r.total_outstanding >= 2000 THEN v_ok := TRUE; END IF;
    END LOOP; CLOSE c;
    PERFORM pg_temp.chk('C4 ...and on the Defaulters report', v_ok, '');

    c := 'dc1'; c2 := 'dc1m';
    c4 := c || 'h';
    CALL core.sp_fee_day_collection_get(c_tenant, c_school, c_user, CURRENT_DATE, c, c2, c4); CLOSE c4;
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk_eq('C5 Day Close school total rose by the 3000', r.school_collected - v_before, 3000);
    PERFORM pg_temp.chk_eq('C6 ...but cash in drawer did not (it was UPI)', r.cash_collected - v_dec2, 0);
    v_ok := FALSE;
    LOOP FETCH c2 INTO r; EXIT WHEN NOT FOUND;
        IF r.payment_mode = 'UPI' AND r.amount >= 3000 THEN v_ok := TRUE; END IF;
    END LOOP; CLOSE c2;
    PERFORM pg_temp.chk('C7 Day Close mode split shows the UPI', v_ok, '');

    c := 'c8'; c2 := 'c8m'; c3 := 'c8h';
    CALL core.sp_fee_collection_register(c_tenant, c_school, c_user, CURRENT_DATE, CURRENT_DATE, NULL, NULL, c, c2, c3);
    v_ok := FALSE;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
        IF r.receipt_no = v_rcpt AND r.amount = 3000 AND r.admission_no = 'ZZ-MAL-C1' THEN v_ok := TRUE; END IF;
    END LOOP; CLOSE c; CLOSE c2; CLOSE c3;
    PERFORM pg_temp.chk('C8 the receipt is in the Collection Register', v_ok, v_rcpt);

    c := 'c9';
    CALL core.sp_fee_payment_history_get(c_tenant, c_school, c_user, v_sid, c);
    v_ok := FALSE;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
        IF r.receipt_no = v_rcpt THEN v_ok := TRUE; END IF;
    END LOOP; CLOSE c;
    PERFORM pg_temp.chk('C9 ...and in the student''s Payment History', v_ok, '');

    -- Concession with no cash (Collect Fee Now unticked, discount given): the
    -- controller still posts it as a zero-cash receipt.
    v_rcpt2 := pg_temp.collect(v_sid, jsonb_build_array(jsonb_build_object('ledgerId', v_lid, 'amount', 0, 'concession', 500)),
                               'Cash', NULL, 'staff ward');
    SELECT * INTO r FROM core.fee_payments WHERE receipt_no = v_rcpt2 AND tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk('C10 a concession-only receipt records 0 cash + reason',
        r.amount = 0 AND r.concession_total = 500 AND r.discount_reason = 'staff ward' AND r.created_by = c_user,
        format('%s amount %s conc %s reason %s', v_rcpt2, r.amount, r.concession_total, r.discount_reason));

    c := 'c11'; c2 := 'c11x';
    CALL core.sp_fee_concession_cancel_register(c_tenant, c_school, c_user, CURRENT_DATE, CURRENT_DATE, c, c2);
    v_ok := FALSE;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
        IF r.receipt_no = v_rcpt2 AND r.discount_reason = 'staff ward' THEN v_ok := TRUE; END IF;
    END LOOP; CLOSE c; CLOSE c2;
    PERFORM pg_temp.chk('C11 the concession is on the Concessions report', v_ok, '');

    c := 'dc2'; c2 := 'dc2m';
    c4 := c || 'h';
    CALL core.sp_fee_day_collection_get(c_tenant, c_school, c_user, CURRENT_DATE, c, c2, c4); CLOSE c4;
    FETCH c INTO r; CLOSE c; CLOSE c2;
    PERFORM pg_temp.chk_eq('C12 a concession adds nothing to money collected', r.school_collected - v_before, 3000);

    SELECT amount_due - amount_paid - concession INTO v_dec FROM core.student_ledger WHERE ledger_id = v_lid;
    PERFORM pg_temp.chk_eq('C13 5000 - 3000 cash - 500 concession = 1500 due', v_dec, 1500);

    -- The engine validates each line against the ROW's outstanding before any
    -- line is applied, so one ledger id listed twice passes both checks.
    BEGIN
        PERFORM pg_temp.collect(v_sid, jsonb_build_array(
            jsonb_build_object('ledgerId', v_lid, 'amount', 1500, 'concession', 0),
            jsonb_build_object('ledgerId', v_lid, 'amount', 1500, 'concession', 0)));
        SELECT amount_paid + concession - amount_due INTO v_dec FROM core.student_ledger WHERE ledger_id = v_lid;
        PERFORM pg_temp.chk('C14 one due listed twice cannot be overpaid',
            FALSE, format('accepted: row now settled %s over its due', v_dec));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C14 one due listed twice cannot be overpaid', TRUE, SQLERRM);
    END;

    -- The Student list CSV export (Admission/GetStudentsData -> GetStudents)
    -- reports Fee Due as amount_due - amount_paid, ignoring concession.
    DECLARE v_s3 integer; v_l3 integer;
    BEGIN
        v_s3 := pg_temp.admit('ZZ-MAL-C15', 'ZZ Mal Export', v_class, v_sec, v_year,
            jsonb_build_array(jsonb_build_object('feeHeadName','ZZ Admission','frequency','One Time','amount',1000)));
        SELECT ledger_id INTO v_l3 FROM core.student_ledger WHERE student_id = v_s3;
        PERFORM pg_temp.collect(v_s3, jsonb_build_array(jsonb_build_object('ledgerId', v_l3, 'amount', 600, 'concession', 400)),
                                'Cash', NULL, 'sibling');
        c := 'c15';
        CALL core.sp_admission_manage('GetStudents', c_tenant, c_school, c_user, p_search => 'ZZ-MAL-C15', p_result => c);
        FETCH c INTO r; CLOSE c;
        PERFORM pg_temp.chk('C15 student list CSV Fee Due honours concession',
            r.fee_due = 0 AND r.fee_status = 'Paid', format('fee_due %s, status %s (ledger outstanding 0)', r.fee_due, r.fee_status));

        -- The on-screen Student Directory (sp_student_list) uses the same formula.
        c := 'c15b';
        CALL core.sp_student_list(c_tenant, c_school, c_user, 'ZZ-MAL-C15', NULL, NULL, NULL, NULL, NULL,
             1, 10, NULL, 'desc', c);
        FETCH c INTO r; CLOSE c;
        PERFORM pg_temp.chk('C16 student directory Fee Due honours concession',
            r.fee_due = 0 AND r.fee_status = 'Paid', format('fee_due %s, status %s (ledger outstanding 0)', r.fee_due, r.fee_status));

        -- The Student Dashboard's Total Fee / Total Paid / Concession come from the
        -- whole ledger (sp_student_fee_totals), not from the still-owing dues list.
        c := 'c17';
        CALL core.sp_student_fee_totals(c_tenant, c_school, c_user, v_s3, c);
        FETCH c INTO r; CLOSE c;
        SELECT SUM(amount_paid), SUM(concession) INTO v_dec, v_dec2 FROM core.student_ledger WHERE student_id = v_s3;
        PERFORM pg_temp.chk('C17 dashboard Total Paid and Concession equal the ledger',
            r.total_paid = v_dec AND r.total_concession = v_dec2 AND r.outstanding = 0,
            format('paid %s / %s, concession %s / %s', r.total_paid, v_dec, r.total_concession, v_dec2));
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- D. Security deposit and its refund trail -------------';

    -- The admission screen now sends the deposit under its REAL fee head (id and
    -- name) instead of a made-up "Security Deposit" line no head is called.
    c := 'd0';
    CALL core.sp_school_admin_fee_head_manage('SaveFeeHead', c_tenant, c_school, c_user, 0,
         'ZZ Caution', 'One Time', 2000, 'Mandatory', 'Academic', 'Admission', TRUE, c);
    CLOSE c;
    DECLARE v_head integer;
    BEGIN
        SELECT fee_head_id INTO v_head FROM core.school_fee_heads
         WHERE tenant_id = c_tenant AND school_id = c_school AND fee_head_name = 'ZZ Caution';
        v_sid := pg_temp.admit('ZZ-MAL-D1', 'ZZ Mal Deposit', v_class, v_sec, v_year,
            jsonb_build_array(jsonb_build_object('feeHeadId', v_head, 'feeHeadName','ZZ Caution',
                                                 'frequency','One Time','amount',2000)));
        SELECT ledger_id, fee_head_id INTO v_lid, v_n FROM core.student_ledger WHERE student_id = v_sid;
        PERFORM pg_temp.chk('D0 the deposit row carries its fee head id', v_n = v_head,
            format('ledger head %s, fee head %s', v_n, v_head));
    END;
    v_rcpt := pg_temp.collect(v_sid, jsonb_build_array(jsonb_build_object('ledgerId', v_lid, 'amount', 2000, 'concession', 0)));

    c := 'd1';
    CALL core.sp_student_refundables_get(c_tenant, c_school, c_user, v_sid, c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('D1 the admission deposit is flagged refundable',
        r.is_refundable IS TRUE, format('%s refundable=%s', r.fee_head_name, r.is_refundable));

    -- The refund voucher itself.
    c := 'd2';
    CALL core.sp_fee_refund_record(c_tenant, c_school, c_user, v_sid, v_lid, 2000, 'Cash',
         'deposit returned at TC', 'Principal', c);
    FETCH c INTO r; CLOSE c;
    SELECT * INTO r FROM core.fee_refunds WHERE refund_no = r.refund_no AND tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk('D2 refund voucher: no, amount, mode, reason, authoriser, who, when',
        r.refund_no LIKE 'RFD-%' AND r.amount = 2000 AND r.refund_mode = 'Cash' AND r.reason IS NOT NULL
        AND r.authorized_by = 'Principal' AND r.refunded_by = c_user AND r.refunded_at IS NOT NULL
        AND r.ledger_id = v_lid AND r.student_id = v_sid, COALESCE(r.refund_no, 'none'));

    c := 'd3'; c2 := 'd3m';
    CALL core.sp_fee_refund_register(c_tenant, c_school, c_user, CURRENT_DATE, CURRENT_DATE, c, c2);
    v_ok := FALSE;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
        IF r.amount = 2000 AND r.reason = 'deposit returned at TC' THEN v_ok := TRUE; END IF;
    END LOOP; CLOSE c; CLOSE c2;
    PERFORM pg_temp.chk('D3 the refund is on the Refund Register', v_ok, '');

    c := 'd4'; c2 := 'd4m'; c4 := 'd4h';
    CALL core.sp_fee_day_collection_get(c_tenant, c_school, c_user, CURRENT_DATE, c, c2, c4);
    FETCH c INTO r; CLOSE c; CLOSE c2; CLOSE c4;
    PERFORM pg_temp.chk('D4 Day Close nets the cash refund out of the drawer', r.cash_refunded >= 2000,
        format('cash_refunded %s', r.cash_refunded));

    -- The refund is on the student's own history too.
    c := 'd4b';
    CALL core.sp_student_history_get(c_tenant, c_school, c_user, v_sid, c);
    v_ok := FALSE;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
        IF r.action LIKE 'Refund RFD-%' AND r.amount = 2000 THEN v_ok := TRUE; END IF;
    END LOOP; CLOSE c;
    PERFORM pg_temp.chk('D4b the refund shows on the student''s history', v_ok, '');

    -- Cancelling the original receipt AFTER the deposit was refunded must be
    -- refused, or the same 2000 is reversed twice (fee_receipt_cancel.sql).
    BEGIN
        c := 'd5';
        CALL core.sp_fee_receipt_cancel(c_tenant, c_school, c_user, v_rcpt, 'wrong student', 'Principal', c);
        FETCH c INTO r; CLOSE c;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    SELECT amount_paid, refund_amount INTO v_dec, v_dec2 FROM core.student_ledger WHERE ledger_id = v_lid;
    PERFORM pg_temp.chk('D5 a refunded receipt cannot be cancelled',
        v_dec >= v_dec2, format('after cancel attempt: paid %s, refunded %s', v_dec, v_dec2));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- E. Transport -----------------------------------------';

    c := 'e0';
    CALL core.sp_transport_route_manage('SaveRoute', c_tenant, c_school, c_user, NULL,
         'ZZ MAL Route', 'suite', jsonb_build_array(
             jsonb_build_object('stopName','ZZ MAL Near','monthlyFare',600),
             jsonb_build_object('stopName','ZZ MAL Far', 'monthlyFare',900)), c);
    CLOSE c;
    SELECT route_id INTO v_route FROM core.transport_routes
     WHERE tenant_id = c_tenant AND school_id = c_school AND route_name = 'ZZ MAL Route';
    SELECT stop_id INTO v_stop_near FROM core.transport_stops WHERE route_id = v_route AND stop_name = 'ZZ MAL Near';
    SELECT stop_id INTO v_stop_far  FROM core.transport_stops WHERE route_id = v_route AND stop_name = 'ZZ MAL Far';

    v_sid := pg_temp.admit('ZZ-MAL-E1', 'ZZ Mal Rider', v_class, v_sec, v_year, NULL);

    -- A 12-month count from October must stop at the session end (the proc
    -- reads the session's real end date).
    c := 'e1';
    CALL core.sp_transport_assign_manage('SaveAssignment', c_tenant, c_school, c_user,
         v_sid, v_route, v_stop_far, v_year, CURRENT_DATE, 12, c);
    CLOSE c;
    SELECT COUNT(*) INTO v_n FROM core.student_ledger
     WHERE student_id = v_sid AND fee_head_name = 'Transport Fee' AND due_date::date > v_end;
    PERFORM pg_temp.chk_eq('E0 transport dues never run past the session end', v_n, 0);

    -- Pay this month in full, pay NEXT month in full and cancel it, part-pay the month after.
    DECLARE l_now integer; l_next integer; l_after integer; v_cancel text;
    BEGIN
        SELECT ledger_id INTO l_now FROM core.student_ledger WHERE student_id = v_sid AND fee_head_name = 'Transport Fee'
           AND due_date::date = date_trunc('month', CURRENT_DATE)::date;
        SELECT ledger_id INTO l_next FROM core.student_ledger WHERE student_id = v_sid AND fee_head_name = 'Transport Fee'
           AND due_date::date = (date_trunc('month', CURRENT_DATE) + interval '1 month')::date;
        SELECT ledger_id INTO l_after FROM core.student_ledger WHERE student_id = v_sid AND fee_head_name = 'Transport Fee'
           AND due_date::date = (date_trunc('month', CURRENT_DATE) + interval '2 month')::date;

        PERFORM pg_temp.collect(v_sid, jsonb_build_array(jsonb_build_object('ledgerId', l_now, 'amount', 900, 'concession', 0)));
        v_cancel := pg_temp.collect(v_sid, jsonb_build_array(jsonb_build_object('ledgerId', l_next, 'amount', 900, 'concession', 0)));
        c := 'e3';
        CALL core.sp_fee_receipt_cancel(c_tenant, c_school, c_user, v_cancel, 'keyed twice', 'Office', c);
        CLOSE c;
        PERFORM pg_temp.collect(v_sid, jsonb_build_array(jsonb_build_object('ledgerId', l_after, 'amount', 300, 'concession', 0)));

        -- Route change: Far (900) -> Near (600).
        c := 'e4';
        CALL core.sp_transport_assign_manage('SaveAssignment', c_tenant, c_school, c_user,
             v_sid, v_route, v_stop_near, v_year, CURRENT_DATE, 12, c);
        CLOSE c;

        SELECT amount_paid INTO v_dec FROM core.student_ledger WHERE ledger_id = l_now;
        PERFORM pg_temp.chk_eq('E1 the paid month survives a route change', v_dec, 900);

        SELECT COUNT(*) INTO v_n FROM core.student_transport
         WHERE student_id = v_sid AND tenant_id = c_tenant AND monthly_fare = 900
           AND end_reason LIKE 'Replaced by %' AND ended_by = c_user AND ended_at IS NOT NULL;
        PERFORM pg_temp.chk('E2 the old assignment is kept with why, who and when it ended', v_n = 1,
            format('%s old row(s)', v_n));

        -- Each later month now owes exactly the new fare in total (nothing more).
        SELECT COUNT(*) INTO v_n FROM (
            SELECT due_date FROM core.student_ledger
             WHERE student_id = v_sid AND fee_head_name = 'Transport Fee'
               AND due_date::date > date_trunc('month', CURRENT_DATE)::date
             GROUP BY due_date
            HAVING SUM(amount_due) <> 600) x;
        PERFORM pg_temp.chk_eq('E3 every later month is billed at the new fare, once', v_n, 0);

        SELECT COALESCE(SUM(amount_due), 0) INTO v_dec FROM core.student_ledger
         WHERE student_id = v_sid AND fee_head_name = 'Transport Fee'
           AND due_date::date = (date_trunc('month', CURRENT_DATE) + interval '2 month')::date;
        PERFORM pg_temp.chk_eq('E3b a part-paid month is topped up, not charged twice', v_dec, 600);

        -- The cancelled receipt's line pointed at next month's row; it is closed,
        -- not deleted, so the line still resolves.
        SELECT COUNT(*) INTO v_n FROM core.fee_payment_details d
          JOIN core.fee_payments p ON p.payment_id = d.payment_id
         WHERE p.receipt_no = v_cancel AND p.tenant_id = c_tenant AND p.school_id = c_school
           AND NOT EXISTS (SELECT 1 FROM core.student_ledger l WHERE l.ledger_id = d.ledger_id);
        PERFORM pg_temp.chk_eq('E4 a cancelled receipt''s line still resolves to its due', v_n, 0);

        SELECT close_reason, closed_by INTO v_txt, v_n FROM core.student_ledger WHERE ledger_id = l_next;
        PERFORM pg_temp.chk('E4b ...which records why, and who closed it',
            v_txt LIKE 'Route changed on %' AND v_n = c_user, format('%s by %s', v_txt, v_n));

        -- Remove transport. Nothing stays owed for months after removal.
        c := 'e5';
        CALL core.sp_transport_assign_manage('RemoveAssignment', c_tenant, c_school, c_user,
             v_sid, NULL, NULL, v_year, NULL, 0, c);
        CLOSE c;
        SELECT COALESCE(SUM(amount_due - amount_paid - concession), 0) INTO v_dec FROM core.student_ledger
         WHERE student_id = v_sid AND fee_head_name = 'Transport Fee'
           AND due_date::date > date_trunc('month', CURRENT_DATE)::date;
        PERFORM pg_temp.chk_eq('E5 no bus fee stays owed for months after removal', v_dec, 0);

        SELECT COALESCE(SUM(amount_paid), 0) INTO v_dec FROM core.student_ledger
         WHERE student_id = v_sid AND fee_head_name = 'Transport Fee';
        PERFORM pg_temp.chk_eq('E5b money already taken stays on the ledger (refundable)', v_dec, 1200);

        SELECT COUNT(*) INTO v_n FROM core.student_transport
         WHERE student_id = v_sid AND is_active = TRUE;
        PERFORM pg_temp.chk_eq('E6 removal ends the assignment', v_n, 0);

        SELECT COUNT(*) INTO v_n FROM core.student_transport
         WHERE student_id = v_sid AND end_reason LIKE 'Transport removed on %';
        PERFORM pg_temp.chk_eq('E6b ...and says why', v_n, 1);
    END;

    -- Scope: a route of ours assigned to another school's student.
    IF v_other IS NOT NULL THEN
        BEGIN
            c := 'e7';
            CALL core.sp_transport_assign_manage('SaveAssignment', c_tenant, c_school, c_user,
                 v_other, v_route, v_stop_near, v_year, CURRENT_DATE, 2, c);
            CLOSE c;
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        SELECT COUNT(*) INTO v_n FROM core.student_ledger WHERE student_id = v_other AND tenant_id = c_tenant;
        PERFORM pg_temp.chk_eq('E7 cannot bill transport to another school''s student', v_n, 0);
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- F. Exit, reactivate, TC -------------------------------';

    v_sid := pg_temp.admit('ZZ-MAL-F1', 'ZZ Mal Leaver', v_class, v_sec, v_year,
        jsonb_build_array(
            jsonb_build_object('feeHeadName','ZZ Admission','frequency','One Time','amount',5000),
            jsonb_build_object('feeHeadName','ZZ Tuition',  'frequency','Monthly', 'amount',1000)));
    c := 'f0';
    CALL core.sp_transport_assign_manage('SaveAssignment', c_tenant, c_school, c_user,
         v_sid, v_route, v_stop_near, v_year, CURRENT_DATE, 3, c);
    CLOSE c;
    -- Pay everything due up to and including this month.
    PERFORM pg_temp.collect(v_sid, (SELECT jsonb_agg(jsonb_build_object('ledgerId', ledger_id, 'amount', amount_due, 'concession', 0))
                                      FROM core.student_ledger WHERE student_id = v_sid AND due_date::date <= CURRENT_DATE));

    DECLARE n_rows integer; n_rcpt integer; v_out numeric; v_closed numeric; v_tc integer;
    BEGIN
        SELECT COUNT(*) INTO n_rows FROM core.student_ledger WHERE student_id = v_sid;
        SELECT COUNT(*) INTO n_rcpt FROM core.fee_payments WHERE student_id = v_sid;
        SELECT COALESCE(SUM(amount_due - amount_paid - concession), 0) INTO v_closed FROM core.student_ledger
         WHERE student_id = v_sid AND due_date::date > CURRENT_DATE;

        c := 'f1';
        CALL core.sp_student_exit('Exit', c_tenant, c_school, c_user, v_sid, 'Transfer', CURRENT_DATE, 'moving city', c);
        FETCH c INTO r; CLOSE c;
        v_out := r.outstanding;
        PERFORM pg_temp.chk_eq('F0 exit reports what it closed', r.closed_amount, v_closed);

        SELECT COUNT(*) INTO v_n FROM core.student_ledger WHERE student_id = v_sid;
        PERFORM pg_temp.chk_eq('F1 exit deletes no ledger row', v_n, n_rows);
        SELECT COUNT(*) INTO v_n FROM core.fee_payments WHERE student_id = v_sid;
        PERFORM pg_temp.chk_eq('F2 exit deletes no receipt', v_n, n_rcpt);
        PERFORM pg_temp.chk_eq('F3 exit reports the ledger outstanding', v_out, pg_temp.outstanding(v_sid));

        SELECT exit_recorded_by, date_of_leaving::text INTO v_n, v_txt FROM core.students WHERE student_id = v_sid;
        PERFORM pg_temp.chk('F4 exit records who, when and why', v_n = c_user AND v_txt::date = CURRENT_DATE,
            format('by %s on %s', v_n, v_txt));

        SELECT COALESCE(SUM(amount_due - amount_paid - concession), 0) INTO v_dec FROM core.student_ledger
         WHERE student_id = v_sid AND due_date::date > CURRENT_DATE;
        PERFORM pg_temp.chk_eq('F5 months after the leaving date are no longer owed', v_dec, 0);

        SELECT COUNT(*) INTO v_n FROM core.student_ledger
         WHERE student_id = v_sid AND due_date::date > CURRENT_DATE
           AND (close_source <> 'Exit' OR close_reason <> 'Left on ' || to_char(CURRENT_DATE, 'YYYY-MM-DD')
                OR closed_by IS DISTINCT FROM c_user OR closed_at IS NULL OR closed_amount <= 0);
        PERFORM pg_temp.chk_eq('F5b ...each closed (not deleted) with reason, who and when', v_n, 0);

        SELECT COUNT(*) INTO v_n FROM core.student_ledger
         WHERE student_id = v_sid AND due_date::date <= CURRENT_DATE AND closed_amount > 0;
        PERFORM pg_temp.chk_eq('F5c dues up to the leaving date are untouched', v_n, 0);

        SELECT COUNT(*) INTO v_n FROM core.student_transport
         WHERE student_id = v_sid AND is_active = TRUE;
        PERFORM pg_temp.chk_eq('F6 exit ends the bus assignment', v_n, 0);

        c := 'f6b';
        CALL core.sp_student_history_get(c_tenant, c_school, c_user, v_sid, c);
        v_n := 0;
        LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
            IF r.action IN ('StudentExited', 'Due closed') THEN v_n := v_n + 1; END IF;
        END LOOP; CLOSE c;
        PERFORM pg_temp.chk('F6c the exit and every closed due show on the history', v_n >= 2,
            format('%s history line(s)', v_n));

        -- Paid up to the leaving date: the TC is issued.
        BEGIN
            c := 'f7';
            CALL core.sp_tc_manage('Issue', c_tenant, c_school, c_user, NULL, v_sid,
                 'Basic', 'Good', 'Pass', 'moving', NULL, p_result_cur => c);
            FETCH c INTO r; CLOSE c;
            v_tc := r.tc_id;
            PERFORM pg_temp.chk('F7 a leaver paid up to the leaving date gets a TC', v_tc IS NOT NULL, r.tc_no);
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('F7 a leaver paid up to the leaving date gets a TC', FALSE, SQLERRM);
        END;

        -- Reactivate is refused while that TC is live.
        BEGIN
            c := 'f8';
            CALL core.sp_student_exit('Undo', c_tenant, c_school, c_user, v_sid, NULL, NULL, NULL, c);
            CLOSE c;
            PERFORM pg_temp.chk('F8 reactivating a student with a live TC is refused', FALSE, 'reactivated');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('F8 reactivating a student with a live TC is refused', TRUE, SQLERRM);
        END;

        IF v_tc IS NOT NULL THEN
            BEGIN
                c := 'f9';
                CALL core.sp_tc_manage('Void', c_tenant, c_school, c_user, v_tc, p_reason => NULL, p_result_cur => c);
                CLOSE c;
                PERFORM pg_temp.chk('F9 voiding a TC needs a reason', FALSE, 'voided with no reason');
            EXCEPTION WHEN OTHERS THEN
                PERFORM pg_temp.chk('F9 voiding a TC needs a reason', TRUE, SQLERRM);
            END;

            c := 'f10';
            CALL core.sp_tc_manage('Void', c_tenant, c_school, c_user, v_tc, p_reason => 'issued in error', p_result_cur => c);
            CLOSE c;
        END IF;

        -- Reactivate: exactly what the exit closed comes back, and it is recorded.
        c := 'f11';
        CALL core.sp_student_exit('Undo', c_tenant, c_school, c_user, v_sid, NULL, NULL, NULL, c);
        FETCH c INTO r; CLOSE c;
        PERFORM pg_temp.chk_eq('F11 reactivate restores exactly what the exit closed', r.closed_amount, v_closed);
        PERFORM pg_temp.chk_eq('F11b ...so the student owes what they owed before', pg_temp.outstanding(v_sid), v_closed);

        SELECT COUNT(*) INTO v_n FROM core.student_ledger WHERE student_id = v_sid AND close_source = 'Exit';
        PERFORM pg_temp.chk_eq('F11c no row is left marked as closed by the exit', v_n, 0);

        SELECT COUNT(*) INTO v_n FROM core.student_transport WHERE student_id = v_sid AND is_active = TRUE;
        PERFORM pg_temp.chk_eq('F11d the bus assignment the exit ended is back', v_n, 1);

        SELECT detail INTO v_txt FROM core.admission_audit
         WHERE student_id = v_sid AND action = 'StudentReactivated' AND action_by = c_user;
        PERFORM pg_temp.chk('F12 the exit and the reactivation stay on record',
            v_txt LIKE 'Was Transfer on %moving city%',
            COALESCE(v_txt, 'no audit row'));
    END;

    -- An overpayment in the advance wallet blocks the TC until it is refunded.
    DECLARE l_one integer;
    BEGIN
        v_sid := pg_temp.admit('ZZ-MAL-F13', 'ZZ Mal TC Kid', v_class, v_sec, v_year,
            jsonb_build_array(jsonb_build_object('feeHeadName','ZZ Admission','frequency','One Time','amount',1000)));
        SELECT ledger_id INTO l_one FROM core.student_ledger WHERE student_id = v_sid;
        PERFORM pg_temp.collect(v_sid, jsonb_build_array(jsonb_build_object('ledgerId', l_one, 'amount', 1000, 'concession', 0)),
                                'Cash', NULL, NULL, jsonb_build_array(jsonb_build_object('mode','Cash','amount',1500)));
        SELECT balance INTO v_dec FROM core.student_advance WHERE student_id = v_sid;
        PERFORM pg_temp.chk_eq('F13 the overpayment sits in the advance wallet', v_dec, 500);

        c := 'f14';
        CALL core.sp_student_exit('Exit', c_tenant, c_school, c_user, v_sid, 'Transfer', CURRENT_DATE, 'moving', c);
        CLOSE c;

        BEGIN
            c := 'f15';
            CALL core.sp_tc_manage('Issue', c_tenant, c_school, c_user, NULL, v_sid,
                 'Basic', 'Good', 'Pass', 'moving', NULL, p_result_cur => c);
            FETCH c INTO r; CLOSE c;
            PERFORM pg_temp.chk('F15 TC withheld while the family''s advance is unreturned',
                FALSE, format('TC %s issued with %s still in the wallet', r.tc_no, v_dec));
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('F15 TC withheld while the family''s advance is unreturned', TRUE, SQLERRM);
        END;

        -- A proc other than collect / cancel / purge can pay the wallet out (the
        -- collection agent's advance refund voucher).
        SELECT COUNT(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'core' AND p.prokind IN ('p','f')
           AND pg_get_functiondef(p.oid) ~* 'UPDATE\s+core\.student_advance'
           AND p.proname NOT IN ('sp_fee_payment_collect', 'sp_fee_receipt_cancel', 'sp_school_purge');
        PERFORM pg_temp.chk('F16 an advance balance can be refunded with a voucher',
            v_n > 0, format('%s proc(s) can pay the wallet out', v_n));
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- G. Promotion and the new session''s money -------------';

    DECLARE v_tgt varchar; v_tgtid integer; l_m integer; v_tgt_start date; v_fs integer; v_rows integer;
    BEGIN
        SELECT academic_year_id, academic_year_name, start_date::date INTO v_tgtid, v_tgt, v_tgt_start
          FROM academic.academic_years
         WHERE tenant_id = c_tenant AND school_id = c_school AND start_date::date > v_start
         ORDER BY start_date LIMIT 1;
        IF v_tgt IS NULL THEN
            INSERT INTO academic.academic_years(tenant_id, school_id, academic_year_name,
                                                start_date, end_date, is_current, created_by)
            VALUES (c_tenant, c_school, 'ZZ MAL NEXT', (v_start + INTERVAL '1 year')::date,
                    (v_start + INTERVAL '2 years' - INTERVAL '1 day')::date, FALSE, c_user)
            RETURNING academic_year_id, academic_year_name, start_date::date INTO v_tgtid, v_tgt, v_tgt_start;
        END IF;
        INSERT INTO academic.academic_classes(tenant_id, school_id, academic_year_id, class_name, display_order, created_by)
        SELECT c_tenant, c_school, v_tgtid, class_name, display_order, c_user
          FROM academic.academic_classes
         WHERE tenant_id = c_tenant AND school_id = c_school AND academic_year_id = v_yid
           AND COALESCE(is_deleted, FALSE) = FALSE
           AND class_name NOT IN (SELECT class_name FROM academic.academic_classes
                                   WHERE tenant_id = c_tenant AND school_id = c_school AND academic_year_id = v_tgtid);
        INSERT INTO academic.academic_class_sections(tenant_id, school_id, academic_year_id,
                                                     academic_class_id, section_name, display_order, created_by)
        SELECT c_tenant, c_school, v_tgtid, tc.academic_class_id, s.section_name, s.display_order, c_user
          FROM academic.academic_class_sections s
          JOIN academic.academic_classes sc ON sc.academic_class_id = s.academic_class_id
          JOIN academic.academic_classes tc ON tc.class_name = sc.class_name AND tc.academic_year_id = v_tgtid
                                           AND tc.tenant_id = c_tenant AND tc.school_id = c_school
         WHERE s.tenant_id = c_tenant AND s.school_id = c_school AND s.academic_year_id = v_yid
           AND COALESCE(s.is_deleted, FALSE) = FALSE
           AND NOT EXISTS (SELECT 1 FROM academic.academic_class_sections x
                            WHERE x.academic_class_id = tc.academic_class_id AND x.section_name = s.section_name);

        -- Class 4's fee structure for the new session: tuition 1200 a month, plus a
        -- one-time Admission-point head that promotion must NOT charge again.
        INSERT INTO core.school_fee_heads(tenant_id, school_id, fee_head_name, frequency, default_amount,
                                          fee_type, fee_group, is_active, is_deleted, created_by,
                                          collection_point, is_refundable)
        VALUES (c_tenant, c_school, 'ZZ Next Tuition', 'Monthly', 1200, 'Mandatory', 'Academic', TRUE, FALSE, c_user, 'Recurring', FALSE),
               (c_tenant, c_school, 'ZZ Next Admission', 'One Time', 4000, 'Mandatory', 'Academic', TRUE, FALSE, c_user, 'Admission', FALSE);
        INSERT INTO core.school_fee_structures(tenant_id, school_id, class_name, academic_year, created_by)
        VALUES (c_tenant, c_school, '4', v_tgt, c_user)
        RETURNING fee_structure_id INTO v_fs;
        INSERT INTO core.school_fee_structure_details(tenant_id, school_id, fee_structure_id, fee_head_id,
                                                      fee_head_name, frequency, amount, created_by)
        SELECT c_tenant, c_school, v_fs, fee_head_id, fee_head_name, frequency, default_amount, c_user
          FROM core.school_fee_heads
         WHERE tenant_id = c_tenant AND school_id = c_school
           AND fee_head_name IN ('ZZ Next Tuition', 'ZZ Next Admission');

        v_sid := pg_temp.admit('ZZ-MAL-G1', 'ZZ Mal Promoted', v_class, v_sec, v_year,
            jsonb_build_array(jsonb_build_object('feeHeadName','ZZ Tuition','frequency','Monthly','amount',1000)));
        -- Overpay one month so the wallet carries 250 into the new session.
        SELECT ledger_id INTO l_m FROM core.student_ledger WHERE student_id = v_sid ORDER BY due_date LIMIT 1;
        PERFORM pg_temp.collect(v_sid, jsonb_build_array(jsonb_build_object('ledgerId', l_m, 'amount', 1000, 'concession', 0)),
                                'Cash', NULL, NULL, jsonb_build_array(jsonb_build_object('mode','Cash','amount',1250)));
        -- ...and keeps the bus.
        c := 'g0';
        CALL core.sp_transport_assign_manage('SaveAssignment', c_tenant, c_school, c_user,
             v_sid, v_route, v_stop_near, v_year, CURRENT_DATE, 12, c);
        CLOSE c;
        v_before := pg_temp.outstanding(v_sid);

        c := 'g1';
        CALL core.sp_student_promote(c_tenant, c_school, c_user, v_year, v_tgt, NULL, TRUE,
             jsonb_build_array(jsonb_build_object('studentId', v_sid, 'outcome', 'promote')), c);
        FETCH c INTO r; CLOSE c;
        PERFORM pg_temp.chk('G0 the promotion message says who was billed', r.message LIKE '%1 billed for%', r.message);

        SELECT dues_carried INTO v_dec FROM core.student_promotion_history WHERE student_id = v_sid;
        PERFORM pg_temp.chk_eq('G1 promotion history records the dues carried', v_dec, v_before);

        SELECT balance INTO v_dec FROM core.student_advance WHERE student_id = v_sid;
        PERFORM pg_temp.chk_eq('G2 the advance wallet survives promotion', v_dec, 250);

        SELECT COUNT(*), COALESCE(SUM(amount_due), 0) INTO v_n, v_dec FROM core.student_ledger
         WHERE student_id = v_sid AND academic_year = v_tgt AND fee_head_name = 'ZZ Next Tuition';
        PERFORM pg_temp.chk('G3 the new session is billed from the class 4 structure',
            v_n = 12 AND v_dec = 14400, format('%s row(s), %s', v_n, v_dec));

        SELECT MIN(due_date::date) INTO v_txt FROM core.student_ledger
         WHERE student_id = v_sid AND fee_head_name = 'ZZ Next Tuition';
        PERFORM pg_temp.chk('G3b ...from the new session''s first month', v_txt::date = v_tgt_start, v_txt);

        SELECT COUNT(*) INTO v_n FROM core.student_ledger
         WHERE student_id = v_sid AND fee_head_name = 'ZZ Next Admission';
        PERFORM pg_temp.chk_eq('G4 the admission fee is not charged again on promotion', v_n, 0);

        SELECT COUNT(*) INTO v_n FROM core.student_ledger
         WHERE student_id = v_sid AND fee_head_name = 'Transport Fee' AND academic_year = v_tgt
           AND amount_due = 600;
        PERFORM pg_temp.chk_eq('G5 a kept bus route is billed for the new session', v_n, 12);

        SELECT COUNT(*) INTO v_n FROM core.student_ledger
         WHERE student_id = v_sid AND due_date::date < v_tgt_start AND amount_due > amount_paid + concession;
        PERFORM pg_temp.chk('G6 old unpaid dues still carry', v_n > 0, format('%s old row(s) owing', v_n));

        -- Never twice: re-running the promotion, or billing the same session again.
        SELECT COUNT(*) INTO v_rows FROM core.student_ledger WHERE student_id = v_sid;
        BEGIN
            c := 'g7';
            CALL core.sp_student_promote(c_tenant, c_school, c_user, v_year, v_tgt, NULL, TRUE,
                 jsonb_build_array(jsonb_build_object('studentId', v_sid, 'outcome', 'promote')), c);
            CLOSE c;
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        PERFORM core.fn_student_bill_plan(c_tenant, c_school, c_user, v_sid, v_tgt, v_tgt_start,
                core.fn_class_fee_plan(c_tenant, c_school, '4', v_tgt));
        SELECT COUNT(*) INTO v_n FROM core.student_ledger WHERE student_id = v_sid;
        PERFORM pg_temp.chk_eq('G7 the new session is never billed twice', v_n, v_rows);

        -- The promotion (and the dues it carried) is readable on the student's history.
        c := 'g8';
        CALL core.sp_student_history_get(c_tenant, c_school, c_user, v_sid, c);
        v_ok := FALSE;
        LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
            IF r.action = 'Promotion: Promote' AND r.detail LIKE '%dues carried%' THEN v_ok := TRUE; END IF;
        END LOOP; CLOSE c;
        PERFORM pg_temp.chk('G8 promotion history (dues carried) is readable by the UI', v_ok, '');

        -- H. Class change -----------------------------------------------------
        RAISE NOTICE '';
        RAISE NOTICE '-- H. Class change --------------------------------------';

        v_sid := pg_temp.admit('ZZ-MAL-H1', 'ZZ Mal Mover', v_class, v_sec, v_year,
            jsonb_build_array(jsonb_build_object('feeHeadName','ZZ Tuition','frequency','Monthly','amount',1000)));
        v_n := (SELECT COUNT(*) FROM core.student_ledger WHERE student_id = v_sid);
        c := 'h1';
        CALL core.sp_student_update(c_tenant, c_school, c_user, v_sid, p_student_name => 'ZZ Mal Mover',
             p_class_name => '4', p_section => 'A', p_result => c);
        FETCH c INTO r; CLOSE c;
        SELECT COUNT(*) INTO v_dec FROM core.student_ledger WHERE student_id = v_sid AND closed_amount = 0;
        PERFORM pg_temp.chk('H1 no structure for the new class: fees left alone, and the office is told',
            v_dec = v_n AND r.message LIKE '%fees were not changed%', r.message);

        SELECT class_name INTO v_txt FROM core.student_enrolment WHERE student_id = v_sid AND academic_year = v_year;
        PERFORM pg_temp.chk('H2 the session enrolment follows a class change', v_txt = '4',
            format('enrolment says %s', v_txt));

        SELECT COUNT(*) INTO v_n FROM core.admission_audit
         WHERE student_id = v_sid AND action = 'ClassChanged' AND detail LIKE '3-A -> 4-A%';
        PERFORM pg_temp.chk_eq('H3 a class change is recorded', v_n, 1);

        -- With a structure: class 6 costs 1500 a month this session.
        INSERT INTO core.school_fee_structures(tenant_id, school_id, class_name, academic_year, created_by)
        VALUES (c_tenant, c_school, '6', v_year, c_user)
        RETURNING fee_structure_id INTO v_fs;
        INSERT INTO core.school_fee_structure_details(tenant_id, school_id, fee_structure_id, fee_head_id,
                                                      fee_head_name, frequency, amount, created_by)
        SELECT c_tenant, c_school, v_fs, fee_head_id, fee_head_name, 'Monthly', 1500, c_user
          FROM core.school_fee_heads
         WHERE tenant_id = c_tenant AND school_id = c_school AND fee_head_name = 'ZZ Next Tuition';

        c := 'h4';
        CALL core.sp_student_update(c_tenant, c_school, c_user, v_sid, p_student_name => 'ZZ Mal Mover',
             p_class_name => '6', p_section => 'A', p_result => c);
        CLOSE c;

        SELECT COALESCE(SUM(amount_due - amount_paid - concession), 0) INTO v_dec FROM core.student_ledger
         WHERE student_id = v_sid AND fee_head_name = 'ZZ Tuition' AND due_date::date > CURRENT_DATE;
        PERFORM pg_temp.chk_eq('H4 the old class''s later instalments are no longer owed', v_dec, 0);

        SELECT COUNT(*) INTO v_n FROM core.student_ledger
         WHERE student_id = v_sid AND fee_head_name = 'ZZ Tuition' AND due_date::date > CURRENT_DATE
           AND (close_source <> 'ClassChange' OR close_reason NOT LIKE 'Moved from 4 to 6 on %');
        PERFORM pg_temp.chk_eq('H4b ...closed with the reason, not deleted', v_n, 0);

        SELECT amount_due INTO v_dec FROM core.student_ledger
         WHERE student_id = v_sid AND fee_head_name = 'ZZ Tuition'
           AND due_date::date = date_trunc('month', CURRENT_DATE)::date;
        PERFORM pg_temp.chk_eq('H5 this month stays at the old class''s fee', v_dec, 1000);

        SELECT COUNT(*), MIN(due_date::date)::text INTO v_n, v_txt FROM core.student_ledger
         WHERE student_id = v_sid AND fee_head_name = 'ZZ Next Tuition' AND amount_due = 1500;
        PERFORM pg_temp.chk('H6 the new class is billed from next month to the session end',
            v_txt::date = (date_trunc('month', CURRENT_DATE) + interval '1 month')::date
            AND v_n = (EXTRACT(YEAR FROM age(date_trunc('month', v_end), date_trunc('month', CURRENT_DATE))) * 12
                     + EXTRACT(MONTH FROM age(date_trunc('month', v_end), date_trunc('month', CURRENT_DATE)))),
            format('%s row(s) from %s', v_n, v_txt));

        -- A class that exists only in ANOTHER session is refused for the current one.
        INSERT INTO academic.academic_classes(tenant_id, school_id, academic_year_id, class_name, display_order, created_by)
        VALUES (c_tenant, c_school, v_tgtid, 'ZZ Next Only', 99, c_user);
        BEGIN
            c := 'h7';
            CALL core.sp_student_update(c_tenant, c_school, c_user, v_sid, p_student_name => 'ZZ Mal Mover',
                 p_class_name => 'ZZ Next Only', p_section => 'A', p_result => c);
            CLOSE c;
            PERFORM pg_temp.chk('H7 a class from another session is refused', FALSE, 'accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('H7 a class from another session is refused', TRUE, SQLERRM);
        END;

        BEGIN
            c := 'h8';
            CALL core.sp_student_update(c_tenant, c_school, c_user, v_sid, p_student_name => 'ZZ Mal Mover',
                 p_class_name => '6', p_section => 'ZZ No Such Section', p_result => c);
            CLOSE c;
            PERFORM pg_temp.chk('H8 a section the class does not have is refused', FALSE, 'accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('H8 a section the class does not have is refused', TRUE, SQLERRM);
        END;
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- I. Scope ---------------------------------------------';

    v_sid := pg_temp.admit('ZZ-MAL-I1', 'ZZ Mal Scope', v_class, v_sec, v_year,
        jsonb_build_array(jsonb_build_object('feeHeadName','ZZ Admission','frequency','One Time','amount',1000)));
    SELECT ledger_id INTO v_lid FROM core.student_ledger WHERE student_id = v_sid;
    PERFORM pg_temp.collect(v_sid, jsonb_build_array(jsonb_build_object('ledgerId', v_lid, 'amount', 1000, 'concession', 0)));

    BEGIN
        c := 'i1';
        CALL core.sp_student_exit('Exit', 23, 33, c_user, v_sid, 'Transfer', CURRENT_DATE, 'x', c);
        CLOSE c;
        PERFORM pg_temp.chk('I1 another school cannot exit our student', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('I1 another school cannot exit our student', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'i2';
        CALL core.sp_fee_refund_record(23, 33, c_user, v_sid, v_lid, 1000, 'Cash', 'x', NULL, c);
        CLOSE c;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    SELECT refund_amount INTO v_dec FROM core.student_ledger WHERE ledger_id = v_lid;
    PERFORM pg_temp.chk_eq('I2 another school cannot refund our student''s fee', v_dec, 0);

    BEGIN
        c := 'i3';
        CALL core.sp_fee_payment_collect(23, 33, c_user, v_sid,
             jsonb_build_array(jsonb_build_object('ledgerId', v_lid, 'amount', 1, 'concession', 0)),
             '[]'::jsonb, 'Cash', NULL, NULL, CURRENT_DATE, NULL, NULL, 0, NULL, NULL, 0, c);
        CLOSE c;
        PERFORM pg_temp.chk('I3 another school cannot collect against our ledger', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('I3 another school cannot collect against our ledger', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'i4';
        CALL core.sp_student_update(23, 33, c_user, v_sid, p_student_name => 'Hijacked', p_result => c);
        CLOSE c;
        PERFORM pg_temp.chk('I4 another school cannot edit our student', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('I4 another school cannot edit our student', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'i5';
        CALL core.sp_fee_receipt_cancel(23, 33, c_user,
             (SELECT receipt_no FROM core.fee_payments WHERE student_id = v_sid LIMIT 1), 'x', NULL, c);
        FETCH c INTO r; CLOSE c;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    SELECT COUNT(*) INTO v_n FROM core.fee_payments WHERE student_id = v_sid AND is_cancelled;
    PERFORM pg_temp.chk_eq('I5 another school cannot cancel our receipt', v_n, 0);

    BEGIN
        c := 'i6';
        CALL core.sp_admission_manage('SaveAdmission', 1, 0, c_user, NULL, 'ZZ-MAL-I6', NULL, 'ZZ Platform',
             'Male', DATE '2016-01-01', v_class, v_sec, v_year, CURRENT_DATE, p_result => c);
        FETCH c INTO r; CLOSE c;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    SELECT COUNT(*) INTO v_n FROM core.students WHERE admission_no = 'ZZ-MAL-I6';
    PERFORM pg_temp.chk_eq('I6 platform scope cannot admit', v_n, 0);

    SELECT COUNT(*) INTO v_n FROM core.students
     WHERE admission_no LIKE 'ZZ-MAL-%' AND (tenant_id <> c_tenant OR school_id <> c_school);
    PERFORM pg_temp.chk_eq('I7 nothing we admitted landed in another school', v_n, 0);
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
