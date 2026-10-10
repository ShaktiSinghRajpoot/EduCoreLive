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
-- Oct 2026 (platform_access_security_tests.sql) -- needs access_security_hardening.sql:
--   * DELETE also switches off the linked login; REACTIVATE switches it back on.
--     Nobody can deactivate their own login, and the last active school admin of a
--     school cannot be deactivated.
--   * Role ids must be roles of THIS tenant (there is no FK; a foreign id used to
--     become the primary role and lock the person out).
--   * Nobody can change their own roles. Only a school admin (or the platform)
--     can grant or remove SCHOOL_ADMIN, and the last school admin keeps it.
--   * Phone uniqueness uses core.fn_user_phone_taken (last 10 digits, like the index).
--   * Activation, role changes and admin password resets write admin_activity_logs.
--
-- Oct 2026 (hr_leave_payroll_tests.sql, docs/test-cases/hr_leave_payroll.md):
--   * core.staff.last_working_date: the day a leaver last worked. Payroll pays
--     the final month up to that day, so a leaver is no longer dropped from the
--     month they worked in. DELETE records it (p_last_working_date, default today).
--   * Choosing "Inactive" on the Edit form is the same as Deactivate: is_active
--     goes FALSE, status_changed_at and the last working day are stamped and the
--     login is switched off (same guards). Inactive -> Active/On Leave on the
--     form is the same as Reactivate. Before this only the status word changed,
--     so the person stayed in the teacher pools and kept signing in.
--   * UPDATE / DELETE / REACTIVATE check the staff row is in THIS school first.
--     An out-of-scope UPDATE with "create login" ticked used to create the login
--     before finding nothing to update, leaving an orphan account.
--   * Refused: employee code differing only by case, negative salary, a status
--     other than Active / On Leave / Inactive, a staff type outside the four
--     buckets, a new staff member created Inactive, a last working day in the
--     future or before the joining date, deactivating someone already inactive.
--   * p_last_working_date is the LAST parameter (after p_result) so existing
--     positional callers keep working.
--
-- NOTE: parameters are POSITIONAL (Npgsql CommandType.StoredProcedure). The C#
-- StaffService MUST build NpgsqlParameter[] in exactly this order.
-- ============================================================================

-- When a leaver last worked. Text 'YYYY-MM-DD' like every other date column on
-- core.staff (see dates_as_text.sql). NULL for anyone still working, and for
-- staff deactivated before this column existed (no honest value to fill in).
ALTER TABLE core.staff ADD COLUMN IF NOT EXISTS last_working_date varchar(10);

-- "zzhr-001" and "ZZHR-001" are the same badge. The proc checks this too; the
-- index makes it hold under concurrent saves.
CREATE UNIQUE INDEX IF NOT EXISTS uq_staff_employee_code_ci
    ON core.staff (tenant_id, school_id, UPPER(TRIM(employee_code)))
    WHERE employee_code IS NOT NULL AND is_deleted = FALSE;


-- ----------------------------------------------------------------------------
-- Switch a staff member's login off or on, with the guards that go with it.
-- One place for DELETE, REACTIVATE and an Edit-form status change.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE core.sp_staff_login_switch(
    p_tenant_id      integer,
    p_school_id      integer,
    p_action_user_id integer,
    p_staff_id       integer,
    p_user_id        integer,
    p_on             boolean)
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

        PERFORM core.fn_admin_audit(p_tenant_id, p_school_id, p_action_user_id, 'USER_ACTIVATE',
            'Staff', 'core.users', p_user_id,
            format('Login re-activated with staff %s', p_staff_id));
    END IF;
END;
$procedure$;


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
    INOUT p_result     refcursor DEFAULT 'staff_cursor',
    -- leaving (DELETE, or UPDATE to Inactive). Last so positional callers still work.
    p_last_working_date date DEFAULT NULL
)
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

        -- Staff Type is DERIVED from the chosen Designation (single source of
        -- truth) so it can never contradict the title, even if the form is
        -- bypassed. Falls back to whatever the caller sent if the designation
        -- has no bucket set.
        IF p_designation IS NOT NULL AND TRIM(p_designation) <> '' THEN
            SELECT staff_type INTO v_staff_type
            FROM   config.designations
            WHERE  tenant_id = p_tenant_id AND is_deleted = FALSE
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
    SELECT name, staff_type, default_department, default_role_id
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
