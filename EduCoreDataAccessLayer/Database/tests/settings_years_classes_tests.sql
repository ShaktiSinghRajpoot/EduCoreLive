-- ============================================================================
-- Academic Years + Classes & Sections test suite (deep).
--
-- Pages: /ERP/SchoolSettings/AcademicYears and /ERP/SchoolSettings/ClassSection.
-- settings_tests.sql has a handful of smoke checks for these two; this file is
-- the real-world walk-through:
--
--   "Sunrise" (tenant 24 / school 34) opens session ZZ 2040-41, makes it current,
--   builds Nursery..XII with sections A/B/C, gives XI two streams, names a
--   coordinator, admits a child, renames a section, removes an unused class,
--   tries to remove the child's class, re-saves the page, copies last year's
--   structure into a new session, then switches the current session back.
--
-- Everything a session or a class touches downstream (students by NAME, class
-- subjects / exam subjects / timetable by ID, the year dropdown) is checked
-- after each mutation, because that is where a settings change does damage.
--
-- Runs inside ONE transaction and ROLLS BACK.
--
--     psql -U postgres -d educore -q -f settings_years_classes_tests.sql
--
-- COVERS
--   A. Academic year: create, read-back, validation, length, overlaps
--   B. Current-session switching
--   C. Edit / rename / charge-fees-from guard
--   D. Delete guards and re-use of a deleted name
--   E. Classes & sections: build, read-back, validation, guards, re-save
--   F. Downstream impact of a Classes & Sections save (subjects, exams, timetable)
--   G. Copy structure from the previous session (clone) + structure info
--   H. Year dropdown (config.sp_dropdown_common) follows the mutations
--   S. Scope and cross-school isolation
--
-- A check that FAILS here is a real application bug unless noted; the name of
-- every such check says what SHOULD happen.
-- ============================================================================

\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE TEMP TABLE _t(id serial, name text, ok boolean, detail text) ON COMMIT DROP;
CREATE TEMP SEQUENCE _cs;

CREATE OR REPLACE FUNCTION pg_temp.chk(p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO _t(name, ok, detail) VALUES (p_name, COALESCE(p_ok, FALSE), p_detail);
    RAISE NOTICE '  [%] %  %', CASE WHEN COALESCE(p_ok, FALSE) THEN 'PASS' ELSE 'FAIL' END,
                 rpad(p_name, 60), p_detail;
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
                        format('got %s, expected %s', COALESCE(p_got,'NULL'), COALESCE(p_want,'NULL')));
END $$;

-- A refusal the user can read: not a raw constraint / type error.
CREATE OR REPLACE FUNCTION pg_temp.readable(p_msg text)
RETURNS boolean LANGUAGE sql AS $$
    SELECT p_msg NOT ILIKE '%violates%' AND p_msg NOT ILIKE '%value too long%'
       AND p_msg NOT ILIKE '%duplicate key%' AND p_msg NOT ILIKE '%syntax%'
$$;

-- ── Call wrappers (the same procs the services call) ─────────────────────────

-- academic.sp_school_admin_academic_year_manage; returns academic_year_id from
-- the result cursor (NULL when the proc returned no id).
CREATE OR REPLACE FUNCTION pg_temp.yr(p_op text, p_t int, p_s int, p_id int,
        p_name text DEFAULT NULL, p_sd date DEFAULT NULL, p_ed date DEFAULT NULL,
        p_cur boolean DEFAULT FALSE, p_ch text DEFAULT NULL)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'yc' || nextval('_cs'); r record;
BEGIN
    CALL academic.sp_school_admin_academic_year_manage(p_op, p_t, p_s, 39, p_id, p_name,
         p_sd, p_ed, p_cur, p_ch, c);
    FETCH c INTO r; CLOSE c;
    RETURN r.academic_year_id;
END $$;

-- GetAcademicYears, as the page lists it (pos = row order on the page).
CREATE OR REPLACE FUNCTION pg_temp.years(p_t int, p_s int)
RETURNS TABLE(id int, name text, sd text, ed text, cur boolean, charge text,
              classes bigint, students bigint, pos int)
LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'yl' || nextval('_cs'); r record; i int := 0;
BEGIN
    CALL academic.sp_school_admin_academic_year_manage('GetAcademicYears', p_t, p_s, 39,
         NULL, NULL, NULL, NULL, FALSE, NULL, c);
    LOOP
        FETCH c INTO r; EXIT WHEN NOT FOUND; i := i + 1;
        id := r.academic_year_id; name := r.academic_year_name; sd := r.start_date;
        ed := r.end_date; cur := r.is_current; charge := r.charge_fees_from;
        classes := r.class_count; students := r.student_count; pos := i;
        RETURN NEXT;
    END LOOP;
    CLOSE c;
END $$;

-- SaveAcademicSetup: the whole structure of one session (classes not in the
-- payload are removed; the rest are updated in place).
CREATE OR REPLACE FUNCTION pg_temp.save_setup(p_t int, p_s int, p_y int, p_json jsonb)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'ss' || nextval('_cs'); r record;
BEGIN
    CALL academic.sp_school_admin_academic_setup_manage('SaveAcademicSetup', p_t, p_s, 39,
         p_y, NULL, p_json::text, c);
    FETCH c INTO r; CLOSE c;
    RETURN r.success;
END $$;

-- GetAcademicSetup, one row per class x section (as the page reads it).
CREATE OR REPLACE FUNCTION pg_temp.setup(p_t int, p_s int, p_y int)
RETURNS TABLE(cls text, cls_ord int, stream text, coord text, coord_id int,
              sec text, sec_ord int, cap int, room text, ct int, strength bigint)
LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'sg' || nextval('_cs'); r record;
BEGIN
    CALL academic.sp_school_admin_academic_setup_manage('GetAcademicSetup', p_t, p_s, 39,
         p_y, NULL, NULL, c);
    LOOP
        FETCH c INTO r; EXIT WHEN NOT FOUND;
        cls := r.class_name; cls_ord := r.class_display_order; stream := r.stream;
        coord := r.coordinator; coord_id := r.coordinator_staff_id;
        sec := r.section_name; sec_ord := r.section_display_order; cap := r.capacity;
        room := r.room_no; ct := r.class_teacher_staff_id; strength := r.strength;
        RETURN NEXT;
    END LOOP;
    CLOSE c;
END $$;

-- The structure exactly as the page would post it back unchanged.
CREATE OR REPLACE FUNCTION pg_temp.cur_json(p_t int, p_s int, p_y int)
RETURNS jsonb LANGUAGE sql AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'className', c.class_name, 'originalName', c.class_name, 'displayOrder', c.display_order,
               'stream', c.stream, 'coordinator', c.coordinator,
               'coordinatorStaffId', c.coordinator_staff_id,
               'sections', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                                'sectionName', s.section_name, 'originalName', s.section_name, 'capacity', s.capacity,
                                'roomNo', s.room_no) ORDER BY s.display_order, s.section_name), '[]'::jsonb)
                            FROM academic.academic_class_sections s
                            WHERE s.academic_class_id = c.academic_class_id
                              AND COALESCE(s.is_deleted, FALSE) = FALSE))
           ORDER BY c.display_order, c.class_name), '[]'::jsonb)
    FROM academic.academic_classes c
    WHERE c.tenant_id = p_t AND c.school_id = p_s AND c.academic_year_id = p_y
      AND COALESCE(c.is_deleted, FALSE) = FALSE
$$;

-- One text fingerprint of a year's structure (everything the page shows).
CREATE OR REPLACE FUNCTION pg_temp.fp(p_t int, p_s int, p_y int)
RETURNS text LANGUAGE sql AS $$
    SELECT string_agg(concat_ws('|', cls, cls_ord, stream, coord, coord_id, sec, sec_ord, cap, room, ct),
                      ';' ORDER BY cls_ord, cls, sec_ord, sec)
    FROM pg_temp.setup(p_t, p_s, p_y)
$$;

-- JSON edits the page makes: drop a class / rename a class / rename or drop a section.
CREATE OR REPLACE FUNCTION pg_temp.j_drop_class(j jsonb, p_cls text)
RETURNS jsonb LANGUAGE sql AS $$
    SELECT COALESCE(jsonb_agg(e ORDER BY o), '[]'::jsonb)
    FROM jsonb_array_elements(j) WITH ORDINALITY x(e, o) WHERE e->>'className' <> p_cls
$$;
CREATE OR REPLACE FUNCTION pg_temp.j_rename_class(j jsonb, p_old text, p_new text)
RETURNS jsonb LANGUAGE sql AS $$
    SELECT jsonb_agg(CASE WHEN e->>'className' = p_old
                          THEN jsonb_set(e, '{className}', to_jsonb(p_new)) ELSE e END ORDER BY o)
    FROM jsonb_array_elements(j) WITH ORDINALITY x(e, o)
$$;
-- p_new NULL = drop the section.
CREATE OR REPLACE FUNCTION pg_temp.j_section(j jsonb, p_cls text, p_old text, p_new text)
RETURNS jsonb LANGUAGE sql AS $$
    SELECT jsonb_agg(CASE WHEN e->>'className' <> p_cls THEN e ELSE
             jsonb_set(e, '{sections}', COALESCE((
                 SELECT jsonb_agg(CASE WHEN s->>'sectionName' = p_old
                                       THEN jsonb_set(s, '{sectionName}', to_jsonb(p_new)) ELSE s END ORDER BY so)
                 FROM jsonb_array_elements(e->'sections') WITH ORDINALITY y(s, so)
                 WHERE NOT (s->>'sectionName' = p_old AND p_new IS NULL)), '[]'::jsonb))
           END ORDER BY o)
    FROM jsonb_array_elements(j) WITH ORDINALITY x(e, o)
$$;

-- academic.sp_academic_year_clone / sp_academic_year_structure_info.
CREATE OR REPLACE FUNCTION pg_temp.clone(p_t int, p_s int, p_from int, p_to int)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'cl' || nextval('_cs'); r record;
BEGIN
    CALL academic.sp_academic_year_clone(p_t, p_s, 39, p_from, p_to, c);
    FETCH c INTO r; CLOSE c;
    RETURN to_jsonb(r);
END $$;
CREATE OR REPLACE FUNCTION pg_temp.info(p_t int, p_s int, p_y int)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'si' || nextval('_cs'); r record;
BEGIN
    CALL academic.sp_academic_year_structure_info(p_t, p_s, 39, p_y, NULL, c);
    FETCH c INTO r;
    IF NOT FOUND THEN CLOSE c; RETURN NULL; END IF;
    CLOSE c;
    RETURN to_jsonb(r);
END $$;

-- The year dropdown every other page uses.
CREATE OR REPLACE FUNCTION pg_temp.dd(p_t int, p_s int)
RETURNS TABLE(name text, code text, sel boolean) LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'dd' || nextval('_cs'); r record;
BEGIN
    CALL config.sp_dropdown_common('AcademicYear', p_t::text, p_s::text, c);
    LOOP
        FETCH c INTO r; EXIT WHEN NOT FOUND;
        name := r."Name"; code := r."Code"; sel := r."IsSelected";
        RETURN NEXT;
    END LOOP;
    CLOSE c;
END $$;

-- Admit a child (the real admission proc) and return the student id.
CREATE OR REPLACE FUNCTION pg_temp.admit(p_no text, p_cls text, p_sec text, p_year text)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'ad' || nextval('_cs'); v int;
BEGIN
    CALL core.sp_admission_manage('SaveAdmission', 24, 34, 39, NULL,
         p_no, NULL, 'ZZ Kid ' || p_no, 'Male', DATE '2015-01-01',
         p_cls, p_sec, p_year, CURRENT_DATE, p_result => c);
    SELECT student_id INTO v FROM core.students
     WHERE tenant_id = 24 AND school_id = 34 AND admission_no = p_no;
    RETURN v;
END $$;


DO $suite$
DECLARE
    c_tenant  CONSTANT integer := 24;
    c_school  CONSTANT integer := 34;
    c_user    CONSTANT integer := 39;
    c_otenant CONSTANT integer := 23;     -- another real school
    c_oschool CONSTANT integer := 33;

    v_fix_id   integer;      -- fixture current session
    v_fix_name text;
    v_oyear    integer;      -- a session that belongs to the other school
    v_ocur     integer;      -- the other school's current session

    v_y      integer;        -- ZZ 2040-41, the session this walk-through builds
    v_y2     integer;
    v_tmp    integer;
    v_sid    integer;
    v_j      jsonb;
    v_r      jsonb;
    v_ok     boolean;
    v_n      integer;
    v_n2     integer;
    v_txt    text;
    v_txt2   text;
    v_rec    record;
    c        refcursor;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '========= ACADEMIC YEARS + CLASSES & SECTIONS TESTS =========';

    SELECT academic_year_id, academic_year_name INTO v_fix_id, v_fix_name
    FROM academic.academic_years
    WHERE tenant_id = c_tenant AND school_id = c_school
      AND COALESCE(is_current, FALSE) AND NOT is_deleted LIMIT 1;

    SELECT academic_year_id INTO v_ocur FROM academic.academic_years
     WHERE tenant_id = c_otenant AND school_id = c_oschool AND is_current AND NOT is_deleted LIMIT 1;
    SELECT academic_year_id INTO v_oyear FROM academic.academic_years
     WHERE tenant_id = c_otenant AND school_id = c_oschool AND NOT is_deleted
     ORDER BY academic_year_id LIMIT 1;

    IF v_fix_id IS NULL OR v_oyear IS NULL OR v_ocur IS NULL THEN
        RAISE EXCEPTION 'Fixture missing: school % needs a current session, school % a session.',
            c_school, c_oschool;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM academic.academic_classes WHERE academic_year_id = v_fix_id AND NOT is_deleted) THEN
        RAISE EXCEPTION 'Fixture missing: session % has no classes.', v_fix_name;
    END IF;
    RAISE NOTICE 'fixture: current session=% (id %), other school session id=%',
        v_fix_name, v_fix_id, v_oyear;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- A. Academic year: create, read-back, validation -----------------';

    BEGIN
        PERFORM pg_temp.yr('SaveAcademicYear', c_tenant, c_school, NULL, '   ',
                           DATE '2040-04-01', DATE '2041-03-31');
        PERFORM pg_temp.chk('AY-03 whitespace-only name refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('AY-03 whitespace-only name refused', TRUE, SQLERRM);
    END;

    BEGIN
        PERFORM pg_temp.yr('SaveAcademicYear', c_tenant, c_school, NULL, NULL,
                           DATE '2040-04-01', DATE '2041-03-31');
        PERFORM pg_temp.chk('AY-02 NULL name refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('AY-02 NULL name refused', TRUE, SQLERRM);
    END;

    BEGIN
        PERFORM pg_temp.yr('SaveAcademicYear', c_tenant, c_school, NULL, 'ZZ Backwards',
                           DATE '2041-04-01', DATE '2040-03-31');
        PERFORM pg_temp.chk('AY-10 end date before start date refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('AY-10 end date before start date refused', TRUE, SQLERRM);
        PERFORM pg_temp.chk('AY-10b ...with a readable message', pg_temp.readable(SQLERRM), SQLERRM);
    END;

    -- Boundary: a one-day session. The proc only refuses end < start, but the
    -- table CHECK says end > start, so it dies on the raw constraint.
    BEGIN
        PERFORM pg_temp.yr('SaveAcademicYear', c_tenant, c_school, NULL, 'ZZ OneDay',
                           DATE '2045-04-01', DATE '2045-04-01');
        PERFORM pg_temp.chk('AY-11 end date = start date refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('AY-11 end date = start date refused', TRUE, SQLERRM);
        PERFORM pg_temp.chk('AY-11b ...with a readable message (proc should check end <= start)',
                            pg_temp.readable(SQLERRM), SQLERRM);
    END;

    -- Dates are optional on the page, but the columns are NOT NULL.
    BEGIN
        PERFORM pg_temp.yr('SaveAcademicYear', c_tenant, c_school, NULL, 'ZZ NoDates',
                           NULL, NULL);
        PERFORM pg_temp.chk('AY-08 session without dates refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('AY-08 session without dates refused', TRUE, SQLERRM);
        PERFORM pg_temp.chk('AY-08b ...with a readable message (dates required)',
                            pg_temp.readable(SQLERRM), SQLERRM);
    END;

    BEGIN
        PERFORM pg_temp.yr('SaveAcademicYear', c_tenant, c_school, NULL, 'ZZ StartOnly',
                           DATE '2046-04-01', NULL);
        PERFORM pg_temp.chk('AY-09 session with start but no end refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('AY-09 session with start but no end refused', TRUE, SQLERRM);
        PERFORM pg_temp.chk('AY-09b ...with a readable message', pg_temp.readable(SQLERRM), SQLERRM);
    END;

    -- Length: academic_year_name is varchar(20); the page has no maxlength.
    BEGIN
        PERFORM pg_temp.yr('SaveAcademicYear', c_tenant, c_school, NULL, 'ZZ 2040-2041 Session1',  -- 21
                           DATE '2047-04-01', DATE '2048-03-31');
        PERFORM pg_temp.chk('AY-05 21-character name refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('AY-05 21-character name refused', TRUE, SQLERRM);
        PERFORM pg_temp.chk('AY-05b ...with a readable message (proc should check length)',
                            pg_temp.readable(SQLERRM), SQLERRM);
    END;

    v_tmp := pg_temp.yr('SaveAcademicYear', c_tenant, c_school, NULL, 'ZZ 2048-2049 Session',  -- 20
                        DATE '2048-04-01', DATE '2049-03-31');
    PERFORM pg_temp.chk('AY-06 exactly 20-character name accepted', v_tmp IS NOT NULL, format('id=%s', v_tmp));

    -- The session this walk-through builds.
    v_y := pg_temp.yr('SaveAcademicYear', c_tenant, c_school, NULL, 'ZZ 2040-41',
                      DATE '2040-04-01', DATE '2041-03-31', FALSE, 'SessionStart');
    PERFORM pg_temp.chk('AY-01 a valid session is created and its id returned', v_y IS NOT NULL,
                        format('id=%s', v_y));

    SELECT * INTO v_rec FROM pg_temp.years(c_tenant, c_school) WHERE id = v_y;
    PERFORM pg_temp.chk_txt('AY-01b read-back: name', v_rec.name, 'ZZ 2040-41');
    PERFORM pg_temp.chk_txt('AY-01c read-back: start date (ISO)', v_rec.sd, '2040-04-01');
    PERFORM pg_temp.chk_txt('AY-01d read-back: end date (ISO)', v_rec.ed, '2041-03-31');
    PERFORM pg_temp.chk_txt('AY-01e read-back: charge fees from', v_rec.charge, 'SessionStart');
    PERFORM pg_temp.chk('AY-01f read-back: not current', v_rec.cur IS FALSE, format('cur=%s', v_rec.cur));
    PERFORM pg_temp.chk_eq('AY-01g read-back: 0 classes', v_rec.classes, 0);
    PERFORM pg_temp.chk_eq('AY-01h read-back: 0 students', v_rec.students, 0);
    SELECT COUNT(*) INTO v_n FROM pg_temp.years(c_tenant, c_school) WHERE cur;
    PERFORM pg_temp.chk_eq('AY-01i adding a non-current session leaves one current', v_n, 1);

    -- List order: newest start date first.
    SELECT string_agg(sd, ',' ORDER BY pos) INTO v_txt FROM pg_temp.years(c_tenant, c_school);
    SELECT string_agg(sd, ',' ORDER BY sd DESC) INTO v_txt2 FROM pg_temp.years(c_tenant, c_school);
    PERFORM pg_temp.chk('AY-40 list is ordered by start date, newest first', v_txt = v_txt2, v_txt);

    v_tmp := pg_temp.yr('SaveAcademicYear', c_tenant, c_school, NULL, '   ZZ Trim   ',
                        DATE '2052-04-01', DATE '2053-03-31');
    SELECT academic_year_name INTO v_txt FROM academic.academic_years WHERE academic_year_id = v_tmp;
    PERFORM pg_temp.chk_txt('AY-04 name is trimmed before saving', v_txt, 'ZZ Trim');

    BEGIN
        PERFORM pg_temp.yr('SaveAcademicYear', c_tenant, c_school, NULL, 'ZZ 2040-41',
                           DATE '2060-04-01', DATE '2061-03-31');
        PERFORM pg_temp.chk('AY-12 duplicate name refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('AY-12 duplicate name refused', TRUE, SQLERRM);
    END;

    BEGIN
        PERFORM pg_temp.yr('SaveAcademicYear', c_tenant, c_school, NULL, 'zz 2040-41',
                           DATE '2060-04-01', DATE '2061-03-31');
        PERFORM pg_temp.chk('AY-13 duplicate name in another case refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('AY-13 duplicate name in another case refused', TRUE, SQLERRM);
    END;

    BEGIN
        PERFORM pg_temp.yr('SaveAcademicYear', c_tenant, c_school, NULL, '  ZZ 2040-41 ',
                           DATE '2060-04-01', DATE '2061-03-31');
        PERFORM pg_temp.chk('AY-14 duplicate name with padding refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('AY-14 duplicate name with padding refused', TRUE, SQLERRM);
    END;

    -- Same name in ANOTHER school is fine.
    v_tmp := pg_temp.yr('SaveAcademicYear', c_otenant, c_oschool, NULL, 'ZZ 2040-41',
                        DATE '2040-04-01', DATE '2041-03-31');
    PERFORM pg_temp.chk('AY-15 the same name in another school is allowed', v_tmp IS NOT NULL,
                        format('id=%s', v_tmp));

    v_tmp := pg_temp.yr('SaveAcademicYear', c_tenant, c_school, NULL, 'ZZ <b>&"''x</b>',
                        DATE '2054-04-01', DATE '2055-03-31');
    SELECT academic_year_name INTO v_txt FROM academic.academic_years WHERE academic_year_id = v_tmp;
    PERFORM pg_temp.chk_txt('AY-07 special characters stored verbatim', v_txt, 'ZZ <b>&"''x</b>');
    v_tmp := pg_temp.yr('SaveAcademicYear', c_tenant, c_school, NULL, 'ZZ सत्र 2056',
                        DATE '2056-04-01', DATE '2057-03-31');
    SELECT academic_year_name INTO v_txt FROM academic.academic_years WHERE academic_year_id = v_tmp;
    PERFORM pg_temp.chk_txt('AY-07b unicode name round-trips', v_txt, 'ZZ सत्र 2056');

    v_tmp := pg_temp.yr('SaveAcademicYear', c_tenant, c_school, NULL, 'ZZ Charge X',
                        DATE '2058-04-01', DATE '2059-03-31', FALSE, 'Garbage');
    SELECT charge_fees_from INTO v_txt FROM academic.academic_years WHERE academic_year_id = v_tmp;
    PERFORM pg_temp.chk_txt('AY-16 unknown charge-fees-from falls back to AdmissionMonth', v_txt, 'AdmissionMonth');
    v_tmp := pg_temp.yr('SaveAcademicYear', c_tenant, c_school, NULL, 'ZZ Charge N',
                        DATE '2062-04-01', DATE '2063-03-31', FALSE, NULL);
    SELECT charge_fees_from INTO v_txt FROM academic.academic_years WHERE academic_year_id = v_tmp;
    PERFORM pg_temp.chk_txt('AY-17 NULL charge-fees-from stores AdmissionMonth', v_txt, 'AdmissionMonth');

    -- Overlapping sessions. Two sessions covering the same day make "which
    -- session is this date in" ambiguous (fee months, attendance, admission).
    BEGIN
        v_tmp := pg_temp.yr('SaveAcademicYear', c_tenant, c_school, NULL, 'ZZ Overlap',
                            DATE '2040-10-01', DATE '2041-09-30');
        PERFORM pg_temp.chk('AY-18 session overlapping another session refused', FALSE,
                            format('accepted id=%s (2040-10-01..2041-09-30 overlaps ZZ 2040-41)', v_tmp));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('AY-18 session overlapping another session refused', TRUE, SQLERRM);
    END;

    BEGIN
        v_tmp := pg_temp.yr('SaveAcademicYear', c_tenant, c_school, NULL, 'ZZ Same Dates',
                            DATE '2040-04-01', DATE '2041-03-31');
        PERFORM pg_temp.chk('AY-19 session with identical dates to another refused', FALSE,
                            format('accepted id=%s', v_tmp));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('AY-19 session with identical dates to another refused', TRUE, SQLERRM);
    END;

    BEGIN
        v_tmp := pg_temp.yr('SaveAcademicYear', c_tenant, c_school, NULL, 'ZZ 2041-42',
                            DATE '2041-04-01', DATE '2042-03-31');
        PERFORM pg_temp.chk('AY-20 back-to-back session (no overlap) accepted', v_tmp IS NOT NULL,
                            format('id=%s', v_tmp));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('AY-20 back-to-back session (no overlap) accepted', FALSE, SQLERRM);
    END;

    -- An edit that moves a session's dates onto another session is refused too.
    BEGIN
        PERFORM pg_temp.yr('SaveAcademicYear', c_tenant, c_school, v_tmp, 'ZZ 2041-42',
                           DATE '2041-03-01', DATE '2042-03-31');
        PERFORM pg_temp.chk('AY-18b editing dates onto another session refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('AY-18b editing dates onto another session refused', TRUE, SQLERRM);
    END;

    BEGIN
        PERFORM pg_temp.yr('BogusOp', c_tenant, c_school, NULL);
        PERFORM pg_temp.chk('AY-41 unknown operation refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('AY-41 unknown operation refused', TRUE, SQLERRM);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- B. Current-session switching -------------------------------------';

    PERFORM pg_temp.yr('SetCurrentAcademicYear', c_tenant, c_school, v_y);
    SELECT COUNT(*) INTO v_n FROM pg_temp.years(c_tenant, c_school) WHERE cur;
    PERFORM pg_temp.chk_eq('AY-21 set current: exactly one session is current', v_n, 1);
    SELECT id INTO v_tmp FROM pg_temp.years(c_tenant, c_school) WHERE cur;
    PERFORM pg_temp.chk('AY-21b ...and it is ZZ 2040-41', v_tmp = v_y, format('current id=%s', v_tmp));

    PERFORM pg_temp.yr('SetCurrentAcademicYear', c_tenant, c_school, v_y);
    SELECT COUNT(*) INTO v_n FROM pg_temp.years(c_tenant, c_school) WHERE cur;
    PERFORM pg_temp.chk_eq('AY-22 set current twice is idempotent', v_n, 1);

    SELECT is_current INTO v_ok FROM academic.academic_years WHERE academic_year_id = v_ocur;
    PERFORM pg_temp.chk('AY-23 our switch did not touch the other school''s current', v_ok IS TRUE,
                        format('other school current=%s', v_ok));

    PERFORM pg_temp.yr('SetCurrentAcademicYear', c_tenant, c_school, v_fix_id);
    SELECT id INTO v_tmp FROM pg_temp.years(c_tenant, c_school) WHERE cur;
    PERFORM pg_temp.chk('AY-24 switch back to the original session', v_tmp = v_fix_id,
                        format('current id=%s', v_tmp));

    BEGIN
        PERFORM pg_temp.yr('SetCurrentAcademicYear', c_tenant, c_school, 0);
        PERFORM pg_temp.chk('AY-25 set current with id 0 refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('AY-25 set current with id 0 refused', TRUE, SQLERRM);
    END;

    -- A stale tab: the year was deleted by someone else, then "Set current" is
    -- clicked. The proc clears every current flag first and then sets nothing.
    BEGIN
        PERFORM pg_temp.yr('SetCurrentAcademicYear', c_tenant, c_school, 999999);
        SELECT COUNT(*) INTO v_n FROM academic.academic_years
         WHERE tenant_id = c_tenant AND school_id = c_school AND is_current AND NOT is_deleted;
        PERFORM pg_temp.chk('AY-26 set current on an unknown id is refused, current kept', v_n = 1,
                            format('accepted; school now has %s current session(s)', v_n));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('AY-26 set current on an unknown id is refused, current kept', TRUE, SQLERRM);
    END;
    PERFORM pg_temp.yr('SetCurrentAcademicYear', c_tenant, c_school, v_fix_id);   -- repair

    BEGIN
        PERFORM pg_temp.yr('SetCurrentAcademicYear', c_tenant, c_school, v_oyear);
        SELECT COUNT(*) INTO v_n FROM academic.academic_years
         WHERE tenant_id = c_tenant AND school_id = c_school AND is_current AND NOT is_deleted;
        PERFORM pg_temp.chk('AY-27 set current on another school''s year refused, current kept', v_n = 1,
                            format('accepted; school now has %s current session(s)', v_n));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('AY-27 set current on another school''s year refused, current kept', TRUE, SQLERRM);
    END;
    SELECT COUNT(*) INTO v_n FROM academic.academic_years
     WHERE academic_year_id = v_oyear AND tenant_id = c_otenant AND school_id = c_oschool;
    SELECT is_current INTO v_ok FROM academic.academic_years WHERE academic_year_id = v_ocur;
    PERFORM pg_temp.chk('AY-27b the other school''s sessions were not modified',
                        v_n = 1 AND v_ok IS TRUE, format('other current still current=%s', v_ok));
    PERFORM pg_temp.yr('SetCurrentAcademicYear', c_tenant, c_school, v_fix_id);   -- repair

    -- Creating a session ticked "Set as current" moves the flag.
    v_y2 := pg_temp.yr('SaveAcademicYear', c_tenant, c_school, NULL, 'ZZ 2064-65',
                       DATE '2064-04-01', DATE '2065-03-31', TRUE, 'AdmissionMonth');
    SELECT COUNT(*) INTO v_n FROM pg_temp.years(c_tenant, c_school) WHERE cur;
    SELECT id INTO v_tmp FROM pg_temp.years(c_tenant, c_school) WHERE cur;
    PERFORM pg_temp.chk('AY-28 creating a session as current moves the flag to it',
                        v_n = 1 AND v_tmp = v_y2, format('%s current, id=%s', v_n, v_tmp));

    -- Editing a NON-current session with the box unticked leaves current alone.
    PERFORM pg_temp.yr('SaveAcademicYear', c_tenant, c_school, v_y, 'ZZ 2040-41',
                       DATE '2040-04-01', DATE '2041-03-31', FALSE, 'SessionStart');
    SELECT id INTO v_tmp FROM pg_temp.years(c_tenant, c_school) WHERE cur;
    PERFORM pg_temp.chk('AY-29 editing a non-current session keeps the current one', v_tmp = v_y2,
                        format('current id=%s', v_tmp));

    -- Editing THE current session and unticking "Set as current" would leave
    -- the school with no current session; every proc that defaults to the
    -- current session would then get NULL. It is refused.
    BEGIN
        PERFORM pg_temp.yr('SaveAcademicYear', c_tenant, c_school, v_y2, 'ZZ 2064-65',
                           DATE '2064-04-01', DATE '2065-03-31', FALSE, 'AdmissionMonth');
        PERFORM pg_temp.chk('AY-30 unticking current on the current session refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('AY-30 unticking current on the current session refused', TRUE, SQLERRM);
    END;
    SELECT COUNT(*) INTO v_n FROM academic.academic_years
     WHERE tenant_id = c_tenant AND school_id = c_school AND is_current AND NOT is_deleted;
    PERFORM pg_temp.chk_eq('AY-30b ...and the school still has exactly one current session', v_n, 1);

    -- Editing a session with "Set as current" ticked moves the flag to it.
    PERFORM pg_temp.yr('SaveAcademicYear', c_tenant, c_school, v_fix_id, v_fix_name,
                       (SELECT start_date FROM academic.academic_years WHERE academic_year_id = v_fix_id)::date,
                       (SELECT end_date   FROM academic.academic_years WHERE academic_year_id = v_fix_id)::date,
                       TRUE,
                       (SELECT charge_fees_from FROM academic.academic_years WHERE academic_year_id = v_fix_id));
    SELECT COUNT(*) INTO v_n FROM pg_temp.years(c_tenant, c_school) WHERE cur;
    SELECT id INTO v_tmp FROM pg_temp.years(c_tenant, c_school) WHERE cur;
    PERFORM pg_temp.chk('AY-31 editing with "current" ticked makes it the only current',
                        v_n = 1 AND v_tmp = v_fix_id, format('%s current, id=%s', v_n, v_tmp));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- C. Edit / rename / charge-fees-from guard -------------------------';

    PERFORM pg_temp.yr('SaveAcademicYear', c_tenant, c_school, v_y2, 'ZZ 2064-2065',
                       DATE '2064-06-01', DATE '2065-05-31', FALSE, 'SessionStart');
    SELECT * INTO v_rec FROM pg_temp.years(c_tenant, c_school) WHERE id = v_y2;
    PERFORM pg_temp.chk('AY-32 edit: name, dates and charge-from all saved',
                        v_rec.name = 'ZZ 2064-2065' AND v_rec.sd = '2064-06-01'
                        AND v_rec.ed = '2065-05-31' AND v_rec.charge = 'SessionStart',
                        format('%s %s..%s %s', v_rec.name, v_rec.sd, v_rec.ed, v_rec.charge));
    SELECT COUNT(*) INTO v_n FROM academic.academic_years
     WHERE tenant_id = c_tenant AND school_id = c_school AND academic_year_name IN ('ZZ 2064-65','ZZ 2064-2065');
    PERFORM pg_temp.chk_eq('AY-32b edit updated in place (no second row)', v_n, 1);

    v_tmp := pg_temp.yr('SaveAcademicYear', c_tenant, c_school, v_y2, 'ZZ 2064-2065',
                        DATE '2064-06-01', DATE '2065-05-31', FALSE, 'SessionStart');
    SELECT COUNT(*) INTO v_n FROM academic.academic_years
     WHERE tenant_id = c_tenant AND school_id = c_school AND academic_year_name = 'ZZ 2064-2065';
    PERFORM pg_temp.chk('AY-33 re-saving unchanged is idempotent (same id, one row)',
                        v_tmp = v_y2 AND v_n = 1, format('id=%s rows=%s', v_tmp, v_n));

    BEGIN
        PERFORM pg_temp.yr('SaveAcademicYear', c_tenant, c_school, v_y2, upper(v_fix_name),
                           DATE '2064-06-01', DATE '2065-05-31', FALSE, 'SessionStart');
        PERFORM pg_temp.chk('AY-34 renaming onto another session''s name refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('AY-34 renaming onto another session''s name refused', TRUE, SQLERRM);
    END;

    PERFORM pg_temp.yr('SaveAcademicYear', c_tenant, c_school, v_y2, 'zz 2064-2065',
                       DATE '2064-06-01', DATE '2065-05-31', FALSE, 'SessionStart');
    SELECT academic_year_name INTO v_txt FROM academic.academic_years WHERE academic_year_id = v_y2;
    PERFORM pg_temp.chk_txt('AY-35 a case-only rename of itself is allowed', v_txt, 'zz 2064-2065');

    -- Editing an id that does not exist (deleted in another tab).
    BEGIN
        v_tmp := pg_temp.yr('SaveAcademicYear', c_tenant, c_school, 999999, 'ZZ Ghost',
                            DATE '2066-04-01', DATE '2067-03-31', FALSE, 'AdmissionMonth');
        PERFORM pg_temp.chk('AY-36 editing an unknown id is refused, not reported saved', FALSE,
                            format('reported success, id=%s', COALESCE(v_tmp::text,'NULL')));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('AY-36 editing an unknown id is refused, not reported saved', TRUE, SQLERRM);
    END;

    -- ...and the same with "Set as current" ticked: the flag is cleared first.
    BEGIN
        PERFORM pg_temp.yr('SaveAcademicYear', c_tenant, c_school, 999999, 'ZZ Ghost',
                           DATE '2066-04-01', DATE '2067-03-31', TRUE, 'AdmissionMonth');
        SELECT COUNT(*) INTO v_n FROM academic.academic_years
         WHERE tenant_id = c_tenant AND school_id = c_school AND is_current AND NOT is_deleted;
        PERFORM pg_temp.chk('AY-37 editing an unknown id as current keeps the current session', v_n = 1,
                            format('school now has %s current session(s)', v_n));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('AY-37 editing an unknown id as current keeps the current session', TRUE, SQLERRM);
    END;
    PERFORM pg_temp.yr('SetCurrentAcademicYear', c_tenant, c_school, v_fix_id);   -- repair

    -- Another school's id through our scope: their row must not change.
    BEGIN
        PERFORM pg_temp.yr('SaveAcademicYear', c_tenant, c_school, v_oyear, 'ZZ Hijack',
                           DATE '2068-04-01', DATE '2069-03-31', FALSE, 'AdmissionMonth');
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    SELECT COUNT(*) INTO v_n FROM academic.academic_years
     WHERE academic_year_id = v_oyear AND academic_year_name = 'ZZ Hijack';
    PERFORM pg_temp.chk_eq('AY-38 another school''s session cannot be edited', v_n, 0);

    -- Charge-fees-from is frozen once a session has students.
    SELECT COUNT(*) INTO v_n FROM core.students
     WHERE tenant_id = c_tenant AND school_id = c_school AND academic_year = v_fix_name
       AND COALESCE(is_active, TRUE);
    IF v_n = 0 THEN
        PERFORM pg_temp.admit('ZZ-YC-FIX', (SELECT class_name FROM academic.academic_classes
                               WHERE academic_year_id = v_fix_id AND NOT is_deleted ORDER BY display_order LIMIT 1),
                               NULL, v_fix_name);
    END IF;
    SELECT charge_fees_from INTO v_txt FROM academic.academic_years WHERE academic_year_id = v_fix_id;
    BEGIN
        PERFORM pg_temp.yr('SaveAcademicYear', c_tenant, c_school, v_fix_id, v_fix_name,
                           (SELECT start_date FROM academic.academic_years WHERE academic_year_id = v_fix_id)::date,
                           (SELECT end_date   FROM academic.academic_years WHERE academic_year_id = v_fix_id)::date,
                           TRUE, CASE WHEN v_txt = 'SessionStart' THEN 'AdmissionMonth' ELSE 'SessionStart' END);
        PERFORM pg_temp.chk('AY-39 charge-from change refused once students are admitted', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('AY-39 charge-from change refused once students are admitted', TRUE, SQLERRM);
    END;

    -- Changing only the dates of a session with students is allowed (same charge-from).
    BEGIN
        PERFORM pg_temp.yr('SaveAcademicYear', c_tenant, c_school, v_fix_id, v_fix_name,
                           (SELECT start_date FROM academic.academic_years WHERE academic_year_id = v_fix_id)::date,
                           (SELECT end_date   FROM academic.academic_years WHERE academic_year_id = v_fix_id)::date - 1,
                           TRUE, v_txt);
        PERFORM pg_temp.chk('AY-39b date fix on a session with students allowed', TRUE, '');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('AY-39b date fix on a session with students allowed', FALSE, SQLERRM);
    END;

    -- Charge-from change on a session with NO students is allowed.
    PERFORM pg_temp.yr('SaveAcademicYear', c_tenant, c_school, v_y, 'ZZ 2040-41',
                       DATE '2040-04-01', DATE '2041-03-31', FALSE, 'AdmissionMonth');
    SELECT charge_fees_from INTO v_txt FROM academic.academic_years WHERE academic_year_id = v_y;
    PERFORM pg_temp.chk_txt('AY-39c charge-from change on an empty session saved', v_txt, 'AdmissionMonth');

    -- A past session whose students were promoted out still has their fee
    -- plans: the lock must not lift just because core.students moved on.
    DECLARE v_py integer; v_pk integer;
    BEGIN
        v_py := pg_temp.yr('SaveAcademicYear', c_tenant, c_school, NULL, 'ZZ Promo',
                           DATE '2084-04-01', DATE '2085-03-31', FALSE, 'AdmissionMonth');
        PERFORM pg_temp.save_setup(c_tenant, c_school, v_py,
            '[{"className":"ZZ-P1","displayOrder":1,"sections":[{"sectionName":"A"}]}]');
        v_pk := pg_temp.admit('ZZ-YC-PRO', 'ZZ-P1', 'A', 'ZZ Promo');
        UPDATE core.students SET academic_year = 'ZZ 2041-42' WHERE student_id = v_pk;   -- promoted
        SELECT students INTO v_n FROM pg_temp.years(c_tenant, c_school) WHERE id = v_py;
        PERFORM pg_temp.chk_eq('AY-39d a promoted-out session still counts its student', v_n, 1);
        BEGIN
            PERFORM pg_temp.yr('SaveAcademicYear', c_tenant, c_school, v_py, 'ZZ Promo',
                               DATE '2084-04-01', DATE '2085-03-31', FALSE, 'SessionStart');
            PERFORM pg_temp.chk('AY-39e charge-from stays locked after the students are promoted', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('AY-39e charge-from stays locked after the students are promoted', TRUE, SQLERRM);
        END;
    END;
    PERFORM pg_temp.yr('SaveAcademicYear', c_tenant, c_school, v_y, 'ZZ 2040-41',
                       DATE '2040-04-01', DATE '2041-03-31', FALSE, 'SessionStart');

    -- ── The rename chain. students.academic_year (and fee structures, the
    -- enrolment history, attendance) hold the session NAME. Rename the session
    -- and every one of them silently detaches -- and the guards that count
    -- them by name stop protecting anything.
    DECLARE v_ry integer; v_kid integer;
    BEGIN
        v_ry := pg_temp.yr('SaveAcademicYear', c_tenant, c_school, NULL, 'ZZ Rename',
                           DATE '2070-04-01', DATE '2071-03-31', FALSE, 'AdmissionMonth');
        PERFORM pg_temp.save_setup(c_tenant, c_school, v_ry,
            '[{"className":"ZZ-R1","displayOrder":1,"sections":[{"sectionName":"A","capacity":40}]}]');
        v_kid := pg_temp.admit('ZZ-YC-REN', 'ZZ-R1', 'A', 'ZZ Rename');
        SELECT students INTO v_n FROM pg_temp.years(c_tenant, c_school) WHERE id = v_ry;
        PERFORM pg_temp.chk_eq('AY-42 a child admitted into ZZ Rename is counted', v_n, 1);

        -- Refused, not cascaded: nine tables keep the name, counters would
        -- restart numbering, and printed receipts/TCs carry the old name.
        BEGIN
            PERFORM pg_temp.yr('SaveAcademicYear', c_tenant, c_school, v_ry, 'ZZ Renamed',
                               DATE '2070-04-01', DATE '2071-03-31', FALSE, 'AdmissionMonth');
            PERFORM pg_temp.chk('AY-43 renaming a session that students use is refused', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('AY-43 renaming a session that students use is refused', TRUE, SQLERRM);
        END;
        BEGIN
            PERFORM pg_temp.yr('SaveAcademicYear', c_tenant, c_school, v_ry, 'zz rename',
                               DATE '2070-04-01', DATE '2071-03-31', FALSE, 'AdmissionMonth');
            PERFORM pg_temp.chk('AY-43b a case-only rename of a used session is refused too', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('AY-43b a case-only rename of a used session is refused too', TRUE, SQLERRM);
        END;
        SELECT students INTO v_n FROM pg_temp.years(c_tenant, c_school) WHERE id = v_ry;
        SELECT academic_year INTO v_txt FROM core.students WHERE student_id = v_kid;
        PERFORM pg_temp.chk('AY-43c ...the child stays attached to the session', v_n = 1 AND v_txt = 'ZZ Rename',
                            format('session counts %s student(s); child says "%s"', v_n, v_txt));
        PERFORM pg_temp.yr('SaveAcademicYear', c_tenant, c_school, v_ry, 'ZZ Rename',
                           DATE '2070-05-01', DATE '2071-04-30', FALSE, 'AdmissionMonth');
        SELECT sd INTO v_txt FROM pg_temp.years(c_tenant, c_school) WHERE id = v_ry;
        PERFORM pg_temp.chk_txt('AY-43d ...but its dates can still be fixed', v_txt, '2070-05-01');

        BEGIN
            PERFORM pg_temp.save_setup(c_tenant, c_school, v_ry, '[]');
            PERFORM pg_temp.chk('AY-44 the used session''s child''s class is still protected', FALSE,
                                'class with an enrolled child was removed');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('AY-44 the used session''s child''s class is still protected', TRUE, SQLERRM);
        END;

        BEGIN
            PERFORM pg_temp.yr('DeleteAcademicYear', c_tenant, c_school, v_ry);
            PERFORM pg_temp.chk('AY-45 the used session cannot be deleted', FALSE,
                                'session deleted while a child is still in it');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('AY-45 the used session cannot be deleted', TRUE, SQLERRM);
        END;
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- D. Delete guards ---------------------------------------------------';

    v_tmp := pg_temp.yr('SaveAcademicYear', c_tenant, c_school, NULL, 'ZZ Delete Me',
                        DATE '2072-04-01', DATE '2073-03-31');
    PERFORM pg_temp.yr('DeleteAcademicYear', c_tenant, c_school, v_tmp);
    SELECT is_deleted AND NOT is_current AND NOT is_active INTO v_ok
      FROM academic.academic_years WHERE academic_year_id = v_tmp;
    PERFORM pg_temp.chk('AY-46 empty session deleted (soft: is_deleted, inactive, not current)', v_ok IS TRUE, '');
    SELECT COUNT(*) INTO v_n FROM pg_temp.years(c_tenant, c_school) WHERE id = v_tmp;
    PERFORM pg_temp.chk_eq('AY-46b ...and it is gone from the list', v_n, 0);

    BEGIN
        PERFORM pg_temp.yr('DeleteAcademicYear', c_tenant, c_school, v_tmp);
        PERFORM pg_temp.chk('AY-47 deleting an already-deleted session changes nothing', TRUE, '');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('AY-47 deleting an already-deleted session changes nothing', TRUE, SQLERRM);
    END;

    -- The year the school just deleted by mistake is typed in again.
    BEGIN
        v_n := pg_temp.yr('SaveAcademicYear', c_tenant, c_school, NULL, 'ZZ Delete Me',
                          DATE '2072-04-01', DATE '2073-03-31');
        PERFORM pg_temp.chk('AY-48 a deleted session''s name can be created again', v_n IS NOT NULL,
                            format('id=%s', v_n));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('AY-48 a deleted session''s name can be created again', FALSE, SQLERRM);
    END;

    BEGIN
        PERFORM pg_temp.yr('DeleteAcademicYear', c_tenant, c_school, v_fix_id);
        PERFORM pg_temp.chk('AY-49 session with classes and students cannot be deleted', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('AY-49 session with classes and students cannot be deleted', TRUE, SQLERRM);
    END;

    DECLARE v_cy integer;
    BEGIN
        v_cy := pg_temp.yr('SaveAcademicYear', c_tenant, c_school, NULL, 'ZZ Classes Only',
                           DATE '2074-04-01', DATE '2075-03-31');
        PERFORM pg_temp.save_setup(c_tenant, c_school, v_cy,
            '[{"className":"ZZ-C1","displayOrder":1,"sections":[{"sectionName":"A"}]}]');
        BEGIN
            PERFORM pg_temp.yr('DeleteAcademicYear', c_tenant, c_school, v_cy);
            PERFORM pg_temp.chk('AY-50 session with classes (no students) cannot be deleted', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('AY-50 session with classes (no students) cannot be deleted', TRUE, SQLERRM);
        END;
    END;

    BEGIN
        PERFORM pg_temp.yr('DeleteAcademicYear', c_tenant, c_school, NULL);
        PERFORM pg_temp.chk('AY-51 delete with no id refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('AY-51 delete with no id refused', TRUE, SQLERRM);
    END;

    BEGIN
        PERFORM pg_temp.yr('DeleteAcademicYear', c_tenant, c_school, 999999);
        PERFORM pg_temp.chk('AY-52 deleting an unknown id is refused, not reported deleted', FALSE,
                            'reported "Academic year deleted."');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('AY-52 deleting an unknown id is refused, not reported deleted', TRUE, SQLERRM);
    END;

    BEGIN
        PERFORM pg_temp.yr('DeleteAcademicYear', c_tenant, c_school, v_oyear);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    SELECT COUNT(*) INTO v_n FROM academic.academic_years WHERE academic_year_id = v_oyear AND NOT is_deleted;
    PERFORM pg_temp.chk_eq('AY-53 another school''s session cannot be deleted', v_n, 1);

    -- Deleting the CURRENT session leaves the school with none.
    DECLARE v_cd integer;
    BEGIN
        v_cd := pg_temp.yr('SaveAcademicYear', c_tenant, c_school, NULL, 'ZZ Cur Del',
                           DATE '2076-04-01', DATE '2077-03-31', TRUE);
        BEGIN
            PERFORM pg_temp.yr('DeleteAcademicYear', c_tenant, c_school, v_cd);
            SELECT COUNT(*) INTO v_n FROM academic.academic_years
             WHERE tenant_id = c_tenant AND school_id = c_school AND is_current AND NOT is_deleted;
            PERFORM pg_temp.chk('AY-54 the current session cannot be deleted', FALSE,
                                format('deleted; school now has %s current session(s)', v_n));
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('AY-54 the current session cannot be deleted', TRUE, SQLERRM);
        END;
    END;
    PERFORM pg_temp.yr('SetCurrentAcademicYear', c_tenant, c_school, v_fix_id);   -- repair

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- E. Classes & sections: build, read-back, validation, guards -------';

    -- Sunrise's ladder for ZZ 2040-41: Nursery..X, XI in two streams (same
    -- rank), XII Science; sections A/B/C, 40 seats each, a room per section.
    SELECT jsonb_agg(jsonb_build_object(
               'className', n, 'displayOrder', o, 'stream', st,
               'sections', (SELECT jsonb_agg(jsonb_build_object('sectionName', s, 'capacity', 40,
                                                                'roomNo', n || '-' || s) ORDER BY s)
                            FROM unnest(ARRAY['A','B','C']) s))
           ORDER BY o, n)
      INTO v_j
    FROM (VALUES ('Nursery',1,'gen'),('LKG',2,'gen'),('UKG',3,'gen'),
                 ('I',4,'gen'),('II',5,'gen'),('III',6,'gen'),('IV',7,'gen'),('V',8,'gen'),
                 ('VI',9,'gen'),('VII',10,'gen'),('VIII',11,'gen'),('IX',12,'gen'),('X',13,'gen'),
                 ('XI Science (PCM)',14,'pcm'),('XI Commerce',14,'com'),('XII Science (PCM)',15,'pcm')) v(n,o,st);

    v_j := jsonb_set(v_j, '{0,coordinatorStaffId}', '23');                  -- Nursery: linked staff
    v_j := jsonb_set(v_j, '{0,coordinator}', '"typed over"');
    v_j := jsonb_set(v_j, '{3,coordinator}', '"Mrs. Rao"');                 -- I: free text only
    v_j := jsonb_set(v_j, '{4,coordinatorStaffId}', '33');                  -- II: other school's staff
    v_j := jsonb_set(v_j, '{4,coordinator}', '"Spoof"');
    v_j := jsonb_set(v_j, '{5,sections}',                                   -- III: order C, A, B
           '[{"sectionName":"C","capacity":35,"roomNo":"III-C"},{"sectionName":"A","capacity":null,"roomNo":null},{"sectionName":"B","capacity":45,"roomNo":"  "}]');
    v_j := jsonb_set(v_j, '{6,className}', '"  IV  "');                     -- padded names
    v_j := jsonb_set(v_j, '{6,sections,0,sectionName}', '" A "');

    v_ok := pg_temp.save_setup(c_tenant, c_school, v_y, v_j);
    PERFORM pg_temp.chk('CS-01 the full ladder saves', v_ok IS TRUE, '');

    SELECT COUNT(DISTINCT cls), COUNT(*) INTO v_n, v_n2 FROM pg_temp.setup(c_tenant, c_school, v_y);
    PERFORM pg_temp.chk('CS-01b read-back: 16 classes, 48 sections', v_n = 16 AND v_n2 = 48,
                        format('%s classes, %s sections', v_n, v_n2));
    SELECT classes INTO v_n FROM pg_temp.years(c_tenant, c_school) WHERE id = v_y;
    PERFORM pg_temp.chk_eq('CS-01c Academic Years page counts the classes', v_n, 16);

    SELECT COUNT(DISTINCT (cls, cls_ord)) INTO v_n FROM pg_temp.setup(c_tenant, c_school, v_y)
     WHERE (cls, cls_ord) IN (('Nursery',1),('XI Commerce',14),('XI Science (PCM)',14),('XII Science (PCM)',15));
    PERFORM pg_temp.chk_eq('CS-02 rank stored as display order; two XI streams share rank 14', v_n, 4);

    SELECT string_agg(cls, ',' ORDER BY rn) INTO v_txt FROM (
        SELECT cls, row_number() OVER () rn FROM (SELECT DISTINCT ON (cls_ord, cls) cls, cls_ord
        FROM pg_temp.setup(c_tenant, c_school, v_y) ORDER BY cls_ord, cls) q) z;
    PERFORM pg_temp.chk('CS-03 classes come back in rank order', v_txt LIKE 'Nursery,LKG,UKG,I,II,III,IV,V,%,X,XI Commerce,XI Science (PCM),XII Science (PCM)', v_txt);

    SELECT stream INTO v_txt FROM pg_temp.setup(c_tenant, c_school, v_y) WHERE cls = 'XI Commerce' LIMIT 1;
    PERFORM pg_temp.chk_txt('CS-04 stream round-trips', v_txt, 'com');

    SELECT coord, coord_id INTO v_rec FROM pg_temp.setup(c_tenant, c_school, v_y) WHERE cls = 'Nursery' LIMIT 1;
    PERFORM pg_temp.chk('CS-05 linked coordinator: staff id kept, name taken from staff row',
                        v_rec.coord_id = 23 AND v_rec.coord = (SELECT full_name FROM core.staff WHERE staff_id = 23),
                        format('%s / %s', v_rec.coord_id, v_rec.coord));
    SELECT coord, coord_id INTO v_rec FROM pg_temp.setup(c_tenant, c_school, v_y) WHERE cls = 'I' LIMIT 1;
    PERFORM pg_temp.chk('CS-06 free-text coordinator without staff id kept',
                        v_rec.coord = 'Mrs. Rao' AND v_rec.coord_id IS NULL, format('%s / %s', v_rec.coord_id, v_rec.coord));
    SELECT coord, coord_id INTO v_rec FROM pg_temp.setup(c_tenant, c_school, v_y) WHERE cls = 'II' LIMIT 1;
    PERFORM pg_temp.chk('CS-07 another school''s staff as coordinator is dropped',
                        v_rec.coord_id IS NULL AND v_rec.coord IS NULL, format('%s / %s', v_rec.coord_id, v_rec.coord));

    SELECT string_agg(sec || '=' || sec_ord, ',' ORDER BY sec_ord) INTO v_txt
      FROM pg_temp.setup(c_tenant, c_school, v_y) WHERE cls = 'III';
    PERFORM pg_temp.chk_txt('CS-08 section order follows the order posted', v_txt, 'C=1,A=2,B=3');
    SELECT string_agg(concat_ws('/', sec, cap, COALESCE(room,'<null>')), ',' ORDER BY sec_ord) INTO v_txt
      FROM pg_temp.setup(c_tenant, c_school, v_y) WHERE cls = 'III';
    PERFORM pg_temp.chk_txt('CS-09 capacity and room round-trip; blank capacity/room stored as NULL',
                            v_txt, 'C/35/III-C,A/<null>,B/45/<null>');

    SELECT COUNT(*) INTO v_n FROM pg_temp.setup(c_tenant, c_school, v_y) WHERE cls = 'IV' AND sec = 'A';
    PERFORM pg_temp.chk_eq('CS-10 class and section names are trimmed', v_n, 1);

    -- Blank names are skipped by the proc (the controller refuses them first).
    PERFORM pg_temp.save_setup(c_tenant, c_school, v_y,
        v_j || '[{"className":"   ","displayOrder":20,"sections":[{"sectionName":"A"}]}]'::jsonb);
    SELECT COUNT(DISTINCT cls) INTO v_n FROM pg_temp.setup(c_tenant, c_school, v_y);
    PERFORM pg_temp.chk_eq('CS-11 a blank class name is not saved', v_n, 16);
    PERFORM pg_temp.save_setup(c_tenant, c_school, v_y,
        jsonb_set(v_j, '{7,sections}', '[{"sectionName":"A"},{"sectionName":"  "}]'));
    SELECT COUNT(*) INTO v_n FROM pg_temp.setup(c_tenant, c_school, v_y) WHERE cls = 'V';
    PERFORM pg_temp.chk_eq('CS-12 a blank section name is not saved', v_n, 1);
    PERFORM pg_temp.save_setup(c_tenant, c_school, v_y, v_j);              -- back to the ladder

    BEGIN
        PERFORM pg_temp.save_setup(c_tenant, c_school, v_y,
            v_j || '[{"className":"nursery","displayOrder":30,"sections":[{"sectionName":"A"}]}]'::jsonb);
        PERFORM pg_temp.chk('CS-13 two classes with the same name (any case) refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CS-13 two classes with the same name (any case) refused', TRUE, SQLERRM);
    END;

    BEGIN
        PERFORM pg_temp.save_setup(c_tenant, c_school, v_y,
            jsonb_set(v_j, '{7,sections}', '[{"sectionName":"A"},{"sectionName":"a"}]'));
        PERFORM pg_temp.chk('CS-14 two sections with the same name in a class refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CS-14 two sections with the same name in a class refused', TRUE, SQLERRM);
    END;

    SELECT COUNT(*) INTO v_n FROM pg_temp.setup(c_tenant, c_school, v_y) WHERE sec = 'A';
    PERFORM pg_temp.chk_eq('CS-15 the same section name in different classes is fine', v_n, 16);

    BEGIN
        PERFORM pg_temp.save_setup(c_tenant, c_school, v_y,
            jsonb_set(v_j, '{7,className}', to_jsonb(repeat('V', 51))));
        PERFORM pg_temp.chk('CS-16 51-character class name refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CS-16 51-character class name refused', TRUE, SQLERRM);
    END;
    BEGIN
        PERFORM pg_temp.save_setup(c_tenant, c_school, v_y,
            jsonb_set(v_j, '{7,sections,0,sectionName}', to_jsonb(repeat('S', 21))));
        PERFORM pg_temp.chk('CS-17 21-character section name refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CS-17 21-character section name refused', TRUE, SQLERRM);
    END;
    BEGIN
        PERFORM pg_temp.save_setup(c_tenant, c_school, v_y,
            jsonb_set(v_j, '{7,sections,0,roomNo}', to_jsonb(repeat('R', 51))));
        PERFORM pg_temp.chk('CS-18 51-character room refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CS-18 51-character room refused', TRUE, SQLERRM);
    END;
    BEGIN
        PERFORM pg_temp.save_setup(c_tenant, c_school, v_y,
            jsonb_set(v_j, '{7,coordinator}', to_jsonb(repeat('C', 151))));
        PERFORM pg_temp.chk('CS-19 151-character coordinator refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CS-19 151-character coordinator refused', TRUE, SQLERRM);
    END;

    v_ok := pg_temp.save_setup(c_tenant, c_school, v_y,
        v_j || jsonb_build_array(jsonb_build_object('className', repeat('M', 50), 'displayOrder', 40,
               'coordinator', repeat('C', 150),
               'sections', jsonb_build_array(jsonb_build_object('sectionName', repeat('S', 20),
                                                               'roomNo', repeat('R', 50), 'capacity', 5000)))));
    SELECT COUNT(*) INTO v_n FROM pg_temp.setup(c_tenant, c_school, v_y)
     WHERE cls = repeat('M', 50) AND sec = repeat('S', 20) AND room = repeat('R', 50) AND cap = 5000
       AND coord = repeat('C', 150);
    PERFORM pg_temp.chk_eq('CS-20 maximum lengths (50/20/50/150) and capacity 5000 accepted', v_n, 1);

    v_ok := pg_temp.save_setup(c_tenant, c_school, v_y,
        v_j || '[{"className":"Rose – \"Red\" & <Lily>","displayOrder":41,"sections":[{"sectionName":"O''Hara","roomNo":"<b>1</b>"}]}]'::jsonb);
    SELECT COUNT(*) INTO v_n FROM pg_temp.setup(c_tenant, c_school, v_y)
     WHERE cls = 'Rose – "Red" & <Lily>' AND sec = 'O''Hara' AND room = '<b>1</b>';
    PERFORM pg_temp.chk_eq('CS-21 special characters in class/section/room stored verbatim', v_n, 1);

    -- The controller limits capacity to 1..5000; the proc and table do not.
    BEGIN
        PERFORM pg_temp.save_setup(c_tenant, c_school, v_y,
            jsonb_set(v_j, '{7,sections,0,capacity}', '-5'));
        PERFORM pg_temp.chk('CS-22 negative capacity refused by the database layer', FALSE,
                            'stored capacity -5 (only the controller checks the range)');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CS-22 negative capacity refused by the database layer', TRUE, SQLERRM);
    END;
    BEGIN
        PERFORM pg_temp.save_setup(c_tenant, c_school, v_y,
            jsonb_set(v_j, '{7,sections,0,capacity}', '0'));
        PERFORM pg_temp.chk('CS-22b capacity 0 refused by the database layer', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CS-22b capacity 0 refused by the database layer', TRUE, SQLERRM);
    END;

    BEGIN
        PERFORM pg_temp.save_setup(c_tenant, c_school, v_y, '{"not":"an array"}'::jsonb);
        PERFORM pg_temp.chk('CS-23 a payload that is not an array refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CS-23 a payload that is not an array refused', TRUE, SQLERRM);
    END;
    BEGIN
        c := 'bad_json';
        CALL academic.sp_school_admin_academic_setup_manage('SaveAcademicSetup', c_tenant, c_school, c_user,
             v_y, NULL, '[{"className": "X"', c);
        PERFORM pg_temp.chk('CS-24 malformed JSON refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CS-24 malformed JSON refused', TRUE, SQLERRM);
    END;

    -- Back to the clean ladder and prove a re-save changes nothing visible.
    PERFORM pg_temp.save_setup(c_tenant, c_school, v_y, v_j);
    v_txt := pg_temp.fp(c_tenant, c_school, v_y);
    PERFORM pg_temp.save_setup(c_tenant, c_school, v_y, pg_temp.cur_json(c_tenant, c_school, v_y));
    v_txt2 := pg_temp.fp(c_tenant, c_school, v_y);
    PERFORM pg_temp.chk('CS-25 re-saving the page unchanged is idempotent (every field)', v_txt = v_txt2,
                        format('%s chars before, %s after', length(v_txt), length(v_txt2)));
    SELECT COUNT(*) INTO v_n FROM academic.academic_classes
     WHERE academic_year_id = v_y AND NOT is_deleted;
    PERFORM pg_temp.chk_eq('CS-25b ...and leaves exactly 16 live classes', v_n, 16);

    -- The class teacher is assigned on another page; a save here must keep it.
    UPDATE academic.academic_class_sections s SET class_teacher_staff_id = 23
      FROM academic.academic_classes c
     WHERE c.academic_class_id = s.academic_class_id AND c.academic_year_id = v_y
       AND NOT c.is_deleted AND NOT s.is_deleted AND c.class_name = 'I' AND s.section_name = 'A';
    PERFORM pg_temp.save_setup(c_tenant, c_school, v_y,
        pg_temp.j_section(pg_temp.cur_json(c_tenant, c_school, v_y), 'II', 'C', 'Rose'));
    SELECT ct INTO v_tmp FROM pg_temp.setup(c_tenant, c_school, v_y) WHERE cls = 'I' AND sec = 'A';
    PERFORM pg_temp.chk_eq('CS-26 a save elsewhere keeps the class teacher of I-A', v_tmp, 23);
    SELECT COUNT(*) INTO v_n FROM pg_temp.setup(c_tenant, c_school, v_y) WHERE cls = 'II' AND sec = 'Rose';
    PERFORM pg_temp.chk_eq('CS-27 renaming an empty section (II-C -> II-Rose) works', v_n, 1);

    -- Remove an unused class: everything else stays as it was.
    v_txt := pg_temp.fp(c_tenant, c_school, v_y);
    PERFORM pg_temp.save_setup(c_tenant, c_school, v_y,
        pg_temp.j_drop_class(pg_temp.cur_json(c_tenant, c_school, v_y), 'UKG'));
    SELECT COUNT(DISTINCT cls) INTO v_n FROM pg_temp.setup(c_tenant, c_school, v_y);
    SELECT COUNT(*) INTO v_n2 FROM pg_temp.setup(c_tenant, c_school, v_y) WHERE cls = 'UKG';
    PERFORM pg_temp.chk('CS-28 removing an unused class (UKG) works', v_n2 = 0, format('%s classes left', v_n));
    v_txt2 := pg_temp.fp(c_tenant, c_school, v_y);
    PERFORM pg_temp.chk('CS-28b ...and no other class or section changed',
                        v_txt2 = (SELECT string_agg(p, ';' ORDER BY o) FROM unnest(string_to_array(v_txt, ';')) WITH ORDINALITY u(p, o)
                                  WHERE p NOT LIKE 'UKG|%'),
                        '');

    -- Sunrise admits a child into IV-A.
    v_sid := pg_temp.admit('ZZ-YC-IVA', 'IV', 'A', 'ZZ 2040-41');
    SELECT strength INTO v_n FROM pg_temp.setup(c_tenant, c_school, v_y) WHERE cls = 'IV' AND sec = 'A';
    PERFORM pg_temp.chk_eq('CS-29 the child shows in IV-A strength', v_n, 1);
    SELECT students INTO v_n FROM pg_temp.years(c_tenant, c_school) WHERE id = v_y;
    PERFORM pg_temp.chk_eq('CS-29b ...and in the session''s student count', v_n, 1);

    v_j := pg_temp.cur_json(c_tenant, c_school, v_y);
    BEGIN
        PERFORM pg_temp.save_setup(c_tenant, c_school, v_y, pg_temp.j_section(v_j, 'IV', 'A', NULL));
        PERFORM pg_temp.chk('CS-30 removing a section with a child in it refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CS-30 removing a section with a child in it refused', TRUE, SQLERRM);
    END;
    BEGIN
        PERFORM pg_temp.save_setup(c_tenant, c_school, v_y, pg_temp.j_section(v_j, 'IV', 'A', 'Alpha'));
        PERFORM pg_temp.chk('CS-31 renaming a section with a child in it refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CS-31 renaming a section with a child in it refused', TRUE, SQLERRM);
    END;
    BEGIN
        PERFORM pg_temp.save_setup(c_tenant, c_school, v_y, pg_temp.j_rename_class(v_j, 'IV', 'Class 4'));
        PERFORM pg_temp.chk('CS-32 renaming a class with a child in it refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CS-32 renaming a class with a child in it refused', TRUE, SQLERRM);
    END;
    BEGIN
        PERFORM pg_temp.save_setup(c_tenant, c_school, v_y, pg_temp.j_rename_class(v_j, 'IV', 'iv'));
        PERFORM pg_temp.chk('CS-33 a case-only rename of a class with a child refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CS-33 a case-only rename of a class with a child refused', TRUE, SQLERRM);
    END;
    BEGIN
        PERFORM pg_temp.save_setup(c_tenant, c_school, v_y, pg_temp.j_drop_class(v_j, 'IV'));
        PERFORM pg_temp.chk('CS-34 removing the whole class with a child in it refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CS-34 removing the whole class with a child in it refused', TRUE, SQLERRM);
    END;
    SELECT COUNT(*) INTO v_n FROM pg_temp.setup(c_tenant, c_school, v_y) WHERE cls = 'IV' AND sec = 'A';
    PERFORM pg_temp.chk_eq('CS-35 IV-A is still there after the refusals', v_n, 1);

    PERFORM pg_temp.save_setup(c_tenant, c_school, v_y, pg_temp.j_section(v_j, 'IV', 'C', NULL));
    SELECT string_agg(sec, ',' ORDER BY sec) INTO v_txt FROM pg_temp.setup(c_tenant, c_school, v_y) WHERE cls = 'IV';
    PERFORM pg_temp.chk_txt('CS-36 an empty section next to the child''s can be removed', v_txt, 'A,B');

    -- Rank / coordinator / room / capacity edits on the child's class are fine.
    v_j := pg_temp.cur_json(c_tenant, c_school, v_y);
    v_j := (SELECT jsonb_agg(CASE WHEN e->>'className' = 'IV'
                 THEN jsonb_set(jsonb_set(e, '{displayOrder}', '70'), '{sections,0,roomNo}', '"Hall"')
                 ELSE e END ORDER BY o) FROM jsonb_array_elements(v_j) WITH ORDINALITY x(e, o));
    PERFORM pg_temp.save_setup(c_tenant, c_school, v_y, v_j);
    SELECT cls_ord || '/' || room INTO v_txt FROM pg_temp.setup(c_tenant, c_school, v_y) WHERE cls = 'IV' AND sec = 'A';
    PERFORM pg_temp.chk_txt('CS-37 rank and room of a class with a child can change', v_txt, '70/Hall');

    -- Renames keep the id. Class VI (no students) has a fee structure and a
    -- subject; section I-A has a class teacher (CS-26) and a timetable slot.
    DECLARE v_cid int; v_cid2 int; v_secid int; v_secid2 int; v_subj int;
    BEGIN
        SELECT subject_id INTO v_subj FROM academic.school_subjects
         WHERE tenant_id = c_tenant AND school_id = c_school ORDER BY subject_id LIMIT 1;
        SELECT academic_class_id INTO v_cid FROM academic.academic_classes
         WHERE academic_year_id = v_y AND class_name = 'VI' AND NOT is_deleted;
        INSERT INTO core.school_fee_structures (tenant_id, school_id, class_name, academic_year, created_by)
        VALUES (c_tenant, c_school, 'VI', 'ZZ 2040-41', c_user);
        INSERT INTO academic.class_subjects (tenant_id, school_id, academic_year_id, academic_class_id,
                                             subject_id, display_order, created_by)
        VALUES (c_tenant, c_school, v_y, v_cid, v_subj, 1, c_user);

        PERFORM pg_temp.save_setup(c_tenant, c_school, v_y,
            pg_temp.j_rename_class(pg_temp.cur_json(c_tenant, c_school, v_y), 'VI', 'Class 6'));
        SELECT academic_class_id INTO v_cid2 FROM academic.academic_classes
         WHERE academic_year_id = v_y AND class_name = 'Class 6' AND NOT is_deleted;
        PERFORM pg_temp.chk('CS-79 renaming a class (VI -> Class 6) keeps its id', v_cid2 = v_cid,
                            format('id %s -> %s', v_cid, v_cid2));
        SELECT COUNT(*) INTO v_n FROM core.school_fee_structures
         WHERE tenant_id = c_tenant AND school_id = c_school AND academic_year = 'ZZ 2040-41' AND class_name = 'Class 6';
        SELECT COUNT(*) INTO v_n2 FROM core.school_fee_structures
         WHERE tenant_id = c_tenant AND school_id = c_school AND academic_year = 'ZZ 2040-41' AND class_name = 'VI';
        PERFORM pg_temp.chk('CS-79b ...and carries the name into the session''s fee structure', v_n = 1 AND v_n2 = 0,
                            format('Class 6: %s, VI: %s', v_n, v_n2));
        SELECT COUNT(*) INTO v_n FROM academic.class_subjects cs
          JOIN academic.academic_classes c ON c.academic_class_id = cs.academic_class_id
         WHERE c.academic_class_id = v_cid AND NOT c.is_deleted;
        PERFORM pg_temp.chk_eq('CS-79c ...and its subject stays mapped', v_n, 1);

        BEGIN
            PERFORM pg_temp.save_setup(c_tenant, c_school, v_y,
                pg_temp.j_rename_class(pg_temp.cur_json(c_tenant, c_school, v_y), 'Class 6', 'Class 6 With A Really Long Name X'));
            PERFORM pg_temp.chk('CS-79d rename past the fee structure''s 30 characters refused', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('CS-79d rename past the fee structure''s 30 characters refused',
                                pg_temp.readable(SQLERRM), SQLERRM);
        END;

        SELECT s.academic_class_section_id INTO v_secid FROM academic.academic_class_sections s
          JOIN academic.academic_classes c ON c.academic_class_id = s.academic_class_id
         WHERE c.academic_year_id = v_y AND NOT c.is_deleted AND NOT s.is_deleted
           AND c.class_name = 'I' AND s.section_name = 'A';
        INSERT INTO academic.timetable (tenant_id, school_id, academic_year_id, academic_class_section_id,
                                        day_of_week, period_seq, subject_id, created_by)
        VALUES (c_tenant, c_school, v_y, v_secid, 2, 3, v_subj, c_user);

        PERFORM pg_temp.save_setup(c_tenant, c_school, v_y,
            pg_temp.j_section(pg_temp.cur_json(c_tenant, c_school, v_y), 'I', 'A', 'Alpha'));
        SELECT s.academic_class_section_id INTO v_secid2 FROM academic.academic_class_sections s
          JOIN academic.academic_classes c ON c.academic_class_id = s.academic_class_id
         WHERE c.academic_year_id = v_y AND NOT c.is_deleted AND NOT s.is_deleted
           AND c.class_name = 'I' AND s.section_name = 'Alpha';
        PERFORM pg_temp.chk('CS-80 renaming an empty section (I-A -> I-Alpha) keeps its id', v_secid2 = v_secid,
                            format('id %s -> %s', v_secid, v_secid2));
        SELECT ct INTO v_tmp FROM pg_temp.setup(c_tenant, c_school, v_y) WHERE cls = 'I' AND sec = 'Alpha';
        PERFORM pg_temp.chk_eq('CS-80b ...keeps its class teacher', v_tmp, 23);
        SELECT COUNT(*) INTO v_n FROM academic.timetable t
          JOIN academic.academic_class_sections s ON s.academic_class_section_id = t.academic_class_section_id
         WHERE s.academic_class_section_id = v_secid AND NOT s.is_deleted;
        PERFORM pg_temp.chk_eq('CS-80c ...and keeps its timetable', v_n, 1);
    END;

    -- A child who LEFT mid-session is not on the roll and does not block.
    UPDATE core.student_enrolment SET status = 'Left' WHERE student_id = v_sid;
    BEGIN
        PERFORM pg_temp.save_setup(c_tenant, c_school, v_y, pg_temp.j_section(v_j, 'IV', 'A', NULL));
        PERFORM pg_temp.chk('CS-38 a section whose only child has Left can be removed', TRUE, '');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CS-38 a section whose only child has Left can be removed', FALSE, SQLERRM);
    END;

    -- Scope of the year itself.
    BEGIN
        PERFORM pg_temp.save_setup(c_tenant, c_school, v_oyear,
            '[{"className":"ZZ Hijack","displayOrder":1,"sections":[{"sectionName":"A"}]}]');
        PERFORM pg_temp.chk('CS-39 saving classes into another school''s session refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CS-39 saving classes into another school''s session refused', TRUE, SQLERRM);
    END;
    SELECT COUNT(*) INTO v_n FROM academic.academic_classes WHERE class_name = 'ZZ Hijack';
    PERFORM pg_temp.chk_eq('CS-39b ...and nothing was written', v_n, 0);

    SELECT COUNT(*) INTO v_n FROM pg_temp.setup(c_tenant, c_school, v_oyear);
    PERFORM pg_temp.chk_eq('CS-41 reading another school''s session returns nothing', v_n, 0);

    -- A deleted session should not take a structure.
    v_tmp := pg_temp.yr('SaveAcademicYear', c_tenant, c_school, NULL, 'ZZ Dead Year',
                        DATE '2078-04-01', DATE '2079-03-31');
    PERFORM pg_temp.yr('DeleteAcademicYear', c_tenant, c_school, v_tmp);
    BEGIN
        PERFORM pg_temp.save_setup(c_tenant, c_school, v_tmp,
            '[{"className":"ZZ Ghost Class","displayOrder":1,"sections":[{"sectionName":"A"}]}]');
        PERFORM pg_temp.chk('CS-42 saving classes into a deleted session refused', FALSE,
                            'classes written into a deleted session');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CS-42 saving classes into a deleted session refused', TRUE, SQLERRM);
    END;

    BEGIN
        PERFORM pg_temp.save_setup(c_tenant, c_school, 0, '[]');
        PERFORM pg_temp.chk('CS-43 saving with no session refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CS-43 saving with no session refused', TRUE, SQLERRM);
    END;

    -- Re-entrancy: the proc used to create a temp table ON COMMIT DROP, so a
    -- second save in the same transaction died with "already exists".
    c := 'reent1';
    CALL academic.sp_school_admin_academic_setup_manage('SaveAcademicSetup', c_tenant, c_school, c_user,
         v_y, NULL, pg_temp.cur_json(c_tenant, c_school, v_y)::text, c);
    CLOSE c;
    BEGIN
        c := 'reent2';
        CALL academic.sp_school_admin_academic_setup_manage('SaveAcademicSetup', c_tenant, c_school, c_user,
             v_y, NULL, pg_temp.cur_json(c_tenant, c_school, v_y)::text, c);
        CLOSE c;
        PERFORM pg_temp.chk('CS-40 two saves in one transaction both work', TRUE, '');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CS-40 two saves in one transaction both work', FALSE, SQLERRM);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- F. Downstream impact of a Classes & Sections save -----------------';

    -- Subjects (class_subjects), exam papers (exam_subjects) and the timetable
    -- all hang off academic_class_id / academic_class_section_id. The save is
    -- delete-all + re-insert, so every save mints new ids. Take the REAL
    -- current session and press Save without changing anything.
    DECLARE v_cs0 int; v_cs1 int; v_es0 int; v_es1 int; v_tt0 int; v_tt1 int; v_sec int; v_subj int;
    BEGIN
        SELECT s.academic_class_section_id INTO v_sec
          FROM academic.academic_class_sections s
          JOIN academic.academic_classes c ON c.academic_class_id = s.academic_class_id
         WHERE c.academic_year_id = v_fix_id AND NOT c.is_deleted AND NOT s.is_deleted
         ORDER BY c.display_order, s.display_order LIMIT 1;
        SELECT subject_id INTO v_subj FROM academic.school_subjects
         WHERE tenant_id = c_tenant AND school_id = c_school ORDER BY subject_id LIMIT 1;
        IF v_subj IS NULL THEN
            INSERT INTO academic.school_subjects (tenant_id, school_id, subject_name, created_by, created_at)
            VALUES (c_tenant, c_school, 'ZZ Maths', c_user, now()) RETURNING subject_id INTO v_subj;
        END IF;
        -- A timetable slot and a class subject, the way their pages would write them.
        INSERT INTO academic.timetable (tenant_id, school_id, academic_year_id, academic_class_section_id,
                                        day_of_week, period_seq, subject_id, created_by)
        VALUES (c_tenant, c_school, v_fix_id, v_sec, 1, 1, v_subj, c_user);
        INSERT INTO academic.class_subjects (tenant_id, school_id, academic_year_id, academic_class_id,
                                             subject_id, display_order, created_by)
        SELECT c_tenant, c_school, v_fix_id, s.academic_class_id, v_subj, 99, c_user
          FROM academic.academic_class_sections s WHERE s.academic_class_section_id = v_sec
        ON CONFLICT DO NOTHING;

        SELECT COUNT(*) INTO v_cs0 FROM academic.class_subjects cs
          JOIN academic.academic_classes c ON c.academic_class_id = cs.academic_class_id
         WHERE c.academic_year_id = v_fix_id AND NOT c.is_deleted;
        SELECT COUNT(*) INTO v_es0 FROM academic.exam_subjects es
          JOIN academic.academic_classes c ON c.academic_class_id = es.academic_class_id
         WHERE c.tenant_id = c_tenant AND c.school_id = c_school AND c.academic_year_id = v_fix_id AND NOT c.is_deleted;
        SELECT COUNT(*) INTO v_tt0 FROM academic.timetable t
          JOIN academic.academic_class_sections s ON s.academic_class_section_id = t.academic_class_section_id
         WHERE s.academic_year_id = v_fix_id AND NOT s.is_deleted;

        v_txt := pg_temp.fp(c_tenant, c_school, v_fix_id);
        PERFORM pg_temp.save_setup(c_tenant, c_school, v_fix_id, pg_temp.cur_json(c_tenant, c_school, v_fix_id));
        PERFORM pg_temp.chk('CS-44 unchanged re-save of the live session keeps the visible structure',
                            v_txt = pg_temp.fp(c_tenant, c_school, v_fix_id), '');

        SELECT COUNT(*) INTO v_cs1 FROM academic.class_subjects cs
          JOIN academic.academic_classes c ON c.academic_class_id = cs.academic_class_id
         WHERE c.academic_year_id = v_fix_id AND NOT c.is_deleted;
        SELECT COUNT(*) INTO v_es1 FROM academic.exam_subjects es
          JOIN academic.academic_classes c ON c.academic_class_id = es.academic_class_id
         WHERE c.tenant_id = c_tenant AND c.school_id = c_school AND c.academic_year_id = v_fix_id AND NOT c.is_deleted;
        SELECT COUNT(*) INTO v_tt1 FROM academic.timetable t
          JOIN academic.academic_class_sections s ON s.academic_class_section_id = t.academic_class_section_id
         WHERE s.academic_year_id = v_fix_id AND NOT s.is_deleted;

        PERFORM pg_temp.chk('CS-45 a save keeps every class''s subject mapping', v_cs1 = v_cs0,
                            format('class subjects on live classes: %s before, %s after', v_cs0, v_cs1));
        PERFORM pg_temp.chk('CS-46 a save keeps every exam paper attached to its class', v_es1 = v_es0,
                            format('exam subjects on live classes: %s before, %s after', v_es0, v_es1));
        PERFORM pg_temp.chk('CS-47 a save keeps the timetable attached to its section', v_tt1 = v_tt0,
                            format('timetable slots on live sections: %s before, %s after', v_tt0, v_tt1));
    END;

    -- Students hold class/section by NAME; an unchanged save keeps them matched.
    SELECT COUNT(*) INTO v_n FROM core.student_enrolment en
     WHERE en.tenant_id = c_tenant AND en.school_id = c_school AND en.academic_year = v_fix_name
       AND en.status <> 'Left'
       AND NOT EXISTS (SELECT 1 FROM academic.academic_classes c
                       JOIN academic.academic_class_sections s ON s.academic_class_id = c.academic_class_id
                       WHERE c.academic_year_id = v_fix_id AND NOT c.is_deleted AND NOT s.is_deleted
                         AND c.class_name = en.class_name AND s.section_name = en.section);
    PERFORM pg_temp.chk_eq('CS-48 every enrolled child still matches a live class+section', v_n, 0);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- G. Copy structure from the previous session ------------------------';

    DECLARE v_new integer; v_src_fp text; v_dst_fp text;
    BEGIN
        v_new := pg_temp.yr('SaveAcademicYear', c_tenant, c_school, NULL, 'ZZ 2027-28',
                            DATE '2027-04-01', DATE '2028-03-31');
        v_r := pg_temp.info(c_tenant, c_school, v_new);
        PERFORM pg_temp.chk('CS-49 structure info: a new session has 0 classes, 0 sections',
                            (v_r->>'class_count')::int = 0 AND (v_r->>'section_count')::int = 0, v_r::text);
        PERFORM pg_temp.chk('CS-50 structure info offers the closest EARLIER session with classes',
                            (v_r->>'source_year_id')::int = v_fix_id,
                            format('offered %s (%s), expected %s', v_r->>'source_year_id', v_r->>'source_year_name', v_fix_id));

        v_r := pg_temp.info(c_tenant, c_school, v_fix_id);
        PERFORM pg_temp.chk('CS-51 structure info counts the live session''s classes and sections',
                            (v_r->>'class_count')::int = (SELECT COUNT(*) FROM academic.academic_classes
                                                           WHERE academic_year_id = v_fix_id AND NOT is_deleted)
                            AND (v_r->>'section_count')::int = (SELECT COUNT(*) FROM academic.academic_class_sections
                                                           WHERE academic_year_id = v_fix_id AND NOT is_deleted),
                            v_r::text);
        PERFORM pg_temp.chk('CS-52 a later session (ZZ 2040-41) is never offered as the source for an earlier one',
                            (v_r->>'source_year_id')::int <> v_y, v_r::text);

        v_r := pg_temp.clone(c_tenant, c_school, v_fix_id, v_new);
        v_src_fp := (SELECT string_agg(concat_ws('|', cls, cls_ord, stream, coord, coord_id, sec, sec_ord, cap, room), ';'
                                       ORDER BY cls_ord, cls, sec_ord, sec) FROM pg_temp.setup(c_tenant, c_school, v_fix_id));
        v_dst_fp := (SELECT string_agg(concat_ws('|', cls, cls_ord, stream, coord, coord_id, sec, sec_ord, cap, room), ';'
                                       ORDER BY cls_ord, cls, sec_ord, sec) FROM pg_temp.setup(c_tenant, c_school, v_new));
        PERFORM pg_temp.chk('CS-53 copy reports what it copied',
                            (v_r->>'success')::boolean AND (v_r->>'classes_copied')::int > 0, v_r->>'message');
        PERFORM pg_temp.chk('CS-54 the copy matches the source (names, ranks, streams, capacity, rooms)',
                            v_src_fp = v_dst_fp, '');
        SELECT COUNT(*) INTO v_n FROM pg_temp.setup(c_tenant, c_school, v_new) WHERE ct IS NOT NULL;
        PERFORM pg_temp.chk_eq('CS-55 class teachers are not copied into the new session', v_n, 0);

        BEGIN
            PERFORM pg_temp.clone(c_tenant, c_school, v_fix_id, v_new);
            PERFORM pg_temp.chk('CS-56 copying into a session that already has classes refused', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('CS-56 copying into a session that already has classes refused', TRUE, SQLERRM);
        END;

        -- The copy is independent: editing it leaves the source alone.
        PERFORM pg_temp.save_setup(c_tenant, c_school, v_new,
            pg_temp.cur_json(c_tenant, c_school, v_new) || '[{"className":"ZZ Only In Copy","displayOrder":90,"sections":[{"sectionName":"A"}]}]'::jsonb);
        SELECT COUNT(*) INTO v_n FROM pg_temp.setup(c_tenant, c_school, v_fix_id) WHERE cls = 'ZZ Only In Copy';
        PERFORM pg_temp.chk_eq('CS-57 editing the copy does not touch the source session', v_n, 0);
        v_r := pg_temp.info(c_tenant, c_school, v_new);
        PERFORM pg_temp.chk('CS-58 once it has classes, the copy banner condition (class_count = 0) is off',
                            (v_r->>'class_count')::int > 0, v_r::text);
    END;

    BEGIN
        PERFORM pg_temp.clone(c_tenant, c_school, v_fix_id, v_fix_id);
        PERFORM pg_temp.chk('CS-59 copying a session onto itself refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CS-59 copying a session onto itself refused', TRUE, SQLERRM);
    END;
    BEGIN
        PERFORM pg_temp.clone(c_tenant, c_school, 0, v_y);
        PERFORM pg_temp.chk('CS-60 copying with a missing source refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CS-60 copying with a missing source refused', TRUE, SQLERRM);
    END;

    DECLARE v_e1 integer; v_e2 integer;
    BEGIN
        v_e1 := pg_temp.yr('SaveAcademicYear', c_tenant, c_school, NULL, 'ZZ Empty Src',
                           DATE '2080-04-01', DATE '2081-03-31');
        v_e2 := pg_temp.yr('SaveAcademicYear', c_tenant, c_school, NULL, 'ZZ Empty Dst',
                           DATE '2082-04-01', DATE '2083-03-31');
        BEGIN
            PERFORM pg_temp.clone(c_tenant, c_school, v_e1, v_e2);
            PERFORM pg_temp.chk('CS-61 copying from a session with no classes refused', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('CS-61 copying from a session with no classes refused', TRUE, SQLERRM);
        END;
        BEGIN
            PERFORM pg_temp.clone(c_tenant, c_school, v_oyear, v_e2);
            PERFORM pg_temp.chk('CS-62 copying FROM another school''s session refused', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('CS-62 copying FROM another school''s session refused', TRUE, SQLERRM);
        END;
        BEGIN
            PERFORM pg_temp.clone(c_tenant, c_school, v_fix_id, v_oyear);
            PERFORM pg_temp.chk('CS-63 copying INTO another school''s session refused', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('CS-63 copying INTO another school''s session refused', TRUE, SQLERRM);
        END;
        SELECT COUNT(*) INTO v_n FROM academic.academic_classes
         WHERE academic_year_id = v_oyear AND tenant_id = c_tenant;
        PERFORM pg_temp.chk_eq('CS-63b ...nothing of ours landed in their session', v_n, 0);
    END;

    v_r := pg_temp.info(c_tenant, c_school, v_oyear);
    PERFORM pg_temp.chk('CS-64 structure info for another school''s session is empty',
                        (v_r->>'academic_year_id')::int = 0 AND (v_r->>'class_count')::int = 0, v_r::text);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- H. Year dropdown follows the mutations ----------------------------';

    SELECT COUNT(*) INTO v_n FROM pg_temp.dd(c_tenant, c_school) WHERE code = v_y::text AND name = 'ZZ 2040-41';
    PERFORM pg_temp.chk_eq('AY-55 a new session appears in the year dropdown', v_n, 1);
    SELECT code INTO v_txt FROM pg_temp.dd(c_tenant, c_school) WHERE sel;
    PERFORM pg_temp.chk_txt('AY-56 the dropdown marks the current session selected', v_txt, v_fix_id::text);
    SELECT code INTO v_txt FROM pg_temp.dd(c_tenant, c_school) LIMIT 1;
    PERFORM pg_temp.chk_txt('AY-57 the current session is listed first', v_txt, v_fix_id::text);
    SELECT COUNT(*) INTO v_n FROM pg_temp.dd(c_tenant, c_school) WHERE name = 'ZZ Dead Year';
    PERFORM pg_temp.chk_eq('AY-58 a deleted session is not in the dropdown', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM pg_temp.dd(c_tenant, c_school) WHERE code = v_oyear::text;
    PERFORM pg_temp.chk_eq('AY-59 another school''s sessions are not in our dropdown', v_n, 0);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- S. Scope -----------------------------------------------------------';

    BEGIN
        PERFORM pg_temp.yr('SaveAcademicYear', 1, 1, NULL, 'ZZ Platform', DATE '2090-04-01', DATE '2091-03-31');
        PERFORM pg_temp.chk('AY-60 tenant 1 (platform) cannot save a session', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('AY-60 tenant 1 (platform) cannot save a session', TRUE, SQLERRM);
    END;
    BEGIN
        PERFORM pg_temp.yr('SaveAcademicYear', c_tenant, 0, NULL, 'ZZ NoSchool', DATE '2090-04-01', DATE '2091-03-31');
        PERFORM pg_temp.chk('AY-61 school 0 cannot save a session', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('AY-61 school 0 cannot save a session', TRUE, SQLERRM);
    END;
    BEGIN
        PERFORM * FROM pg_temp.years(1, 0);
        PERFORM pg_temp.chk('AY-62 tenant 1 cannot list sessions', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('AY-62 tenant 1 cannot list sessions', TRUE, SQLERRM);
    END;
    BEGIN
        PERFORM pg_temp.yr('SetCurrentAcademicYear', 1, 0, v_fix_id);
        PERFORM pg_temp.chk('AY-63 tenant 1 cannot set the current session', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('AY-63 tenant 1 cannot set the current session', TRUE, SQLERRM);
    END;
    BEGIN
        PERFORM pg_temp.yr('DeleteAcademicYear', 1, 0, v_y);
        PERFORM pg_temp.chk('AY-64 tenant 1 cannot delete a session', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('AY-64 tenant 1 cannot delete a session', TRUE, SQLERRM);
    END;
    BEGIN
        PERFORM pg_temp.save_setup(1, 0, v_y, '[]');
        PERFORM pg_temp.chk('CS-65 tenant 1 cannot save classes', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CS-65 tenant 1 cannot save classes', TRUE, SQLERRM);
    END;
    BEGIN
        PERFORM * FROM pg_temp.setup(c_tenant, 0, v_y);
        PERFORM pg_temp.chk('CS-66 school 0 cannot read classes', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CS-66 school 0 cannot read classes', TRUE, SQLERRM);
    END;
    BEGIN
        PERFORM pg_temp.clone(1, 0, v_fix_id, v_y);
        PERFORM pg_temp.chk('CS-67 tenant 1 cannot copy a structure', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CS-67 tenant 1 cannot copy a structure', TRUE, SQLERRM);
    END;
    v_r := pg_temp.info(1, 0, v_y);
    PERFORM pg_temp.chk('CS-68 tenant 1 structure info returns no row', v_r IS NULL OR v_r = '{}'::jsonb,
                        COALESCE(v_r::text, 'no row'));

    SELECT COUNT(*) INTO v_n FROM pg_temp.years(c_tenant, c_school) y
     WHERE y.id IN (SELECT academic_year_id FROM academic.academic_years WHERE school_id <> c_school);
    PERFORM pg_temp.chk_eq('AY-65 our list never shows another school''s session', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM pg_temp.years(c_otenant, c_oschool) WHERE name LIKE 'ZZ 20%' AND name <> 'ZZ 2040-41';
    PERFORM pg_temp.chk_eq('AY-66 the other school''s list shows none of our sessions', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM academic.academic_classes
     WHERE (tenant_id <> c_tenant OR school_id <> c_school)
       AND academic_year_id IN (SELECT academic_year_id FROM academic.academic_years
                                WHERE tenant_id = c_tenant AND school_id = c_school);
    PERFORM pg_temp.chk_eq('CS-69 no class row of another school points at our sessions', v_n, 0);
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
