-- Student data checks (student_data_checks.sql): checks on the QA Test School
-- (tenant 32, school 45, admin login 62). Changes QA rows inside the transaction
-- and ROLLS BACK. Run from this folder:
--     psql ... -f student_data_checks_tests.sql
\set ON_ERROR_STOP 1
BEGIN;
\ir ../student_data_checks.sql

DO $t$
DECLARE
    TN int := 32; SC int := 45; ADMIN int := 62;
    c refcursor; r record; v_a int; v_b int; v_c int; v_n int; v_txt text; v_before int;
    pass int := 0; fail int := 0;
BEGIN
    -- three students of Class 1-A
    SELECT MIN(student_id), MAX(student_id) INTO v_a, v_c FROM core.students
     WHERE tenant_id = TN AND class_name = 'Class 1' AND section = 'A' AND is_active;
    SELECT student_id INTO v_b FROM core.students
     WHERE tenant_id = TN AND class_name = 'Class 1' AND section = 'A' AND is_active AND student_id NOT IN (v_a, v_c) LIMIT 1;

    -- students already without a roll on the live data (the summary adds ours to them)
    SELECT COUNT(*) INTO v_before FROM core.students
     WHERE tenant_id = TN AND school_id = SC AND is_active AND NULLIF(trim(COALESCE(roll_no, '')), '') IS NULL;

    -- make problems: a missing roll, a duplicate roll, a bad mobile, no DOB
    UPDATE core.students SET roll_no = NULL WHERE student_id = v_a;
    UPDATE core.students SET roll_no = (SELECT roll_no FROM core.students WHERE student_id = v_c) WHERE student_id = v_b;
    UPDATE core.students SET mobile = '98765', dob = NULL WHERE student_id = v_c;

    -- 1. summary counts them
    CALL core.sp_student_data_checks('Summary', TN, SC, ADMIN, NULL, NULL, NULL, NULL, c);
    v_txt := '';
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
        IF r.issue IN ('no_roll', 'dup_roll', 'bad_mobile', 'no_dob') THEN v_txt := v_txt || r.issue || '=' || r.students || ' '; END IF;
    END LOOP; CLOSE c;
    IF v_txt LIKE '%no_roll=' || (v_before + 1) || ' %' AND v_txt LIKE '%dup_roll=2%' AND v_txt LIKE '%bad_mobile=1%' AND v_txt LIKE '%no_dob=1%'
    THEN pass := pass + 1; RAISE NOTICE 'PASS 1 summary: %', v_txt;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 1 summary: %', v_txt; END IF;

    -- 2. list for one check shows the student and the detail
    CALL core.sp_student_data_checks('List', TN, SC, ADMIN, 'bad_mobile', NULL, NULL, NULL, c);
    v_txt := NULL;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.student_id = v_c THEN v_txt := r.detail; END IF; END LOOP; CLOSE c;
    IF v_txt = '98765' THEN pass := pass + 1; RAISE NOTICE 'PASS 2 list shows the bad mobile %', v_txt;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 2 %', v_txt; END IF;

    -- 3. assign missing: only the student without a number gets the next free one
    CALL core.sp_student_data_checks('AssignRolls', TN, SC, ADMIN, NULL, 'Class 1', 'A', 'missing', c);
    FETCH c INTO r; CLOSE c;
    IF (SELECT roll_no FROM core.students WHERE student_id = v_a) IS NOT NULL
       AND (SELECT roll_no FROM core.student_enrolment WHERE student_id = v_a AND academic_year = '2026-27') =
           (SELECT roll_no FROM core.students WHERE student_id = v_a)
    THEN pass := pass + 1; RAISE NOTICE 'PASS 3 % (student % got %)', r.message, v_a, (SELECT roll_no FROM core.students WHERE student_id = v_a);
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 3 %', r.message; END IF;

    -- 4. renumber all: 1..n in name order, no duplicates left, audit written
    CALL core.sp_student_data_checks('AssignRolls', TN, SC, ADMIN, NULL, 'Class 1', 'A', 'all', c);
    FETCH c INTO r; CLOSE c;
    SELECT string_agg(roll_no, ',' ORDER BY lower(student_name)) INTO v_txt FROM core.students
     WHERE tenant_id = TN AND class_name = 'Class 1' AND section = 'A' AND is_active;
    IF v_txt = '1,2,3' AND EXISTS (SELECT 1 FROM core.admission_audit WHERE student_id = v_b AND detail LIKE '%Data Checks%')
    THEN pass := pass + 1; RAISE NOTICE 'PASS 4 renumbered %: %', r.message, v_txt;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 4 %', v_txt; END IF;

    -- 5. running it again changes nothing
    CALL core.sp_student_data_checks('AssignRolls', TN, SC, ADMIN, NULL, 'Class 1', 'A', 'all', c);
    FETCH c INTO r; CLOSE c;
    IF r.message LIKE 'Nothing to change%' THEN pass := pass + 1; RAISE NOTICE 'PASS 5 %', r.message;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 5 %', r.message; END IF;

    -- 6. another school sees none of these students
    CALL core.sp_student_data_checks('List', 30, 1, ADMIN, 'no_dob', NULL, NULL, NULL, c);
    v_n := 0; LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.student_id IN (v_a, v_b, v_c) THEN v_n := v_n + 1; END IF; END LOOP; CLOSE c;
    IF v_n = 0 THEN pass := pass + 1; RAISE NOTICE 'PASS 6 other school sees none';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 6 leak'; END IF;

    RAISE NOTICE '== % passed, % failed ==', pass, fail;
END;
$t$;

ROLLBACK;
