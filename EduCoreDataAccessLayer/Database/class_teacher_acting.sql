-- ============================================================================
-- Acting class teacher (QA BUG-114)
--
-- Only the class teacher (or an admin) may take a section's attendance. When the
-- class teacher is away that day (approved leave, or marked Absent / On leave in
-- Staff Attendance), a teacher who takes a period in that section that day --
-- by the timetable or as the substitute -- may take the register instead. Nobody
-- has to set anything up: approving the leave and covering the periods is enough.
--
-- core.sp_class_teacher_acting(..., p_class, p_section, p_date)
--   one row: is_acting, class_teacher (name), away_reason
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

CREATE OR REPLACE PROCEDURE core.sp_class_teacher_acting(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_class          varchar,
    IN    p_section        varchar,
    IN    p_date           date,
    INOUT p_result         refcursor DEFAULT 'acting_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_section  integer;
    v_teacher  integer;
    v_me       integer;
    v_away     varchar;
    v_dow      integer := EXTRACT(ISODOW FROM COALESCE(p_date, CURRENT_DATE))::int;
    v_acting   boolean := FALSE;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    -- The section of the session that contains the date, and its class teacher.
    SELECT sec.academic_class_section_id, sec.class_teacher_staff_id
      INTO v_section, v_teacher
      FROM academic.academic_class_sections sec
      JOIN academic.academic_classes c ON c.academic_class_id = sec.academic_class_id
      JOIN academic.academic_years y   ON y.academic_year_id  = sec.academic_year_id
     WHERE sec.tenant_id = p_tenant_id AND sec.school_id = p_school_id
       AND NOT COALESCE(sec.is_deleted, FALSE)
       AND c.class_name = p_class AND sec.section_name = COALESCE(p_section, '')
       AND COALESCE(p_date, CURRENT_DATE) BETWEEN y.start_date::date AND y.end_date::date
     LIMIT 1;

    -- The signed-in user's staff record.
    SELECT s.staff_id INTO v_me
      FROM core.staff s
     WHERE s.user_id = p_action_user_id AND s.tenant_id = p_tenant_id AND s.school_id = p_school_id
       AND NOT COALESCE(s.is_deleted, FALSE)
     LIMIT 1;

    IF v_section IS NOT NULL AND v_teacher IS NOT NULL AND v_me IS NOT NULL AND v_me <> v_teacher THEN
        v_away := core.fn_staff_away(p_tenant_id, p_school_id, v_teacher, COALESCE(p_date, CURRENT_DATE));
        IF v_away IS NOT NULL THEN
            v_acting := EXISTS (
                    SELECT 1 FROM academic.timetable t
                     WHERE t.tenant_id = p_tenant_id AND t.school_id = p_school_id
                       AND t.academic_class_section_id = v_section
                       AND t.day_of_week = v_dow AND t.staff_id = v_me)
                OR EXISTS (
                    SELECT 1 FROM academic.timetable_substitutions x
                     WHERE x.tenant_id = p_tenant_id AND x.school_id = p_school_id
                       AND x.academic_class_section_id = v_section
                       AND x.sub_date = COALESCE(p_date, CURRENT_DATE)
                       AND x.substitute_staff_id = v_me);
        END IF;
    END IF;

    OPEN p_result FOR
    SELECT v_acting AS is_acting,
           (SELECT s.full_name FROM core.staff s WHERE s.staff_id = v_teacher) AS class_teacher,
           v_away AS away_reason;
END;
$procedure$;
