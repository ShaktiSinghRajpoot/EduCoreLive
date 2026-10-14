-- Session change, end to end, on the QA Test School (tenant 32, school 45, admin
-- login 62): new session -> copy classes -> copy fees -> promote -> Year-End
-- carry / close / reopen. Everything happens inside the transaction and is
-- ROLLED BACK. Run from this folder:
--     psql ... -f session_change_tests.sql
\set ON_ERROR_STOP 1
BEGIN;
\ir ../fee_structure_copy.sql
\ir ../fee_year_end.sql
\ir ../student_promotion.sql

DO $t$
DECLARE
    T int := 32; S int := 45; A int := 62;
    c refcursor; r record; v_new int; v_old int; v_txt text; v_n int; v_students jsonb;
    pass int := 0; fail int := 0;
BEGIN
    SELECT academic_year_id INTO v_old FROM academic.academic_years
     WHERE tenant_id = T AND school_id = S AND academic_year_name = '2026-27' AND NOT COALESCE(is_deleted, FALSE);

    -- 1. a new session, and its classes / sections copied from 2026-27
    c := 'c1';
    CALL academic.sp_school_admin_academic_year_manage('SaveAcademicYear', T, S, A, NULL, 'ZZ 2027-28',
         '2027-04-01', '2028-03-31', FALSE, 'AdmissionMonth', c);
    CLOSE c;
    SELECT academic_year_id INTO v_new FROM academic.academic_years
     WHERE tenant_id = T AND school_id = S AND academic_year_name = 'ZZ 2027-28';
    c := 'c2';
    CALL academic.sp_academic_year_clone(T, S, A, v_old, v_new, c); FETCH c INTO r; CLOSE c;
    IF r.classes_copied > 0 THEN pass := pass + 1; RAISE NOTICE 'PASS 1 %', r.message;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 1 %', r.message; END IF;

    -- 2. fee structure copied with a 10%% increase, in whole rupees
    c := 'c3';
    CALL core.sp_fee_structure_copy(T, S, A, '2026-27', 'ZZ 2027-28', 10, c); FETCH c INTO r; CLOSE c;
    SELECT COUNT(*) INTO v_n
      FROM core.school_fee_structure_details o
      JOIN core.school_fee_structures os ON os.fee_structure_id = o.fee_structure_id AND os.academic_year = '2026-27'
      JOIN core.school_fee_structures ns ON ns.tenant_id = os.tenant_id AND ns.school_id = os.school_id
                                        AND ns.class_name = os.class_name AND ns.academic_year = 'ZZ 2027-28'
      JOIN core.school_fee_structure_details n ON n.fee_structure_id = ns.fee_structure_id AND n.fee_head_id = o.fee_head_id
     WHERE os.tenant_id = T AND os.school_id = S AND NOT o.is_deleted AND n.amount <> ROUND(o.amount * 1.10);
    IF r.copied > 0 AND v_n = 0 THEN pass := pass + 1; RAISE NOTICE 'PASS 2 %', r.message;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 2 % (% wrong amounts)', r.message, v_n; END IF;

    -- 3. copying again changes nothing
    c := 'c4';
    CALL core.sp_fee_structure_copy(T, S, A, '2026-27', 'ZZ 2027-28', 10, c); FETCH c INTO r; CLOSE c;
    IF r.copied = 0 AND r.skipped > 0 THEN pass := pass + 1; RAISE NOTICE 'PASS 3 re-run: %', r.message;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 3 %', r.message; END IF;

    -- 4. promote Class 8-A: billed in the new session; existing rolls kept, a missing roll comes last
    UPDATE core.students SET roll_no = NULL
     WHERE student_id = (SELECT MIN(student_id) FROM core.students
                          WHERE tenant_id = T AND school_id = S AND is_active AND class_name = 'Class 8' AND section = 'A');
    SELECT jsonb_agg(jsonb_build_object('studentId', student_id, 'outcome', 'Promote') ORDER BY student_id) INTO v_students
      FROM core.students WHERE tenant_id = T AND school_id = S AND is_active AND class_name = 'Class 8' AND section = 'A';
    SELECT string_agg(COALESCE(roll_no, '-'), ',' ORDER BY student_id) INTO v_txt
      FROM core.students WHERE student_id IN (SELECT (x->>'studentId')::int FROM jsonb_array_elements(v_students) x);
    c := 'c5';
    CALL core.sp_student_promote(T, S, A, '2026-27', 'ZZ 2027-28', NULL, TRUE, v_students, c); FETCH c INTO r; CLOSE c;
    SELECT COUNT(*) INTO v_n FROM core.students s
     WHERE s.student_id IN (SELECT (x->>'studentId')::int FROM jsonb_array_elements(v_students) x)
       AND s.class_name = 'Class 9' AND s.academic_year = 'ZZ 2027-28'
       AND EXISTS (SELECT 1 FROM core.student_ledger l WHERE l.student_id = s.student_id AND l.academic_year = 'ZZ 2027-28');
    IF r.promoted = jsonb_array_length(v_students) AND v_n = r.promoted
    THEN pass := pass + 1; RAISE NOTICE 'PASS 4 %', r.message;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 4 % (% billed in Class 9)', r.message, v_n; END IF;

    SELECT string_agg(COALESCE(roll_no, '-'), ',' ORDER BY student_id) INTO r
      FROM core.students WHERE student_id IN (SELECT (x->>'studentId')::int FROM jsonb_array_elements(v_students) x);
    -- a roll that existed is unchanged; a missing one is now higher than every existing one
    v_n := 0;
    FOR i IN 1 .. array_length(string_to_array(v_txt, ','), 1) LOOP
        IF split_part(v_txt, ',', i) <> '-' AND split_part(v_txt, ',', i) <> split_part(r.string_agg, ',', i) THEN v_n := v_n + 1; END IF;
        IF split_part(v_txt, ',', i) = '-' AND NOT (split_part(r.string_agg, ',', i) ~ '^[0-9]+$'
           AND split_part(r.string_agg, ',', i)::int > (SELECT COALESCE(MAX(x::int), 0) FROM unnest(string_to_array(v_txt, ',')) x WHERE x ~ '^[0-9]+$'))
        THEN v_n := v_n + 1; END IF;
    END LOOP;
    IF v_n = 0 THEN pass := pass + 1; RAISE NOTICE 'PASS 5 rolls % -> %', v_txt, r.string_agg;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 5 rolls % -> %', v_txt, r.string_agg; END IF;

    -- 6. Year-End 2026-27: next session known, Close refused while lines are open
    c := 'c6';
    CALL core.sp_fee_year_end_manage('Status', T, S, A, '2026-27', NULL, NULL, NULL, c); FETCH c INTO r; CLOSE c;
    BEGIN
        c := 'c7';
        CALL core.sp_fee_year_end_manage('Close', T, S, A, '2026-27', NULL, NULL, NULL, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 6 closed with open lines';
    EXCEPTION WHEN raise_exception THEN
        IF r.next_session IS NOT NULL AND r.open_lines > 0 THEN pass := pass + 1; RAISE NOTICE 'PASS 6 next %, % open; close refused: %', r.next_session, r.open_lines, SQLERRM;
        ELSE fail := fail + 1; RAISE NOTICE 'FAIL 6 status %', row_to_json(r); END IF;
    END;

    -- 7. at session end (every line due): carry all, close, changes refused, reopen
    UPDATE core.student_ledger SET due_date = '2026-10-01'
     WHERE tenant_id = T AND school_id = S AND academic_year = '2026-27' AND NULLIF(due_date, '')::date > CURRENT_DATE;
    c := 'c8';  CALL core.sp_fee_year_end_manage('CarryAll', T, S, A, '2026-27', NULL, NULL, NULL, c); CLOSE c;
    c := 'c9';  CALL core.sp_fee_year_end_manage('Close',    T, S, A, '2026-27', NULL, NULL, NULL, c); CLOSE c;
    BEGIN
        c := 'c10';
        CALL core.sp_fee_year_end_manage('CarryAll', T, S, A, '2026-27', NULL, NULL, NULL, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 7 a closed session was changed';
    EXCEPTION WHEN raise_exception THEN
        c := 'c11'; CALL core.sp_fee_year_end_manage('Reopen', T, S, A, '2026-27', NULL, NULL, NULL, c); FETCH c INTO r; CLOSE c;
        pass := pass + 1; RAISE NOTICE 'PASS 7 closed session refused changes; %', r.message;
    END;

    RAISE NOTICE '== % passed, % failed ==', pass, fail;
END;
$t$;

ROLLBACK;
