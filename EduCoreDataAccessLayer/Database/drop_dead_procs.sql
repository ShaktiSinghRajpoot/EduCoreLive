-- ============================================================================
-- Drop three procedures nothing calls.
--
-- Found by auditing every mutating proc for validation guards: these three came
-- back with none. They are not under-validated live code — they are DEAD code
-- that nothing in the app reaches, and that is the problem with them.
--
--   core.sp_admission_manage1      an orphaned copy of sp_admission_manage,
--                                  left over from a rewrite. It predates the
--                                  back-dated-admission fix, so it still bills
--                                  a student every month since they joined.
--
--   config.sp_role_permission_management
--                                  the live permissions path is
--                                  config.sp_role_manage + sp_role_permissions_save
--                                  (both properly scoped and validated), reached
--                                  through RbacService. This one was reached only
--                                  by RolePermissionService, which was never
--                                  registered in DI — deleted alongside this.
--
--   core.sp_school_user_management  creates and updates LOGINS with no scope
--                                  guard. Nothing calls it; user creation goes
--                                  through the staff "give login" path.
--
-- Why remove rather than leave them: each looks like live security surface. The
-- next person to need "save role permissions" or "create a user" would
-- reasonably wire one up and inherit its missing guards — the same trap as the
-- superseded sp_fee_payment_collect revisions and the stale sp_dropdown_common.
--
-- Target DB: PostgreSQL. Safe to re-run.
-- ============================================================================

DROP PROCEDURE IF EXISTS core.sp_admission_manage1(
    text, integer, integer, integer, integer, text, text, text, text, date, text, text,
    text, date, text, text, text, text, text, text, text, text, text, text, text, text,
    text, text, text, text, text, text, text, text, numeric, text, text, numeric, numeric,
    numeric, numeric, text, numeric, numeric, text, numeric, jsonb, integer, integer,
    integer, text, text, text, text, text, text, refcursor);

DO $$
DECLARE r record;
BEGIN
    -- Drop by name regardless of signature — these are orphans, and pinning the
    -- exact argument list of code nobody calls is not worth the brittleness.
    FOR r IN
        SELECT n.nspname AS sch, p.proname AS nm,
               pg_get_function_identity_arguments(p.oid) AS args
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE (n.nspname = 'core'   AND p.proname IN ('sp_admission_manage1', 'sp_school_user_management'))
           OR (n.nspname = 'config' AND p.proname = 'sp_role_permission_management')
    LOOP
        EXECUTE format('DROP PROCEDURE IF EXISTS %I.%I(%s)', r.sch, r.nm, r.args);
        RAISE NOTICE 'dropped %.%', r.sch, r.nm;
    END LOOP;
END $$;
