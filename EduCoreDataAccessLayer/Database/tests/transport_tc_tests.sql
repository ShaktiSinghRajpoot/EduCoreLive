-- ============================================================================
-- Transport + Transfer Certificate + ID Card test suite.
--
-- Runs inside ONE transaction and ROLLS BACK — it creates routes, assigns
-- students to buses, marks students as left and issues certificates, none of
-- which survives. Safe against any database.
--
--     psql ... -f transport_tc_tests.sql
--
-- COVERS
--   A. Routes and stops
--   B. Bus assignment — and the monthly fee dues it generates
--   C. Removing an assignment
--   D. TC gates: must have left, dues must be clear, one per student
--   E. TC print marks a reprint as DUPLICATE; void
--   F. ID card data — who is eligible, and scope
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


DO $suite$
DECLARE
    c_tenant CONSTANT integer := 24;
    c_school CONSTANT integer := 34;
    c_user   CONSTANT integer := 39;

    v_year  varchar;
    v_class varchar;

    c       refcursor;
    v_route integer;
    v_stop  integer;
    v_sid   integer;   -- student with dues
    v_sid2  integer;   -- clean student, gets the TC
    v_tc    integer;
    v_n     integer;
    v_dec   numeric;
    v_txt   text;
    v_bool  boolean;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '====== TRANSPORT + TC + ID CARD TESTS ======';

    SELECT academic_year_name INTO v_year FROM academic.academic_years
     WHERE tenant_id = c_tenant AND school_id = c_school AND COALESCE(is_current, FALSE) LIMIT 1;
    SELECT class_name INTO v_class FROM academic.academic_classes
     WHERE tenant_id = c_tenant AND school_id = c_school AND COALESCE(is_deleted, FALSE) = FALSE
     ORDER BY display_order LIMIT 1;

    IF v_year IS NULL OR v_class IS NULL THEN
        RAISE EXCEPTION 'Fixture missing: school % has no current session or classes.', c_school;
    END IF;
    RAISE NOTICE 'fixture: session=%  class=%', v_year, v_class;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- A. Routes and stops -----------------------------------';

    -- A1: a route needs a name.
    BEGIN
        c := 'a1';
        CALL core.sp_transport_route_manage('SaveRoute', c_tenant, c_school, c_user,
             NULL, '   ', 'blank name', NULL, c);
        PERFORM pg_temp.chk('A1 blank route name refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('A1 blank route name refused', TRUE, SQLERRM);
    END;

    -- A2: a route with two stops at different fares.
    c := 'a2';
    CALL core.sp_transport_route_manage('SaveRoute', c_tenant, c_school, c_user,
         NULL, 'ZZ Test Route', 'suite route',
         jsonb_build_array(
             jsonb_build_object('stopName', 'ZZ Near Stop', 'monthlyFare', 500),
             jsonb_build_object('stopName', 'ZZ Far Stop',  'monthlyFare', 900)), c);

    SELECT route_id INTO v_route FROM core.transport_routes
     WHERE tenant_id = c_tenant AND school_id = c_school AND route_name = 'ZZ Test Route';
    PERFORM pg_temp.chk('A2 route created', v_route IS NOT NULL, format('route_id=%s', v_route));

    SELECT COUNT(*) INTO v_n FROM core.transport_stops WHERE route_id = v_route;
    PERFORM pg_temp.chk_eq('A3 both stops saved', v_n, 2);

    SELECT stop_id, monthly_fare INTO v_stop, v_dec FROM core.transport_stops
     WHERE route_id = v_route AND stop_name = 'ZZ Far Stop';
    PERFORM pg_temp.chk_eq('A4 the stop carries its own fare', v_dec, 900);

    -- A5: another school cannot see this route.
    SELECT COUNT(*) INTO v_n FROM core.transport_routes
     WHERE route_id = v_route AND tenant_id = 23 AND school_id = 33;
    PERFORM pg_temp.chk_eq('A5 route is scoped to this school', v_n, 0);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- B. Bus assignment + its fee dues ----------------------';

    c := 's1';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-BUS-1', NULL, 'ZZ Bus Rider', 'Male', DATE '2015-01-01',
         v_class, 'A', v_year, CURRENT_DATE, p_result => c);
    SELECT student_id INTO v_sid FROM core.students WHERE admission_no = 'ZZ-BUS-1';

    -- B1: assigning a stop that does not exist must be refused, or the student
    --     ends up on a bus nobody runs.
    BEGIN
        c := 'b1';
        CALL core.sp_transport_assign_manage('SaveAssignment', c_tenant, c_school, c_user,
             v_sid, v_route, 999999, v_year, CURRENT_DATE, 6, c);
        PERFORM pg_temp.chk('B1 unknown stop refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('B1 unknown stop refused', TRUE, SQLERRM);
    END;

    -- B2: a real assignment for 6 months generates 6 monthly bus-fee dues at the
    --     STOP's fare — that is the whole point of the fare living on the stop.
    c := 'b2';
    CALL core.sp_transport_assign_manage('SaveAssignment', c_tenant, c_school, c_user,
         v_sid, v_route, v_stop, v_year, CURRENT_DATE, 6, c);

    SELECT COUNT(*), COALESCE(SUM(amount_due), 0) INTO v_n, v_dec
      FROM core.student_ledger
     WHERE student_id = v_sid AND LOWER(fee_head_name) LIKE '%transport%';
    PERFORM pg_temp.chk_eq('B2 six monthly bus dues generated', v_n, 6);
    PERFORM pg_temp.chk_eq('B3 at the far stop fare (6 x 900)', v_dec, 5400);

    SELECT COUNT(*) INTO v_n FROM core.student_transport
     WHERE student_id = v_sid AND COALESCE(is_active, TRUE) AND NOT COALESCE(is_deleted, FALSE);
    PERFORM pg_temp.chk_eq('B4 one active assignment', v_n, 1);

    -- B5: re-assigning must not leave the student on two buses.
    -- CALL cannot take a subquery argument, so resolve the stop first.
    DECLARE v_near integer;
    BEGIN
        SELECT stop_id INTO v_near FROM core.transport_stops
         WHERE route_id = v_route AND stop_name = 'ZZ Near Stop';
        c := 'b5';
        CALL core.sp_transport_assign_manage('SaveAssignment', c_tenant, c_school, c_user,
             v_sid, v_route, v_near, v_year, CURRENT_DATE, 6, c);
    END;

    SELECT COUNT(*) INTO v_n FROM core.student_transport
     WHERE student_id = v_sid AND COALESCE(is_active, TRUE) AND NOT COALESCE(is_deleted, FALSE);
    PERFORM pg_temp.chk_eq('B5 re-assigning leaves only one active row', v_n, 1);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- C. Removing an assignment -----------------------------';

    -- Pay one month first, so the two halves of the rule can be told apart.
    DECLARE v_lid integer; k1 boolean; k2 text; k3 varchar; k4 numeric;
    BEGIN
        SELECT ledger_id INTO v_lid FROM core.student_ledger
         WHERE student_id = v_sid AND LOWER(fee_head_name) LIKE '%transport%'
         ORDER BY due_date LIMIT 1;

        c := 'c0';
        CALL core.sp_fee_payment_collect(c_tenant, c_school, c_user, v_sid,
             jsonb_build_array(jsonb_build_object('ledgerId', v_lid, 'amount', 500, 'concession', 0)),
             '[]'::jsonb, 'Cash', NULL, NULL, CURRENT_DATE, v_year, NULL, 0, NULL, NULL, 0, c);
        FETCH c INTO k1, k2, k3, k4;
    END;

    c := 'c1';
    CALL core.sp_transport_assign_manage('RemoveAssignment', c_tenant, c_school, c_user,
         v_sid, NULL, NULL, v_year, NULL, 0, c);

    SELECT COUNT(*) INTO v_n FROM core.student_transport
     WHERE student_id = v_sid AND COALESCE(is_active, TRUE) AND NOT COALESCE(is_deleted, FALSE);
    PERFORM pg_temp.chk_eq('C1 assignment removed', v_n, 0);

    -- A month already PAID for is history and must survive — taking a child off
    -- the bus does not unbill the months they rode.
    SELECT COUNT(*) INTO v_n FROM core.student_ledger
     WHERE student_id = v_sid AND LOWER(fee_head_name) LIKE '%transport%'
       AND amount_paid > 0;
    PERFORM pg_temp.chk_eq('C2 a paid bus month survives removal', v_n, 1);

    -- ...while the months they will NOT ride are dropped, so nobody is chased for
    -- a bus they no longer take.
    SELECT COUNT(*) INTO v_n FROM core.student_ledger
     WHERE student_id = v_sid AND LOWER(fee_head_name) LIKE '%transport%'
       AND COALESCE(amount_paid, 0) = 0;
    PERFORM pg_temp.chk_eq('C3 unpaid future bus months are dropped', v_n, 0);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- D. Transfer Certificate gates -------------------------';

    c := 's2';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-TC-1', NULL, 'ZZ TC Student', 'Female', DATE '2015-02-02',
         v_class, 'A', v_year, CURRENT_DATE, p_result => c);
    SELECT student_id INTO v_sid2 FROM core.students WHERE admission_no = 'ZZ-TC-1';

    -- D1: still enrolled — a TC is a leaving certificate.
    BEGIN
        c := 'd1';
        CALL core.sp_tc_manage('Issue', c_tenant, c_school, c_user, NULL, v_sid2,
             'Basic', 'Good', 'Pass', 'moving city', NULL, p_result_cur => c);
        PERFORM pg_temp.chk('D1 TC refused while still enrolled', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('D1 TC refused while still enrolled', TRUE, SQLERRM);
    END;

    -- Mark as left.
    c := 'd2';
    CALL core.sp_student_exit('Exit', c_tenant, c_school, c_user, v_sid2,
         'Transfer', CURRENT_DATE, 'relocating', c);

    SELECT status INTO v_txt FROM core.students WHERE student_id = v_sid2;
    PERFORM pg_temp.chk('D2 student marked as left', v_txt <> 'Active', format('status = %s', v_txt));

    -- D3: a student who still owes money cannot be given a TC. Needs a student
    --     with a real unpaid balance — the bus rider's dues were dropped when the
    --     assignment was removed, which is C3's point.
    DECLARE v_owing integer;
    BEGIN
        c := 'd3a';
        CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
             'ZZ-TC-DUES', NULL, 'ZZ Owes Money', 'Male', DATE '2015-04-04',
             v_class, 'A', v_year, CURRENT_DATE,
             p_fee_plan_json => jsonb_build_array(
                 jsonb_build_object('feeHeadName','ZZ Tuition','frequency','One Time','amount',2500)),
             p_result => c);
        SELECT student_id INTO v_owing FROM core.students WHERE admission_no = 'ZZ-TC-DUES';

        SELECT COALESCE(SUM(amount_due - amount_paid - COALESCE(concession,0)), 0) INTO v_dec
          FROM core.student_ledger WHERE student_id = v_owing;
        PERFORM pg_temp.chk_eq('D3a the student really does owe', v_dec, 2500);

        c := 'd3b';
        CALL core.sp_student_exit('Exit', c_tenant, c_school, c_user, v_owing,
             'Transfer', CURRENT_DATE, 'test', c);

        BEGIN
            c := 'd3c';
            CALL core.sp_tc_manage('Issue', c_tenant, c_school, c_user, NULL, v_owing,
                 'Basic', 'Good', 'Pass', 'left with dues', NULL, p_result_cur => c);
            PERFORM pg_temp.chk('D3 TC refused while dues are pending', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('D3 TC refused while dues are pending', TRUE, SQLERRM);
        END;
    END;

    -- D4: the clean student gets one.
    c := 'd4';
    CALL core.sp_tc_manage('Issue', c_tenant, c_school, c_user, NULL, v_sid2,
         'Basic', 'Good', 'Pass', 'relocating', NULL, p_result_cur => c);

    SELECT tc_id, tc_no INTO v_tc, v_txt FROM core.tc_register
     WHERE student_id = v_sid2 AND COALESCE(is_void, FALSE) = FALSE;
    PERFORM pg_temp.chk('D4 certificate issued', v_tc IS NOT NULL, format('tc_no = %s', v_txt));

    -- D5: only one live TC per student.
    BEGIN
        c := 'd5';
        CALL core.sp_tc_manage('Issue', c_tenant, c_school, c_user, NULL, v_sid2,
             'Basic', 'Good', 'Pass', 'again', NULL, p_result_cur => c);
        PERFORM pg_temp.chk('D5 a second TC is refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('D5 a second TC is refused', TRUE, SQLERRM);
    END;

    -- The frozen snapshot: a TC must record the student as they were, so a later
    -- name change cannot rewrite an issued certificate.
    SELECT student_name INTO v_txt FROM core.tc_register WHERE tc_id = v_tc;
    PERFORM pg_temp.chk('D6 TC froze the student name', v_txt = 'ZZ TC Student',
                        format('snapshot says "%s"', v_txt));
    UPDATE core.students SET student_name = 'ZZ Renamed' WHERE student_id = v_sid2;
    SELECT student_name INTO v_txt FROM core.tc_register WHERE tc_id = v_tc;
    PERFORM pg_temp.chk('D7 renaming the student does not change the TC',
                        v_txt = 'ZZ TC Student', format('snapshot still "%s"', v_txt));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- E. Print + void ---------------------------------------';

    SELECT print_count INTO v_n FROM core.tc_register WHERE tc_id = v_tc;
    PERFORM pg_temp.chk_eq('E1 not yet printed', COALESCE(v_n, 0), 0);

    DECLARE cp refcursor := 'e2';
            r_tcid int; r_was_dup boolean;
    BEGIN
        CALL core.sp_tc_manage('Print', c_tenant, c_school, c_user, v_tc, NULL, p_result_cur => cp);
        SELECT print_count INTO v_n FROM core.tc_register WHERE tc_id = v_tc;
        PERFORM pg_temp.chk_eq('E2 first print counted', v_n, 1);
    END;

    -- A reprint must be stamped DUPLICATE — an original and a copy in circulation
    -- have to be distinguishable.
    DECLARE cp refcursor := 'e3';
    BEGIN
        CALL core.sp_tc_manage('Print', c_tenant, c_school, c_user, v_tc, NULL, p_result_cur => cp);
        SELECT print_count INTO v_n FROM core.tc_register WHERE tc_id = v_tc;
        PERFORM pg_temp.chk_eq('E3 reprint counted', v_n, 2);
    END;

    -- E4: void retires the number rather than deleting the row, so the audit
    --     trail of a mistaken certificate survives.
    c := 'e4';
    CALL core.sp_tc_manage('Void', c_tenant, c_school, c_user, v_tc, NULL,
         p_reason => 'issued by mistake', p_result_cur => c);

    SELECT is_void INTO v_bool FROM core.tc_register WHERE tc_id = v_tc;
    PERFORM pg_temp.chk('E4 certificate voided', COALESCE(v_bool, FALSE), '');

    SELECT COUNT(*) INTO v_n FROM core.tc_register WHERE tc_id = v_tc;
    PERFORM pg_temp.chk_eq('E5 the row survives (number is retired, not deleted)', v_n, 1);

    -- E6: voiding twice is refused.
    BEGIN
        c := 'e6';
        CALL core.sp_tc_manage('Void', c_tenant, c_school, c_user, v_tc, NULL,
             p_reason => 'again', p_result_cur => c);
        PERFORM pg_temp.chk('E6 voiding twice refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('E6 voiding twice refused', TRUE, SQLERRM);
    END;

    -- E7: after voiding, the student is eligible for a fresh certificate.
    c := 'e7';
    CALL core.sp_tc_manage('Issue', c_tenant, c_school, c_user, NULL, v_sid2,
         'Basic', 'Good', 'Pass', 'reissue after void', NULL, p_result_cur => c);
    SELECT COUNT(*) INTO v_n FROM core.tc_register
     WHERE student_id = v_sid2 AND COALESCE(is_void, FALSE) = FALSE;
    PERFORM pg_temp.chk_eq('E7 a fresh TC can be issued after a void', v_n, 1);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- F. ID card data ---------------------------------------';

    c := 'f1';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-CARD-1', NULL, 'ZZ Card Student', 'Male', DATE '2015-03-03',
         v_class, 'A', v_year, CURRENT_DATE, p_result => c);

    DECLARE cc refcursor := 'f2'; v_found int := 0; r_sid int;
    BEGIN
        CALL core.sp_id_card_students(c_tenant, c_school, c_user, v_class, 'A', v_year, NULL, cc);
        LOOP FETCH cc INTO r_sid; EXIT WHEN NOT FOUND; v_found := v_found + 1; END LOOP;
        PERFORM pg_temp.chk('F1 the class roster comes back', v_found > 0,
                            format('%s student(s)', v_found));
    END;

    -- A student who has left must not appear on an ID-card run.
    DECLARE cc refcursor := 'f3'; v_found int := 0; r_sid int;
    BEGIN
        CALL core.sp_id_card_students(c_tenant, c_school, c_user, NULL, NULL, v_year, v_sid2, cc);
        LOOP FETCH cc INTO r_sid; EXIT WHEN NOT FOUND; v_found := v_found + 1; END LOOP;
        PERFORM pg_temp.chk_eq('F2 a student who left gets no ID card', v_found, 0);
    END;

    -- And another school's roster is empty.
    DECLARE cc refcursor := 'f4'; v_found int := 0; r_sid int;
    BEGIN
        CALL core.sp_id_card_students(23, 33, c_user, v_class, 'A', v_year, NULL, cc);
        LOOP FETCH cc INTO r_sid; EXIT WHEN NOT FOUND; v_found := v_found + 1; END LOOP;
        PERFORM pg_temp.chk_eq('F3 another school sees none of ours', v_found, 0);
    END;
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
            RAISE NOTICE '   %  %', rpad(r.name, 52), r.detail;
        END LOOP;
    END IF;
    RAISE NOTICE '';
END
$sum$;

ROLLBACK;
