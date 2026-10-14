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
