-- ============================================================================
-- Super Admin: modules per school, and "Login as School Admin".
--
-- Three levels decide what a school sees:
--   1. Super Admin GIVES a module to a school          (allow_* below)
--   2. the School Admin switches a given module on/off  (enable_*, Workflow page)
--   3. the School Admin decides which role sees which page (Users & Roles)
--
-- A module is ON for a school only when it is given AND switched on. The
-- Workflow read (sp_school_admin_admission_workflow_manage, GetAdmissionWorkflow)
-- returns enable_* already combined with allow_*, so the menu, the module guard
-- ([RequiresModule]) and every page that reads the flags hide a module that was
-- not given without any change of their own. The School Admin's save cannot
-- switch on a module that was not given (its stored switch is kept as it was).
--
-- Taking a module away hides it; nothing is deleted. Giving it back shows the
-- old data again.
--
-- Re-runnable.
-- ============================================================================

ALTER TABLE core.school_admission_workflow_settings ADD COLUMN IF NOT EXISTS allow_transport boolean NOT NULL DEFAULT TRUE;
ALTER TABLE core.school_admission_workflow_settings ADD COLUMN IF NOT EXISTS allow_exams     boolean NOT NULL DEFAULT TRUE;
ALTER TABLE core.school_admission_workflow_settings ADD COLUMN IF NOT EXISTS allow_inventory boolean NOT NULL DEFAULT TRUE;
ALTER TABLE core.school_admission_workflow_settings ADD COLUMN IF NOT EXISTS allow_payroll   boolean NOT NULL DEFAULT TRUE;

-- Every "Login as School Admin": who, which school, as which user, when.
CREATE TABLE IF NOT EXISTS core.superadmin_login_as_log (
    log_id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    super_user_id   integer NOT NULL,
    tenant_id       integer NOT NULL,
    school_id       integer NOT NULL,
    school_user_id  integer NOT NULL,
    started_at      timestamptz NOT NULL DEFAULT now(),
    ended_at        timestamptz
);


-- ── Is this user a Super Admin? ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION core.fn_is_super_admin(p_user_id integer)
RETURNS boolean LANGUAGE sql STABLE AS $fn$
    SELECT EXISTS (SELECT 1 FROM core.user_roles ur
                     JOIN config.roles r ON r.role_id = ur.role_id
                    WHERE ur.user_id = p_user_id AND r.role_code = 'SUPER_ADMIN'
                      AND COALESCE(ur.is_active, TRUE) AND NOT COALESCE(ur.is_deleted, FALSE));
$fn$;


-- ── Is a module ON for a school? (given AND switched on; no row = on) ────────
-- For SQL flows that act on a module outside its own pages (promotion re-bills
-- a bus, re-admit restores one ...). p_module: transport | exams | inventory | payroll.
CREATE OR REPLACE FUNCTION core.fn_module_on(p_tenant_id integer, p_school_id integer, p_module text)
RETURNS boolean LANGUAGE sql STABLE AS $fn$
    SELECT COALESCE((SELECT CASE lower(p_module)
                              WHEN 'transport' THEN w.enable_transport AND w.allow_transport
                              WHEN 'exams'     THEN w.enable_exams     AND w.allow_exams
                              WHEN 'inventory' THEN w.enable_inventory AND w.allow_inventory
                              WHEN 'payroll'   THEN w.enable_payroll   AND w.allow_payroll
                              ELSE TRUE END
                       FROM core.school_admission_workflow_settings w
                      WHERE w.tenant_id = p_tenant_id AND w.school_id = p_school_id
                        AND NOT COALESCE(w.is_deleted, FALSE)
                      LIMIT 1), TRUE);
$fn$;


-- ── Modules given to a school: Get | Save ───────────────────────────────────
CREATE OR REPLACE PROCEDURE core.sp_superadmin_school_modules(
    IN    p_operation       text,          -- Get | Save
    IN    p_action_user_id  integer,
    IN    p_school_id       integer,
    IN    p_allow_transport boolean DEFAULT NULL,
    IN    p_allow_exams     boolean DEFAULT NULL,
    IN    p_allow_inventory boolean DEFAULT NULL,
    IN    p_allow_payroll   boolean DEFAULT NULL,
    INOUT p_result          refcursor DEFAULT 'modules_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_tenant integer;
    v_name   text;
    v_riders integer;
    v_dues   numeric;
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

        INSERT INTO core.school_admission_workflow_settings
            (tenant_id, school_id, allow_transport, allow_exams, allow_inventory, allow_payroll, created_by)
        VALUES (v_tenant, p_school_id,
                COALESCE(p_allow_transport, TRUE), COALESCE(p_allow_exams, TRUE),
                COALESCE(p_allow_inventory, TRUE), COALESCE(p_allow_payroll, TRUE), p_action_user_id)
        ON CONFLICT (tenant_id, school_id) DO UPDATE
        SET allow_transport = EXCLUDED.allow_transport,
            allow_exams     = EXCLUDED.allow_exams,
            allow_inventory = EXCLUDED.allow_inventory,
            allow_payroll   = EXCLUDED.allow_payroll,
            updated_by = p_action_user_id, updated_at = now();
    ELSIF p_operation <> 'Get' THEN
        RAISE EXCEPTION 'Unknown operation %.', p_operation;
    END IF;

    OPEN p_result FOR
    SELECT p_school_id AS school_id, v_name AS school_name,
           COALESCE(w.allow_transport, TRUE) AS allow_transport,
           COALESCE(w.allow_exams,     TRUE) AS allow_exams,
           COALESCE(w.allow_inventory, TRUE) AS allow_inventory,
           COALESCE(w.allow_payroll,   TRUE) AS allow_payroll,
           CASE WHEN p_operation = 'Save' THEN 'Modules saved for ' || v_name || '.' ELSE '' END AS message
      FROM (SELECT 1) one
      LEFT JOIN core.school_admission_workflow_settings w
             ON w.tenant_id = v_tenant AND w.school_id = p_school_id AND NOT COALESCE(w.is_deleted, FALSE);
END;
$procedure$;


-- ── Login as School Admin: Start | End ──────────────────────────────────────
-- Start: the school's first active School Admin login (the one the school was
-- created with), and a log row. End: closes the log row.
CREATE OR REPLACE PROCEDURE core.sp_superadmin_login_as(
    IN    p_operation       text,          -- Start | End
    IN    p_action_user_id  integer,
    IN    p_school_id       integer DEFAULT NULL,
    IN    p_log_id          integer DEFAULT NULL,
    INOUT p_result          refcursor DEFAULT 'login_as_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_tenant integer;
    v_user   integer;
    v_log    integer;
BEGIN
    IF NOT core.fn_is_super_admin(p_action_user_id) THEN
        RAISE EXCEPTION 'Only the Super Admin can log in as a school.';
    END IF;

    IF p_operation = 'End' THEN
        UPDATE core.superadmin_login_as_log SET ended_at = now()
         WHERE log_id = p_log_id AND super_user_id = p_action_user_id AND ended_at IS NULL;
        OPEN p_result FOR SELECT TRUE AS success;
        RETURN;
    END IF;

    IF p_operation <> 'Start' THEN
        RAISE EXCEPTION 'Unknown operation %.', p_operation;
    END IF;

    SELECT tenant_id INTO v_tenant
      FROM core.schools WHERE school_id = p_school_id AND NOT COALESCE(is_deleted, FALSE);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'School not found.';
    END IF;

    SELECT u.user_id INTO v_user
      FROM core.user_roles ur
      JOIN config.roles r ON r.role_id = ur.role_id AND r.role_code = 'SCHOOL_ADMIN'
      JOIN core.users u   ON u.user_id = ur.user_id
     WHERE ur.tenant_id = v_tenant AND ur.school_id = p_school_id
       AND COALESCE(ur.is_active, TRUE) AND NOT COALESCE(ur.is_deleted, FALSE)
       AND u.is_active AND NOT COALESCE(u.is_deleted, FALSE)
     ORDER BY u.user_id
     LIMIT 1;
    IF v_user IS NULL THEN
        RAISE EXCEPTION 'This school has no active School Admin login.';
    END IF;

    INSERT INTO core.superadmin_login_as_log (super_user_id, tenant_id, school_id, school_user_id)
    VALUES (p_action_user_id, v_tenant, p_school_id, v_user)
    RETURNING log_id INTO v_log;

    OPEN p_result FOR SELECT v_user AS user_id, v_tenant AS tenant_id, p_school_id AS school_id, v_log AS log_id;
END;
$procedure$;


-- ── The school's Workflow settings: GetAdmissionWorkflow | SaveAdmissionWorkflow ─
-- (moved here from fee_charge_from_per_year.sql; same signature)
CREATE OR REPLACE PROCEDURE core.sp_school_admin_admission_workflow_manage(
    IN p_operation                              character varying,
    IN p_tenant_id                              integer,
    IN p_school_id                              integer,
    IN p_action_user_id                         integer,
    IN p_enable_registration                    boolean DEFAULT NULL::boolean,
    IN p_registration_required_before_admission boolean DEFAULT NULL::boolean,
    IN p_enable_registration_fee                boolean DEFAULT NULL::boolean,
    IN p_auto_generate_registration_number      boolean DEFAULT NULL::boolean,
    IN p_registration_number_prefix             character varying DEFAULT NULL::character varying,
    IN p_collect_fee_at_admission               boolean DEFAULT NULL::boolean,
    IN p_enable_security_fee                    boolean DEFAULT NULL::boolean,
    IN p_enable_transport                       boolean DEFAULT NULL::boolean,
    IN p_enable_exams                           boolean DEFAULT NULL::boolean,
    IN p_enable_inventory                       boolean DEFAULT NULL::boolean,
    IN p_enable_payroll                         boolean DEFAULT NULL::boolean,
    INOUT p_result                              refcursor DEFAULT 'result_cursor'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_enable_reg   boolean;
    v_required     boolean;
    v_enable_fee   boolean;
    v_auto_num     boolean;
    v_prefix       varchar(20);
    v_collect      boolean;
    v_enable_sec   boolean;
    v_enable_trans boolean;
    v_enable_exam  boolean;
    v_enable_inv   boolean;
    v_enable_pay   boolean;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    IF p_operation = 'GetAdmissionWorkflow' THEN
        OPEN p_result FOR
        SELECT
            enable_registration,
            registration_required_before_admission,
            enable_registration_fee,
            auto_generate_registration_number,
            registration_number_prefix,
            collect_fee_at_admission,
            enable_security_fee,
            -- a module is on only when the Super Admin gave it AND the school switched it on
            enable_transport AND allow_transport AS enable_transport,
            enable_exams     AND allow_exams     AS enable_exams,
            enable_inventory AND allow_inventory AS enable_inventory,
            enable_payroll   AND allow_payroll   AS enable_payroll,
            allow_transport, allow_exams, allow_inventory, allow_payroll
        FROM core.school_admission_workflow_settings
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND COALESCE(is_deleted, FALSE) = FALSE
        LIMIT 1;

    ELSIF p_operation = 'SaveAdmissionWorkflow' THEN
        v_enable_reg   := COALESCE(p_enable_registration, FALSE);
        v_required     := v_enable_reg AND COALESCE(p_registration_required_before_admission, FALSE);
        v_enable_fee   := v_enable_reg AND COALESCE(p_enable_registration_fee, FALSE);
        v_auto_num     := COALESCE(p_auto_generate_registration_number, TRUE);
        v_prefix       := COALESCE(NULLIF(trim(p_registration_number_prefix), ''), 'REG-');
        v_collect      := COALESCE(p_collect_fee_at_admission, FALSE);
        v_enable_sec   := COALESCE(p_enable_security_fee, FALSE);
        v_enable_trans := COALESCE(p_enable_transport, TRUE);
        v_enable_exam  := COALESCE(p_enable_exams, TRUE);
        v_enable_inv   := COALESCE(p_enable_inventory, TRUE);
        v_enable_pay   := COALESCE(p_enable_payroll, TRUE);

        -- Transport cannot be switched off while children still ride or owe bus
        -- fees: those dues would stay on the fee counter with no module behind them.
        IF NOT v_enable_trans AND core.fn_module_on(p_tenant_id, p_school_id, 'transport') THEN
            IF EXISTS (SELECT 1 FROM core.student_transport a
                         JOIN core.students st ON st.student_id = a.student_id AND st.is_active
                        WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
                          AND a.is_active AND NOT COALESCE(a.is_deleted, FALSE))
               OR EXISTS (SELECT 1 FROM core.student_ledger
                           WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                             AND fee_head_name = 'Transport Fee'
                             AND amount_due - amount_paid - COALESCE(concession, 0) > 0) THEN
                RAISE EXCEPTION 'Transport cannot be turned off while students are on buses or owe bus fees. End their bus assignments (Transport > Assign Transport) first.';
            END IF;
        END IF;

        INSERT INTO core.school_admission_workflow_settings
        (
            tenant_id, school_id,
            enable_registration, registration_required_before_admission,
            enable_registration_fee,
            auto_generate_registration_number, registration_number_prefix,
            collect_fee_at_admission,
            enable_security_fee,
            enable_transport,
            enable_exams,
            enable_inventory,
            enable_payroll,
            created_by, created_at, is_deleted, is_active
        )
        VALUES
        (
            p_tenant_id, p_school_id,
            v_enable_reg, v_required,
            v_enable_fee,
            v_auto_num, v_prefix,
            v_collect,
            v_enable_sec,
            v_enable_trans,
            v_enable_exam,
            v_enable_inv,
            v_enable_pay,
            p_action_user_id, NOW(), FALSE, TRUE
        )
        ON CONFLICT (tenant_id, school_id) DO UPDATE
        SET enable_registration                    = EXCLUDED.enable_registration,
            registration_required_before_admission = EXCLUDED.registration_required_before_admission,
            enable_registration_fee                = EXCLUDED.enable_registration_fee,
            auto_generate_registration_number      = EXCLUDED.auto_generate_registration_number,
            registration_number_prefix             = EXCLUDED.registration_number_prefix,
            collect_fee_at_admission               = EXCLUDED.collect_fee_at_admission,
            enable_security_fee                    = EXCLUDED.enable_security_fee,
            -- a module the Super Admin has not given keeps its stored switch
            enable_transport = CASE WHEN school_admission_workflow_settings.allow_transport
                                    THEN EXCLUDED.enable_transport ELSE school_admission_workflow_settings.enable_transport END,
            enable_exams     = CASE WHEN school_admission_workflow_settings.allow_exams
                                    THEN EXCLUDED.enable_exams ELSE school_admission_workflow_settings.enable_exams END,
            enable_inventory = CASE WHEN school_admission_workflow_settings.allow_inventory
                                    THEN EXCLUDED.enable_inventory ELSE school_admission_workflow_settings.enable_inventory END,
            enable_payroll   = CASE WHEN school_admission_workflow_settings.allow_payroll
                                    THEN EXCLUDED.enable_payroll ELSE school_admission_workflow_settings.enable_payroll END,
            is_deleted = FALSE, is_active = TRUE,
            updated_by = p_action_user_id, updated_at = NOW();

        OPEN p_result FOR SELECT TRUE AS success, 'Saved successfully.' AS message;
    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;
