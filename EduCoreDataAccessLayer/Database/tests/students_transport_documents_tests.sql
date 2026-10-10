-- ============================================================================
-- Students, transport (non-money) and documents (TC / ID card) test suite.
--
-- The money side of admission, exit, promotion, bus billing and TC dues is
-- covered by money_admission_lifecycle_tests.sql. This suite covers what the
-- office actually types and prints: a child's record, the directory, photos,
-- the promotion roster, routes / stops / vehicles, and the TC and ID card.
--
-- Runs inside ONE transaction and ROLLS BACK.
--
--     psql ... -f students_transport_documents_tests.sql
--
-- Every check states the CORRECT behaviour. Phase 1 (2026-10-10) named the 28
-- failing ones "BUG <id> ..."; they were fixed the same day and keep their ids
-- (STU-*, PRO-*, TRN-*, TC-*) without the prefix. Where accepting a bad write
-- would spoil the fixture for later checks, the write is undone with a private
-- exception ('__undo__') after the result is recorded.
--
-- COVERS
--   A. Editing a student (DOB, mobile, duplicates, roll, audit, enrolment)
--   B. Directory search / filter / sort / paging
--   C. Student photo
--   D. Promotion: roster, retain, sections, double submit, history
--   E. Transport: routes, stops, vehicles, assignment guards, capacity, scope
--   F. Transfer Certificate: Board format, numbering, void, print, fields
--   G. ID cards: class set, order, missing photo, sections
--   H. Scope and leaks
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

-- Admit one test student into the current session and return its id. Every
-- fixture student goes through the real admission proc.
CREATE OR REPLACE FUNCTION pg_temp.admit(p_no text, p_name text, p_class text, p_sec text,
                                         p_roll text, p_dob date, p_mobile text,
                                         p_adm date DEFAULT CURRENT_DATE)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    c      refcursor := 'adm_' || lower(replace(p_no, '-', '_'));
    v_year varchar;
    v_id   integer;
    r      record;
BEGIN
    SELECT academic_year_name INTO v_year FROM academic.academic_years
     WHERE tenant_id = 24 AND school_id = 34 AND COALESCE(is_current, FALSE) LIMIT 1;

    CALL core.sp_admission_manage('SaveAdmission', 24, 34, 39, NULL,
         p_no, p_roll, p_name, 'Male', p_dob, p_class, p_sec, v_year, p_adm,
         p_guardian_name => 'ZZ Guardian', p_mobile => p_mobile,
         p_address => 'ZZ Address', p_result => c);
    FETCH c INTO r;
    CLOSE c;

    SELECT student_id INTO v_id FROM core.students
     WHERE tenant_id = 24 AND school_id = 34 AND admission_no = p_no;
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'Fixture admission % failed: %', p_no, r.message;
    END IF;
    RETURN v_id;
END $$;


DO $suite$
DECLARE
    c_tenant CONSTANT integer := 24;
    c_school CONSTANT integer := 34;
    c_user   CONSTANT integer := 39;

    v_year   varchar;          -- current session
    v_yearid integer;
    v_start  date;
    v_tgt    varchar;          -- the session promoted into
    v_tgtid  integer;

    c      refcursor;
    r      record;
    v_n    integer;
    v_m    integer;
    v_txt  text;
    v_txt2 text;
    v_bool boolean;
    v_acc  boolean;

    v_edit integer;            -- the student whose record is edited
    v_twin integer;
    v_dupsrc integer;
    v_other_sid integer;       -- a student of school 33
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '===== STUDENTS + TRANSPORT + DOCUMENTS TESTS =====';

    SELECT academic_year_id, academic_year_name, start_date INTO v_yearid, v_year, v_start
    FROM academic.academic_years
    WHERE tenant_id = c_tenant AND school_id = c_school AND COALESCE(is_current, FALSE) LIMIT 1;

    -- The suite leans on the school's numeric class names ("5", "6", "7") on
    -- purpose: they are what breaks text sorting and jQuery .data().
    IF v_year IS NULL OR NOT EXISTS (
        SELECT 1 FROM academic.academic_classes
         WHERE tenant_id = c_tenant AND school_id = c_school AND academic_year_id = v_yearid
           AND class_name IN ('5', '6', '7') AND COALESCE(is_deleted, FALSE) = FALSE
        HAVING COUNT(*) = 3) THEN
        RAISE EXCEPTION 'Fixture missing: school % needs classes 5, 6 and 7 in its current session.', c_school;
    END IF;

    SELECT student_id INTO v_other_sid FROM core.students
     WHERE tenant_id = 23 AND school_id = 33 AND is_active ORDER BY student_id LIMIT 1;
    IF v_other_sid IS NULL THEN
        RAISE EXCEPTION 'Fixture missing: school 33 needs one active student.';
    END IF;

    RAISE NOTICE 'fixture: session=%  other-school student=%', v_year, v_other_sid;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- A. Editing a student ---------------------------------';

    -- Admitted on 15 Apr so a DOB "after admission but before today" exists.
    v_edit := pg_temp.admit('ZZ-STD-01', 'ZZ Edit Kid', '5', 'A', '3',
                            DATE '2016-05-05', '9000000010', DATE '2026-04-15');

    -- A1: the office corrects DOB, mobile (typed with stray spaces) and Aadhaar.
    c := 'a1';
    CALL core.sp_student_update(c_tenant, c_school, c_user, v_edit,
         'ZZ Edit Kid', '3', 'Male', DATE '2016-06-06', '5', 'A',
         'ZZ Guardian', 'ZZ Mother', '  9876543210 ', NULL, 'ZZ Address',
         'B+', 'Hindu', 'General', 'Indian', '123456789012', NULL, c);
    SELECT dob, mobile INTO v_txt, v_txt2 FROM core.students WHERE student_id = v_edit;
    PERFORM pg_temp.chk('A1 corrected DOB is stored', v_txt = '2016-06-06', format('dob=%s', v_txt));
    PERFORM pg_temp.chk('A1b mobile is stored trimmed', v_txt2 = '9876543210', format('mobile="%s"', v_txt2));
    SELECT id_proof_no INTO v_txt FROM core.students WHERE student_id = v_edit;
    PERFORM pg_temp.chk('A1c Aadhaar is stored', v_txt = '123456789012', format('id_proof_no=%s', v_txt));

    -- A2: Admission refuses a future DOB (sp_admission_manage, AdmissionController);
    --     the edit form is the other door into the same column.
    v_acc := FALSE;
    BEGIN
        c := 'a2';
        CALL core.sp_student_update(c_tenant, c_school, c_user, v_edit,
             'ZZ Edit Kid', '3', 'Male', CURRENT_DATE + 30, '5', 'A',
             'ZZ Guardian', NULL, '9876543210', NULL, 'ZZ Address',
             NULL, NULL, NULL, NULL, NULL, NULL, c);
        v_acc := TRUE;
        RAISE EXCEPTION '__undo__';
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('STU-DOB-FUTURE future DOB refused on edit', NOT v_acc,
                            CASE WHEN v_acc THEN 'accepted (undone)' ELSE SQLERRM END);
    END;

    -- A3: born after they joined.
    v_acc := FALSE;
    BEGIN
        c := 'a3';
        CALL core.sp_student_update(c_tenant, c_school, c_user, v_edit,
             'ZZ Edit Kid', '3', 'Male', DATE '2026-05-01', '5', 'A',
             'ZZ Guardian', NULL, '9876543210', NULL, 'ZZ Address',
             NULL, NULL, NULL, NULL, NULL, NULL, c);
        v_acc := TRUE;
        RAISE EXCEPTION '__undo__';
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('STU-DOB-ADM DOB after admission date refused', NOT v_acc,
                            CASE WHEN v_acc THEN 'accepted (undone)' ELSE SQLERRM END);
    END;

    -- A4: Admission insists on 10 digits (AdmissionController.cs:212); the edit
    --     path has no server-side check at all, only the browser pattern.
    v_acc := FALSE;
    BEGIN
        c := 'a4';
        CALL core.sp_student_update(c_tenant, c_school, c_user, v_edit,
             'ZZ Edit Kid', '3', 'Male', NULL, '5', 'A',
             'ZZ Guardian', NULL, '98AB5', NULL, 'ZZ Address',
             NULL, NULL, NULL, NULL, NULL, NULL, c);
        v_acc := TRUE;
        RAISE EXCEPTION '__undo__';
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('STU-MOBILE a non-10-digit mobile refused on edit', NOT v_acc,
                            CASE WHEN v_acc THEN 'accepted "98AB5" (undone)' ELSE SQLERRM END);
    END;

    -- A5/A5b: blank and padded names.
    BEGIN
        c := 'a5';
        CALL core.sp_student_update(c_tenant, c_school, c_user, v_edit,
             '   ', '3', 'Male', NULL, '5', 'A',
             'ZZ Guardian', NULL, '9876543210', NULL, 'ZZ Address',
             NULL, NULL, NULL, NULL, NULL, NULL, c);
        PERFORM pg_temp.chk('A5 blank name refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('A5 blank name refused', TRUE, SQLERRM);
    END;

    c := 'a5b';
    CALL core.sp_student_update(c_tenant, c_school, c_user, v_edit,
         '  ZZ Edit Kid  ', '3', 'Male', NULL, '5', 'A',
         'ZZ Guardian', NULL, '9876543210', NULL, 'ZZ Address',
         NULL, NULL, NULL, NULL, NULL, NULL, c);
    SELECT student_name INTO v_txt FROM core.students WHERE student_id = v_edit;
    PERFORM pg_temp.chk('A5b a padded name is stored trimmed', v_txt = 'ZZ Edit Kid', format('"%s"', v_txt));

    -- A6: Admission refuses a second active student with the same name + DOB +
    --     mobile. Editing one student INTO another's identity must be refused too.
    v_twin   := pg_temp.admit('ZZ-STD-02', 'ZZ Twin', '5', 'A', '4', DATE '2016-07-07', '9000000011');
    v_dupsrc := pg_temp.admit('ZZ-STD-03', 'ZZ Dup Source', '5', 'A', '5', DATE '2016-08-08', '9000000012');
    v_acc := FALSE;
    BEGIN
        c := 'a6';
        CALL core.sp_student_update(c_tenant, c_school, c_user, v_dupsrc,
             'zz  TWIN', '5', 'Male', DATE '2016-07-07', '5', 'A',
             'ZZ Guardian', NULL, '9000000011', NULL, 'ZZ Address',
             NULL, NULL, NULL, NULL, NULL, NULL, c);
        v_acc := TRUE;
        RAISE EXCEPTION '__undo__';
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('STU-DUP-EDIT edit into a duplicate student refused', NOT v_acc,
                            CASE WHEN v_acc THEN 'two active "ZZ Twin" with same DOB+mobile (undone)' ELSE SQLERRM END);
    END;

    -- A7: two children with the same roll number in one class-section. The ID
    --     card sheet and attendance register both key on it.
    v_acc := FALSE;
    BEGIN
        c := 'a7';
        CALL core.sp_student_update(c_tenant, c_school, c_user, v_dupsrc,
             'ZZ Dup Source', '4', 'Male', NULL, '5', 'A',
             'ZZ Guardian', NULL, '9000000012', NULL, 'ZZ Address',
             NULL, NULL, NULL, NULL, NULL, NULL, c);
        v_acc := TRUE;
        RAISE EXCEPTION '__undo__';
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('STU-ROLL-DUP duplicate roll no in a section refused', NOT v_acc,
                            CASE WHEN v_acc THEN 'roll 4 now held by two students in 5-A (undone)' ELSE SQLERRM END);
    END;

    -- A8: gender drives the directory's Male / Female tiles; anything else falls
    --     out of both counts silently.
    v_acc := FALSE;
    BEGIN
        c := 'a8';
        CALL core.sp_student_update(c_tenant, c_school, c_user, v_edit,
             'ZZ Edit Kid', '3', 'Boy', NULL, '5', 'A',
             'ZZ Guardian', NULL, '9876543210', NULL, 'ZZ Address',
             NULL, NULL, NULL, NULL, NULL, NULL, c);
        v_acc := TRUE;
        RAISE EXCEPTION '__undo__';
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('STU-GENDER gender outside Male/Female/Other refused', NOT v_acc,
                            CASE WHEN v_acc THEN 'accepted "Boy" (undone)' ELSE SQLERRM END);
    END;

    -- A9: markup in a name is stored as typed. Storing it is right; every place
    --     that renders it must escape it (see the static XSS rows in the catalog).
    c := 'a9';
    CALL core.sp_student_update(c_tenant, c_school, c_user, v_twin,
         'ZZ Twin', '4', 'Male', NULL, '5', 'A',
         '<img src=x onerror=alert(1)>', NULL, '9000000011', NULL, 'ZZ Address',
         NULL, NULL, NULL, NULL, NULL, NULL, c);
    SELECT guardian_name INTO v_txt FROM core.students WHERE student_id = v_twin;
    PERFORM pg_temp.chk('A9 markup in a guardian name is stored verbatim',
                        v_txt = '<img src=x onerror=alert(1)>', v_txt);

    -- A10: who changed the DOB and the mobile? A1 changed both: one
    --      StudentEdited row with old -> new and the user.
    SELECT COUNT(*) INTO v_n FROM core.admission_audit
     WHERE student_id = v_edit AND action = 'StudentEdited'
       AND detail LIKE '%DOB: 2016-05-05 -> 2016-06-06%'
       AND detail LIKE '%Mobile: 9000000010 -> 9876543210%'
       AND action_by = c_user;
    PERFORM pg_temp.chk('STU-AUDIT DOB / mobile edits leave an audit row', v_n = 1,
                        format('%s matching StudentEdited row(s)', v_n));

    SELECT COUNT(*) INTO v_n FROM core.admission_audit
     WHERE student_id = v_edit AND action = 'StudentEdited' AND detail LIKE '%123456789012%';
    PERFORM pg_temp.chk_eq('A10b the Aadhaar number itself is not copied into the audit', v_n, 0);

    -- A10c: Aadhaar is 12 digits when filled, on edit as on admission.
    BEGIN
        c := 'a10c';
        CALL core.sp_student_update(c_tenant, c_school, c_user, v_edit,
             'ZZ Edit Kid', '3', 'Male', NULL, '5', 'A',
             'ZZ Guardian', NULL, '9876543210', NULL, 'ZZ Address',
             NULL, NULL, NULL, NULL, 'ABC123', NULL, c);
        PERFORM pg_temp.chk('STU-AADHAAR a non-12-digit Aadhaar refused on edit', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('STU-AADHAAR a non-12-digit Aadhaar refused on edit', TRUE, SQLERRM);
    END;

    -- A10d: an old row that predates the rule stays editable: an unchanged
    --       legacy ID proof does not block an unrelated edit.
    UPDATE core.students SET id_proof_no = 'BC-OLD-77' WHERE student_id = v_twin;
    c := 'a10d';
    CALL core.sp_student_update(c_tenant, c_school, c_user, v_twin,
         'ZZ Twin', '4', 'Male', NULL, '5', 'A',
         '<img src=x onerror=alert(1)>', 'ZZ Mum', '9000000011', NULL, 'ZZ Address',
         NULL, NULL, NULL, NULL, 'BC-OLD-77', NULL, c);
    SELECT mother_name INTO v_txt FROM core.students WHERE student_id = v_twin;
    PERFORM pg_temp.chk('A10d a legacy ID proof does not block another edit', v_txt = 'ZZ Mum', v_txt);

    -- A10e/f: admission applies the same Aadhaar and roll rules.
    DECLARE ca refcursor := 'a10e'; ra record;
    BEGIN
        CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
             'ZZ-STD-91', NULL, 'ZZ Bad Aadhaar', 'Male', DATE '2016-01-01', '5', 'A', v_year, CURRENT_DATE,
             p_mobile => '9000000911', p_id_proof_no => '1234', p_result => ca);
        FETCH ca INTO ra; CLOSE ca;
        PERFORM pg_temp.chk('STU-AADHAAR-ADM admission refuses a non-12-digit Aadhaar',
                            ra.success = 0 AND ra.message LIKE '%12 digits%', ra.message);
    END;
    DECLARE ca refcursor := 'a10f'; ra record;
    BEGIN
        CALL core.sp_admission_manage('SaveAdmission', c_tenant, c_school, c_user, NULL,
             'ZZ-STD-92', '4', 'ZZ Roll Clash', 'Male', DATE '2016-01-02', '5', 'A', v_year, CURRENT_DATE,
             p_mobile => '9000000912', p_result => ca);
        FETCH ca INTO ra; CLOSE ca;
        PERFORM pg_temp.chk('STU-ROLL-ADM admission refuses a roll no already used in the section',
                            ra.success = 0 AND ra.message LIKE '%already used%', ra.message);
    END;

    -- A11: a roll number change should reach the per-session record, which is
    --      what Enrolment History and the next promotion read.
    c := 'a11';
    CALL core.sp_student_update(c_tenant, c_school, c_user, v_edit,
         'ZZ Edit Kid', '13', 'Male', NULL, '5', 'A',
         'ZZ Guardian', NULL, '9876543210', NULL, 'ZZ Address',
         NULL, NULL, NULL, NULL, NULL, NULL, c);
    SELECT roll_no INTO v_txt FROM core.student_enrolment WHERE student_id = v_edit AND academic_year = v_year;
    PERFORM pg_temp.chk('STU-ENROL-ROLL roll change reaches enrolment history', v_txt = '13',
                        format('enrolment roll=%s, student roll=13', COALESCE(v_txt, 'NULL')));

    -- A12: a section change is followed by the enrolment row and audited.
    c := 'a12';
    CALL core.sp_student_update(c_tenant, c_school, c_user, v_edit,
         'ZZ Edit Kid', '13', 'Male', NULL, '5', 'B',
         'ZZ Guardian', NULL, '9876543210', NULL, 'ZZ Address',
         NULL, NULL, NULL, NULL, NULL, NULL, c);
    SELECT section INTO v_txt FROM core.student_enrolment WHERE student_id = v_edit AND academic_year = v_year;
    PERFORM pg_temp.chk('A12 section change reaches the enrolment row', v_txt = 'B', format('section=%s', v_txt));
    SELECT COUNT(*) INTO v_n FROM core.admission_audit WHERE student_id = v_edit AND action = 'SectionChanged';
    PERFORM pg_temp.chk_eq('A12b ...and leaves a SectionChanged audit row', v_n, 1);

    -- A13: a section the class does not have.
    BEGIN
        c := 'a13';
        CALL core.sp_student_update(c_tenant, c_school, c_user, v_edit,
             'ZZ Edit Kid', '13', 'Male', NULL, '5', 'Z',
             'ZZ Guardian', NULL, '9876543210', NULL, 'ZZ Address',
             NULL, NULL, NULL, NULL, NULL, NULL, c);
        PERFORM pg_temp.chk('A13 a section the class does not have refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('A13 a section the class does not have refused', TRUE, SQLERRM);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- B. Directory search / filter / sort --------------------';

    PERFORM pg_temp.admit('ZZ-STD-04', 'ZZ Meera Devi', '2', 'A', '1', DATE '2019-01-01', '9000000041');
    PERFORM pg_temp.admit('ZZ-STD-05', 'ZZ Sort Lkg',   'LKG', 'Kid A', '1', DATE '2022-01-01', '9000000051');
    PERFORM pg_temp.admit('ZZ-STD-06', 'ZZ Sort Two',   '2', 'A', '2', DATE '2019-02-02', '9000000061');

    -- B1-B4: name (any case), admission no (lower case), partial mobile, padding.
    c := 'b1';
    CALL core.sp_student_list(c_tenant, c_school, c_user, 'zz MEERA', NULL, NULL, NULL, NULL, NULL,
         1, 50, NULL, 'asc', c);
    v_n := 0; LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_n := v_n + 1; v_txt := r.student_name; END LOOP; CLOSE c;
    PERFORM pg_temp.chk('B1 search by name ignores case', v_n = 1 AND v_txt = 'ZZ Meera Devi', format('%s row(s)', v_n));

    c := 'b2';
    CALL core.sp_student_list(c_tenant, c_school, c_user, 'zz-std-04', NULL, NULL, NULL, NULL, NULL,
         1, 50, NULL, 'asc', c);
    v_n := 0; LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_n := v_n + 1; END LOOP; CLOSE c;
    PERFORM pg_temp.chk_eq('B2 search by admission no in lower case', v_n, 1);

    c := 'b3';
    CALL core.sp_student_list(c_tenant, c_school, c_user, '00000041', NULL, NULL, NULL, NULL, NULL,
         1, 50, NULL, 'asc', c);
    v_n := 0; LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_n := v_n + 1; END LOOP; CLOSE c;
    PERFORM pg_temp.chk_eq('B3 search by part of the parent mobile', v_n, 1);

    c := 'b4';
    CALL core.sp_student_list(c_tenant, c_school, c_user, '   zz meera devi   ', NULL, NULL, NULL, NULL, NULL,
         1, 50, NULL, 'asc', c);
    v_n := 0; LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_n := v_n + 1; END LOOP; CLOSE c;
    PERFORM pg_temp.chk_eq('B4 surrounding spaces in the search are ignored', v_n, 1);

    -- B5: a double space typed between the names.
    c := 'b5';
    CALL core.sp_student_list(c_tenant, c_school, c_user, 'zz meera  devi', NULL, NULL, NULL, NULL, NULL,
         1, 50, NULL, 'asc', c);
    v_n := 0; LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_n := v_n + 1; END LOOP; CLOSE c;
    PERFORM pg_temp.chk_eq('STU-SEARCH-SPACE a double space still finds the name', v_n, 1);

    -- B6: '%' and '_' are LIKE wildcards; typed into the box they match everyone.
    SELECT COUNT(*) INTO v_m FROM core.students WHERE tenant_id = c_tenant AND school_id = c_school AND is_active;
    c := 'b6';
    CALL core.sp_student_list(c_tenant, c_school, c_user, '%', NULL, NULL, NULL, NULL, NULL,
         1, 200, NULL, 'asc', c);
    v_n := 0; LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_n := v_n + 1; END LOOP; CLOSE c;
    PERFORM pg_temp.chk('STU-SEARCH-WILDCARD "%" is a literal, not match-all', v_n = 0,
                        format('"%%" returned %s of %s students', v_n, v_m));

    -- B7: class "5" filter is exact (not 15, not 5-anything).
    c := 'b7';
    CALL core.sp_student_list(c_tenant, c_school, c_user, NULL, '5', NULL, NULL, NULL, NULL,
         1, 200, NULL, 'asc', c);
    v_n := 0; v_bool := TRUE;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_n := v_n + 1; IF r.class_name <> '5' THEN v_bool := FALSE; END IF; END LOOP; CLOSE c;
    PERFORM pg_temp.chk('B7 numeric class filter "5" is exact', v_bool AND v_n >= 3, format('%s row(s)', v_n));

    -- B8: "sort by class" should follow the school's teaching order (LKG before
    --     2), not text order, where "2" < "LKG" and "10" < "2".
    c := 'b8';
    CALL core.sp_student_list(c_tenant, c_school, c_user, 'ZZ Sort', NULL, NULL, NULL, NULL, NULL,
         1, 50, 'class', 'asc', c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('STU-SORT-CLASS class sort follows teaching order',
                        r.class_name = 'LKG', format('first row is class %s', r.class_name));

    -- B9: paging: page 2 of size 1 is the second row and total_count is stable.
    c := 'b9';
    CALL core.sp_student_list(c_tenant, c_school, c_user, 'ZZ Sort', NULL, NULL, NULL, NULL, NULL,
         2, 1, 'name', 'asc', c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('B9 page 2 of size 1 is the second row by name',
                        r.student_name = 'ZZ Sort Two' AND r.total_count = 2,
                        format('%s, total %s', r.student_name, r.total_count));

    -- B10: other school's directory shows none of ours.
    c := 'b10';
    CALL core.sp_student_list(23, 33, c_user, 'ZZ', NULL, NULL, NULL, NULL, NULL, 1, 200, NULL, 'asc', c);
    v_n := 0; LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.admission_no LIKE 'ZZ-STD-%' THEN v_n := v_n + 1; END IF; END LOOP; CLOSE c;
    PERFORM pg_temp.chk_eq('B10 another school''s directory shows none of ours', v_n, 0);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- C. Student photo --------------------------------------';

    c := 'c1';
    CALL core.sp_student_set_photo(c_tenant, c_school, c_user, v_edit,
         '/uploads/students/24/34/student_1_a.jpg', c);
    SELECT photo_url INTO v_txt FROM core.students WHERE student_id = v_edit;
    PERFORM pg_temp.chk('C1 photo url stored', v_txt = '/uploads/students/24/34/student_1_a.jpg', v_txt);

    c := 'c2';
    CALL core.sp_student_set_photo(c_tenant, c_school, c_user, v_edit,
         '/uploads/students/24/34/student_1_b.jpg', c);
    SELECT photo_url INTO v_txt FROM core.students WHERE student_id = v_edit;
    PERFORM pg_temp.chk('C2 replacing the photo points at the new file', v_txt LIKE '%student_1_b.jpg', v_txt);

    BEGIN
        c := 'c3';
        CALL core.sp_student_set_photo(23, 33, c_user, v_edit, '/uploads/evil.jpg', c);
        PERFORM pg_temp.chk('C3 another school cannot set our student''s photo', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C3 another school cannot set our student''s photo', TRUE, SQLERRM);
    END;
    SELECT photo_url INTO v_txt FROM core.students WHERE student_id = v_edit;
    PERFORM pg_temp.chk('C3b ...and the photo is unchanged', v_txt LIKE '%student_1_b.jpg', v_txt);

    -- C4: the replaced file is handed back so the controller can delete it,
    --     and every change leaves who / when on the History card.
    c := 'c4';
    CALL core.sp_student_set_photo(c_tenant, c_school, c_user, v_edit,
         '/uploads/students/24/34/student_1_c.jpg', c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk('PHO-08 the replaced photo''s url comes back for deletion',
                        r.old_photo_url LIKE '%student_1_b.jpg', COALESCE(r.old_photo_url, 'NULL'));
    SELECT COUNT(*) INTO v_n FROM core.admission_audit
     WHERE student_id = v_edit AND action = 'PhotoChanged' AND action_by = c_user;
    PERFORM pg_temp.chk_eq('PHO-12 each photo change is audited (added, replaced, replaced)', v_n, 3);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- D. Promotion (Class 5 at session end) ------------------';

    -- Target session + the same ladder, exactly as promotion_tests does it.
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
    END IF;

    INSERT INTO academic.academic_classes(tenant_id, school_id, academic_year_id,
                                          class_name, display_order, created_by)
    SELECT c_tenant, c_school, v_tgtid, class_name, display_order, c_user
    FROM academic.academic_classes
    WHERE tenant_id = c_tenant AND school_id = c_school AND academic_year_id = v_yearid
      AND COALESCE(is_deleted, FALSE) = FALSE
      AND class_name NOT IN (SELECT class_name FROM academic.academic_classes
                              WHERE tenant_id = c_tenant AND school_id = c_school
                                AND academic_year_id = v_tgtid);

    INSERT INTO academic.academic_class_sections(tenant_id, school_id, academic_year_id,
                                                 academic_class_id, section_name,
                                                 display_order, created_by)
    SELECT c_tenant, c_school, v_tgtid, tc.academic_class_id, s.section_name, s.display_order, c_user
    FROM academic.academic_class_sections s
    JOIN academic.academic_classes sc ON sc.academic_class_id = s.academic_class_id
    JOIN academic.academic_classes tc ON tc.class_name = sc.class_name
                                     AND tc.academic_year_id = v_tgtid
                                     AND tc.tenant_id = c_tenant AND tc.school_id = c_school
    WHERE s.tenant_id = c_tenant AND s.school_id = c_school AND s.academic_year_id = v_yearid
      AND COALESCE(s.is_deleted, FALSE) = FALSE
      AND NOT EXISTS (SELECT 1 FROM academic.academic_class_sections x
                       WHERE x.academic_year_id = v_tgtid
                         AND x.academic_class_id = tc.academic_class_id
                         AND x.section_name = s.section_name);

    RAISE NOTICE 'promotion: % -> %', v_year, v_tgt;

    DECLARE
        p1 integer; p2 integer; r1 integer; r2 integer; b1 integer;
    BEGIN
        p1 := pg_temp.admit('ZZ-STD-11', 'ZZ Promote One', '5', 'A', '21', DATE '2015-01-11', '9000000111');
        p2 := pg_temp.admit('ZZ-STD-12', 'ZZ Promote Two', '5', 'A', '22', DATE '2015-01-12', '9000000112');
        r1 := pg_temp.admit('ZZ-STD-13', 'ZZ Retain One',  '5', 'A', '23', DATE '2015-01-13', '9000000113');
        r2 := pg_temp.admit('ZZ-STD-14', 'ZZ Retain Two',  '5', 'A', '24', DATE '2015-01-14', '9000000114');
        b1 := pg_temp.admit('ZZ-STD-15', 'ZZ Section B',   '5', 'B', '25', DATE '2015-01-15', '9000000115');

        -- D0: the Section dropdowns (promotion target + Edit Student) come from
        --     sp_class_setup_sections, which reads the session's class setup
        --     (it used to be sp_class_active_sections, which lists only sections
        --     that already hold students). Class 5 has A, B and C; C is empty.
        c := 'd0';
        CALL core.sp_class_setup_sections(c_tenant, c_school, '5', v_year, c);
        v_txt := '';
        LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_txt := v_txt || r.section || ','; END LOOP; CLOSE c;
        PERFORM pg_temp.chk('PRO-SECTIONS an empty set-up section is offered',
                            v_txt = 'A,B,C,', format('offered: %s (class 5 has A,B,C)', rtrim(v_txt, ',')));

        c := 'd0b';
        CALL core.sp_class_setup_sections(23, 33, '5', v_year, c);
        v_n := 0; LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_n := v_n + 1; END LOOP; CLOSE c;
        PERFORM pg_temp.chk_eq('D0b another school does not see our class setup', v_n, 0);

        -- Run 1: two promoted, two retained, one whose section 6 does not have,
        -- plus another school's student smuggled into the payload.
        c := 'd1';
        CALL core.sp_student_promote(c_tenant, c_school, c_user, v_year, v_tgt, 'keep', TRUE,
             jsonb_build_array(
                 jsonb_build_object('studentId', p1, 'outcome', 'promote'),
                 jsonb_build_object('studentId', p2, 'outcome', 'promote'),
                 jsonb_build_object('studentId', r1, 'outcome', 'retain'),
                 jsonb_build_object('studentId', r2, 'outcome', 'retain'),
                 jsonb_build_object('studentId', b1, 'outcome', 'promote'),
                 jsonb_build_object('studentId', v_other_sid, 'outcome', 'promote')), c);
        FETCH c INTO r; CLOSE c;
        PERFORM pg_temp.chk('D1 2 promoted, 2 retained, 2 skipped',
                            r.promoted = 2 AND r.retained = 2 AND r.skipped = 2,
                            format('%s / %s / %s', r.promoted, r.retained, r.skipped));
        PERFORM pg_temp.chk('D1b the skip list says why (section B, not found)',
                            r.skipped_detail LIKE '%section B%' AND r.skipped_detail LIKE '%not found%',
                            r.skipped_detail);

        SELECT class_name || '-' || section || ' ' || academic_year INTO v_txt FROM core.students WHERE student_id = p1;
        PERFORM pg_temp.chk('D2 promoted student is in 6-A of the new session',
                            v_txt = '6-A ' || v_tgt, v_txt);
        SELECT class_name || '-' || section || ' ' || academic_year INTO v_txt FROM core.students WHERE student_id = r1;
        PERFORM pg_temp.chk('D3 retained student is in 5-A of the new session',
                            v_txt = '5-A ' || v_tgt, v_txt);
        SELECT class_name || '-' || section INTO v_txt FROM core.students WHERE student_id = b1;
        PERFORM pg_temp.chk('D4 the 5-B student was not moved', v_txt = '5-B', v_txt);
        SELECT class_name INTO v_txt FROM core.students WHERE student_id = v_other_sid;
        SELECT tenant_id INTO v_n FROM core.students WHERE student_id = v_other_sid;
        PERFORM pg_temp.chk('D5 the other school''s student was not touched', v_n = 23, format('tenant %s, class %s', v_n, v_txt));

        -- D6: the 5-B student, with an explicit target section.
        c := 'd6';
        CALL core.sp_student_promote(c_tenant, c_school, c_user, v_year, v_tgt, 'A', TRUE,
             jsonb_build_array(jsonb_build_object('studentId', b1, 'outcome', 'promote')), c);
        SELECT class_name || '-' || section INTO v_txt FROM core.students WHERE student_id = b1;
        PERFORM pg_temp.chk('D6 with target section A the 5-B student lands in 6-A', v_txt = '6-A', v_txt);

        -- D7: double submit of run 1 moves nobody a second class.
        BEGIN
            c := 'd7';
            CALL core.sp_student_promote(c_tenant, c_school, c_user, v_year, v_tgt, 'keep', TRUE,
                 jsonb_build_array(jsonb_build_object('studentId', p1, 'outcome', 'promote')), c);
            SELECT class_name INTO v_txt FROM core.students WHERE student_id = p1;
            PERFORM pg_temp.chk('D7 a repeated run does not promote twice', v_txt = '6', format('now in %s', v_txt));
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('D7 a repeated run does not promote twice', TRUE, SQLERRM);
        END;

        -- D8: enrolment trail: old session closed with the outcome, new one current.
        SELECT string_agg(academic_year || ':' || class_name || ':' || status || ':' || is_current::text, ' | '
                          ORDER BY academic_year = v_tgt)
          INTO v_txt FROM core.student_enrolment WHERE student_id = r1;
        PERFORM pg_temp.chk('D8 retained student''s enrolment trail',
                            v_txt = v_year || ':5:Retained:false | ' || v_tgt || ':5:Active:true', v_txt);

        -- D9: the office reloads the roster for "5, " || current session after the run.
        --     Students who already moved still show (their old enrolment row matches)
        --     and every one of them is "skipped (not in ...)" on the next commit.
        c := 'd9';
        CALL core.sp_admission_manage('GetStudents', c_tenant, c_school, c_user,
             p_page_size => 1000, p_filter_class => '5', p_filter_year => v_year,
             p_filter_status => 'Active', p_result => c);
        v_n := 0;
        LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
            IF r.student_id IN (p1, p2, r1, r2) THEN v_n := v_n + 1; END IF;
        END LOOP; CLOSE c;
        PERFORM pg_temp.chk('PRO-ROSTER roster omits students already moved on', v_n = 0,
                            format('%s already-moved student(s) listed again', v_n));

        -- D10: the History card shows the promotion and who did it.
        c := 'd10';
        CALL core.sp_student_history_get(c_tenant, c_school, c_user, r1, c);
        v_bool := FALSE;
        LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
            IF r.action = 'Promotion: Retain' AND r.done_by IS NOT NULL THEN v_bool := TRUE; END IF;
        END LOOP; CLOSE c;
        PERFORM pg_temp.chk('D10 history card shows "Promotion: Retain" and who', v_bool, '');

        -- D11: another school cannot read that history.
        c := 'd11';
        CALL core.sp_student_history_get(23, 33, c_user, r1, c);
        v_n := 0; LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_n := v_n + 1; END LOOP; CLOSE c;
        PERFORM pg_temp.chk_eq('D11 another school reads none of our history', v_n, 0);

        c := 'd12';
        CALL core.sp_student_enrolment_history(23, 33, c_user, r1, c);
        v_n := 0; LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_n := v_n + 1; END LOOP; CLOSE c;
        PERFORM pg_temp.chk_eq('D12 ...nor our enrolment history', v_n, 0);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- E. Transport (routes, stops, vehicles) ----------------';

    DECLARE
        v_r1 integer; v_r2 integer; v_r33 integer;
        v_sa integer; v_sb integer; v_sc integer; v_sy integer;
        s1 integer; s2 integer; s3 integer; s4 integer;
        v_veh integer;
    BEGIN
        -- E1: a route with three stops.
        c := 'e1';
        CALL core.sp_transport_route_manage('SaveRoute', c_tenant, c_school, c_user,
             NULL, 'ZZ Route North', 'three stops',
             jsonb_build_array(
                 jsonb_build_object('stopId', 0, 'stopName', 'ZZ Stop A', 'monthlyFare', 500, 'displayOrder', 1),
                 jsonb_build_object('stopId', 0, 'stopName', 'ZZ Stop B', 'monthlyFare', 700, 'displayOrder', 2),
                 jsonb_build_object('stopId', 0, 'stopName', 'ZZ Stop C', 'monthlyFare', 900, 'displayOrder', 3)), c);
        SELECT route_id INTO v_r1 FROM core.transport_routes
         WHERE tenant_id = c_tenant AND school_id = c_school AND route_name = 'ZZ Route North';
        SELECT stop_id INTO v_sa FROM core.transport_stops WHERE route_id = v_r1 AND stop_name = 'ZZ Stop A';
        SELECT stop_id INTO v_sb FROM core.transport_stops WHERE route_id = v_r1 AND stop_name = 'ZZ Stop B';
        SELECT stop_id INTO v_sc FROM core.transport_stops WHERE route_id = v_r1 AND stop_name = 'ZZ Stop C';

        c := 'e1b';
        CALL core.sp_transport_route_manage('GetStops', c_tenant, c_school, c_user, v_r1, NULL, NULL, NULL, c);
        v_txt := '';
        LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_txt := v_txt || r.stop_name || ','; END LOOP; CLOSE c;
        PERFORM pg_temp.chk('E1 three stops, in the order they were entered',
                            v_txt = 'ZZ Stop A,ZZ Stop B,ZZ Stop C,', v_txt);

        -- E2: the same route again with different case and padding.
        v_acc := FALSE;
        BEGIN
            c := 'e2';
            CALL core.sp_transport_route_manage('SaveRoute', c_tenant, c_school, c_user,
                 NULL, '  zz route NORTH ', NULL, '[]'::jsonb, c);
            v_acc := TRUE;
            RAISE EXCEPTION '__undo__';
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('TRN-DUP-ROUTE a duplicate route name refused', NOT v_acc,
                                CASE WHEN v_acc THEN 'a second "ZZ Route North" was created (undone)' ELSE SQLERRM END);
        END;

        -- E3: a negative fare.
        v_acc := FALSE;
        BEGIN
            c := 'e3';
            CALL core.sp_transport_route_manage('SaveRoute', c_tenant, c_school, c_user,
                 NULL, 'ZZ Route Negative', NULL,
                 jsonb_build_array(jsonb_build_object('stopId', 0, 'stopName', 'ZZ Neg Stop', 'monthlyFare', -100)), c);
            v_acc := TRUE;
            RAISE EXCEPTION '__undo__';
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('TRN-NEG-FARE a negative stop fare refused', NOT v_acc,
                                CASE WHEN v_acc THEN 'stop saved at -100 a month (undone)' ELSE SQLERRM END);
        END;

        -- Riders for Stop C.
        s1 := pg_temp.admit('ZZ-STD-21', 'ZZ Rider One',   '3', 'A', '1', DATE '2017-03-01', '9000000211');
        s2 := pg_temp.admit('ZZ-STD-22', 'ZZ Rider Two',   '3', 'A', '2', DATE '2017-03-02', '9000000212');
        s3 := pg_temp.admit('ZZ-STD-23', 'ZZ Rider Three', '3', 'A', '3', DATE '2017-03-03', '9000000213');
        s4 := pg_temp.admit('ZZ-STD-24', 'ZZ Rider Four',  '3', 'A', '4', DATE '2017-03-04', '9000000214');

        -- E4: a 2-seat bus on the route, then two children on it.
        c := 'e4';
        CALL core.sp_transport_vehicle_manage('SaveVehicle', c_tenant, c_school, c_user,
             NULL, 'ZZ-BUS-01', 2, 'ZZ Driver', '9000009999', v_r1, NULL, c);
        SELECT vehicle_id INTO v_veh FROM core.transport_vehicles
         WHERE tenant_id = c_tenant AND school_id = c_school AND vehicle_no = 'ZZ-BUS-01';
        PERFORM pg_temp.chk('E4 vehicle saved on the route', v_veh IS NOT NULL, format('vehicle_id=%s', v_veh));

        c := 'e4a'; CALL core.sp_transport_assign_manage('SaveAssignment', c_tenant, c_school, c_user, s1, v_r1, v_sc, v_year, CURRENT_DATE, 12, c);
        c := 'e4b'; CALL core.sp_transport_assign_manage('SaveAssignment', c_tenant, c_school, c_user, s2, v_r1, v_sc, v_year, CURRENT_DATE, 12, c);

        -- E5: approved default -- a full route refuses a new rider, and says
        --     how full it is.
        BEGIN
            c := 'e5';
            CALL core.sp_transport_assign_manage('SaveAssignment', c_tenant, c_school, c_user, s3, v_r1, v_sc, v_year, CURRENT_DATE, 12, c);
            PERFORM pg_temp.chk('TRN-CAPACITY a 3rd rider on a 2-seat route is refused', FALSE, 'accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('TRN-CAPACITY a 3rd rider on a 2-seat route is refused',
                                SQLERRM LIKE '%2 of 2 seats%', SQLERRM);
        END;

        c := 'e5b';
        CALL core.sp_transport_route_manage('GetRoutes', c_tenant, c_school, c_user, NULL, NULL, NULL, NULL, c);
        v_txt := NULL;
        LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.route_id = v_r1 THEN v_txt := r.riders || '/' || r.seats; END IF; END LOOP; CLOSE c;
        PERFORM pg_temp.chk('E5b Routes shows riders / seats', v_txt = '2/2', COALESCE(v_txt, 'not listed'));

        -- E5c: a child already on the route can still move stop on a full route.
        c := 'e5c';
        CALL core.sp_transport_assign_manage('SaveAssignment', c_tenant, c_school, c_user, s1, v_r1, v_sa, v_year, CURRENT_DATE, 12, c);
        SELECT stop_id INTO v_n FROM core.student_transport WHERE student_id = s1 AND is_active;
        PERFORM pg_temp.chk('E5c a rider already on a full route can change stop', v_n = v_sa, format('stop %s', v_n));
        c := 'e5d';
        CALL core.sp_transport_assign_manage('SaveAssignment', c_tenant, c_school, c_user, s1, v_r1, v_sc, v_year, CURRENT_DATE, 12, c);

        -- E6: the office edits the route and drops Stop C while children ride it.
        BEGIN
            c := 'e6';
            CALL core.sp_transport_route_manage('SaveRoute', c_tenant, c_school, c_user,
                 v_r1, 'ZZ Route North', 'three stops',
                 jsonb_build_array(
                     jsonb_build_object('stopId', v_sa, 'stopName', 'ZZ Stop A', 'monthlyFare', 500, 'displayOrder', 1),
                     jsonb_build_object('stopId', v_sb, 'stopName', 'ZZ Stop B', 'monthlyFare', 700, 'displayOrder', 2)), c);
            PERFORM pg_temp.chk('TRN-DEL-STOP a stop with riders cannot be removed', FALSE, 'route saved without it');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('TRN-DEL-STOP a stop with riders cannot be removed', TRUE, SQLERRM);
        END;
        SELECT is_active INTO v_bool FROM core.transport_stops WHERE stop_id = v_sc;
        PERFORM pg_temp.chk('E6b ...and Stop C is still in service', v_bool, format('is_active=%s', v_bool));

        -- E6c: approved default -- a fare change applies to new riders only.
        c := 'e6c';
        CALL core.sp_transport_route_manage('SaveRoute', c_tenant, c_school, c_user,
             v_r1, 'ZZ Route North', 'three stops',
             jsonb_build_array(
                 jsonb_build_object('stopId', v_sa, 'stopName', 'ZZ Stop A', 'monthlyFare', 500, 'displayOrder', 1),
                 jsonb_build_object('stopId', v_sb, 'stopName', 'ZZ Stop B', 'monthlyFare', 700, 'displayOrder', 2),
                 jsonb_build_object('stopId', v_sc, 'stopName', 'ZZ Stop C', 'monthlyFare', 950, 'displayOrder', 3)), c);
        SELECT monthly_fare INTO v_m FROM core.transport_stops WHERE stop_id = v_sc;
        SELECT monthly_fare INTO v_n FROM core.student_transport WHERE student_id = s2 AND is_active;
        PERFORM pg_temp.chk('E6c new stop fare saved; the rider keeps the fare assigned',
                            v_m = 950 AND v_n = 900, format('stop now %s, rider still %s', v_m, v_n));

        -- E7: a second route, switched off; assigning to it must be refused.
        c := 'e7';
        CALL core.sp_transport_route_manage('SaveRoute', c_tenant, c_school, c_user,
             NULL, 'ZZ Route South', NULL,
             jsonb_build_array(jsonb_build_object('stopId', 0, 'stopName', 'ZZ Stop Y', 'monthlyFare', 400, 'displayOrder', 1)), c);
        SELECT route_id INTO v_r2 FROM core.transport_routes
         WHERE tenant_id = c_tenant AND school_id = c_school AND route_name = 'ZZ Route South';
        SELECT stop_id INTO v_sy FROM core.transport_stops WHERE route_id = v_r2;

        c := 'e7a';
        CALL core.sp_transport_route_manage('ToggleRouteStatus', c_tenant, c_school, c_user, v_r2, NULL, NULL, NULL, c);

        c := 'e7b';
        CALL core.sp_transport_routes_dropdown(c_tenant, c_school, c);
        v_n := 0; LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.route_id = v_r2 THEN v_n := v_n + 1; END IF; END LOOP; CLOSE c;
        PERFORM pg_temp.chk_eq('E7 an inactive route is not offered on Assign', v_n, 0);

        BEGIN
            c := 'e7c';
            CALL core.sp_transport_assign_manage('SaveAssignment', c_tenant, c_school, c_user, s4, v_r2, v_sy, v_year, CURRENT_DATE, 12, c);
            PERFORM pg_temp.chk('TRN-INACTIVE-ROUTE assigning to an inactive route refused', FALSE, 'accepted and billed');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('TRN-INACTIVE-ROUTE assigning to an inactive route refused', TRUE, SQLERRM);
        END;

        -- E8: back on, but Stop Y replaced by Stop Z; Y must not take new riders.
        c := 'e8';
        CALL core.sp_transport_route_manage('ToggleRouteStatus', c_tenant, c_school, c_user, v_r2, NULL, NULL, NULL, c);
        c := 'e8a';
        CALL core.sp_transport_route_manage('SaveRoute', c_tenant, c_school, c_user,
             v_r2, 'ZZ Route South', NULL,
             jsonb_build_array(jsonb_build_object('stopId', 0, 'stopName', 'ZZ Stop Z', 'monthlyFare', 450, 'displayOrder', 1)), c);
        SELECT is_active INTO v_bool FROM core.transport_stops WHERE stop_id = v_sy;
        PERFORM pg_temp.chk('E8 a stop with no riders left out of the save is switched off', v_bool = FALSE, format('is_active=%s', v_bool));

        BEGIN
            c := 'e8b';
            CALL core.sp_transport_assign_manage('SaveAssignment', c_tenant, c_school, c_user, s4, v_r2, v_sy, v_year, CURRENT_DATE, 12, c);
            PERFORM pg_temp.chk('TRN-INACTIVE-STOP assigning to a removed stop refused', FALSE, 'accepted and billed');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('TRN-INACTIVE-STOP assigning to a removed stop refused', TRUE, SQLERRM);
        END;

        -- E9-E11: vehicles.
        BEGIN
            c := 'e9';
            CALL core.sp_transport_vehicle_manage('SaveVehicle', c_tenant, c_school, c_user,
                 NULL, ' zz bus 01 ', 40, NULL, NULL, NULL, NULL, c);
            PERFORM pg_temp.chk('TRN-DUP-VEH a duplicate vehicle number refused', FALSE, 'second ZZ-BUS-01 registered');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('TRN-DUP-VEH a duplicate vehicle number refused', TRUE, SQLERRM);
        END;

        BEGIN
            c := 'e10';
            CALL core.sp_transport_vehicle_manage('SaveVehicle', c_tenant, c_school, c_user,
                 NULL, 'ZZ-BUS-NEG', -5, NULL, NULL, NULL, NULL, c);
            PERFORM pg_temp.chk('TRN-CAP-NEG a negative capacity refused', FALSE, 'capacity -5 stored');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('TRN-CAP-NEG a negative capacity refused', TRUE, SQLERRM);
        END;

        -- A route of school 33 (made here if it has none; rolled back with the rest).
        SELECT route_id INTO v_r33 FROM core.transport_routes
         WHERE tenant_id = 23 AND school_id = 33 AND NOT is_deleted ORDER BY route_id LIMIT 1;
        IF v_r33 IS NULL THEN
            c := 'e11x';
            CALL core.sp_transport_route_manage('SaveRoute', 23, 33, c_user, NULL, 'ZZ Other School Route', NULL, '[]'::jsonb, c);
            SELECT route_id INTO v_r33 FROM core.transport_routes
             WHERE tenant_id = 23 AND school_id = 33 AND route_name = 'ZZ Other School Route';
        END IF;

        BEGIN
            c := 'e11';
            CALL core.sp_transport_vehicle_manage('SaveVehicle', c_tenant, c_school, c_user,
                 v_veh, 'ZZ-BUS-01', 2, NULL, NULL, v_r33, NULL, c);
            PERFORM pg_temp.chk('TRN-VEH-SCOPE vehicle cannot point at another school''s route', FALSE, 'stored');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('TRN-VEH-SCOPE vehicle cannot point at another school''s route', TRUE, SQLERRM);
        END;
        SELECT route_id INTO v_n FROM core.transport_vehicles WHERE vehicle_id = v_veh;
        PERFORM pg_temp.chk('E11b ...the bus is still on our route', v_n = v_r1, format('route %s', v_n));

        -- E12: approved default -- the only active bus of a route children ride
        --      cannot be switched off (sold); with a second bus on the route it can.
        BEGIN
            c := 'e12';
            CALL core.sp_transport_vehicle_manage('ToggleVehicleStatus', c_tenant, c_school, c_user, v_veh, NULL, NULL, NULL, NULL, NULL, NULL, c);
            PERFORM pg_temp.chk('TRN-SOLD the last bus of a route with riders cannot be switched off', FALSE, 'switched off');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('TRN-SOLD the last bus of a route with riders cannot be switched off', TRUE, SQLERRM);
        END;

        DECLARE v_veh2 integer;
        BEGIN
            c := 'e12a';
            CALL core.sp_transport_vehicle_manage('SaveVehicle', c_tenant, c_school, c_user,
                 NULL, 'ZZ-BUS-02', 40, NULL, NULL, v_r1, NULL, c);
            SELECT vehicle_id INTO v_veh2 FROM core.transport_vehicles
             WHERE tenant_id = c_tenant AND school_id = c_school AND vehicle_no = 'ZZ-BUS-02';

            c := 'e12b';
            CALL core.sp_transport_vehicle_manage('ToggleVehicleStatus', c_tenant, c_school, c_user, v_veh, NULL, NULL, NULL, NULL, NULL, NULL, c);
            SELECT is_active INTO v_bool FROM core.transport_vehicles WHERE vehicle_id = v_veh;
            PERFORM pg_temp.chk('E12b with a second bus on the route, the first can be switched off', v_bool = FALSE, format('is_active=%s', v_bool));

            -- Seats now come from the remaining active bus only.
            PERFORM pg_temp.chk_eq('E12c seats follow the active buses', core.fn_transport_route_seats(v_r1), 40);

            BEGIN
                c := 'e12d';
                CALL core.sp_transport_vehicle_manage('DeleteVehicle', c_tenant, c_school, c_user, v_veh2, NULL, NULL, NULL, NULL, NULL, NULL, c);
                PERFORM pg_temp.chk('E12d deleting the last active bus of a ridden route is refused', FALSE, 'deleted');
            EXCEPTION WHEN OTHERS THEN
                PERFORM pg_temp.chk('E12d deleting the last active bus of a ridden route is refused', TRUE, SQLERRM);
            END;
        END;

        -- E13: the switched-off bus can be deleted, and leaves the list.
        c := 'e13';
        CALL core.sp_transport_vehicle_manage('DeleteVehicle', c_tenant, c_school, c_user, v_veh, NULL, NULL, NULL, NULL, NULL, NULL, c);
        c := 'e13b';
        CALL core.sp_transport_vehicle_manage('GetVehicles', c_tenant, c_school, c_user, NULL, NULL, NULL, NULL, NULL, NULL, NULL, c);
        v_n := 0; LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.vehicle_id = v_veh THEN v_n := v_n + 1; END IF; END LOOP; CLOSE c;
        PERFORM pg_temp.chk_eq('E13 a deleted vehicle leaves the list', v_n, 0);

        -- E14-E18: scope on every id the transport pages send.
        c := 'e14';
        CALL core.sp_transport_route_manage('GetStops', 23, 33, c_user, v_r1, NULL, NULL, NULL, c);
        v_n := 0; LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_n := v_n + 1; END LOOP; CLOSE c;
        PERFORM pg_temp.chk_eq('E14 another school cannot list our stops', v_n, 0);

        -- E15a: the Assign page's "Currently assigned" panel (GetForStudent).
        BEGIN
            c := 'e15a';
            CALL core.sp_transport_assign_manage('GetForStudent', c_tenant, c_school, c_user, s1, NULL, NULL, NULL, NULL, 12, c);
            FETCH c INTO r; CLOSE c;
            PERFORM pg_temp.chk('TRN-GETASSIGN Assign page can read the current bus',
                                r.stop_id = v_sc, format('route %s / stop %s', r.route_name, r.stop_name));
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('TRN-GETASSIGN Assign page can read the current bus', FALSE, SQLERRM);
        END;

        c := 'e15';
        CALL core.sp_transport_assign_manage('GetForStudent', 23, 33, c_user, s1, NULL, NULL, NULL, NULL, 12, c);
        v_n := 0; LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_n := v_n + 1; END LOOP; CLOSE c;
        PERFORM pg_temp.chk_eq('E15 another school cannot read our student''s bus', v_n, 0);

        BEGIN
            c := 'e16';
            CALL core.sp_transport_route_manage('SaveRoute', 23, 33, c_user, v_r2, 'ZZ Hijacked', NULL, '[]'::jsonb, c);
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        SELECT route_name INTO v_txt FROM core.transport_routes WHERE route_id = v_r2;
        PERFORM pg_temp.chk('E16 another school cannot rename our route', v_txt = 'ZZ Route South', v_txt);

        c := 'e17';
        v_bool := NULL;
        BEGIN
            CALL core.sp_transport_route_manage('DeleteRoute', 23, 33, c_user, v_r2, NULL, NULL, NULL, c);
            FETCH c INTO r; CLOSE c;
            v_bool := r.success;
        EXCEPTION WHEN OTHERS THEN v_bool := FALSE;
        END;
        SELECT is_deleted INTO v_acc FROM core.transport_routes WHERE route_id = v_r2;
        PERFORM pg_temp.chk('E17 another school cannot delete our route', v_acc = FALSE, format('is_deleted=%s', v_acc));
        PERFORM pg_temp.chk('TRN-SCOPE-MSG ...and is not told "Route deleted."', v_bool IS DISTINCT FROM TRUE,
                            CASE WHEN v_bool THEN 'proc answered success=TRUE for a no-op' ELSE 'refused' END);

        -- E19: delete a route children still ride.
        BEGIN
            c := 'e19';
            CALL core.sp_transport_route_manage('DeleteRoute', c_tenant, c_school, c_user, v_r1, NULL, NULL, NULL, c);
            PERFORM pg_temp.chk('TRN-DEL-ROUTE a route with riders cannot be deleted', FALSE, 'deleted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('TRN-DEL-ROUTE a route with riders cannot be deleted', TRUE, SQLERRM);
        END;
        SELECT is_deleted INTO v_acc FROM core.transport_routes WHERE route_id = v_r1;
        PERFORM pg_temp.chk('E19b ...and it is still there', v_acc = FALSE, format('is_deleted=%s', v_acc));

        -- E20: a route nobody rides is soft-deleted: the row (history) stays.
        c := 'e20';
        CALL core.sp_transport_route_manage('DeleteRoute', c_tenant, c_school, c_user, v_r2, NULL, NULL, NULL, c);
        SELECT is_deleted INTO v_acc FROM core.transport_routes WHERE route_id = v_r2;
        PERFORM pg_temp.chk('E20 a route with no riders is soft-deleted (row kept)', v_acc, format('is_deleted=%s', v_acc));
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- F. Transfer Certificate (document side) ---------------';

    DECLARE
        t1 integer; t2 integer; t3 integer; t4 integer; t5 integer; t6 integer;
        v_tc1 integer; v_no1 text; v_tc2 integer; v_no2 text; v_tc3 integer; v_no3 text;
    BEGIN
        t1 := pg_temp.admit('ZZ-STD-31', 'ZZ TC Board',    '7', 'A', '31', DATE '2013-04-12', '9000000311');
        t2 := pg_temp.admit('ZZ-STD-32', 'ZZ TC Second',   '7', 'A', '32', DATE '2013-04-13', '9000000312');
        t3 := pg_temp.admit('ZZ-STD-33', 'ZZ TC Days',     '7', 'A', '33', DATE '2013-04-14', '9000000313');
        t4 := pg_temp.admit('ZZ-STD-34', 'ZZ TC Negative', '7', 'A', '34', DATE '2013-04-15', '9000000314');
        t5 := pg_temp.admit('ZZ-STD-35', 'ZZ TC AppDate',  '7', 'A', '35', DATE '2013-04-16', '9000000315');
        t6 := pg_temp.admit('ZZ-STD-36', 'ZZ TC Withdrawn','7', 'A', '36', DATE '2013-04-17', '9000000316');

        c := 'fx1'; CALL core.sp_student_exit('Exit', c_tenant, c_school, c_user, t1, 'Transfer', CURRENT_DATE, 'Father transferred', c);
        c := 'fx2'; CALL core.sp_student_exit('Exit', c_tenant, c_school, c_user, t2, 'Transfer', CURRENT_DATE, 'Relocating', c);
        c := 'fx3'; CALL core.sp_student_exit('Exit', c_tenant, c_school, c_user, t3, 'Transfer', CURRENT_DATE, 'Relocating', c);
        c := 'fx4'; CALL core.sp_student_exit('Exit', c_tenant, c_school, c_user, t4, 'Transfer', CURRENT_DATE, 'Relocating', c);
        c := 'fx5'; CALL core.sp_student_exit('Exit', c_tenant, c_school, c_user, t5, 'Transfer', CURRENT_DATE, 'Relocating', c);
        c := 'fx6'; CALL core.sp_student_exit('Exit', c_tenant, c_school, c_user, t6, 'Withdrawn', CURRENT_DATE, 'Parents withdrew', c);

        -- F1: Board format with every Board field.
        c := 'f1';
        CALL core.sp_tc_manage('Issue', c_tenant, c_school, c_user, NULL, t1,
             'Board', 'Good', 'Qualified for Class 8', NULL, 'No dues',
             p_exam_result => 'Annual 2026 - Passed', p_failed_status => 'No',
             p_subjects => 'English, Hindi, Maths', p_fees_paid_upto => 'October 2026',
             p_working_days => 120, p_days_present => 110, p_activities => 'Football',
             p_application_date => CURRENT_DATE - 2, p_result_cur => c);
        FETCH c INTO r; CLOSE c;
        v_tc1 := r.tc_id; v_no1 := r.tc_no;
        PERFORM pg_temp.chk('TC-ISSUE-PRINT issue returns the uuid that Tc/Print opens',
                            r.public_id IS NOT NULL AND r.public_id = (SELECT public_id FROM core.tc_register WHERE tc_id = v_tc1),
                            COALESCE(r.public_id::text, 'NULL'));
        SELECT format || '|' || COALESCE(subjects_studied, '') || '|' || COALESCE(working_days::text, '') || '|' ||
               COALESCE(days_present::text, '') || '|' || COALESCE(reason_for_leaving, '')
          INTO v_txt FROM core.tc_register WHERE tc_id = v_tc1;
        PERFORM pg_temp.chk('F1 Board TC keeps format and Board fields',
                            v_txt = 'Board|English, Hindi, Maths|120|110|Father transferred', v_txt);
        PERFORM pg_temp.chk('F2 number is TC-<year>-<4 digits>', v_no1 ~ '^TC-[0-9]{4}-[0-9]{4}$', v_no1);

        -- F3: the next certificate takes the next number.
        c := 'f3';
        CALL core.sp_tc_manage('Issue', c_tenant, c_school, c_user, NULL, t2,
             'Basic', 'Good', 'Pass', NULL, NULL, p_result_cur => c);
        FETCH c INTO r; CLOSE c;
        v_tc2 := r.tc_id; v_no2 := r.tc_no;
        PERFORM pg_temp.chk('F3 numbers run on without a gap',
                            right(v_no2, 4)::int = right(v_no1, 4)::int + 1, v_no1 || ' -> ' || v_no2);

        -- F4: a blank-looking reason is no reason.
        BEGIN
            c := 'f4';
            CALL core.sp_tc_manage('Void', c_tenant, c_school, c_user, v_tc1, NULL, p_reason => '    ', p_result_cur => c);
            PERFORM pg_temp.chk('F4 void with a whitespace reason refused', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('F4 void with a whitespace reason refused', TRUE, SQLERRM);
        END;

        -- F5: void, with who / why / when.
        c := 'f5';
        CALL core.sp_tc_manage('Void', c_tenant, c_school, c_user, v_tc1, NULL,
             p_reason => 'Wrong date of leaving', p_result_cur => c);
        SELECT (void_reason = 'Wrong date of leaving' AND voided_by = c_user AND voided_at IS NOT NULL)
          INTO v_bool FROM core.tc_register WHERE tc_id = v_tc1;
        PERFORM pg_temp.chk('F5 void records why, who and when', v_bool, '');

        -- F6: a voided certificate must not print as a clean certificate. The
        --     Register hides the button, but the Print URL (Tc/Print?id=<uuid>)
        --     still serves it, and Tc/Print.cshtml has no VOID stamp.
        v_acc := FALSE;
        BEGIN
            c := 'f6';
            CALL core.sp_tc_manage('Print', c_tenant, c_school, c_user, v_tc1, NULL, p_result_cur => c);
            FETCH c INTO r; CLOSE c;
            v_acc := r.tc_id IS NOT NULL;
            RAISE EXCEPTION '__undo__';
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('TC-VOID-PRINT a voided TC is not served for print', NOT v_acc,
                                CASE WHEN v_acc THEN 'served as a printable certificate' ELSE SQLERRM END);
        END;

        -- F7: re-issue after void takes a fresh number; the voided one is retired.
        c := 'f7';
        CALL core.sp_tc_manage('Issue', c_tenant, c_school, c_user, NULL, t1,
             'Board', 'Good', 'Qualified for Class 8', NULL, NULL, p_result_cur => c);
        FETCH c INTO r; CLOSE c;
        v_tc3 := r.tc_id; v_no3 := r.tc_no;
        PERFORM pg_temp.chk('F7 re-issue takes a new number, never the voided one',
                            v_no3 NOT IN (v_no1, v_no2) AND right(v_no3, 4)::int = right(v_no2, 4)::int + 1,
                            v_no1 || ' (void) -> ' || v_no3);

        -- F8: days present cannot exceed working days.
        v_acc := FALSE;
        BEGIN
            c := 'f8';
            CALL core.sp_tc_manage('Issue', c_tenant, c_school, c_user, NULL, t3,
                 'Board', 'Good', 'Pass', NULL, NULL,
                 p_working_days => 200, p_days_present => 250, p_result_cur => c);
            v_acc := TRUE;
            RAISE EXCEPTION '__undo__';
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('TC-DAYS days present > working days refused', NOT v_acc,
                                CASE WHEN v_acc THEN 'issued with 250 of 200 days (undone)' ELSE SQLERRM END);
        END;

        v_acc := FALSE;
        BEGIN
            c := 'f9';
            CALL core.sp_tc_manage('Issue', c_tenant, c_school, c_user, NULL, t4,
                 'Board', 'Good', 'Pass', NULL, NULL,
                 p_working_days => -5, p_days_present => -1, p_result_cur => c);
            v_acc := TRUE;
            RAISE EXCEPTION '__undo__';
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('TC-DAYS-NEG negative working / present days refused', NOT v_acc,
                                CASE WHEN v_acc THEN 'issued with -5 working days (undone)' ELSE SQLERRM END);
        END;

        -- F10: the parent cannot have applied after the certificate was issued.
        v_acc := FALSE;
        BEGIN
            c := 'f10';
            CALL core.sp_tc_manage('Issue', c_tenant, c_school, c_user, NULL, t5,
                 'Board', 'Good', 'Pass', NULL, NULL,
                 p_application_date => CURRENT_DATE + 20, p_result_cur => c);
            v_acc := TRUE;
            RAISE EXCEPTION '__undo__';
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('TC-APPDATE application date after issue refused', NOT v_acc,
                                CASE WHEN v_acc THEN 'issued with an application date 20 days ahead (undone)' ELSE SQLERRM END);
        END;

        -- F11: a plain withdrawal does not get a TC.
        BEGIN
            c := 'f11';
            CALL core.sp_tc_manage('Issue', c_tenant, c_school, c_user, NULL, t6,
                 'Basic', 'Good', 'Pass', NULL, NULL, p_result_cur => c);
            PERFORM pg_temp.chk('F11 no TC for a "Withdrawn" student', FALSE, 'it was issued');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('F11 no TC for a "Withdrawn" student', TRUE, SQLERRM);
        END;

        -- F12: the Register finds a certificate by number and by name.
        c := 'f12';
        CALL core.sp_tc_manage('List', c_tenant, c_school, c_user, p_search => lower(v_no3),
             p_page_no => 1, p_page_size => 50, p_result_cur => c);
        v_n := 0; LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_n := v_n + 1; END LOOP; CLOSE c;
        PERFORM pg_temp.chk_eq('F12 register search by TC no (any case)', v_n, 1);

        c := 'f12b';
        CALL core.sp_tc_manage('List', c_tenant, c_school, c_user, p_search => 'zz tc board',
             p_page_no => 1, p_page_size => 50, p_result_cur => c);
        v_n := 0; v_m := 0;
        LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_n := v_n + 1; IF r.is_void THEN v_m := v_m + 1; END IF; END LOOP; CLOSE c;
        PERFORM pg_temp.chk('F12b by name: the live and the voided TC both listed', v_n = 2 AND v_m = 1,
                            format('%s row(s), %s void', v_n, v_m));

        -- F12c: the Register says why, who and when a number was voided.
        c := 'f12c';
        CALL core.sp_tc_manage('List', c_tenant, c_school, c_user, p_search => v_no1,
             p_page_no => 1, p_page_size => 50, p_result_cur => c);
        FETCH c INTO r; CLOSE c;
        PERFORM pg_temp.chk('TC-VOID-VISIBLE register lists the void reason, who and when',
                            r.void_reason = 'Wrong date of leaving' AND r.voided_by_name IS NOT NULL AND r.voided_at IS NOT NULL,
                            format('%s / %s', r.void_reason, r.voided_by_name));

        -- F12d: "Get" (opening / refreshing the Print page) never counts a print.
        c := 'f12d';
        CALL core.sp_tc_manage('Get', c_tenant, c_school, c_user, v_tc3, NULL, p_result_cur => c);
        FETCH c INTO r; CLOSE c;
        SELECT print_count INTO v_n FROM core.tc_register WHERE tc_id = v_tc3;
        PERFORM pg_temp.chk('TC-GET-PRINT opening the certificate does not use up the original',
                            v_n = 0 AND r.was_duplicate = FALSE, format('print_count=%s', v_n));

        -- F12e: the Inactive list knows a live TC exists, and links the leaver's
        --       read-only dashboard; the leaver's record still opens.
        c := 'f12e';
        CALL core.sp_student_exit_list(c_tenant, c_school, c_user, 'ZZ-STD-32', NULL, NULL, 1, 10, NULL, 'desc', c);
        FETCH c INTO r; CLOSE c;
        PERFORM pg_temp.chk('F12e Inactive list flags the live TC and carries the uuid',
                            r.has_tc AND r.public_id IS NOT NULL, format('has_tc=%s', r.has_tc));

        c := 'f12f';
        CALL core.sp_admission_manage('GetStudentById', c_tenant, c_school, c_user, t2, p_result => c);
        FETCH c INTO r; CLOSE c;
        PERFORM pg_temp.chk('STU-LEFT-VIEW a left student''s record still opens (read-only)',
                            r.student_id = t2 AND r.is_active = FALSE, format('status=%s', r.status));

        -- F13-F15: scope.
        c := 'f13';
        CALL core.sp_tc_manage('List', 23, 33, c_user, p_search => 'ZZ TC', p_page_no => 1, p_page_size => 50, p_result_cur => c);
        v_n := 0; LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_n := v_n + 1; END LOOP; CLOSE c;
        PERFORM pg_temp.chk_eq('F13 another school''s register shows none of ours', v_n, 0);

        BEGIN
            c := 'f14';
            CALL core.sp_tc_manage('Print', 23, 33, c_user, v_tc3, NULL, p_result_cur => c);
            PERFORM pg_temp.chk('F14 another school cannot print our TC', FALSE, 'it was served');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('F14 another school cannot print our TC', TRUE, SQLERRM);
        END;
        SELECT print_count INTO v_n FROM core.tc_register WHERE tc_id = v_tc3;
        PERFORM pg_temp.chk_eq('F14b ...and did not use up its "original" print', v_n, 0);

        BEGIN
            c := 'f15';
            CALL core.sp_tc_manage('Void', 23, 33, c_user, v_tc3, NULL, p_reason => 'hostile', p_result_cur => c);
            PERFORM pg_temp.chk('F15 another school cannot void our TC', FALSE, 'it was voided');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('F15 another school cannot void our TC', TRUE, SQLERRM);
        END;
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- G. ID cards (class 7-A, one photo missing) ------------';

    DECLARE
        g1 integer; g2 integer; g3 integer;
    BEGIN
        -- Rolls 10, 2 and 1 entered out of order; only roll 2 has a photo.
        g1 := pg_temp.admit('ZZ-STD-41', 'ZZ Card Ten', '7', 'A', '10', DATE '2013-05-10', '9000000410');
        g2 := pg_temp.admit('ZZ-STD-42', 'ZZ Card Two', '7', 'A', '2',  DATE '2013-05-02', '9000000402');
        g3 := pg_temp.admit('ZZ-STD-43', 'ZZ Card One', '7', 'A', '1',  DATE '2013-05-01', '9000000401');
        c := 'g0';
        CALL core.sp_student_set_photo(c_tenant, c_school, c_user, g2, '/uploads/students/24/34/card_two.jpg', c);

        c := 'g1';
        CALL core.sp_id_card_students(c_tenant, c_school, c_user, '7', 'A', v_year, NULL, c);
        v_txt := ''; v_n := 0; v_m := 0;
        LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
            IF r.admission_no LIKE 'ZZ-STD-4%' THEN
                v_txt := v_txt || r.roll_no || ',';
                v_n := v_n + 1;
                IF r.photo_url IS NULL THEN v_m := v_m + 1; END IF;
            END IF;
            IF r.admission_no LIKE 'ZZ-STD-3%' THEN v_n := v_n + 100; END IF;   -- left students must not appear
        END LOOP; CLOSE c;
        PERFORM pg_temp.chk('G1 7-A sheet: our 3 cards, no leavers', v_n = 3, format('%s', v_n));
        PERFORM pg_temp.chk('G2 cards run in numeric roll order (1, 2, 10)', v_txt = '1,2,10,', v_txt);
        PERFORM pg_temp.chk_eq('G3 two cards come back without a photo (placeholder)', v_m, 2);

        c := 'g4';
        CALL core.sp_id_card_students(c_tenant, c_school, c_user, '7', 'a', NULL, NULL, c);
        v_n := 0; LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.admission_no LIKE 'ZZ-STD-4%' THEN v_n := v_n + 1; END IF; END LOOP; CLOSE c;
        PERFORM pg_temp.chk_eq('G4 section "a" matches A', v_n, 3);

        c := 'g5';
        CALL core.sp_id_card_students(c_tenant, c_school, c_user, '7', 'A', 'ZZ NO SUCH YEAR', NULL, c);
        v_n := 0; LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_n := v_n + 1; END LOOP; CLOSE c;
        PERFORM pg_temp.chk_eq('G5 an unknown year gives an empty sheet', v_n, 0);

        c := 'g6';
        CALL core.sp_id_card_sections(c_tenant, c_school, c_user, '7', v_year, c);
        v_txt := ''; LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_txt := v_txt || r.section || ','; END LOOP; CLOSE c;
        PERFORM pg_temp.chk('G6 sections for class 7', v_txt = 'A,', v_txt);

        c := 'g7';
        CALL core.sp_id_card_students(c_tenant, c_school, c_user, NULL, NULL, NULL, g2, c);
        FETCH c INTO r; CLOSE c;
        PERFORM pg_temp.chk('G7 one student''s card carries the photo', r.photo_url LIKE '%card_two.jpg', r.photo_url);

        c := 'g8';
        CALL core.sp_id_card_students(23, 33, c_user, NULL, NULL, NULL, g2, c);
        v_n := 0; LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_n := v_n + 1; END LOOP; CLOSE c;
        PERFORM pg_temp.chk_eq('G8 another school cannot print our student''s card', v_n, 0);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- H. Scope and leaks ------------------------------------';

    SELECT COUNT(*) INTO v_n FROM core.students
     WHERE admission_no LIKE 'ZZ-STD-%' AND (tenant_id <> c_tenant OR school_id <> c_school);
    PERFORM pg_temp.chk_eq('H1 no test student landed in another school', v_n, 0);

    SELECT COUNT(*) INTO v_n FROM core.student_ledger l
      JOIN core.students s ON s.student_id = l.student_id
     WHERE s.admission_no LIKE 'ZZ-STD-%' AND (l.tenant_id <> c_tenant OR l.school_id <> c_school);
    PERFORM pg_temp.chk_eq('H2 no ledger row for them under another school', v_n, 0);

    SELECT COUNT(*) INTO v_n FROM core.transport_routes
     WHERE route_name LIKE 'ZZ Route%' AND (tenant_id <> c_tenant OR school_id <> c_school);
    PERFORM pg_temp.chk_eq('H3 no test route in another school', v_n, 0);

    SELECT COUNT(*) INTO v_n FROM core.tc_register t
      JOIN core.students s ON s.student_id = t.student_id
     WHERE s.admission_no LIKE 'ZZ-STD-%' AND (t.tenant_id <> c_tenant OR t.school_id <> c_school);
    PERFORM pg_temp.chk_eq('H4 no test TC in another school''s register', v_n, 0);

    SELECT COUNT(*) INTO v_n FROM core.student_enrolment e
      JOIN core.students s ON s.student_id = e.student_id
     WHERE s.admission_no LIKE 'ZZ-STD-%' AND (e.tenant_id <> c_tenant OR e.school_id <> c_school);
    PERFORM pg_temp.chk_eq('H5 no test enrolment row in another school', v_n, 0);
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
