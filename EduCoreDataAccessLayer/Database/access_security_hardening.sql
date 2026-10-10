-- ============================================================================
-- Access & security hardening (platform_access_security_tests.sql, Oct 2026).
--
-- Apply this FIRST, then the proc scripts that use what it adds:
--   change_password.sql, forgot_password.sql, sp_rbac_manage.sql,
--   sp_staff_manage.sql, sp_school_manage.sql, school_purge.sql
--
-- What it adds:
--   1. core.users.password_changed_at -- the "security stamp". The sign-in cookie
--      carries it; the cookie check in Program.cs compares it with the database,
--      so a password change or reset signs out every other session.
--   2. core.fn_admin_audit(...)       -- the one way procs write admin_activity_logs
--      (who, when, what, old -> new). Rows are kept forever; nothing purges them
--      except the purge of the school they belong to.
--   3. core.sp_session_check(...)     -- what the cookie check asks on each request
--      (cached for a minute in the app): is the user still active, does their
--      school still allow sign-in, and what is their password stamp.
--   4. A one-off data fix: staff marked Inactive before this release kept a live
--      login (sp_staff_manage DELETE only touched core.staff). Their logins are
--      switched off now -- except where that person is the LAST active school
--      admin of their school, which would lock the school out.
--
-- Safe to re-run: every step is IF NOT EXISTS / CREATE OR REPLACE / idempotent.
-- ============================================================================

-- 1. Security stamp ----------------------------------------------------------
ALTER TABLE core.users
    ADD COLUMN IF NOT EXISTS password_changed_at timestamp without time zone;


-- 2. Audit helper ------------------------------------------------------------
-- created_by is NOT NULL on the table; a missing actor is recorded as 0.
CREATE OR REPLACE FUNCTION core.fn_admin_audit(
    p_tenant_id   integer,
    p_school_id   integer,
    p_user_id     integer,
    p_action      character varying,
    p_module      character varying,
    p_table       character varying,
    p_record_id   integer,
    p_description text)
RETURNS void
LANGUAGE sql
AS $function$
    INSERT INTO core.admin_activity_logs
        (tenant_id, user_id, school_id, action, module_name, table_name, record_id,
         description, created_by, created_at)
    VALUES
        (COALESCE(p_tenant_id, 1), p_user_id, NULLIF(p_school_id, 0), p_action, p_module, p_table,
         p_record_id, p_description, COALESCE(p_user_id, 0), CURRENT_TIMESTAMP);
$function$;


-- 2b. School-admin helpers (used by sp_staff_manage) --------------------------
-- Is this user an active SCHOOL_ADMIN of the tenant, or the platform super admin?
CREATE OR REPLACE FUNCTION core.fn_user_is_school_admin(p_tenant_id integer, p_user_id integer)
RETURNS boolean
LANGUAGE sql
STABLE
AS $function$
    SELECT EXISTS (
        SELECT 1 FROM core.user_roles ur
        JOIN config.roles rr ON rr.role_id = ur.role_id AND rr.tenant_id = ur.tenant_id
                            AND rr.role_code = 'SCHOOL_ADMIN' AND rr.is_deleted = FALSE
        WHERE ur.tenant_id = p_tenant_id AND ur.user_id = p_user_id
          AND ur.is_active = TRUE AND ur.is_deleted = FALSE)
    OR EXISTS (
        SELECT 1 FROM core.users u
        WHERE u.user_id = p_user_id AND u.tenant_id = 1 AND u.is_active = TRUE AND u.is_deleted = FALSE);
$function$;

-- Is this user the LAST active school admin of the school? (TRUE only when they
-- are an admin there and no other active login holds SCHOOL_ADMIN for it.)
CREATE OR REPLACE FUNCTION core.fn_is_last_school_admin(p_school_id integer, p_user_id integer)
RETURNS boolean
LANGUAGE sql
STABLE
AS $function$
    SELECT EXISTS (
        SELECT 1 FROM core.user_roles ur
        JOIN config.roles rr ON rr.role_id = ur.role_id AND rr.tenant_id = ur.tenant_id
                            AND rr.role_code = 'SCHOOL_ADMIN' AND rr.is_deleted = FALSE
        WHERE ur.user_id = p_user_id AND ur.school_id = p_school_id
          AND ur.is_active = TRUE AND ur.is_deleted = FALSE)
    AND NOT EXISTS (
        SELECT 1 FROM core.user_roles ur
        JOIN config.roles rr ON rr.role_id = ur.role_id AND rr.tenant_id = ur.tenant_id
                            AND rr.role_code = 'SCHOOL_ADMIN' AND rr.is_deleted = FALSE
        JOIN core.users u ON u.user_id = ur.user_id AND u.is_active = TRUE AND u.is_deleted = FALSE
        WHERE ur.school_id = p_school_id AND ur.user_id <> p_user_id
          AND ur.is_active = TRUE AND ur.is_deleted = FALSE);
$function$;


-- 3. Per-request session check -------------------------------------------------
-- p_school_id is the school in the cookie (0 for the platform super admin).
-- The school rule is the same one the login lookup applies (sp_login_management).
CREATE OR REPLACE PROCEDURE core.sp_session_check(
    IN p_user_id integer,
    IN p_school_id integer,
    INOUT p_result refcursor DEFAULT 'session_check_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    OPEN p_result FOR
    SELECT
        (u.user_id IS NOT NULL AND u.is_active AND NOT u.is_deleted) AS user_ok,
        CASE
            WHEN COALESCE(p_school_id, 0) = 0 THEN TRUE
            ELSE COALESCE((
                SELECT sc.is_active AND NOT sc.is_deleted AND COALESCE(st.allows_login, FALSE)
                FROM core.schools sc
                LEFT JOIN config.school_statuses st
                       ON st.school_status_id = sc.status_id AND st.is_deleted = FALSE
                WHERE sc.school_id = p_school_id), FALSE)
        END AS school_ok,
        COALESCE(to_char(u.password_changed_at, 'YYYYMMDDHH24MISSUS'), '0') AS password_stamp
    FROM (SELECT p_user_id AS id) x
    LEFT JOIN core.users u ON u.user_id = x.id;
END;
$procedure$;


-- 4. Inactive staff must not keep a live login ----------------------------------
DO $fix$
DECLARE r record;
BEGIN
    FOR r IN
        SELECT s.staff_id, s.tenant_id, s.school_id, s.user_id
        FROM core.staff s
        JOIN core.users u ON u.user_id = s.user_id AND u.is_active AND NOT u.is_deleted
        WHERE s.is_active = FALSE AND s.is_deleted = FALSE
    LOOP
        -- Never switch off the last active school admin of a school.
        IF core.fn_is_last_school_admin(r.school_id, r.user_id) THEN
            RAISE NOTICE 'kept login of user % (staff %): last school admin of school %',
                r.user_id, r.staff_id, r.school_id;
            CONTINUE;
        END IF;

        UPDATE core.users SET is_active = FALSE, updated_at = CURRENT_TIMESTAMP
        WHERE user_id = r.user_id;

        PERFORM core.fn_admin_audit(r.tenant_id, r.school_id, NULL, 'USER_DEACTIVATE', 'Staff',
            'core.users', r.user_id,
            format('Login of inactive staff %s switched off by access_security_hardening.sql', r.staff_id));
    END LOOP;
END
$fix$;
