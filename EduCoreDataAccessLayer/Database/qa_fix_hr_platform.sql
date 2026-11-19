-- =====================================================================
-- qa_fix_hr_platform.sql  (QA pack 18-Nov-2026: HR / Staff, Platform,
-- Inventory, Exams, Attendance, roles, dashboard)
-- Idempotent and re-runnable. No BEGIN/COMMIT inside: run with
--   psql --single-transaction -f qa_fix_hr_platform.sql
-- =====================================================================


-- ---------------------------------------------------------------------
-- UX-24: next Employee ID for a school when the form leaves it blank.
-- Shape <SCHOOL INITIALS>-EMP-<3 digits>, e.g. "Angel's Paradise School"
-- -> APS-EMP-033. The number follows the highest one already used with
-- that prefix, so a typed code never gets re-issued.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_next_employee_code(p_tenant_id integer, p_school_id integer)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_name   text;
    v_prefix text := '';
    v_word   text;
    v_next   integer;
BEGIN
    SELECT COALESCE(NULLIF(TRIM(display_name), ''), school_name) INTO v_name
    FROM core.schools
    WHERE tenant_id = p_tenant_id AND school_id = p_school_id;

    -- First letter of each word, at most four ("Angel's Paradise School" -> APS).
    FOREACH v_word IN ARRAY regexp_split_to_array(COALESCE(v_name, ''), '\s+') LOOP
        v_word := regexp_replace(v_word, '[^A-Za-z]', '', 'g');
        IF v_word <> '' AND length(v_prefix) < 4 THEN
            v_prefix := v_prefix || upper(left(v_word, 1));
        END IF;
    END LOOP;
    IF v_prefix = '' THEN
        v_prefix := 'SCH';
    END IF;

    SELECT COALESCE(MAX(substring(employee_code FROM '(\d+)$')::integer), 0) + 1 INTO v_next
    FROM core.staff
    WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND is_deleted = FALSE
      AND upper(employee_code) ~ ('^' || v_prefix || '-EMP-\d+$');

    RETURN v_prefix || '-EMP-' || lpad(v_next::text, 3, '0');
END;
$function$;


-- ---------------------------------------------------------------------
-- BUG-022 / BUG-040 / UX-24: core.sp_staff_manage
--  * GET returns login_moved: this person's (inactive) login email or phone now
--    belongs to another active login, so the profile can say so.
--  * UPDATE keeps the saved Designation (and so Staff Type) when the form sent
--    none -- the Edit page used to post an empty designation if Save was clicked
--    before the designation list had loaded, silently wiping both.
--  * INSERT fills a blank Employee ID from core.fn_next_employee_code.
-- ---------------------------------------------------------------------
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
    v_designation text;
    v_old_desig   text;
    v_old_type    text;
    v_emp_code    text;
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
               s.user_id, s.status_changed_at, s.last_working_date,
               -- BUG-040: an inactive login whose email or phone now belongs to
               -- another active login (re-hired under a new staff record).
               (u.user_id IS NOT NULL AND u.is_active = FALSE
                AND (core.fn_user_email_taken(u.email, u.user_id)
                     OR EXISTS (SELECT 1 FROM core.user_profiles up
                                WHERE up.user_id = u.user_id AND up.phone IS NOT NULL
                                  AND core.fn_user_phone_taken(up.phone, u.user_id)))) AS login_moved
        FROM   core.staff s
        LEFT JOIN core.users u ON u.user_id = s.user_id AND u.is_deleted = FALSE
        WHERE  s.tenant_id = p_tenant_id
          AND  s.school_id = p_school_id
          AND  s.staff_id  = p_staff_id
          AND  s.is_deleted = FALSE;
        RETURN;
    END IF;

    -- Every write below works on one staff row of THIS school. Find it first, so
    -- nothing (a login, a role) is created for a row that is not ours.
    IF p_operation IN ('UPDATE', 'DELETE', 'REACTIVATE') THEN
        SELECT user_id, status, NULLIF(joining_date, '')::date, designation, staff_type
          INTO v_user_id, v_old_status, v_join, v_old_desig, v_old_type
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

        -- UX-24: a new staff member without an Employee ID gets the next one.
        v_emp_code := NULLIF(TRIM(p_employee_code), '');
        IF p_operation = 'INSERT' AND v_emp_code IS NULL THEN
            v_emp_code := core.fn_next_employee_code(p_tenant_id, p_school_id);
        END IF;

        -- BUG-022: an edit that sends no designation keeps the saved one (the form
        -- posted an empty value when Save was clicked before its list had loaded).
        v_designation := NULLIF(TRIM(p_designation), '');
        IF p_operation = 'UPDATE' AND v_designation IS NULL THEN
            v_designation := v_old_desig;
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
        IF v_designation IS NOT NULL THEN
            SELECT staff_type INTO v_staff_type
            FROM   config.designations
            WHERE  tenant_id = p_tenant_id AND school_id = p_school_id AND is_deleted = FALSE
              AND  LOWER(TRIM(name)) = LOWER(TRIM(v_designation))
            LIMIT 1;
        END IF;
        v_staff_type := COALESCE(v_staff_type, NULLIF(TRIM(p_staff_type), ''));
        -- The form never posts Staff Type; on an edit keep the saved one when the
        -- designation does not give one (e.g. a designation deactivated since).
        IF p_operation = 'UPDATE' AND v_staff_type IS NULL THEN
            v_staff_type := v_old_type;
        END IF;
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
                 NULLIF(TRIM(p_mobile), ''), v_designation, TRUE, p_action_user_id, NOW());

        END IF;

        -- Reset the password of an EXISTING login when a new hash is supplied (admin
        -- "reset password" on the edit form). Force a self-reset on next sign-in.
        IF p_operation = 'UPDATE'
           AND COALESCE(p_create_login, FALSE) = FALSE
           AND v_user_id IS NOT NULL
           AND p_password_hash IS NOT NULL AND TRIM(p_password_hash) <> '' THEN
            -- Resetting a School Admin's password would let whoever did it sign in as
            -- that admin: only another School Admin may.
            IF core.fn_user_is_school_admin(p_tenant_id, v_user_id)
               AND NOT core.fn_user_is_school_admin(p_tenant_id, p_action_user_id) THEN
                RAISE EXCEPTION 'Only a School Admin can reset a School Admin''s password.';
            END IF;
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
                -- A School Admin's roles are changed only by a School Admin.
                IF v_had_admin AND NOT core.fn_user_is_school_admin(p_tenant_id, p_action_user_id) THEN
                    RAISE EXCEPTION 'Only a School Admin can change a School Admin''s roles.';
                END IF;
                -- A role that can manage roles, settings, staff logins, salary or modules
                -- is as strong as an admin: only a School Admin gives it to someone.
                IF NOT core.fn_user_is_school_admin(p_tenant_id, p_action_user_id)
                   AND EXISTS (SELECT 1
                                 FROM unnest(p_role_ids) AS rid
                                 JOIN config.role_permissions rp ON rp.role_id = rid AND rp.school_id = p_school_id
                                                                AND rp.is_allowed AND NOT rp.is_deleted
                                 JOIN config.permissions pm ON pm.permission_id = rp.permission_id
                                WHERE pm.permission_key IN ('rbac.manage', 'settings.manage', 'staff.manage',
                                                            'payroll.manage', 'admission_workflow.manage')
                                  AND NOT EXISTS (SELECT 1 FROM core.user_roles ur
                                                   WHERE ur.user_id = v_user_id AND ur.role_id = rid
                                                     AND ur.is_active AND NOT ur.is_deleted)) THEN
                    RAISE EXCEPTION 'Only a School Admin can give a role that manages roles, settings, staff, salary or modules.';
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
                (p_tenant_id, p_school_id, v_emp_code, TRIM(p_full_name), p_gender, p_dob,
                 NULLIF(TRIM(p_mobile), ''), NULLIF(TRIM(p_alt_mobile), ''), NULLIF(TRIM(p_email), ''), p_blood_group, p_address,
                 v_staff_type, p_department, v_designation, p_joining_date, p_qualification,
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
                designation     = v_designation,
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
$procedure$

;


-- ---------------------------------------------------------------------
-- BUG-041 (owner decision #12): an inactive login releases BOTH its email and
-- its mobile. Email already worked (uq_user_email_active looks at
-- core.users.is_active). The phone index and check look at
-- core.user_profiles.is_active, which stayed TRUE when the login was switched
-- off -- so the number stayed locked forever. Now the profile follows the login.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_user_phone_taken(p_phone character varying, p_exclude_user_id integer DEFAULT NULL::integer)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
    SELECT EXISTS (
        SELECT 1
        FROM core.user_profiles up
        JOIN core.users u ON u.user_id = up.user_id
                         AND u.is_active = TRUE AND u.is_deleted = FALSE
        WHERE up.phone IS NOT NULL
          AND length(regexp_replace(p_phone, '\D', '', 'g')) >= 10
          AND right(regexp_replace(up.phone, '\D', '', 'g'), 10)
              = right(regexp_replace(p_phone, '\D', '', 'g'), 10)
          AND up.is_deleted = FALSE
          AND up.is_active  = TRUE
          AND (p_exclude_user_id IS NULL OR up.user_id <> p_exclude_user_id)
    );
$function$;

-- One-time catch-up: profiles of logins that are already switched off.
UPDATE core.user_profiles up
SET    is_active = FALSE, updated_at = now()
FROM   core.users u
WHERE  u.user_id = up.user_id
  AND  u.is_active = FALSE
  AND  up.is_active = TRUE;


-- BUG-041: switching a staff login off/on also switches its profile row.
CREATE OR REPLACE PROCEDURE core.sp_staff_login_switch(IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_staff_id integer, IN p_user_id integer, IN p_on boolean)
 LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_user_id IS NULL THEN
        RETURN;
    END IF;

    IF NOT p_on THEN
        IF p_user_id = p_action_user_id THEN
            RAISE EXCEPTION 'You cannot deactivate your own login.';
        END IF;
        IF core.fn_is_last_school_admin(p_school_id, p_user_id) THEN
            RAISE EXCEPTION 'This is the last active School Admin of the school. Make someone else a School Admin first.';
        END IF;

        -- Someone who has left must not keep signing in.
        UPDATE core.users
        SET    is_active = FALSE, updated_by = p_action_user_id, updated_at = now()
        WHERE  user_id = p_user_id AND tenant_id = p_tenant_id AND is_active = TRUE;

        IF FOUND THEN
            -- BUG-041: the profile follows the login, which frees the phone number
            -- (uq_user_phone_active) just as the email is freed.
            UPDATE core.user_profiles
            SET    is_active = FALSE, updated_by = p_action_user_id, updated_at = now()
            WHERE  user_id = p_user_id AND tenant_id = p_tenant_id AND is_active = TRUE;

            PERFORM core.fn_admin_audit(p_tenant_id, p_school_id, p_action_user_id, 'USER_DEACTIVATE',
                'Staff', 'core.users', p_user_id,
                format('Login deactivated with staff %s', p_staff_id));
        END IF;
        RETURN;
    END IF;

    -- Bring the login back, unless its email or phone now belongs to someone else.
    IF EXISTS (SELECT 1 FROM core.users WHERE user_id = p_user_id
               AND tenant_id = p_tenant_id AND is_active = FALSE AND is_deleted = FALSE) THEN
        IF core.fn_user_email_taken((SELECT email FROM core.users WHERE user_id = p_user_id), p_user_id) THEN
            RAISE EXCEPTION 'This person''s login email is now used by another user. Change it before re-activating.';
        END IF;
        IF EXISTS (SELECT 1 FROM core.user_profiles up WHERE up.user_id = p_user_id AND up.phone IS NOT NULL
                   AND core.fn_user_phone_taken(up.phone, p_user_id)) THEN
            RAISE EXCEPTION 'This person''s login phone is now used by another user. Change it before re-activating.';
        END IF;

        UPDATE core.users
        SET    is_active = TRUE, updated_by = p_action_user_id, updated_at = now()
        WHERE  user_id = p_user_id;

        UPDATE core.user_profiles
        SET    is_active = TRUE, updated_by = p_action_user_id, updated_at = now()
        WHERE  user_id = p_user_id AND tenant_id = p_tenant_id AND is_deleted = FALSE AND is_active = FALSE;

        PERFORM core.fn_admin_audit(p_tenant_id, p_school_id, p_action_user_id, 'USER_ACTIVATE',
            'Staff', 'core.users', p_user_id,
            format('Login re-activated with staff %s', p_staff_id));
    END IF;
END;
$procedure$;


-- ---------------------------------------------------------------------
-- BUG-047 + Module-Access-Test 4: platform modules page
--  * Get also returns the school's own enable_* switches.
--  * Save writes a SCHOOL_MODULES_CHANGE row to the admin audit log.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_school_plan_text(
    p_transport boolean, p_exams boolean, p_inventory boolean, p_payroll boolean,
    p_attendance boolean, p_academics boolean, p_fees boolean, p_accounts boolean)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $function$
    SELECT COALESCE(NULLIF(concat_ws(', ',
               CASE WHEN p_transport  THEN 'Transport'  END,
               CASE WHEN p_exams      THEN 'Exams'      END,
               CASE WHEN p_inventory  THEN 'Inventory'  END,
               CASE WHEN p_payroll    THEN 'Staff'      END,
               CASE WHEN p_attendance THEN 'Attendance' END,
               CASE WHEN p_academics  THEN 'Academics'  END,
               CASE WHEN p_fees       THEN 'Fees'       END,
               CASE WHEN p_accounts   THEN 'Accounts'   END), ''), 'none');
$function$;

CREATE OR REPLACE PROCEDURE core.sp_superadmin_school_modules(IN p_operation text, IN p_action_user_id integer, IN p_school_id integer, IN p_allow_transport boolean DEFAULT NULL::boolean, IN p_allow_exams boolean DEFAULT NULL::boolean, IN p_allow_inventory boolean DEFAULT NULL::boolean, IN p_allow_payroll boolean DEFAULT NULL::boolean, IN p_allow_attendance boolean DEFAULT NULL::boolean, IN p_allow_academics boolean DEFAULT NULL::boolean, IN p_allow_fees boolean DEFAULT NULL::boolean, IN p_allow_accounts boolean DEFAULT NULL::boolean, INOUT p_result refcursor DEFAULT 'modules_cursor'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_tenant integer;
    v_name   text;
    v_riders integer;
    v_dues   numeric;
    v_before text;
    v_after  text;
BEGIN
    IF NOT core.fn_is_super_admin(p_action_user_id) THEN
        RAISE EXCEPTION 'Only the Super Admin can change the modules of a school.';
    END IF;

    SELECT tenant_id, school_name INTO v_tenant, v_name
      FROM core.schools WHERE school_id = p_school_id AND NOT COALESCE(is_deleted, FALSE);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'School not found.';
    END IF;

    IF p_operation = 'Save' THEN
        -- Transport cannot be taken away while children still ride or owe bus
        -- fees: those dues would disappear from the fee counter.
        IF NOT COALESCE(p_allow_transport, TRUE) THEN
            SELECT COUNT(*) INTO v_riders
              FROM core.student_transport a
              JOIN core.students st ON st.student_id = a.student_id AND st.is_active
             WHERE a.tenant_id = v_tenant AND a.school_id = p_school_id
               AND a.is_active AND NOT COALESCE(a.is_deleted, FALSE);
            SELECT COALESCE(SUM(amount_due - amount_paid - COALESCE(concession, 0)), 0) INTO v_dues
              FROM core.student_ledger
             WHERE tenant_id = v_tenant AND school_id = p_school_id
               AND fee_head_name = 'Transport Fee'
               AND amount_due - amount_paid - COALESCE(concession, 0) > 0;
            IF v_riders > 0 OR v_dues > 0 THEN
                RAISE EXCEPTION '% still has % student(s) on buses and Rs % of bus fees unpaid. The school must end those bus assignments first, then Transport can be taken away.',
                    v_name, v_riders, to_char(v_dues, 'FM99,99,99,990.00');
            END IF;
        END IF;

        -- Module-Access-Test 4: every plan change goes to the admin audit log
        -- (who = action user, when = the log time, which modules before -> after).
        SELECT core.fn_school_plan_text(w.allow_transport, w.allow_exams, w.allow_inventory, w.allow_payroll,
                                        w.allow_attendance, w.allow_academics, w.allow_fees, w.allow_accounts)
          INTO v_before
          FROM core.school_admission_workflow_settings w
         WHERE w.tenant_id = v_tenant AND w.school_id = p_school_id;

        INSERT INTO core.school_admission_workflow_settings
            (tenant_id, school_id, allow_transport, allow_exams, allow_inventory, allow_payroll,
             allow_attendance, allow_academics, allow_fees, allow_accounts, created_by)
        VALUES (v_tenant, p_school_id,
                COALESCE(p_allow_transport, TRUE), COALESCE(p_allow_exams, TRUE),
                COALESCE(p_allow_inventory, TRUE), COALESCE(p_allow_payroll, TRUE),
                COALESCE(p_allow_attendance, TRUE), COALESCE(p_allow_academics, TRUE),
                COALESCE(p_allow_fees, TRUE), COALESCE(p_allow_accounts, TRUE), p_action_user_id)
        ON CONFLICT (tenant_id, school_id) DO UPDATE
        SET allow_transport  = EXCLUDED.allow_transport,
            allow_exams      = EXCLUDED.allow_exams,
            allow_inventory  = EXCLUDED.allow_inventory,
            allow_payroll    = EXCLUDED.allow_payroll,
            allow_attendance = COALESCE(p_allow_attendance, school_admission_workflow_settings.allow_attendance),
            allow_academics  = COALESCE(p_allow_academics,  school_admission_workflow_settings.allow_academics),
            allow_fees       = COALESCE(p_allow_fees,       school_admission_workflow_settings.allow_fees),
            allow_accounts   = COALESCE(p_allow_accounts,   school_admission_workflow_settings.allow_accounts),
            updated_by = p_action_user_id, updated_at = now();

        SELECT core.fn_school_plan_text(w.allow_transport, w.allow_exams, w.allow_inventory, w.allow_payroll,
                                        w.allow_attendance, w.allow_academics, w.allow_fees, w.allow_accounts)
          INTO v_after
          FROM core.school_admission_workflow_settings w
         WHERE w.tenant_id = v_tenant AND w.school_id = p_school_id;

        IF v_before IS DISTINCT FROM v_after THEN
            PERFORM core.fn_admin_audit(1, NULL, p_action_user_id, 'SCHOOL_MODULES_CHANGE', 'SuperAdmin/Schools',
                'core.school_admission_workflow_settings', p_school_id,
                format('Modules given to %s (school %s): [%s] -> [%s]',
                       v_name, p_school_id, COALESCE(v_before, 'all (default)'), v_after));
        END IF;
    ELSIF p_operation <> 'Get' THEN
        RAISE EXCEPTION 'Unknown operation %.', p_operation;
    END IF;

    OPEN p_result FOR
    SELECT p_school_id AS school_id, v_name AS school_name,
           COALESCE(w.allow_transport,  TRUE) AS allow_transport,
           COALESCE(w.allow_exams,      TRUE) AS allow_exams,
           COALESCE(w.allow_inventory,  TRUE) AS allow_inventory,
           COALESCE(w.allow_payroll,    TRUE) AS allow_payroll,
           COALESCE(w.allow_attendance, TRUE) AS allow_attendance,
           COALESCE(w.allow_academics,  TRUE) AS allow_academics,
           COALESCE(w.allow_fees,       TRUE) AS allow_fees,
           COALESCE(w.allow_accounts,   TRUE) AS allow_accounts,
           -- BUG-047: the school's own switches, so the platform page can show a
           -- module that is given but switched off by the school itself.
           COALESCE(w.enable_transport,  TRUE) AS enable_transport,
           COALESCE(w.enable_exams,      TRUE) AS enable_exams,
           COALESCE(w.enable_inventory,  TRUE) AS enable_inventory,
           COALESCE(w.enable_payroll,    TRUE) AS enable_payroll,
           COALESCE(w.enable_attendance, TRUE) AS enable_attendance,
           COALESCE(w.enable_academics,  TRUE) AS enable_academics,
           COALESCE(w.enable_fees,       TRUE) AS enable_fees,
           COALESCE(w.enable_accounts,   TRUE) AS enable_accounts,
           CASE WHEN p_operation = 'Save' THEN 'Modules saved for ' || v_name || '.' ELSE '' END AS message
      FROM (SELECT 1) one
      LEFT JOIN core.school_admission_workflow_settings w
             ON w.tenant_id = v_tenant AND w.school_id = p_school_id AND NOT COALESCE(w.is_deleted, FALSE);
END;
$procedure$;


-- ---------------------------------------------------------------------
-- UX-14 / owner decision #13: core.sp_student_list gets p_section_keys, so a
-- teacher's Student Directory lists only the sections they teach. The old
-- overload (without it) is dropped first.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS core.sp_student_list(integer, integer, integer, text, text, text, text, text, text, integer, integer, text, text, refcursor);
CREATE OR REPLACE PROCEDURE core.sp_student_list(IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_search text DEFAULT NULL::text, IN p_filter_class text DEFAULT NULL::text, IN p_filter_gender text DEFAULT NULL::text, IN p_filter_fee text DEFAULT NULL::text, IN p_filter_year text DEFAULT NULL::text, IN p_filter_status text DEFAULT NULL::text, IN p_page_no integer DEFAULT 1, IN p_page_size integer DEFAULT 10, IN p_sort_column text DEFAULT NULL::text, IN p_sort_dir text DEFAULT 'asc'::text, INOUT p_result refcursor DEFAULT 'student_list_cursor'::refcursor, IN p_section_keys text[] DEFAULT NULL::text[])
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_offset  integer;
    v_col     text;
    v_asc     boolean;
    -- The search as typed, trimmed, lower-cased and with inner runs of spaces
    -- collapsed, so "meera  devi" finds "Meera Devi".
    v_q       text := NULLIF(regexp_replace(LOWER(TRIM(COALESCE(p_search, ''))), '\s+', ' ', 'g'), '');
BEGIN
    -- Tenant/school scope guard (tenant 1 = platform, never real data).
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        OPEN p_result FOR SELECT WHERE FALSE;   -- empty result set
        RETURN;
    END IF;

    v_offset := (GREATEST(COALESCE(p_page_no, 1), 1) - 1) * COALESCE(p_page_size, 10);
    v_col    := LOWER(TRIM(COALESCE(p_sort_column, '')));
    v_asc    := LOWER(TRIM(COALESCE(p_sort_dir, 'asc'))) <> 'desc';

    OPEN p_result FOR
        WITH filtered AS (
            SELECT
                s.student_id, s.public_id, s.admission_no, s.roll_no, s.student_name,
                s.gender,
                -- When a session is asked for, report the class/section the
                -- student held IN THAT SESSION, not their present one.
                COALESCE(e.class_name,    s.class_name)    AS class_name,
                COALESCE(e.section,       s.section)       AS section,
                COALESCE(e.academic_year, s.academic_year) AS academic_year,
                s.admission_date, s.created_at, s.guardian_name, s.mobile,
                s.annual_total, s.status, s.approval_status, s.enquiry_id,
                s.photo_url,
                -- Teaching order of the class in the student's session, so a
                -- "sort by class" reads Nursery, LKG, 1, 2 ... 10, not text order.
                (SELECT MIN(ac.display_order)
                   FROM academic.academic_classes ac
                   JOIN academic.academic_years ay ON ay.academic_year_id = ac.academic_year_id
                  WHERE ac.tenant_id = s.tenant_id AND ac.school_id = s.school_id
                    AND ac.class_name = COALESCE(e.class_name, s.class_name)
                    AND ay.academic_year_name = COALESCE(e.academic_year, s.academic_year)
                    AND COALESCE(ac.is_deleted, FALSE) = FALSE) AS class_order,
                -- Concession settles a due as surely as cash does. Leaving it
                -- out showed a fully settled student as owing / Partial.
                COALESCE((
                    SELECT CASE
                        WHEN SUM(l.amount_due - l.amount_paid - l.concession) <= 0 THEN 'Paid'
                        WHEN SUM(l.amount_paid + l.concession) = 0 THEN 'Pending'
                        ELSE 'Partial' END
                    FROM core.student_ledger l
                    WHERE l.student_id = s.student_id
                ), 'Pending') AS fee_status,
                COALESCE((
                    SELECT SUM(l.amount_due - l.amount_paid - l.concession)
                    FROM core.student_ledger l
                    WHERE l.student_id = s.student_id
                ), 0) AS fee_due
            FROM core.students s
            -- Per-session position (core.student_enrolment). students.academic_year
            -- only holds where a student is NOW, so filtering on it loses everyone
            -- who has since been promoted. Matches only when a session is asked
            -- for; otherwise e.* is NULL and the COALESCEs fall back to students.
            LEFT JOIN core.student_enrolment e
                   ON e.student_id    = s.student_id
                  AND e.academic_year = NULLIF(TRIM(COALESCE(p_filter_year, '')), '')
            WHERE s.tenant_id = p_tenant_id
              AND s.school_id = p_school_id
              AND s.is_active = TRUE
              -- strpos, not LIKE: a typed % or _ is a character, not a wildcard
              -- (LIKE '%%%' matched every student).
              AND (
                  v_q IS NULL
                  OR strpos(regexp_replace(LOWER(s.student_name), '\s+', ' ', 'g'), v_q) > 0
                  OR strpos(LOWER(s.admission_no), v_q) > 0
                  OR strpos(regexp_replace(LOWER(COALESCE(s.guardian_name, '')), '\s+', ' ', 'g'), v_q) > 0
                  OR strpos(COALESCE(s.mobile, ''), v_q) > 0
              )
              -- Enrolled in the requested session at all.
              AND (NULLIF(TRIM(COALESCE(p_filter_year, '')), '') IS NULL
                   OR e.enrolment_id IS NOT NULL)
              -- Class is matched against that session's position.
              AND (p_filter_class  IS NULL OR TRIM(p_filter_class)  = '' OR LOWER(COALESCE(e.class_name, s.class_name)) = LOWER(TRIM(p_filter_class)))
              AND (p_filter_gender IS NULL OR TRIM(p_filter_gender) = '' OR LOWER(COALESCE(s.gender,'')) = LOWER(TRIM(p_filter_gender)))
              AND (p_filter_status IS NULL OR TRIM(p_filter_status) = '' OR LOWER(s.status)              = LOWER(TRIM(p_filter_status)))
              -- UX-14 (owner decision #13): a teacher's list holds only the sections
              -- they teach, as 'class|section' keys (lower case, trimmed). NULL = all.
              AND (p_section_keys IS NULL
                   OR LOWER(TRIM(COALESCE(e.class_name, s.class_name, ''))) || '|' ||
                      LOWER(TRIM(COALESCE(e.section, s.section, ''))) = ANY (p_section_keys))
        ),
        scored AS (
            -- fee filter runs after fee_status is computed
            SELECT * FROM filtered f
            WHERE (p_filter_fee IS NULL OR TRIM(p_filter_fee) = '' OR LOWER(f.fee_status) = LOWER(TRIM(p_filter_fee)))
        )
        SELECT
            student_id, public_id, admission_no, roll_no, student_name, gender,
            class_name, section, academic_year, admission_date,
            guardian_name, mobile, annual_total, status, approval_status,
            enquiry_id, fee_status, fee_due, photo_url,
            COUNT(*)                                                    OVER() AS total_count,
            COUNT(*) FILTER (WHERE UPPER(COALESCE(gender,'')) = 'MALE')   OVER() AS male_count,
            COUNT(*) FILTER (WHERE UPPER(COALESCE(gender,'')) = 'FEMALE') OVER() AS female_count,
            COUNT(*) FILTER (WHERE UPPER(COALESCE(status,'')) = 'ACTIVE') OVER() AS active_count
        FROM scored
        ORDER BY
            -- Whitelisted, injection-safe sort (no dynamic SQL).
            CASE WHEN v_col = 'name'    AND v_asc      THEN student_name    END ASC,
            CASE WHEN v_col = 'name'    AND NOT v_asc  THEN student_name    END DESC,
            CASE WHEN v_col = 'class'   AND v_asc      THEN class_order     END ASC,
            CASE WHEN v_col = 'class'   AND v_asc      THEN section         END ASC,
            CASE WHEN v_col = 'class'   AND NOT v_asc  THEN class_order     END DESC,
            CASE WHEN v_col = 'class'   AND NOT v_asc  THEN section         END DESC,
            CASE WHEN v_col = 'admdate' AND v_asc      THEN admission_date  END ASC,
            CASE WHEN v_col = 'admdate' AND NOT v_asc  THEN admission_date  END DESC,
            -- Default: the most recently ENTERED record first, not the most
            -- recent admission date. The two are not the same — a student who
            -- joined in 2023 and is being entered today is the newest row in
            -- this list, and sorting on admission_date buried them near the
            -- bottom where whoever just typed them could not find them.
            -- Sorting by admission date is still available as 'admdate'.
            created_at DESC, student_id DESC
        LIMIT  COALESCE(p_page_size, 10)
        OFFSET v_offset;
    RETURN;
END;
$procedure$;


-- ---------------------------------------------------------------------
-- UX-26: "Elementary School (Class 1-8)" school type.
-- ---------------------------------------------------------------------
INSERT INTO config.school_types (name, created_by, created_at, is_deleted, category_codes)
SELECT 'Elementary School (Class 1–8)', 1, now(), FALSE, ARRAY['SCHOOL']
WHERE NOT EXISTS (SELECT 1 FROM config.school_types WHERE name = 'Elementary School (Class 1–8)');

-- ---------------------------------------------------------------------
-- UX-25: UDISE code on the school profile (11 digits, optional).
-- ---------------------------------------------------------------------
ALTER TABLE core.school_profiles ADD COLUMN IF NOT EXISTS udise_code varchar(11);

-- ---------------------------------------------------------------------
-- UX-28: default departments + designations for a school that has none.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_seed_default_designations(p_tenant_id integer, p_school_id integer, p_action_user_id integer)
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
    IF EXISTS (SELECT 1 FROM config.designations
               WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND is_deleted = FALSE) THEN
        RETURN;
    END IF;

    INSERT INTO config.departments (tenant_id, school_id, name, sort_order, is_active, created_by, created_at)
    SELECT p_tenant_id, p_school_id, d.name, d.ord, TRUE, COALESCE(p_action_user_id, 0), now()
    FROM (VALUES ('Administration', 1), ('Academic', 2), ('Accounts', 3), ('Support', 4), ('Transport', 5)) AS d(name, ord)
    WHERE NOT EXISTS (SELECT 1 FROM config.departments x
                      WHERE x.tenant_id = p_tenant_id AND x.school_id = p_school_id
                        AND x.is_deleted = FALSE AND LOWER(x.name) = LOWER(d.name));

    INSERT INTO config.designations (tenant_id, school_id, name, staff_type, default_department, sort_order, is_active, created_by, created_at)
    SELECT p_tenant_id, p_school_id, d.name, d.stype, d.dept, d.ord, TRUE, COALESCE(p_action_user_id, 0), now()
    FROM (VALUES ('Principal',  'Teaching',     'Administration', 1),
                 ('PGT',        'Teaching',     'Academic',       2),
                 ('TGT',        'Teaching',     'Academic',       3),
                 ('PRT',        'Teaching',     'Academic',       4),
                 ('Clerk',      'Non-Teaching', 'Administration', 5),
                 ('Accountant', 'Non-Teaching', 'Accounts',       6),
                 ('Peon',       'Support',      'Support',        7),
                 ('Driver',     'Transport',    'Transport',      8)) AS d(name, stype, dept, ord);
END;
$function$;

-- ---------------------------------------------------------------------
-- UX-25 / UX-28: core.sp_school_manage takes p_udise_code (validated, saved,
-- returned by GET) and seeds default designations for a new school.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS core.sp_school_manage(character varying, integer, integer, character varying, integer, character varying, character varying, character varying, character varying, integer, character varying, character varying, integer, character varying, character varying, integer, integer, integer, integer, integer, character varying, integer, character varying, character varying, character varying, character varying, character varying, character varying, integer, character varying, character varying, character varying, character varying, character varying, integer, integer, integer, boolean, boolean, boolean, boolean, character varying, character varying, character varying, character varying, integer, integer, integer, integer, refcursor, integer);
CREATE OR REPLACE PROCEDURE core.sp_school_manage(IN p_operation character varying, IN p_tenant_id integer, IN p_action_user_id integer, IN p_tenant_mode character varying DEFAULT NULL::character varying, IN p_selected_tenant_id integer DEFAULT NULL::integer, IN p_tenant_name character varying DEFAULT NULL::character varying, IN p_tenant_code character varying DEFAULT NULL::character varying, IN p_tenant_email character varying DEFAULT NULL::character varying, IN p_tenant_phone character varying DEFAULT NULL::character varying, IN p_school_id integer DEFAULT NULL::integer, IN p_school_name character varying DEFAULT NULL::character varying, IN p_display_name character varying DEFAULT NULL::character varying, IN p_status_id integer DEFAULT NULL::integer, IN p_registration_number character varying DEFAULT NULL::character varying, IN p_affiliation_number character varying DEFAULT NULL::character varying, IN p_board_id integer DEFAULT NULL::integer, IN p_school_type_id integer DEFAULT NULL::integer, IN p_ownership_type_id integer DEFAULT NULL::integer, IN p_medium_id integer DEFAULT NULL::integer, IN p_established_year integer DEFAULT NULL::integer, IN p_website character varying DEFAULT NULL::character varying, IN p_address_type_id integer DEFAULT NULL::integer, IN p_address_line1 character varying DEFAULT NULL::character varying, IN p_address_line2 character varying DEFAULT NULL::character varying, IN p_city character varying DEFAULT NULL::character varying, IN p_district character varying DEFAULT NULL::character varying, IN p_state character varying DEFAULT NULL::character varying, IN p_pincode character varying DEFAULT NULL::character varying, IN p_contact_type_id integer DEFAULT NULL::integer, IN p_contact_name character varying DEFAULT NULL::character varying, IN p_designation character varying DEFAULT NULL::character varying, IN p_contact_email character varying DEFAULT NULL::character varying, IN p_phone character varying DEFAULT NULL::character varying, IN p_alternate_phone character varying DEFAULT NULL::character varying, IN p_academic_year_id integer DEFAULT NULL::integer, IN p_date_format_id integer DEFAULT NULL::integer, IN p_time_format_id integer DEFAULT NULL::integer, IN p_enable_sms boolean DEFAULT false, IN p_enable_email boolean DEFAULT false, IN p_enable_whatsapp boolean DEFAULT false, IN p_create_school_admin boolean DEFAULT false, IN p_admin_full_name character varying DEFAULT NULL::character varying, IN p_admin_email character varying DEFAULT NULL::character varying, IN p_admin_phone character varying DEFAULT NULL::character varying, IN p_password_hash character varying DEFAULT NULL::character varying, IN p_country_id integer DEFAULT NULL::integer, IN p_state_id integer DEFAULT NULL::integer, IN p_district_id integer DEFAULT NULL::integer, IN p_board_state_id integer DEFAULT NULL::integer, INOUT p_result refcursor DEFAULT 'school_cursor'::refcursor, IN p_institution_category_id integer DEFAULT NULL::integer, IN p_udise_code character varying DEFAULT NULL::character varying)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_school_id integer;
    v_tenant_id integer;
    v_school_code character varying;
    v_user_id integer;
    v_seq integer;
    v_old_status character varying;
    v_new_status character varying;
    v_category_id integer;
    v_category_code character varying;
    v_category_name character varying;
    v_board_required boolean;
BEGIN
    IF p_operation IS NULL OR TRIM(p_operation) = '' THEN
        RAISE EXCEPTION 'Operation is required.';
    END IF;

    p_operation := UPPER(TRIM(p_operation));

    -- Creating or changing a school -- including its status, which is the login
    -- gate -- is a platform action. GET / LIST stay readable by the school itself.
    IF p_operation IN ('INSERT', 'UPDATE', 'DELETE') AND COALESCE(p_tenant_id, 0) <> 1 THEN
        RAISE EXCEPTION 'Only the platform super admin can create or change a school.';
    END IF;

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
            sp.udise_code,
            sp.board_id,
            sp.board_state_id,
            sp.institution_category_id,
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
            a.country_id,
            a.state_id,
            a.district_id,

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

    -- DELETE (soft delete) was removed: it hid the school from the list AND from Edit,
    -- so it could never be reopened or purged. Close it (status) or purge it instead.

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

    -- core.schools.status_id has no foreign key; an unknown id would block every login
    -- with an empty message.
    IF NOT EXISTS (SELECT 1 FROM config.school_statuses
                   WHERE school_status_id = p_status_id AND is_deleted = FALSE) THEN
        RAISE EXCEPTION 'Please select a valid status.';
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

    IF TRIM(p_pincode) !~ '^[1-9][0-9]{5}$' THEN
        RAISE EXCEPTION 'Pincode must be 6 digits and cannot start with 0.';
    END IF;

    IF p_contact_name IS NULL OR TRIM(p_contact_name) = '' THEN
        RAISE EXCEPTION 'Primary contact person is required.';
    END IF;

    -- Boards flagged requires_state (State Board, Madrasah Board) are meaningless
    -- without knowing WHICH state's board â€” MSBSHSE and UP Board share nothing but
    -- the label. Driven by the flag, not a hardcoded board_id.
    IF p_board_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM config.boards
                   WHERE board_id = p_board_id AND requires_state = TRUE AND is_deleted = FALSE)
       AND (p_board_state_id IS NULL OR p_board_state_id <= 0) THEN
        RAISE EXCEPTION 'Please select which state''s board this school follows.';
    END IF;

    -- Without the address state id the mismatch check below cannot run, and a UP Board
    -- school could be saved in Bihar.
    IF p_board_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM config.boards
                   WHERE board_id = p_board_id AND requires_state = TRUE AND is_deleted = FALSE)
       AND (p_state_id IS NULL OR p_state_id <= 0) THEN
        RAISE EXCEPTION 'Please select the state from the list.';
    END IF;

    -- A State Board is granted by one state's education department, so a UP Board school
    -- cannot be located in Bihar. Rejected rather than silently corrected: here the super
    -- admin chose both values, so they should see which one is wrong. (On the school's own
    -- Basic Profile the field is locked instead â€” nothing to correct there.)
    -- This is the hole SCH14 came through.
    IF p_board_id IS NOT NULL
       AND p_board_state_id IS NOT NULL AND p_board_state_id > 0
       AND p_state_id IS NOT NULL AND p_state_id > 0
       AND p_state_id <> p_board_state_id
       AND EXISTS (SELECT 1 FROM config.boards
                   WHERE board_id = p_board_id AND requires_state = TRUE AND is_deleted = FALSE) THEN
        RAISE EXCEPTION 'A % school must be located in % â€” the address state does not match the board.',
            (SELECT name FROM config.boards WHERE board_id = p_board_id),
            (SELECT name FROM config.states WHERE state_id = p_board_state_id);
    END IF;

    -- Mobile or landline with STD code, stored as digits -- the same rule as the
    -- school's own Basic Profile (core.fn_school_phone_clean).
    p_phone := core.fn_school_phone_clean(p_phone, 'Phone');
    IF p_phone IS NULL THEN
        RAISE EXCEPTION 'Phone is required.';
    END IF;

    -- A login phone is a mobile number: 10 digits starting 6-9, like the form asks.
    IF p_admin_phone IS NOT NULL AND TRIM(p_admin_phone) <> ''
       AND TRIM(p_admin_phone) !~ '^[6-9][0-9]{9}$' THEN
        RAISE EXCEPTION 'Admin phone must be a 10-digit mobile number.';
    END IF;

    -- Institution category. Not sent (an app older than this parameter, or a direct
    -- call): an existing school keeps its own, a new one is a SCHOOL.
    v_category_id := p_institution_category_id;
    IF v_category_id IS NULL AND p_operation = 'UPDATE' THEN
        SELECT institution_category_id INTO v_category_id
        FROM core.school_profiles
        WHERE school_id = p_school_id AND is_deleted = FALSE;
    END IF;
    v_category_id := COALESCE(v_category_id, 1);

    SELECT category_code, name, board_required
      INTO v_category_code, v_category_name, v_board_required
    FROM config.institution_categories
    WHERE category_id = v_category_id AND is_deleted = FALSE;
    IF v_category_code IS NULL THEN
        RAISE EXCEPTION 'Please select a valid institution category.';
    END IF;

    IF v_board_required AND p_board_id IS NULL THEN
        RAISE EXCEPTION 'Board is required.';
    END IF;

    -- Each list row says which categories it is offered for (category_codes, NULL = all),
    -- so a coaching centre cannot be saved with a CBSE board or a "K-12 School" type.
    IF p_board_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM config.boards
        WHERE board_id = p_board_id AND is_deleted = FALSE
          AND (category_codes IS NULL OR v_category_code = ANY (category_codes))) THEN
        RAISE EXCEPTION 'The selected board is not available for a %.', v_category_name;
    END IF;

    IF p_school_type_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM config.school_types
        WHERE school_type_id = p_school_type_id AND is_deleted = FALSE
          AND (category_codes IS NULL OR v_category_code = ANY (category_codes))) THEN
        RAISE EXCEPTION 'The selected type is not available for a %.', v_category_name;
    END IF;

    IF p_ownership_type_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM config.ownership_types
        WHERE ownership_type_id = p_ownership_type_id AND is_deleted = FALSE
          AND (category_codes IS NULL OR v_category_code = ANY (category_codes))) THEN
        RAISE EXCEPTION 'The selected ownership is not available for a %.', v_category_name;
    END IF;

    /*
        TENANT RESOLUTION
    */
    IF p_operation = 'INSERT' THEN
        IF p_tenant_mode = 'existing' THEN
            IF p_selected_tenant_id IS NULL OR p_selected_tenant_id <= 0 THEN
                RAISE EXCEPTION 'Please select tenant.';
            END IF;

            -- Tenant 1 is the platform; a school there fails chk_school_profiles_scope
            -- with a raw constraint error, so say it plainly instead.
            IF p_selected_tenant_id = 1 THEN
                RAISE EXCEPTION 'The platform tenant cannot own a school. Choose another tenant or create a new one.';
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

            -- A short slug: lower-case letters, digits and hyphens (e.g. "dps-group").
            IF LOWER(TRIM(p_tenant_code)) !~ '^[a-z0-9][a-z0-9-]{1,49}$' THEN
                RAISE EXCEPTION 'Tenant code may use only letters, digits and hyphens (2-50 characters).';
            END IF;

            -- No is_deleted filter: the unique index covers deleted tenants too, so a
            -- deleted tenant's code is still taken.
            IF EXISTS (
                SELECT 1
                FROM core.tenants
                WHERE LOWER(TRIM(tenant_code)) = LOWER(TRIM(p_tenant_code))
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
        IF p_operation = 'UPDATE' THEN
            RAISE EXCEPTION 'School not found.';
        END IF;
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

    -- UX-25: UDISE code is 11 digits (optional).
    IF NULLIF(TRIM(p_udise_code), '') IS NOT NULL AND TRIM(p_udise_code) !~ '^[0-9]{11}$' THEN
        RAISE EXCEPTION 'UDISE code must be exactly 11 digits.';
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

        -- One shared guard (see Database/user_email_unique.sql) instead of an
        -- inline EXISTS. The inline version filtered only is_active, so an email
        -- held by a DEACTIVATED user slipped past it and then blew up on the
        -- unique index with a raw Postgres error instead of this message.
        IF p_operation = 'INSERT' AND core.fn_user_email_taken(p_admin_email) THEN
            RAISE EXCEPTION 'This email is already registered to another user.';
        END IF;

        -- Phone must be unique across active login users (mirrors the email rule).
        IF p_operation = 'INSERT'
           AND p_admin_phone IS NOT NULL AND TRIM(p_admin_phone) <> ''
           AND core.fn_user_phone_taken(p_admin_phone) THEN
            RAISE EXCEPTION 'Admin phone already exists.';
        END IF;
    END IF;

    /*
        INSERT / UPDATE SCHOOL MASTER
        Only basic school fields should be stored in core.schools.
    */
    IF p_operation = 'INSERT' THEN
        -- Running sequence: SCH1, SCH2, SCH3, ... (see Database/school_code_sequence.sql)
        --
        -- WHY a counter row and not a sequence: nextval() does not roll back, so a
        -- failed save would burn a number and leave a hole. This UPDATE rolls back
        -- with the transaction, keeping the numbering gap-free, and its row lock
        -- makes concurrent creates queue instead of racing to the same number.
        --
        -- The old 'SCH' || YYYYMMDDHH24MISS was only unique to the second, so two
        -- schools created in the same second on one tenant collided on
        -- uq_school_code (tenant_id, school_code) and the second save failed.
        UPDATE core.school_code_counters
        SET last_seq   = last_seq + 1,
            updated_at = NOW()
        WHERE counter_key = 'GLOBAL'
        RETURNING last_seq INTO v_seq;

        IF v_seq IS NULL THEN
            RAISE EXCEPTION 'School code counter is missing. Run Database/school_code_sequence.sql.';
        END IF;

        v_school_code := 'SCH' || v_seq;

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

        PERFORM core.fn_admin_audit(1, NULL, p_action_user_id, 'SCHOOL_CREATE', 'SuperAdmin/Schools',
            'core.schools', v_school_id,
            format('School %s (%s) created on tenant %s', TRIM(p_school_name), v_school_code, v_tenant_id));

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

        SELECT st.name INTO v_old_status
        FROM core.schools s LEFT JOIN config.school_statuses st ON st.school_status_id = s.status_id
        WHERE s.school_id = v_school_id;

        UPDATE core.schools
        SET
            school_name = TRIM(p_school_name),
            display_name = NULLIF(TRIM(p_display_name), ''),
            status_id = p_status_id,
            updated_by = p_action_user_id,
            updated_at = NOW()
        WHERE school_id = v_school_id
          AND tenant_id = v_tenant_id;

        SELECT name INTO v_new_status FROM config.school_statuses WHERE school_status_id = p_status_id;
        IF v_old_status IS DISTINCT FROM v_new_status THEN
            PERFORM core.fn_admin_audit(1, NULL, p_action_user_id, 'SCHOOL_STATUS', 'SuperAdmin/Schools',
                'core.schools', v_school_id,
                format('School %s (tenant %s) status: %s -> %s', v_school_id, v_tenant_id,
                       COALESCE(v_old_status, '?'), COALESCE(v_new_status, '?')));
        END IF;
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
        udise_code,
        board_id,
        board_state_id,
        institution_category_id,
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
        NULLIF(TRIM(p_udise_code), ''),
        p_board_id,
        -- Cleared when the chosen board doesn't need one, so switching State Board
        -- -> CBSE can't leave a stale state behind.
        CASE WHEN EXISTS (SELECT 1 FROM config.boards
                          WHERE board_id = p_board_id AND requires_state = TRUE AND is_deleted = FALSE)
             THEN p_board_state_id ELSE NULL END,
        v_category_id,
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
        udise_code = EXCLUDED.udise_code,
        board_id = EXCLUDED.board_id,
        board_state_id = EXCLUDED.board_state_id,
        institution_category_id = EXCLUDED.institution_category_id,
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
        country_id,
        state_id,
        district_id,
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
        p_country_id,
        p_state_id,
        p_district_id,
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
        country_id = EXCLUDED.country_id,
        state_id = EXCLUDED.state_id,
        district_id = EXCLUDED.district_id,
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

    -- Roles are tenant-scoped (config.roles has a row per tenant). Seed the standard
    -- staff roles for this tenant if they are missing -- on every save, not only when
    -- an admin is created at INSERT. Otherwise a school created without an admin has
    -- no SCHOOL_ADMIN role, so the admin added later from Edit gets a login with no
    -- role and can never sign in, and the built-in role defaults below find nothing.
    -- role_id is an identity column, so it is left to auto-generate.
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

        -- A brand-new user cannot conflict, so nothing inserted means the tenant's
        -- SCHOOL_ADMIN role is missing or switched off: stop rather than leave a login
        -- that can never sign in.
        IF NOT FOUND THEN
            RAISE EXCEPTION 'This tenant has no active School Admin role, so the admin could not be created.';
        END IF;

        PERFORM core.fn_admin_audit(1, NULL, p_action_user_id, 'SCHOOL_ADMIN_CREATE', 'SuperAdmin/Schools',
            'core.users', v_user_id,
            format('School admin %s created for school %s (tenant %s)', LOWER(TRIM(p_admin_email)), v_school_id, v_tenant_id));
    END IF;

    -- A new school's built-in roles (Teacher, Accountant, Receptionist) start with
    -- sensible permissions instead of none (builtin_role_defaults.sql).
    IF p_operation = 'INSERT' THEN
        PERFORM config.fn_apply_builtin_role_defaults(v_tenant_id, v_school_id, p_action_user_id);
        -- UX-28: common departments and designations, so the staff import works
        -- from day one (its own template example uses PRT).
        PERFORM core.fn_seed_default_designations(v_tenant_id, v_school_id, p_action_user_id);
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

        -- Same guard, excluding the admin being edited so they don't clash with themselves.
        IF core.fn_user_email_taken(p_admin_email, v_user_id) THEN
            RAISE EXCEPTION 'This email is already registered to another user.';
        END IF;

        -- Phone must stay unique across active login users (excluding the admin being edited).
        IF p_admin_phone IS NOT NULL AND TRIM(p_admin_phone) <> ''
           AND core.fn_user_phone_taken(p_admin_phone, v_user_id) THEN
            RAISE EXCEPTION 'Admin phone already exists.';
        END IF;

        IF v_user_id IS NOT NULL THEN
            -- Update existing admin. Password is changed only when a new hash is supplied.
            UPDATE core.users
            SET email = LOWER(TRIM(p_admin_email)),
                password_hash = COALESCE(NULLIF(TRIM(p_password_hash), ''), password_hash),
                -- A super-admin reset must be single-use: the admin is forced to pick
                -- their own password at next login, so the person who reset it does not
                -- keep working knowledge of a live credential. INSERT already does this
                -- for brand-new admins; the reset path was missing it.
                -- CASE, not TRUE: this same UPDATE runs for a plain name/email edit with
                -- no password, and that must NOT lock the admin out of their own session.
                must_change_password = CASE
                    WHEN NULLIF(TRIM(p_password_hash), '') IS NOT NULL THEN TRUE
                    ELSE must_change_password
                END,
                -- A new password ends the admin's open sessions (cookie stamp check).
                password_changed_at = CASE
                    WHEN NULLIF(TRIM(p_password_hash), '') IS NOT NULL THEN NOW()
                    ELSE password_changed_at
                END,
                updated_by = p_action_user_id,
                updated_at = NOW()
            WHERE user_id = v_user_id;

            IF NULLIF(TRIM(p_password_hash), '') IS NOT NULL THEN
                PERFORM core.fn_admin_audit(1, NULL, p_action_user_id, 'PASSWORD_RESET_BY_ADMIN', 'SuperAdmin/Schools',
                    'core.users', v_user_id,
                    format('School admin password reset for school %s (tenant %s)', v_school_id, v_tenant_id));
            END IF;

            UPDATE core.user_profiles
            SET full_name = COALESCE(NULLIF(TRIM(p_admin_full_name), ''), full_name),
                phone = NULLIF(TRIM(p_admin_phone), ''),
                updated_by = p_action_user_id,
                updated_at = NOW()
            WHERE user_id = v_user_id
              AND tenant_id = v_tenant_id;

        ELSIF p_password_hash IS NOT NULL AND TRIM(p_password_hash) <> '' THEN
            -- No admin yet: create one (only when a password was supplied).
            -- must_change_password = TRUE, exactly like INSERT: the super admin typed
            -- this password, so it must be single-use.
            INSERT INTO core.users
                (tenant_id, school_id, email, password_hash, must_change_password, is_active, created_by, created_at)
            VALUES
                (v_tenant_id, v_school_id, LOWER(TRIM(p_admin_email)), p_password_hash, TRUE, TRUE, p_action_user_id, NOW())
            RETURNING user_id INTO v_user_id;

            PERFORM core.fn_admin_audit(1, NULL, p_action_user_id, 'SCHOOL_ADMIN_CREATE', 'SuperAdmin/Schools',
                'core.users', v_user_id,
                format('School admin %s created for school %s (tenant %s)', LOWER(TRIM(p_admin_email)), v_school_id, v_tenant_id));

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

            IF NOT FOUND THEN
                RAISE EXCEPTION 'This tenant has no active School Admin role, so the admin could not be created.';
            END IF;
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
$procedure$;


-- ---------------------------------------------------------------------
-- UX-25: the School Profile page (School Admin) reads and saves the UDISE
-- code through this small proc, beside core.sp_school_admin_basic_profile_manage.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE core.sp_school_udise(
    IN p_operation text, IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer,
    IN p_udise_code text DEFAULT NULL, INOUT p_result refcursor DEFAULT 'udise_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id IS NULL OR p_tenant_id <= 1 OR p_school_id IS NULL OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid tenant/school scope.';
    END IF;

    IF p_operation = 'Save' THEN
        IF NULLIF(TRIM(p_udise_code), '') IS NOT NULL AND TRIM(p_udise_code) !~ '^[0-9]{11}$' THEN
            RAISE EXCEPTION 'UDISE code must be exactly 11 digits.';
        END IF;
        UPDATE core.school_profiles
        SET    udise_code = NULLIF(TRIM(p_udise_code), ''),
               updated_by = p_action_user_id, updated_at = now()
        WHERE  tenant_id = p_tenant_id AND school_id = p_school_id;
    ELSIF p_operation <> 'Get' THEN
        RAISE EXCEPTION 'Unknown operation %.', p_operation;
    END IF;

    OPEN p_result FOR
    SELECT sp.udise_code
    FROM   core.school_profiles sp
    WHERE  sp.tenant_id = p_tenant_id AND sp.school_id = p_school_id;
END;
$procedure$;


-- ---------------------------------------------------------------------
-- BUG-049: Import Data "Check" compares the file with the school's students:
-- every admission number in use (any status) and, for active students, the
-- name + DOB + mobile the admission save treats as a duplicate.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE core.sp_import_existing_students(
    IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer,
    INOUT p_result refcursor DEFAULT 'import_existing_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    OPEN p_result FOR
    SELECT UPPER(REGEXP_REPLACE(TRIM(COALESCE(admission_no, '')), '\s+', ' ', 'g')) AS admission_no,
           regexp_replace(LOWER(TRIM(COALESCE(student_name, ''))), '\s+', ' ', 'g')  AS student_name,
           to_char(NULLIF(dob, '')::date, 'YYYY-MM-DD')                              AS dob,
           COALESCE(mobile, '')                                                       AS mobile,
           is_active
    FROM   core.students
    WHERE  tenant_id = p_tenant_id AND school_id = p_school_id;
END;
$procedure$;


-- ---------------------------------------------------------------------
-- BUG-008 / UX-19: dashboard speed. Indexes for the dashboard's reads and a
-- core.sp_dashboard_summary that reads the week's money lines once and lets
-- today's attendance use an index.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS ix_student_attendance_school_date
    ON core.student_attendance (tenant_id, school_id, attendance_date);
CREATE INDEX IF NOT EXISTS ix_fee_payments_school_date
    ON core.fee_payments (tenant_id, school_id, payment_date);
CREATE INDEX IF NOT EXISTS ix_student_ledger_school
    ON core.student_ledger (tenant_id, school_id);
CREATE INDEX IF NOT EXISTS ix_student_enrolment_school_year
    ON core.student_enrolment (tenant_id, school_id, academic_year) INCLUDE (student_id, status);

CREATE OR REPLACE PROCEDURE core.sp_dashboard_summary(IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, INOUT p_kpi refcursor DEFAULT 'db_kpi'::refcursor, INOUT p_trend refcursor DEFAULT 'db_trend'::refcursor, INOUT p_classes refcursor DEFAULT 'db_classes'::refcursor, INOUT p_modes refcursor DEFAULT 'db_modes'::refcursor, INOUT p_defaulters refcursor DEFAULT 'db_defaulters'::refcursor, INOUT p_recent refcursor DEFAULT 'db_recent'::refcursor, INOUT p_approvals refcursor DEFAULT 'db_approvals'::refcursor, INOUT p_events refcursor DEFAULT 'db_events'::refcursor, INOUT p_birthdays refcursor DEFAULT 'db_birthdays'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        OPEN p_kpi FOR SELECT 0 AS students, 0 AS staff, 0::numeric AS today_collection,
                              0::numeric AS outstanding, 0 AS due_students, 0 AS on_leave_today,
                              0::numeric AS yesterday_collection, 0 AS present_today,
                              0 AS marked_today;
        OPEN p_trend      FOR SELECT NULL::date AS d, 0::numeric AS amount WHERE FALSE;
        OPEN p_classes    FOR SELECT NULL::text AS class_name, 0 AS students WHERE FALSE;
        OPEN p_modes      FOR SELECT NULL::text AS mode, 0::numeric AS amount WHERE FALSE;
        OPEN p_defaulters FOR SELECT NULL::int AS student_id, NULL::text AS student_name WHERE FALSE;
        OPEN p_recent     FOR SELECT NULL::text AS receipt_no WHERE FALSE;
        OPEN p_approvals  FOR SELECT NULL::int AS leave_id WHERE FALSE;
        OPEN p_events     FOR SELECT NULL::date AS calendar_date WHERE FALSE;
        OPEN p_birthdays  FOR SELECT NULL::text AS name WHERE FALSE;
        RETURN;
    END IF;

    -- ── 1. Headline numbers ─────────────────────────────────────────────────
    OPEN p_kpi FOR
    SELECT
        -- Students on the roll of the session in progress (core.student_enrolment):
        -- a child admitted for next session does not count yet, a child promoted
        -- early still counts here until this session ends.
        (SELECT COUNT(DISTINCT e.student_id) FROM core.student_enrolment e
          WHERE e.tenant_id = p_tenant_id AND e.school_id = p_school_id
            AND e.academic_year = core.fn_session_on(p_tenant_id, p_school_id, CURRENT_DATE)
            AND COALESCE(e.status, '') NOT IN ('Left', 'PassedOut'))::int
            AS students,

        (SELECT COUNT(*) FROM core.staff st
          WHERE st.tenant_id = p_tenant_id AND st.school_id = p_school_id
            AND st.is_deleted = FALSE AND COALESCE(st.status,'Active') = 'Active')::int
            AS staff,

        -- Receipts issued today minus cancellations made today.
        (SELECT COALESCE(SUM(ml.amount), 0)
           FROM core.fn_fee_money_lines(p_tenant_id, p_school_id, CURRENT_DATE, CURRENT_DATE) ml)
            AS today_collection,

        (SELECT COALESCE(SUM(ml.amount), 0)
           FROM core.fn_fee_money_lines(p_tenant_id, p_school_id, CURRENT_DATE - 1, CURRENT_DATE - 1) ml)
            AS yesterday_collection,

        -- The ledger is the single source of truth for what is owed: rows that
        -- have fallen due, for students of this school.
        (SELECT COALESCE(SUM(l.amount_due - l.amount_paid - COALESCE(l.concession,0)), 0)
           FROM core.student_ledger l
           JOIN core.students s ON s.student_id = l.student_id
                               AND s.tenant_id = p_tenant_id AND s.school_id = p_school_id
          WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
            AND l.amount_due > l.amount_paid + COALESCE(l.concession,0)
            AND (l.due_date IS NULL OR l.due_date::date <= CURRENT_DATE))
            AS outstanding,

        (SELECT COUNT(DISTINCT l.student_id) FROM core.student_ledger l
           JOIN core.students s ON s.student_id = l.student_id
                               AND s.tenant_id = p_tenant_id AND s.school_id = p_school_id
          WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
            AND l.amount_due > l.amount_paid + COALESCE(l.concession,0)
            AND (l.due_date IS NULL OR l.due_date::date <= CURRENT_DATE))::int
            AS due_students,

        (SELECT COUNT(*) FROM core.staff_leave sl
          WHERE sl.tenant_id = p_tenant_id AND sl.school_id = p_school_id
            AND sl.status = 'Approved'
            AND CURRENT_DATE BETWEEN sl.from_date::date AND sl.to_date::date)::int
            AS on_leave_today,

        -- Today's attendance, over students whose class actually took a register.
        -- attendance_date is stored as 'YYYY-MM-DD' text: compared as text so the
        -- (tenant, school, date) index is used (BUG-008; ::date read every row).
        (SELECT COUNT(*) FROM core.student_attendance a
          WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
            AND a.attendance_date = to_char(CURRENT_DATE, 'YYYY-MM-DD')
            AND a.status NOT IN ('Absent', 'Leave'))::int
            AS present_today,

        (SELECT COUNT(*) FROM core.student_attendance a
          WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
            AND a.attendance_date = to_char(CURRENT_DATE, 'YYYY-MM-DD'))::int
            AS marked_today;

    -- ── 2. Collection, last 7 days ──────────────────────────────────────────
    -- generate_series so a day with no receipts is a zero on the chart rather
    -- than a missing point the line would skip over.
    OPEN p_trend FOR
    -- One read of the money lines for the whole week, then summed per day
    -- (BUG-008: it used to run the function once per day).
    WITH week AS (
        SELECT ml.line_date, SUM(ml.amount) AS amount
        FROM core.fn_fee_money_lines(p_tenant_id, p_school_id, CURRENT_DATE - 6, CURRENT_DATE) ml
        GROUP BY ml.line_date
    )
    SELECT g.d::date AS d, COALESCE(w.amount, 0) AS amount
    FROM generate_series(CURRENT_DATE - 6, CURRENT_DATE, INTERVAL '1 day') AS g(d)
    LEFT JOIN week w ON w.line_date = g.d::date
    ORDER BY d;

    -- ── 3. Class-wise strength ──────────────────────────────────────────────
    -- The same roll, per class. The class is joined by its id: matching the name
    -- found it once per session, so every count doubled once a second session existed.
    OPEN p_classes FOR
    SELECT e.class_name, COUNT(DISTINCT e.student_id)::int AS students
    FROM core.student_enrolment e
    LEFT JOIN academic.academic_classes ac ON ac.academic_class_id = e.academic_class_id
    WHERE e.tenant_id = p_tenant_id AND e.school_id = p_school_id
      AND e.academic_year = core.fn_session_on(p_tenant_id, p_school_id, CURRENT_DATE)
      AND COALESCE(e.status, '') NOT IN ('Left', 'PassedOut')
    GROUP BY e.class_name
    ORDER BY MIN(COALESCE(ac.display_order, 9999)), e.class_name;   -- teaching order

    -- ── 4. Collection by payment mode, this month ───────────────────────────
    OPEN p_modes FOR
    -- By real tender. 'Advance' (paid from the wallet) and 'To wallet' (surplus
    -- saved to it) are not new money in a mode, so the chart leaves them out.
    SELECT ml.mode, SUM(ml.amount) AS amount
    FROM core.fn_fee_money_lines(p_tenant_id, p_school_id,
                                 DATE_TRUNC('month', CURRENT_DATE)::date, CURRENT_DATE) ml
    WHERE ml.mode NOT IN ('Advance', 'To wallet')
    GROUP BY ml.mode
    HAVING SUM(ml.amount) <> 0
    ORDER BY amount DESC;

    -- ── 5. Highest outstanding ──────────────────────────────────────────────
    OPEN p_defaulters FOR
    -- The ledger is summed FIRST and the last payment looked up on its own:
    -- joining payments into the ledger GROUP BY multiplied every figure by the
    -- number of receipts the student had.
    SELECT s.student_id, s.public_id, s.student_name, s.class_name, s.section,
           l.total, l.paid, l.due,
           (SELECT MAX(fp.payment_date) FROM core.fee_payments fp
             WHERE fp.tenant_id = p_tenant_id AND fp.school_id = p_school_id
               AND fp.student_id = s.student_id
               AND COALESCE(fp.is_cancelled, FALSE) = FALSE) AS last_payment
    FROM (SELECT ll.student_id,
                 SUM(ll.amount_due)  AS total,
                 SUM(ll.amount_paid) AS paid,
                 COALESCE(SUM(ll.amount_due - ll.amount_paid - COALESCE(ll.concession,0))
                          FILTER (WHERE ll.amount_due > ll.amount_paid + COALESCE(ll.concession,0)
                                    AND (ll.due_date IS NULL OR ll.due_date::date <= CURRENT_DATE)), 0) AS due
          FROM core.student_ledger ll
          WHERE ll.tenant_id = p_tenant_id AND ll.school_id = p_school_id
          GROUP BY ll.student_id) l
    JOIN core.students s ON s.student_id = l.student_id
                        AND s.tenant_id = p_tenant_id AND s.school_id = p_school_id
    WHERE l.due > 0
    ORDER BY l.due DESC
    LIMIT 10;

    -- ── 6. Recent receipts ──────────────────────────────────────────────────
    OPEN p_recent FOR
    -- A registration receipt has no student yet: name it from the enquiry.
    SELECT fp.receipt_no, fp.amount, fp.payment_mode, fp.payment_date,
           COALESCE(s.student_name, e.student_name) AS student_name,
           COALESCE(s.class_name, e.class_name)     AS class_name
    FROM core.fee_payments fp
    LEFT JOIN core.students  s ON s.student_id = fp.student_id
    LEFT JOIN core.enquiries e ON e.enquiry_id = fp.enquiry_id
    WHERE fp.tenant_id = p_tenant_id AND fp.school_id = p_school_id
      AND COALESCE(fp.is_cancelled, FALSE) = FALSE
    ORDER BY fp.payment_date DESC, fp.payment_id DESC
    LIMIT 8;

    -- ── 7. Pending approvals (leave is the only approval queue that exists) ─
    OPEN p_approvals FOR
    SELECT sl.leave_id, st.full_name, sl.leave_type, sl.from_date, sl.to_date,
           sl.days, sl.applied_at
    FROM core.staff_leave sl
    JOIN core.staff st ON st.staff_id = sl.staff_id
    WHERE sl.tenant_id = p_tenant_id AND sl.school_id = p_school_id
      AND sl.status = 'Pending'
    ORDER BY sl.applied_at
    LIMIT 8;

    -- ── 8. Upcoming calendar entries ────────────────────────────────────────
    OPEN p_events FOR
    SELECT c.calendar_date, c.title, c.day_type
    FROM academic.school_calendar c
    WHERE c.tenant_id = p_tenant_id AND c.school_id = p_school_id
      AND c.calendar_date::date >= CURRENT_DATE
    ORDER BY c.calendar_date
    LIMIT 6;

    -- ── 9. Birthdays today, students and staff together ─────────────────────
    -- Matched on day+month so the year (and leap years) do not matter.
    OPEN p_birthdays FOR
    SELECT s.student_name AS name, 'Student' AS who,
           s.class_name AS detail
    FROM core.students s
    WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id AND s.is_active
      AND s.dob IS NOT NULL
      AND EXTRACT(MONTH FROM s.dob::date) = EXTRACT(MONTH FROM CURRENT_DATE)
      AND EXTRACT(DAY   FROM s.dob::date) = EXTRACT(DAY   FROM CURRENT_DATE)
    UNION ALL
    SELECT st.full_name, 'Staff', COALESCE(st.designation, '')
    FROM core.staff st
    WHERE st.tenant_id = p_tenant_id AND st.school_id = p_school_id
      AND st.is_deleted = FALSE AND COALESCE(st.status,'Active') = 'Active'
      AND st.dob IS NOT NULL
      AND EXTRACT(MONTH FROM st.dob::date) = EXTRACT(MONTH FROM CURRENT_DATE)
      AND EXTRACT(DAY   FROM st.dob::date) = EXTRACT(DAY   FROM CURRENT_DATE);
END;
$procedure$;
