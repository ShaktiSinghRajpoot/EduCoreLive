-- ============================================================
-- Feature: Change Password + forced first-login reset
-- ============================================================
-- What this script does:
--   1. Adds core.users.must_change_password (default FALSE).
--   2. Re-creates core.sp_login_management to:
--        - return must_change_password on GET_LOGIN_USER / GET_USER_BY_ID
--        - add a CHANGE_PASSWORD operation (sets the new hash, clears the flag)
--      A new p_password_hash param is appended before p_result. The old 8-arg
--      overload is dropped first so there is no ambiguous overload.
--
-- NOTE: the temp-password admin is flagged must_change_password = TRUE inside
--       core.sp_school_manage (see sp_school_manage.sql). Re-run that script too.
-- ============================================================

ALTER TABLE core.users
    ADD COLUMN IF NOT EXISTS must_change_password boolean NOT NULL DEFAULT false;

-- Drop the previous (8-arg) signature so CREATE below is the only overload.
DROP PROCEDURE IF EXISTS core.sp_login_management(
    character varying, character varying, integer, boolean,
    character varying, character varying, text, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_login_management(
    IN p_operation_type character varying,
    IN p_email character varying DEFAULT NULL::character varying,
    IN p_user_id integer DEFAULT NULL::integer,
    IN p_is_success boolean DEFAULT NULL::boolean,
    IN p_failure_reason character varying DEFAULT NULL::character varying,
    IN p_ip_address character varying DEFAULT NULL::character varying,
    IN p_user_agent text DEFAULT NULL::text,
    IN p_password_hash text DEFAULT NULL::text,
    INOUT p_result refcursor DEFAULT NULL::refcursor)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_user_id INTEGER;
    v_tenant_id INTEGER;
    v_school_id INTEGER;
BEGIN

    IF p_operation_type = 'GET_LOGIN_USER' THEN

        OPEN p_result FOR
        SELECT
            u.user_id,
            u.tenant_id,
            ur.school_id,
            u.email,
            u.password_hash,
            u.is_email_verified,
            u.is_active,
            u.is_deleted,
            u.last_login_at,
            u.must_change_password,

            up.full_name,
            up.phone,

            r.role_id,
            r.role_name,
            r.role_code
        FROM core.users u
        LEFT JOIN core.user_profiles up
            ON up.user_id = u.user_id
           AND up.tenant_id = u.tenant_id
           AND up.is_deleted = FALSE

        INNER JOIN core.user_roles ur
            ON ur.user_id = u.user_id
           AND ur.tenant_id = u.tenant_id
           AND ur.is_deleted = FALSE
           AND ur.is_active = TRUE
           AND ur.is_primary = TRUE

        INNER JOIN config.roles r
            ON r.role_id = ur.role_id
           AND r.tenant_id = u.tenant_id
           AND r.is_deleted = FALSE
           AND r.is_active = TRUE

        WHERE LOWER(u.email) = LOWER(p_email)
          AND u.is_deleted = FALSE
          AND u.is_active = TRUE
        ORDER BY
            CASE r.role_code
                WHEN 'SUPER_ADMIN' THEN 1
                WHEN 'SCHOOL_ADMIN' THEN 2
                WHEN 'TEACHER' THEN 3
                WHEN 'ACCOUNTANT' THEN 4
                WHEN 'RECEPTIONIST' THEN 5
                ELSE 99
            END
        LIMIT 1;

      ELSIF p_operation_type = 'GET_USER_ROLES' THEN

        OPEN p_result FOR
        SELECT
            u.user_id,
        u.tenant_id,
        ur.school_id,
        u.email,
        u.password_hash,
        u.is_email_verified,
        u.is_active,
        u.is_deleted,
        u.last_login_at,

        up.full_name,
        up.phone,

        r.role_id,
        r.role_name,
        r.role_code,

        ur.is_primary
        FROM core.users u
        LEFT JOIN core.user_profiles up
            ON up.user_id = u.user_id
           AND up.tenant_id = u.tenant_id
           AND up.is_deleted = FALSE

        INNER JOIN core.user_roles ur
            ON ur.user_id = u.user_id
           AND ur.tenant_id = u.tenant_id
           AND ur.is_deleted = FALSE
           AND ur.is_active = TRUE

        INNER JOIN config.roles r
            ON r.role_id = ur.role_id
           AND r.tenant_id = u.tenant_id
           AND r.is_deleted = FALSE
           AND r.is_active = TRUE

        WHERE u.user_id = p_user_id
          AND u.is_deleted = FALSE
          AND u.is_active = TRUE

        ORDER BY
            ur.is_primary DESC,
        CASE r.role_code
                WHEN 'SUPER_ADMIN' THEN 1
                WHEN 'TENANT_ADMIN' THEN 2
                WHEN 'SCHOOL_ADMIN' THEN 3
                WHEN 'TEACHER' THEN 4
                WHEN 'ACCOUNTANT' THEN 5
                WHEN 'RECEPTIONIST' THEN 6
                ELSE 99
            END;

    ELSIF p_operation_type = 'GET_USER_BY_ID' THEN

        OPEN p_result FOR
        SELECT
            u.user_id,
            u.tenant_id,
            ur.school_id,
            u.email,
            u.password_hash,
            u.is_email_verified,
            u.is_active,
            u.is_deleted,
            u.last_login_at,
            u.must_change_password,

            up.full_name,
            up.phone,

            r.role_id,
            r.role_name,
            r.role_code
        FROM core.users u
        LEFT JOIN core.user_profiles up
            ON up.user_id = u.user_id
           AND up.tenant_id = u.tenant_id
           AND up.is_deleted = FALSE

        INNER JOIN core.user_roles ur
            ON ur.user_id = u.user_id
           AND ur.tenant_id = u.tenant_id
           AND ur.is_deleted = FALSE
           AND ur.is_active = TRUE
           AND ur.is_primary = TRUE

        INNER JOIN config.roles r
            ON r.role_id = ur.role_id
           AND r.tenant_id = u.tenant_id
           AND r.is_deleted = FALSE
           AND r.is_active = TRUE

        WHERE u.user_id = p_user_id
          AND u.is_deleted = FALSE
          AND u.is_active = TRUE
        ORDER BY
            CASE r.role_code
                WHEN 'SUPER_ADMIN' THEN 1
                WHEN 'SCHOOL_ADMIN' THEN 2
                WHEN 'TEACHER' THEN 3
                WHEN 'ACCOUNTANT' THEN 4
                WHEN 'RECEPTIONIST' THEN 5
                ELSE 99
            END
        LIMIT 1;

    ELSIF p_operation_type = 'SAVE_LOGIN_ATTEMPT' THEN

        SELECT
            u.user_id,
            u.tenant_id,
            ur.school_id
        INTO
            v_user_id,
            v_tenant_id,
            v_school_id
        FROM core.users u
        LEFT JOIN core.user_roles ur
            ON ur.user_id = u.user_id
           AND ur.tenant_id = u.tenant_id
           AND ur.is_deleted = FALSE
           AND ur.is_primary = TRUE
        WHERE LOWER(u.email) = LOWER(p_email)
          AND u.is_deleted = FALSE
        LIMIT 1;

        INSERT INTO core.login_attempts
        (
            tenant_id,
            user_id,
            school_id,
            email,
            ip_address,
            user_agent,
            is_success,
            failure_reason,
            created_by,
            created_at,
            is_deleted
        )
        VALUES
        (
            v_tenant_id,
            v_user_id,
            v_school_id,
            p_email,
            p_ip_address,
            p_user_agent,
            COALESCE(p_is_success, FALSE),
            p_failure_reason,
            v_user_id,
            CURRENT_TIMESTAMP,
            FALSE
        );

    ELSIF p_operation_type = 'SAVE_USER_SESSION' THEN

        SELECT
            u.user_id,
            u.tenant_id,
            ur.school_id
        INTO
            v_user_id,
            v_tenant_id,
            v_school_id
        FROM core.users u
        LEFT JOIN core.user_roles ur
            ON ur.user_id = u.user_id
           AND ur.tenant_id = u.tenant_id
           AND ur.is_deleted = FALSE
           AND ur.is_primary = TRUE
        WHERE u.user_id = p_user_id
          AND u.is_deleted = FALSE
        LIMIT 1;

        INSERT INTO core.user_sessions
        (
            tenant_id,
            user_id,
            school_id,
            ip_address,
            user_agent,
            login_at,
            expires_at,
            is_active,
            created_by,
            created_at,
            is_deleted
        )
        VALUES
        (
            v_tenant_id,
            p_user_id,
            v_school_id,
            p_ip_address,
            p_user_agent,
            CURRENT_TIMESTAMP,
            CURRENT_TIMESTAMP + INTERVAL '8 hours',
            TRUE,
            p_user_id,
            CURRENT_TIMESTAMP,
            FALSE
        );

        UPDATE core.users
        SET last_login_at = CURRENT_TIMESTAMP,
            updated_by = p_user_id,
            updated_at = CURRENT_TIMESTAMP
        WHERE user_id = p_user_id;

    ELSIF p_operation_type = 'CHANGE_PASSWORD' THEN

        -- user_id is the global IDENTITY PK, so scoping by it is tenant-safe.
        UPDATE core.users
        SET password_hash = p_password_hash,
            must_change_password = FALSE,
            updated_by = p_user_id,
            updated_at = CURRENT_TIMESTAMP
        WHERE user_id = p_user_id
          AND is_deleted = FALSE
          AND is_active = TRUE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'User not found or inactive.';
        END IF;

    ELSE
        RAISE EXCEPTION 'Invalid operation type: %', p_operation_type;
    END IF;

END;
$procedure$;
