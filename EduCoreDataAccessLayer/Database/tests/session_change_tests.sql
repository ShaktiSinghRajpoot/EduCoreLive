-- Session change, end to end, on the QA Test School (tenant 32, school 45, admin
-- login 62): new session -> copy classes -> copy fees -> promote -> Year-End
-- carry / close / reopen -> copy teachers & timetable -> make it current. Everything happens inside the transaction and is
-- ROLLED BACK. Run from this folder:
--     psql ... -f session_change_tests.sql
\set ON_ERROR_STOP 1
BEGIN;
\ir ../fee_structure_copy.sql
\ir ../fee_year_end.sql
\ir ../student_promotion.sql
\ir ../academic_session_rollover.sql
\ir ../academic_year_class_section_fixes.sql
\ir ../id_card.sql
\ir ../transfer_certificate.sql

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
    CALL academic.sp_school_admin_academic_year_manage('SaveAcademicYear', T, S, A, NULL, 'ZZ 2031-32',
         '2031-04-01', '2032-03-31', FALSE, 'AdmissionMonth', c);
    CLOSE c;
    SELECT academic_year_id INTO v_new FROM academic.academic_years
     WHERE tenant_id = T AND school_id = S AND academic_year_name = 'ZZ 2031-32';
    c := 'c2';
    CALL academic.sp_academic_year_clone(T, S, A, v_old, v_new, c); FETCH c INTO r; CLOSE c;
    IF r.classes_copied > 0 THEN pass := pass + 1; RAISE NOTICE 'PASS 1 %', r.message;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 1 %', r.message; END IF;

    -- 2. fee structure copied with a 10%% increase, in whole rupees
    c := 'c3';
    CALL core.sp_fee_structure_copy(T, S, A, '2026-27', 'ZZ 2031-32', 10, c); FETCH c INTO r; CLOSE c;
    SELECT COUNT(*) INTO v_n
      FROM core.school_fee_structure_details o
      JOIN core.school_fee_structures os ON os.fee_structure_id = o.fee_structure_id AND os.academic_year = '2026-27'
      JOIN core.school_fee_structures ns ON ns.tenant_id = os.tenant_id AND ns.school_id = os.school_id
                                        AND ns.class_name = os.class_name AND ns.academic_year = 'ZZ 2031-32'
      JOIN core.school_fee_structure_details n ON n.fee_structure_id = ns.fee_structure_id AND n.fee_head_id = o.fee_head_id
     WHERE os.tenant_id = T AND os.school_id = S AND NOT o.is_deleted AND n.amount <> ROUND(o.amount * 1.10);
    IF r.copied > 0 AND v_n = 0 THEN pass := pass + 1; RAISE NOTICE 'PASS 2 %', r.message;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 2 % (% wrong amounts)', r.message, v_n; END IF;

    -- 3. copying again changes nothing
    c := 'c4';
    CALL core.sp_fee_structure_copy(T, S, A, '2026-27', 'ZZ 2031-32', 10, c); FETCH c INTO r; CLOSE c;
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
    CALL core.sp_student_promote(T, S, A, '2026-27', 'ZZ 2031-32', NULL, TRUE, v_students, c); FETCH c INTO r; CLOSE c;
    SELECT COUNT(*) INTO v_n FROM core.students s
     WHERE s.student_id IN (SELECT (x->>'studentId')::int FROM jsonb_array_elements(v_students) x)
       AND s.class_name = 'Class 9' AND s.academic_year = 'ZZ 2031-32'
       AND EXISTS (SELECT 1 FROM core.student_ledger l WHERE l.student_id = s.student_id AND l.academic_year = 'ZZ 2031-32');
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
    -- (carrying opens in the session's last month: for this run 2026-27 ends this month)
    UPDATE academic.academic_years SET end_date = to_char((date_trunc('month', CURRENT_DATE) + INTERVAL '1 month - 1 day')::date, 'YYYY-MM-DD')
     WHERE tenant_id = T AND school_id = S AND academic_year_name = '2026-27';
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

    -- 8. subjects came with the class copy; class teachers + timetable copy on request, once
    c := 'c12';
    CALL academic.sp_academic_year_copy_setup(T, S, A, v_old, v_new, TRUE, TRUE, TRUE, c); FETCH c INTO r; CLOSE c;
    v_txt := r.subjects || '/' || r.teachers || '/' || r.periods;
    c := 'c13';
    CALL academic.sp_academic_year_copy_setup(T, S, A, v_old, v_new, TRUE, TRUE, TRUE, c); FETCH c INTO r; CLOSE c;
    IF split_part(v_txt, '/', 1) = '0' AND split_part(v_txt, '/', 2)::int > 0 AND split_part(v_txt, '/', 3)::int > 0
       AND r.subjects = 0 AND r.teachers = 0 AND r.periods = 0
       AND (SELECT COUNT(*) FROM academic.class_subjects WHERE academic_year_id = v_new) > 0
    THEN pass := pass + 1; RAISE NOTICE 'PASS 8 subjects/teachers/periods copied % then nothing', v_txt;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 8 first % then %/%/%', v_txt, r.subjects, r.teachers, r.periods; END IF;

    -- 9. the new session cannot be made current while students are still in the old one
    BEGIN
        c := 'c14';
        CALL academic.sp_school_admin_academic_year_manage('SetCurrentAcademicYear', T, S, A, v_new, NULL, NULL, NULL, FALSE, NULL, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 9 made current with students still in 2026-27';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 9 %', SQLERRM; END;

    -- 10. a session with no classes cannot be made current
    c := 'c15';
    CALL academic.sp_school_admin_academic_year_manage('SaveAcademicYear', T, S, A, NULL, 'ZZ 2029-30',
         '2029-04-01', '2030-03-31', FALSE, 'AdmissionMonth', c);
    CLOSE c;
    SELECT academic_year_id INTO v_n FROM academic.academic_years
     WHERE tenant_id = T AND school_id = S AND academic_year_name = 'ZZ 2029-30';
    BEGIN
        c := 'c16';
        CALL academic.sp_school_admin_academic_year_manage('SetCurrentAcademicYear', T, S, A, v_n,
             NULL, NULL, NULL, FALSE, NULL, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 10 empty session made current';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 10 %', SQLERRM; END;

    -- 12. ID cards for the OLD session still list the promoted students, with their old class
    c := 'c18';
    CALL core.sp_id_card_students(T, S, A, 'Class 8', 'A', '2026-27', NULL, c);
    v_n := 0; LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.class_name = 'Class 8' AND r.academic_year = '2026-27' THEN v_n := v_n + 1; END IF; END LOOP; CLOSE c;
    IF v_n = jsonb_array_length(v_students) THEN pass := pass + 1; RAISE NOTICE 'PASS 12 old-session ID cards: % promoted students as Class 8', v_n;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 12 % of % on old-session cards', v_n, jsonb_array_length(v_students); END IF;

    -- 13. a TC right after promotion is written for the session they finished
    v_n := (v_students->0->>'studentId')::int;
    UPDATE core.students SET is_active = FALSE, status = 'Transfer', date_of_leaving = CURRENT_DATE WHERE student_id = v_n;
    UPDATE core.student_ledger SET amount_paid = amount_due - COALESCE(concession, 0) WHERE student_id = v_n;
    c := 'c19';
    CALL core.sp_tc_manage('Issue', T, S, A, NULL, v_n, 'Basic', 'Good', 'Passed', 'Parent transfer', NULL, p_result_cur => c);
    CLOSE c;
    SELECT class_name || ' ' || academic_year INTO v_txt FROM core.tc_register WHERE student_id = v_n AND NOT is_void;
    IF v_txt = 'Class 8 2026-27' THEN pass := pass + 1; RAISE NOTICE 'PASS 13 TC after promotion: %', v_txt;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 13 TC says %', v_txt; END IF;

    -- 11. once every student is in the new session, it can be made current
    UPDATE core.students SET academic_year = 'ZZ 2031-32' WHERE tenant_id = T AND school_id = S AND is_active;
    c := 'c17';
    CALL academic.sp_school_admin_academic_year_manage('SetCurrentAcademicYear', T, S, A, v_new, NULL, NULL, NULL, FALSE, NULL, c);
    CLOSE c;
    IF (SELECT is_current FROM academic.academic_years WHERE academic_year_id = v_new)
    THEN pass := pass + 1; RAISE NOTICE 'PASS 11 made current after everyone moved';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 11 not current'; END IF;

    RAISE NOTICE '== % passed, % failed ==', pass, fail;
END;
$t$;

ROLLBACK;
