-- Report cards + certificates (report_card_certificates.sql): checks on the QA
-- Test School (tenant 32, school 45, admin login 62). Creates everything inside
-- the transaction and ROLLS BACK. Run from this folder:
--     psql ... -f report_card_certificates_tests.sql
\set ON_ERROR_STOP 1
BEGIN;
\ir ../report_card_certificates.sql

DO $t$
DECLARE
    TN int := 32; SC int := 45; ADMIN int := 62;
    v_active int; v_left int; v_id int; v_no text; v_no2 text; v_n int; v_txt text;
    c refcursor; r record;
    pass int := 0; fail int := 0;
BEGIN
    SELECT student_id INTO v_active FROM core.students WHERE tenant_id = TN AND COALESCE(is_active, TRUE) ORDER BY student_id LIMIT 1;
    SELECT student_id INTO v_left FROM core.students WHERE tenant_id = TN AND NOT COALESCE(is_active, TRUE) ORDER BY student_id LIMIT 1;

    -- 1. report-card extras: one row per asked student, attendance numbers present
    CALL core.sp_report_card_extras(TN, SC, ADMIN, ARRAY[v_active], '2026-27', c);
    FETCH c INTO r; CLOSE c;
    IF r.student_id = v_active AND r.school_days IS NOT NULL THEN pass := pass + 1;
        RAISE NOTICE 'PASS 1 extras: days % present % (% %%), mother %', r.school_days, r.present, r.percent, r.mother_name;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 1'; END IF;

    -- 2. search finds current and former students
    SELECT left(student_name, 4) INTO v_txt FROM core.students WHERE student_id = v_active;
    CALL core.sp_certificate_manage('Search', TN, SC, ADMIN, NULL, NULL, NULL, NULL, NULL, NULL, v_txt, c);
    v_n := 0; LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.student_id = v_active THEN v_n := 1; END IF; END LOOP; CLOSE c;
    IF v_n = 1 THEN pass := pass + 1; RAISE NOTICE 'PASS 2 search "%" finds the student', v_txt;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 2'; END IF;

    -- 3. bonafide for a current student: numbered BC-<year>-0001, student copied in
    CALL core.sp_certificate_manage('Issue', TN, SC, ADMIN, NULL, v_active, 'Bonafide', 'Opening a bank account', NULL, NULL, NULL, c);
    FETCH c INTO r; CLOSE c; v_id := r.cert_id; v_no := r.cert_no;
    IF v_no LIKE 'BC-' || EXTRACT(YEAR FROM CURRENT_DATE) || '-%'
       AND (SELECT student_name = (SELECT student_name FROM core.students WHERE student_id = v_active) AND is_current FROM core.certificates WHERE cert_id = v_id)
    THEN pass := pass + 1; RAISE NOTICE 'PASS 3 %', r.message;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 3 %', v_no; END IF;

    -- 4. bonafide needs a purpose
    BEGIN
        CALL core.sp_certificate_manage('Issue', TN, SC, ADMIN, NULL, v_active, 'Bonafide', ' ', NULL, NULL, NULL, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 4 no purpose accepted';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 4 %', SQLERRM; END;

    -- 5. a former student gets no bonafide, but does get a character certificate
    IF v_left IS NULL THEN
        pass := pass + 1; RAISE NOTICE 'PASS 5 (skipped: no former student in QA data)';
    ELSE
        BEGIN
            CALL core.sp_certificate_manage('Issue', TN, SC, ADMIN, NULL, v_left, 'Bonafide', 'x', NULL, NULL, NULL, c);
            fail := fail + 1; RAISE NOTICE 'FAIL 5 bonafide for a former student';
        EXCEPTION WHEN raise_exception THEN
            CALL core.sp_certificate_manage('Issue', TN, SC, ADMIN, NULL, v_left, 'Character', NULL, 'Very Good', NULL, NULL, c);
            FETCH c INTO r; CLOSE c;
            IF r.cert_no LIKE 'CC-%' THEN pass := pass + 1; RAISE NOTICE 'PASS 5 former student: bonafide refused, %', r.message;
            ELSE fail := fail + 1; RAISE NOTICE 'FAIL 5'; END IF;
        END;
    END IF;

    -- 6. the next bonafide gets the next number
    CALL core.sp_certificate_manage('Issue', TN, SC, ADMIN, NULL, v_active, 'Bonafide', 'Scholarship', NULL, NULL, NULL, c);
    FETCH c INTO r; CLOSE c; v_no2 := r.cert_no;
    IF right(v_no2, 4)::int = right(v_no, 4)::int + 1 THEN pass := pass + 1; RAISE NOTICE 'PASS 6 % then %', v_no, v_no2;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 6 % then %', v_no, v_no2; END IF;

    -- 7. void needs a reason, keeps the row, and cannot be done twice
    BEGIN
        CALL core.sp_certificate_manage('Void', TN, SC, ADMIN, v_id, NULL, NULL, NULL, NULL, '', NULL, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 7 void without reason';
    EXCEPTION WHEN raise_exception THEN
        CALL core.sp_certificate_manage('Void', TN, SC, ADMIN, v_id, NULL, NULL, NULL, NULL, 'Name misspelt', NULL, c); CLOSE c;
        BEGIN
            CALL core.sp_certificate_manage('Void', TN, SC, ADMIN, v_id, NULL, NULL, NULL, NULL, 'again', NULL, c);
            fail := fail + 1; RAISE NOTICE 'FAIL 7 voided twice';
        EXCEPTION WHEN raise_exception THEN
            IF (SELECT is_void FROM core.certificates WHERE cert_id = v_id) THEN pass := pass + 1; RAISE NOTICE 'PASS 7 void: reason required, kept, once only';
            ELSE fail := fail + 1; RAISE NOTICE 'FAIL 7'; END IF;
        END;
    END;

    -- 8. the register lists them; filter by type; another school sees none
    CALL core.sp_certificate_manage('List', TN, SC, ADMIN, NULL, NULL, 'Bonafide', NULL, NULL, NULL, NULL, c);
    v_n := 0; LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.cert_type = 'Bonafide' THEN v_n := v_n + 1; ELSE v_n := v_n - 100; END IF; END LOOP; CLOSE c;
    CALL core.sp_certificate_manage('Get', 30, 1, ADMIN, v_id, NULL, NULL, NULL, NULL, NULL, NULL, c);
    FETCH c INTO r; CLOSE c;
    IF v_n = 2 AND r.cert_id IS NULL THEN pass := pass + 1; RAISE NOTICE 'PASS 8 register: 2 bonafide, other school sees nothing';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 8 % %', v_n, r.cert_id; END IF;

    RAISE NOTICE '== % passed, % failed ==', pass, fail;
END;
$t$;

ROLLBACK;
