-- ============================================================================
-- Promotion History (Students › Promotion History).
--
-- Who moved out of one session and how: promoted, kept in the same class
-- (retained / failed) or passed out, with the class they left and the class
-- they went to, the dues they owed at the time, who did it and when.
-- Reads core.student_promotion_history (written by core.sp_student_promote).
--
--   p_from_year      the session the children were promoted FROM
--   p_only_my_class  TRUE  -> only sections whose class teacher (in that session)
--                             is the signed-in user (a teacher's view)
--                    FALSE -> the whole school (office / admin)
--
-- One row per child: if a child was moved twice out of the same session, the
-- latest move counts. Read-only. Re-runnable.
-- ============================================================================
CREATE OR REPLACE PROCEDURE core.sp_promotion_history(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_from_year      varchar,
    IN    p_only_my_class  boolean   DEFAULT FALSE,
    INOUT p_result         refcursor DEFAULT 'promotion_history_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_staff integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    IF p_only_my_class THEN
        SELECT staff_id INTO v_staff
          FROM core.staff
         WHERE user_id = p_action_user_id AND tenant_id = p_tenant_id AND school_id = p_school_id
           AND NOT COALESCE(is_deleted, FALSE)
         LIMIT 1;
    END IF;

    OPEN p_result FOR
    WITH latest AS (
        SELECT DISTINCT ON (h.student_id) h.*
          FROM core.student_promotion_history h
         WHERE h.tenant_id = p_tenant_id AND h.school_id = p_school_id
           AND lower(h.from_year) = lower(trim(p_from_year))
         ORDER BY h.student_id, h.promoted_at DESC, h.promotion_id DESC
    )
    SELECT l.student_id, s.public_id, s.student_name, s.admission_no,
           l.from_class, l.from_section, l.to_year, l.to_class, l.to_section,
           l.outcome, l.dues_carried,
           core.fn_user_display_name(l.promoted_by) AS promoted_by,
           l.promoted_at,
           COALESCE(c.display_order, 999) AS class_order
      FROM latest l
      JOIN core.students s ON s.student_id = l.student_id
      LEFT JOIN academic.academic_years y ON y.tenant_id = p_tenant_id AND y.school_id = p_school_id
                                         AND lower(y.academic_year_name) = lower(l.from_year)
                                         AND NOT COALESCE(y.is_deleted, FALSE)
      LEFT JOIN academic.academic_classes c ON c.academic_year_id = y.academic_year_id
                                           AND c.class_name = l.from_class AND NOT COALESCE(c.is_deleted, FALSE)
     WHERE NOT p_only_my_class
        OR (v_staff IS NOT NULL AND EXISTS (
               SELECT 1 FROM academic.academic_class_sections sec
                WHERE sec.academic_class_id = c.academic_class_id
                  AND COALESCE(sec.section_name, '') = COALESCE(l.from_section, '')
                  AND sec.class_teacher_staff_id = v_staff
                  AND NOT COALESCE(sec.is_deleted, FALSE)))
     ORDER BY class_order, l.from_class, l.from_section, s.student_name;
END;
$procedure$;
