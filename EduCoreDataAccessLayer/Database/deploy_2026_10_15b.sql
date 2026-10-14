-- Bundle 2026-10-15b: copy class subjects / class teachers / timetable into a new session; a session is made current only after it is set up and every student was promoted into it. Run with:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_15b.sql
-- Sources (re-runnable): academic_session_rollover.sql, academic_year_class_section_fixes.sql

-- ============================================================================
-- Session rollover — carrying the academic structure into a new session.
--
-- Classes and sections are per-session rows (academic_year_id on both tables),
-- so a brand new session starts completely empty. Nothing else in that session
-- is usable until its structure exists: promotion has no ladder to walk, the
-- class/section pickers are blank, and a student written into it points at a
-- class that does not exist.
--
-- Creating that structure by hand for every session is what schools skip, so
-- this copies it forward in one step — the same "copy setup from the previous
-- session" step every school ERP does before it promotes anyone.
--
--   academic.sp_academic_year_structure_info   does this session have structure
--   academic.sp_academic_year_clone            copy classes + sections forward
-- ============================================================================


-- ── is this session ready? ─────────────────────────────────────────────────
-- Answers "does this session have classes, and if not, what could we copy
-- from". Callers pass whichever they hold: the Classes & Sections page has the
-- year id, the Promotion page only has the year name.
--
-- The suggested source is the closest EARLIER session that actually has
-- classes — the one an admin would pick by hand anyway.
DROP PROCEDURE IF EXISTS academic.sp_academic_year_structure_info(integer, integer, integer, integer, character varying, refcursor);

CREATE OR REPLACE PROCEDURE academic.sp_academic_year_structure_info(
    IN  p_tenant_id         integer,
    IN  p_school_id         integer,
    IN  p_action_user_id    integer,
    IN  p_academic_year_id   integer          DEFAULT NULL,
    IN  p_academic_year_name character varying DEFAULT NULL,
    INOUT p_result           refcursor        DEFAULT 'structure_info_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_year_id    integer;
    v_year_name  varchar;
    v_start      date;
    v_classes    integer := 0;
    v_sections   integer := 0;
    v_src_id     integer;
    v_src_name   varchar;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        OPEN p_result FOR SELECT WHERE FALSE;
        RETURN;
    END IF;

    SELECT academic_year_id, academic_year_name, start_date
    INTO   v_year_id, v_year_name, v_start
    FROM   academic.academic_years
    WHERE  tenant_id = p_tenant_id
      AND  school_id = p_school_id
      AND  COALESCE(is_deleted, FALSE) = FALSE
      AND  (   (COALESCE(p_academic_year_id, 0) > 0 AND academic_year_id = p_academic_year_id)
            OR (COALESCE(p_academic_year_id, 0) = 0
                AND academic_year_name = TRIM(COALESCE(p_academic_year_name, ''))))
    LIMIT 1;

    IF v_year_id IS NULL THEN
        OPEN p_result FOR
        SELECT 0 AS academic_year_id, ''::varchar AS academic_year_name,
               0 AS class_count, 0 AS section_count,
               0 AS source_year_id, ''::varchar AS source_year_name;
        RETURN;
    END IF;

    SELECT COUNT(DISTINCT ac.academic_class_id),
           COUNT(acs.academic_class_section_id)
    INTO   v_classes, v_sections
    FROM   academic.academic_classes ac
    LEFT JOIN academic.academic_class_sections acs
           ON acs.academic_class_id = ac.academic_class_id
          AND COALESCE(acs.is_deleted, FALSE) = FALSE
          AND COALESCE(acs.is_active,  TRUE)  = TRUE
    WHERE  ac.tenant_id = p_tenant_id
      AND  ac.school_id = p_school_id
      AND  ac.academic_year_id = v_year_id
      AND  COALESCE(ac.is_deleted, FALSE) = FALSE
      AND  COALESCE(ac.is_active,  TRUE)  = TRUE;

    -- Closest earlier session that has something worth copying. start_date is
    -- the real ordering; academic_year_id only breaks ties.
    SELECT ay.academic_year_id, ay.academic_year_name
    INTO   v_src_id, v_src_name
    FROM   academic.academic_years ay
    WHERE  ay.tenant_id = p_tenant_id
      AND  ay.school_id = p_school_id
      AND  ay.academic_year_id <> v_year_id
      AND  COALESCE(ay.is_deleted, FALSE) = FALSE
      AND  (v_start IS NULL OR ay.start_date IS NULL OR ay.start_date::date < v_start)
      AND  EXISTS (
               SELECT 1 FROM academic.academic_classes ac
               WHERE ac.tenant_id = p_tenant_id
                 AND ac.school_id = p_school_id
                 AND ac.academic_year_id = ay.academic_year_id
                 AND COALESCE(ac.is_deleted, FALSE) = FALSE
                 AND COALESCE(ac.is_active,  TRUE)  = TRUE)
    ORDER BY ay.start_date DESC NULLS LAST, ay.academic_year_id DESC
    LIMIT 1;

    OPEN p_result FOR
    SELECT v_year_id                   AS academic_year_id,
           v_year_name                 AS academic_year_name,
           v_classes                   AS class_count,
           v_sections                  AS section_count,
           COALESCE(v_src_id, 0)       AS source_year_id,
           COALESCE(v_src_name, '')    AS source_year_name;
    RETURN;
END;
$procedure$;


-- ── copy the structure forward ─────────────────────────────────────────────
-- Copies classes (with display_order, stream, coordinator), their sections
-- (with display_order, capacity, room) and each class's subjects from one
-- session into another. Without the subjects the new session has no exams,
-- timetable, homework or report cards.
--
-- The class teacher is deliberately NOT copied: staff change between sessions
-- and it is assigned on its own page. Strength is derived from core.students,
-- so there is nothing to copy there either.
--
-- Refuses to run when the target already has classes rather than merging —
-- merging would silently double a structure that was half set up by hand.
DROP PROCEDURE IF EXISTS academic.sp_academic_year_clone(integer, integer, integer, integer, integer, refcursor);

CREATE OR REPLACE PROCEDURE academic.sp_academic_year_clone(
    IN  p_tenant_id           integer,
    IN  p_school_id           integer,
    IN  p_action_user_id      integer,
    IN  p_from_academic_year_id integer,
    IN  p_to_academic_year_id   integer,
    INOUT p_result              refcursor DEFAULT 'year_clone_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    c            record;
    v_from_name  varchar;
    v_to_name    varchar;
    v_new_class  integer;
    v_copied_sec integer;
    v_classes    integer := 0;
    v_sections   integer := 0;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    IF COALESCE(p_from_academic_year_id, 0) <= 0 OR COALESCE(p_to_academic_year_id, 0) <= 0 THEN
        RAISE EXCEPTION 'Choose the session to copy from and the session to copy into.';
    END IF;

    IF p_from_academic_year_id = p_to_academic_year_id THEN
        RAISE EXCEPTION 'Choose two different sessions.';
    END IF;

    SELECT academic_year_name INTO v_from_name
    FROM   academic.academic_years
    WHERE  academic_year_id = p_from_academic_year_id
      AND  tenant_id = p_tenant_id AND school_id = p_school_id
      AND  COALESCE(is_deleted, FALSE) = FALSE;

    SELECT academic_year_name INTO v_to_name
    FROM   academic.academic_years
    WHERE  academic_year_id = p_to_academic_year_id
      AND  tenant_id = p_tenant_id AND school_id = p_school_id
      AND  COALESCE(is_deleted, FALSE) = FALSE;

    IF v_from_name IS NULL OR v_to_name IS NULL THEN
        RAISE EXCEPTION 'One of the sessions does not belong to this school.';
    END IF;

    IF EXISTS (
        SELECT 1 FROM academic.academic_classes
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND academic_year_id = p_to_academic_year_id
          AND COALESCE(is_deleted, FALSE) = FALSE
    ) THEN
        RAISE EXCEPTION 'Session % already has classes. Remove them first if you want to copy % over it.', v_to_name, v_from_name;
    END IF;

    FOR c IN
        SELECT academic_class_id, class_name, display_order, stream, coordinator, coordinator_staff_id
        FROM   academic.academic_classes
        WHERE  tenant_id = p_tenant_id
          AND  school_id = p_school_id
          AND  academic_year_id = p_from_academic_year_id
          AND  COALESCE(is_deleted, FALSE) = FALSE
          AND  COALESCE(is_active,  TRUE)  = TRUE
        ORDER BY display_order, academic_class_id
    LOOP
        INSERT INTO academic.academic_classes
            (tenant_id, school_id, academic_year_id, class_name, display_order,
             stream, coordinator, coordinator_staff_id,
             created_by, created_at, is_deleted, is_active)
        VALUES
            (p_tenant_id, p_school_id, p_to_academic_year_id, c.class_name, c.display_order,
             c.stream, c.coordinator, c.coordinator_staff_id,
             p_action_user_id, NOW(), FALSE, TRUE)
        RETURNING academic_class_id INTO v_new_class;

        v_classes := v_classes + 1;

        INSERT INTO academic.academic_class_sections
            (tenant_id, school_id, academic_year_id, academic_class_id, section_name,
             display_order, capacity, room_no,
             created_by, created_at, is_deleted, is_active)
        SELECT p_tenant_id, p_school_id, p_to_academic_year_id, v_new_class, acs.section_name,
               acs.display_order, acs.capacity, acs.room_no,
               p_action_user_id, NOW(), FALSE, TRUE
        FROM   academic.academic_class_sections acs
        WHERE  acs.academic_class_id = c.academic_class_id
          AND  COALESCE(acs.is_deleted, FALSE) = FALSE
          AND  COALESCE(acs.is_active,  TRUE)  = TRUE
        ORDER BY acs.display_order, acs.academic_class_section_id;

        GET DIAGNOSTICS v_copied_sec = ROW_COUNT;
        v_sections := v_sections + v_copied_sec;

        -- the class's subjects come along
        INSERT INTO academic.class_subjects
            (tenant_id, school_id, academic_year_id, academic_class_id, subject_id, display_order, created_by)
        SELECT p_tenant_id, p_school_id, p_to_academic_year_id, v_new_class, cs.subject_id, cs.display_order, p_action_user_id
        FROM   academic.class_subjects cs
        WHERE  cs.academic_class_id = c.academic_class_id
        ON CONFLICT DO NOTHING;
    END LOOP;

    IF v_classes = 0 THEN
        RAISE EXCEPTION 'Session % has no classes to copy.', v_from_name;
    END IF;

    OPEN p_result FOR
    SELECT TRUE       AS success,
           v_classes  AS classes_copied,
           v_sections AS sections_copied,
           'Copied ' || v_classes || ' classes and ' || v_sections ||
           ' sections from ' || v_from_name || ' into ' || v_to_name || '.' AS message;
    RETURN;
END;
$procedure$;

-- ── copy the rest of the set-up into a session that already has classes ────
-- For a session whose classes were already copied (or typed in): its classes'
-- subjects, the class teachers and the timetable, from an earlier session.
-- Classes match by class name and sections by section name. Only staff who are
-- still working are copied; a period of someone who left is copied without a
-- teacher. Nothing that is already set in the target is overwritten, so it is
-- safe to run twice.
--   p_subjects / p_teachers / p_timetable choose what to copy.
CREATE OR REPLACE PROCEDURE academic.sp_academic_year_copy_setup(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_from_year_id   integer,
    IN    p_to_year_id     integer,
    IN    p_subjects       boolean DEFAULT TRUE,
    IN    p_teachers       boolean DEFAULT FALSE,
    IN    p_timetable      boolean DEFAULT FALSE,
    INOUT p_result         refcursor DEFAULT 'copy_setup_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_subjects  integer := 0;
    v_teachers  integer := 0;
    v_periods   integer := 0;
    v_from_name varchar;
    v_to_name   varchar;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;
    IF COALESCE(p_from_year_id, 0) <= 0 OR COALESCE(p_to_year_id, 0) <= 0 OR p_from_year_id = p_to_year_id THEN
        RAISE EXCEPTION 'Choose two different sessions.';
    END IF;

    SELECT academic_year_name INTO v_from_name FROM academic.academic_years
     WHERE academic_year_id = p_from_year_id AND tenant_id = p_tenant_id AND school_id = p_school_id;
    SELECT academic_year_name INTO v_to_name FROM academic.academic_years
     WHERE academic_year_id = p_to_year_id AND tenant_id = p_tenant_id AND school_id = p_school_id;
    IF v_from_name IS NULL OR v_to_name IS NULL THEN
        RAISE EXCEPTION 'One of the sessions does not belong to this school.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM academic.academic_classes
                    WHERE academic_year_id = p_to_year_id AND NOT COALESCE(is_deleted, FALSE)) THEN
        RAISE EXCEPTION 'Session % has no classes yet. Copy the classes and sections first.', v_to_name;
    END IF;

    -- Subjects of each class (matched by class name)
    IF p_subjects THEN
        INSERT INTO academic.class_subjects
            (tenant_id, school_id, academic_year_id, academic_class_id, subject_id, display_order, created_by)
        SELECT p_tenant_id, p_school_id, p_to_year_id, nc.academic_class_id, cs.subject_id, cs.display_order, p_action_user_id
          FROM academic.class_subjects cs
          JOIN academic.academic_classes oc ON oc.academic_class_id = cs.academic_class_id
          JOIN academic.academic_classes nc ON nc.tenant_id = oc.tenant_id AND nc.school_id = oc.school_id
                                           AND nc.academic_year_id = p_to_year_id AND nc.class_name = oc.class_name
                                           AND NOT COALESCE(nc.is_deleted, FALSE)
         WHERE cs.tenant_id = p_tenant_id AND cs.school_id = p_school_id AND cs.academic_year_id = p_from_year_id
        ON CONFLICT DO NOTHING;
        GET DIAGNOSTICS v_subjects = ROW_COUNT;
    END IF;

    -- Class teachers (class + section name); only staff still working; only where none is set
    IF p_teachers THEN
        UPDATE academic.academic_class_sections ns
           SET class_teacher_staff_id = os.class_teacher_staff_id, updated_by = p_action_user_id, updated_at = now()
          FROM academic.academic_class_sections os
          JOIN academic.academic_classes oc ON oc.academic_class_id = os.academic_class_id
          JOIN core.staff st ON st.staff_id = os.class_teacher_staff_id
                            AND NOT COALESCE(st.is_deleted, FALSE) AND COALESCE(st.is_active, TRUE)
                            AND COALESCE(st.status, 'Active') <> 'Inactive',
               academic.academic_classes nc
         WHERE os.tenant_id = p_tenant_id AND os.school_id = p_school_id AND os.academic_year_id = p_from_year_id
           AND NOT COALESCE(os.is_deleted, FALSE)
           AND nc.academic_class_id = ns.academic_class_id AND nc.class_name = oc.class_name
           AND ns.academic_year_id = p_to_year_id AND ns.section_name = os.section_name
           AND NOT COALESCE(ns.is_deleted, FALSE) AND ns.class_teacher_staff_id IS NULL;
        GET DIAGNOSTICS v_teachers = ROW_COUNT;
    END IF;

    -- Timetable (class + section name); the period of a teacher who has left is copied without a teacher
    IF p_timetable THEN
        INSERT INTO academic.timetable
            (tenant_id, school_id, academic_year_id, academic_class_section_id, day_of_week, period_seq,
             subject_id, staff_id, room_no, created_by, created_at)
        SELECT p_tenant_id, p_school_id, p_to_year_id, ns.academic_class_section_id, t.day_of_week, t.period_seq,
               t.subject_id,
               CASE WHEN EXISTS (SELECT 1 FROM core.staff st WHERE st.staff_id = t.staff_id
                                    AND NOT COALESCE(st.is_deleted, FALSE) AND COALESCE(st.is_active, TRUE)
                                    AND COALESCE(st.status, 'Active') <> 'Inactive') THEN t.staff_id END,
               t.room_no, p_action_user_id, now()
          FROM academic.timetable t
          JOIN academic.academic_class_sections os ON os.academic_class_section_id = t.academic_class_section_id
          JOIN academic.academic_classes oc ON oc.academic_class_id = os.academic_class_id
          JOIN academic.academic_classes nc ON nc.tenant_id = oc.tenant_id AND nc.school_id = oc.school_id
                                           AND nc.academic_year_id = p_to_year_id AND nc.class_name = oc.class_name
                                           AND NOT COALESCE(nc.is_deleted, FALSE)
          JOIN academic.academic_class_sections ns ON ns.academic_class_id = nc.academic_class_id
                                                  AND ns.section_name = os.section_name
                                                  AND NOT COALESCE(ns.is_deleted, FALSE)
         WHERE t.tenant_id = p_tenant_id AND t.school_id = p_school_id AND t.academic_year_id = p_from_year_id
        ON CONFLICT DO NOTHING;
        GET DIAGNOSTICS v_periods = ROW_COUNT;
    END IF;

    OPEN p_result FOR
    SELECT v_subjects AS subjects, v_teachers AS teachers, v_periods AS periods,
           'Copied from ' || v_from_name || ' into ' || v_to_name || ': '
           || concat_ws(', ',
                CASE WHEN p_subjects  THEN v_subjects || ' class subject(s)' END,
                CASE WHEN p_teachers  THEN v_teachers || ' class teacher(s)' END,
                CASE WHEN p_timetable THEN v_periods  || ' timetable period(s)' END)
           || '. Anything already set was kept.' AS message;
END;
$procedure$;


-- ============================================================================
-- Academic Years + Classes & Sections: correctness fixes.
--
-- Found by tests/settings_years_classes_tests.sql. This script SUPERSEDES the
-- two procedure definitions below:
--   academic.sp_school_admin_academic_year_manage   (was fee_charge_from_per_year.sql)
--   academic.sp_school_admin_academic_setup_manage  (was academic_class_section_fields.sql)
-- Those scripts are not re-run for this change: fee_charge_from_per_year.sql
-- also rewrites the admission-workflow proc and drops a column, and
-- academic_class_section_fields.sql would put the old setup proc back.
--
-- Safe to re-run: every step is CREATE OR REPLACE / IF EXISTS / IF NOT EXISTS.
--
-- WHAT CHANGES
--   Sessions
--   * Name: max 20 characters, start and end dates required, end AFTER start
--     -- refused with a readable message instead of a raw constraint error.
--   * Two sessions of one school can no longer overlap.
--   * Set-current / edit / delete check that the session exists in THIS school
--     first. Before, an unknown id cleared every current flag and then set
--     nothing, leaving the school with no current session.
--   * The current session can not be un-ticked or deleted; another session has
--     to be made current first. A school always has exactly one.
--   * A session can not be renamed once anything stores its name (students,
--     enrolment, fee structures, attendance, transport, TC register, enquiries,
--     admission / registration counters). Those tables hold the NAME, not the
--     id, so a rename silently detached all of them. Refusing is safer than a
--     cascade across nine tables: counters would restart numbering and printed
--     receipts / TCs already carry the old name.
--   * A deleted session's name can be used again (the unique key now ignores
--     deleted rows, as the proc's duplicate check always did).
--   * The charge-fees-from lock and the student count also count the session's
--     enrolment history, so promoting students out does not unlock it.
--   Classes & Sections
--   * Save updates classes and sections IN PLACE (matched by their original
--     name, then by name) instead of delete-all + re-insert. Their ids stay,
--     so subjects, exam papers, the timetable and the class teacher stay
--     attached. Only what was really removed is soft-deleted.
--   * A renamed class keeps its id and carries its name into the session's
--     fee structures (the only other table that stores a class name without a
--     student behind it; renaming a class WITH students is still refused).
--   * A deleted session can not take a structure; capacity must be 1..5000;
--     the payload must be a JSON array. No temp table any more, so the proc
--     can run twice in one transaction.
-- ============================================================================


-- ── 1. Session names unique among LIVE rows only ────────────────────────────
ALTER TABLE academic.academic_years DROP CONSTRAINT IF EXISTS uq_academic_year;

CREATE UNIQUE INDEX IF NOT EXISTS ux_academic_years_name
    ON academic.academic_years (tenant_id, school_id, lower(academic_year_name))
    WHERE COALESCE(is_deleted, FALSE) = FALSE;


-- ── 2. Where a session's NAME is used ───────────────────────────────────────
-- Returns e.g. '3 student(s), 1 fee structure(s)', or NULL when nothing uses it.
CREATE OR REPLACE FUNCTION academic.fn_academic_year_name_usage(
    p_tenant_id integer, p_school_id integer, p_name text)
RETURNS text
LANGUAGE plpgsql STABLE
AS $function$
DECLARE
    v_parts text[] := '{}';
    v_n     integer;
BEGIN
    -- Students: their present position plus every session they were enrolled in.
    SELECT COUNT(*) INTO v_n FROM (
        SELECT student_id FROM core.students
         WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND academic_year = p_name
        UNION
        SELECT student_id FROM core.student_enrolment
         WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND academic_year = p_name) s;
    IF v_n > 0 THEN v_parts := v_parts || (v_n || ' student(s)'); END IF;

    SELECT COUNT(*) INTO v_n FROM core.school_fee_structures
     WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND academic_year = p_name;
    IF v_n > 0 THEN v_parts := v_parts || (v_n || ' fee structure(s)'); END IF;

    SELECT COUNT(*) INTO v_n FROM core.student_attendance
     WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND academic_year = p_name;
    IF v_n > 0 THEN v_parts := v_parts || (v_n || ' attendance record(s)'); END IF;

    SELECT COUNT(*) INTO v_n FROM core.student_transport
     WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND academic_year = p_name;
    IF v_n > 0 THEN v_parts := v_parts || (v_n || ' transport record(s)'); END IF;

    SELECT COUNT(*) INTO v_n FROM core.tc_register
     WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND academic_year = p_name;
    IF v_n > 0 THEN v_parts := v_parts || (v_n || ' TC(s)'); END IF;

    SELECT COUNT(*) INTO v_n FROM core.enquiries
     WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND session = p_name;
    IF v_n > 0 THEN v_parts := v_parts || (v_n || ' enquiry(ies)'); END IF;

    -- A counter means numbers were already issued under this name; a renamed
    -- session would start again from 1 and hand out duplicates.
    SELECT COUNT(*) INTO v_n FROM (
        SELECT 1 FROM core.admission_counters
         WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND academic_year = p_name
        UNION ALL
        SELECT 1 FROM core.registration_counters
         WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND session = p_name) c;
    IF v_n > 0 THEN v_parts := v_parts || 'issued admission/registration numbers'::text; END IF;

    RETURN NULLIF(array_to_string(v_parts, ', '), '');
END;
$function$;


-- ── 3. Academic year proc ───────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE academic.sp_school_admin_academic_year_manage(
    IN p_operation          character varying,
    IN p_tenant_id          integer,
    IN p_school_id          integer,
    IN p_action_user_id     integer,
    IN p_academic_year_id   integer           DEFAULT NULL::integer,
    IN p_academic_year_name character varying DEFAULT NULL::character varying,
    IN p_start_date         date              DEFAULT NULL::date,
    IN p_end_date           date              DEFAULT NULL::date,
    IN p_is_current         boolean           DEFAULT false,
    IN p_charge_fees_from   character varying DEFAULT NULL::character varying,
    INOUT p_result          refcursor         DEFAULT 'result_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_id            integer;
    v_name          text;
    v_year_name     text;
    v_was_current   boolean;
    v_class_count   integer;
    v_student_count integer;
    v_usage         text;
    v_clash         record;
    v_charge_from   varchar(20);
    v_old_charge    varchar(20);
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    IF p_operation = 'GetAcademicYears' THEN

        OPEN p_result FOR
        SELECT
            ay.academic_year_id,
            ay.academic_year_name,
            ay.start_date,
            ay.end_date,
            COALESCE(ay.is_current, FALSE) AS is_current,
            COALESCE(NULLIF(TRIM(ay.charge_fees_from), ''), 'AdmissionMonth') AS charge_fees_from,
            (SELECT COUNT(*) FROM academic.academic_classes ac
              WHERE ac.tenant_id = p_tenant_id
                AND ac.school_id = p_school_id
                AND ac.academic_year_id = ay.academic_year_id
                AND COALESCE(ac.is_deleted, FALSE) = FALSE) AS class_count,
            -- Present students plus the session's enrolment history, so a past
            -- session still shows (and is locked by) the students it billed.
            (SELECT COUNT(*) FROM (
                 SELECT st.student_id FROM core.students st
                  WHERE st.tenant_id = p_tenant_id AND st.school_id = p_school_id
                    AND st.academic_year = ay.academic_year_name
                    AND COALESCE(st.is_active, TRUE) = TRUE
                 UNION
                 SELECT en.student_id FROM core.student_enrolment en
                  WHERE en.tenant_id = p_tenant_id AND en.school_id = p_school_id
                    AND en.academic_year = ay.academic_year_name) s) AS student_count
        FROM academic.academic_years ay
        WHERE ay.tenant_id = p_tenant_id
          AND ay.school_id = p_school_id
          AND COALESCE(ay.is_deleted, FALSE) = FALSE
        ORDER BY ay.start_date DESC NULLS LAST, ay.academic_year_name DESC;

    ELSIF p_operation = 'SaveAcademicYear' THEN

        v_name := trim(COALESCE(p_academic_year_name, ''));
        IF v_name = '' THEN
            RAISE EXCEPTION 'Academic year name is required.';
        END IF;
        IF length(v_name) > 20 THEN
            RAISE EXCEPTION 'Academic year name can be at most 20 characters.';
        END IF;

        -- The columns are NOT NULL with CHECK (end > start); say so in words
        -- rather than let the raw constraint error reach the user.
        IF p_start_date IS NULL OR p_end_date IS NULL THEN
            RAISE EXCEPTION 'Start date and end date are both required.';
        END IF;
        IF p_end_date <= p_start_date THEN
            RAISE EXCEPTION 'End date must be after the start date.';
        END IF;

        -- An edit must point at a live session of THIS school. Checked before
        -- anything is written: the current-flag reset below would otherwise run
        -- for an id that then updates nothing.
        IF COALESCE(p_academic_year_id, 0) > 0 THEN
            SELECT academic_year_name,
                   COALESCE(NULLIF(TRIM(charge_fees_from), ''), 'AdmissionMonth'),
                   COALESCE(is_current, FALSE)
              INTO v_year_name, v_old_charge, v_was_current
            FROM academic.academic_years
            WHERE tenant_id = p_tenant_id
              AND school_id = p_school_id
              AND academic_year_id = p_academic_year_id
              AND COALESCE(is_deleted, FALSE) = FALSE;

            IF v_year_name IS NULL THEN
                RAISE EXCEPTION 'This academic year no longer exists. Refresh the page.';
            END IF;
        END IF;

        IF EXISTS (
            SELECT 1 FROM academic.academic_years
            WHERE tenant_id = p_tenant_id
              AND school_id = p_school_id
              AND COALESCE(is_deleted, FALSE) = FALSE
              AND lower(academic_year_name) = lower(v_name)
              AND academic_year_id <> COALESCE(p_academic_year_id, 0)
        ) THEN
            RAISE EXCEPTION 'An academic year named "%" already exists.', v_name;
        END IF;

        -- Two sessions covering the same day make "which session is this date
        -- in" ambiguous for fee months, attendance and admissions.
        SELECT academic_year_name, start_date, end_date INTO v_clash
        FROM academic.academic_years
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND COALESCE(is_deleted, FALSE) = FALSE
          AND academic_year_id <> COALESCE(p_academic_year_id, 0)
          AND start_date::date <= p_end_date
          AND end_date::date   >= p_start_date
        ORDER BY start_date
        LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'These dates overlap session "%" (% to %).',
                v_clash.academic_year_name, v_clash.start_date, v_clash.end_date;
        END IF;

        -- Anything but the one other value means the default.
        v_charge_from := CASE WHEN p_charge_fees_from = 'SessionStart'
                              THEN 'SessionStart' ELSE 'AdmissionMonth' END;

        IF COALESCE(p_academic_year_id, 0) > 0 THEN
            -- A school always has one current session: un-ticking it here would
            -- leave none. Making another session current is the way to move it.
            IF v_was_current AND NOT COALESCE(p_is_current, FALSE) THEN
                RAISE EXCEPTION 'This is the current session. Set another session as current instead of un-ticking it.';
            END IF;

            -- Students, fee structures, attendance... store the session NAME,
            -- not its id, so a rename would silently detach every one of them.
            -- A case-only change counts too: those columns compare exactly.
            IF v_name IS DISTINCT FROM v_year_name THEN
                v_usage := academic.fn_academic_year_name_usage(p_tenant_id, p_school_id, v_year_name);
                IF v_usage IS NOT NULL THEN
                    RAISE EXCEPTION 'Cannot rename % to %: it is already used by %. Those records keep the session name, so a rename would detach them.',
                        v_year_name, v_name, v_usage;
                END IF;
            END IF;

            -- The guard this move exists for. A student's fee ledger is generated
            -- once, at admission, from this setting -- and then frozen. Refuse
            -- while the value would actually differ; dates stay editable.
            IF v_old_charge IS DISTINCT FROM v_charge_from THEN
                SELECT COUNT(*) INTO v_student_count FROM (
                    SELECT student_id FROM core.students
                     WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                       AND academic_year = v_year_name AND COALESCE(is_active, TRUE) = TRUE
                    UNION
                    SELECT student_id FROM core.student_enrolment
                     WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                       AND academic_year = v_year_name) s;

                IF v_student_count > 0 THEN
                    RAISE EXCEPTION
                        'Cannot change when fees are charged from for %: % student(s) are already admitted in this session, and their fee plans were generated under the current setting.',
                        v_year_name, v_student_count;
                END IF;
            END IF;
        END IF;

        -- Only one current year per school.
        IF COALESCE(p_is_current, FALSE) THEN
            UPDATE academic.academic_years
            SET is_current = FALSE, updated_by = p_action_user_id, updated_at = NOW()
            WHERE tenant_id = p_tenant_id
              AND school_id = p_school_id
              AND COALESCE(is_deleted, FALSE) = FALSE
              AND COALESCE(is_current, FALSE)
              AND academic_year_id <> COALESCE(p_academic_year_id, 0);
        END IF;

        IF COALESCE(p_academic_year_id, 0) <= 0 THEN
            INSERT INTO academic.academic_years
                (tenant_id, school_id, academic_year_name, start_date, end_date, is_current,
                 charge_fees_from, created_by, created_at, is_deleted, is_active)
            VALUES
                (p_tenant_id, p_school_id, v_name, p_start_date, p_end_date, COALESCE(p_is_current, FALSE),
                 v_charge_from, p_action_user_id, NOW(), FALSE, TRUE)
            RETURNING academic_year_id INTO v_id;
        ELSE
            UPDATE academic.academic_years
            SET academic_year_name = v_name,
                start_date       = p_start_date,
                end_date         = p_end_date,
                is_current       = COALESCE(p_is_current, FALSE),
                charge_fees_from = v_charge_from,
                updated_by       = p_action_user_id,
                updated_at       = NOW()
            WHERE tenant_id = p_tenant_id
              AND school_id = p_school_id
              AND academic_year_id = p_academic_year_id
              AND COALESCE(is_deleted, FALSE) = FALSE
            RETURNING academic_year_id INTO v_id;
        END IF;

        OPEN p_result FOR
        SELECT TRUE AS success, 'Saved successfully.' AS message, v_id AS academic_year_id;

    ELSIF p_operation = 'SetCurrentAcademicYear' THEN

        IF p_academic_year_id IS NULL OR p_academic_year_id <= 0 THEN
            RAISE EXCEPTION 'Select an academic year.';
        END IF;

        -- Check first: clearing every flag and then matching nothing (a stale
        -- tab, another school's id) used to leave the school with no current year.
        IF NOT EXISTS (
            SELECT 1 FROM academic.academic_years
            WHERE tenant_id = p_tenant_id
              AND school_id = p_school_id
              AND academic_year_id = p_academic_year_id
              AND COALESCE(is_deleted, FALSE) = FALSE
        ) THEN
            RAISE EXCEPTION 'This academic year no longer exists. Refresh the page.';
        END IF;

        -- Every page opens on the current session and lists the students who are
        -- IN it. Switching before the session is set up, or before the students
        -- were promoted into it, left Collect Fees, attendance and homework showing
        -- nobody. So the order is: set it up, promote, then make it current.
        IF NOT EXISTS (
            SELECT 1 FROM academic.academic_classes
            WHERE tenant_id = p_tenant_id AND school_id = p_school_id
              AND academic_year_id = p_academic_year_id AND COALESCE(is_deleted, FALSE) = FALSE
        ) THEN
            RAISE EXCEPTION 'This session has no classes yet. Set up its classes and sections first (Classes & Sections).';
        END IF;

        SELECT COUNT(*), string_agg(DISTINCT s.academic_year, ', ')
          INTO v_student_count, v_name
          FROM core.students s
         WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id AND s.is_active
           AND s.academic_year IS DISTINCT FROM (SELECT y.academic_year_name FROM academic.academic_years y
                                                  WHERE y.academic_year_id = p_academic_year_id);
        IF v_student_count > 0 THEN
            RAISE EXCEPTION '% student(s) are still in %. Promote them into this session first (Students › Promotion), then make it current.',
                v_student_count, v_name;
        END IF;

        UPDATE academic.academic_years
        SET is_current = FALSE, updated_by = p_action_user_id, updated_at = NOW()
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND COALESCE(is_deleted, FALSE) = FALSE
          AND academic_year_id <> p_academic_year_id;

        UPDATE academic.academic_years
        SET is_current = TRUE, updated_by = p_action_user_id, updated_at = NOW()
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND academic_year_id = p_academic_year_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

        OPEN p_result FOR
        SELECT TRUE AS success, 'Current academic year updated.' AS message, p_academic_year_id AS academic_year_id;

    ELSIF p_operation = 'DeleteAcademicYear' THEN

        IF p_academic_year_id IS NULL OR p_academic_year_id <= 0 THEN
            RAISE EXCEPTION 'Select an academic year.';
        END IF;

        SELECT academic_year_name, COALESCE(is_current, FALSE) INTO v_year_name, v_was_current
        FROM academic.academic_years
        WHERE academic_year_id = p_academic_year_id
          AND tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

        IF v_year_name IS NULL THEN
            RAISE EXCEPTION 'This academic year no longer exists. Refresh the page.';
        END IF;

        IF v_was_current THEN
            RAISE EXCEPTION 'This is the current session. Set another session as current before deleting it.';
        END IF;

        SELECT COUNT(*) INTO v_class_count
        FROM academic.academic_classes
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND academic_year_id = p_academic_year_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

        SELECT COUNT(*) INTO v_student_count FROM (
            SELECT student_id FROM core.students
             WHERE tenant_id = p_tenant_id AND school_id = p_school_id
               AND academic_year = v_year_name AND COALESCE(is_active, TRUE) = TRUE
            UNION
            SELECT student_id FROM core.student_enrolment
             WHERE tenant_id = p_tenant_id AND school_id = p_school_id
               AND academic_year = v_year_name) s;

        IF v_class_count > 0 OR v_student_count > 0 THEN
            RAISE EXCEPTION 'Cannot delete this year: it has % class(es) and % student(s). Remove those first.',
                v_class_count, v_student_count;
        END IF;

        -- Fee structures, enquiries, counters... keep the name; deleting the
        -- session under them would orphan them just like a rename.
        v_usage := academic.fn_academic_year_name_usage(p_tenant_id, p_school_id, v_year_name);
        IF v_usage IS NOT NULL THEN
            RAISE EXCEPTION 'Cannot delete this year: it is used by %.', v_usage;
        END IF;

        UPDATE academic.academic_years
        SET is_deleted = TRUE, is_active = FALSE, is_current = FALSE,
            deleted_by = p_action_user_id, deleted_at = NOW(),
            updated_by = p_action_user_id, updated_at = NOW()
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND academic_year_id = p_academic_year_id;

        OPEN p_result FOR
        SELECT TRUE AS success, 'Academic year deleted.' AS message, p_academic_year_id AS academic_year_id;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;


-- ── 4. Academic setup (Classes & Sections) proc ─────────────────────────────
CREATE OR REPLACE PROCEDURE academic.sp_school_admin_academic_setup_manage(
    IN p_operation          character varying,
    IN p_tenant_id          integer,
    IN p_school_id          integer,
    IN p_action_user_id     integer,
    IN p_academic_year_id   integer           DEFAULT NULL::integer,
    IN p_academic_year_name character varying DEFAULT NULL::character varying,
    IN p_setup_json         text              DEFAULT NULL::text,
    INOUT p_result          refcursor         DEFAULT 'result_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_academic_year_id   integer;
    v_academic_year_name text;
    v_academic_class_id  integer;

    v_setup_json   jsonb;
    v_class_item   jsonb;
    v_section_item jsonb;
    v_sections     jsonb;
    v_i            integer;
    v_n            integer;
    v_k            integer;

    v_class_name   text;
    v_orig_name    text;
    v_old_name     text;
    v_section_name text;

    v_class_ids    integer[];   -- live class id matched to each payload item (by position)
    v_section_ids  integer[];   -- same, for the sections of one class
    v_keep_classes integer[] := '{}';
    v_keep_secs    integer[];
    v_sec_id       integer;

    v_class_order   integer;
    v_section_order integer;

    v_stream         text;
    v_coordinator    text;
    v_coord_staff_id integer;
    v_capacity       integer;
    v_room_no        text;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    IF p_operation = 'GetAcademicSetup' THEN

        OPEN p_result FOR
        SELECT
            ay.academic_year_id,
            p_tenant_id AS tenant_id,
            p_school_id AS school_id,
            ay.start_date,
            ay.end_date,
            ay.is_current,
            ac.academic_class_id,
            ac.class_name,
            ac.display_order AS class_display_order,
            ac.stream,
            ac.coordinator,
            ac.coordinator_staff_id,
            acs.academic_class_section_id,
            acs.section_name,
            acs.display_order AS section_display_order,
            acs.capacity,
            acs.room_no,
            acs.class_teacher_staff_id,
            cts.full_name AS class_teacher,
            -- Strength for THE SESSION BEING VIEWED, from the per-session
            -- enrolment rows (core.students only holds the present position).
            COALESCE((
                SELECT COUNT(*)
                FROM core.student_enrolment en
                WHERE en.tenant_id = p_tenant_id
                  AND en.school_id = p_school_id
                  AND en.academic_year = ay.academic_year_name
                  AND en.class_name = ac.class_name
                  AND en.section = acs.section_name
                  AND en.status <> 'Left'   -- left mid-session, not on the roll
            ), 0) AS strength
        FROM academic.academic_years ay
        LEFT JOIN academic.academic_classes ac
            ON ac.academic_year_id = ay.academic_year_id
           AND ac.tenant_id = p_tenant_id
           AND ac.school_id = p_school_id
           AND COALESCE(ac.is_deleted, FALSE) = FALSE
        LEFT JOIN academic.academic_class_sections acs
            ON acs.academic_class_id = ac.academic_class_id
           AND acs.academic_year_id = ay.academic_year_id
           AND acs.tenant_id = p_tenant_id
           AND acs.school_id = p_school_id
           AND COALESCE(acs.is_deleted, FALSE) = FALSE
        LEFT JOIN core.staff cts
            ON cts.staff_id = acs.class_teacher_staff_id
           AND cts.tenant_id = p_tenant_id
           AND cts.school_id = p_school_id
           AND COALESCE(cts.is_deleted, FALSE) = FALSE
        WHERE ay.academic_year_id = p_academic_year_id
          AND ay.tenant_id = p_tenant_id
          AND ay.school_id = p_school_id
          AND COALESCE(ay.is_deleted, FALSE) = FALSE
          AND COALESCE(ay.is_active, TRUE) = TRUE
        ORDER BY
            ac.display_order,
            ac.class_name,
            acs.display_order,
            acs.section_name;

    ELSIF p_operation = 'SaveAcademicSetup' THEN

        IF p_academic_year_id IS NULL OR p_academic_year_id <= 0 THEN
            RAISE EXCEPTION 'Please select academic year.';
        END IF;

        v_academic_year_id := p_academic_year_id;
        v_setup_json := COALESCE(NULLIF(p_setup_json, ''), '[]')::jsonb;

        IF jsonb_typeof(v_setup_json) <> 'array' THEN
            RAISE EXCEPTION 'The class list must be a JSON array.';
        END IF;

        -- A live session of THIS school only: another school's id must not
        -- take our classes, and a deleted session must not take any.
        SELECT academic_year_name INTO v_academic_year_name
        FROM academic.academic_years
        WHERE academic_year_id = v_academic_year_id
          AND tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

        IF v_academic_year_name IS NULL THEN
            RAISE EXCEPTION 'Please select academic year.';
        END IF;

        -- Capacity is checked by the controller too; this is the last word.
        SELECT trim(COALESCE(ci ->> 'className', ci ->> 'ClassName', '')),
               trim(COALESCE(si ->> 'sectionName', si ->> 'SectionName', ''))
          INTO v_class_name, v_section_name
        FROM jsonb_array_elements(v_setup_json) ci
        CROSS JOIN jsonb_array_elements(COALESCE(ci -> 'sections', ci -> 'Sections', '[]'::jsonb)) si
        WHERE jsonb_typeof(si) = 'object'
          AND NULLIF(si ->> 'capacity', '') IS NOT NULL
          AND (si ->> 'capacity')::int NOT BETWEEN 1 AND 5000
        LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'Capacity for % - % must be between 1 and 5000.', v_class_name, v_section_name;
        END IF;

        -- Guard: refuse to drop (or rename) a class/section that still has
        -- enrolled students. Students hold the class and section by NAME, so a
        -- section only survives if the payload still carries it by that name.
        IF EXISTS (
            SELECT 1
            FROM academic.academic_classes ac
            JOIN academic.academic_class_sections acs
              ON acs.academic_class_id = ac.academic_class_id
             AND COALESCE(acs.is_deleted, FALSE) = FALSE
            WHERE ac.tenant_id = p_tenant_id
              AND ac.school_id = p_school_id
              AND ac.academic_year_id = v_academic_year_id
              AND COALESCE(ac.is_deleted, FALSE) = FALSE
              AND EXISTS (
                  SELECT 1 FROM core.student_enrolment en
                  WHERE en.tenant_id = p_tenant_id
                    AND en.school_id = p_school_id
                    AND en.academic_year = v_academic_year_name
                    AND en.class_name = ac.class_name
                    AND en.section = acs.section_name
                    AND en.status <> 'Left'
              )
              AND NOT EXISTS (
                  SELECT 1
                  FROM jsonb_array_elements(v_setup_json) ci
                  CROSS JOIN jsonb_array_elements(
                      COALESCE(ci -> 'Sections', ci -> 'sections', '[]'::jsonb)) si
                  WHERE trim(COALESCE(ci ->> 'ClassName', ci ->> 'className', '')) = ac.class_name
                    AND trim(
                          CASE WHEN jsonb_typeof(si) = 'object'
                               THEN COALESCE(si ->> 'SectionName', si ->> 'sectionName', '')
                               ELSE trim(BOTH '"' FROM si::text)
                          END
                        ) = acs.section_name
              )
        ) THEN
            RAISE EXCEPTION 'Cannot remove a class or section that still has enrolled students. Move or promote those students first.';
        END IF;

        -- ── Match every payload class to a live class, keeping its id ──────
        -- WHY: subjects, exam papers and the timetable point at the class /
        -- section ID. The old delete-all + re-insert gave every class a new id
        -- on every save and left all of those pointing at deleted rows.
        -- Pass 1 matches by originalName (what the page loaded, so a rename is
        -- recognised); pass 2 matches the rest by name. An id is used once.
        v_n := jsonb_array_length(v_setup_json);
        v_class_ids := array_fill(NULL::integer, ARRAY[GREATEST(v_n, 1)]);

        FOR v_k IN 1..2 LOOP
            FOR v_i IN 1..v_n LOOP
                CONTINUE WHEN v_class_ids[v_i] IS NOT NULL;
                v_class_item := v_setup_json -> (v_i - 1);
                v_class_name := trim(COALESCE(v_class_item ->> 'ClassName', v_class_item ->> 'className', ''));
                CONTINUE WHEN v_class_name = '';
                v_orig_name := NULLIF(trim(COALESCE(v_class_item ->> 'originalName', v_class_item ->> 'OriginalName', '')), '');
                CONTINUE WHEN v_k = 1 AND v_orig_name IS NULL;

                SELECT academic_class_id INTO v_academic_class_id
                FROM academic.academic_classes
                WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                  AND academic_year_id = v_academic_year_id
                  AND COALESCE(is_deleted, FALSE) = FALSE
                  AND lower(class_name) = lower(CASE WHEN v_k = 1 THEN v_orig_name ELSE v_class_name END)
                  AND NOT (academic_class_id = ANY (v_keep_classes))
                LIMIT 1;

                IF v_academic_class_id IS NOT NULL THEN
                    v_class_ids[v_i] := v_academic_class_id;
                    v_keep_classes := v_keep_classes || v_academic_class_id;
                END IF;
            END LOOP;
        END LOOP;

        -- Only what was really removed goes: those classes and their sections.
        UPDATE academic.academic_class_sections
        SET is_deleted = TRUE, is_active = FALSE,
            deleted_by = p_action_user_id, deleted_at = NOW(),
            updated_by = p_action_user_id, updated_at = NOW()
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND academic_year_id = v_academic_year_id
          AND COALESCE(is_deleted, FALSE) = FALSE
          AND NOT (academic_class_id = ANY (v_keep_classes));

        UPDATE academic.academic_classes
        SET is_deleted = TRUE, is_active = FALSE,
            deleted_by = p_action_user_id, deleted_at = NOW(),
            updated_by = p_action_user_id, updated_at = NOW()
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND academic_year_id = v_academic_year_id
          AND COALESCE(is_deleted, FALSE) = FALSE
          AND NOT (academic_class_id = ANY (v_keep_classes));

        v_class_order := 0;

        FOR v_i IN 1..v_n LOOP
            v_class_item := v_setup_json -> (v_i - 1);
            v_class_name := trim(COALESCE(v_class_item ->> 'ClassName', v_class_item ->> 'className', ''));
            CONTINUE WHEN v_class_name = '';

            v_class_order := v_class_order + 1;
            v_stream      := NULLIF(trim(COALESCE(v_class_item ->> 'stream',      v_class_item ->> 'Stream',      '')), '');
            v_coordinator := NULLIF(trim(COALESCE(v_class_item ->> 'coordinator', v_class_item ->> 'Coordinator', '')), '');
            v_coord_staff_id := NULLIF(COALESCE(v_class_item ->> 'coordinatorStaffId', v_class_item ->> 'CoordinatorStaffId', ''), '')::int;

            -- Snapshot the coordinator's name from the linked staff row; a staff
            -- id that is not this school's is dropped.
            IF COALESCE(v_coord_staff_id, 0) > 0 THEN
                SELECT full_name INTO v_coordinator
                FROM   core.staff
                WHERE  staff_id = v_coord_staff_id
                  AND  tenant_id = p_tenant_id AND school_id = p_school_id
                  AND  COALESCE(is_deleted, FALSE) = FALSE;

                IF v_coordinator IS NULL THEN
                    v_coord_staff_id := NULL;
                END IF;
            END IF;

            v_academic_class_id := v_class_ids[v_i];

            IF v_academic_class_id IS NULL THEN
                INSERT INTO academic.academic_classes
                    (tenant_id, school_id, academic_year_id, class_name, display_order,
                     stream, coordinator, coordinator_staff_id, created_by, created_at, is_deleted, is_active)
                VALUES
                    (p_tenant_id, p_school_id, v_academic_year_id, v_class_name,
                     COALESCE(NULLIF(v_class_item ->> 'displayOrder', '')::int, v_class_order),
                     v_stream, v_coordinator, NULLIF(COALESCE(v_coord_staff_id, 0), 0),
                     p_action_user_id, NOW(), FALSE, TRUE)
                RETURNING academic_class_id INTO v_academic_class_id;
            ELSE
                SELECT class_name INTO v_old_name
                FROM academic.academic_classes WHERE academic_class_id = v_academic_class_id;

                -- A rename keeps the class id (so subjects, exams, timetable and
                -- class teachers stay) and carries the new name into this
                -- session's fee structures, the one other place a class name is
                -- stored without a student behind it. Renaming a class that has
                -- students was already refused by the guard above.
                IF v_old_name IS DISTINCT FROM v_class_name AND EXISTS (
                    SELECT 1 FROM core.school_fee_structures
                    WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                      AND academic_year = v_academic_year_name AND class_name = v_old_name
                ) THEN
                    IF length(v_class_name) > 30 THEN
                        RAISE EXCEPTION 'Cannot rename % to %: it has a fee structure, and a fee structure class name can be at most 30 characters.',
                            v_old_name, v_class_name;
                    END IF;
                    IF EXISTS (
                        SELECT 1 FROM core.school_fee_structures
                        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                          AND academic_year = v_academic_year_name AND class_name = v_class_name
                    ) THEN
                        RAISE EXCEPTION 'Cannot rename % to %: a fee structure for % already exists in this session.',
                            v_old_name, v_class_name, v_class_name;
                    END IF;

                    UPDATE core.school_fee_structures
                    SET class_name = v_class_name, updated_by = p_action_user_id, updated_at = NOW()
                    WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                      AND academic_year = v_academic_year_name AND class_name = v_old_name;
                END IF;

                UPDATE academic.academic_classes
                SET class_name           = v_class_name,
                    display_order        = COALESCE(NULLIF(v_class_item ->> 'displayOrder', '')::int, v_class_order),
                    stream               = v_stream,
                    coordinator          = v_coordinator,
                    coordinator_staff_id = NULLIF(COALESCE(v_coord_staff_id, 0), 0),
                    updated_by           = p_action_user_id,
                    updated_at           = NOW()
                WHERE academic_class_id = v_academic_class_id;
            END IF;

            -- ── Sections of this class: same two-pass match, by id ──────────
            v_sections := COALESCE(v_class_item -> 'Sections', v_class_item -> 'sections', '[]'::jsonb);
            v_section_ids := array_fill(NULL::integer, ARRAY[GREATEST(jsonb_array_length(v_sections), 1)]);
            v_keep_secs := '{}';

            FOR v_k IN 1..2 LOOP
                FOR v_section_order IN 1..jsonb_array_length(v_sections) LOOP
                    CONTINUE WHEN v_section_ids[v_section_order] IS NOT NULL;
                    v_section_item := v_sections -> (v_section_order - 1);
                    IF jsonb_typeof(v_section_item) = 'object' THEN
                        v_section_name := trim(COALESCE(v_section_item ->> 'sectionName', v_section_item ->> 'SectionName', ''));
                        v_orig_name    := NULLIF(trim(COALESCE(v_section_item ->> 'originalName', v_section_item ->> 'OriginalName', '')), '');
                    ELSE
                        v_section_name := trim(trim(BOTH '"' FROM v_section_item::text));
                        v_orig_name    := NULL;
                    END IF;
                    CONTINUE WHEN v_section_name = '';
                    CONTINUE WHEN v_k = 1 AND v_orig_name IS NULL;

                    SELECT academic_class_section_id INTO v_sec_id
                    FROM academic.academic_class_sections
                    WHERE academic_class_id = v_academic_class_id
                      AND COALESCE(is_deleted, FALSE) = FALSE
                      AND lower(section_name) = lower(CASE WHEN v_k = 1 THEN v_orig_name ELSE v_section_name END)
                      AND NOT (academic_class_section_id = ANY (v_keep_secs))
                    LIMIT 1;

                    IF v_sec_id IS NOT NULL THEN
                        v_section_ids[v_section_order] := v_sec_id;
                        v_keep_secs := v_keep_secs || v_sec_id;
                    END IF;
                END LOOP;
            END LOOP;

            UPDATE academic.academic_class_sections
            SET is_deleted = TRUE, is_active = FALSE,
                deleted_by = p_action_user_id, deleted_at = NOW(),
                updated_by = p_action_user_id, updated_at = NOW()
            WHERE academic_class_id = v_academic_class_id
              AND COALESCE(is_deleted, FALSE) = FALSE
              AND NOT (academic_class_section_id = ANY (v_keep_secs));

            v_k := 0;   -- position among the non-blank sections
            FOR v_section_order IN 1..jsonb_array_length(v_sections) LOOP
                v_section_item := v_sections -> (v_section_order - 1);
                IF jsonb_typeof(v_section_item) = 'object' THEN
                    v_section_name := trim(COALESCE(v_section_item ->> 'sectionName', v_section_item ->> 'SectionName', ''));
                    v_capacity     := NULLIF(v_section_item ->> 'capacity', '')::int;
                    v_room_no      := NULLIF(trim(COALESCE(v_section_item ->> 'roomNo', '')), '');
                ELSE
                    v_section_name := trim(trim(BOTH '"' FROM v_section_item::text));
                    v_capacity     := NULL;
                    v_room_no      := NULL;
                END IF;
                CONTINUE WHEN v_section_name = '';
                v_k := v_k + 1;

                IF v_section_ids[v_section_order] IS NULL THEN
                    INSERT INTO academic.academic_class_sections
                        (tenant_id, school_id, academic_year_id, academic_class_id, section_name,
                         display_order, capacity, room_no,
                         created_by, created_at, is_deleted, is_active)
                    VALUES
                        (p_tenant_id, p_school_id, v_academic_year_id, v_academic_class_id, v_section_name,
                         v_k, v_capacity, v_room_no,
                         p_action_user_id, NOW(), FALSE, TRUE);
                ELSE
                    -- In place: the class teacher (set on its own page) and the
                    -- timetable stay with the section.
                    UPDATE academic.academic_class_sections
                    SET section_name  = v_section_name,
                        display_order = v_k,
                        capacity      = v_capacity,
                        room_no       = v_room_no,
                        updated_by    = p_action_user_id,
                        updated_at    = NOW()
                    WHERE academic_class_section_id = v_section_ids[v_section_order];
                END IF;
            END LOOP;
        END LOOP;

        OPEN p_result FOR
        SELECT
            TRUE AS success,
            'Saved successfully.' AS message,
            v_academic_year_id AS academic_year_id;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;


