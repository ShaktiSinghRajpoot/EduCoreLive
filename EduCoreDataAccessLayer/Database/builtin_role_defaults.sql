-- ============================================================================
-- Default permissions for the built-in roles TEACHER, ACCOUNTANT, RECEPTIONIST.
--
-- They were created with no permissions at all, so a teacher who signed in saw
-- only the Dashboard until the school ticked boxes on the Roles page (which most
-- schools never knew to do). Grants are stored per (tenant, school, role), so the
-- defaults are applied per school, and ONLY where that role has no grant at all
-- for that school: a school that already configured a role is never touched.
--
--   TEACHER       students.view, attendance.view/manage, exams.view/manage,
--                 academics.view
--   ACCOUNTANT    fees.view/manage/collect/cancel/refund/concession,
--                 reports.view, inventory.view
--   RECEPTIONIST  enquiry.view/manage, registration.view/manage,
--                 students.view, fees.collect
--
-- config.fn_apply_builtin_role_defaults is also called by sp_school_manage when a
-- school is created. The block at the end applies it to every existing school.
-- Target DB: PostgreSQL. Safe to re-run.
-- ============================================================================

CREATE OR REPLACE FUNCTION config.fn_apply_builtin_role_defaults(
    p_tenant_id integer, p_school_id integer, p_action_user_id integer)
RETURNS integer
LANGUAGE plpgsql
AS $function$
DECLARE
    v_added integer := 0;
    v_n     integer;
    r       record;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RETURN 0;
    END IF;

    FOR r IN
        SELECT ro.role_id, ro.role_code
        FROM config.roles ro
        WHERE ro.tenant_id = p_tenant_id
          AND ro.role_code IN ('TEACHER', 'ACCOUNTANT', 'RECEPTIONIST')
          AND NOT COALESCE(ro.is_deleted, FALSE)
          -- untouched: no grant (live or removed) for this school yet
          AND NOT EXISTS (SELECT 1 FROM config.role_permissions rp
                          WHERE rp.role_id = ro.role_id
                            AND rp.tenant_id = p_tenant_id
                            AND rp.school_id = p_school_id)
    LOOP
        INSERT INTO config.role_permissions
            (tenant_id, school_id, role_id, permission_id, is_allowed, created_by, created_at)
        SELECT p_tenant_id, p_school_id, r.role_id, p.permission_id, TRUE, COALESCE(p_action_user_id, 0), now()
        FROM config.permissions p
        WHERE p.permission_key = ANY (CASE r.role_code
            WHEN 'TEACHER'      THEN ARRAY['students.view', 'attendance.view', 'attendance.manage',
                                           'exams.view', 'exams.manage', 'academics.view']
            WHEN 'ACCOUNTANT'   THEN ARRAY['fees.view', 'fees.manage', 'fees.collect', 'fees.cancel',
                                           'fees.refund', 'fees.concession', 'reports.view', 'inventory.view']
            WHEN 'RECEPTIONIST' THEN ARRAY['enquiry.view', 'enquiry.manage', 'registration.view',
                                           'registration.manage', 'students.view', 'fees.collect']
            END);
        GET DIAGNOSTICS v_n = ROW_COUNT;
        v_added := v_added + v_n;
    END LOOP;

    RETURN v_added;
END;
$function$;

-- Apply to every live school of every school tenant (once per untouched role).
DO $$
DECLARE s record; v_total integer := 0;
BEGIN
    FOR s IN SELECT tenant_id, school_id FROM core.schools
             WHERE tenant_id > 1 AND NOT COALESCE(is_deleted, FALSE)
    LOOP
        v_total := v_total + config.fn_apply_builtin_role_defaults(s.tenant_id, s.school_id, 0);
    END LOOP;
    RAISE NOTICE 'built-in role defaults: % grant(s) added', v_total;
END $$;
