CREATE OR REPLACE PROCEDURE core.sp_school_manage(IN p_operation character varying, IN p_tenant_id integer, IN p_action_user_id integer, IN p_tenant_mode character varying DEFAULT NULL::character varying, IN p_selected_tenant_id integer DEFAULT NULL::integer, IN p_tenant_name character varying DEFAULT NULL::character varying, IN p_tenant_code character varying DEFAULT NULL::character varying, IN p_tenant_email character varying DEFAULT NULL::character varying, IN p_tenant_phone character varying DEFAULT NULL::character varying, IN p_school_id integer DEFAULT NULL::integer, IN p_school_name character varying DEFAULT NULL::character varying, IN p_display_name character varying DEFAULT NULL::character varying, IN p_status_id integer DEFAULT NULL::integer, IN p_registration_number character varying DEFAULT NULL::character varying, IN p_affiliation_number character varying DEFAULT NULL::character varying, IN p_board_id integer DEFAULT NULL::integer, IN p_school_type_id integer DEFAULT NULL::integer, IN p_ownership_type_id integer DEFAULT NULL::integer, IN p_medium_id integer DEFAULT NULL::integer, IN p_established_year integer DEFAULT NULL::integer, IN p_website character varying DEFAULT NULL::character varying, IN p_address_type_id integer DEFAULT NULL::integer, IN p_address_line1 character varying DEFAULT NULL::character varying, IN p_address_line2 character varying DEFAULT NULL::character varying, IN p_city character varying DEFAULT NULL::character varying, IN p_district character varying DEFAULT NULL::character varying, IN p_state character varying DEFAULT NULL::character varying, IN p_pincode character varying DEFAULT NULL::character varying, IN p_contact_type_id integer DEFAULT NULL::integer, IN p_contact_name character varying DEFAULT NULL::character varying, IN p_designation character varying DEFAULT NULL::character varying, IN p_contact_email character varying DEFAULT NULL::character varying, IN p_phone character varying DEFAULT NULL::character varying, IN p_alternate_phone character varying DEFAULT NULL::character varying, IN p_academic_year_id integer DEFAULT NULL::integer, IN p_date_format_id integer DEFAULT NULL::integer, IN p_time_format_id integer DEFAULT NULL::integer, IN p_enable_sms boolean DEFAULT false, IN p_enable_email boolean DEFAULT false, IN p_enable_whatsapp boolean DEFAULT false, IN p_create_school_admin boolean DEFAULT false, IN p_admin_full_name character varying DEFAULT NULL::character varying, IN p_admin_email character varying DEFAULT NULL::character varying, IN p_admin_phone character varying DEFAULT NULL::character varying, IN p_password_hash character varying DEFAULT NULL::character varying, INOUT p_result refcursor DEFAULT 'school_cursor'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_school_id integer;
    v_tenant_id integer;
    v_school_code character varying;
    v_user_id integer;
BEGIN
    IF p_operation IS NULL OR TRIM(p_operation) = '' THEN
        RAISE EXCEPTION 'Operation is required.';
    END IF;

    p_operation := UPPER(TRIM(p_operation));

    /*
        LIST
    */
    IF p_operation = 'LIST' THEN
        OPEN p_result FOR
        SELECT
            s.school_id,
            s.school_code,
            s.school_name,
            s.display_name,
            t.tenant_name,
            st.name AS status_name,
            b.name AS board_name,
            sty.name AS school_type_name,
            a.city,
            a.state,
            c.contact_name,
            c.phone,
            s.created_at
        FROM core.schools s
        INNER JOIN core.tenants t
            ON t.tenant_id = s.tenant_id
           AND t.is_deleted = FALSE
        LEFT JOIN core.school_profiles sp
            ON sp.tenant_id = s.tenant_id
           AND sp.school_id = s.school_id
           AND sp.is_deleted = FALSE
           AND sp.is_active = TRUE
        LEFT JOIN config.school_statuses st
            ON st.school_status_id = s.status_id
           AND st.is_deleted = FALSE
        LEFT JOIN config.boards b
            ON b.board_id = sp.board_id
           AND b.is_deleted = FALSE
        LEFT JOIN config.school_types sty
            ON sty.school_type_id = sp.school_type_id
           AND sty.is_deleted = FALSE
        LEFT JOIN core.school_addresses a
            ON a.tenant_id = s.tenant_id
           AND a.school_id = s.school_id
           AND a.is_primary = TRUE
           AND a.is_active = TRUE
           AND a.is_deleted = FALSE
        LEFT JOIN core.school_contacts c
            ON c.tenant_id = s.tenant_id
           AND c.school_id = s.school_id
           AND c.is_primary = TRUE
           AND c.is_active = TRUE
           AND c.is_deleted = FALSE
        WHERE s.is_active = TRUE
          AND s.is_deleted = FALSE
          AND (
                p_tenant_id = 1
                OR s.tenant_id = p_tenant_id
              )
        ORDER BY s.school_id DESC;

        RETURN;
    END IF;

    /*
        GET BY ID
    */
    IF p_operation = 'GET' THEN
        IF p_school_id IS NULL OR p_school_id <= 0 THEN
            RAISE EXCEPTION 'School id is required.';
        END IF;

        OPEN p_result FOR
        SELECT
            s.tenant_id,
            t.tenant_name,
            t.tenant_code,
            s.school_id,
            s.school_code,
            s.school_name,
            s.display_name,
            s.status_id,

            sp.registration_number,
            sp.affiliation_number,
            sp.board_id,
            sp.school_type_id,
            sp.ownership_type_id,
            sp.medium_id,
            sp.established_year,
            sp.website,
            sp.logo_url,
            sp.header_image_url,
            sp.description,

            a.address_type_id,
            a.address_line1,
            a.address_line2,
            a.city,
            a.district,
            a.state,
            a.pincode,

            c.contact_type_id,
            c.contact_name,
            c.designation,
            c.email,
            c.phone,
            c.alternate_phone,

            ss.academic_year_id,
            ss.date_format_id,
            ss.time_format_id,
            COALESCE(ss.enable_sms, FALSE) AS enable_sms,
            COALESCE(ss.enable_email, FALSE) AS enable_email,
            COALESCE(ss.enable_whatsapp, FALSE) AS enable_whatsapp,

            adm.user_id   AS admin_user_id,
            adm.full_name AS admin_full_name,
            adm.email     AS admin_email,
            adm.phone     AS admin_phone
        FROM core.schools s
        LEFT JOIN core.tenants t
            ON t.tenant_id = s.tenant_id
           AND t.is_deleted = FALSE
        LEFT JOIN core.school_profiles sp
            ON sp.tenant_id = s.tenant_id
           AND sp.school_id = s.school_id
           AND sp.is_deleted = FALSE
        LEFT JOIN core.school_addresses a
            ON a.tenant_id = s.tenant_id
           AND a.school_id = s.school_id
           AND a.is_primary = TRUE
           AND a.is_active = TRUE
           AND a.is_deleted = FALSE
        LEFT JOIN core.school_contacts c
            ON c.tenant_id = s.tenant_id
           AND c.school_id = s.school_id
           AND c.is_primary = TRUE
           AND c.is_active = TRUE
           AND c.is_deleted = FALSE
        LEFT JOIN core.school_settings ss
            ON ss.tenant_id = s.tenant_id
           AND ss.school_id = s.school_id
           AND ss.is_deleted = FALSE
        -- primary SCHOOL_ADMIN for this school (for edit pre-fill)
        LEFT JOIN LATERAL (
            SELECT u.user_id, u.email, up.full_name, up.phone
            FROM core.user_roles ur
            JOIN config.roles r
                ON r.role_id = ur.role_id
               AND r.tenant_id = s.tenant_id
               AND r.role_code = 'SCHOOL_ADMIN'
            JOIN core.users u
                ON u.user_id = ur.user_id
               AND u.is_active = TRUE
               AND u.is_deleted = FALSE
            LEFT JOIN core.user_profiles up
                ON up.user_id = u.user_id
               AND up.tenant_id = u.tenant_id
               AND up.is_deleted = FALSE
            WHERE ur.tenant_id = s.tenant_id
              AND ur.school_id = s.school_id
              AND ur.is_active = TRUE
              AND ur.is_deleted = FALSE
            ORDER BY ur.is_primary DESC, u.user_id
            LIMIT 1
        ) adm ON TRUE
        WHERE s.school_id = p_school_id
          AND (p_tenant_id = 1 OR s.tenant_id = p_tenant_id)
          AND s.is_active = TRUE
          AND s.is_deleted = FALSE;

        RETURN;
    END IF;

    /*
        DELETE / SOFT DELETE
    */
    IF p_operation = 'DELETE' THEN
        IF p_school_id IS NULL OR p_school_id <= 0 THEN
            RAISE EXCEPTION 'School id is required.';
        END IF;

        UPDATE core.schools
        SET
            is_active = FALSE,
            is_deleted = TRUE,
            deleted_by = p_action_user_id,
            deleted_at = NOW(),
            updated_by = p_action_user_id,
            updated_at = NOW()
        WHERE school_id = p_school_id
          AND (p_tenant_id = 1 OR tenant_id = p_tenant_id)
          AND is_deleted = FALSE;

        OPEN p_result FOR
        SELECT p_school_id AS school_id;

        RETURN;
    END IF;

    /*
        INSERT / UPDATE VALIDATION
    */
    IF p_operation NOT IN ('INSERT', 'UPDATE') THEN
        RAISE EXCEPTION 'Invalid operation: %', p_operation;
    END IF;

    IF p_school_name IS NULL OR TRIM(p_school_name) = '' THEN
        RAISE EXCEPTION 'School name is required.';
    END IF;

    IF p_status_id IS NULL OR p_status_id <= 0 THEN
        RAISE EXCEPTION 'Status is required.';
    END IF;

    IF p_address_line1 IS NULL OR TRIM(p_address_line1) = '' THEN
        RAISE EXCEPTION 'Address line 1 is required.';
    END IF;

    IF p_city IS NULL OR TRIM(p_city) = '' THEN
        RAISE EXCEPTION 'City is required.';
    END IF;

    IF p_state IS NULL OR TRIM(p_state) = '' THEN
        RAISE EXCEPTION 'State is required.';
    END IF;

    IF p_pincode IS NULL OR TRIM(p_pincode) = '' THEN
        RAISE EXCEPTION 'Pincode is required.';
    END IF;

    IF TRIM(p_pincode) !~ '^[0-9]{6}$' THEN
        RAISE EXCEPTION 'Pincode must be 6 digits.';
    END IF;

    IF p_contact_name IS NULL OR TRIM(p_contact_name) = '' THEN
        RAISE EXCEPTION 'Contact name is required.';
    END IF;

    IF p_phone IS NULL OR TRIM(p_phone) = '' THEN
        RAISE EXCEPTION 'Phone is required.';
    END IF;

    /*
        TENANT RESOLUTION
    */
    IF p_operation = 'INSERT' THEN
        IF p_tenant_mode = 'existing' THEN
            IF p_selected_tenant_id IS NULL OR p_selected_tenant_id <= 0 THEN
                RAISE EXCEPTION 'Please select tenant.';
            END IF;

            IF NOT EXISTS (
                SELECT 1
                FROM core.tenants
                WHERE tenant_id = p_selected_tenant_id
                  AND is_active = TRUE
                  AND is_deleted = FALSE
            ) THEN
                RAISE EXCEPTION 'Selected tenant does not exist.';
            END IF;

            v_tenant_id := p_selected_tenant_id;

        ELSIF p_tenant_mode = 'new' THEN
            IF p_tenant_name IS NULL OR TRIM(p_tenant_name) = '' THEN
                RAISE EXCEPTION 'Tenant name is required.';
            END IF;

            IF p_tenant_code IS NULL OR TRIM(p_tenant_code) = '' THEN
                RAISE EXCEPTION 'Tenant code is required.';
            END IF;

            IF EXISTS (
                SELECT 1
                FROM core.tenants
                WHERE LOWER(TRIM(tenant_code)) = LOWER(TRIM(p_tenant_code))
                  AND is_deleted = FALSE
            ) THEN
                RAISE EXCEPTION 'Tenant code already exists.';
            END IF;

            IF p_tenant_email IS NOT NULL
               AND TRIM(p_tenant_email) <> ''
               AND EXISTS (
                    SELECT 1
                    FROM core.tenants
                    WHERE LOWER(TRIM(contact_email)) = LOWER(TRIM(p_tenant_email))
                      AND is_deleted = FALSE
               ) THEN
                RAISE EXCEPTION 'Tenant email already exists.';
            END IF;

            INSERT INTO core.tenants
            (
                tenant_name,
                tenant_code,
                contact_email,
                contact_phone,
                is_active,
                created_by,
                created_at
            )
            VALUES
            (
                TRIM(p_tenant_name),
                LOWER(TRIM(p_tenant_code)),
                NULLIF(TRIM(p_tenant_email), ''),
                NULLIF(TRIM(p_tenant_phone), ''),
                TRUE,
                p_action_user_id,
                NOW()
            )
            RETURNING tenant_id INTO v_tenant_id;

        ELSE
            RAISE EXCEPTION 'Tenant option is required.';
        END IF;
    ELSE
        -- UPDATE: the platform super admin (tenant 1) may edit a school on any tenant,
        -- so resolve the school's own tenant; a school-scoped user stays on their tenant.
        IF p_tenant_id = 1 THEN
            SELECT tenant_id INTO v_tenant_id
            FROM core.schools
            WHERE school_id = p_school_id
              AND is_deleted = FALSE;
        ELSE
            v_tenant_id := p_tenant_id;
        END IF;
    END IF;

    IF v_tenant_id IS NULL OR v_tenant_id <= 0 THEN
        RAISE EXCEPTION 'Tenant id is required.';
    END IF;

    /*
        SCHOOL DUPLICATE VALIDATION
    */
    IF EXISTS (
        SELECT 1
        FROM core.schools
        WHERE tenant_id = v_tenant_id
          AND LOWER(TRIM(school_name)) = LOWER(TRIM(p_school_name))
          AND is_deleted = FALSE
          AND (p_operation = 'INSERT' OR school_id <> p_school_id)
    ) THEN
        RAISE EXCEPTION 'School name already exists for this tenant.';
    END IF;

    IF p_registration_number IS NOT NULL
       AND TRIM(p_registration_number) <> ''
       AND EXISTS (
            SELECT 1
            FROM core.school_profiles sp
            WHERE sp.tenant_id = v_tenant_id
              AND LOWER(TRIM(sp.registration_number)) = LOWER(TRIM(p_registration_number))
              AND sp.is_deleted = FALSE
              AND (p_operation = 'INSERT' OR sp.school_id <> p_school_id)
       ) THEN
        RAISE EXCEPTION 'Registration number already exists for this tenant.';
    END IF;

    IF p_affiliation_number IS NOT NULL
       AND TRIM(p_affiliation_number) <> ''
       AND EXISTS (
            SELECT 1
            FROM core.school_profiles sp
            WHERE sp.tenant_id = v_tenant_id
              AND LOWER(TRIM(sp.affiliation_number)) = LOWER(TRIM(p_affiliation_number))
              AND sp.is_deleted = FALSE
              AND (p_operation = 'INSERT' OR sp.school_id <> p_school_id)
       ) THEN
        RAISE EXCEPTION 'Affiliation number already exists for this tenant.';
    END IF;

    /*
        ADMIN VALIDATION
    */
    IF COALESCE(p_create_school_admin, FALSE) = TRUE THEN
        IF p_admin_full_name IS NULL OR TRIM(p_admin_full_name) = '' THEN
            RAISE EXCEPTION 'Admin full name is required.';
        END IF;

        IF p_admin_email IS NULL OR TRIM(p_admin_email) = '' THEN
            RAISE EXCEPTION 'Admin email is required.';
        END IF;

        IF p_operation = 'INSERT'
           AND EXISTS (
                SELECT 1
                FROM core.users
                WHERE LOWER(TRIM(email)) = LOWER(TRIM(p_admin_email))
                  AND is_active = TRUE
           ) THEN
            RAISE EXCEPTION 'Admin email already exists.';
        END IF;

        -- Phone must be unique across active login users (mirrors the email rule).
        IF p_operation = 'INSERT'
           AND p_admin_phone IS NOT NULL AND TRIM(p_admin_phone) <> ''
           AND EXISTS (
                SELECT 1
                FROM core.user_profiles
                WHERE TRIM(phone) = TRIM(p_admin_phone)
                  AND is_active = TRUE
                  AND is_deleted = FALSE
           ) THEN
            RAISE EXCEPTION 'Admin phone already exists.';
        END IF;
    END IF;

    /*
        INSERT / UPDATE SCHOOL MASTER
        Only basic school fields should be stored in core.schools.
    */
    IF p_operation = 'INSERT' THEN
        v_school_code := 'SCH' || TO_CHAR(NOW(), 'YYYYMMDDHH24MISS');

        INSERT INTO core.schools
        (
            tenant_id,
            school_code,
            school_name,
            display_name,
            status_id,
            is_active,
            created_by,
            created_at
        )
        VALUES
        (
            v_tenant_id,
            v_school_code,
            TRIM(p_school_name),
            NULLIF(TRIM(p_display_name), ''),
            p_status_id,
            TRUE,
            p_action_user_id,
            NOW()
        )
        RETURNING school_id INTO v_school_id;

    ELSE
        IF p_school_id IS NULL OR p_school_id <= 0 THEN
            RAISE EXCEPTION 'School id is required.';
        END IF;

        IF NOT EXISTS (
            SELECT 1
            FROM core.schools
            WHERE school_id = p_school_id
              AND tenant_id = v_tenant_id
              AND is_active = TRUE
              AND is_deleted = FALSE
        ) THEN
            RAISE EXCEPTION 'School not found.';
        END IF;

        v_school_id := p_school_id;

        UPDATE core.schools
        SET
            school_name = TRIM(p_school_name),
            display_name = NULLIF(TRIM(p_display_name), ''),
            status_id = p_status_id,
            updated_by = p_action_user_id,
            updated_at = NOW()
        WHERE school_id = v_school_id
          AND tenant_id = v_tenant_id;
    END IF;

    /*
        SCHOOL PROFILE UPSERT
    */
    INSERT INTO core.school_profiles
    (
        tenant_id,
        school_id,
        registration_number,
        affiliation_number,
        board_id,
        school_type_id,
        ownership_type_id,
        medium_id,
        established_year,
        website,
        is_active,
        created_by,
        created_at
    )
    VALUES
    (
        v_tenant_id,
        v_school_id,
        NULLIF(TRIM(p_registration_number), ''),
        NULLIF(TRIM(p_affiliation_number), ''),
        p_board_id,
        p_school_type_id,
        p_ownership_type_id,
        p_medium_id,
        p_established_year,
        NULLIF(TRIM(p_website), ''),
        TRUE,
        p_action_user_id,
        NOW()
    )
    ON CONFLICT (tenant_id, school_id)
    DO UPDATE SET
        registration_number = EXCLUDED.registration_number,
        affiliation_number = EXCLUDED.affiliation_number,
        board_id = EXCLUDED.board_id,
        school_type_id = EXCLUDED.school_type_id,
        ownership_type_id = EXCLUDED.ownership_type_id,
        medium_id = EXCLUDED.medium_id,
        established_year = EXCLUDED.established_year,
        website = EXCLUDED.website,
        is_active = TRUE,
        is_deleted = FALSE,
        updated_by = p_action_user_id,
        updated_at = NOW();

    /*
        ADDRESS UPSERT
    */
    INSERT INTO core.school_addresses
    (
        tenant_id,
        school_id,
        address_type_id,
        address_line1,
        address_line2,
        city,
        district,
        state,
        pincode,
        is_primary,
        is_active,
        created_by,
        created_at
    )
    VALUES
    (
        v_tenant_id,
        v_school_id,
        COALESCE(p_address_type_id, 1),
        TRIM(p_address_line1),
        NULLIF(TRIM(p_address_line2), ''),
        TRIM(p_city),
        NULLIF(TRIM(p_district), ''),
        TRIM(p_state),
        TRIM(p_pincode),
        TRUE,
        TRUE,
        p_action_user_id,
        NOW()
    )
    ON CONFLICT (tenant_id, school_id, address_type_id)
    DO UPDATE SET
        address_line1 = EXCLUDED.address_line1,
        address_line2 = EXCLUDED.address_line2,
        city = EXCLUDED.city,
        district = EXCLUDED.district,
        state = EXCLUDED.state,
        pincode = EXCLUDED.pincode,
        is_primary = TRUE,
        is_active = TRUE,
        is_deleted = FALSE,
        updated_by = p_action_user_id,
        updated_at = NOW();

    /*
        CONTACT UPSERT
    */
    INSERT INTO core.school_contacts
    (
        tenant_id,
        school_id,
        contact_type_id,
        contact_name,
        designation,
        email,
        phone,
        alternate_phone,
        is_primary,
        is_active,
        created_by,
        created_at
    )
    VALUES
    (
        v_tenant_id,
        v_school_id,
        COALESCE(p_contact_type_id, 1),
        TRIM(p_contact_name),
        NULLIF(TRIM(p_designation), ''),
        NULLIF(TRIM(p_contact_email), ''),
        TRIM(p_phone),
        NULLIF(TRIM(p_alternate_phone), ''),
        TRUE,
        TRUE,
        p_action_user_id,
        NOW()
    )
    ON CONFLICT (tenant_id, school_id, contact_type_id)
    DO UPDATE SET
        contact_name = EXCLUDED.contact_name,
        designation = EXCLUDED.designation,
        email = EXCLUDED.email,
        phone = EXCLUDED.phone,
        alternate_phone = EXCLUDED.alternate_phone,
        is_primary = TRUE,
        is_active = TRUE,
        is_deleted = FALSE,
        updated_by = p_action_user_id,
        updated_at = NOW();

    /*
        SETTINGS UPSERT
    */
    INSERT INTO core.school_settings
    (
        tenant_id,
        school_id,
        academic_year_id,
        date_format_id,
        time_format_id,
        enable_sms,
        enable_email,
        enable_whatsapp,
        is_active,
        created_by,
        created_at
    )
    VALUES
    (
        v_tenant_id,
        v_school_id,
        p_academic_year_id,
        p_date_format_id,
        p_time_format_id,
        COALESCE(p_enable_sms, FALSE),
        COALESCE(p_enable_email, FALSE),
        COALESCE(p_enable_whatsapp, FALSE),
        TRUE,
        p_action_user_id,
        NOW()
    )
    ON CONFLICT (tenant_id, school_id)
    DO UPDATE SET
        academic_year_id = EXCLUDED.academic_year_id,
        date_format_id = EXCLUDED.date_format_id,
        time_format_id = EXCLUDED.time_format_id,
        enable_sms = EXCLUDED.enable_sms,
        enable_email = EXCLUDED.enable_email,
        enable_whatsapp = EXCLUDED.enable_whatsapp,
        is_active = TRUE,
        is_deleted = FALSE,
        updated_by = p_action_user_id,
        updated_at = NOW();

    /*
        CREATE SCHOOL ADMIN
    */
    IF p_operation = 'INSERT' AND COALESCE(p_create_school_admin, FALSE) = TRUE THEN
        INSERT INTO core.users
        (
            tenant_id,
            school_id,
            email,
            password_hash,
            --role_id,
            is_active,
            must_change_password,
            created_by,
            created_at
        )
        VALUES
        (
            v_tenant_id,
            v_school_id,
            LOWER(TRIM(p_admin_email)),
            p_password_hash,
           -- 3,
            TRUE,
            TRUE,   -- force the emailed temp-password admin to reset on first login
            p_action_user_id,
            NOW()
        )
        RETURNING user_id INTO v_user_id;

        INSERT INTO core.user_profiles
        (
            tenant_id,
            user_id,
            school_id,
            full_name,
            phone,
            designation,
            is_active,
            created_by,
            created_at
        )
        VALUES
        (
            v_tenant_id,
            v_user_id,
            v_school_id,
            TRIM(p_admin_full_name),
            NULLIF(TRIM(p_admin_phone), ''),
            'School Admin',
            TRUE,
            p_action_user_id,
            NOW()
        );

        -- Roles are tenant-scoped (config.roles has a row per tenant). Seed the standard
        -- staff roles for this tenant if they are missing, otherwise a freshly-created
        -- tenant has no SCHOOL_ADMIN row and the admin can never log in. role_id is an
        -- identity column, so it is left to auto-generate.
        INSERT INTO config.roles
        (
            tenant_id, role_code, role_name, is_active, is_deleted, created_by, created_at
        )
        SELECT
            v_tenant_id, x.code, x.name, TRUE, FALSE, p_action_user_id, NOW()
        FROM (VALUES
            ('SCHOOL_ADMIN', 'School Admin'),
            ('TEACHER',      'Teacher'),
            ('ACCOUNTANT',   'Accountant'),
            ('RECEPTIONIST', 'Receptionist')
        ) AS x(code, name)
        WHERE NOT EXISTS (
            SELECT 1 FROM config.roles r
            WHERE r.tenant_id = v_tenant_id
              AND r.role_code = x.code
        );

        -- Assign the SCHOOL_ADMIN role for THIS tenant by code (not a hardcoded id).
        INSERT INTO core.user_roles
        (
            tenant_id,
            user_id,
            role_id,
            school_id,
            is_primary,
            is_active,
            created_by,
            created_at
        )
        SELECT
            v_tenant_id,
            v_user_id,
            r.role_id,
            v_school_id,
            TRUE,
            TRUE,
            p_action_user_id,
            NOW()
        FROM config.roles r
        WHERE r.tenant_id = v_tenant_id
          AND r.role_code = 'SCHOOL_ADMIN'
          AND r.is_active = TRUE
          AND r.is_deleted = FALSE
        ON CONFLICT (tenant_id, user_id, role_id) DO NOTHING;
    END IF;

    /*
        UPDATE SCHOOL ADMIN (edit existing; create one if none exists yet)
    */
    IF p_operation = 'UPDATE'
       AND COALESCE(p_create_school_admin, FALSE) = TRUE
       AND p_admin_email IS NOT NULL AND TRIM(p_admin_email) <> '' THEN

        SELECT u.user_id INTO v_user_id
        FROM core.user_roles ur
        JOIN config.roles r
            ON r.role_id = ur.role_id
           AND r.tenant_id = v_tenant_id
           AND r.role_code = 'SCHOOL_ADMIN'
        JOIN core.users u
            ON u.user_id = ur.user_id
           AND u.is_active = TRUE
           AND u.is_deleted = FALSE
        WHERE ur.tenant_id = v_tenant_id
          AND ur.school_id = v_school_id
          AND ur.is_active = TRUE
          AND ur.is_deleted = FALSE
        ORDER BY ur.is_primary DESC, u.user_id
        LIMIT 1;

        -- Email must stay unique across active users (excluding the admin being edited).
        IF EXISTS (
            SELECT 1 FROM core.users
            WHERE LOWER(TRIM(email)) = LOWER(TRIM(p_admin_email))
              AND is_active = TRUE
              AND (v_user_id IS NULL OR user_id <> v_user_id)
        ) THEN
            RAISE EXCEPTION 'Admin email already exists.';
        END IF;

        -- Phone must stay unique across active login users (excluding the admin being edited).
        IF p_admin_phone IS NOT NULL AND TRIM(p_admin_phone) <> ''
           AND EXISTS (
            SELECT 1 FROM core.user_profiles
            WHERE TRIM(phone) = TRIM(p_admin_phone)
              AND is_active = TRUE
              AND is_deleted = FALSE
              AND (v_user_id IS NULL OR user_id <> v_user_id)
        ) THEN
            RAISE EXCEPTION 'Admin phone already exists.';
        END IF;

        IF v_user_id IS NOT NULL THEN
            -- Update existing admin. Password is changed only when a new hash is supplied.
            UPDATE core.users
            SET email = LOWER(TRIM(p_admin_email)),
                password_hash = COALESCE(NULLIF(TRIM(p_password_hash), ''), password_hash),
                updated_by = p_action_user_id,
                updated_at = NOW()
            WHERE user_id = v_user_id;

            UPDATE core.user_profiles
            SET full_name = COALESCE(NULLIF(TRIM(p_admin_full_name), ''), full_name),
                phone = NULLIF(TRIM(p_admin_phone), ''),
                updated_by = p_action_user_id,
                updated_at = NOW()
            WHERE user_id = v_user_id
              AND tenant_id = v_tenant_id;

        ELSIF p_password_hash IS NOT NULL AND TRIM(p_password_hash) <> '' THEN
            -- No admin yet: create one (only when a password was supplied).
            INSERT INTO core.users
                (tenant_id, school_id, email, password_hash, is_active, created_by, created_at)
            VALUES
                (v_tenant_id, v_school_id, LOWER(TRIM(p_admin_email)), p_password_hash, TRUE, p_action_user_id, NOW())
            RETURNING user_id INTO v_user_id;

            INSERT INTO core.user_profiles
                (tenant_id, user_id, school_id, full_name, phone, designation, is_active, created_by, created_at)
            VALUES
                (v_tenant_id, v_user_id, v_school_id, TRIM(p_admin_full_name), NULLIF(TRIM(p_admin_phone), ''), 'School Admin', TRUE, p_action_user_id, NOW());

            INSERT INTO core.user_roles
                (tenant_id, user_id, role_id, school_id, is_primary, is_active, created_by, created_at)
            SELECT v_tenant_id, v_user_id, r.role_id, v_school_id, TRUE, TRUE, p_action_user_id, NOW()
            FROM config.roles r
            WHERE r.tenant_id = v_tenant_id
              AND r.role_code = 'SCHOOL_ADMIN'
              AND r.is_active = TRUE
              AND r.is_deleted = FALSE
            ON CONFLICT (tenant_id, user_id, role_id) DO NOTHING;
        END IF;
    END IF;

    /*
        FINAL RESULT
    */
    OPEN p_result FOR
    SELECT
        v_school_id AS school_id,
        v_tenant_id AS tenant_id;
END;
$procedure$

