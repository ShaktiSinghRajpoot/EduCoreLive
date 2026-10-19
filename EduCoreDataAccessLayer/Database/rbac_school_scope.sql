-- ============================================================================
-- Roles stay inside their school (19 Oct 2026, security review).
--
-- Built-in roles (School Admin, Teacher, Accountant, Receptionist) are one row per
-- TENANT, and a school's own roles carry its school_id. Their GRANTS were always
-- written per school (role_permissions.school_id), and the login's permission
-- check (core.sp_get_user_permissions) already read them per school. But the Users
-- & Roles screen read and wrote grants by tenant only, and the role list, rename
-- and delete looked roles up by tenant only. In a tenant with two schools, the
-- admin of one school could change the other school's Teacher permissions or
-- delete its roles; and a user with roles in both schools got both schools' roles
-- in either. Today every tenant has one school, so nothing changes for anyone;
-- this closes it before a second school is ever added to a tenant.
--
--   role list / get / rename / delete : built-in roles + this school's own roles
--   role grants read / save / resolve : this school's grants only
--   a user's roles (effective/resolve): the roles given in this school only
--
-- Re-runnable (replaces the routines from sp_rbac_manage.sql).
-- ============================================================================

CREATE OR REPLACE PROCEDURE config.sp_role_manage(IN p_operation text, IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_role_id integer, IN p_role_name text, IN p_description text, INOUT p_result refcursor DEFAULT 'role_cursor'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_role_id   integer;
    v_role_code text;
    v_base      text;
    v_suffix    integer := 1;
    v_existing  text;
BEGIN
    IF p_tenant_id IS NULL OR p_tenant_id <= 1 OR p_school_id IS NULL OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid tenant/school scope.';
    END IF;

    -- ---------------------------------------------------------------- LIST
    -- All roles for the tenant + a live user count per role. SUPER_ADMIN is the
    -- platform role and never appears inside a school's list.
    IF p_operation = 'LIST' THEN
        OPEN p_result FOR
        SELECT r.role_id, r.role_code, r.role_name, r.description, r.is_active,
               (r.role_code IN ('SCHOOL_ADMIN','TEACHER','ACCOUNTANT','RECEPTIONIST')) AS is_builtin,
               (SELECT COUNT(*) FROM core.user_roles ur
                 WHERE ur.tenant_id = r.tenant_id AND ur.role_id = r.role_id AND ur.school_id = p_school_id
                   AND ur.is_deleted = FALSE AND ur.is_active = TRUE) AS user_count,
               (SELECT COUNT(*) FROM config.role_permissions rp
                 WHERE rp.tenant_id = r.tenant_id AND rp.role_id = r.role_id AND rp.school_id = p_school_id
                   AND rp.is_deleted = FALSE AND rp.is_allowed = TRUE) AS permission_count
        FROM   config.roles r
        WHERE  r.tenant_id = p_tenant_id
          AND  (r.school_id IS NULL OR r.school_id = p_school_id)   -- built-in roles, and this school's own
          AND  r.is_deleted = FALSE
          AND  r.role_code <> 'SUPER_ADMIN'
        ORDER BY is_builtin DESC, r.role_name;
        RETURN;
    END IF;

    -- ----------------------------------------------------------------- GET
    IF p_operation = 'GET' THEN
        OPEN p_result FOR
        SELECT r.role_id, r.role_code, r.role_name, r.description, r.is_active,
               (r.role_code IN ('SCHOOL_ADMIN','TEACHER','ACCOUNTANT','RECEPTIONIST')) AS is_builtin
        FROM   config.roles r
        WHERE  r.tenant_id = p_tenant_id AND r.role_id = p_role_id AND r.is_deleted = FALSE
          AND  (r.school_id IS NULL OR r.school_id = p_school_id);
        RETURN;
    END IF;

    -- -------------------------------------------------------------- DELETE
    IF p_operation = 'DELETE' THEN
        SELECT role_code INTO v_existing
        FROM config.roles
        WHERE tenant_id = p_tenant_id AND role_id = p_role_id AND is_deleted = FALSE AND (school_id IS NULL OR school_id = p_school_id);

        IF v_existing IS NULL THEN
            RAISE EXCEPTION 'Role not found.';
        END IF;
        IF v_existing IN ('SUPER_ADMIN','SCHOOL_ADMIN','TEACHER','ACCOUNTANT','RECEPTIONIST') THEN
            RAISE EXCEPTION 'Built-in roles cannot be deleted.';
        END IF;
        IF EXISTS (SELECT 1 FROM core.user_roles
                   WHERE tenant_id = p_tenant_id AND role_id = p_role_id
                     AND is_deleted = FALSE AND is_active = TRUE) THEN
            RAISE EXCEPTION 'This role is assigned to one or more users. Reassign them first.';
        END IF;

        UPDATE config.roles
        SET is_deleted = TRUE, is_active = FALSE, deleted_by = p_action_user_id, deleted_at = now()
        WHERE tenant_id = p_tenant_id AND role_id = p_role_id AND school_id = p_school_id;

        PERFORM core.fn_admin_audit(p_tenant_id, p_school_id, p_action_user_id, 'ROLE_DELETE', 'Roles',
            'config.roles', p_role_id,
            format('Role %s deleted', (SELECT role_name FROM config.roles WHERE role_id = p_role_id)));

        OPEN p_result FOR SELECT p_role_id AS role_id;
        RETURN;
    END IF;

    -- ============================ INSERT / UPDATE ========================
    IF p_operation IN ('INSERT', 'UPDATE') THEN
        IF p_role_name IS NULL OR TRIM(p_role_name) = '' THEN
            RAISE EXCEPTION 'Role name is required.';
        END IF;

        -- Role name must be unique within the tenant (case-insensitive).
        IF EXISTS (
            SELECT 1 FROM config.roles
            WHERE tenant_id = p_tenant_id AND is_deleted = FALSE
              AND LOWER(TRIM(role_name)) = LOWER(TRIM(p_role_name))
              AND (p_operation = 'INSERT' OR role_id <> p_role_id)
        ) THEN
            RAISE EXCEPTION 'A role with this name already exists.';
        END IF;

        IF p_operation = 'INSERT' THEN
            -- Auto-generate a stable role_code from the name (UPPER, non-alnum -> _),
            -- de-duped within the tenant.
            v_base := UPPER(REGEXP_REPLACE(TRIM(p_role_name), '[^a-zA-Z0-9]+', '_', 'g'));
            v_base := TRIM(BOTH '_' FROM v_base);
            IF v_base = '' THEN v_base := 'ROLE'; END IF;
            v_role_code := v_base;
            -- The platform and built-in codes are RESERVED even when this tenant has
            -- no row with that code: PermissionService treats SUPER_ADMIN/SCHOOL_ADMIN
            -- as a full bypass and LIST hides SUPER_ADMIN, so "Super Admin" must
            -- become SUPER_ADMIN_2, never SUPER_ADMIN.
            WHILE v_role_code IN ('SUPER_ADMIN','TENANT_ADMIN','SCHOOL_ADMIN','TEACHER','ACCOUNTANT','RECEPTIONIST')
               OR EXISTS (SELECT 1 FROM config.roles
                          WHERE tenant_id = p_tenant_id AND role_code = v_role_code AND is_deleted = FALSE) LOOP
                v_suffix := v_suffix + 1;
                v_role_code := v_base || '_' || v_suffix;
            END LOOP;

            INSERT INTO config.roles
                (tenant_id, school_id, role_code, role_name, description, is_active, created_by, created_at)
            VALUES
                (p_tenant_id, p_school_id, v_role_code, TRIM(p_role_name), NULLIF(TRIM(p_description), ''),
                 TRUE, p_action_user_id, now())
            RETURNING role_id INTO v_role_id;

            PERFORM core.fn_admin_audit(p_tenant_id, p_school_id, p_action_user_id, 'ROLE_CREATE', 'Roles',
                'config.roles', v_role_id, format('Role %s created (code %s)', TRIM(p_role_name), v_role_code));
        ELSE
            SELECT role_code INTO v_existing
            FROM config.roles
            WHERE tenant_id = p_tenant_id AND role_id = p_role_id AND is_deleted = FALSE AND (school_id IS NULL OR school_id = p_school_id);
            IF v_existing IS NULL THEN
                RAISE EXCEPTION 'Role not found.';
            END IF;
            IF v_existing IN ('SUPER_ADMIN','SCHOOL_ADMIN','TEACHER','ACCOUNTANT','RECEPTIONIST') THEN
                RAISE EXCEPTION 'Built-in roles cannot be renamed.';
            END IF;

            PERFORM core.fn_admin_audit(p_tenant_id, p_school_id, p_action_user_id, 'ROLE_UPDATE', 'Roles',
                'config.roles', p_role_id,
                format('Role renamed: %s -> %s',
                       (SELECT role_name FROM config.roles WHERE role_id = p_role_id), TRIM(p_role_name)));

            UPDATE config.roles
            SET role_name = TRIM(p_role_name),
                description = NULLIF(TRIM(p_description), ''),
                updated_by = p_action_user_id, updated_at = now()
            WHERE tenant_id = p_tenant_id AND role_id = p_role_id AND school_id = p_school_id
            RETURNING role_id INTO v_role_id;
        END IF;

        OPEN p_result FOR SELECT v_role_id AS role_id;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation: %', p_operation;
END;
$procedure$;

CREATE OR REPLACE PROCEDURE config.sp_role_permissions_get(IN p_tenant_id integer, IN p_school_id integer, IN p_role_id integer, INOUT p_result refcursor DEFAULT 'rp_cursor'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id IS NULL OR p_tenant_id <= 1 OR p_school_id IS NULL OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid tenant/school scope.';
    END IF;

    OPEN p_result FOR
    SELECT rp.permission_id
    FROM   config.role_permissions rp
    WHERE  rp.tenant_id = p_tenant_id
      AND  rp.role_id   = p_role_id
      AND  rp.school_id = p_school_id
      AND  rp.is_deleted = FALSE
      AND  rp.is_allowed = TRUE;
END;
$procedure$;

CREATE OR REPLACE PROCEDURE config.sp_role_permissions_save(IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_role_id integer, IN p_permission_ids integer[], INOUT p_result refcursor DEFAULT 'rp_save_cursor'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_role_code text;
    v_before    text;
    v_after     text;
BEGIN
    IF p_tenant_id IS NULL OR p_tenant_id <= 1 OR p_school_id IS NULL OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid tenant/school scope.';
    END IF;

    -- Only ids from the catalog can be granted (there is no FK on role_permissions).
    IF EXISTS (SELECT 1 FROM UNNEST(COALESCE(p_permission_ids, ARRAY[]::integer[])) AS pid
               WHERE NOT EXISTS (SELECT 1 FROM config.permissions p WHERE p.permission_id = pid)) THEN
        RAISE EXCEPTION 'Unknown permission.';
    END IF;

    SELECT role_code INTO v_role_code
    FROM config.roles
    WHERE tenant_id = p_tenant_id AND role_id = p_role_id AND is_deleted = FALSE AND (school_id IS NULL OR school_id = p_school_id);
    IF v_role_code IS NULL THEN
        RAISE EXCEPTION 'Role not found.';
    END IF;

    -- Grants before the save, for the audit row.
    SELECT string_agg(p.permission_key, ', ' ORDER BY p.permission_key) INTO v_before
    FROM config.role_permissions rp JOIN config.permissions p USING (permission_id)
    WHERE rp.tenant_id = p_tenant_id AND rp.role_id = p_role_id AND rp.school_id = p_school_id AND rp.is_deleted = FALSE AND rp.is_allowed = TRUE;

    -- Soft-delete grants that are no longer selected.
    UPDATE config.role_permissions
    SET is_deleted = TRUE, is_allowed = FALSE, updated_by = p_action_user_id, updated_at = now()
    WHERE tenant_id = p_tenant_id AND role_id = p_role_id AND school_id = p_school_id AND is_deleted = FALSE
      AND NOT (permission_id = ANY (COALESCE(p_permission_ids, ARRAY[]::integer[])));

    -- Revive any previously-removed grants that are selected again.
    UPDATE config.role_permissions
    SET is_deleted = FALSE, is_allowed = TRUE, updated_by = p_action_user_id, updated_at = now()
    WHERE tenant_id = p_tenant_id AND role_id = p_role_id AND school_id = p_school_id AND is_deleted = TRUE
      AND permission_id = ANY (COALESCE(p_permission_ids, ARRAY[]::integer[]));

    -- Insert brand-new grants (those with no row at all yet).
    INSERT INTO config.role_permissions
        (tenant_id, school_id, role_id, permission_id, is_allowed, created_by, created_at)
    SELECT p_tenant_id, p_school_id, p_role_id, pid, TRUE, p_action_user_id, now()
    FROM   UNNEST(COALESCE(p_permission_ids, ARRAY[]::integer[])) AS pid
    WHERE  NOT EXISTS (
        SELECT 1 FROM config.role_permissions rp
        WHERE rp.tenant_id = p_tenant_id AND rp.role_id = p_role_id AND rp.school_id = p_school_id AND rp.permission_id = pid
    );

    SELECT string_agg(p.permission_key, ', ' ORDER BY p.permission_key) INTO v_after
    FROM config.role_permissions rp JOIN config.permissions p USING (permission_id)
    WHERE rp.tenant_id = p_tenant_id AND rp.role_id = p_role_id AND rp.school_id = p_school_id AND rp.is_deleted = FALSE AND rp.is_allowed = TRUE;

    IF v_before IS DISTINCT FROM v_after THEN
        PERFORM core.fn_admin_audit(p_tenant_id, p_school_id, p_action_user_id, 'ROLE_PERMISSIONS', 'Roles',
            'config.role_permissions', p_role_id,
            format('Role %s permissions: [%s] -> [%s]',
                   (SELECT role_name FROM config.roles WHERE role_id = p_role_id),
                   COALESCE(v_before, ''), COALESCE(v_after, '')));
    END IF;

    OPEN p_result FOR SELECT p_role_id AS role_id;
END;
$procedure$;

CREATE OR REPLACE PROCEDURE config.sp_role_permissions_resolve(IN p_tenant_id integer, IN p_school_id integer, IN p_role_id integer, INOUT p_result refcursor DEFAULT 'resolve_cursor'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
BEGIN
    OPEN p_result FOR
    SELECT p.permission_key
    FROM   config.role_permissions rp
    JOIN   config.permissions p ON p.permission_id = rp.permission_id AND p.is_active = TRUE
    WHERE  rp.tenant_id = p_tenant_id
      AND  rp.role_id   = p_role_id
      AND  rp.school_id = p_school_id
      AND  rp.is_deleted = FALSE
      AND  rp.is_allowed = TRUE;
END;
$procedure$;

CREATE OR REPLACE PROCEDURE core.sp_user_roles_effective(IN p_tenant_id integer, IN p_school_id integer, IN p_user_id integer, INOUT p_result refcursor DEFAULT 'user_roles_cursor'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
BEGIN
    OPEN p_result FOR
    SELECT r.role_id, r.role_code
    FROM   core.user_roles ur
    JOIN   config.roles r
        ON r.role_id = ur.role_id AND r.tenant_id = ur.tenant_id AND r.is_deleted = FALSE
    JOIN   core.users u
        ON u.user_id = ur.user_id AND u.is_active = TRUE AND u.is_deleted = FALSE
    WHERE  ur.tenant_id = p_tenant_id
      AND  ur.user_id   = p_user_id
      AND  ur.school_id = p_school_id
      AND  ur.is_deleted = FALSE
      AND  ur.is_active  = TRUE
      AND  EXISTS (
            SELECT 1
            FROM core.schools sc
            JOIN config.school_statuses st
              ON st.school_status_id = sc.status_id AND st.is_deleted = FALSE
            WHERE sc.school_id = p_school_id AND sc.tenant_id = p_tenant_id
              AND sc.is_active = TRUE AND sc.is_deleted = FALSE AND st.allows_login = TRUE);
END;
$procedure$;

CREATE OR REPLACE PROCEDURE core.sp_user_roles_resolve(IN p_tenant_id integer, IN p_school_id integer, IN p_user_id integer, INOUT p_result refcursor DEFAULT 'user_roles_cursor'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
BEGIN
    OPEN p_result FOR
    SELECT r.role_id, r.role_code
    FROM   core.user_roles ur
    JOIN   config.roles r
        ON r.role_id = ur.role_id AND r.tenant_id = ur.tenant_id AND r.is_deleted = FALSE
    WHERE  ur.tenant_id = p_tenant_id
      AND  ur.user_id   = p_user_id
      AND  ur.school_id = p_school_id
      AND  ur.is_deleted = FALSE
      AND  ur.is_active  = TRUE;
END;
$procedure$;
