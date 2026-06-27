-- ============================================================================
-- sp_rbac_manage.sql  —  Dynamic RBAC management procs
--
-- Mirrors the sp_staff_manage.sql conventions: POSITIONAL params (Npgsql
-- CommandType.StoredProcedure), INOUT refcursor OUT, tenant>1/school>0 guard.
--
-- Procs:
--   config.sp_role_manage              LIST/GET/INSERT/UPDATE/DELETE roles
--   config.sp_permission_catalog       global permission catalog (matrix source)
--   config.sp_role_permissions_get     granted permission_ids for a role
--   config.sp_role_permissions_save    replace a role's grants (matrix Save)
--   config.sp_role_permissions_resolve granted permission_KEYS for a role (runtime)
--   core.sp_user_role_list             login users + their primary role
--   core.sp_user_role_assign           reassign a user's primary role
--
-- Built-in role codes are protected from edit/delete so a school can't break its
-- own admin/teacher logins.
-- ============================================================================

-- ============================================================== sp_role_manage
DROP PROCEDURE IF EXISTS config.sp_role_manage(
    text, integer, integer, integer, integer, text, text, refcursor);

CREATE OR REPLACE PROCEDURE config.sp_role_manage(
    p_operation      text,
    p_tenant_id      integer,
    p_school_id      integer,
    p_action_user_id integer,
    p_role_id        integer,
    p_role_name      text,
    p_description    text,
    INOUT p_result   refcursor DEFAULT 'role_cursor'
)
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
                 WHERE ur.tenant_id = r.tenant_id AND ur.role_id = r.role_id
                   AND ur.is_deleted = FALSE AND ur.is_active = TRUE) AS user_count,
               (SELECT COUNT(*) FROM config.role_permissions rp
                 WHERE rp.tenant_id = r.tenant_id AND rp.role_id = r.role_id
                   AND rp.is_deleted = FALSE AND rp.is_allowed = TRUE) AS permission_count
        FROM   config.roles r
        WHERE  r.tenant_id = p_tenant_id
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
        WHERE  r.tenant_id = p_tenant_id AND r.role_id = p_role_id AND r.is_deleted = FALSE;
        RETURN;
    END IF;

    -- -------------------------------------------------------------- DELETE
    IF p_operation = 'DELETE' THEN
        SELECT role_code INTO v_existing
        FROM config.roles
        WHERE tenant_id = p_tenant_id AND role_id = p_role_id AND is_deleted = FALSE;

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
        WHERE tenant_id = p_tenant_id AND role_id = p_role_id;
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
            WHILE EXISTS (SELECT 1 FROM config.roles
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
        ELSE
            SELECT role_code INTO v_existing
            FROM config.roles
            WHERE tenant_id = p_tenant_id AND role_id = p_role_id AND is_deleted = FALSE;
            IF v_existing IS NULL THEN
                RAISE EXCEPTION 'Role not found.';
            END IF;
            IF v_existing IN ('SUPER_ADMIN','SCHOOL_ADMIN','TEACHER','ACCOUNTANT','RECEPTIONIST') THEN
                RAISE EXCEPTION 'Built-in roles cannot be renamed.';
            END IF;

            UPDATE config.roles
            SET role_name = TRIM(p_role_name),
                description = NULLIF(TRIM(p_description), ''),
                updated_by = p_action_user_id, updated_at = now()
            WHERE tenant_id = p_tenant_id AND role_id = p_role_id
            RETURNING role_id INTO v_role_id;
        END IF;

        OPEN p_result FOR SELECT v_role_id AS role_id;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation: %', p_operation;
END;
$procedure$;


-- ======================================================= sp_permission_catalog
DROP PROCEDURE IF EXISTS config.sp_permission_catalog(refcursor);

CREATE OR REPLACE PROCEDURE config.sp_permission_catalog(
    INOUT p_result refcursor DEFAULT 'perm_cursor'
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    OPEN p_result FOR
    SELECT permission_id, permission_key, module_group, display_name, sort_order
    FROM   config.permissions
    WHERE  is_active = TRUE
    ORDER BY sort_order, permission_key;
END;
$procedure$;


-- =================================================== sp_role_permissions_get
DROP PROCEDURE IF EXISTS config.sp_role_permissions_get(integer, integer, integer, refcursor);

CREATE OR REPLACE PROCEDURE config.sp_role_permissions_get(
    p_tenant_id integer,
    p_school_id integer,
    p_role_id   integer,
    INOUT p_result refcursor DEFAULT 'rp_cursor'
)
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
      AND  rp.is_deleted = FALSE
      AND  rp.is_allowed = TRUE;
END;
$procedure$;


-- ================================================== sp_role_permissions_save
-- Replace the role's grants with the supplied permission_id array: anything no
-- longer present is soft-deleted; new ids are inserted (or revived).
DROP PROCEDURE IF EXISTS config.sp_role_permissions_save(
    integer, integer, integer, integer, integer[], refcursor);

CREATE OR REPLACE PROCEDURE config.sp_role_permissions_save(
    p_tenant_id      integer,
    p_school_id      integer,
    p_action_user_id integer,
    p_role_id        integer,
    p_permission_ids integer[],
    INOUT p_result   refcursor DEFAULT 'rp_save_cursor'
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_role_code text;
BEGIN
    IF p_tenant_id IS NULL OR p_tenant_id <= 1 OR p_school_id IS NULL OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid tenant/school scope.';
    END IF;

    SELECT role_code INTO v_role_code
    FROM config.roles
    WHERE tenant_id = p_tenant_id AND role_id = p_role_id AND is_deleted = FALSE;
    IF v_role_code IS NULL THEN
        RAISE EXCEPTION 'Role not found.';
    END IF;

    -- Soft-delete grants that are no longer selected.
    UPDATE config.role_permissions
    SET is_deleted = TRUE, is_allowed = FALSE, updated_by = p_action_user_id, updated_at = now()
    WHERE tenant_id = p_tenant_id AND role_id = p_role_id AND is_deleted = FALSE
      AND NOT (permission_id = ANY (COALESCE(p_permission_ids, ARRAY[]::integer[])));

    -- Revive any previously-removed grants that are selected again.
    UPDATE config.role_permissions
    SET is_deleted = FALSE, is_allowed = TRUE, updated_by = p_action_user_id, updated_at = now()
    WHERE tenant_id = p_tenant_id AND role_id = p_role_id AND is_deleted = TRUE
      AND permission_id = ANY (COALESCE(p_permission_ids, ARRAY[]::integer[]));

    -- Insert brand-new grants (those with no row at all yet).
    INSERT INTO config.role_permissions
        (tenant_id, school_id, role_id, permission_id, is_allowed, created_by, created_at)
    SELECT p_tenant_id, p_school_id, p_role_id, pid, TRUE, p_action_user_id, now()
    FROM   UNNEST(COALESCE(p_permission_ids, ARRAY[]::integer[])) AS pid
    WHERE  NOT EXISTS (
        SELECT 1 FROM config.role_permissions rp
        WHERE rp.tenant_id = p_tenant_id AND rp.role_id = p_role_id AND rp.permission_id = pid
    );

    OPEN p_result FOR SELECT p_role_id AS role_id;
END;
$procedure$;


-- =============================================== sp_role_permissions_resolve
-- Runtime resolver: the permission KEYS a role currently holds. Used by the C#
-- PermissionService (then cached). Admin bypass is handled in C#, not here.
DROP PROCEDURE IF EXISTS config.sp_role_permissions_resolve(integer, integer, integer, refcursor);

CREATE OR REPLACE PROCEDURE config.sp_role_permissions_resolve(
    p_tenant_id integer,
    p_school_id integer,
    p_role_id   integer,
    INOUT p_result refcursor DEFAULT 'resolve_cursor'
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    OPEN p_result FOR
    SELECT p.permission_key
    FROM   config.role_permissions rp
    JOIN   config.permissions p ON p.permission_id = rp.permission_id AND p.is_active = TRUE
    WHERE  rp.tenant_id = p_tenant_id
      AND  rp.role_id   = p_role_id
      AND  rp.is_deleted = FALSE
      AND  rp.is_allowed = TRUE;
END;
$procedure$;


-- ============================================================ sp_user_role_list
-- Login users in the school + their primary role, for the Users & Roles screen.
DROP PROCEDURE IF EXISTS core.sp_user_role_list(integer, integer, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_user_role_list(
    p_tenant_id integer,
    p_school_id integer,
    INOUT p_result refcursor DEFAULT 'user_role_cursor'
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id IS NULL OR p_tenant_id <= 1 OR p_school_id IS NULL OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid tenant/school scope.';
    END IF;

    OPEN p_result FOR
    SELECT u.user_id,
           u.email,
           up.full_name,
           up.phone,
           ur.role_id,
           r.role_name,
           r.role_code
    FROM   core.users u
    LEFT JOIN core.user_profiles up
           ON up.user_id = u.user_id AND up.tenant_id = u.tenant_id AND up.is_deleted = FALSE
    LEFT JOIN core.user_roles ur
           ON ur.user_id = u.user_id AND ur.tenant_id = u.tenant_id
          AND ur.is_deleted = FALSE AND ur.is_active = TRUE AND ur.is_primary = TRUE
    LEFT JOIN config.roles r
           ON r.role_id = ur.role_id AND r.tenant_id = u.tenant_id AND r.is_deleted = FALSE
    WHERE  u.tenant_id = p_tenant_id
      AND  u.is_deleted = FALSE
      AND  u.is_active = TRUE
      AND  COALESCE(r.role_code, '') <> 'SUPER_ADMIN'
    ORDER BY up.full_name, u.email;
END;
$procedure$;


-- ========================================================== sp_user_role_assign
-- Set a user's primary role. Clears any existing primary, then upserts the new
-- role as primary (revives a soft-deleted row if present).
DROP PROCEDURE IF EXISTS core.sp_user_role_assign(integer, integer, integer, integer, integer, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_user_role_assign(
    p_tenant_id      integer,
    p_school_id      integer,
    p_action_user_id integer,
    p_user_id        integer,
    p_role_id        integer,
    INOUT p_result   refcursor DEFAULT 'assign_cursor'
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id IS NULL OR p_tenant_id <= 1 OR p_school_id IS NULL OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid tenant/school scope.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM config.roles
                   WHERE tenant_id = p_tenant_id AND role_id = p_role_id AND is_deleted = FALSE) THEN
        RAISE EXCEPTION 'Role not found.';
    END IF;

    -- Demote current primary role(s) for this user.
    UPDATE core.user_roles
    SET is_primary = FALSE, updated_by = p_action_user_id, updated_at = now()
    WHERE tenant_id = p_tenant_id AND user_id = p_user_id
      AND is_deleted = FALSE AND is_primary = TRUE AND role_id <> p_role_id;

    IF EXISTS (SELECT 1 FROM core.user_roles
               WHERE tenant_id = p_tenant_id AND user_id = p_user_id AND role_id = p_role_id) THEN
        UPDATE core.user_roles
        SET is_primary = TRUE, is_active = TRUE, is_deleted = FALSE,
            school_id = p_school_id, updated_by = p_action_user_id, updated_at = now()
        WHERE tenant_id = p_tenant_id AND user_id = p_user_id AND role_id = p_role_id;
    ELSE
        INSERT INTO core.user_roles
            (tenant_id, user_id, role_id, school_id, is_primary, is_active, created_by, created_at)
        VALUES
            (p_tenant_id, p_user_id, p_role_id, p_school_id, TRUE, TRUE, p_action_user_id, now());
    END IF;

    OPEN p_result FOR SELECT p_user_id AS user_id, p_role_id AS role_id;
END;
$procedure$;


-- ========================================================= sp_user_roles_resolve
-- All active roles (id + code) for a user. Used by:
--   • PermissionService — to UNION the permissions of every role the user holds,
--     and to detect an admin role (SUPER_ADMIN / SCHOOL_ADMIN → full bypass);
--   • the People edit form — to pre-check the user's current roles.
DROP PROCEDURE IF EXISTS core.sp_user_roles_resolve(integer, integer, integer, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_user_roles_resolve(
    p_tenant_id integer,
    p_school_id integer,
    p_user_id   integer,
    INOUT p_result refcursor DEFAULT 'user_roles_cursor'
)
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
      AND  ur.is_deleted = FALSE
      AND  ur.is_active  = TRUE;
END;
$procedure$;
