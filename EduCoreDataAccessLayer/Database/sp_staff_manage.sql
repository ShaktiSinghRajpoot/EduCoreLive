-- ============================================================================
-- sp_staff_manage.sql  —  CRUD for core.staff (HR/Staff module)
--
-- Operations (p_operation):
--   LIST       - all non-deleted staff for the school (UI filters client-side)
--   GET        - one staff row by p_staff_id
--   INSERT     - create a staff row; optionally also create a login user + role
--   UPDATE     - update a staff row; optionally create a login if not present
--   DELETE     - soft deactivate (status='Inactive', is_active=FALSE)
--   REACTIVATE - status='Active', is_active=TRUE
--
-- "Give login": when p_create_login = TRUE and email + password hash are
-- supplied, a core.users login is created (must_change_password=TRUE), a
-- profile + role (p_role_id) assigned, and core.staff.user_id linked. A bus
-- driver / peon left without a login is simply a staff row with user_id NULL.
--
-- NOTE: parameters are POSITIONAL (Npgsql CommandType.StoredProcedure). The C#
-- StaffService MUST build NpgsqlParameter[] in exactly this order.
-- ============================================================================

DROP PROCEDURE IF EXISTS core.sp_staff_manage(
    text, integer, integer, integer, integer,
    text, text, text, date, text, text, text, text, text,
    text, text, text, date, text, integer, text,
    numeric, text, text, text, text,
    boolean, text, integer[],
    text, text, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_staff_manage(
    p_operation        text,
    p_tenant_id        integer,
    p_school_id        integer,
    p_action_user_id   integer,
    p_staff_id         integer,
    -- personal
    p_employee_code    text,
    p_full_name        text,
    p_gender           text,
    p_dob              date,
    p_mobile           text,
    p_alt_mobile       text,
    p_email            text,
    p_blood_group      text,
    p_address          text,
    -- employment
    p_staff_type       text,
    p_department       text,
    p_designation      text,
    p_joining_date     date,
    p_qualification    text,
    p_experience_years integer,
    p_status           text,
    -- payroll / bank
    p_monthly_salary   numeric,
    p_bank_account_no  text,
    p_ifsc_code        text,
    p_pan              text,
    p_aadhaar          text,
    -- login linkage
    p_create_login     boolean,
    p_password_hash    text,
    p_role_ids         integer[],
    -- list filters
    p_search           text,
    p_status_filter    text,
    -- out
    INOUT p_result     refcursor DEFAULT 'staff_cursor'
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_staff_id integer;
    v_user_id  integer;
BEGIN
    -- Multi-tenancy guard (tenant 1 = platform; real schools are tenant > 1).
    IF p_tenant_id IS NULL OR p_tenant_id <= 1 OR p_school_id IS NULL OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid tenant/school scope.';
    END IF;

    -- ---------------------------------------------------------------- LIST
    IF p_operation = 'LIST' THEN
        OPEN p_result FOR
        SELECT s.staff_id, s.employee_code, s.full_name, s.gender, s.dob,
               s.mobile, s.alt_mobile, s.email, s.blood_group, s.address,
               s.staff_type, s.department, s.designation, s.joining_date,
               s.qualification, s.experience_years, s.status,
               s.monthly_salary, s.bank_account_no, s.ifsc_code, s.pan, s.aadhaar,
               s.user_id
        FROM   core.staff s
        WHERE  s.tenant_id = p_tenant_id
          AND  s.school_id = p_school_id
          AND  s.is_deleted = FALSE
          AND  (p_status_filter IS NULL OR p_status_filter = '' OR s.status = p_status_filter)
          AND  (p_search IS NULL OR p_search = ''
                OR s.full_name    ILIKE '%' || p_search || '%'
                OR s.employee_code ILIKE '%' || p_search || '%'
                OR s.designation  ILIKE '%' || p_search || '%')
        ORDER BY s.full_name;
        RETURN;
    END IF;

    -- ----------------------------------------------------------------- GET
    IF p_operation = 'GET' THEN
        OPEN p_result FOR
        SELECT s.staff_id, s.employee_code, s.full_name, s.gender, s.dob,
               s.mobile, s.alt_mobile, s.email, s.blood_group, s.address,
               s.staff_type, s.department, s.designation, s.joining_date,
               s.qualification, s.experience_years, s.status,
               s.monthly_salary, s.bank_account_no, s.ifsc_code, s.pan, s.aadhaar,
               s.user_id
        FROM   core.staff s
        WHERE  s.tenant_id = p_tenant_id
          AND  s.school_id = p_school_id
          AND  s.staff_id  = p_staff_id
          AND  s.is_deleted = FALSE;
        RETURN;
    END IF;

    -- -------------------------------------------------------------- DELETE
    IF p_operation = 'DELETE' THEN
        UPDATE core.staff
        SET    status = 'Inactive', is_active = FALSE,
               updated_by = p_action_user_id, updated_at = now()
        WHERE  tenant_id = p_tenant_id AND school_id = p_school_id AND staff_id = p_staff_id;
        OPEN p_result FOR SELECT p_staff_id AS staff_id;
        RETURN;
    END IF;

    -- ---------------------------------------------------------- REACTIVATE
    IF p_operation = 'REACTIVATE' THEN
        UPDATE core.staff
        SET    status = 'Active', is_active = TRUE,
               updated_by = p_action_user_id, updated_at = now()
        WHERE  tenant_id = p_tenant_id AND school_id = p_school_id AND staff_id = p_staff_id;
        OPEN p_result FOR SELECT p_staff_id AS staff_id;
        RETURN;
    END IF;

    -- ============================ INSERT / UPDATE ========================
    IF p_operation IN ('INSERT', 'UPDATE') THEN

        IF p_full_name IS NULL OR TRIM(p_full_name) = '' THEN
            RAISE EXCEPTION 'Staff full name is required.';
        END IF;

        -- Employee code unique per school (when supplied).
        IF p_employee_code IS NOT NULL AND TRIM(p_employee_code) <> ''
           AND EXISTS (
                SELECT 1 FROM core.staff
                WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                  AND is_deleted = FALSE
                  AND TRIM(employee_code) = TRIM(p_employee_code)
                  AND (p_operation = 'INSERT' OR staff_id <> p_staff_id)
           ) THEN
            RAISE EXCEPTION 'Employee code already exists.';
        END IF;

        -- Resolve which staff row we are creating the login for.
        IF p_operation = 'UPDATE' THEN
            SELECT user_id INTO v_user_id
            FROM core.staff
            WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND staff_id = p_staff_id;
        END IF;

        -- Optionally create a login user (only when none is linked yet).
        IF COALESCE(p_create_login, FALSE) = TRUE
           AND v_user_id IS NULL
           AND p_email IS NOT NULL AND TRIM(p_email) <> ''
           AND p_password_hash IS NOT NULL AND TRIM(p_password_hash) <> '' THEN

            IF EXISTS (SELECT 1 FROM core.users
                       WHERE LOWER(TRIM(email)) = LOWER(TRIM(p_email)) AND is_active = TRUE) THEN
                RAISE EXCEPTION 'A login with this email already exists.';
            END IF;

            IF p_mobile IS NOT NULL AND TRIM(p_mobile) <> ''
               AND EXISTS (SELECT 1 FROM core.user_profiles
                           WHERE TRIM(phone) = TRIM(p_mobile)
                             AND is_active = TRUE AND is_deleted = FALSE) THEN
                RAISE EXCEPTION 'A login with this phone already exists.';
            END IF;

            INSERT INTO core.users
                (tenant_id, school_id, email, password_hash, must_change_password, is_active, created_by, created_at)
            VALUES
                (p_tenant_id, p_school_id, LOWER(TRIM(p_email)), p_password_hash, TRUE, TRUE, p_action_user_id, NOW())
            RETURNING user_id INTO v_user_id;

            INSERT INTO core.user_profiles
                (tenant_id, user_id, school_id, full_name, phone, designation, is_active, created_by, created_at)
            VALUES
                (p_tenant_id, v_user_id, p_school_id, TRIM(p_full_name),
                 NULLIF(TRIM(p_mobile), ''), NULLIF(TRIM(p_designation), ''), TRUE, p_action_user_id, NOW());

        END IF;

        -- Assign / sync the login's role(s). A user's effective permissions are the
        -- UNION of all their roles. Runs for a freshly-created OR an existing login,
        -- so the People edit form is the single place to manage a person's access.
        IF v_user_id IS NOT NULL AND p_role_ids IS NOT NULL THEN
            -- drop roles no longer selected
            UPDATE core.user_roles
            SET is_deleted = TRUE, is_active = FALSE, is_primary = FALSE,
                updated_by = p_action_user_id, updated_at = now()
            WHERE tenant_id = p_tenant_id AND user_id = v_user_id AND is_deleted = FALSE
              AND NOT (role_id = ANY (p_role_ids));

            -- revive previously-removed roles that are selected again
            UPDATE core.user_roles
            SET is_deleted = FALSE, is_active = TRUE, school_id = p_school_id,
                updated_by = p_action_user_id, updated_at = now()
            WHERE tenant_id = p_tenant_id AND user_id = v_user_id AND is_deleted = TRUE
              AND role_id = ANY (p_role_ids);

            -- insert brand-new selections
            INSERT INTO core.user_roles
                (tenant_id, user_id, role_id, school_id, is_primary, is_active, created_by, created_at)
            SELECT p_tenant_id, v_user_id, rid, p_school_id, FALSE, TRUE, p_action_user_id, now()
            FROM   unnest(p_role_ids) AS rid
            WHERE  NOT EXISTS (
                SELECT 1 FROM core.user_roles ur
                WHERE ur.tenant_id = p_tenant_id AND ur.user_id = v_user_id AND ur.role_id = rid);

            -- keep exactly one primary among the active roles (lowest role_id)
            UPDATE core.user_roles SET is_primary = FALSE
            WHERE tenant_id = p_tenant_id AND user_id = v_user_id AND is_deleted = FALSE AND is_primary = TRUE;
            UPDATE core.user_roles SET is_primary = TRUE
            WHERE user_role_id = (
                SELECT user_role_id FROM core.user_roles
                WHERE tenant_id = p_tenant_id AND user_id = v_user_id AND is_deleted = FALSE AND is_active = TRUE
                ORDER BY role_id LIMIT 1);
        END IF;

        IF p_operation = 'INSERT' THEN
            INSERT INTO core.staff
                (tenant_id, school_id, employee_code, full_name, gender, dob,
                 mobile, alt_mobile, email, blood_group, address,
                 staff_type, department, designation, joining_date, qualification,
                 experience_years, status, monthly_salary, bank_account_no, ifsc_code,
                 pan, aadhaar, user_id, created_by, updated_by)
            VALUES
                (p_tenant_id, p_school_id, NULLIF(TRIM(p_employee_code), ''), TRIM(p_full_name), p_gender, p_dob,
                 NULLIF(TRIM(p_mobile), ''), NULLIF(TRIM(p_alt_mobile), ''), NULLIF(TRIM(p_email), ''), p_blood_group, p_address,
                 p_staff_type, p_department, p_designation, p_joining_date, p_qualification,
                 p_experience_years, COALESCE(NULLIF(TRIM(p_status), ''), 'Active'), p_monthly_salary, p_bank_account_no, p_ifsc_code,
                 p_pan, p_aadhaar, v_user_id, p_action_user_id, p_action_user_id)
            RETURNING staff_id INTO v_staff_id;
        ELSE
            UPDATE core.staff
            SET employee_code   = NULLIF(TRIM(p_employee_code), ''),
                full_name       = TRIM(p_full_name),
                gender          = p_gender,
                dob             = p_dob,
                mobile          = NULLIF(TRIM(p_mobile), ''),
                alt_mobile      = NULLIF(TRIM(p_alt_mobile), ''),
                email           = NULLIF(TRIM(p_email), ''),
                blood_group     = p_blood_group,
                address         = p_address,
                staff_type      = p_staff_type,
                department      = p_department,
                designation     = p_designation,
                joining_date    = p_joining_date,
                qualification   = p_qualification,
                experience_years = p_experience_years,
                status          = COALESCE(NULLIF(TRIM(p_status), ''), status),
                monthly_salary  = p_monthly_salary,
                bank_account_no = p_bank_account_no,
                ifsc_code       = p_ifsc_code,
                pan             = p_pan,
                aadhaar         = p_aadhaar,
                user_id         = COALESCE(v_user_id, user_id),
                updated_by      = p_action_user_id,
                updated_at      = now()
            WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND staff_id = p_staff_id
            RETURNING staff_id INTO v_staff_id;
        END IF;

        OPEN p_result FOR SELECT v_staff_id AS staff_id;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation: %', p_operation;
END;
$procedure$;

-- ============================================================================
-- sp_staff_dropdowns — form source lists for the Add/Edit Staff screens:
--   cursor 0: departments      (department name)
--   cursor 1: designations     (name + default staff_type)
--   cursor 2: assignable roles (role_id + role_name) for the "give login" toggle
-- ============================================================================
DROP PROCEDURE IF EXISTS config.sp_staff_dropdowns(integer, integer, refcursor, refcursor, refcursor);

CREATE OR REPLACE PROCEDURE config.sp_staff_dropdowns(
    p_tenant_id integer,
    p_school_id integer,
    INOUT p_departments  refcursor DEFAULT 'departments_cursor',
    INOUT p_designations refcursor DEFAULT 'designations_cursor',
    INOUT p_roles        refcursor DEFAULT 'roles_cursor'
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    OPEN p_departments FOR
    SELECT name
    FROM   config.departments
    WHERE  tenant_id = p_tenant_id AND is_deleted = FALSE AND is_active = TRUE
    ORDER BY sort_order, name;

    OPEN p_designations FOR
    SELECT name, staff_type
    FROM   config.designations
    WHERE  tenant_id = p_tenant_id AND is_deleted = FALSE AND is_active = TRUE
    ORDER BY sort_order, name;

    -- School-scoped roles a new login can be given (exclude the platform SUPER_ADMIN).
    OPEN p_roles FOR
    SELECT role_id, role_name
    FROM   config.roles
    WHERE  tenant_id = p_tenant_id
      AND  is_deleted = FALSE AND is_active = TRUE
      AND  role_code <> 'SUPER_ADMIN'
    ORDER BY role_name;
END;
$procedure$;
