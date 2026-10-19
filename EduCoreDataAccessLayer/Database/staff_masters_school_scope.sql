-- ============================================================================
-- Departments & Designations belong to one school (19 Oct 2026, security review).
--
-- They were one list per TENANT, and a rename / delete also rewrote the text on
-- core.staff for the whole tenant: with two schools in a tenant, one school's admin
-- renaming "Teacher" changed the other school's staff records. Every tenant has one
-- school today, so each row is given that school and nothing changes on screen.
-- The Add Staff role list also shows only built-in roles and this school's own.
--
-- Re-runnable.
-- ============================================================================

ALTER TABLE config.departments  ADD COLUMN IF NOT EXISTS school_id integer;
ALTER TABLE config.designations ADD COLUMN IF NOT EXISTS school_id integer;
-- each existing row to its tenant's school (a tenant with one school -- all of them today)
UPDATE config.departments d SET school_id = s.school_id
  FROM (SELECT tenant_id, min(school_id) school_id FROM core.schools WHERE NOT COALESCE(is_deleted, FALSE)
         GROUP BY tenant_id HAVING count(*) = 1) s
 WHERE d.tenant_id = s.tenant_id AND d.school_id IS NULL;
UPDATE config.designations d SET school_id = s.school_id
  FROM (SELECT tenant_id, min(school_id) school_id FROM core.schools WHERE NOT COALESCE(is_deleted, FALSE)
         GROUP BY tenant_id HAVING count(*) = 1) s
 WHERE d.tenant_id = s.tenant_id AND d.school_id IS NULL;
-- a name is unique within a school now, not within the tenant
ALTER TABLE config.departments  DROP CONSTRAINT IF EXISTS uq_department_name;
ALTER TABLE config.designations DROP CONSTRAINT IF EXISTS uq_designation_name;
CREATE UNIQUE INDEX IF NOT EXISTS uq_department_name  ON config.departments  (tenant_id, COALESCE(school_id, 0), name);
CREATE UNIQUE INDEX IF NOT EXISTS uq_designation_name ON config.designations (tenant_id, COALESCE(school_id, 0), name);

CREATE OR REPLACE PROCEDURE config.sp_staff_masters_manage(IN p_operation text, IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_id integer DEFAULT NULL::integer, IN p_name text DEFAULT NULL::text, IN p_staff_type text DEFAULT NULL::text, IN p_default_department text DEFAULT NULL::text, IN p_sort_order integer DEFAULT 0, IN p_default_role_id integer DEFAULT NULL::integer, INOUT p_result refcursor DEFAULT 'result_cursor'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
-- Oct 2026 (hr_leave_payroll_tests.sql):
--   * Editing a row keeps what the page did not send: the page has no sort-order
--     or default-role field, so p_sort_order NULL/0 and p_default_role_id NULL
--     keep the stored values (they used to be reset on every edit).
--   * A rename follows through: core.staff stores the department / designation
--     NAME, so the staff rows (and designations defaulting to a renamed
--     department) are renamed too. Before, staff kept a name that no longer
--     existed, and the in-use delete guard -- which looks for the new name --
--     then let an in-use designation be deleted. A designation's staff type
--     change follows through to its staff the same way.
--   * A deleted row no longer holds its name: uq_*_name (tenant_id, name) covers
--     deleted rows, so re-adding a deleted name died on a raw constraint error.
--     Saving that name now renames the deleted row out of the way first.
--   * Editing / deleting / toggling a row of another tenant (or a deleted one)
--     says "not found" instead of reporting success.
DECLARE
    v_name        text := NULLIF(TRIM(p_name), '');
    v_staff_type  text;
    v_target_name text;
    v_old_type    text;
    v_id          integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    -- ─────────────────────────────── DEPARTMENTS ───────────────────────────
    IF p_operation = 'SaveDepartment' THEN
        IF v_name IS NULL THEN
            RAISE EXCEPTION 'Department name is required.';
        END IF;
        -- Unique per tenant (case-insensitive), ignoring the row being edited.
        IF EXISTS (SELECT 1 FROM config.departments
                   WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND COALESCE(is_deleted, FALSE) = FALSE
                     AND LOWER(name) = LOWER(v_name)
                     AND (COALESCE(p_id, 0) = 0 OR department_id <> p_id)) THEN
            RAISE EXCEPTION 'A department named "%" already exists.', v_name;
        END IF;

        IF COALESCE(p_id, 0) > 0 THEN
            SELECT name INTO v_target_name FROM config.departments
            WHERE department_id = p_id AND tenant_id = p_tenant_id AND school_id = p_school_id AND COALESCE(is_deleted, FALSE) = FALSE;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'Department not found.';
            END IF;
        END IF;

        -- A deleted row gives its name up (see the header).
        UPDATE config.departments
        SET    name = LEFT(name, 80) || ' (deleted ' || department_id || ')'
        WHERE  tenant_id = p_tenant_id AND school_id = p_school_id AND is_deleted = TRUE AND name = v_name;

        IF COALESCE(p_id, 0) > 0 THEN
            UPDATE config.departments
            SET name = v_name, sort_order = COALESCE(NULLIF(p_sort_order, 0), sort_order),
                updated_by = p_action_user_id, updated_at = NOW()
            WHERE department_id = p_id AND tenant_id = p_tenant_id AND school_id = p_school_id
            RETURNING department_id INTO v_id;

            IF v_target_name IS DISTINCT FROM v_name THEN
                UPDATE core.staff
                SET    department = v_name, updated_by = p_action_user_id, updated_at = now()
                WHERE  tenant_id = p_tenant_id AND school_id = p_school_id AND LOWER(TRIM(department)) = LOWER(TRIM(v_target_name));
                UPDATE config.designations
                SET    default_department = v_name, updated_by = p_action_user_id, updated_at = NOW()
                WHERE  tenant_id = p_tenant_id AND school_id = p_school_id AND LOWER(TRIM(default_department)) = LOWER(TRIM(v_target_name));
            END IF;
        ELSE
            INSERT INTO config.departments (tenant_id, school_id, name, sort_order, created_by)
            VALUES (p_tenant_id, p_school_id, v_name, COALESCE(p_sort_order, 0), p_action_user_id)
            RETURNING department_id INTO v_id;
        END IF;
        OPEN p_result FOR SELECT TRUE AS success, 'Department saved.' AS message, v_id AS id;
        RETURN;

    ELSIF p_operation = 'DeleteDepartment' THEN
        SELECT name INTO v_target_name FROM config.departments
        WHERE department_id = p_id AND tenant_id = p_tenant_id AND school_id = p_school_id AND COALESCE(is_deleted, FALSE) = FALSE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Department not found.';
        END IF;

        IF EXISTS (SELECT 1 FROM core.staff
                   WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND COALESCE(is_deleted, FALSE) = FALSE
                     AND LOWER(TRIM(department)) = LOWER(TRIM(v_target_name))) THEN
            RAISE EXCEPTION 'This department is assigned to staff and cannot be deleted. Reassign them first.';
        END IF;

        UPDATE config.departments
        SET is_deleted = TRUE, is_active = FALSE, deleted_by = p_action_user_id, deleted_at = NOW(),
            updated_by = p_action_user_id, updated_at = NOW()
        WHERE department_id = p_id AND tenant_id = p_tenant_id AND school_id = p_school_id;
        OPEN p_result FOR SELECT TRUE AS success, 'Department deleted.' AS message;
        RETURN;

    ELSIF p_operation = 'ToggleDepartment' THEN
        UPDATE config.departments
        SET is_active = NOT is_active, updated_by = p_action_user_id, updated_at = NOW()
        WHERE department_id = p_id AND tenant_id = p_tenant_id AND school_id = p_school_id AND COALESCE(is_deleted, FALSE) = FALSE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Department not found.';
        END IF;
        OPEN p_result FOR SELECT TRUE AS success, 'Department status updated.' AS message;
        RETURN;

    -- ─────────────────────────────── DESIGNATIONS ──────────────────────────
    ELSIF p_operation = 'SaveDesignation' THEN
        IF v_name IS NULL THEN
            RAISE EXCEPTION 'Designation name is required.';
        END IF;
        v_staff_type := COALESCE(NULLIF(TRIM(p_staff_type), ''), 'Non-Teaching');
        IF v_staff_type NOT IN ('Teaching', 'Non-Teaching', 'Transport', 'Support') THEN
            RAISE EXCEPTION 'Invalid staff type.';
        END IF;
        IF EXISTS (SELECT 1 FROM config.designations
                   WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND COALESCE(is_deleted, FALSE) = FALSE
                     AND LOWER(name) = LOWER(v_name)
                     AND (COALESCE(p_id, 0) = 0 OR designation_id <> p_id)) THEN
            RAISE EXCEPTION 'A designation named "%" already exists.', v_name;
        END IF;

        IF COALESCE(p_id, 0) > 0 THEN
            SELECT name, staff_type INTO v_target_name, v_old_type FROM config.designations
            WHERE designation_id = p_id AND tenant_id = p_tenant_id AND school_id = p_school_id AND COALESCE(is_deleted, FALSE) = FALSE;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'Designation not found.';
            END IF;
        END IF;

        UPDATE config.designations
        SET    name = LEFT(name, 80) || ' (deleted ' || designation_id || ')'
        WHERE  tenant_id = p_tenant_id AND school_id = p_school_id AND is_deleted = TRUE AND name = v_name;

        IF COALESCE(p_id, 0) > 0 THEN
            UPDATE config.designations
            SET name = v_name, staff_type = v_staff_type,
                default_department = NULLIF(TRIM(p_default_department), ''),
                default_role_id = COALESCE(NULLIF(p_default_role_id, 0), default_role_id),
                sort_order = COALESCE(NULLIF(p_sort_order, 0), sort_order),
                updated_by = p_action_user_id, updated_at = NOW()
            WHERE designation_id = p_id AND tenant_id = p_tenant_id AND school_id = p_school_id
            RETURNING designation_id INTO v_id;

            -- Staff carry the designation name and the staff type derived from it.
            IF v_target_name IS DISTINCT FROM v_name OR v_old_type IS DISTINCT FROM v_staff_type THEN
                UPDATE core.staff
                SET    designation = v_name, staff_type = v_staff_type,
                       updated_by = p_action_user_id, updated_at = now()
                WHERE  tenant_id = p_tenant_id AND school_id = p_school_id AND LOWER(TRIM(designation)) = LOWER(TRIM(v_target_name));
            END IF;
        ELSE
            INSERT INTO config.designations
                (tenant_id, school_id, name, staff_type, default_department, default_role_id, sort_order, created_by)
            VALUES
                (p_tenant_id, p_school_id, v_name, v_staff_type, NULLIF(TRIM(p_default_department), ''),
                 NULLIF(COALESCE(p_default_role_id, 0), 0), COALESCE(p_sort_order, 0), p_action_user_id)
            RETURNING designation_id INTO v_id;
        END IF;
        OPEN p_result FOR SELECT TRUE AS success, 'Designation saved.' AS message, v_id AS id;
        RETURN;

    ELSIF p_operation = 'DeleteDesignation' THEN
        SELECT name INTO v_target_name FROM config.designations
        WHERE designation_id = p_id AND tenant_id = p_tenant_id AND school_id = p_school_id AND COALESCE(is_deleted, FALSE) = FALSE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Designation not found.';
        END IF;

        IF EXISTS (SELECT 1 FROM core.staff
                   WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND COALESCE(is_deleted, FALSE) = FALSE
                     AND LOWER(TRIM(designation)) = LOWER(TRIM(v_target_name))) THEN
            RAISE EXCEPTION 'This designation is assigned to staff and cannot be deleted. Reassign them first.';
        END IF;

        UPDATE config.designations
        SET is_deleted = TRUE, is_active = FALSE, deleted_by = p_action_user_id, deleted_at = NOW(),
            updated_by = p_action_user_id, updated_at = NOW()
        WHERE designation_id = p_id AND tenant_id = p_tenant_id AND school_id = p_school_id;
        OPEN p_result FOR SELECT TRUE AS success, 'Designation deleted.' AS message;
        RETURN;

    ELSIF p_operation = 'ToggleDesignation' THEN
        UPDATE config.designations
        SET is_active = NOT is_active, updated_by = p_action_user_id, updated_at = NOW()
        WHERE designation_id = p_id AND tenant_id = p_tenant_id AND school_id = p_school_id AND COALESCE(is_deleted, FALSE) = FALSE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Designation not found.';
        END IF;
        OPEN p_result FOR SELECT TRUE AS success, 'Designation status updated.' AS message;
        RETURN;

    END IF;

    RAISE EXCEPTION 'Unknown operation: %', p_operation;
END;
$procedure$;

CREATE OR REPLACE PROCEDURE config.sp_staff_masters_list(IN p_tenant_id integer, IN p_school_id integer, INOUT p_departments refcursor DEFAULT 'departments_cursor'::refcursor, INOUT p_designations refcursor DEFAULT 'designations_cursor'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    OPEN p_departments FOR
    SELECT department_id, name, sort_order, is_active
    FROM   config.departments
    WHERE  tenant_id = p_tenant_id AND school_id = p_school_id AND COALESCE(is_deleted, FALSE) = FALSE
    ORDER BY sort_order, name;

    OPEN p_designations FOR
    SELECT designation_id, name, staff_type, default_department, default_role_id, sort_order, is_active
    FROM   config.designations
    WHERE  tenant_id = p_tenant_id AND school_id = p_school_id AND COALESCE(is_deleted, FALSE) = FALSE
    ORDER BY sort_order, name;
END;
$procedure$;

CREATE OR REPLACE PROCEDURE config.sp_staff_dropdowns(IN p_tenant_id integer, IN p_school_id integer, INOUT p_departments refcursor DEFAULT 'departments_cursor'::refcursor, INOUT p_designations refcursor DEFAULT 'designations_cursor'::refcursor, INOUT p_roles refcursor DEFAULT 'roles_cursor'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
BEGIN
    OPEN p_departments FOR
    SELECT name
    FROM   config.departments
    WHERE  tenant_id = p_tenant_id AND school_id = p_school_id AND is_deleted = FALSE AND is_active = TRUE
    ORDER BY sort_order, name;

    OPEN p_designations FOR
    SELECT name, staff_type, default_department, default_role_id
    FROM   config.designations
    WHERE  tenant_id = p_tenant_id AND school_id = p_school_id AND is_deleted = FALSE AND is_active = TRUE
    ORDER BY sort_order, name;

    -- School-scoped roles a new login can be given (exclude the platform SUPER_ADMIN).
    OPEN p_roles FOR
    SELECT role_id, role_name
    FROM   config.roles
    WHERE  tenant_id = p_tenant_id
      AND  (school_id IS NULL OR school_id = p_school_id)   -- built-in roles, and this school's own
      AND  is_deleted = FALSE AND is_active = TRUE
      AND  role_code <> 'SUPER_ADMIN'
    ORDER BY role_name;
END;
$procedure$;

CREATE OR REPLACE PROCEDURE core.sp_staff_manage(IN p_operation text, IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_staff_id integer, IN p_employee_code text, IN p_full_name text, IN p_gender text, IN p_dob date, IN p_mobile text, IN p_alt_mobile text, IN p_email text, IN p_blood_group text, IN p_address text, IN p_staff_type text, IN p_department text, IN p_designation text, IN p_joining_date date, IN p_qualification text, IN p_experience_years integer, IN p_status text, IN p_monthly_salary numeric, IN p_bank_account_no text, IN p_ifsc_code text, IN p_pan text, IN p_aadhaar text, IN p_create_login boolean, IN p_password_hash text, IN p_role_ids integer[], IN p_search text, IN p_status_filter text, INOUT p_result refcursor DEFAULT 'staff_cursor'::refcursor, IN p_last_working_date date DEFAULT NULL::date)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_staff_id    integer;
    v_user_id     integer;
    v_staff_type  text;
    v_old_roles   text;
    v_new_roles   text;
    v_admin_role  integer;
    v_had_admin   boolean;
    v_gets_admin  boolean;
    v_old_status  text;
    v_new_status  text;
    v_join        date;
    v_lwd         date;
    v_going_off   boolean := FALSE;
    v_coming_back boolean := FALSE;
BEGIN
    -- Multi-tenancy guard (tenant 1 = platform; real schools are tenant > 1).
    IF p_tenant_id IS NULL OR p_tenant_id <= 1 OR p_school_id IS NULL OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid tenant/school scope.';
    END IF;

    -- ---------------------------------------------------------------- LIST
    IF p_operation = 'LIST' THEN
        OPEN p_result FOR
        SELECT s.staff_id, s.public_id, s.employee_code, s.full_name, s.gender, s.dob,
               s.mobile, s.alt_mobile, s.email, s.blood_group, s.address,
               s.staff_type, s.department, s.designation, s.joining_date,
               s.qualification, s.experience_years, s.status,
               s.monthly_salary, s.bank_account_no, s.ifsc_code, s.pan, s.aadhaar,
               s.user_id, s.status_changed_at, s.last_working_date
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
        SELECT s.staff_id, s.public_id, s.employee_code, s.full_name, s.gender, s.dob,
               s.mobile, s.alt_mobile, s.email, s.blood_group, s.address,
               s.staff_type, s.department, s.designation, s.joining_date,
               s.qualification, s.experience_years, s.status,
               s.monthly_salary, s.bank_account_no, s.ifsc_code, s.pan, s.aadhaar,
               s.user_id, s.status_changed_at, s.last_working_date
        FROM   core.staff s
        WHERE  s.tenant_id = p_tenant_id
          AND  s.school_id = p_school_id
          AND  s.staff_id  = p_staff_id
          AND  s.is_deleted = FALSE;
        RETURN;
    END IF;

    -- Every write below works on one staff row of THIS school. Find it first, so
    -- nothing (a login, a role) is created for a row that is not ours.
    IF p_operation IN ('UPDATE', 'DELETE', 'REACTIVATE') THEN
        SELECT user_id, status, NULLIF(joining_date, '')::date
          INTO v_user_id, v_old_status, v_join
        FROM core.staff
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND staff_id = p_staff_id AND is_deleted = FALSE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Staff member not found.';
        END IF;
    END IF;

    -- -------------------------------------------------------------- DELETE
    IF p_operation = 'DELETE' THEN
        IF v_old_status = 'Inactive' THEN
            RAISE EXCEPTION 'This staff member is already inactive.';
        END IF;

        v_lwd := COALESCE(p_last_working_date, CURRENT_DATE);
        IF v_lwd > CURRENT_DATE THEN
            RAISE EXCEPTION 'The last working day cannot be in the future. Deactivate on or after that day.';
        END IF;
        -- Someone hired for a future date who never joined: no working days at
        -- all, so no last working day (payroll then never pays them).
        IF p_last_working_date IS NULL AND v_join IS NOT NULL AND v_join > CURRENT_DATE THEN
            v_lwd := NULL;
        END IF;
        IF v_join IS NOT NULL AND v_lwd < v_join THEN
            RAISE EXCEPTION 'The last working day cannot be before the joining date (%).', to_char(v_join, 'DD Mon YYYY');
        END IF;

        UPDATE core.staff
        SET    status = 'Inactive', is_active = FALSE,
               status_changed_at = now(),
               last_working_date = to_char(v_lwd, 'YYYY-MM-DD'),
               updated_by = p_action_user_id, updated_at = now()
        WHERE  tenant_id = p_tenant_id AND school_id = p_school_id AND staff_id = p_staff_id;

        CALL core.sp_staff_login_switch(p_tenant_id, p_school_id, p_action_user_id, p_staff_id, v_user_id, FALSE);
        CALL core.sp_staff_release_duties(p_tenant_id, p_school_id, p_action_user_id, p_staff_id);

        OPEN p_result FOR SELECT p_staff_id AS staff_id;
        RETURN;
    END IF;

    -- ---------------------------------------------------------- REACTIVATE
    -- Meant for a mistaken deactivation. A re-hire after a real gap should also
    -- get a new joining date on the Edit form, or payroll would see the gap as
    -- employed time.
    IF p_operation = 'REACTIVATE' THEN
        UPDATE core.staff
        SET    status = 'Active', is_active = TRUE,
               status_changed_at = now(),
               last_working_date = NULL,
               updated_by = p_action_user_id, updated_at = now()
        WHERE  tenant_id = p_tenant_id AND school_id = p_school_id AND staff_id = p_staff_id;

        CALL core.sp_staff_login_switch(p_tenant_id, p_school_id, p_action_user_id, p_staff_id, v_user_id, TRUE);

        OPEN p_result FOR SELECT p_staff_id AS staff_id;
        RETURN;
    END IF;

    -- ============================ INSERT / UPDATE ========================
    IF p_operation IN ('INSERT', 'UPDATE') THEN

        IF p_full_name IS NULL OR TRIM(p_full_name) = '' THEN
            RAISE EXCEPTION 'Staff full name is required.';
        END IF;

        -- Payroll pays a salary only for the statuses it knows; any other word
        -- would silently drop the person from payroll.
        v_new_status := COALESCE(NULLIF(TRIM(p_status), ''), v_old_status, 'Active');
        IF v_new_status NOT IN ('Active', 'On Leave', 'Inactive') THEN
            RAISE EXCEPTION 'Status must be Active, On Leave or Inactive.';
        END IF;
        IF p_operation = 'INSERT' AND v_new_status = 'Inactive' THEN
            RAISE EXCEPTION 'A new staff member starts Active or On Leave.';
        END IF;

        IF p_monthly_salary IS NOT NULL AND p_monthly_salary < 0 THEN
            RAISE EXCEPTION 'Monthly salary cannot be negative.';
        END IF;

        -- Employee code unique per school (when supplied), ignoring case and spaces.
        IF p_employee_code IS NOT NULL AND TRIM(p_employee_code) <> ''
           AND EXISTS (
                SELECT 1 FROM core.staff
                WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                  AND is_deleted = FALSE
                  AND UPPER(TRIM(employee_code)) = UPPER(TRIM(p_employee_code))
                  AND (p_operation = 'INSERT' OR staff_id <> p_staff_id)
           ) THEN
            RAISE EXCEPTION 'Employee code already exists.';
        END IF;

        -- Mobile and email unique among this school's current staff (not the row
        -- being edited, not deleted or Inactive people, so a re-hire still works).
        -- Mobile compares the last 10 digits, the same rule as the login phone.
        IF p_mobile IS NOT NULL AND TRIM(p_mobile) <> ''
           AND EXISTS (
                SELECT 1 FROM core.staff
                WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                  AND is_deleted = FALSE AND status <> 'Inactive'
                  AND RIGHT(regexp_replace(mobile, '\D', '', 'g'), 10)
                      = RIGHT(regexp_replace(p_mobile, '\D', '', 'g'), 10)
                  AND (p_operation = 'INSERT' OR staff_id <> p_staff_id)
           ) THEN
            RAISE EXCEPTION 'A staff member with this mobile already exists.';
        END IF;

        IF p_email IS NOT NULL AND TRIM(p_email) <> ''
           AND EXISTS (
                SELECT 1 FROM core.staff
                WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                  AND is_deleted = FALSE AND status <> 'Inactive'
                  AND LOWER(TRIM(email)) = LOWER(TRIM(p_email))
                  AND (p_operation = 'INSERT' OR staff_id <> p_staff_id)
           ) THEN
            RAISE EXCEPTION 'A staff member with this email already exists.';
        END IF;

        -- Staff Type is DERIVED from the chosen Designation (single source of
        -- truth) so it can never contradict the title, even if the form is
        -- bypassed. Falls back to whatever the caller sent if the designation
        -- has no bucket set.
        IF p_designation IS NOT NULL AND TRIM(p_designation) <> '' THEN
            SELECT staff_type INTO v_staff_type
            FROM   config.designations
            WHERE  tenant_id = p_tenant_id AND school_id = p_school_id AND is_deleted = FALSE
              AND  LOWER(TRIM(name)) = LOWER(TRIM(p_designation))
            LIMIT 1;
        END IF;
        v_staff_type := COALESCE(v_staff_type, NULLIF(TRIM(p_staff_type), ''));
        IF v_staff_type IS NOT NULL AND v_staff_type NOT IN ('Teaching', 'Non-Teaching', 'Transport', 'Support') THEN
            RAISE EXCEPTION 'Invalid staff type.';
        END IF;

        -- Status flips through the Edit form behave exactly like Deactivate /
        -- Reactivate (see the header).
        IF p_operation = 'UPDATE' THEN
            v_going_off   := v_new_status = 'Inactive' AND v_old_status <> 'Inactive';
            v_coming_back := v_old_status = 'Inactive' AND v_new_status <> 'Inactive';
        END IF;

        -- The last working day is set when someone goes Inactive, and can be
        -- corrected later while they stay Inactive.
        IF v_new_status = 'Inactive' AND (v_going_off OR p_last_working_date IS NOT NULL) THEN
            v_lwd := COALESCE(p_last_working_date, CURRENT_DATE);
            IF v_lwd > CURRENT_DATE THEN
                RAISE EXCEPTION 'The last working day cannot be in the future. Deactivate on or after that day.';
            END IF;
            IF p_last_working_date IS NULL AND COALESCE(p_joining_date, v_join) > CURRENT_DATE THEN
                v_lwd := NULL;   -- never joined (see DELETE)
            END IF;
            IF COALESCE(p_joining_date, v_join) IS NOT NULL AND v_lwd < COALESCE(p_joining_date, v_join) THEN
                RAISE EXCEPTION 'The last working day cannot be before the joining date.';
            END IF;
        END IF;

        -- Optionally create a login user (only when none is linked yet).
        IF COALESCE(p_create_login, FALSE) = TRUE
           AND v_user_id IS NULL
           AND p_email IS NOT NULL AND TRIM(p_email) <> ''
           AND p_password_hash IS NOT NULL AND TRIM(p_password_hash) <> '' THEN

            -- Shared guard (Database/user_email_unique.sql) so this can't drift from
            -- the uq_user_email_active index. The old inline check missed is_deleted.
            IF core.fn_user_email_taken(p_email) THEN
                RAISE EXCEPTION 'A login with this email already exists.';
            END IF;

            -- Same rule as uq_user_phone_active (last 10 digits), so '+91 98390 73643'
            -- gets this message instead of a raw constraint error.
            IF p_mobile IS NOT NULL AND TRIM(p_mobile) <> ''
               AND core.fn_user_phone_taken(p_mobile) THEN
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

        -- Reset the password of an EXISTING login when a new hash is supplied (admin
        -- "reset password" on the edit form). Force a self-reset on next sign-in.
        IF p_operation = 'UPDATE'
           AND COALESCE(p_create_login, FALSE) = FALSE
           AND v_user_id IS NOT NULL
           AND p_password_hash IS NOT NULL AND TRIM(p_password_hash) <> '' THEN
            UPDATE core.users
            SET    password_hash = p_password_hash,
                   must_change_password = TRUE,
                   password_changed_at = now(),   -- ends the person's open sessions
                   updated_by = p_action_user_id,
                   updated_at = now()
            WHERE  user_id = v_user_id AND tenant_id = p_tenant_id;

            PERFORM core.fn_admin_audit(p_tenant_id, p_school_id, p_action_user_id, 'PASSWORD_RESET_BY_ADMIN',
                'Staff', 'core.users', v_user_id, format('Password reset for staff %s', p_staff_id));
        END IF;

        -- Assign / sync the login's role(s). A user's effective permissions are the
        -- UNION of all their roles. Runs for a freshly-created OR an existing login,
        -- so the People edit form is the single place to manage a person's access.
        IF v_user_id IS NOT NULL AND p_role_ids IS NOT NULL THEN
            -- Every id must be a live role of THIS tenant (and never the platform role).
            IF EXISTS (SELECT 1 FROM unnest(p_role_ids) AS rid
                       WHERE NOT EXISTS (SELECT 1 FROM config.roles r
                                         WHERE r.role_id = rid AND r.tenant_id = p_tenant_id
                                           AND r.is_deleted = FALSE AND r.role_code <> 'SUPER_ADMIN')) THEN
                RAISE EXCEPTION 'Role not found.';
            END IF;

            SELECT string_agg(r.role_code, ', ' ORDER BY r.role_code) INTO v_old_roles
            FROM core.user_roles ur JOIN config.roles r ON r.role_id = ur.role_id
            WHERE ur.tenant_id = p_tenant_id AND ur.user_id = v_user_id
              AND ur.is_deleted = FALSE AND ur.is_active = TRUE;
            SELECT string_agg(r.role_code, ', ' ORDER BY r.role_code) INTO v_new_roles
            FROM config.roles r WHERE r.role_id = ANY (p_role_ids);

            IF v_old_roles IS DISTINCT FROM v_new_roles THEN
                IF v_user_id = p_action_user_id THEN
                    RAISE EXCEPTION 'You cannot change your own roles. Ask another School Admin.';
                END IF;

                SELECT role_id INTO v_admin_role FROM config.roles
                WHERE tenant_id = p_tenant_id AND role_code = 'SCHOOL_ADMIN' AND is_deleted = FALSE
                ORDER BY role_id LIMIT 1;
                v_had_admin  := COALESCE(v_old_roles, '') ~ '(^|, )SCHOOL_ADMIN(,|$)';
                v_gets_admin := v_admin_role = ANY (p_role_ids);

                IF v_had_admin IS DISTINCT FROM v_gets_admin
                   AND NOT core.fn_user_is_school_admin(p_tenant_id, p_action_user_id) THEN
                    RAISE EXCEPTION 'Only a School Admin can grant or remove the School Admin role.';
                END IF;
                IF v_had_admin AND NOT v_gets_admin
                   AND core.fn_is_last_school_admin(p_school_id, v_user_id) THEN
                    RAISE EXCEPTION 'This is the last active School Admin of the school. Make someone else a School Admin first.';
                END IF;

                PERFORM core.fn_admin_audit(p_tenant_id, p_school_id, p_action_user_id, 'USER_ROLES_CHANGE',
                    'Staff', 'core.user_roles', v_user_id,
                    format('Roles: [%s] -> [%s]', COALESCE(v_old_roles, ''), COALESCE(v_new_roles, '')));
            END IF;

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
                 v_staff_type, p_department, p_designation, p_joining_date, p_qualification,
                 p_experience_years, v_new_status, p_monthly_salary, p_bank_account_no, p_ifsc_code,
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
                staff_type      = v_staff_type,
                department      = p_department,
                designation     = p_designation,
                joining_date    = p_joining_date,
                qualification   = p_qualification,
                experience_years = p_experience_years,
                status          = v_new_status,
                -- is_active always follows the status, whichever screen set it.
                is_active       = (v_new_status <> 'Inactive'),
                status_changed_at = CASE WHEN v_going_off OR v_coming_back THEN now()
                                         ELSE status_changed_at END,
                last_working_date = CASE WHEN v_lwd IS NOT NULL THEN to_char(v_lwd, 'YYYY-MM-DD')
                                         WHEN v_coming_back THEN NULL
                                         ELSE last_working_date END,
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

            IF v_going_off THEN
                CALL core.sp_staff_login_switch(p_tenant_id, p_school_id, p_action_user_id, p_staff_id, v_user_id, FALSE);
                CALL core.sp_staff_release_duties(p_tenant_id, p_school_id, p_action_user_id, p_staff_id);
            ELSIF v_coming_back THEN
                CALL core.sp_staff_login_switch(p_tenant_id, p_school_id, p_action_user_id, p_staff_id, v_user_id, TRUE);
            END IF;
        END IF;

        OPEN p_result FOR SELECT v_staff_id AS staff_id;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation: %', p_operation;
END;
$procedure$;
