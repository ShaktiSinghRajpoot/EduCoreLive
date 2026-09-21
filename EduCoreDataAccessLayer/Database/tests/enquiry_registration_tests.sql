-- ============================================================================
-- Enquiry CRM + Registration test suite.
--
-- Runs inside ONE transaction and ROLLS BACK — it creates enquiries, registers
-- them and takes registration fees, none of which survives. Safe to point at any
-- database, including one holding real data.
--
--     psql ... -f enquiry_registration_tests.sql
--
-- COVERS
--   A. Enquiry create / read / scope
--   B. Status changes and the history trail
--   C. The "Admission Confirmed is final" rule
--   D. Follow-ups
--   E. Registration — numbering, the already-admitted guard, idempotency
--   F. Registration fee receipt
--   G. The enquiry -> registration -> admission chain end to end
-- ============================================================================

\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE TEMP TABLE _t(id serial, name text, ok boolean, detail text) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.chk(p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO _t(name, ok, detail) VALUES (p_name, p_ok, p_detail);
    RAISE NOTICE '  [%] %  %', CASE WHEN p_ok THEN 'PASS' ELSE 'FAIL' END, rpad(p_name, 52), p_detail;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.chk_eq(p_name text, p_got numeric, p_want numeric)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.chk(p_name, p_got IS NOT DISTINCT FROM p_want,
                        format('got %s, expected %s', COALESCE(p_got::text,'NULL'), p_want));
END $$;

CREATE OR REPLACE FUNCTION pg_temp.chk_txt(p_name text, p_got text, p_want text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.chk(p_name, p_got IS NOT DISTINCT FROM p_want,
                        format('got "%s", expected "%s"', COALESCE(p_got,'NULL'), p_want));
END $$;


DO $suite$
DECLARE
    c_tenant CONSTANT integer := 24;
    c_school CONSTANT integer := 34;
    c_user   CONSTANT integer := 39;

    v_year  varchar;
    v_class varchar;

    c       refcursor;
    v_eid   integer;
    v_eid2  integer;
    v_n     integer;
    v_txt   text;
    v_reg   text;
    v_sid   integer;
    v_amt   numeric;
    v_rcpt  varchar;
    v_regdate date;

    k_ok    integer;
    k_ok_b  boolean;
    k_msg   text;
    k_id    integer;
    k_txt   text;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '========= ENQUIRY + REGISTRATION TESTS =========';

    SELECT academic_year_name INTO v_year
    FROM academic.academic_years
    WHERE tenant_id = c_tenant AND school_id = c_school AND COALESCE(is_current, FALSE) LIMIT 1;

    SELECT class_name INTO v_class
    FROM academic.academic_classes
    WHERE tenant_id = c_tenant AND school_id = c_school AND COALESCE(is_deleted, FALSE) = FALSE
    ORDER BY display_order LIMIT 1;

    IF v_year IS NULL OR v_class IS NULL THEN
        RAISE EXCEPTION 'Fixture missing: school % has no current session or classes.', c_school;
    END IF;
    RAISE NOTICE 'fixture: session=%  class=%', v_year, v_class;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- A. Enquiry create -------------------------------------';

    c := 'a1';
    CALL core.sp_enquiry_crm_manage(
         p_operation => 'SaveEnquiry', p_tenant_id => c_tenant, p_school_id => c_school,
         p_action_user_id => c_user, p_student_name => 'ZZ Test Child', p_gender => 'Male',
         p_dob => DATE '2018-05-05', p_class_name => v_class, p_session => v_year,
         p_parent_name => 'ZZ Parent', p_father_mobile => '9990000001',
         p_mobile => '9990000001', p_city => 'Testville',
         p_lead_source => 'Walk-in', p_priority => 'High', p_status => 'New',
         p_next_followup_date => CURRENT_DATE + 3, p_notes => 'created by test suite',
         p_result => c);

    SELECT enquiry_id INTO v_eid FROM core.enquiries
     WHERE tenant_id = c_tenant AND school_id = c_school AND student_name = 'ZZ Test Child'
     ORDER BY enquiry_id DESC LIMIT 1;
    PERFORM pg_temp.chk('A1 enquiry created', v_eid IS NOT NULL, format('enquiry_id=%s', v_eid));

    SELECT status, is_active INTO v_txt, k_ok_b FROM core.enquiries WHERE enquiry_id = v_eid;
    PERFORM pg_temp.chk_txt('A2 new enquiry starts as New', v_txt, 'New');
    PERFORM pg_temp.chk('A3 new enquiry is active', COALESCE(k_ok_b, FALSE), '');

    -- The CRM list only shows active rows for THIS school.
    SELECT COUNT(*) INTO v_n FROM core.enquiries
     WHERE enquiry_id = v_eid AND tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk_eq('A4 enquiry is scoped to this school', v_n, 1);

    SELECT COUNT(*) INTO v_n FROM core.enquiries
     WHERE enquiry_id = v_eid AND tenant_id = 23 AND school_id = 33;
    PERFORM pg_temp.chk_eq('A5 another school cannot see it', v_n, 0);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- B. Status changes + history ---------------------------';

    c := 'b1';
    CALL core.sp_enquiry_crm_manage(
         p_operation => 'UpdateStatus', p_tenant_id => c_tenant, p_school_id => c_school,
         p_action_user_id => c_user, p_enquiry_id => v_eid,
         p_status => 'Interested', p_lost_reason => NULL, p_notes => 'warmed up', p_result => c);

    SELECT status INTO v_txt FROM core.enquiries WHERE enquiry_id = v_eid;
    PERFORM pg_temp.chk_txt('B1 status moved to Interested', v_txt, 'Interested');

    SELECT COUNT(*) INTO v_n FROM core.enquiry_status_history
     WHERE enquiry_id = v_eid AND status_to = 'Interested';
    PERFORM pg_temp.chk_eq('B2 the change is recorded in history', v_n, 1);

    SELECT status_from INTO v_txt FROM core.enquiry_status_history
     WHERE enquiry_id = v_eid AND status_to = 'Interested' LIMIT 1;
    PERFORM pg_temp.chk_txt('B3 history remembers what it came from', v_txt, 'New');

    -- Setting the SAME status again must not add a second history row.
    SELECT COUNT(*) INTO v_n FROM core.enquiry_status_history WHERE enquiry_id = v_eid;
    c := 'b4';
    CALL core.sp_enquiry_crm_manage(
         p_operation => 'UpdateStatus', p_tenant_id => c_tenant, p_school_id => c_school,
         p_action_user_id => c_user, p_enquiry_id => v_eid,
         p_status => 'Interested', p_lost_reason => NULL, p_notes => 'same again', p_result => c);
    SELECT COUNT(*) INTO v_n FROM core.enquiry_status_history WHERE enquiry_id = v_eid;
    PERFORM pg_temp.chk_eq('B4 re-setting the same status adds no history', v_n, 2);

    -- A lost status must capture the reason, or the CRM cannot report why.
    c := 'b5';
    CALL core.sp_enquiry_crm_manage(
         p_operation => 'UpdateStatus', p_tenant_id => c_tenant, p_school_id => c_school,
         p_action_user_id => c_user, p_enquiry_id => v_eid,
         p_status => 'Not Interested', p_lost_reason => 'too far', p_notes => 'lost', p_result => c);
    SELECT lost_reason INTO v_txt FROM core.enquiries WHERE enquiry_id = v_eid;
    PERFORM pg_temp.chk_txt('B5 lost reason is stored', v_txt, 'too far');

    -- ...and clearing back to a live status must clear it, or a won lead keeps
    -- carrying the reason it was once lost for.
    c := 'b6';
    CALL core.sp_enquiry_crm_manage(
         p_operation => 'UpdateStatus', p_tenant_id => c_tenant, p_school_id => c_school,
         p_action_user_id => c_user, p_enquiry_id => v_eid,
         p_status => 'Interested', p_lost_reason => NULL, p_notes => 'back in play', p_result => c);
    SELECT lost_reason INTO v_txt FROM core.enquiries WHERE enquiry_id = v_eid;
    PERFORM pg_temp.chk('B6 lost reason cleared when it goes live again',
                        v_txt IS NULL, format('lost_reason is %s', COALESCE('"'||v_txt||'"','NULL')));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- C. Follow-ups -----------------------------------------';

    c := 'c1';
    CALL core.sp_enquiry_followup_manage(
         p_operation => 'LogFollowup', p_tenant_id => c_tenant, p_school_id => c_school,
         p_action_user_id => c_user, p_enquiry_id => v_eid,
         p_followup_type => 'Call', p_outcome => 'Spoke to parent',
         p_notes => 'will visit saturday', p_next_followup_date => CURRENT_DATE + 7,
         p_result => c);

    SELECT COUNT(*) INTO v_n FROM core.enquiry_followups WHERE enquiry_id = v_eid;
    PERFORM pg_temp.chk_eq('C1 follow-up recorded', v_n, 1);

    SELECT next_followup_date INTO v_txt FROM core.enquiries WHERE enquiry_id = v_eid;
    PERFORM pg_temp.chk('C2 next follow-up date carried onto the enquiry',
                        (SELECT next_followup_date::date FROM core.enquiries WHERE enquiry_id = v_eid) = CURRENT_DATE + 7,
                        format('enquiry says %s', (SELECT next_followup_date FROM core.enquiries WHERE enquiry_id = v_eid)));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- D. Registration ---------------------------------------';

    c := 'd1';
    CALL core.sp_enquiry_register(p_tenant_id => c_tenant, p_school_id => c_school,
         p_action_user_id => c_user, p_enquiry_id => v_eid, p_auto_generate => TRUE, p_result => c);
    FETCH c INTO k_ok_b, k_msg, v_reg;
    PERFORM pg_temp.chk('D1 registration succeeds', COALESCE(k_ok_b, FALSE), k_msg);
    PERFORM pg_temp.chk('D2 a registration number was generated',
                        v_reg IS NOT NULL AND length(v_reg) > 0, format('reg no = "%s"', v_reg));

    SELECT registration_number, registration_date INTO v_txt, v_regdate
      FROM core.enquiries WHERE enquiry_id = v_eid;
    PERFORM pg_temp.chk_txt('D3 number stored on the enquiry', v_txt, v_reg);
    PERFORM pg_temp.chk('D4 registration date stamped', v_regdate IS NOT NULL,
                        format('date = %s', v_regdate));

    -- Registering the same enquiry again must not mint a second number.
    c := 'd5';
    CALL core.sp_enquiry_register(p_tenant_id => c_tenant, p_school_id => c_school,
         p_action_user_id => c_user, p_enquiry_id => v_eid, p_auto_generate => TRUE, p_result => c);
    FETCH c INTO k_ok_b, k_msg, k_txt;
    PERFORM pg_temp.chk_txt('D5 re-registering keeps the same number', k_txt, v_reg);

    SELECT COUNT(*) INTO v_n FROM core.enquiries
     WHERE tenant_id = c_tenant AND school_id = c_school AND registration_number = v_reg;
    PERFORM pg_temp.chk_eq('D6 the number is not duplicated', v_n, 1);

    -- Another school cannot register this enquiry.
    BEGIN
        c := 'd7';
        CALL core.sp_enquiry_register(p_tenant_id => 23, p_school_id => 33,
             p_action_user_id => c_user, p_enquiry_id => v_eid, p_auto_generate => TRUE, p_result => c);
        PERFORM pg_temp.chk('D7 cross-school registration refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('D7 cross-school registration refused', TRUE, SQLERRM);
    END;

    -- A manual number with auto-generate off, and none supplied, must be refused.
    c := 'd8';
    CALL core.sp_enquiry_crm_manage(
         p_operation => 'SaveEnquiry', p_tenant_id => c_tenant, p_school_id => c_school,
         p_action_user_id => c_user, p_student_name => 'ZZ Manual Reg', p_gender => 'Female',
         p_dob => DATE '2018-06-06', p_class_name => v_class, p_session => v_year,
         p_parent_name => 'ZZ P2', p_mobile => '9990000003',
         p_lead_source => 'Walk-in', p_priority => 'Medium', p_status => 'New',
         p_result => c);
    SELECT enquiry_id INTO v_eid2 FROM core.enquiries
     WHERE student_name = 'ZZ Manual Reg' ORDER BY enquiry_id DESC LIMIT 1;

    BEGIN
        c := 'd8b';
        CALL core.sp_enquiry_register(p_tenant_id => c_tenant, p_school_id => c_school,
             p_action_user_id => c_user, p_enquiry_id => v_eid2, p_auto_generate => FALSE, p_result => c);
        PERFORM pg_temp.chk('D8 no number + no auto-generate is refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('D8 no number + no auto-generate is refused', TRUE, SQLERRM);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- E. Registration fee -----------------------------------';

    c := 'e1';
    CALL core.sp_registration_fee_record(
         p_tenant_id => c_tenant, p_school_id => c_school, p_action_user_id => c_user,
         p_enquiry_id => v_eid, p_amount => 500, p_payment_mode => 'Cash',
         p_remarks => 'reg fee', p_payment_date => CURRENT_DATE, p_fin_year => v_year,
         p_result => c);
    FETCH c INTO k_ok_b, k_msg, v_rcpt;
    PERFORM pg_temp.chk('E1 registration fee recorded', COALESCE(k_ok_b, FALSE), k_msg);

    PERFORM pg_temp.chk('E2 receipt number has no space',
                        v_rcpt IS NOT NULL AND position(' ' in v_rcpt) = 0,
                        format('receipt = "%s"', v_rcpt));

    SELECT COALESCE(SUM(amount),0) INTO v_amt FROM core.fee_payments
     WHERE enquiry_id = v_eid AND COALESCE(is_cancelled, FALSE) = FALSE;
    PERFORM pg_temp.chk_eq('E3 the money is on the receipt', v_amt, 500);

    -- A registration-fee receipt belongs to an enquiry, not a student.
    SELECT student_id INTO v_sid FROM core.fee_payments WHERE receipt_no = v_rcpt;
    PERFORM pg_temp.chk('E4 receipt is tied to the enquiry, not a student',
                        v_sid IS NULL OR v_sid = 0, format('student_id = %s', COALESCE(v_sid::text,'NULL')));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- F. Enquiry -> admission chain -------------------------';

    c := 'f1';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-FROM-ENQ', NULL, 'ZZ Test Child', 'Male', DATE '2018-05-05',
         v_class, 'A', v_year, CURRENT_DATE,
         p_enquiry_id => v_eid, p_result => c);

    SELECT student_id INTO v_sid FROM core.students WHERE admission_no = 'ZZ-FROM-ENQ';
    PERFORM pg_temp.chk('F1 student admitted from the enquiry', v_sid IS NOT NULL, format('student_id=%s', v_sid));

    SELECT enquiry_id INTO v_n FROM core.students WHERE student_id = v_sid;
    PERFORM pg_temp.chk_eq('F2 student remembers which enquiry it came from', v_n, v_eid);

    -- Once admitted, the enquiry must not be registerable again.
    BEGIN
        c := 'f3';
        CALL core.sp_enquiry_register(p_tenant_id => c_tenant, p_school_id => c_school,
         p_action_user_id => c_user, p_enquiry_id => v_eid, p_auto_generate => TRUE, p_result => c);
        FETCH c INTO k_ok_b, k_msg, k_txt;
        PERFORM pg_temp.chk('F3 an admitted enquiry cannot be re-registered',
                            NOT COALESCE(k_ok_b, TRUE), COALESCE(k_msg,'it was accepted'));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('F3 an admitted enquiry cannot be re-registered', TRUE, SQLERRM);
    END;

    -- And its status cannot be walked backwards once admission is confirmed.
    UPDATE core.enquiries SET status = 'Admission Confirmed' WHERE enquiry_id = v_eid;
    c := 'f4';
    CALL core.sp_enquiry_crm_manage(
         p_operation => 'UpdateStatus', p_tenant_id => c_tenant, p_school_id => c_school,
         p_action_user_id => c_user, p_enquiry_id => v_eid,
         p_status => 'Not Interested', p_lost_reason => 'changed mind', p_notes => 'undo', p_result => c);
    FETCH c INTO k_ok, k_msg;
    PERFORM pg_temp.chk('F4 status is final after Admission Confirmed',
                        COALESCE(k_ok,1) = 0, COALESCE(k_msg,''));

    SELECT status INTO v_txt FROM core.enquiries WHERE enquiry_id = v_eid;
    PERFORM pg_temp.chk_txt('F5 the status really did not change', v_txt, 'Admission Confirmed');
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
            RAISE NOTICE '   %  %', rpad(r.name, 52), r.detail;
        END LOOP;
    END IF;
    RAISE NOTICE '';
END
$sum$;

ROLLBACK;
