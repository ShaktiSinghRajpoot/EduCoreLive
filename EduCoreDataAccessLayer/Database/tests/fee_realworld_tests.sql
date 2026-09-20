-- ============================================================================
-- THE WHOLE FEE FLOW, UNDER EVERY WORKFLOW SETTING.
--
-- The other suites each test one module. This one asks the question a school
-- would ask: with MY settings, does the right money end up on the right ledger?
--
-- It runs the same family through the same flow four times, changing only the
-- Admission Workflow switches, and checks the ledger and the cash after each.
--
--   1. Registration off, no collection at admission
--   2. Registration on, fee taken, then admission
--   3. Collection at admission
--   4. Charge from session start vs from the admission month
--
-- WHAT THIS CANNOT TEST, AND WHY IT STILL MATTERS.
-- `collect_fee_at_admission` is enforced in AdmissionController, not in the
-- procedures, so from here both states have to be simulated: the ON case by
-- collecting, the OFF case by not collecting. What IS tested is that each
-- produces the right ledger and the right money — which is the part a bug would
-- show up in.
--
-- Runs inside ONE transaction and ROLLS BACK.
--
--     psql ... -f fee_realworld_tests.sql
-- ============================================================================

\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE TEMP TABLE _t(id serial, name text, ok boolean, detail text) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.chk(p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO _t(name, ok, detail) VALUES (p_name, p_ok, p_detail);
    RAISE NOTICE '  [%] %  %', CASE WHEN p_ok THEN 'PASS' ELSE 'FAIL' END, rpad(p_name, 58), p_detail;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.chk_eq(p_name text, p_got numeric, p_want numeric)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.chk(p_name, ROUND(COALESCE(p_got,0),2) = ROUND(COALESCE(p_want,0),2),
                        format('got %s, expected %s', COALESCE(p_got::text,'NULL'), p_want));
END $$;

-- Set the school's switches for the run that follows.
CREATE OR REPLACE FUNCTION pg_temp.workflow(
    p_tenant integer, p_school integer, p_user integer,
    p_registration boolean, p_required boolean, p_collect boolean, p_charge text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE c refcursor := ('wf_' || md5(clock_timestamp()::text))::refcursor;
BEGIN
    CALL core.sp_school_admin_admission_workflow_manage(
         p_operation => 'SaveAdmissionWorkflow',
         p_tenant_id => p_tenant, p_school_id => p_school, p_action_user_id => p_user,
         p_enable_registration => p_registration,
         p_registration_required_before_admission => p_required,
         p_enable_registration_fee => p_registration,
         p_collect_fee_at_admission => p_collect,
         p_charge_fees_from => p_charge,
         p_result => c);
END $$;

-- What a student currently owes, has paid, and was let off.
CREATE OR REPLACE FUNCTION pg_temp.ledger(p_student integer,
    OUT billed numeric, OUT paid numeric, OUT waived numeric,
    OUT outstanding numeric, OUT monthly_rows integer)
RETURNS record LANGUAGE plpgsql AS $$
BEGIN
    -- The OUT name is 'waived', not 'concession': plpgsql would otherwise not
    -- know whether the column or the parameter was meant.
    SELECT COALESCE(SUM(l.amount_due),0), COALESCE(SUM(l.amount_paid),0),
           COALESCE(SUM(l.concession),0),
           COALESCE(SUM(l.amount_due - l.amount_paid - COALESCE(l.concession,0)),0),
           COUNT(*) FILTER (WHERE l.frequency = 'Monthly')
      INTO billed, paid, waived, outstanding, monthly_rows
      FROM core.student_ledger l WHERE l.student_id = p_student;
END $$;


DO $suite$
DECLARE
    c_tenant CONSTANT integer := 24;
    c_school CONSTANT integer := 34;
    c_user   CONSTANT integer := 39;
    c_month  CONSTANT numeric := 1000;     -- monthly tuition
    c_admfee CONSTANT numeric := 5000;     -- one-time admission charge

    v_year varchar; v_start date; v_end date; v_yid integer;
    v_class varchar; v_sec varchar;
    v_full integer;       -- months in the session
    v_left integer;       -- months from this month to session end

    v_plan jsonb;
    c refcursor;
    v_eid integer; v_sid integer; v_lid integer;
    v_n integer; v_dec numeric; v_txt text;
    k_ok boolean; k_msg text; k_rcpt varchar; k_amt numeric;
    r record;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '====== THE FEE FLOW UNDER EVERY WORKFLOW SETTING ======';

    SELECT academic_year_id, academic_year_name, start_date, end_date
      INTO v_yid, v_year, v_start, v_end
      FROM academic.academic_years
     WHERE tenant_id = c_tenant AND school_id = c_school AND COALESCE(is_current, FALSE) LIMIT 1;

    SELECT class_name INTO v_class FROM academic.academic_classes
     WHERE tenant_id = c_tenant AND school_id = c_school AND academic_year_id = v_yid
       AND COALESCE(is_deleted, FALSE) = FALSE ORDER BY display_order LIMIT 1;
    SELECT s.section_name INTO v_sec FROM academic.academic_class_sections s
     JOIN academic.academic_classes ac ON ac.academic_class_id = s.academic_class_id
     WHERE ac.tenant_id = c_tenant AND ac.school_id = c_school
       AND ac.class_name = v_class AND ac.academic_year_id = v_yid LIMIT 1;

    v_full := (EXTRACT(YEAR FROM v_end)::int*12 + EXTRACT(MONTH FROM v_end)::int)
            - (EXTRACT(YEAR FROM v_start)::int*12 + EXTRACT(MONTH FROM v_start)::int) + 1;
    v_left := (EXTRACT(YEAR FROM v_end)::int*12 + EXTRACT(MONTH FROM v_end)::int)
            - (EXTRACT(YEAR FROM CURRENT_DATE)::int*12 + EXTRACT(MONTH FROM CURRENT_DATE)::int) + 1;

    v_plan := jsonb_build_array(
        jsonb_build_object('feeHeadName','ZZ Admission Fee','frequency','One Time','amount',c_admfee),
        jsonb_build_object('feeHeadName','ZZ Tuition',      'frequency','Monthly', 'amount',c_month));

    RAISE NOTICE 'session % (% to %)  class % / %', v_year, v_start, v_end, v_class, v_sec;
    RAISE NOTICE 'plan: %/month + % one-time.  session has % months, % left from today',
                 c_month, c_admfee, v_full, v_left;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '── RUN 1. Registration OFF, nothing collected at admission ──';
    RAISE NOTICE '   A walk-in family. Everything is billed, nothing is paid yet.';

    PERFORM pg_temp.workflow(c_tenant, c_school, c_user, FALSE, FALSE, FALSE, 'AdmissionMonth');

    c := 'r1';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-RW-1', NULL, 'ZZ Walk In', 'Male', DATE '2015-01-01',
         v_class, v_sec, v_year, CURRENT_DATE, p_fee_plan_json => v_plan, p_result => c);
    SELECT student_id INTO v_sid FROM core.students WHERE admission_no = 'ZZ-RW-1';

    SELECT * INTO r FROM pg_temp.ledger(v_sid);
    PERFORM pg_temp.chk_eq('1.1 monthly instalments from this month', r.monthly_rows, v_left);
    PERFORM pg_temp.chk_eq('1.2 billed = months x fee + admission charge',
                           r.billed, v_left * c_month + c_admfee);
    PERFORM pg_temp.chk_eq('1.3 nothing collected', r.paid, 0);
    PERFORM pg_temp.chk_eq('1.4 the whole amount is outstanding', r.outstanding, r.billed);

    SELECT COUNT(*) INTO v_n FROM core.fee_payments
     WHERE student_id = v_sid AND COALESCE(is_cancelled, FALSE) = FALSE;
    PERFORM pg_temp.chk_eq('1.5 no receipt exists for them', v_n, 0);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '── RUN 2. Registration ON: fee first, then admission ───────';
    RAISE NOTICE '   The family pays to register, then joins. Both must be visible.';

    PERFORM pg_temp.workflow(c_tenant, c_school, c_user, TRUE, TRUE, FALSE, 'AdmissionMonth');

    c := 'r2a';
    CALL core.sp_enquiry_crm_manage(p_operation => 'SaveEnquiry',
         p_tenant_id => c_tenant, p_school_id => c_school, p_action_user_id => c_user,
         p_student_name => 'ZZ Registered', p_gender => 'Male',
         p_class_name => v_class, p_session => v_year,
         p_mobile => '9990000001', p_status => 'New', p_result => c);
    SELECT enquiry_id INTO v_eid FROM core.enquiries
     WHERE student_name = 'ZZ Registered' ORDER BY enquiry_id DESC LIMIT 1;

    c := 'r2b';
    CALL core.sp_enquiry_register(p_tenant_id => c_tenant, p_school_id => c_school,
         p_action_user_id => c_user, p_enquiry_id => v_eid, p_auto_generate => TRUE, p_result => c);

    c := 'r2c';
    CALL core.sp_registration_fee_record(
         p_tenant_id => c_tenant, p_school_id => c_school, p_action_user_id => c_user,
         p_enquiry_id => v_eid, p_amount => 500, p_payment_mode => 'Cash',
         p_payment_date => CURRENT_DATE, p_fin_year => v_year, p_result => c);
    FETCH c INTO k_ok, k_msg, k_rcpt;
    PERFORM pg_temp.chk('2.1 registration fee taken', COALESCE(k_ok, FALSE), k_msg);

    -- A registration fee is NOT a due on a student who does not exist. It must
    -- not conjure a ledger, or the family would appear to owe what they just paid.
    SELECT COUNT(*) INTO v_n FROM core.student_ledger l
      JOIN core.students s ON s.student_id = l.student_id
     WHERE s.enquiry_id = v_eid;
    PERFORM pg_temp.chk_eq('2.2 it created no ledger row (there is no student yet)', v_n, 0);

    c := 'r2d';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-RW-2', NULL, 'ZZ Registered', 'Male', DATE '2015-01-01',
         v_class, v_sec, v_year, CURRENT_DATE,
         p_enquiry_id => v_eid, p_fee_plan_json => v_plan, p_result => c);
    SELECT student_id INTO v_sid FROM core.students WHERE admission_no = 'ZZ-RW-2';

    SELECT * INTO r FROM pg_temp.ledger(v_sid);
    PERFORM pg_temp.chk_eq('2.3 the admission ledger is the same as a walk-in''s',
                           r.billed, v_left * c_month + c_admfee);

    -- The 500 already paid must NOT reduce the tuition they owe...
    PERFORM pg_temp.chk_eq('2.4 the registration fee did not settle any due', r.paid, 0);

    -- ...but it must be visible on the child's record, not stranded on the enquiry.
    SELECT COALESCE(SUM(amount),0) INTO v_dec FROM core.fee_payments
     WHERE student_id = v_sid AND COALESCE(is_cancelled, FALSE) = FALSE;
    PERFORM pg_temp.chk_eq('2.5 ...and the 500 IS on the student record', v_dec, 500);

    -- The two facts a school needs to hold at once: they owe the full fee, and
    -- they have already paid 500 for something else.
    PERFORM pg_temp.chk_eq('2.6 they still owe the whole fee', r.outstanding, r.billed);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '── RUN 3. Collecting at admission ─────────────────────────';
    RAISE NOTICE '   The cashier takes money at the desk. It must land on the';
    RAISE NOTICE '   admission charge first, not on next March''s tuition.';

    PERFORM pg_temp.workflow(c_tenant, c_school, c_user, FALSE, FALSE, TRUE, 'AdmissionMonth');

    c := 'r3a';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-RW-3', NULL, 'ZZ Pays Now', 'Male', DATE '2015-01-01',
         v_class, v_sec, v_year, CURRENT_DATE, p_fee_plan_json => v_plan, p_result => c);
    SELECT student_id INTO v_sid FROM core.students WHERE admission_no = 'ZZ-RW-3';

    -- What the controller's allocation does: admission-point charges first.
    SELECT ledger_id INTO v_lid FROM core.student_ledger
     WHERE student_id = v_sid AND fee_head_name = 'ZZ Admission Fee';

    c := 'r3b';
    CALL core.sp_fee_payment_collect(c_tenant, c_school, c_user, v_sid,
         jsonb_build_array(jsonb_build_object('ledgerId', v_lid, 'amount', c_admfee, 'concession', 0)),
         '[]'::jsonb, 'Cash', NULL, NULL, CURRENT_DATE, v_year, NULL, 0, NULL, NULL, 0, c);
    FETCH c INTO k_ok, k_msg, k_rcpt, k_amt;
    PERFORM pg_temp.chk_eq('3.1 the admission charge is settled', k_amt, c_admfee);

    SELECT status INTO v_txt FROM core.student_ledger WHERE ledger_id = v_lid;
    PERFORM pg_temp.chk('3.2 that row reads Paid', v_txt = 'Paid', format('status %s', v_txt));

    SELECT * INTO r FROM pg_temp.ledger(v_sid);
    PERFORM pg_temp.chk_eq('3.3 what is left is exactly the year''s tuition',
                           r.outstanding, v_left * c_month);

    SELECT COUNT(*) INTO v_n FROM core.student_ledger
     WHERE student_id = v_sid AND frequency = 'Monthly' AND COALESCE(amount_paid,0) > 0;
    PERFORM pg_temp.chk_eq('3.4 no month was settled out of turn', v_n, 0);

    -- The money reaches the drawer the same day it is taken.
    DECLARE d_ok boolean; d_msg text; d_exp numeric; d_diff numeric;
    BEGIN
        c := 'r3c';
        CALL core.sp_fee_day_close(c_tenant, c_school, c_user, CURRENT_DATE, 0, 'check', c);
        FETCH c INTO d_ok, d_msg, d_exp, d_diff;
        PERFORM pg_temp.chk('3.5 the cash is in today''s drawer', d_exp >= c_admfee,
                            format('drawer expects %s', d_exp));
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '── RUN 4. The same family, billed from session start ───────';
    RAISE NOTICE '   Only the switch changes. The fee must change with it.';

    PERFORM pg_temp.workflow(c_tenant, c_school, c_user, FALSE, FALSE, TRUE, 'SessionStart');

    c := 'r4';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-RW-4', NULL, 'ZZ Session Start', 'Male', DATE '2015-01-01',
         v_class, v_sec, v_year, CURRENT_DATE, p_fee_plan_json => v_plan, p_result => c);
    SELECT student_id INTO v_sid FROM core.students WHERE admission_no = 'ZZ-RW-4';

    SELECT * INTO r FROM pg_temp.ledger(v_sid);
    PERFORM pg_temp.chk_eq('4.1 now the WHOLE session is billed', r.monthly_rows, v_full);
    PERFORM pg_temp.chk_eq('4.2 billed = full session + admission charge',
                           r.billed, v_full * c_month + c_admfee);

    -- The difference between the two runs is the months the switch added.
    DECLARE v_am numeric;
    BEGIN
        SELECT COALESCE(SUM(amount_due),0) INTO v_am FROM core.student_ledger
         WHERE student_id = (SELECT student_id FROM core.students WHERE admission_no='ZZ-RW-3');
        PERFORM pg_temp.chk_eq('4.3 the switch is worth exactly the skipped months',
                               r.billed - v_am, (v_full - v_left) * c_month);
        RAISE NOTICE '    same family, same plan: AdmissionMonth bills %, SessionStart bills %',
                     v_am, r.billed;
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '── Across all four runs ───────────────────────────────────';

    -- Whatever the settings, the books hold for every student created here.
    DECLARE bad integer;
    BEGIN
        SELECT COUNT(*) INTO bad FROM core.student_ledger l
         WHERE l.student_id IN (SELECT student_id FROM core.students
                                WHERE admission_no LIKE 'ZZ-RW-%')
           AND (l.amount_paid + COALESCE(l.concession,0)) > l.amount_due + 0.01;
        PERFORM pg_temp.chk_eq('5.1 no row was over-collected under any setting', bad, 0);

        SELECT COUNT(*) INTO bad FROM core.student_ledger l
         WHERE l.student_id IN (SELECT student_id FROM core.students
                                WHERE admission_no LIKE 'ZZ-RW-%')
           AND (l.due_date < DATE_TRUNC('month', v_start)::date
                OR l.due_date > DATE_TRUNC('month', v_end)::date + INTERVAL '1 month');
        PERFORM pg_temp.chk_eq('5.2 no instalment fell outside the session', bad, 0);

        -- The ledger and the receipts agree for every one of them.
        SELECT COUNT(*) INTO bad FROM (
            SELECT s.student_id,
                   COALESCE((SELECT SUM(amount_paid) FROM core.student_ledger
                             WHERE student_id = s.student_id), 0) AS led,
                   COALESCE((SELECT SUM(d.amount) FROM core.fee_payment_details d
                             JOIN core.fee_payments p ON p.payment_id = d.payment_id
                             WHERE p.student_id = s.student_id
                               AND COALESCE(p.is_cancelled, FALSE) = FALSE
                               AND d.ledger_id IS NOT NULL), 0) AS rec
            FROM core.students s WHERE s.admission_no LIKE 'ZZ-RW-%') t
         WHERE ROUND(led,2) <> ROUND(rec,2);
        PERFORM pg_temp.chk_eq('5.3 ledger and receipts agree for every student', bad, 0);
    END;

    -- And a school that switches settings does not disturb what is already billed.
    SELECT COALESCE(SUM(amount_due),0) INTO v_dec FROM core.student_ledger
     WHERE student_id = (SELECT student_id FROM core.students WHERE admission_no='ZZ-RW-1');
    PERFORM pg_temp.chk_eq('5.4 run 1''s ledger is untouched by later switches',
                           v_dec, v_left * c_month + c_admfee);
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
            RAISE NOTICE '   %  %', rpad(r.name, 58), r.detail;
        END LOOP;
    END IF;
    RAISE NOTICE '';
END
$sum$;

ROLLBACK;
