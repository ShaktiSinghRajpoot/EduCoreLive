-- ============================================================================
-- Student Promotion test suite.
--
-- Promotion moves a whole cohort between sessions in one click. A wrong rule
-- here is not one bad row — it is every student in the school, and the office
-- finds out months later when the fee ledger does not match the register.
--
-- Runs inside ONE transaction and ROLLS BACK.
--
--     psql ... -f promotion_tests.sql
--
-- COVERS
--   A. The session guards
--   B. A normal promotion, and what moves with the student
--   C. Outcomes other than promote (retain, pass out)
--   D. Skipping a class (1st straight to 3rd)
--   E. Carry-forward of pending dues
--   F. Scope
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

    v_src      varchar;      -- current session
    v_tgt      varchar;      -- the session to promote into
    v_srcid    integer;
    v_tgtid    integer;
    v_c1       varchar;      -- lowest class
    v_c2       varchar;      -- the one above it
    v_c3       varchar;      -- and the one above that
    v_start    date;
    v_sec      varchar;

    c      refcursor;
    v_sid  integer;   -- promoted normally
    v_sid2 integer;   -- retained
    v_sid3 integer;   -- skips a class
    v_sid4 integer;   -- passes out
    v_n    integer;
    v_txt  text;
    v_dec  numeric;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '========= STUDENT PROMOTION TESTS =========';

    SELECT academic_year_id, academic_year_name, start_date INTO v_srcid, v_src, v_start
    FROM academic.academic_years
    WHERE tenant_id = c_tenant AND school_id = c_school AND COALESCE(is_current, FALSE) LIMIT 1;

    -- The next session by start date; create one if the school has only ever had
    -- the current one, so the suite works on a fresh school too.
    SELECT academic_year_id, academic_year_name INTO v_tgtid, v_tgt
    FROM academic.academic_years
    WHERE tenant_id = c_tenant AND school_id = c_school AND start_date::date > v_start
    ORDER BY start_date LIMIT 1;

    IF v_tgt IS NULL THEN
        INSERT INTO academic.academic_years(tenant_id, school_id, academic_year_name,
                                            start_date, end_date, is_current, created_by)
        VALUES (c_tenant, c_school, 'ZZ NEXT',
                (v_start + INTERVAL '1 year')::date,
                (v_start + INTERVAL '2 years' - INTERVAL '1 day')::date, FALSE, c_user)
        RETURNING academic_year_id, academic_year_name INTO v_tgtid, v_tgt;
        RAISE NOTICE 'created target session % for the test', v_tgt;
    END IF;

    -- Three consecutive classes that all carry the SAME section, so a student can
    -- actually be promoted between them. Section names are per class here — the
    -- pre-primary classes use "Kid A" while class 1 upwards use "A" — so picking
    -- the three lowest classes and assuming a section would not work.
    SELECT section_name INTO v_sec
    FROM academic.academic_class_sections s
    JOIN academic.academic_classes ac ON ac.academic_class_id = s.academic_class_id
    WHERE s.tenant_id = c_tenant AND s.school_id = c_school
      AND s.academic_year_id = v_srcid AND COALESCE(s.is_deleted, FALSE) = FALSE
    GROUP BY section_name
    HAVING COUNT(DISTINCT ac.academic_class_id) >= 3
    ORDER BY COUNT(*) DESC LIMIT 1;

    IF v_sec IS NULL THEN
        RAISE EXCEPTION 'Fixture missing: school % has no section shared by 3 classes.', c_school;
    END IF;

    SELECT class_name INTO v_c1 FROM academic.academic_classes ac
     WHERE ac.tenant_id = c_tenant AND ac.school_id = c_school
       AND ac.academic_year_id = v_srcid AND COALESCE(ac.is_deleted, FALSE) = FALSE
       AND EXISTS (SELECT 1 FROM academic.academic_class_sections x
                    WHERE x.academic_class_id = ac.academic_class_id
                      AND x.section_name = v_sec AND COALESCE(x.is_deleted, FALSE) = FALSE)
     ORDER BY ac.display_order LIMIT 1;
    SELECT class_name INTO v_c2 FROM academic.academic_classes ac
     WHERE ac.tenant_id = c_tenant AND ac.school_id = c_school
       AND ac.academic_year_id = v_srcid AND COALESCE(ac.is_deleted, FALSE) = FALSE
       AND EXISTS (SELECT 1 FROM academic.academic_class_sections x
                    WHERE x.academic_class_id = ac.academic_class_id
                      AND x.section_name = v_sec AND COALESCE(x.is_deleted, FALSE) = FALSE)
     ORDER BY ac.display_order OFFSET 1 LIMIT 1;
    SELECT class_name INTO v_c3 FROM academic.academic_classes ac
     WHERE ac.tenant_id = c_tenant AND ac.school_id = c_school
       AND ac.academic_year_id = v_srcid AND COALESCE(ac.is_deleted, FALSE) = FALSE
       AND EXISTS (SELECT 1 FROM academic.academic_class_sections x
                    WHERE x.academic_class_id = ac.academic_class_id
                      AND x.section_name = v_sec AND COALESCE(x.is_deleted, FALSE) = FALSE)
     ORDER BY ac.display_order OFFSET 2 LIMIT 1;

    IF v_c1 IS NULL OR v_c2 IS NULL THEN
        RAISE EXCEPTION 'Fixture missing: school % needs at least two classes.', c_school;
    END IF;

    -- The target session needs the same ladder, or there is nowhere to promote to.
    INSERT INTO academic.academic_classes(tenant_id, school_id, academic_year_id,
                                          class_name, display_order, created_by)
    SELECT c_tenant, c_school, v_tgtid, class_name, display_order, c_user
    FROM academic.academic_classes
    WHERE tenant_id = c_tenant AND school_id = c_school AND academic_year_id = v_srcid
      AND COALESCE(is_deleted, FALSE) = FALSE
      AND class_name NOT IN (SELECT class_name FROM academic.academic_classes
                              WHERE tenant_id = c_tenant AND school_id = c_school
                                AND academic_year_id = v_tgtid);

    -- ...and the sections under them, or a student in section A has nowhere to land.
    INSERT INTO academic.academic_class_sections(tenant_id, school_id, academic_year_id,
                                                 academic_class_id, section_name,
                                                 display_order, created_by)
    SELECT c_tenant, c_school, v_tgtid, tc.academic_class_id, s.section_name,
           s.display_order, c_user
    FROM academic.academic_class_sections s
    JOIN academic.academic_classes sc ON sc.academic_class_id = s.academic_class_id
    JOIN academic.academic_classes tc ON tc.class_name = sc.class_name
                                     AND tc.academic_year_id = v_tgtid
                                     AND tc.tenant_id = c_tenant AND tc.school_id = c_school
    WHERE s.tenant_id = c_tenant AND s.school_id = c_school
      AND s.academic_year_id = v_srcid
      AND COALESCE(s.is_deleted, FALSE) = FALSE
      AND NOT EXISTS (SELECT 1 FROM academic.academic_class_sections x
                       WHERE x.academic_year_id = v_tgtid
                         AND x.academic_class_id = tc.academic_class_id
                         AND x.section_name = s.section_name);

    RAISE NOTICE 'fixture: % -> %   ladder: % / % / %   section %', v_src, v_tgt, v_c1, v_c2, COALESCE(v_c3,'(none)'), v_sec;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- A. Session guards ------------------------------------';

    BEGIN
        c := 'a1';
        CALL core.sp_student_promote(c_tenant, c_school, c_user, v_src, v_src,
             NULL, TRUE, '[]'::jsonb, c);
        PERFORM pg_temp.chk('A1 promoting into the same session refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('A1 promoting into the same session refused', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'a2';
        CALL core.sp_student_promote(c_tenant, c_school, c_user, v_src, 'ZZ NOT A SESSION',
             NULL, TRUE, jsonb_build_array(jsonb_build_object('studentId', 1, 'outcome', 'promote')), c);
        PERFORM pg_temp.chk('A2 unknown target session refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('A2 unknown target session refused', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'a3';
        CALL core.sp_student_promote(c_tenant, c_school, c_user, v_src, v_tgt,
             NULL, TRUE, '[]'::jsonb, c);
        PERFORM pg_temp.chk('A3 promoting nobody refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('A3 promoting nobody refused', TRUE, SQLERRM);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- B. A normal promotion --------------------------------';

    c := 's1';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-PROM-1', NULL, 'ZZ Promote Me', 'Male', DATE '2014-01-01',
         v_c1, v_sec, v_src, v_start, p_result => c);
    SELECT student_id INTO v_sid FROM core.students WHERE admission_no = 'ZZ-PROM-1';

    c := 'b1';
    CALL core.sp_student_promote(c_tenant, c_school, c_user, v_src, v_tgt,
         NULL, TRUE,
         jsonb_build_array(jsonb_build_object('studentId', v_sid, 'outcome', 'promote')), c);

    SELECT class_name, academic_year INTO v_txt, v_txt
      FROM core.students WHERE student_id = v_sid;
    SELECT class_name INTO v_txt FROM core.students WHERE student_id = v_sid;
    PERFORM pg_temp.chk('B1 moved up one class', v_txt = v_c2,
                        format('now in %s, was %s', v_txt, v_c1));

    SELECT academic_year INTO v_txt FROM core.students WHERE student_id = v_sid;
    PERFORM pg_temp.chk('B2 moved into the new session', v_txt = v_tgt, format('now %s', v_txt));

    -- Section is kept unless the caller asks for a specific one — a student who
    -- was in A stays in A rather than being silently reshuffled.
    SELECT section INTO v_txt FROM core.students WHERE student_id = v_sid;
    PERFORM pg_temp.chk('B3 section kept when none was chosen', v_txt = v_sec,
                        format('section %s, expected %s', v_txt, v_sec));

    -- The admission number is identity and must never change on promotion.
    SELECT admission_no INTO v_txt FROM core.students WHERE student_id = v_sid;
    PERFORM pg_temp.chk('B4 admission number unchanged', v_txt = 'ZZ-PROM-1', format('got %s', v_txt));

    SELECT status INTO v_txt FROM core.students WHERE student_id = v_sid;
    PERFORM pg_temp.chk('B5 still an active student', v_txt = 'Active', format('status %s', v_txt));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- C. Retain and pass out -------------------------------';

    c := 's2';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-PROM-2', NULL, 'ZZ Retain Me', 'Female', DATE '2014-02-02',
         v_c2, v_sec, v_src, v_start, p_result => c);
    SELECT student_id INTO v_sid2 FROM core.students WHERE admission_no = 'ZZ-PROM-2';

    c := 'c1';
    CALL core.sp_student_promote(c_tenant, c_school, c_user, v_src, v_tgt,
         NULL, TRUE,
         jsonb_build_array(jsonb_build_object('studentId', v_sid2, 'outcome', 'retain')), c);

    SELECT class_name INTO v_txt FROM core.students WHERE student_id = v_sid2;
    PERFORM pg_temp.chk('C1 retained student keeps the same class', v_txt = v_c2,
                        format('still in %s', v_txt));

    SELECT academic_year INTO v_txt FROM core.students WHERE student_id = v_sid2;
    PERFORM pg_temp.chk('C2 ...but still moves into the new session', v_txt = v_tgt,
                        format('session %s', v_txt));

    -- Passing out leaves the school.
    c := 's4';
    CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
         'ZZ-PROM-4', NULL, 'ZZ Pass Out', 'Male', DATE '2010-04-04',
         v_c2, v_sec, v_src, v_start, p_result => c);
    SELECT student_id INTO v_sid4 FROM core.students WHERE admission_no = 'ZZ-PROM-4';

    c := 'c3';
    CALL core.sp_student_promote(c_tenant, c_school, c_user, v_src, v_tgt,
         NULL, TRUE,
         jsonb_build_array(jsonb_build_object('studentId', v_sid4, 'outcome', 'passout')), c);

    SELECT status INTO v_txt FROM core.students WHERE student_id = v_sid4;
    PERFORM pg_temp.chk('C3 passed-out student is no longer Active',
                        v_txt <> 'Active', format('status %s', v_txt));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- D. Skipping a class ----------------------------------';

    IF v_c3 IS NULL THEN
        PERFORM pg_temp.chk('D  skipped — school has only two classes', TRUE, '');
    ELSE
        c := 's3';
        CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
             'ZZ-PROM-3', NULL, 'ZZ Skip Me', 'Male', DATE '2014-03-03',
             v_c1, v_sec, v_src, v_start, p_result => c);
        SELECT student_id INTO v_sid3 FROM core.students WHERE admission_no = 'ZZ-PROM-3';

        -- 1st straight to 3rd: allowed, because a school may double-promote.
        c := 'd1';
        CALL core.sp_student_promote(c_tenant, c_school, c_user, v_src, v_tgt,
             NULL, TRUE,
             jsonb_build_array(jsonb_build_object(
                 'studentId', v_sid3, 'outcome', 'promote', 'toClass', v_c3)), c);

        SELECT class_name INTO v_txt FROM core.students WHERE student_id = v_sid3;
        PERFORM pg_temp.chk('D1 double promotion lands in the chosen class',
                            v_txt = v_c3, format('now in %s, expected %s', v_txt, v_c3));

        -- Going DOWN is not a promotion and must be refused, or a typo in the
        -- dropdown quietly demotes a child.
        c := 's5';
        CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
             'ZZ-PROM-5', NULL, 'ZZ No Demote', 'Female', DATE '2014-05-05',
             v_c3, v_sec, v_src, v_start, p_result => c);
        DECLARE v_sid5 integer;
        BEGIN
            SELECT student_id INTO v_sid5 FROM core.students WHERE admission_no = 'ZZ-PROM-5';
            BEGIN
                c := 'd2';
                CALL core.sp_student_promote(c_tenant, c_school, c_user, v_src, v_tgt,
                     NULL, TRUE,
                     jsonb_build_array(jsonb_build_object(
                         'studentId', v_sid5, 'outcome', 'promote', 'toClass', v_c1)), c);
                SELECT class_name INTO v_txt FROM core.students WHERE student_id = v_sid5;
                PERFORM pg_temp.chk('D2 promoting DOWN a class is refused',
                                    v_txt <> v_c1, format('ended up in %s', v_txt));
            EXCEPTION WHEN OTHERS THEN
                PERFORM pg_temp.chk('D2 promoting DOWN a class is refused', TRUE, SQLERRM);
            END;
        END;
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- E. Carry-forward of dues -----------------------------';

    -- A student who owes money and is promoted with carry ON must still owe it in
    -- the new session; that is the whole point of the checkbox.
    DECLARE v_owe integer; v_before numeric; v_after numeric;
    BEGIN
        c := 's6';
        CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
             'ZZ-PROM-DUES', NULL, 'ZZ Owes', 'Male', DATE '2014-06-06',
             v_c1, v_sec, v_src, v_start,
             p_fee_plan_json => jsonb_build_array(
                 jsonb_build_object('feeHeadName','ZZ Tuition','frequency','One Time','amount',1500)),
             p_result => c);
        SELECT student_id INTO v_owe FROM core.students WHERE admission_no = 'ZZ-PROM-DUES';

        SELECT COALESCE(SUM(amount_due - amount_paid - COALESCE(concession,0)), 0)
          INTO v_before FROM core.student_ledger WHERE student_id = v_owe;
        PERFORM pg_temp.chk_eq('E1 student owes before promotion', v_before, 1500);

        c := 'e2';
        CALL core.sp_student_promote(c_tenant, c_school, c_user, v_src, v_tgt,
             NULL, TRUE,
             jsonb_build_array(jsonb_build_object('studentId', v_owe, 'outcome', 'promote')), c);

        SELECT COALESCE(SUM(amount_due - amount_paid - COALESCE(concession,0)), 0)
          INTO v_after FROM core.student_ledger WHERE student_id = v_owe;
        PERFORM pg_temp.chk('E2 carry ON: the debt survives promotion',
                            v_after >= v_before,
                            format('owed %s before, %s after', v_before, v_after));
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- F. Scope ---------------------------------------------';

    BEGIN
        c := 'f1';
        CALL core.sp_student_promote(23, 33, c_user, v_src, v_tgt,
             NULL, TRUE,
             jsonb_build_array(jsonb_build_object('studentId', v_sid, 'outcome', 'promote')), c);
        PERFORM pg_temp.chk('F1 another school cannot promote our student', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('F1 another school cannot promote our student', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'f2';
        CALL core.sp_student_promote(1, 0, c_user, v_src, v_tgt,
             NULL, TRUE,
             jsonb_build_array(jsonb_build_object('studentId', v_sid, 'outcome', 'promote')), c);
        PERFORM pg_temp.chk('F2 platform scope refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('F2 platform scope refused', TRUE, SQLERRM);
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
            RAISE NOTICE '   %  %', rpad(r.name, 54), r.detail;
        END LOOP;
    END IF;
    RAISE NOTICE '';
END
$sum$;

ROLLBACK;
