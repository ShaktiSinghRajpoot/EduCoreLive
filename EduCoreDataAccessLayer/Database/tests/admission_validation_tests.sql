-- ============================================================================
-- Admission validation — what the database refuses.
--
-- The New Admission screen marks ten fields with a red star and the controller
-- re-checks all ten. This suite tests the layer underneath: what
-- sp_admission_manage itself refuses, because the proc is the last thing between
-- a request and a real child's record.
--
-- Every refusal below was REPRODUCED FIRST as an accepted admission. Before this
-- work the proc would create a student with a blank name, one sitting in a class
-- that does not exist, one admitted in 2027, and one born after the day they
-- joined.
--
-- Runs inside ONE transaction and ROLLS BACK.
--
--     psql ... -f admission_validation_tests.sql
--
-- COVERS
--   A. A student must have a name
--   B. A student must sit in a class that exists
--   C. Dates that cannot have happened
--   D. The admission number
--   E. A valid admission still goes through, unchanged
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

    v_year varchar; v_class varchar; v_sec varchar; v_yid integer;

    c refcursor;
    r_sid integer; r_ok integer; r_msg text; r_adm text;
    v_n integer;

    -- Every case: what to send, and what the office should be told.
    v_before integer;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '========= ADMISSION VALIDATION (the proc layer) =========';

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

    RAISE NOTICE 'fixture: session %  class %  section %', v_year, v_class, v_sec;

    SELECT COUNT(*) INTO v_before FROM core.students
     WHERE tenant_id = c_tenant AND school_id = c_school;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- A. A student must have a name ------------------------';

    c := 'a1';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-V-A1', NULL, '   ', 'Male', DATE '2015-01-01',
         v_class, v_sec, v_year, CURRENT_DATE, p_result => c);
    FETCH c INTO r_sid, r_ok, r_msg, r_adm;
    PERFORM pg_temp.chk('A1 a name of spaces is refused', COALESCE(r_ok,1) = 0, r_msg);

    c := 'a2';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-V-A2', NULL, NULL, 'Male', DATE '2015-01-01',
         v_class, v_sec, v_year, CURRENT_DATE, p_result => c);
    FETCH c INTO r_sid, r_ok, r_msg, r_adm;
    PERFORM pg_temp.chk('A2 a missing name is refused', COALESCE(r_ok,1) = 0, r_msg);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- B. The class has to exist ---------------------------';

    -- A student in a class that is not in the ladder is an orphan: no class list
    -- shows them, no fee structure matches, and promotion cannot move them on.
    c := 'b1';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-V-B1', NULL, 'ZZ Ghost Class', 'Male', DATE '2015-01-01',
         'NOT A CLASS', 'X', v_year, CURRENT_DATE, p_result => c);
    FETCH c INTO r_sid, r_ok, r_msg, r_adm;
    PERFORM pg_temp.chk('B1 a class that does not exist is refused', COALESCE(r_ok,1) = 0, r_msg);

    c := 'b2';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-V-B2', NULL, 'ZZ No Class', 'Male', DATE '2015-01-01',
         '', v_sec, v_year, CURRENT_DATE, p_result => c);
    FETCH c INTO r_sid, r_ok, r_msg, r_adm;
    PERFORM pg_temp.chk('B2 a blank class is refused', COALESCE(r_ok,1) = 0, r_msg);

    -- A class that belongs to a DIFFERENT session is not this session's class.
    DECLARE v_other varchar;
    BEGIN
        SELECT ac.class_name INTO v_other
        FROM academic.academic_classes ac
        JOIN academic.academic_years ay ON ay.academic_year_id = ac.academic_year_id
        WHERE ac.tenant_id = c_tenant AND ac.school_id = c_school
          AND ay.academic_year_name <> v_year
          AND ac.class_name NOT IN (SELECT class_name FROM academic.academic_classes
                                     WHERE academic_year_id = v_yid)
        LIMIT 1;

        IF v_other IS NULL THEN
            PERFORM pg_temp.chk('B3 skipped — no class unique to another session', TRUE, '');
        ELSE
            c := 'b3';
            CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
                 'ZZ-V-B3', NULL, 'ZZ Wrong Session', 'Male', DATE '2015-01-01',
                 v_other, v_sec, v_year, CURRENT_DATE, p_result => c);
            FETCH c INTO r_sid, r_ok, r_msg, r_adm;
            PERFORM pg_temp.chk('B3 another session''s class is refused', COALESCE(r_ok,1) = 0, r_msg);
        END IF;
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- C. Dates that cannot have happened -------------------';

    -- A future admission date also lands the first instalment in a month the
    -- session has not reached.
    c := 'c1';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-V-C1', NULL, 'ZZ Time Traveller', 'Male', DATE '2015-01-01',
         v_class, v_sec, v_year, CURRENT_DATE + 400, p_result => c);
    FETCH c INTO r_sid, r_ok, r_msg, r_adm;
    PERFORM pg_temp.chk('C1 a future admission date is refused', COALESCE(r_ok,1) = 0, r_msg);

    c := 'c2';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-V-C2', NULL, 'ZZ Tomorrow', 'Male', DATE '2015-01-01',
         v_class, v_sec, v_year, CURRENT_DATE + 1, p_result => c);
    FETCH c INTO r_sid, r_ok, r_msg, r_adm;
    PERFORM pg_temp.chk('C2 even tomorrow is refused', COALESCE(r_ok,1) = 0, r_msg);

    -- ...but today is fine. Off-by-one here would block every walk-in admission.
    c := 'c3';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-V-C3', NULL, 'ZZ Today', 'Male', DATE '2015-01-01',
         v_class, v_sec, v_year, CURRENT_DATE, p_result => c);
    FETCH c INTO r_sid, r_ok, r_msg, r_adm;
    PERFORM pg_temp.chk('C3 TODAY is accepted', COALESCE(r_ok,0) = 1, r_msg);

    c := 'c4';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-V-C4', NULL, 'ZZ Unborn', 'Male', CURRENT_DATE + 200,
         v_class, v_sec, v_year, CURRENT_DATE, p_result => c);
    FETCH c INTO r_sid, r_ok, r_msg, r_adm;
    PERFORM pg_temp.chk('C4 a date of birth in the future is refused', COALESCE(r_ok,1) = 0, r_msg);

    -- Born after the day they joined: a typo nobody should be left holding.
    c := 'c5';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-V-C5', NULL, 'ZZ Backwards', 'Male', CURRENT_DATE - 10,
         v_class, v_sec, v_year, CURRENT_DATE - 100, p_result => c);
    FETCH c INTO r_sid, r_ok, r_msg, r_adm;
    PERFORM pg_temp.chk('C5 born after the admission date is refused', COALESCE(r_ok,1) = 0, r_msg);

    -- A back-dated admission is legitimate — an existing student entered late.
    c := 'c6';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-V-C6', NULL, 'ZZ Backdated', 'Male', DATE '2015-01-01',
         v_class, v_sec, v_year, CURRENT_DATE - 60, p_result => c);
    FETCH c INTO r_sid, r_ok, r_msg, r_adm;
    PERFORM pg_temp.chk('C6 a PAST admission date is still accepted', COALESCE(r_ok,0) = 1, r_msg);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- D. The admission number -----------------------------';

    c := 'd1';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-V-C6', NULL, 'ZZ Duplicate', 'Male', DATE '2015-01-01',
         v_class, v_sec, v_year, CURRENT_DATE, p_result => c);
    FETCH c INTO r_sid, r_ok, r_msg, r_adm;
    PERFORM pg_temp.chk('D1 a number already in use is refused', COALESCE(r_ok,1) = 0, r_msg);

    SELECT student_name INTO r_msg FROM core.students WHERE admission_no = 'ZZ-V-C6';
    PERFORM pg_temp.chk('D2 ...and the first child was NOT overwritten',
                        r_msg = 'ZZ Backdated', format('still %s', r_msg));

    -- Blank means "give me one", which is how the form is meant to be used.
    c := 'd3';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         NULL, NULL, 'ZZ Auto Number', 'Male', DATE '2015-01-01',
         v_class, v_sec, v_year, CURRENT_DATE, p_result => c);
    FETCH c INTO r_sid, r_ok, r_msg, r_adm;
    PERFORM pg_temp.chk('D3 a blank number is auto-generated',
                        COALESCE(r_ok,0) = 1 AND r_adm IS NOT NULL, format('got %s', r_adm));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- E. A good admission is untouched --------------------';

    c := 'e1';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-V-E1', NULL, 'ZZ Perfectly Fine', 'Female', DATE '2015-06-06',
         v_class, v_sec, v_year, CURRENT_DATE,
         p_fee_plan_json => jsonb_build_array(
             jsonb_build_object('feeHeadName','ZZ Tuition','frequency','Monthly','amount',1000)),
         p_result => c);
    FETCH c INTO r_sid, r_ok, r_msg, r_adm;
    PERFORM pg_temp.chk('E1 a complete admission still succeeds', COALESCE(r_ok,0) = 1, r_msg);

    SELECT COUNT(*) INTO v_n FROM core.student_ledger WHERE student_id = r_sid;
    PERFORM pg_temp.chk('E2 ...and its fee plan was still built', v_n > 0, format('%s ledger row(s)', v_n));

    -- Nothing the refusals touched left a row behind.
    SELECT COUNT(*) INTO v_n FROM core.students
     WHERE tenant_id = c_tenant AND school_id = c_school
       AND admission_no IN ('ZZ-V-A1','ZZ-V-A2','ZZ-V-B1','ZZ-V-B2','ZZ-V-B3','ZZ-V-C1','ZZ-V-C2','ZZ-V-C4','ZZ-V-C5');
    PERFORM pg_temp.chk_eq('E3 no refused admission left a half-written student', v_n, 0);

    -- Exactly the four good ones exist: C3, C6, D3's auto-numbered one, and E1.
    SELECT COUNT(*) INTO v_n FROM core.students
     WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk_eq('E4 exactly four students were created', v_n - v_before, 4);
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
