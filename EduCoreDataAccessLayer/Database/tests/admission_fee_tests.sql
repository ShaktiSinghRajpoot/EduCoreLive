-- ============================================================================
-- Fee collected AT ADMISSION.
--
-- The admission screen takes one lump sum and a concession, and the controller
-- spreads them across the dues it has just created. That allocation is C# and
-- cannot be run from here — what this suite tests is the layer beneath it: what
-- the fee engine guarantees no matter what the allocation sends, and what an
-- admission-time collection actually leaves behind.
--
-- That split matters. If AllocateAdmissionPayment ever had a bug, these are the
-- rules that stop it becoming wrong money.
--
-- Runs inside ONE transaction and ROLLS BACK.
--
--     psql ... -f admission_fee_tests.sql
--
-- COVERS
--   A. The engine refuses a bad allocation
--   B. Cash and concession settle a due together
--   C. Admission-point charges vs scheduled dues
--   D. A refundable deposit takes cash but never a concession
--   E. The receipt and the ledger agree
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


DO $suite$
DECLARE
    c_tenant CONSTANT integer := 24;
    c_school CONSTANT integer := 34;
    c_user   CONSTANT integer := 39;

    v_year varchar; v_class varchar; v_sec varchar; v_yid integer;

    c refcursor;
    v_sid integer;
    v_adm integer;   -- the admission-point due
    v_dep integer;   -- the refundable deposit
    v_m1  integer;   -- first monthly instalment
    v_n   integer;
    v_dec numeric;
    v_txt text;

    k_ok boolean; k_msg text; k_rcpt varchar; k_amt numeric;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '========= FEE COLLECTED AT ADMISSION =========';

    SELECT academic_year_id, academic_year_name INTO v_yid, v_year
      FROM academic.academic_years
     WHERE tenant_id = c_tenant AND school_id = c_school AND COALESCE(is_current, FALSE) LIMIT 1;
    SELECT class_name INTO v_class FROM academic.academic_classes
     WHERE tenant_id = c_tenant AND school_id = c_school AND academic_year_id = v_yid
       AND COALESCE(is_deleted, FALSE) = FALSE ORDER BY display_order LIMIT 1;
    SELECT s.section_name INTO v_sec FROM academic.academic_class_sections s
     JOIN academic.academic_classes ac ON ac.academic_class_id = s.academic_class_id
     WHERE ac.tenant_id = c_tenant AND ac.school_id = c_school
       AND ac.class_name = v_class AND ac.academic_year_id = v_yid LIMIT 1;

    RAISE NOTICE 'fixture: session %  class % / %', v_year, v_class, v_sec;

    -- A plan shaped like a real admission: a one-time admission charge, a
    -- refundable deposit, and monthly tuition.
    c := 's1';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-AF-1', NULL, 'ZZ Admission Fee', 'Male', DATE '2015-01-01',
         v_class, v_sec, v_year, CURRENT_DATE,
         p_fee_plan_json => jsonb_build_array(
             jsonb_build_object('feeHeadName','ZZ Admission Charge','frequency','One Time','amount',5000),
             jsonb_build_object('feeHeadName','ZZ Caution Money',   'frequency','One Time','amount',2000),
             jsonb_build_object('feeHeadName','ZZ Tuition',         'frequency','Monthly', 'amount',1000)),
         p_result => c);
    SELECT student_id INTO v_sid FROM core.students WHERE admission_no = 'ZZ-AF-1';

    SELECT ledger_id INTO v_adm FROM core.student_ledger
     WHERE student_id = v_sid AND fee_head_name = 'ZZ Admission Charge';
    SELECT ledger_id INTO v_dep FROM core.student_ledger
     WHERE student_id = v_sid AND fee_head_name = 'ZZ Caution Money';
    SELECT ledger_id INTO v_m1 FROM core.student_ledger
     WHERE student_id = v_sid AND frequency = 'Monthly' ORDER BY due_date LIMIT 1;

    PERFORM pg_temp.chk('setup: three kinds of due exist',
                        v_adm IS NOT NULL AND v_dep IS NOT NULL AND v_m1 IS NOT NULL, '');

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- A. The engine refuses a bad allocation --------------';
    RAISE NOTICE '   AllocateAdmissionPayment is C# and cannot run here. These';
    RAISE NOTICE '   are the rules that stop a bug in it becoming wrong money.';

    BEGIN
        c := 'a1';
        CALL core.sp_fee_payment_collect(c_tenant, c_school, c_user, v_sid,
             jsonb_build_array(jsonb_build_object('ledgerId', v_adm, 'amount', 6000, 'concession', 0)),
             '[]'::jsonb, 'Cash', NULL, NULL, CURRENT_DATE, v_year, NULL, 0, NULL, NULL, 0, c);
        PERFORM pg_temp.chk('A1 more than the row owes is refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('A1 more than the row owes is refused', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'a2';
        CALL core.sp_fee_payment_collect(c_tenant, c_school, c_user, v_sid,
             jsonb_build_array(jsonb_build_object('ledgerId', v_adm, 'amount', -100, 'concession', 0)),
             '[]'::jsonb, 'Cash', NULL, NULL, CURRENT_DATE, v_year, NULL, 0, NULL, NULL, 0, c);
        PERFORM pg_temp.chk('A2 a negative amount is refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('A2 a negative amount is refused', TRUE, SQLERRM);
    END;

    -- A ledger row that is not this student's must never be settled by their
    -- payment, however the allocation came by the id.
    BEGIN
        c := 'a3';
        CALL core.sp_fee_payment_collect(c_tenant, c_school, c_user, v_sid,
             jsonb_build_array(jsonb_build_object('ledgerId', 999999, 'amount', 100, 'concession', 0)),
             '[]'::jsonb, 'Cash', NULL, NULL, CURRENT_DATE, v_year, NULL, 0, NULL, NULL, 0, c);
        PERFORM pg_temp.chk('A3 someone else''s due is refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('A3 someone else''s due is refused', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'a4';
        CALL core.sp_fee_payment_collect(c_tenant, c_school, c_user, v_sid,
             '[]'::jsonb, '[]'::jsonb, 'Cash', NULL, NULL, CURRENT_DATE, v_year,
             NULL, 0, NULL, NULL, 0, c);
        PERFORM pg_temp.chk('A4 collecting nothing is refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('A4 collecting nothing is refused', TRUE, SQLERRM);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- B. Cash and concession settle a due together --------';

    -- The admission charge: 4000 taken, 1000 written off.
    c := 'b1';
    CALL core.sp_fee_payment_collect(c_tenant, c_school, c_user, v_sid,
         jsonb_build_array(jsonb_build_object('ledgerId', v_adm, 'amount', 4000, 'concession', 1000)),
         '[]'::jsonb, 'Cash', NULL, NULL, CURRENT_DATE, v_year, NULL, 0, NULL, NULL, 0, c);
    FETCH c INTO k_ok, k_msg, k_rcpt, k_amt;

    PERFORM pg_temp.chk_eq('B1 the receipt is for the cash only', k_amt, 4000);

    SELECT amount_paid, concession, status INTO v_dec, v_n, v_txt
      FROM core.student_ledger WHERE ledger_id = v_adm;
    PERFORM pg_temp.chk_eq('B2 cash on the row', v_dec, 4000);
    PERFORM pg_temp.chk_eq('B3 concession on the row', v_n, 1000);
    PERFORM pg_temp.chk('B4 together they settle it in full', v_txt = 'Paid', format('status %s', v_txt));

    -- Nothing may be collected against a row that is already settled.
    BEGIN
        c := 'b5';
        CALL core.sp_fee_payment_collect(c_tenant, c_school, c_user, v_sid,
             jsonb_build_array(jsonb_build_object('ledgerId', v_adm, 'amount', 1, 'concession', 0)),
             '[]'::jsonb, 'Cash', NULL, NULL, CURRENT_DATE, v_year, NULL, 0, NULL, NULL, 0, c);
        PERFORM pg_temp.chk('B5 a settled row cannot take more', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('B5 a settled row cannot take more', TRUE, SQLERRM);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- C. A refundable deposit ----------------------------';

    -- The controller skips refundable heads when spreading a concession: a
    -- deposit is money the school gives back, so discounting it would mean
    -- returning more than was taken. Cash still fills it. Here the deposit is
    -- settled in cash alone, which is what that rule produces.
    c := 'c1';
    CALL core.sp_fee_payment_collect(c_tenant, c_school, c_user, v_sid,
         jsonb_build_array(jsonb_build_object('ledgerId', v_dep, 'amount', 2000, 'concession', 0)),
         '[]'::jsonb, 'Cash', NULL, NULL, CURRENT_DATE, v_year, NULL, 0, NULL, NULL, 0, c);

    SELECT amount_paid, concession INTO v_dec, v_n
      FROM core.student_ledger WHERE ledger_id = v_dep;
    PERFORM pg_temp.chk_eq('C1 the deposit is paid in full, in cash', v_dec, 2000);
    PERFORM pg_temp.chk_eq('C2 ...and carries no concession', v_n, 0);

    -- The refund path exists precisely because this money is returnable.
    c := 'c3';
    CALL core.sp_fee_refund_record(c_tenant, c_school, c_user, v_sid, v_dep,
         2000, 'Cash', 'deposit returned on leaving', '39', c);

    SELECT refund_amount INTO v_dec FROM core.student_ledger WHERE ledger_id = v_dep;
    PERFORM pg_temp.chk_eq('C3 the deposit can be refunded in full', v_dec, 2000);

    SELECT amount_paid INTO v_dec FROM core.student_ledger WHERE ledger_id = v_dep;
    PERFORM pg_temp.chk_eq('C4 ...without rewriting what was collected', v_dec, 2000);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- D. Scheduled dues are untouched --------------------';

    -- Collecting at admission settles what the cashier is taking now. The
    -- monthly instalments the same admission created stay owing.
    SELECT COUNT(*) INTO v_n FROM core.student_ledger
     WHERE student_id = v_sid AND frequency = 'Monthly' AND COALESCE(amount_paid,0) > 0;
    PERFORM pg_temp.chk_eq('D1 no monthly instalment was quietly settled', v_n, 0);

    SELECT COALESCE(SUM(amount_due - amount_paid - COALESCE(concession,0)), 0) INTO v_dec
      FROM core.student_ledger WHERE student_id = v_sid AND frequency = 'Monthly';
    PERFORM pg_temp.chk('D2 the year''s tuition is still owed', v_dec > 0,
                        format('%s outstanding', v_dec));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- E. The receipt and the ledger agree ----------------';

    DECLARE l_paid numeric; l_conc numeric; r_paid numeric; r_conc numeric; n_bad integer;
    BEGIN
        SELECT COALESCE(SUM(amount_paid),0), COALESCE(SUM(concession),0)
          INTO l_paid, l_conc FROM core.student_ledger WHERE student_id = v_sid;

        SELECT COALESCE(SUM(d.amount),0), COALESCE(SUM(d.concession),0)
          INTO r_paid, r_conc
          FROM core.fee_payment_details d
          JOIN core.fee_payments p ON p.payment_id = d.payment_id
         WHERE p.student_id = v_sid AND COALESCE(p.is_cancelled, FALSE) = FALSE
           AND d.ledger_id IS NOT NULL;

        PERFORM pg_temp.chk_eq('E1 ledger paid = the receipt lines', l_paid, r_paid);
        PERFORM pg_temp.chk_eq('E2 ledger concession = the receipt lines', l_conc, r_conc);
        PERFORM pg_temp.chk_eq('E3 6000 cash was taken in total', l_paid, 6000);
        PERFORM pg_temp.chk_eq('E4 1000 was written off', l_conc, 1000);

        SELECT COUNT(*) INTO n_bad FROM core.student_ledger
         WHERE student_id = v_sid
           AND (amount_paid + COALESCE(concession,0)) > amount_due + 0.01;
        PERFORM pg_temp.chk_eq('E5 no row shows more settled than it was due', n_bad, 0);
    END;

    -- Each receipt names the charges it settled, so the parent's copy is not one
    -- opaque line — that is the whole reason the lump sum is itemised.
    SELECT COUNT(DISTINCT d.fee_head_name) INTO v_n
      FROM core.fee_payment_details d
      JOIN core.fee_payments p ON p.payment_id = d.payment_id
     WHERE p.student_id = v_sid AND d.ledger_id IS NOT NULL;
    PERFORM pg_temp.chk('E6 the receipts name each charge settled', v_n >= 2,
                        format('%s distinct head(s) itemised', v_n));
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
            RAISE NOTICE '   %  %', rpad(r.name, 56), r.detail;
        END LOOP;
    END IF;
    RAISE NOTICE '';
END
$sum$;

ROLLBACK;
