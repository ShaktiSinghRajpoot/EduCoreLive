-- ============================================================================
-- School Settings test suite.
--
-- Settings are the shape of everything else: the sessions, the class ladder, the
-- sections and the fee heads. A student, a ledger row and a timetable slot all
-- point back here, so the rules worth testing are the ones that stop a setting
-- being changed out from under the data that depends on it.
--
-- Runs inside ONE transaction and ROLLS BACK.
--
--     psql ... -f settings_tests.sql
--
-- COVERS
--   A. Academic years — name, dates, duplicates, current
--   B. Classes and sections — and the enrolled-students guard
--   C. Fee heads — name, duplicates, and what delete does to a ledger
--   D. Subjects
--   E. Scope
-- ============================================================================

\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE TEMP TABLE _t(id serial, name text, ok boolean, detail text) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.chk(p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO _t(name, ok, detail) VALUES (p_name, p_ok, p_detail);
    RAISE NOTICE '  [%] %  %', CASE WHEN p_ok THEN 'PASS' ELSE 'FAIL' END, rpad(p_name, 54), p_detail;
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

    v_year   varchar;
    v_yearid integer;
    v_class  varchar;
    v_clsid  integer;
    v_start  date;
    v_sec    varchar;

    c     refcursor;
    v_n   integer;
    v_txt text;
    v_dec numeric;
    v_new integer;
    v_fh  integer;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '========= SCHOOL SETTINGS TESTS =========';

    SELECT academic_year_id, academic_year_name, start_date INTO v_yearid, v_year, v_start
    FROM academic.academic_years
    WHERE tenant_id = c_tenant AND school_id = c_school AND COALESCE(is_current, FALSE) LIMIT 1;

    SELECT academic_class_id, class_name INTO v_clsid, v_class
    FROM academic.academic_classes
    WHERE tenant_id = c_tenant AND school_id = c_school AND academic_year_id = v_yearid
      AND COALESCE(is_deleted, FALSE) = FALSE ORDER BY display_order LIMIT 1;

    SELECT section_name INTO v_sec FROM academic.academic_class_sections
    WHERE tenant_id = c_tenant AND school_id = c_school AND academic_class_id = v_clsid
      AND COALESCE(is_deleted, FALSE) = FALSE LIMIT 1;

    IF v_year IS NULL OR v_class IS NULL THEN
        RAISE EXCEPTION 'Fixture missing: school % has no current session or classes.', c_school;
    END IF;
    RAISE NOTICE 'fixture: session=%  class=%  section=%', v_year, v_class, v_sec;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- A. Academic years -----------------------------------';

    BEGIN
        c := 'a1';
        CALL academic.sp_school_admin_academic_year_manage('SaveAcademicYear',
             c_tenant, c_school, c_user, NULL, '   ',
             DATE '2040-04-01', DATE '2041-03-31', FALSE, c);
        PERFORM pg_temp.chk('A1 blank session name refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('A1 blank session name refused', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'a2';
        CALL academic.sp_school_admin_academic_year_manage('SaveAcademicYear',
             c_tenant, c_school, c_user, NULL, 'ZZ Backwards',
             DATE '2041-04-01', DATE '2040-03-31', FALSE, c);
        PERFORM pg_temp.chk('A2 end date before start date refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('A2 end date before start date refused', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'a3';
        CALL academic.sp_school_admin_academic_year_manage('SaveAcademicYear',
             c_tenant, c_school, c_user, NULL, v_year,
             DATE '2040-04-01', DATE '2041-03-31', FALSE, c);
        PERFORM pg_temp.chk('A3 duplicate session name refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('A3 duplicate session name refused', TRUE, SQLERRM);
    END;

    c := 'a4';
    CALL academic.sp_school_admin_academic_year_manage('SaveAcademicYear',
         c_tenant, c_school, c_user, NULL, 'ZZ Session',
         DATE '2040-04-01', DATE '2041-03-31', FALSE, c);

    SELECT academic_year_id INTO v_new FROM academic.academic_years
     WHERE tenant_id = c_tenant AND school_id = c_school AND academic_year_name = 'ZZ Session';
    PERFORM pg_temp.chk('A4 a valid session is created', v_new IS NOT NULL, format('id=%s', v_new));

    -- Exactly one session can be current, or every screen that reads "the current
    -- session" gets a coin flip.
    c := 'a5';
    CALL academic.sp_school_admin_academic_year_manage('SetCurrentAcademicYear',
         c_tenant, c_school, c_user, v_new, NULL, NULL, NULL, TRUE, c);

    SELECT COUNT(*) INTO v_n FROM academic.academic_years
     WHERE tenant_id = c_tenant AND school_id = c_school AND COALESCE(is_current, FALSE);
    PERFORM pg_temp.chk_eq('A5 exactly one session is current', v_n, 1);

    SELECT academic_year_name INTO v_txt FROM academic.academic_years
     WHERE tenant_id = c_tenant AND school_id = c_school AND COALESCE(is_current, FALSE);
    PERFORM pg_temp.chk('A6 ...and it is the one we just set', v_txt = 'ZZ Session',
                        format('current is %s', v_txt));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- B. Classes and sections -----------------------------';

    BEGIN
        c := 'b1';
        CALL academic.sp_school_admin_academic_setup_manage('SaveAcademicSetup',
             c_tenant, c_school, c_user, NULL, NULL, '[]', c);
        PERFORM pg_temp.chk('B1 saving a setup with no session refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('B1 saving a setup with no session refused', TRUE, SQLERRM);
    END;

    -- THE ONE THAT MATTERS: a class or section with students in it cannot be
    -- removed. Without this guard a settings tidy-up orphans real children.
    DECLARE v_sid integer;
    BEGIN
        c := 'b2';
        CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
             'ZZ-SET-1', NULL, 'ZZ Settings Kid', 'Male', DATE '2015-01-01',
             v_class, v_sec, v_year, CURRENT_DATE, p_result => c);
        SELECT student_id INTO v_sid FROM core.students WHERE admission_no = 'ZZ-SET-1';
        PERFORM pg_temp.chk('B2 a student exists in that class', v_sid IS NOT NULL,
                            format('student_id=%s', v_sid));

        BEGIN
            -- An empty ladder means "remove everything", including their class.
            c := 'b3';
            CALL academic.sp_school_admin_academic_setup_manage('SaveAcademicSetup',
                 c_tenant, c_school, c_user, v_yearid, v_year, '[]', c);
            PERFORM pg_temp.chk('B3 removing a class with enrolled students refused',
                                FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('B3 removing a class with enrolled students refused',
                                TRUE, SQLERRM);
        END;

        -- ...and the class is still there afterwards.
        SELECT COUNT(*) INTO v_n FROM academic.academic_classes
         WHERE academic_class_id = v_clsid AND COALESCE(is_deleted, FALSE) = FALSE;
        PERFORM pg_temp.chk_eq('B4 the class survived the refused delete', v_n, 1);

        SELECT class_name INTO v_txt FROM core.students WHERE student_id = v_sid;
        PERFORM pg_temp.chk('B5 the student still has a class', v_txt = v_class,
                            format('still in %s', v_txt));
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- C. Fee heads ----------------------------------------';

    BEGIN
        c := 'c1';
        CALL core.sp_school_admin_fee_head_manage('SaveFeeHead',
             c_tenant, c_school, c_user, 0, '   ', 'Monthly', 100,
             'Fee', 'Academic', 'Recurring', FALSE, 0, c);
        PERFORM pg_temp.chk('C1 blank fee head name refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C1 blank fee head name refused', TRUE, SQLERRM);
    END;

    c := 'c2';
    CALL core.sp_school_admin_fee_head_manage('SaveFeeHead',
         c_tenant, c_school, c_user, 0, 'ZZ Lab Fee', 'Monthly', 250,
         'Fee', 'Academic', 'Recurring', FALSE, 0, c);

    SELECT fee_head_id, default_amount INTO v_fh, v_dec FROM core.school_fee_heads
     WHERE tenant_id = c_tenant AND school_id = c_school AND fee_head_name = 'ZZ Lab Fee';
    PERFORM pg_temp.chk('C2 fee head created', v_fh IS NOT NULL, format('id=%s', v_fh));
    PERFORM pg_temp.chk_eq('C3 its default amount is stored', v_dec, 250);

    -- Saving an existing name is an UPSERT, not an error: it updates that head in
    -- place. That is deliberate — it also means re-adding a head someone had
    -- deleted revives it, rather than failing with a "duplicate" complaint about
    -- a row the user cannot see. What matters is that it never leaves two heads
    -- with the same name, because a ledger row identifies its head BY NAME.
    c := 'c4';
    CALL core.sp_school_admin_fee_head_manage('SaveFeeHead',
         c_tenant, c_school, c_user, 0, 'ZZ Lab Fee', 'Monthly', 300,
         'Fee', 'Academic', 'Recurring', FALSE, 0, c);

    SELECT COUNT(*) INTO v_n FROM core.school_fee_heads
     WHERE tenant_id = c_tenant AND school_id = c_school
       AND fee_head_name = 'ZZ Lab Fee' AND COALESCE(is_deleted, FALSE) = FALSE;
    PERFORM pg_temp.chk_eq('C4 the same name never creates a second head', v_n, 1);

    SELECT default_amount INTO v_dec FROM core.school_fee_heads
     WHERE tenant_id = c_tenant AND school_id = c_school AND fee_head_name = 'ZZ Lab Fee';
    PERFORM pg_temp.chk_eq('C4b ...it updates the existing one', v_dec, 300);

    -- A name that differs only by surrounding spaces is the same head, now that
    -- the proc trims it — otherwise "Lab Fee " and "Lab Fee" would be two heads
    -- and a ledger could point at either.
    c := 'c4c';
    CALL core.sp_school_admin_fee_head_manage('SaveFeeHead',
         c_tenant, c_school, c_user, 0, '  ZZ Lab Fee  ', 'Monthly', 350,
         'Fee', 'Academic', 'Recurring', FALSE, 0, c);

    SELECT COUNT(*) INTO v_n FROM core.school_fee_heads
     WHERE tenant_id = c_tenant AND school_id = c_school
       AND TRIM(fee_head_name) = 'ZZ Lab Fee' AND COALESCE(is_deleted, FALSE) = FALSE;
    PERFORM pg_temp.chk_eq('C4c a padded name is the same head, not a new one', v_n, 1);

    -- A refundable head is how the security deposit is modelled; the flag has to
    -- survive the round trip or the deposit becomes ordinary income.
    c := 'c5';
    CALL core.sp_school_admin_fee_head_manage('SaveFeeHead',
         c_tenant, c_school, c_user, 0, 'ZZ Deposit', 'One Time', 5000,
         'Deposit', 'Academic', 'Admission', TRUE, 0, c);

    SELECT is_refundable INTO v_txt FROM core.school_fee_heads
     WHERE tenant_id = c_tenant AND school_id = c_school AND fee_head_name = 'ZZ Deposit';
    PERFORM pg_temp.chk('C5 the refundable flag round-trips', v_txt::boolean IS TRUE,
                        format('is_refundable = %s', v_txt));

    -- Deleting a fee head is a cascade — it has to take its ledger rows with it,
    -- or the student is left owing money against a head that no longer exists.
    DECLARE v_sid2 integer; v_before integer; v_after integer;
    BEGIN
        c := 'c6';
        CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
             'ZZ-SET-2', NULL, 'ZZ Fee Kid', 'Female', DATE '2015-02-02',
             v_class, v_sec, v_year, CURRENT_DATE,
             p_fee_plan_json => jsonb_build_array(
                 jsonb_build_object('feeHeadName','ZZ Lab Fee','frequency','One Time','amount',250)),
             p_result => c);
        SELECT student_id INTO v_sid2 FROM core.students WHERE admission_no = 'ZZ-SET-2';

        SELECT COUNT(*) INTO v_before FROM core.student_ledger
         WHERE student_id = v_sid2 AND fee_head_name = 'ZZ Lab Fee';
        PERFORM pg_temp.chk('C6 the head is on a student ledger', v_before > 0,
                            format('%s row(s)', v_before));

        c := 'c7';
        CALL core.sp_fee_head_delete_cascade(c_tenant, c_school, c_user, v_fh, c);

        SELECT COUNT(*) INTO v_after FROM core.student_ledger
         WHERE student_id = v_sid2 AND fee_head_name = 'ZZ Lab Fee';
        PERFORM pg_temp.chk_eq('C7 cascade took the unpaid ledger rows with it', v_after, 0);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- D. Subjects -----------------------------------------';

    BEGIN
        c := 'd1';
        DECLARE c2 refcursor := 'd1b';
        BEGIN
            CALL academic.sp_school_admin_subject_manage('SaveClassSubjects',
                 c_tenant, c_school, c_user, v_yearid, NULL, '[]', c, c2);
            PERFORM pg_temp.chk('D1 saving subjects without a class refused',
                                FALSE, 'it was accepted');
        END;
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('D1 saving subjects without a class refused', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'd2';
        DECLARE c2 refcursor := 'd2b';
        BEGIN
            -- A class id from nowhere must not be writable, even with a valid scope.
            CALL academic.sp_school_admin_subject_manage('SaveClassSubjects',
                 c_tenant, c_school, c_user, v_yearid, 999999, '[]', c, c2);
            PERFORM pg_temp.chk('D2 a class from another school refused',
                                FALSE, 'it was accepted');
        END;
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('D2 a class from another school refused', TRUE, SQLERRM);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- E. Scope --------------------------------------------';

    BEGIN
        c := 'e1';
        CALL academic.sp_school_admin_academic_year_manage('SaveAcademicYear',
             1, 0, c_user, NULL, 'ZZ Platform',
             DATE '2040-04-01', DATE '2041-03-31', FALSE, c);
        PERFORM pg_temp.chk('E1 platform scope session write refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('E1 platform scope session write refused', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'e2';
        CALL core.sp_school_admin_fee_head_manage('SaveFeeHead',
             1, 0, c_user, 0, 'ZZ Platform Fee', 'Monthly', 100,
             'Fee', 'Academic', 'Recurring', FALSE, 0, c);
        PERFORM pg_temp.chk('E2 platform scope fee head write refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('E2 platform scope fee head write refused', TRUE, SQLERRM);
    END;

    -- Another school must not be able to delete our fee head.
    DECLARE v_fh2 integer;
    BEGIN
        SELECT fee_head_id INTO v_fh2 FROM core.school_fee_heads
         WHERE tenant_id = c_tenant AND school_id = c_school AND fee_head_name = 'ZZ Deposit';
        BEGIN
            c := 'e3';
            CALL core.sp_fee_head_delete_cascade(23, 33, c_user, v_fh2, c);
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        SELECT COUNT(*) INTO v_n FROM core.school_fee_heads
         WHERE fee_head_id = v_fh2 AND COALESCE(is_deleted, FALSE) = FALSE;
        PERFORM pg_temp.chk_eq('E3 another school could not delete our fee head', v_n, 1);
    END;

    SELECT COUNT(*) INTO v_n FROM academic.academic_years
     WHERE academic_year_name = 'ZZ Session' AND (tenant_id <> c_tenant OR school_id <> c_school);
    PERFORM pg_temp.chk_eq('E4 nothing we created leaked to another school', v_n, 0);
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
            RAISE NOTICE '   %  %', rpad(r.name, 54), r.detail;
        END LOOP;
    END IF;
    RAISE NOTICE '';
END
$sum$;

ROLLBACK;
