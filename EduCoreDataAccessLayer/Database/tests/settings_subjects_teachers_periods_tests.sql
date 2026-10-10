-- ============================================================================
-- Subjects, Class Teachers and Period Structure test suite.
--
-- Three settings pages that the rest of the school day hangs off:
--   * Subject Management   -> what each class studies (timetable dropdown, exams)
--   * Assign Class Teacher -> who owns a section (and may mark its attendance)
--   * Period Structure     -> the bell schedule (timetable grid, Smart Bell)
--
-- Scenario: the school maps Class 7's subjects (English, Hindi, Mathematics,
-- Science, Social Science, optional Sanskrit), makes Vinod class teacher of 1-A
-- and then 1-B too, and sets an 8-period day with a short break, lunch and diary
-- time - then adds a morning assembly after the timetable is already filled.
--
-- Runs inside ONE transaction and ROLLS BACK.
--
--     psql ... -f settings_subjects_teachers_periods_tests.sql
--
-- COVERS
--   A. Subject Management - save, read-back, master reuse, replace-all, session
--   B. Assign Class Teacher - pool, assign, clear, load, attendance gate
--   C. Period Structure - save, validations, overlaps, edit, delete, atomicity
--   D. Downstream - timetable after period edits / subject removal / class rebuild
--   E. Scope and cross-school isolation
--
-- A check whose name starts with "BUG" documents app behaviour that is wrong
-- today; it fails until the app is fixed. Do not weaken it.
-- ============================================================================

\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE TEMP TABLE _t(id serial, name text, ok boolean, detail text) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.chk(p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO _t(name, ok, detail) VALUES (p_name, COALESCE(p_ok, FALSE), p_detail);
    RAISE NOTICE '  [%] %  %', CASE WHEN COALESCE(p_ok, FALSE) THEN 'PASS' ELSE 'FAIL' END, rpad(p_name, 60), p_detail;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.chk_eq(p_name text, p_got numeric, p_want numeric)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.chk(p_name, p_got IS NOT DISTINCT FROM p_want,
                        format('got %s, expected %s', COALESCE(p_got::text,'NULL'), p_want));
END $$;

CREATE OR REPLACE FUNCTION pg_temp.chk_txt(p_name text, p_got text, p_want text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.chk(p_name, p_got IS NOT DISTINCT FROM p_want,
                        format('got [%s], expected [%s]', COALESCE(p_got,'NULL'), COALESCE(p_want,'NULL')));
END $$;

-- A fresh cursor name per call, so helpers never collide on an open portal.
CREATE OR REPLACE FUNCTION pg_temp.cur() RETURNS refcursor LANGUAGE sql AS
$$ SELECT ('k' || replace(gen_random_uuid()::text, '-', ''))::refcursor $$;

-- ── Subject proc wrappers (same positional layout as SubjectService) ──
CREATE OR REPLACE FUNCTION pg_temp.subj_get(p_t int, p_s int, p_year int, p_class int)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c refcursor := pg_temp.cur(); c2 refcursor := pg_temp.cur(); r record; v text := '';
BEGIN
    CALL academic.sp_school_admin_subject_manage('GetClassSubjects', p_t, p_s, 39, p_year, p_class, NULL, c, c2);
    LOOP
        FETCH c INTO r; EXIT WHEN NOT FOUND;
        v := v || CASE WHEN v = '' THEN '' ELSE ',' END || r.subject_name;
    END LOOP;
    CLOSE c; CLOSE c2;
    RETURN v;
END $$;

-- Returns the subject_count the proc reports. p_year NULL = what the service sends.
CREATE OR REPLACE FUNCTION pg_temp.subj_save(p_t int, p_s int, p_class int, p_items text, p_year int DEFAULT NULL)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE c refcursor := pg_temp.cur(); c2 refcursor := pg_temp.cur(); r record;
BEGIN
    CALL academic.sp_school_admin_subject_manage('SaveClassSubjects', p_t, p_s, 39, p_year, p_class, p_items, c, c2);
    FETCH c INTO r; CLOSE c; CLOSE c2;
    RETURN r.subject_count;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.subj_master(p_t int, p_s int)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c refcursor := pg_temp.cur(); c2 refcursor := pg_temp.cur(); r record; v text := '';
BEGIN
    CALL academic.sp_school_admin_subject_manage('GetSubjectMaster', p_t, p_s, 39, NULL, NULL, NULL, c, c2);
    LOOP
        FETCH c INTO r; EXIT WHEN NOT FOUND;
        v := v || '|' || r.subject_name;
    END LOOP;
    CLOSE c; CLOSE c2;
    RETURN v || '|';
END $$;

-- ── Class teacher proc wrappers (10-arg session-aware overload) ──
CREATE OR REPLACE FUNCTION pg_temp.ct_assign(p_t int, p_s int, p_sec int, p_staff int)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c refcursor := pg_temp.cur(); r record;
BEGIN
    CALL core.sp_class_teacher_manage('Assign'::varchar, p_t, p_s, 39, NULL::int, p_sec, p_staff, NULL::varchar, NULL::varchar, c);
    FETCH c INTO r; CLOSE c;
    RETURN r.message;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.ct_is(p_t int, p_s int, p_user int, p_cls text, p_sec text)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE c refcursor := pg_temp.cur(); r record;
BEGIN
    CALL core.sp_class_teacher_manage('IsTeacher'::varchar, p_t, p_s, p_user, NULL::int, NULL::int, NULL::int, p_cls::varchar, p_sec::varchar, c);
    FETCH c INTO r; CLOSE c;
    RETURN r.is_teacher;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.ct_grid(p_t int, p_s int, p_year int)
RETURNS TABLE(o_sec int, o_teacher int, o_name text, o_load int) LANGUAGE plpgsql AS $$
DECLARE c refcursor := pg_temp.cur(); r record;
BEGIN
    CALL core.sp_class_teacher_manage('Grid'::varchar, p_t, p_s, 39, p_year, NULL::int, NULL::int, NULL::varchar, NULL::varchar, c);
    LOOP
        FETCH c INTO r; EXIT WHEN NOT FOUND;
        o_sec := r.section_id; o_teacher := r.teacher_id; o_name := r.teacher_name; o_load := r.teacher_load;
        RETURN NEXT;
    END LOOP;
    CLOSE c;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.ct_pool(p_t int, p_s int)
RETURNS TABLE(o_staff int, o_name text) LANGUAGE plpgsql AS $$
DECLARE c refcursor := pg_temp.cur(); r record;
BEGIN
    CALL core.sp_class_teacher_manage('Teachers'::varchar, p_t, p_s, 39, NULL::int, NULL::int, NULL::int, NULL::varchar, NULL::varchar, c);
    LOOP
        FETCH c INTO r; EXIT WHEN NOT FOUND;
        o_staff := r.staff_id; o_name := r.full_name;
        RETURN NEXT;
    END LOOP;
    CLOSE c;
END $$;

-- ── Period structure wrappers ──
CREATE OR REPLACE FUNCTION pg_temp.ps_save(p_t int, p_s int, p_items text)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c refcursor := pg_temp.cur(); r record;
BEGIN
    CALL academic.sp_school_admin_period_structure_manage('SavePeriodStructure', p_t, p_s, 39, p_items, c);
    FETCH c INTO r; CLOSE c;
    RETURN r.message;
END $$;

-- "seq:label@start-end/type;..." in the order the proc returns them.
CREATE OR REPLACE FUNCTION pg_temp.ps_get(p_t int, p_s int)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c refcursor := pg_temp.cur(); r record; v text := '';
BEGIN
    CALL academic.sp_school_admin_period_structure_manage('GetPeriodStructure', p_t, p_s, 39, NULL, c);
    LOOP
        FETCH c INTO r; EXIT WHEN NOT FOUND;
        v := v || r.seq || ':' || r.label || '@' || r.start_time || '-' || r.end_time || '/' || r.period_type || ';';
    END LOOP;
    CLOSE c;
    RETURN v;
END $$;

-- ── Timetable wrappers (downstream consumer) ──
CREATE OR REPLACE FUNCTION pg_temp.tt_save(p_t int, p_s int, p_sec int, p_day int, p_seq int, p_subject int, p_staff int)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := pg_temp.cur(); c2 refcursor := pg_temp.cur();
        c3 refcursor := pg_temp.cur(); c4 refcursor := pg_temp.cur(); r record;
BEGIN
    CALL academic.sp_school_admin_timetable_manage('SaveCell', p_t, p_s, 39, NULL::int, p_sec,
         p_day::smallint, p_seq::smallint, p_subject, p_staff, NULL::varchar, c1, c2, c3, c4);
    FETCH c1 INTO r; CLOSE c1; CLOSE c2; CLOSE c3; CLOSE c4;
    RETURN r.message;
END $$;

-- result 3 of GetGrid = the subject dropdown the timetable modal offers.
CREATE OR REPLACE FUNCTION pg_temp.tt_grid_subjects(p_t int, p_s int, p_sec int)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c1 refcursor := pg_temp.cur(); c2 refcursor := pg_temp.cur();
        c3 refcursor := pg_temp.cur(); c4 refcursor := pg_temp.cur(); r record; v text := '';
BEGIN
    CALL academic.sp_school_admin_timetable_manage('GetGrid', p_t, p_s, 39, NULL::int, p_sec,
         NULL::smallint, NULL::smallint, NULL::int, NULL::int, NULL::varchar, c1, c2, c3, c4);
    LOOP
        FETCH c3 INTO r; EXIT WHEN NOT FOUND;
        v := v || CASE WHEN v = '' THEN '' ELSE ',' END || r.subject_name;
    END LOOP;
    CLOSE c1; CLOSE c2; CLOSE c3; CLOSE c4;
    RETURN v;
END $$;


DO $suite$
DECLARE
    c_tenant CONSTANT integer := 24;
    c_school CONSTANT integer := 34;
    c_user   CONSTANT integer := 39;
    -- The other real school used for isolation checks.
    o_tenant CONSTANT integer := 23;
    o_school CONSTANT integer := 33;

    v_year     integer;
    v_yearname varchar;
    v_cls7     integer;   -- Class "7"  (no subjects yet)
    v_cls6     integer;   -- Class "6"  (already has subjects)
    v_sec7a    integer;   -- 7-A
    v_sec8a    integer;   -- 8-A
    v_sec1a    integer;   -- 1-A
    v_sec1b    integer;   -- 1-B
    v_staff_t1 integer;   -- active teaching staff with a login
    v_user_t1  integer;
    v_staff_t2 integer;   -- second active teaching staff with a login
    v_user_t2  integer;
    v_staff_nt integer;   -- active NON-teaching staff
    v_staff_in integer;   -- inactive staff
    v_staff_ot integer;   -- staff of the other school
    v_sec_ot   integer;   -- section of the other school
    v_cls_ot   integer;   -- class of the other school
    v_year_ot  integer;   -- a session of the other school
    v_sec_del  integer;   -- a soft-deleted section of our school
    v_cls_del  integer;   -- a soft-deleted class of our school

    c     refcursor;
    v_n   integer;
    v_m   integer;
    v_txt text;
    v_b   boolean;
    v_id  integer;
    v_sid integer;
    v_items text;
    v_ot_before text;
    v_ot_sched  text;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '===== SUBJECTS / CLASS TEACHERS / PERIOD STRUCTURE TESTS =====';

    SELECT academic_year_id, academic_year_name INTO v_year, v_yearname
    FROM academic.academic_years
    WHERE tenant_id = c_tenant AND school_id = c_school AND COALESCE(is_current, FALSE)
      AND NOT is_deleted LIMIT 1;

    SELECT academic_class_id INTO v_cls7 FROM academic.academic_classes
     WHERE tenant_id = c_tenant AND school_id = c_school AND academic_year_id = v_year
       AND class_name = '7' AND NOT is_deleted;
    SELECT academic_class_id INTO v_cls6 FROM academic.academic_classes
     WHERE tenant_id = c_tenant AND school_id = c_school AND academic_year_id = v_year
       AND class_name = '6' AND NOT is_deleted;

    SELECT s.academic_class_section_id INTO v_sec7a FROM academic.academic_class_sections s
      JOIN academic.academic_classes c2 ON c2.academic_class_id = s.academic_class_id
     WHERE s.tenant_id = c_tenant AND s.school_id = c_school AND s.academic_year_id = v_year
       AND c2.class_name = '7' AND s.section_name = 'A' AND NOT s.is_deleted;
    SELECT s.academic_class_section_id INTO v_sec8a FROM academic.academic_class_sections s
      JOIN academic.academic_classes c2 ON c2.academic_class_id = s.academic_class_id
     WHERE s.tenant_id = c_tenant AND s.school_id = c_school AND s.academic_year_id = v_year
       AND c2.class_name = '8' AND s.section_name = 'A' AND NOT s.is_deleted;
    SELECT s.academic_class_section_id INTO v_sec1a FROM academic.academic_class_sections s
      JOIN academic.academic_classes c2 ON c2.academic_class_id = s.academic_class_id
     WHERE s.tenant_id = c_tenant AND s.school_id = c_school AND s.academic_year_id = v_year
       AND c2.class_name = '1' AND s.section_name = 'A' AND NOT s.is_deleted;
    SELECT s.academic_class_section_id INTO v_sec1b FROM academic.academic_class_sections s
      JOIN academic.academic_classes c2 ON c2.academic_class_id = s.academic_class_id
     WHERE s.tenant_id = c_tenant AND s.school_id = c_school AND s.academic_year_id = v_year
       AND c2.class_name = '1' AND s.section_name = 'B' AND NOT s.is_deleted;

    SELECT staff_id, user_id INTO v_staff_t1, v_user_t1 FROM core.staff
     WHERE tenant_id = c_tenant AND school_id = c_school AND staff_type = 'Teaching'
       AND is_active AND NOT is_deleted AND user_id IS NOT NULL ORDER BY staff_id LIMIT 1;
    SELECT staff_id, user_id INTO v_staff_t2, v_user_t2 FROM core.staff
     WHERE tenant_id = c_tenant AND school_id = c_school AND staff_type = 'Teaching'
       AND is_active AND NOT is_deleted AND user_id IS NOT NULL AND staff_id <> v_staff_t1
     ORDER BY staff_id LIMIT 1;
    SELECT staff_id INTO v_staff_nt FROM core.staff
     WHERE tenant_id = c_tenant AND school_id = c_school AND staff_type <> 'Teaching'
       AND is_active AND NOT is_deleted ORDER BY staff_id LIMIT 1;
    SELECT staff_id INTO v_staff_in FROM core.staff
     WHERE tenant_id = c_tenant AND school_id = c_school AND NOT is_active AND NOT is_deleted
     ORDER BY staff_id LIMIT 1;

    SELECT staff_id INTO v_staff_ot FROM core.staff
     WHERE tenant_id = o_tenant AND school_id = o_school AND NOT is_deleted LIMIT 1;
    SELECT academic_class_section_id, academic_class_id, academic_year_id INTO v_sec_ot, v_cls_ot, v_year_ot
      FROM academic.academic_class_sections
     WHERE tenant_id = o_tenant AND school_id = o_school AND NOT is_deleted LIMIT 1;

    SELECT academic_class_section_id INTO v_sec_del FROM academic.academic_class_sections
     WHERE tenant_id = c_tenant AND school_id = c_school AND is_deleted LIMIT 1;
    SELECT academic_class_id INTO v_cls_del FROM academic.academic_classes
     WHERE tenant_id = c_tenant AND school_id = c_school AND is_deleted LIMIT 1;

    IF v_year IS NULL OR v_cls7 IS NULL OR v_cls6 IS NULL OR v_sec7a IS NULL OR v_sec8a IS NULL
       OR v_sec1a IS NULL OR v_sec1b IS NULL OR v_staff_t1 IS NULL OR v_staff_t2 IS NULL
       OR v_staff_nt IS NULL OR v_staff_in IS NULL OR v_staff_ot IS NULL OR v_sec_ot IS NULL THEN
        RAISE EXCEPTION 'Fixture missing for school % (year=% cls7=% sec7a=% t1=% t2=% nt=% in=% ot=%)',
            c_school, v_year, v_cls7, v_sec7a, v_staff_t1, v_staff_t2, v_staff_nt, v_staff_in, v_staff_ot;
    END IF;
    RAISE NOTICE 'fixture: session=% cls7=% 7-A=% 1-A=% 1-B=% teacher1=% teacher2=% nonteach=% inactive=% other-school staff=% section=%',
        v_yearname, v_cls7, v_sec7a, v_sec1a, v_sec1b, v_staff_t1, v_staff_t2, v_staff_nt, v_staff_in, v_staff_ot, v_sec_ot;

    v_ot_sched := pg_temp.ps_get(o_tenant, o_school);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- A. Subject Management ------------------------------------';

    -- A1: the left panel lists the session's classes with their counts.
    DECLARE c2 refcursor; r record; v_cnt7 integer; v_cnt6 integer;
    BEGIN
        c := pg_temp.cur(); c2 := pg_temp.cur(); v_n := 0;
        CALL academic.sp_school_admin_subject_manage('GetClasses', c_tenant, c_school, c_user, NULL, NULL, NULL, c, c2);
        LOOP
            FETCH c INTO r; EXIT WHEN NOT FOUND;
            v_n := v_n + 1;
            IF r.academic_class_id = v_cls7 THEN v_cnt7 := r.subject_count; END IF;
            IF r.academic_class_id = v_cls6 THEN v_cnt6 := r.subject_count; END IF;
        END LOOP;
        FETCH c2 INTO r;
        CLOSE c; CLOSE c2;
        SELECT COUNT(*) INTO v_m FROM academic.academic_classes
         WHERE tenant_id = c_tenant AND school_id = c_school AND academic_year_id = v_year
           AND NOT is_deleted AND is_active;
        PERFORM pg_temp.chk_eq('SUB-A1 GetClasses lists every active class of the session', v_n, v_m);
        PERFORM pg_temp.chk_eq('SUB-A2 class 7 starts with 0 subjects', v_cnt7, 0);
        PERFORM pg_temp.chk('SUB-A3 class 6 shows its saved subject count', v_cnt6 > 0, format('count=%s', v_cnt6));
        PERFORM pg_temp.chk_eq('SUB-A4 second cursor names the resolved session', r.academic_year_id, v_year);
    END;

    -- A5: Class 7's real-world list, with an optional Sanskrit.
    SELECT COUNT(*) INTO v_m FROM academic.school_subjects WHERE tenant_id = c_tenant AND school_id = c_school;
    v_n := pg_temp.subj_save(c_tenant, c_school, v_cls7,
           jsonb_build_array('English','Hindi','Mathematics','Science','Social Science','Sanskrit')::text);
    PERFORM pg_temp.chk_eq('SUB-A5 save of 6 subjects reports 6', v_n, 6);
    PERFORM pg_temp.chk_txt('SUB-A6 read-back is the same list in the same order',
        pg_temp.subj_get(c_tenant, c_school, NULL, v_cls7),
        'English,Hindi,Mathematics,Science,Social Science,Sanskrit');

    -- English/Hindi/Science/Sanskrit already exist in the master; only
    -- Mathematics and Social Science are new.
    SELECT COUNT(*) INTO v_n FROM academic.school_subjects WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk_eq('SUB-A7 only the 2 unseen names were added to the master', v_n - v_m, 2);

    -- A8: case and padding find the existing master row, not a new one.
    SELECT COUNT(*) INTO v_m FROM academic.school_subjects WHERE tenant_id = c_tenant AND school_id = c_school;
    v_n := pg_temp.subj_save(c_tenant, c_school, v_cls7,
           jsonb_build_array('  english ','HINDI','mathematics','Science','Social Science','Sanskrit')::text);
    SELECT COUNT(*) INTO v_n FROM academic.school_subjects WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk_eq('SUB-A8 "  english " / "HINDI" reuse the master rows', v_n, v_m);
    PERFORM pg_temp.chk_txt('SUB-A9 ...and the stored names keep the master spelling',
        pg_temp.subj_get(c_tenant, c_school, NULL, v_cls7),
        'English,Hindi,Mathematics,Science,Social Science,Sanskrit');

    -- A10: idempotent re-save - no duplicate mapping rows.
    PERFORM pg_temp.subj_save(c_tenant, c_school, v_cls7,
           jsonb_build_array('English','Hindi','Mathematics','Science','Social Science','Sanskrit')::text);
    SELECT COUNT(*) INTO v_n FROM academic.class_subjects
     WHERE tenant_id = c_tenant AND school_id = c_school AND academic_year_id = v_year AND academic_class_id = v_cls7;
    PERFORM pg_temp.chk_eq('SUB-A10 re-saving the same list keeps 6 mapping rows', v_n, 6);

    -- A11: reorder.
    PERFORM pg_temp.subj_save(c_tenant, c_school, v_cls7,
           jsonb_build_array('Mathematics','English','Hindi','Science','Social Science','Sanskrit')::text);
    PERFORM pg_temp.chk_txt('SUB-A11 a new order is stored as display order',
        pg_temp.subj_get(c_tenant, c_school, NULL, v_cls7),
        'Mathematics,English,Hindi,Science,Social Science,Sanskrit');

    -- A12: remove the optional Sanskrit - unmapped from the class, kept in the master.
    PERFORM pg_temp.subj_save(c_tenant, c_school, v_cls7,
           jsonb_build_array('Mathematics','English','Hindi','Science','Social Science')::text);
    PERFORM pg_temp.chk_txt('SUB-A12 removing Sanskrit unmaps it (replace-all)',
        pg_temp.subj_get(c_tenant, c_school, NULL, v_cls7),
        'Mathematics,English,Hindi,Science,Social Science');
    PERFORM pg_temp.chk('SUB-A13 ...Sanskrit stays in the master for other classes',
        position('|Sanskrit|' IN pg_temp.subj_master(c_tenant, c_school)) > 0, '');
    PERFORM pg_temp.chk('SUB-A14 ...and class 6 still has Sanskrit',
        position('Sanskrit' IN pg_temp.subj_get(c_tenant, c_school, NULL, v_cls6)) > 0, '');

    -- A15: blank and whitespace-only entries are skipped, not stored.
    v_n := pg_temp.subj_save(c_tenant, c_school, v_cls7,
           jsonb_build_array('Mathematics', '', '   ', 'English')::text);
    PERFORM pg_temp.chk_txt('SUB-A15 blank / whitespace entries are skipped',
        pg_temp.subj_get(c_tenant, c_school, NULL, v_cls7), 'Mathematics,English');
    PERFORM pg_temp.chk_eq('SUB-A16 ...and the reported count is 2', v_n, 2);

    -- A17: special characters round-trip exactly.
    PERFORM pg_temp.subj_save(c_tenant, c_school, v_cls7,
           jsonb_build_array('Science & Tech (Lab)', 'संस्कृत', 'Children''s Lit', 'Maths/Stats', 'x" onmouseover="alert(1)')::text);
    PERFORM pg_temp.chk_txt('SUB-A17 &, Devanagari, apostrophe, slash, quotes round-trip',
        pg_temp.subj_get(c_tenant, c_school, NULL, v_cls7),
        'Science & Tech (Lab),संस्कृत,Children''s Lit,Maths/Stats,x" onmouseover="alert(1)');

    -- A18: duplicates within one list collapse to one mapping, and the count
    -- shown to the user should match what was stored.
    v_n := pg_temp.subj_save(c_tenant, c_school, v_cls7, jsonb_build_array('Mathematics','mathematics',' MATHEMATICS ')::text);
    SELECT COUNT(*) INTO v_m FROM academic.class_subjects
     WHERE tenant_id = c_tenant AND school_id = c_school AND academic_year_id = v_year AND academic_class_id = v_cls7;
    PERFORM pg_temp.chk_eq('SUB-A18 same name 3 ways = one mapping row', v_m, 1);
    PERFORM pg_temp.chk_eq('BUG SUB-A19 reported subject_count matches rows stored', v_n, v_m);

    -- A20: empty list = clear the class.
    v_n := pg_temp.subj_save(c_tenant, c_school, v_cls7, '[]');
    PERFORM pg_temp.chk_txt('SUB-A20 an empty list clears the class', pg_temp.subj_get(c_tenant, c_school, NULL, v_cls7), '');
    v_n := pg_temp.subj_save(c_tenant, c_school, v_cls7, NULL);
    PERFORM pg_temp.chk_eq('SUB-A21 a NULL list is treated as empty, not an error', v_n, 0);

    -- A22: name longer than the 80-char column is refused.
    BEGIN
        PERFORM pg_temp.subj_save(c_tenant, c_school, v_cls7, jsonb_build_array(repeat('X', 81))::text);
        PERFORM pg_temp.chk('SUB-A22 an 81-char subject name is refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('SUB-A22 an 81-char subject name is refused', TRUE, SQLERRM);
    END;
    v_n := pg_temp.subj_save(c_tenant, c_school, v_cls7, jsonb_build_array(repeat('Y', 80))::text);
    PERFORM pg_temp.chk_eq('SUB-A23 an exactly-80-char name is accepted', v_n, 1);

    -- A24..A26: refusals.
    BEGIN
        PERFORM pg_temp.subj_save(c_tenant, c_school, NULL, '["English"]');
        PERFORM pg_temp.chk('SUB-A24 save without a class refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('SUB-A24 save without a class refused', TRUE, SQLERRM);
    END;
    BEGIN
        PERFORM pg_temp.subj_save(c_tenant, c_school, v_cls_del, '["English"]');
        PERFORM pg_temp.chk('SUB-A25 save to a deleted class refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('SUB-A25 save to a deleted class refused', TRUE, SQLERRM);
    END;
    BEGIN
        PERFORM pg_temp.subj_save(c_tenant, c_school, 999999, '["English"]');
        PERFORM pg_temp.chk('SUB-A26 save to a non-existent class refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('SUB-A26 save to a non-existent class refused', TRUE, SQLERRM);
    END;
    BEGIN
        c := pg_temp.cur();
        DECLARE c2 refcursor := pg_temp.cur();
        BEGIN
            CALL academic.sp_school_admin_subject_manage('Nope', c_tenant, c_school, c_user, NULL, NULL, NULL, c, c2);
            PERFORM pg_temp.chk('SUB-A27 unknown operation refused', FALSE, 'it was accepted');
        END;
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('SUB-A27 unknown operation refused', TRUE, SQLERRM);
    END;

    -- A28: THE SESSION BUG. The page reads subjects for the session in its picker
    -- (?academicYearId=...), but SaveClassSubjects never sends that id, so the proc
    -- falls back to the CURRENT session. Editing next session's class writes the
    -- mapping under this session and the page then reads back nothing.
    DECLARE v_ny integer; v_ncls integer; v_row_year integer;
    BEGIN
        c := pg_temp.cur();
        CALL academic.sp_school_admin_academic_year_manage('SaveAcademicYear',
             c_tenant, c_school, c_user, NULL, 'ZZ Next Session',
             DATE '2040-04-01', DATE '2041-03-31', FALSE, 'AdmissionMonth', c);
        SELECT academic_year_id INTO v_ny FROM academic.academic_years
         WHERE tenant_id = c_tenant AND school_id = c_school AND academic_year_name = 'ZZ Next Session';

        c := pg_temp.cur();
        CALL academic.sp_school_admin_academic_setup_manage('SaveAcademicSetup',
             c_tenant, c_school, c_user, v_ny, 'ZZ Next Session',
             '[{"className":"ZZ VI","sections":[{"sectionName":"A"}]}]', c);
        DROP TABLE IF EXISTS _ct_snap;   -- the setup proc's ON COMMIT temp table; one call per tx in the app
        SELECT academic_class_id INTO v_ncls FROM academic.academic_classes
         WHERE tenant_id = c_tenant AND school_id = c_school AND academic_year_id = v_ny
           AND class_name = 'ZZ VI' AND NOT is_deleted;
        PERFORM pg_temp.chk('SUB-A28 fixture: next-session class exists', v_ncls IS NOT NULL, format('class=%s', v_ncls));

        -- Proc path with the year passed explicitly works.
        PERFORM pg_temp.subj_save(c_tenant, c_school, v_ncls, '["English","Hindi"]', v_ny);
        PERFORM pg_temp.chk_txt('SUB-A29 proc: save with an explicit session reads back',
            pg_temp.subj_get(c_tenant, c_school, v_ny, v_ncls), 'English,Hindi');

        -- Service path: SubjectService.SaveClassSubjectsAsync leaves p_academic_year_id NULL.
        PERFORM pg_temp.subj_save(c_tenant, c_school, v_ncls, '["English","Hindi","Mathematics"]', NULL);
        PERFORM pg_temp.chk_txt('BUG SUB-A30 save as the page sends it lands in the class''s session',
            pg_temp.subj_get(c_tenant, c_school, v_ny, v_ncls), 'English,Hindi,Mathematics');
        SELECT COUNT(*) INTO v_n FROM academic.class_subjects cs
          JOIN academic.academic_classes ac ON ac.academic_class_id = cs.academic_class_id
         WHERE cs.tenant_id = c_tenant AND cs.school_id = c_school
           AND cs.academic_year_id <> ac.academic_year_id;
        PERFORM pg_temp.chk_eq('BUG SUB-A31 no mapping row points at a class of another session', v_n, 0);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- B. Assign Class Teacher -----------------------------------';

    -- Start from a clean slate for the sections used here.
    PERFORM pg_temp.ct_assign(c_tenant, c_school, v_sec1a, NULL);
    PERFORM pg_temp.ct_assign(c_tenant, c_school, v_sec1b, NULL);
    PERFORM pg_temp.ct_assign(c_tenant, c_school, v_sec7a, NULL);

    SELECT COUNT(*) INTO v_n FROM pg_temp.ct_grid(c_tenant, c_school, NULL);
    SELECT COUNT(*) INTO v_m FROM academic.academic_class_sections s
      JOIN academic.academic_classes ac ON ac.academic_class_id = s.academic_class_id
     WHERE s.tenant_id = c_tenant AND s.school_id = c_school AND s.academic_year_id = v_year
       AND NOT s.is_deleted AND NOT ac.is_deleted;
    PERFORM pg_temp.chk_eq('ACT-B1 grid lists every live section of the current session', v_n, v_m);
    SELECT COUNT(*) INTO v_n FROM pg_temp.ct_grid(c_tenant, c_school, v_year);
    PERFORM pg_temp.chk_eq('ACT-B2 grid with the explicit session id = same rows', v_n, v_m);

    -- Pool.
    SELECT COUNT(*) INTO v_n FROM pg_temp.ct_pool(c_tenant, c_school) WHERE o_staff = v_staff_t1;
    PERFORM pg_temp.chk_eq('ACT-B3 pool lists the active teacher', v_n, 1);
    SELECT COUNT(*) INTO v_n FROM pg_temp.ct_pool(c_tenant, c_school) WHERE o_staff = v_staff_in;
    PERFORM pg_temp.chk_eq('ACT-B4 pool hides inactive staff', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM pg_temp.ct_pool(c_tenant, c_school) WHERE o_staff = v_staff_ot;
    PERFORM pg_temp.chk_eq('ACT-B5 pool hides another school''s staff', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM pg_temp.ct_pool(c_tenant, c_school) p
      JOIN core.staff st ON st.staff_id = p.o_staff
     WHERE COALESCE(st.staff_type, '') <> 'Teaching';
    PERFORM pg_temp.chk_eq('BUG ACT-B6 pool lists only teaching staff', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM pg_temp.ct_pool(c_tenant, c_school);
    PERFORM pg_temp.chk('ACT-B7 pool is non-empty', v_n > 0, format('%s staff', v_n));

    -- Assign.
    v_txt := pg_temp.ct_assign(c_tenant, c_school, v_sec1a, v_staff_t1);
    PERFORM pg_temp.chk_txt('ACT-B8 assign returns the assigned message', v_txt, 'Class teacher assigned.');
    SELECT class_teacher_staff_id INTO v_id FROM academic.academic_class_sections WHERE academic_class_section_id = v_sec1a;
    PERFORM pg_temp.chk_eq('ACT-B9 1-A now has the teacher', v_id, v_staff_t1);
    SELECT updated_by INTO v_id FROM academic.academic_class_sections WHERE academic_class_section_id = v_sec1a;
    PERFORM pg_temp.chk_eq('ACT-B10 the acting user is stamped as updated_by', v_id, c_user);

    -- Same teacher, second section: allowed (warning only), load = 2.
    v_txt := pg_temp.ct_assign(c_tenant, c_school, v_sec1b, v_staff_t1);
    PERFORM pg_temp.chk_txt('ACT-B11 one teacher may take a second section', v_txt, 'Class teacher assigned.');
    SELECT o_load INTO v_n FROM pg_temp.ct_grid(c_tenant, c_school, NULL) WHERE o_sec = v_sec1a;
    PERFORM pg_temp.chk_eq('ACT-B12 grid load for that teacher is 2', v_n, 2);
    SELECT o_name INTO v_txt FROM pg_temp.ct_grid(c_tenant, c_school, NULL) WHERE o_sec = v_sec1b;
    PERFORM pg_temp.chk('ACT-B13 grid shows the teacher''s name', v_txt IS NOT NULL, COALESCE(v_txt, 'NULL'));

    -- Idempotent re-assign.
    PERFORM pg_temp.ct_assign(c_tenant, c_school, v_sec1b, v_staff_t1);
    SELECT o_load INTO v_n FROM pg_temp.ct_grid(c_tenant, c_school, NULL) WHERE o_sec = v_sec1b;
    PERFORM pg_temp.chk_eq('ACT-B14 re-assigning the same teacher changes nothing', v_n, 2);

    -- Replace 1-B's teacher.
    PERFORM pg_temp.ct_assign(c_tenant, c_school, v_sec1b, v_staff_t2);
    SELECT o_load INTO v_n FROM pg_temp.ct_grid(c_tenant, c_school, NULL) WHERE o_sec = v_sec1a;
    PERFORM pg_temp.chk_eq('ACT-B15 reassigning 1-B drops teacher 1 back to load 1', v_n, 1);

    -- Attendance gate (IsTeacher).
    PERFORM pg_temp.chk('ACT-B16 class teacher of 1-A passes the attendance gate',
        pg_temp.ct_is(c_tenant, c_school, v_user_t1, '1', 'A'), '');
    PERFORM pg_temp.chk('ACT-B17 gate ignores case and padding (" 1 ", " a ")',
        pg_temp.ct_is(c_tenant, c_school, v_user_t1, ' 1 ', ' a '), '');
    PERFORM pg_temp.chk('ACT-B18 another teacher is not class teacher of 1-A',
        NOT pg_temp.ct_is(c_tenant, c_school, v_user_t2, '1', 'A'), '');
    PERFORM pg_temp.chk('ACT-B19 teacher 1 is no longer class teacher of 1-B',
        NOT pg_temp.ct_is(c_tenant, c_school, v_user_t1, '1', 'B'), '');
    PERFORM pg_temp.chk('ACT-B20 teacher 2 is class teacher of 1-B',
        pg_temp.ct_is(c_tenant, c_school, v_user_t2, '1', 'B'), '');
    PERFORM pg_temp.chk('ACT-B21 a NULL section never passes the gate',
        NOT COALESCE(pg_temp.ct_is(c_tenant, c_school, v_user_t1, '1', NULL), FALSE), '');

    -- Clear with NULL and with 0.
    v_txt := pg_temp.ct_assign(c_tenant, c_school, v_sec1b, 0);
    PERFORM pg_temp.chk_txt('ACT-B22 staff 0 clears the section', v_txt, 'Class teacher cleared.');
    SELECT class_teacher_staff_id INTO v_id FROM academic.academic_class_sections WHERE academic_class_section_id = v_sec1b;
    PERFORM pg_temp.chk('ACT-B23 ...and stores NULL, not 0', v_id IS NULL, COALESCE(v_id::text, 'NULL'));
    PERFORM pg_temp.ct_assign(c_tenant, c_school, v_sec1a, NULL);
    PERFORM pg_temp.chk('ACT-B24 after clearing, the old teacher fails the gate',
        NOT pg_temp.ct_is(c_tenant, c_school, v_user_t1, '1', 'A'), '');

    -- Section refusals.
    BEGIN
        PERFORM pg_temp.ct_assign(c_tenant, c_school, v_sec_del, v_staff_t1);
        PERFORM pg_temp.chk('ACT-B25 assigning to a deleted section refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('ACT-B25 assigning to a deleted section refused', TRUE, SQLERRM);
    END;
    BEGIN
        PERFORM pg_temp.ct_assign(c_tenant, c_school, 999999, v_staff_t1);
        PERFORM pg_temp.chk('ACT-B26 assigning to a non-existent section refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('ACT-B26 assigning to a non-existent section refused', TRUE, SQLERRM);
    END;

    -- Staff refusals: the proc does not check the staff id at all, and the
    -- column has no foreign key.
    BEGIN
        PERFORM pg_temp.ct_assign(c_tenant, c_school, v_sec7a, v_staff_ot);
        PERFORM pg_temp.chk('BUG ACT-B27 another school''s staff cannot be class teacher', FALSE,
            'accepted: section now points at a foreign staff_id');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('BUG ACT-B27 another school''s staff cannot be class teacher', TRUE, SQLERRM);
    END;
    PERFORM pg_temp.ct_assign(c_tenant, c_school, v_sec7a, NULL);
    BEGIN
        PERFORM pg_temp.ct_assign(c_tenant, c_school, v_sec7a, 999999);
        PERFORM pg_temp.chk('BUG ACT-B28 a non-existent staff id is refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('BUG ACT-B28 a non-existent staff id is refused', TRUE, SQLERRM);
    END;
    PERFORM pg_temp.ct_assign(c_tenant, c_school, v_sec7a, NULL);
    BEGIN
        PERFORM pg_temp.ct_assign(c_tenant, c_school, v_sec7a, v_staff_in);
        PERFORM pg_temp.chk('BUG ACT-B29 inactive staff cannot be class teacher', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('BUG ACT-B29 inactive staff cannot be class teacher', TRUE, SQLERRM);
    END;
    PERFORM pg_temp.ct_assign(c_tenant, c_school, v_sec7a, NULL);

    -- Unknown operation falls through to the Grid (no refusal) - document it.
    -- Scope checks are in section E.

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- C. Period Structure ---------------------------------------';

    PERFORM pg_temp.chk_txt('PER-C1 school starts with no schedule', pg_temp.ps_get(c_tenant, c_school), '');

    -- 8 teaching periods, short break, lunch, diary - posted out of order, with
    -- a padded label, an upper-case type and one item with no type.
    v_items := '[
      {"name":"P5","start":"10:55","end":"11:35","type":"class"},
      {"name":"P1","start":"08:00","end":"08:40","type":"class"},
      {"name":"P2","start":"08:40","end":"09:20","type":"class"},
      {"name":"  Lunch  ","start":"11:35","end":"12:05","type":"LUNCH"},
      {"name":"P3","start":"09:20","end":"10:00","type":"class"},
      {"name":"Short Break","start":"10:00","end":"10:15","type":" break "},
      {"name":"P4","start":"10:15","end":"10:55","type":"class"},
      {"name":"P6","start":"12:05","end":"12:45","type":"class"},
      {"name":"P7","start":"12:45","end":"13:25","type":"class"},
      {"name":"P8","start":"13:25","end":"14:05"},
      {"name":"Diary","start":"14:05","end":"14:15","type":"diary"}]';
    v_txt := pg_temp.ps_save(c_tenant, c_school, v_items);
    PERFORM pg_temp.chk_txt('PER-C2 a valid 11-slot day saves', v_txt, 'Schedule saved.');
    SELECT COUNT(*) INTO v_n FROM academic.period_structure WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk_eq('PER-C3 11 rows stored', v_n, 11);
    PERFORM pg_temp.chk_txt('PER-C4 stored in clock order with seq 1..11, trimmed, lower-cased, default class',
        pg_temp.ps_get(c_tenant, c_school),
        '1:P1@08:00-08:40/class;2:P2@08:40-09:20/class;3:P3@09:20-10:00/class;4:Short Break@10:00-10:15/break;'
        || '5:P4@10:15-10:55/class;6:P5@10:55-11:35/class;7:Lunch@11:35-12:05/lunch;8:P6@12:05-12:45/class;'
        || '9:P7@12:45-13:25/class;10:P8@13:25-14:05/class;11:Diary@14:05-14:15/diary;');
    SELECT COUNT(*) INTO v_n FROM academic.period_structure
     WHERE tenant_id = c_tenant AND school_id = c_school AND period_type = 'class';
    PERFORM pg_temp.chk_eq('PER-C5 8 teaching periods', v_n, 8);
    SELECT created_by INTO v_n FROM academic.period_structure WHERE tenant_id = c_tenant AND school_id = c_school LIMIT 1;
    PERFORM pg_temp.chk_eq('PER-C6 created_by is the acting user', v_n, c_user);

    -- Idempotent re-save.
    PERFORM pg_temp.ps_save(c_tenant, c_school, v_items);
    SELECT COUNT(*) INTO v_n FROM academic.period_structure WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk_eq('PER-C7 re-saving the same day keeps 11 rows (no duplicates)', v_n, 11);

    -- Refusals. Each must leave the saved schedule untouched.
    v_ot_before := pg_temp.ps_get(c_tenant, c_school);

    BEGIN PERFORM pg_temp.ps_save(c_tenant, c_school, '[]');
        PERFORM pg_temp.chk('PER-C8 an empty schedule refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('PER-C8 an empty schedule refused', TRUE, SQLERRM); END;

    BEGIN PERFORM pg_temp.ps_save(c_tenant, c_school, NULL);
        PERFORM pg_temp.chk('PER-C9 a NULL schedule refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('PER-C9 a NULL schedule refused', TRUE, SQLERRM); END;

    BEGIN PERFORM pg_temp.ps_save(c_tenant, c_school, '[{"name":"   ","start":"08:00","end":"08:40","type":"class"}]');
        PERFORM pg_temp.chk('PER-C10 a whitespace-only label refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('PER-C10 a whitespace-only label refused', TRUE, SQLERRM); END;

    BEGIN PERFORM pg_temp.ps_save(c_tenant, c_school, '[{"start":"08:00","end":"08:40","type":"class"}]');
        PERFORM pg_temp.chk('PER-C11 a missing label refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('PER-C11 a missing label refused', TRUE, SQLERRM); END;

    BEGIN PERFORM pg_temp.ps_save(c_tenant, c_school, '[{"name":"P1","end":"08:40","type":"class"}]');
        PERFORM pg_temp.chk('PER-C12 a missing start time refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('PER-C12 a missing start time refused', TRUE, SQLERRM); END;

    BEGIN PERFORM pg_temp.ps_save(c_tenant, c_school, '[{"name":"P1","start":"08:00","type":"class"}]');
        PERFORM pg_temp.chk('PER-C13 a missing end time refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('PER-C13 a missing end time refused', TRUE, SQLERRM); END;

    BEGIN PERFORM pg_temp.ps_save(c_tenant, c_school, '[{"name":"P1","start":"08:40","end":"08:00","type":"class"}]');
        PERFORM pg_temp.chk('PER-C14 a backwards period (ends before start) refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('PER-C14 a backwards period (ends before start) refused', TRUE, SQLERRM); END;

    BEGIN PERFORM pg_temp.ps_save(c_tenant, c_school, '[{"name":"P1","start":"08:00","end":"08:00","type":"class"}]');
        PERFORM pg_temp.chk('PER-C15 a zero-length period refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('PER-C15 a zero-length period refused', TRUE, SQLERRM); END;

    BEGIN PERFORM pg_temp.ps_save(c_tenant, c_school, '[{"name":"Late","start":"23:30","end":"00:15","type":"class"}]');
        PERFORM pg_temp.chk('PER-C16 a period crossing midnight refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('PER-C16 a period crossing midnight refused', TRUE, SQLERRM); END;

    BEGIN PERFORM pg_temp.ps_save(c_tenant, c_school,
        '[{"name":"P1","start":"08:00","end":"08:45","type":"class"},{"name":"P2","start":"08:40","end":"09:20","type":"class"}]');
        PERFORM pg_temp.chk('PER-C17 overlapping periods refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('PER-C17 overlapping periods refused', TRUE, SQLERRM); END;

    BEGIN PERFORM pg_temp.ps_save(c_tenant, c_school,
        '[{"name":"P2","start":"08:40","end":"09:20","type":"class"},{"name":"P1","start":"08:00","end":"08:45","type":"class"}]');
        PERFORM pg_temp.chk('PER-C18 overlap caught whatever order it is posted in', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('PER-C18 overlap caught whatever order it is posted in', TRUE, SQLERRM); END;

    BEGIN PERFORM pg_temp.ps_save(c_tenant, c_school,
        '[{"name":"Lunch","start":"11:30","end":"12:00","type":"lunch"},{"name":"P5","start":"11:00","end":"13:00","type":"class"}]');
        PERFORM pg_temp.chk('PER-C19 a break inside a class period refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('PER-C19 a break inside a class period refused', TRUE, SQLERRM); END;

    BEGIN PERFORM pg_temp.ps_save(c_tenant, c_school,
        '[{"name":"P1","start":"08:00","end":"08:40","type":"class"},{"name":"P1","start":"08:40","end":"09:20","type":"class"}]');
        PERFORM pg_temp.chk('PER-C20 two periods with the same label refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('PER-C20 two periods with the same label refused', TRUE, SQLERRM); END;

    BEGIN PERFORM pg_temp.ps_save(c_tenant, c_school,
        '[{"name":"Break","start":"10:00","end":"10:10","type":"break"},{"name":" break ","start":"12:00","end":"12:10","type":"break"}]');
        PERFORM pg_temp.chk('PER-C21 duplicate label by case/padding refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('PER-C21 duplicate label by case/padding refused', TRUE, SQLERRM); END;

    BEGIN PERFORM pg_temp.ps_save(c_tenant, c_school, '[{"name":"Games","start":"08:00","end":"08:40","type":"sports"}]');
        PERFORM pg_temp.chk('PER-C22 an unknown period type refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('PER-C22 an unknown period type refused', TRUE, SQLERRM); END;

    BEGIN PERFORM pg_temp.ps_save(c_tenant, c_school,
        format('[{"name":"%s","start":"08:00","end":"08:40","type":"class"}]', repeat('L', 51)));
        PERFORM pg_temp.chk('PER-C23 a 51-char label refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('PER-C23 a 51-char label refused', TRUE, SQLERRM); END;

    BEGIN PERFORM pg_temp.ps_save(c_tenant, c_school, '[{"name":"P1","start":"25:00","end":"26:00","type":"class"}]');
        PERFORM pg_temp.chk('PER-C24 an impossible clock time refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('PER-C24 an impossible clock time refused', TRUE, SQLERRM); END;

    BEGIN PERFORM pg_temp.ps_save(c_tenant, c_school, '{"name":"P1"}');
        PERFORM pg_temp.chk('PER-C25 a payload that is not an array refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('PER-C25 a payload that is not an array refused', TRUE, SQLERRM); END;

    BEGIN
        c := pg_temp.cur();
        CALL academic.sp_school_admin_period_structure_manage('Nope', c_tenant, c_school, c_user, NULL, c);
        PERFORM pg_temp.chk('PER-C26 unknown operation refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('PER-C26 unknown operation refused', TRUE, SQLERRM); END;

    PERFORM pg_temp.chk('PER-C27 every refused save left the schedule untouched',
        pg_temp.ps_get(c_tenant, c_school) = v_ot_before, '');

    -- Boundary: exact 50-char label and back-to-back periods are fine.
    v_txt := pg_temp.ps_save(c_tenant, c_school,
        format('[{"name":"%s","start":"08:00","end":"08:40","type":"assembly"},{"name":"P1","start":"08:40","end":"09:20"}]', repeat('L', 50)));
    PERFORM pg_temp.chk_txt('PER-C28 50-char label + back-to-back periods accepted', v_txt, 'Schedule saved.');

    -- Edit + delete via replace-all: restore the day, then move P3 and drop Diary.
    PERFORM pg_temp.ps_save(c_tenant, c_school, v_items);
    v_items := replace(v_items, '{"name":"P3","start":"09:20","end":"10:00","type":"class"}',
                                '{"name":"P3","start":"09:20","end":"09:55","type":"class"}');
    v_items := replace(v_items, ',
      {"name":"Diary","start":"14:05","end":"14:15","type":"diary"}', '');
    PERFORM pg_temp.ps_save(c_tenant, c_school, v_items);
    SELECT to_char(end_time, 'HH24:MI') INTO v_txt FROM academic.period_structure
     WHERE tenant_id = c_tenant AND school_id = c_school AND label = 'P3';
    PERFORM pg_temp.chk_txt('PER-C29 editing P3''s end time is stored', v_txt, '09:55');
    SELECT COUNT(*) INTO v_n FROM academic.period_structure
     WHERE tenant_id = c_tenant AND school_id = c_school AND label = 'Diary';
    PERFORM pg_temp.chk_eq('PER-C30 removing Diary deletes it', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM academic.period_structure WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk_eq('PER-C31 10 rows remain', v_n, 10);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- D. Downstream: timetable, exams, class rebuild ------------';

    -- Class 7 studies Mathematics + English; the timetable dropdown follows it.
    PERFORM pg_temp.subj_save(c_tenant, c_school, v_cls7, '["Mathematics","English"]');
    PERFORM pg_temp.chk_txt('DS-D1 timetable subject dropdown for 7-A = class 7''s subjects',
        pg_temp.tt_grid_subjects(c_tenant, c_school, v_sec7a), 'Mathematics,English');

    SELECT subject_id INTO v_sid FROM academic.school_subjects
     WHERE tenant_id = c_tenant AND school_id = c_school AND subject_name = 'Mathematics';

    -- Book Monday P1 (seq 1) for 7-A.
    v_txt := pg_temp.tt_save(c_tenant, c_school, v_sec7a, 1, 1, v_sid, v_staff_t1);
    PERFORM pg_temp.chk_txt('DS-D2 Monday P1 booked for 7-A', v_txt, 'Period updated.');

    BEGIN
        PERFORM pg_temp.tt_save(c_tenant, c_school, v_sec7a, 1, 4, v_sid, v_staff_t1);   -- seq 4 = Short Break
        PERFORM pg_temp.chk('DS-D3 a break slot cannot be booked', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('DS-D3 a break slot cannot be booked', TRUE, SQLERRM); END;

    BEGIN
        PERFORM pg_temp.tt_save(c_tenant, c_school, v_sec8a, 1, 1, v_sid, v_staff_t1);
        PERFORM pg_temp.chk('DS-D4 the same teacher cannot take 8-A in the same slot', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('DS-D4 the same teacher cannot take 8-A in the same slot', TRUE, SQLERRM); END;

    -- Book Monday P8 (seq 10) for 7-A too.
    PERFORM pg_temp.tt_save(c_tenant, c_school, v_sec7a, 1, 10, v_sid, NULL);

    -- Now the school adds a morning assembly before P1. Period Structure renumbers
    -- seq by clock order, but timetable rows are keyed by seq: Monday's Maths P1
    -- booking (seq 1) is now sitting on the Assembly.
    v_items := replace(v_items, '[', '[
      {"name":"Assembly","start":"07:40","end":"08:00","type":"assembly"},');
    PERFORM pg_temp.ps_save(c_tenant, c_school, v_items);
    SELECT p.label INTO v_txt
      FROM academic.timetable t
      JOIN academic.period_structure p
        ON p.tenant_id = t.tenant_id AND p.school_id = t.school_id AND p.seq = t.period_seq
     WHERE t.tenant_id = c_tenant AND t.school_id = c_school
       AND t.academic_class_section_id = v_sec7a AND t.day_of_week = 1 AND t.subject_id = v_sid
     ORDER BY t.period_seq LIMIT 1;
    PERFORM pg_temp.chk_txt('DS-D5 Monday Maths stays on P1 after adding an assembly', v_txt, 'P1');

    -- Remove P8 while it still has a lesson: the save is refused, so the booking
    -- can never be left on a period that no longer exists.
    BEGIN
        PERFORM pg_temp.ps_save(c_tenant, c_school, replace(v_items, ',
      {"name":"P8","start":"13:25","end":"14:05"}', ''));
        PERFORM pg_temp.chk('DS-D6a removing a period that has lessons is refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('DS-D6a removing a period that has lessons is refused', TRUE, SQLERRM);
    END;
    SELECT COUNT(*) INTO v_n
      FROM academic.timetable t
     WHERE t.tenant_id = c_tenant AND t.school_id = c_school
       AND NOT EXISTS (SELECT 1 FROM academic.period_structure p
                        WHERE p.tenant_id = t.tenant_id AND p.school_id = t.school_id
                          AND p.seq = t.period_seq AND p.period_type = 'class');
    PERFORM pg_temp.chk_eq('DS-D6 no timetable booking is left on a non-teaching / missing period', v_n, 0);

    -- Remove Mathematics from class 7 while 7-A still has Maths booked.
    PERFORM pg_temp.subj_save(c_tenant, c_school, v_cls7, '["English"]');
    SELECT COUNT(*) INTO v_n FROM academic.timetable
     WHERE tenant_id = c_tenant AND school_id = c_school AND academic_class_section_id = v_sec7a AND subject_id = v_sid;
    PERFORM pg_temp.chk_eq('DS-D7 unmapping a subject does not leave its timetable bookings behind', v_n, 0);
    PERFORM pg_temp.subj_save(c_tenant, c_school, v_cls7, '["Mathematics","English"]');

    -- Exams read class_subjects (exam proc refuses a subject the class does not
    -- study). Mapping present = exam can use it.
    SELECT COUNT(*) INTO v_n FROM academic.class_subjects
     WHERE tenant_id = c_tenant AND school_id = c_school AND academic_year_id = v_year
       AND academic_class_id = v_cls7 AND subject_id = v_sid;
    PERFORM pg_temp.chk_eq('DS-D8 Mathematics is mapped to class 7 for exam setup', v_n, 1);

    -- A Classes & Sections save updates classes and sections in place (ids
    -- kept), so the class teacher, subjects and timetable all stay attached.
    -- (It used to rebuild every row with new ids and drop subjects/timetable.)
    DECLARE v_json text; v_before6 text; v_new6 integer; v_new7a integer;
    BEGIN
        PERFORM pg_temp.ct_assign(c_tenant, c_school, v_sec7a, v_staff_t1);
        -- DS-D7 cleared 7-A's Maths lessons; book one again so D12 has something to keep.
        PERFORM pg_temp.tt_save(c_tenant, c_school, v_sec7a, 1,
            (SELECT MIN(seq) FROM academic.period_structure
              WHERE tenant_id = c_tenant AND school_id = c_school AND period_type = 'class')::int,
            v_sid, v_staff_t1);
        v_before6 := pg_temp.subj_get(c_tenant, c_school, NULL, v_cls6);

        SELECT jsonb_agg(jsonb_build_object(
                   'className', ac.class_name, 'displayOrder', ac.display_order, 'stream', ac.stream,
                   'coordinatorStaffId', ac.coordinator_staff_id,
                   'sections', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                                    'sectionName', s.section_name, 'capacity', s.capacity, 'roomNo', s.room_no)
                                    ORDER BY s.display_order), '[]'::jsonb)
                                FROM academic.academic_class_sections s
                                WHERE s.academic_class_id = ac.academic_class_id AND NOT s.is_deleted))
                   ORDER BY ac.display_order)::text
          INTO v_json
          FROM academic.academic_classes ac
         WHERE ac.tenant_id = c_tenant AND ac.school_id = c_school
           AND ac.academic_year_id = v_year AND NOT ac.is_deleted;

        c := pg_temp.cur();
        CALL academic.sp_school_admin_academic_setup_manage('SaveAcademicSetup',
             c_tenant, c_school, c_user, v_year, v_yearname, v_json, c);
        DROP TABLE IF EXISTS _ct_snap;

        SELECT academic_class_id INTO v_new6 FROM academic.academic_classes
         WHERE tenant_id = c_tenant AND school_id = c_school AND academic_year_id = v_year
           AND class_name = '6' AND NOT is_deleted;
        SELECT s.academic_class_section_id INTO v_new7a FROM academic.academic_class_sections s
          JOIN academic.academic_classes ac ON ac.academic_class_id = s.academic_class_id
         WHERE s.tenant_id = c_tenant AND s.school_id = c_school AND s.academic_year_id = v_year
           AND ac.class_name = '7' AND s.section_name = 'A' AND NOT s.is_deleted;

        PERFORM pg_temp.chk('DS-D9 re-saving Classes & Sections unchanged keeps class 6''s id',
            v_new6 IS NOT NULL AND v_new6 = v_cls6, format('%s -> %s', v_cls6, v_new6));
        SELECT class_teacher_staff_id INTO v_id FROM academic.academic_class_sections WHERE academic_class_section_id = v_new7a;
        PERFORM pg_temp.chk_eq('DS-D10 ...class teacher of 7-A is carried over', v_id, v_staff_t1);
        PERFORM pg_temp.chk_txt('DS-D11 ...class 6 keeps its subjects', pg_temp.subj_get(c_tenant, c_school, NULL, v_new6), v_before6);
        SELECT COUNT(*) INTO v_n FROM academic.timetable
         WHERE tenant_id = c_tenant AND school_id = c_school AND academic_class_section_id = v_new7a;
        PERFORM pg_temp.chk('DS-D12 ...7-A keeps its timetable', v_n > 0, format('%s booking(s) on the section', v_n));
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- E. Scope and isolation ------------------------------------';

    BEGIN PERFORM pg_temp.subj_save(1, 0, v_cls7, '["English"]');
        PERFORM pg_temp.chk('SC-E1 platform scope subject save refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('SC-E1 platform scope subject save refused', TRUE, SQLERRM); END;
    BEGIN PERFORM pg_temp.subj_get(c_tenant, 0, NULL, v_cls7);
        PERFORM pg_temp.chk('SC-E2 schoolId 0 subject read refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('SC-E2 schoolId 0 subject read refused', TRUE, SQLERRM); END;
    BEGIN PERFORM pg_temp.ps_save(1, c_school, '[{"name":"P1","start":"08:00","end":"08:40"}]');
        PERFORM pg_temp.chk('SC-E3 tenant 1 period save refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('SC-E3 tenant 1 period save refused', TRUE, SQLERRM); END;
    BEGIN PERFORM pg_temp.ps_get(c_tenant, 0);
        PERFORM pg_temp.chk('SC-E4 schoolId 0 period read refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('SC-E4 schoolId 0 period read refused', TRUE, SQLERRM); END;
    BEGIN PERFORM pg_temp.ct_assign(1, 0, v_sec1a, v_staff_t1);
        PERFORM pg_temp.chk('SC-E5 platform scope class-teacher assign refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('SC-E5 platform scope class-teacher assign refused', TRUE, SQLERRM); END;
    BEGIN PERFORM COUNT(*) FROM pg_temp.ct_grid(1, c_school, NULL);
        PERFORM pg_temp.chk('SC-E6 tenant 1 grid read refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('SC-E6 tenant 1 grid read refused', TRUE, SQLERRM); END;
    BEGIN PERFORM COUNT(*) FROM pg_temp.ct_pool(c_tenant, 0);
        PERFORM pg_temp.chk('SC-E7 schoolId 0 teacher pool refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('SC-E7 schoolId 0 teacher pool refused', TRUE, SQLERRM); END;

    -- Cross-school: the other school cannot read or write our rows, and vice versa.
    PERFORM pg_temp.chk_txt('SC-E8 other school reading our class sees no subjects',
        pg_temp.subj_get(o_tenant, o_school, NULL, v_cls7), '');
    BEGIN PERFORM pg_temp.subj_save(o_tenant, o_school, v_cls7, '["Hacked"]');
        PERFORM pg_temp.chk('SC-E9 other school cannot save our class''s subjects', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('SC-E9 other school cannot save our class''s subjects', TRUE, SQLERRM); END;
    BEGIN PERFORM pg_temp.subj_save(c_tenant, c_school, v_cls_ot, '["Hacked"]');
        PERFORM pg_temp.chk('SC-E10 we cannot save the other school''s class', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('SC-E10 we cannot save the other school''s class', TRUE, SQLERRM); END;
    SELECT COUNT(*) INTO v_n FROM academic.school_subjects
     WHERE tenant_id = o_tenant AND school_id = o_school AND created_at = now();
    PERFORM pg_temp.chk_eq('SC-E11 nothing we saved created a subject in the other school', v_n, 0);

    DECLARE v_ot_teacher integer;
    BEGIN
        SELECT class_teacher_staff_id INTO v_ot_teacher FROM academic.academic_class_sections WHERE academic_class_section_id = v_sec_ot;
        BEGIN PERFORM pg_temp.ct_assign(c_tenant, c_school, v_sec_ot, v_staff_t1);
            PERFORM pg_temp.chk('SC-E12 we cannot assign a teacher to the other school''s section', FALSE, 'accepted');
        EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk('SC-E12 we cannot assign a teacher to the other school''s section', TRUE, SQLERRM); END;
        SELECT class_teacher_staff_id INTO v_id FROM academic.academic_class_sections WHERE academic_class_section_id = v_sec_ot;
        PERFORM pg_temp.chk('SC-E13 ...their section is unchanged', v_id IS NOT DISTINCT FROM v_ot_teacher, '');
    END;
    SELECT COUNT(*) INTO v_n FROM pg_temp.ct_grid(c_tenant, c_school, v_year_ot);
    PERFORM pg_temp.chk_eq('SC-E14 passing the other school''s session id shows none of their sections', v_n, 0);
    PERFORM pg_temp.chk('SC-E15 IsTeacher never answers across schools',
        NOT pg_temp.ct_is(o_tenant, o_school, v_user_t1, '7', 'A'), '');

    PERFORM pg_temp.chk_txt('SC-E16 our period saves did not touch the other school''s schedule',
        pg_temp.ps_get(o_tenant, o_school), v_ot_sched);
    PERFORM pg_temp.chk('SC-E17 other school''s schedule shows none of our labels',
        position('Assembly@07:40' IN pg_temp.ps_get(o_tenant, o_school)) = 0, '');
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
            RAISE NOTICE '   %  %', rpad(r.name, 60), r.detail;
        END LOOP;
    END IF;
    RAISE NOTICE '';
END
$sum$;

ROLLBACK;
