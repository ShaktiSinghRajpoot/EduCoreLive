-- ============================================================================
-- sp_school_user_management — CRUD for the school's own login users.
--
-- Dumped from the live DB (pg_get_functiondef) so the email guard below has a
-- source file, per the repo convention. Edit here and re-apply with psql -f.
--
-- The only change from the original: the CREATE branch's duplicate-email check
-- now calls core.fn_user_email_taken (Database/user_email_unique.sql) instead of
-- an inline tenant+school-scoped EXISTS. That check was narrower than reality —
-- login resolves an email with NO tenant filter, so an address already used in
-- ANOTHER tenant passed this check and then hit uq_user_email_active with a raw
-- Postgres error instead of the friendly 'Email already exists.' message.
-- ============================================================================

CREATE OR REPLACE PROCEDURE core.sp_school_user_management(IN p_operation_type character varying, IN p_tenant_id integer, IN p_school_id integer, IN p_user_id integer DEFAULT NULL::integer, IN p_email character varying DEFAULT NULL::character varying, IN p_password_hash text DEFAULT NULL::text, IN p_full_name character varying DEFAULT NULL::character varying, IN p_phone character varying DEFAULT NULL::character varying, IN p_designation character varying DEFAULT NULL::character varying, IN p_role_id integer DEFAULT NULL::integer, IN p_is_active boolean DEFAULT NULL::boolean, IN p_action_by integer DEFAULT NULL::integer, INOUT p_result refcursor DEFAULT NULL::refcursor)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_new_user_id integer;
BEGIN

    IF p_operation_type = 'LIST' THEN

        OPEN p_result FOR
        SELECT
            u.user_id,
            u.email,
            u.is_active,
            u.created_at,
            up.full_name,
            up.phone,
            up.designation,
            r.role_id,
            r.role_name
        FROM core.users u
        LEFT JOIN core.user_profiles up
            ON up.tenant_id = u.tenant_id
           AND up.school_id = u.school_id
           AND up.user_id = u.user_id
           AND up.is_deleted = false
        LEFT JOIN core.user_roles ur
            ON ur.tenant_id = u.tenant_id
           AND ur.school_id = u.school_id
           AND ur.user_id = u.user_id
           AND ur.is_deleted = false
        LEFT JOIN config.roles r
            ON r.role_id = ur.role_id
           AND r.is_deleted = false
        WHERE u.tenant_id = p_tenant_id
          AND u.school_id = p_school_id
          AND u.is_deleted = false
        ORDER BY u.created_at DESC;

    ELSIF p_operation_type = 'GET_BY_ID' THEN

        OPEN p_result FOR
        SELECT
            u.user_id,
            u.email,
            u.is_active,
            up.full_name,
            up.phone,
            up.alternate_phone,
            up.designation,
            up.profile_photo_url,
            r.role_id,
            r.role_name
        FROM core.users u
        LEFT JOIN core.user_profiles up
            ON up.tenant_id = u.tenant_id
           AND up.school_id = u.school_id
           AND up.user_id = u.user_id
           AND up.is_deleted = false
        LEFT JOIN core.user_roles ur
            ON ur.tenant_id = u.tenant_id
           AND ur.school_id = u.school_id
           AND ur.user_id = u.user_id
           AND ur.is_deleted = false
        LEFT JOIN config.roles r
            ON r.role_id = ur.role_id
           AND r.is_deleted = false
        WHERE u.tenant_id = p_tenant_id
          AND u.school_id = p_school_id
          AND u.user_id = p_user_id
          AND u.is_deleted = false;

    ELSIF p_operation_type = 'CREATE' THEN

        -- Global, not tenant+school scoped: login resolves an email with no tenant
        -- filter, so an address already live in another tenant must be refused here
        -- rather than failing later on uq_user_email_active.
        IF core.fn_user_email_taken(p_email) THEN
            OPEN p_result FOR SELECT false AS success, 'Email already exists.' AS message;
            RETURN;
        END IF;

        INSERT INTO core.users
        (
            tenant_id, school_id, email, password_hash,
            is_email_verified, is_active,
            created_by
        )
        VALUES
        (
            p_tenant_id, p_school_id, LOWER(p_email), p_password_hash,
             false, true,
            p_action_by
        )
        RETURNING user_id INTO v_new_user_id;

        INSERT INTO core.user_profiles
        (
            tenant_id, school_id, user_id,
            full_name, phone, designation,
            created_by
        )
        VALUES
        (
            p_tenant_id, p_school_id, v_new_user_id,
            p_full_name, p_phone, p_designation,
            p_action_by
        );

        INSERT INTO core.user_roles
        (
            tenant_id, school_id, user_id, role_id,
            created_by
        )
        VALUES
        (
            p_tenant_id, p_school_id, v_new_user_id, p_role_id,
            p_action_by
        );

        INSERT INTO core.admin_activity_logs
        (
            tenant_id, school_id, user_id,
            action, module_name, table_name, record_id,
            description, created_by
        )
        VALUES
        (
            p_tenant_id, p_school_id, p_action_by,
            'CREATE_USER', 'School User Management', 'core.users', v_new_user_id,
            'School user created: ' || p_email,
            p_action_by
        );

        OPEN p_result FOR
        SELECT true AS success, 'User created successfully.' AS message, v_new_user_id AS user_id;

    ELSIF p_operation_type = 'UPDATE' THEN

        UPDATE core.users
        SET
            email = LOWER(p_email),
            updated_by = p_action_by,
            updated_at = CURRENT_TIMESTAMP
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND user_id = p_user_id
          AND is_deleted = false;

        UPDATE core.user_profiles
        SET
            full_name = p_full_name,
            phone = p_phone,
            designation = p_designation,
            updated_by = p_action_by,
            updated_at = CURRENT_TIMESTAMP
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND user_id = p_user_id
          AND is_deleted = false;

        UPDATE core.user_roles
        SET
            role_id = p_role_id,
            updated_by = p_action_by,
            updated_at = CURRENT_TIMESTAMP
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND user_id = p_user_id
          AND is_deleted = false;

        OPEN p_result FOR
        SELECT true AS success, 'User updated successfully.' AS message;

    ELSIF p_operation_type = 'SOFT_DELETE' THEN

        UPDATE core.users
        SET
            is_deleted = true,
            is_active = false,
            deleted_by = p_action_by,
            deleted_at = CURRENT_TIMESTAMP
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND user_id = p_user_id
          AND is_deleted = false;

        UPDATE core.user_roles
        SET
            is_deleted = true,
            is_active = false,
            deleted_by = p_action_by,
            deleted_at = CURRENT_TIMESTAMP
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND user_id = p_user_id
          AND is_deleted = false;

        OPEN p_result FOR
        SELECT true AS success, 'User deleted successfully.' AS message;

    ELSIF p_operation_type = 'CHANGE_STATUS' THEN

        UPDATE core.users
        SET
            is_active = p_is_active,
            updated_by = p_action_by,
            updated_at = CURRENT_TIMESTAMP
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND user_id = p_user_id
          AND is_deleted = false;

        OPEN p_result FOR
        SELECT true AS success, 'User status updated successfully.' AS message;

    END IF;

END;
$procedure$

;
