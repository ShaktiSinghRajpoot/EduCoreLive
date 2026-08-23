-- ============================================================================
-- Assign Class Teacher — keep the OLD 9-arg signature working alongside the new
-- session-aware one.
--
-- WHY THIS EXISTS. class_teacher_session.sql added p_academic_year_id and
-- dropped the 9-arg signature. That is only safe when every deployed app sends
-- 10 params — and it was not: local dev and the Railway-hosted app share ONE
-- database, and the deployed app was still on the older build. Dropping the
-- 9-arg overload broke it with 42883, including the IsTeacher operation that
-- gates attendance marking.
--
-- So both signatures have to exist while the two builds coexist.
--
-- The catch: two overloads differing only by a trailing DEFAULT param are
-- AMBIGUOUS to a named-argument call ("procedure is not unique"), which is how
-- Npgsql calls procs. Verified on PG 16. So p_academic_year_id must NOT have a
-- default: a 9-name call then cannot match the 10-arg proc and resolves to the
-- shim, while a 10-name call cannot match the shim. Both are unique.
--
-- The 9-arg version is a thin shim that delegates with a NULL year, so the
-- logic lives in exactly one place.
--
-- REMOVE THIS SHIM once every deployment is on the 10-param build.
--
-- Target DB: PostgreSQL. Safe to re-run.
-- ============================================================================

-- ============================================================================
-- Assign Class Teacher — make it session-aware.
--
-- academic.academic_class_sections is keyed per academic year, so the class
-- teacher of "1st - A" is a per-session fact. The proc resolved the year from
-- core.school_settings only, which meant next session's sections were
-- unreachable: you could not assign their teachers before the year rolled over.
--
-- Adds p_academic_year_id (NULL = the school's current year, so every existing
-- caller behaves exactly as before). Classes & Sections, Subjects and Timetable
-- already work this way.
--
-- The proc gains a parameter, so the old signature is dropped first — otherwise
-- CREATE OR REPLACE would leave two overloads.
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================


-- One transaction: PostgreSQL DDL is transactional, so the drop and both
-- CREATEs land atomically and no request can arrive between them.
BEGIN;

-- CREATE OR REPLACE cannot remove a parameter default, so the session-aware
-- proc is dropped and recreated without the default on p_academic_year_id.
DROP PROCEDURE IF EXISTS core.sp_class_teacher_manage(
    character varying, integer, integer, integer, integer,
    integer, integer, character varying, character varying, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_class_teacher_manage(
    IN    p_operation        character varying,
    IN    p_tenant_id        integer,
    IN    p_school_id        integer,
    IN    p_action_user_id   integer,
    IN    p_academic_year_id integer,
    IN    p_section_id       integer   DEFAULT NULL,
    IN    p_staff_id         integer   DEFAULT NULL,
    IN    p_class            character varying DEFAULT NULL,
    IN    p_section          character varying DEFAULT NULL,
    INOUT p_result           refcursor DEFAULT 'class_teacher_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_year integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    -- An explicit session wins. Otherwise prefer academic_years.is_current, which
    -- is what every other proc in this app treats as "the current session".
    --
    -- This ORDER IS A FIX. The previous version read core.school_settings first
    -- and then fell back to MAX(academic_year_id) — and school_settings
    -- .academic_year_id is NULL for at least one live school, so it silently
    -- resolved to the NEWEST year instead of the current one. That showed the
    -- wrong session's sections on the grid, and worse, made the 'IsTeacher'
    -- attendance gate answer about the wrong year: a class teacher of a current
    -- section could be told they are not one, and refused attendance marking.
    v_year := p_academic_year_id;

    IF v_year IS NULL THEN
        SELECT academic_year_id INTO v_year
        FROM academic.academic_years
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND is_current AND COALESCE(is_deleted, FALSE) = FALSE
        ORDER BY academic_year_id DESC
        LIMIT 1;
    END IF;

    IF v_year IS NULL THEN
        SELECT academic_year_id INTO v_year
        FROM core.school_settings
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND COALESCE(is_deleted, FALSE) = FALSE
        LIMIT 1;
    END IF;

    IF v_year IS NULL THEN
        SELECT MAX(academic_year_id) INTO v_year
        FROM academic.academic_classes
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND COALESCE(is_deleted, FALSE) = FALSE;
    END IF;

    -- ── Teacher pool: active staff who can be class teachers ──
    -- Staff are not per session, so this ignores v_year.
    IF p_operation = 'Teachers' THEN
        OPEN p_result FOR
        SELECT st.staff_id, st.full_name
        FROM core.staff st
        WHERE st.tenant_id = p_tenant_id AND st.school_id = p_school_id
          AND COALESCE(st.is_deleted, FALSE) = FALSE
          AND COALESCE(st.is_active, TRUE)   = TRUE
        ORDER BY st.full_name;
        RETURN;
    END IF;

    -- ── Assign / clear a section's class teacher ──
    -- The section id already identifies one session's row, so no year filter is
    -- needed; the scope check below is what keeps it to this school.
    IF p_operation = 'Assign' THEN
        UPDATE academic.academic_class_sections
        SET class_teacher_staff_id = NULLIF(p_staff_id, 0),
            updated_by = p_action_user_id,
            updated_at = now()
        WHERE academic_class_section_id = p_section_id
          AND tenant_id = p_tenant_id AND school_id = p_school_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Section not found.';
        END IF;

        OPEN p_result FOR
        SELECT TRUE AS success,
               CASE WHEN NULLIF(p_staff_id, 0) IS NULL THEN 'Class teacher cleared.'
                    ELSE 'Class teacher assigned.' END AS message;
        RETURN;
    END IF;

    -- ── Is this user the class teacher of a class-section? (attendance gate) ──
    IF p_operation = 'IsTeacher' THEN
        OPEN p_result FOR
        SELECT EXISTS (
            SELECT 1
            FROM academic.academic_class_sections sec
            JOIN academic.academic_classes c ON c.academic_class_id = sec.academic_class_id
            JOIN core.staff st ON st.staff_id = sec.class_teacher_staff_id
                              AND st.tenant_id = sec.tenant_id AND st.school_id = sec.school_id
            WHERE sec.tenant_id = p_tenant_id AND sec.school_id = p_school_id
              AND sec.academic_year_id = v_year
              AND LOWER(c.class_name)   = LOWER(TRIM(p_class))
              AND LOWER(sec.section_name) = LOWER(TRIM(p_section))
              AND st.user_id = p_action_user_id
              AND COALESCE(sec.is_deleted, FALSE) = FALSE
        ) AS is_teacher;
        RETURN;
    END IF;

    -- ── Grid: every class-section of the session + its teacher + load ──
    OPEN p_result FOR
    SELECT
        sec.academic_class_section_id AS section_id,
        c.class_name,
        c.display_order               AS class_rank,
        sec.section_name,
        sec.room_no,
        sec.class_teacher_staff_id    AS teacher_id,
        st.full_name                  AS teacher_name,
        COALESCE((
            SELECT COUNT(*) FROM academic.academic_class_sections x
            WHERE x.tenant_id = sec.tenant_id AND x.school_id = sec.school_id
              AND x.academic_year_id = sec.academic_year_id
              AND x.class_teacher_staff_id = sec.class_teacher_staff_id
              AND COALESCE(x.is_deleted, FALSE) = FALSE
        ), 0) AS teacher_load
    FROM academic.academic_class_sections sec
    JOIN academic.academic_classes c
      ON c.academic_class_id = sec.academic_class_id
    LEFT JOIN core.staff st
      ON st.staff_id = sec.class_teacher_staff_id
     AND st.tenant_id = sec.tenant_id AND st.school_id = sec.school_id
    WHERE sec.tenant_id = p_tenant_id AND sec.school_id = p_school_id
      AND sec.academic_year_id = v_year
      AND COALESCE(sec.is_deleted, FALSE) = FALSE
      AND COALESCE(c.is_deleted, FALSE)   = FALSE
    ORDER BY c.display_order, c.class_name, sec.section_name;
END;
$procedure$;

-- ── Backward-compatible 9-arg shim (older builds call this) ──

CREATE OR REPLACE PROCEDURE core.sp_class_teacher_manage(

    IN    p_operation      character varying,

    IN    p_tenant_id      integer,

    IN    p_school_id      integer,

    IN    p_action_user_id integer,

    IN    p_section_id     integer DEFAULT NULL,

    IN    p_staff_id       integer DEFAULT NULL,

    IN    p_class          character varying DEFAULT NULL,

    IN    p_section        character varying DEFAULT NULL,

    INOUT p_result         refcursor DEFAULT $$class_teacher_cursor$$::refcursor)

LANGUAGE plpgsql

AS $shim$

BEGIN

    -- 10 positional args, so this can only resolve to the session-aware proc.

    CALL core.sp_class_teacher_manage(

        p_operation, p_tenant_id, p_school_id, p_action_user_id,

        NULL::integer, p_section_id, p_staff_id, p_class, p_section, p_result);

END

$shim$;

COMMIT;
