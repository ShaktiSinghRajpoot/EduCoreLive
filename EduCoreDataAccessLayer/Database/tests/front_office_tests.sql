-- Front office (front_office.sql): checks on the QA Test School (tenant 32,
-- school 45, receptionist login 65). Creates the tables/proc inside the
-- transaction and ROLLS BACK. Run from this folder:
--     psql ... -f front_office_tests.sql
\set ON_ERROR_STOP 1
BEGIN;
\ir ../front_office.sql

DO $t$
DECLARE
    TN int := 32; SC int := 45; U int := 65;
    c refcursor; r record; v_id int; v_n int; v_txt text;
    pass int := 0; fail int := 0;
BEGIN
    -- 1. a visitor comes in, shows on today's list as inside, then is marked out
    CALL core.sp_front_office_manage('VisitorSave', TN, SC, U, NULL, NULL, NULL, 'Ramesh Gupta', '9876543210', 'Meet teacher', 'QA Teacher', 2,
                                     NULL, 'Re: Aarav marks', NULL, NULL, NULL, NULL, c);
    FETCH c INTO r; CLOSE c; v_id := r.id;
    CALL core.sp_front_office_manage('Summary', TN, SC, U, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, c);
    FETCH c INTO r; CLOSE c; v_n := r.inside_now;
    CALL core.sp_front_office_manage('VisitorOut', TN, SC, U, v_id, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, c); CLOSE c;
    IF v_n >= 1 AND (SELECT time_out IS NOT NULL FROM core.fo_visitors WHERE visitor_id = v_id)
    THEN pass := pass + 1; RAISE NOTICE 'PASS 1 visitor in (% inside), then out', v_n;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 1'; END IF;

    -- 2. marking out twice is refused
    BEGIN
        CALL core.sp_front_office_manage('VisitorOut', TN, SC, U, v_id, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 2 out twice';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 2 %', SQLERRM; END;

    -- 3. a call with a follow-up; it counts as due once its date comes; done clears it
    CALL core.sp_front_office_manage('CallSave', TN, SC, U, NULL, NULL, NULL, 'Sunita Verma', '9000000201', 'Admission enquiry', NULL, NULL,
                                     NULL, 'Asked about Class 3 seats', 'Incoming', CURRENT_DATE, NULL, NULL, c);
    FETCH c INTO r; CLOSE c; v_id := r.id;
    CALL core.sp_front_office_manage('Summary', TN, SC, U, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, c);
    FETCH c INTO r; CLOSE c; v_n := r.follow_ups_due;
    CALL core.sp_front_office_manage('CallDone', TN, SC, U, v_id, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'Called back, visiting Monday', NULL, NULL, NULL, NULL, c); CLOSE c;
    SELECT note INTO v_txt FROM core.fo_calls WHERE call_id = v_id;
    IF v_n >= 1 AND v_txt LIKE '%Follow-up: Called back%' THEN pass := pass + 1; RAISE NOTICE 'PASS 3 follow-up due %, done: %', v_n, replace(v_txt, E'\n', ' | ');
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 3 % %', v_n, v_txt; END IF;

    -- 4. a follow-up date in the past is refused
    BEGIN
        CALL core.sp_front_office_manage('CallSave', TN, SC, U, NULL, NULL, NULL, 'X', NULL, 'Fee', NULL, NULL, NULL, NULL, 'Outgoing', CURRENT_DATE - 1, NULL, NULL, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 4 past follow-up';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 4 %', SQLERRM; END;

    -- 5. complaint: numbered, pending, needs a note to resolve, then resolved
    CALL core.sp_front_office_manage('ComplaintSave', TN, SC, U, NULL, NULL, NULL, 'Rakesh Sharma', '9000000201', 'Transport', 'Transport in-charge', NULL,
                                     NULL, 'Bus came 30 minutes late three days this week', 'Parent', NULL, 'Aarav Sharma (Class 1-A)', NULL, c);
    FETCH c INTO r; CLOSE c; v_id := r.id; v_txt := r.message;
    BEGIN
        CALL core.sp_front_office_manage('ComplaintStatus', TN, SC, U, v_id, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'Resolved', c);
        fail := fail + 1; RAISE NOTICE 'FAIL 5 resolved without a note';
    EXCEPTION WHEN raise_exception THEN
        CALL core.sp_front_office_manage('ComplaintStatus', TN, SC, U, v_id, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'Driver warned; route timing changed', NULL, NULL, NULL, 'Resolved', c); CLOSE c;
        IF v_txt LIKE 'Complaint CMP-%' AND (SELECT status = 'Resolved' AND resolved_at IS NOT NULL FROM core.fo_complaints WHERE complaint_id = v_id)
        THEN pass := pass + 1; RAISE NOTICE 'PASS 5 % -> resolved with a note', v_txt;
        ELSE fail := fail + 1; RAISE NOTICE 'FAIL 5'; END IF;
    END;

    -- 6. the pending list leaves out resolved ones; another school sees nothing
    CALL core.sp_front_office_manage('Complaints', TN, SC, U, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'Pending', c);
    v_n := 0; LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.complaint_id = v_id THEN v_n := v_n + 1; END IF; END LOOP; CLOSE c;
    CALL core.sp_front_office_manage('Complaints', 30, 1, U, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, c);
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.complaint_id = v_id THEN v_n := v_n + 10; END IF; END LOOP; CLOSE c;
    IF v_n = 0 THEN pass := pass + 1; RAISE NOTICE 'PASS 6 resolved not pending; other school sees nothing';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 6 code %', v_n; END IF;

    RAISE NOTICE '== % passed, % failed ==', pass, fail;
END;
$t$;

ROLLBACK;
