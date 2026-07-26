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
    -- p_email is really an IDENTIFIER: an email address OR a mobile number.
    -- Digits-only, so '+91 86016-33239' and '8601633239' are the same person.
    -- An email yields far fewer than 10 digits, so it can never be mistaken for
    -- a phone (see the length check in the WHERE clauses below).
    v_digits TEXT;
BEGIN
    v_digits := regexp_replace(COALESCE(p_email, ''), '\D', '', 'g');

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
            r.role_code,

            -- School gate. Returned as DATA rather than filtering the user out, on
            -- purpose: AccountController checks these only AFTER BCrypt.Verify
            -- succeeds. If the row were filtered here, "your school is suspended"
            -- would be learnable by anyone who guessed an email — an enumeration
            -- vector. This way only someone with the correct password sees it.
            -- A deleted/disabled school is blocked whatever its status says.
            COALESCE(
                CASE WHEN COALESCE(ur.school_id, 0) = 0      THEN TRUE    -- super admin, no school
                     WHEN sc.school_id IS NULL               THEN FALSE   -- school row gone
                     WHEN sc.is_deleted OR NOT sc.is_active  THEN FALSE   -- deleted / disabled
                     ELSE st.allows_login
                END, FALSE)                          AS school_allows_login,
            COALESCE(st.status_code, 'UNKNOWN')      AS school_status_code,
            CASE WHEN COALESCE(ur.school_id, 0) > 0
                      AND (sc.school_id IS NULL OR sc.is_deleted OR NOT sc.is_active)
                 THEN 'This school is closed and no longer accessible.'
                 ELSE st.login_message
            END                                      AS school_login_message
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

        -- LEFT, not INNER: a super admin has school_id = 0 and no row in
        -- core.schools — an INNER JOIN would lock the platform admin out.
        -- No is_deleted filter here either: the CASE above needs to SEE a deleted
        -- school in order to block it, rather than have the row vanish.
        LEFT JOIN core.schools sc
            ON sc.school_id = ur.school_id
        LEFT JOIN config.school_statuses st
            ON st.school_status_id = sc.status_id
           AND st.is_deleted = FALSE

        -- Email OR phone. Matches how core.sp_password_reset already resolves a
        -- user, and is backed by uq_user_phone_active so a number can only ever
        -- point at one signed-in-able account (see user_login_by_phone.sql).
        WHERE (
                LOWER(TRIM(u.email)) = LOWER(TRIM(p_email))
                OR (
                        length(v_digits) >= 10
                    AND up.phone IS NOT NULL
                    AND up.is_active = TRUE
                    AND right(regexp_replace(up.phone, '\D', '', 'g'), 10) = right(v_digits, 10)
                   )
              )
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
        -- Joined so an attempt made with a PHONE is still attributed to the right
        -- user; without it a phone login would log an anonymous attempt.
        LEFT JOIN core.user_profiles up
            ON up.user_id = u.user_id
           AND up.tenant_id = u.tenant_id
           AND up.is_deleted = FALSE
        WHERE (
                LOWER(TRIM(u.email)) = LOWER(TRIM(p_email))
                OR (
                        length(v_digits) >= 10
                    AND up.phone IS NOT NULL
                    AND right(regexp_replace(up.phone, '\D', '', 'g'), 10) = right(v_digits, 10)
                   )
              )
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
