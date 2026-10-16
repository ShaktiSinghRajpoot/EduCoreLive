-- Bundle 2026-10-16a: Super Admin gives modules per school (allow_*), nothing of an off module in any flow, Login as School Admin (log table). Run with:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_16a.sql
-- Sources (re-runnable, in this order): superadmin_modules_login_as.sql, student_exit.sql, student_promotion.sql, transport_live_tracking.sql

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

-- ============================================================================
-- Student exit flow — the foundation the Transfer Certificate sits on.
--
-- A student who leaves is NOT deleted: the record stays, is_active goes FALSE
-- and status records how they left. Fee ledger, receipts and (later) the TC
-- register all keep pointing at the same student_id.
--
--   core.sp_student_exit        mark a student as left (or undo it)
--   core.sp_student_exit_list   the real "Inactive / Left" list
--
-- status values used here:
--   Active     still studying
--   Transfer   left for another school   -> eligible for a TC
--   Passout    completed the final class -> eligible for a TC
--   Struck Off removed by the school (long absence, discipline)
--   Withdrawn  parents withdrew, no TC sought
-- ============================================================================

-- ── columns ────────────────────────────────────────────────────────────────
ALTER TABLE core.students
    ADD COLUMN IF NOT EXISTS date_of_leaving  date,
    ADD COLUMN IF NOT EXISTS leaving_reason   varchar(300),
    ADD COLUMN IF NOT EXISTS exit_recorded_by integer,
    ADD COLUMN IF NOT EXISTS exit_recorded_at timestamptz;

COMMENT ON COLUMN core.students.date_of_leaving IS
    'Last day at this school. Printed on the TC, so it is set once at exit.';


-- ── money when a student leaves / comes back ───────────────────────────────
-- Depends on student_money_lifecycle.sql (fn_student_close_future_dues,
-- fn_student_restore_closed_dues and the close columns).
--
-- Leaving: every instalment due AFTER the leaving date is CLOSED (never
-- deleted) with the reason 'Left on <date>', who and when, and the bus
-- assignment ends. Dues up to the leaving date stay owed. Before this, tuition
-- and bus fees for every month to March stayed on a leaver's ledger, and the TC
-- was refused for months the child never attended.
--
-- Coming back (Reactivate): exactly what the exit closed is put back — the rows
-- closed with close_source 'Exit' and the bus assignment ended by it.
CREATE OR REPLACE FUNCTION core.fn_student_leave_money(
    p_tenant_id      integer,
    p_school_id      integer,
    p_student_id     integer,
    p_date_of_leaving date,
    p_action_user_id integer)
RETURNS numeric
LANGUAGE plpgsql
AS $$
DECLARE
    v_reason varchar(200) := 'Left on ' || to_char(p_date_of_leaving, 'YYYY-MM-DD');
    v_closed numeric(12,2);
BEGIN
    v_closed := core.fn_student_close_future_dues(
        p_tenant_id, p_school_id, p_student_id, p_date_of_leaving,
        v_reason, 'Exit', p_action_user_id);

    -- A refundable deposit (caution money) still unpaid is not owed by someone who
    -- is leaving: it would only be collected to be handed back. Close it as well.
    SELECT v_closed + COALESCE(SUM(core.fn_ledger_close(l.ledger_id, v_reason, 'Exit', p_action_user_id)), 0)
      INTO v_closed
      FROM core.student_ledger l
      JOIN core.school_fee_heads h ON h.fee_head_id = l.fee_head_id AND COALESCE(h.is_refundable, FALSE)
     WHERE l.student_id = p_student_id AND l.tenant_id = p_tenant_id AND l.school_id = p_school_id
       AND l.amount_due - l.amount_paid - l.concession > 0;

    UPDATE core.student_transport
       SET is_active  = FALSE,
           end_reason = v_reason,
           ended_by   = p_action_user_id,
           ended_at   = now(),
           updated_by = p_action_user_id,
           updated_at = now()
     WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
       AND is_active = TRUE;

    RETURN v_closed;
END;
$$;

CREATE OR REPLACE FUNCTION core.fn_student_return_money(
    p_tenant_id      integer,
    p_school_id      integer,
    p_student_id     integer,
    p_action_user_id integer)
RETURNS numeric
LANGUAGE plpgsql
AS $$
DECLARE
    v_restored numeric(12,2);
    v_assign   integer;
BEGIN
    -- Put back only the fees from this month on: the months the child was away
    -- are not billed again (re-admitted in January after leaving in July).
    SELECT COALESCE(SUM(core.fn_ledger_reopen(l.ledger_id)), 0) INTO v_restored
      FROM core.student_ledger l
     WHERE l.student_id = p_student_id AND l.tenant_id = p_tenant_id AND l.school_id = p_school_id
       AND l.close_source = 'Exit' AND l.closed_amount > 0
       AND (l.due_date IS NULL OR l.due_date::date >= date_trunc('month', CURRENT_DATE)::date)
       -- no bus fees come back when the school's Transport module is off
       AND (l.fee_head_name <> 'Transport Fee' OR core.fn_module_on(p_tenant_id, p_school_id, 'transport'));

    -- The bus assignment the exit ended (the latest one), if it was not
    -- replaced by another since.
    SELECT assignment_id INTO v_assign
      FROM core.student_transport
     WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
       AND is_active = FALSE AND COALESCE(is_deleted, FALSE) = FALSE
       AND end_reason LIKE 'Left on %'
     ORDER BY assignment_id DESC
     LIMIT 1;

    IF v_assign IS NOT NULL AND core.fn_module_on(p_tenant_id, p_school_id, 'transport') AND NOT EXISTS (
        SELECT 1 FROM core.student_transport
         WHERE student_id = p_student_id AND is_active = TRUE) THEN
        UPDATE core.student_transport
           SET is_active  = TRUE,
               end_reason = NULL, ended_by = NULL, ended_at = NULL,
               updated_by = p_action_user_id, updated_at = now()
         WHERE assignment_id = v_assign;
    END IF;

    RETURN v_restored;
END;
$$;


-- ── mark / unmark a student as left ────────────────────────────────────────
CREATE OR REPLACE PROCEDURE core.sp_student_exit(
    IN  p_operation      varchar,    -- 'Exit' | 'Undo'
    IN  p_tenant_id      integer,
    IN  p_school_id      integer,
    IN  p_action_user_id integer,
    IN  p_student_id     integer,
    IN  p_status         varchar DEFAULT NULL,  -- Transfer | Passout | Struck Off | Withdrawn
    IN  p_date_of_leaving date   DEFAULT NULL,
    IN  p_reason         varchar DEFAULT NULL,
    INOUT p_result       refcursor DEFAULT 'student_exit_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_name   varchar;
    v_active boolean;
    v_year   varchar;   -- session the student is sitting in (for the enrolment row)
    v_dues   numeric(12,2);
    v_closed numeric(12,2);
    v_prepaid numeric(12,2);   -- already paid for months after the leaving date
    v_current varchar;         -- the school's current session
    v_roll   varchar;
    s        core.students%ROWTYPE;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    SELECT * INTO s
    FROM core.students
    WHERE student_id = p_student_id
      AND tenant_id  = p_tenant_id
      AND school_id  = p_school_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Student not found.';
    END IF;
    v_name := s.student_name; v_active := s.is_active; v_year := s.academic_year;

    IF p_operation = 'Exit' THEN
        IF NOT v_active THEN
            RAISE EXCEPTION '% has already left.', v_name;
        END IF;

        IF COALESCE(TRIM(p_status), '') NOT IN ('Transfer', 'Passout', 'Struck Off', 'Withdrawn') THEN
            RAISE EXCEPTION 'Choose how the student left.';
        END IF;

        IF p_date_of_leaving IS NULL THEN
            RAISE EXCEPTION 'Date of leaving is required.';
        END IF;
        -- A future date made the child disappear from homework, exams and ID cards
        -- while still coming to school. Mark them as left on the day they leave.
        IF p_date_of_leaving > CURRENT_DATE THEN
            RAISE EXCEPTION 'The date of leaving cannot be in the future. Mark % as left on the day they leave.', v_name;
        END IF;
        IF s.admission_date IS NOT NULL AND p_date_of_leaving < s.admission_date::date THEN
            RAISE EXCEPTION 'The date of leaving cannot be before the admission date (%).', to_char(s.admission_date::date, 'DD Mon YYYY');
        END IF;

        -- Fees already paid for months after leaving: not closed (they were paid),
        -- so the office is told how much, to refund it or keep it as the school decides.
        SELECT COALESCE(SUM(l.amount_paid), 0) INTO v_prepaid
          FROM core.student_ledger l
         WHERE l.student_id = p_student_id AND l.tenant_id = p_tenant_id AND l.school_id = p_school_id
           AND l.due_date IS NOT NULL AND l.due_date::date > p_date_of_leaving AND l.amount_paid > 0;

        -- Instalments after the leaving date are closed and the bus ends.
        v_closed := core.fn_student_leave_money(
            p_tenant_id, p_school_id, p_student_id, p_date_of_leaving, p_action_user_id);

        -- What is still owed (up to the leaving date) does NOT block the exit:
        -- the student has physically left either way. It is reported so the
        -- office can chase it, and the TC step checks it again.
        SELECT COALESCE(SUM(l.amount_due - l.amount_paid - COALESCE(l.concession, 0)), 0)
        INTO v_dues
        FROM core.student_ledger l
        WHERE l.student_id = p_student_id;

        UPDATE core.students
        SET status           = TRIM(p_status),
            is_active        = FALSE,
            date_of_leaving  = p_date_of_leaving,
            leaving_reason   = NULLIF(TRIM(p_reason), ''),
            exit_recorded_by = p_action_user_id,
            exit_recorded_at = now(),
            updated_by       = p_action_user_id,
            updated_at       = now()
        WHERE student_id = p_student_id;

        -- Close the session they were in. is_current stays TRUE: this is still
        -- their latest enrolment, it just ended early.
        PERFORM core.fn_student_enrolment_close(
            p_student_id, v_year,
            CASE WHEN TRIM(p_status) = 'Passout' THEN 'PassedOut' ELSE 'Left' END,
            p_action_user_id);

        INSERT INTO core.admission_audit (tenant_id, school_id, student_id, action, detail, action_by)
        VALUES (p_tenant_id, p_school_id, p_student_id, 'StudentExited',
                TRIM(p_status) || ' on ' || to_char(p_date_of_leaving, 'YYYY-MM-DD') ||
                COALESCE(' (' || NULLIF(TRIM(p_reason), '') || ')', '') ||
                '; ' || to_char(v_closed, 'FM99999990.00') || ' of later dues closed' ||
                '; ' || to_char(GREATEST(v_dues, 0), 'FM99999990.00') || ' still owed',
                p_action_user_id);

        OPEN p_result FOR
        SELECT TRUE AS success,
               v_name || ' marked as ' || TRIM(p_status) || '.' ||
               CASE WHEN v_closed > 0
                    THEN ' Rs ' || to_char(v_closed, 'FM99,99,99,990.00') || ' of fees due after the leaving date closed.'
                    ELSE '' END ||
               CASE WHEN v_prepaid > 0
                    THEN ' Rs ' || to_char(v_prepaid, 'FM99,99,99,990.00') || ' was already paid for months after leaving.'
                    ELSE '' END AS message,
               GREATEST(v_dues, 0) AS outstanding,
               v_closed AS closed_amount;

    ELSIF p_operation = 'Undo' THEN
        IF v_active THEN
            RAISE EXCEPTION '% is already an active student.', v_name;
        END IF;

        -- A live TC says the child has left. Void it first, so the register
        -- and the roll never disagree.
        IF EXISTS (SELECT 1 FROM core.tc_register
                    WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                      AND student_id = p_student_id AND is_void = FALSE) THEN
            RAISE EXCEPTION 'A Transfer Certificate has been issued for %. Void it before re-activating.', v_name;
        END IF;

        -- Re-admitting puts the child back in the session they left. Once that
        -- session is over they would land in last year's class with no fees for
        -- this year, so that is a new admission instead.
        SELECT y.academic_year_name INTO v_current
          FROM academic.academic_years y
         WHERE y.tenant_id = p_tenant_id AND y.school_id = p_school_id
           AND COALESCE(y.is_current, FALSE) AND NOT COALESCE(y.is_deleted, FALSE)
         LIMIT 1;
        IF v_current IS NOT NULL AND v_year IS DISTINCT FROM v_current THEN
            RAISE EXCEPTION '% left in %, which is not the current session (%). Admit them again for % instead.',
                v_name, COALESCE(v_year, 'an earlier session'), v_current, v_current;
        END IF;

        -- Their roll number may have been given to someone else meanwhile.
        v_roll := NULLIF(TRIM(COALESCE(s.roll_no, '')), '');
        IF v_roll IS NULL OR EXISTS (
               SELECT 1 FROM core.students o
                WHERE o.tenant_id = p_tenant_id AND o.school_id = p_school_id AND o.is_active
                  AND o.student_id <> p_student_id AND o.academic_year = v_year
                  AND o.class_name = s.class_name AND COALESCE(o.section, '') = COALESCE(s.section, '')
                  AND lower(TRIM(o.roll_no)) = lower(v_roll)) THEN
            SELECT (COALESCE(MAX(TRIM(o.roll_no)::int), 0) + 1)::text INTO v_roll
              FROM core.students o
             WHERE o.tenant_id = p_tenant_id AND o.school_id = p_school_id AND o.is_active
               AND o.student_id <> p_student_id AND o.academic_year = v_year
               AND o.class_name = s.class_name AND COALESCE(o.section, '') = COALESCE(s.section, '')
               AND TRIM(o.roll_no) ~ '^[0-9]{1,6}$';
        END IF;

        v_closed := core.fn_student_return_money(p_tenant_id, p_school_id, p_student_id, p_action_user_id);

        -- The exit details are cleared on the student row (they describe a
        -- leaving that no longer stands) but kept here, with the restore.
        INSERT INTO core.admission_audit (tenant_id, school_id, student_id, action, detail, action_by)
        VALUES (p_tenant_id, p_school_id, p_student_id, 'StudentReactivated',
                'Was ' || COALESCE(s.status, '?') || ' on ' || COALESCE(s.date_of_leaving::text, '?') ||
                COALESCE(' (' || s.leaving_reason || ')', '') ||
                ', recorded by user ' || COALESCE(s.exit_recorded_by::text, '?') ||
                ' at ' || COALESCE(LEFT(s.exit_recorded_at::text, 16), '?') ||
                '; ' || to_char(v_closed, 'FM99999990.00') || ' of dues restored',
                p_action_user_id);

        UPDATE core.students
        SET status           = 'Active',
            is_active        = TRUE,
            roll_no          = v_roll,
            date_of_leaving  = NULL,
            leaving_reason   = NULL,
            exit_recorded_by = NULL,
            exit_recorded_at = NULL,
            updated_by       = p_action_user_id,
            updated_at       = now()
        WHERE student_id = p_student_id;

        -- Put them back on the roll for the session they were in.
        PERFORM core.fn_student_enrolment_close(
            p_student_id, v_year, 'Active', p_action_user_id);

        OPEN p_result FOR
        SELECT TRUE AS success,
               v_name || ' re-activated.' ||
               CASE WHEN v_closed > 0
                    THEN ' Rs ' || to_char(v_closed, 'FM99,99,99,990.00') || ' of dues closed at exit restored.'
                    ELSE '' END AS message,
               0::numeric AS outstanding,
               v_closed AS closed_amount;
    ELSE
        RAISE EXCEPTION 'Unknown operation %.', p_operation;
    END IF;
END;
$procedure$;


-- ── the "Inactive / Left" list ─────────────────────────────────────────────
-- Same shape as sp_student_list: search + filters + whitelisted sort +
-- pagination, with window aggregates so the tiles stay right across pages.
CREATE OR REPLACE PROCEDURE core.sp_student_exit_list(
    IN  p_tenant_id      integer,
    IN  p_school_id      integer,
    IN  p_action_user_id integer,
    IN  p_search         text    DEFAULT NULL,
    IN  p_filter_status  text    DEFAULT NULL,   -- Transfer | Passout | Struck Off | Withdrawn
    IN  p_filter_dues    text    DEFAULT NULL,   -- 'pending' | 'clear'
    IN  p_page_no        integer DEFAULT 1,
    IN  p_page_size      integer DEFAULT 10,
    IN  p_sort_column    text    DEFAULT NULL,
    IN  p_sort_dir       text    DEFAULT 'desc',
    INOUT p_result       refcursor DEFAULT 'student_exit_list_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_offset integer;
    v_col    text;
    v_asc    boolean;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        OPEN p_result FOR SELECT WHERE FALSE;
        RETURN;
    END IF;

    v_offset := (GREATEST(COALESCE(p_page_no, 1), 1) - 1) * COALESCE(p_page_size, 10);
    v_col    := LOWER(TRIM(COALESCE(p_sort_column, '')));
    v_asc    := LOWER(TRIM(COALESCE(p_sort_dir, 'desc'))) <> 'desc';

    OPEN p_result FOR
        WITH filtered AS (
            SELECT
                s.student_id, s.admission_no, s.student_name,
                s.class_name, s.section, s.academic_year,
                s.guardian_name, s.mobile,
                s.admission_date, s.date_of_leaving,
                s.status, s.leaving_reason,
                -- The uuid opens the (read-only) Student Dashboard of a leaver;
                -- has_tc stops the page offering a second TC.
                s.public_id,
                EXISTS (SELECT 1 FROM core.tc_register t
                         WHERE t.student_id = s.student_id AND t.tenant_id = s.tenant_id
                           AND t.school_id = s.school_id AND NOT t.is_void) AS has_tc,
                COALESCE((
                    SELECT SUM(l.amount_due - l.amount_paid - COALESCE(l.concession, 0))
                    FROM core.student_ledger l
                    WHERE l.student_id = s.student_id
                ), 0) AS outstanding
            FROM core.students s
            WHERE s.tenant_id = p_tenant_id
              AND s.school_id = p_school_id
              AND s.is_active = FALSE
              -- strpos, not LIKE: a typed % or _ is a character, not a wildcard.
              AND (
                  p_search IS NULL OR TRIM(p_search) = ''
                  OR strpos(LOWER(s.student_name), LOWER(TRIM(p_search))) > 0
                  OR strpos(LOWER(s.admission_no), LOWER(TRIM(p_search))) > 0
                  OR strpos(COALESCE(s.mobile, ''), TRIM(p_search)) > 0
              )
              AND (p_filter_status IS NULL OR TRIM(p_filter_status) = ''
                   OR LOWER(s.status) = LOWER(TRIM(p_filter_status)))
        ),
        scored AS (
            SELECT * FROM filtered f
            WHERE p_filter_dues IS NULL OR TRIM(p_filter_dues) = ''
               OR (LOWER(TRIM(p_filter_dues)) = 'pending' AND f.outstanding > 0)
               OR (LOWER(TRIM(p_filter_dues)) = 'clear'   AND f.outstanding <= 0)
        )
        SELECT
            student_id, admission_no, student_name, class_name, section,
            academic_year, guardian_name, mobile, admission_date,
            date_of_leaving, status, leaving_reason, public_id, has_tc,
            GREATEST(outstanding, 0) AS outstanding,
            COUNT(*)                                                        OVER() AS total_count,
            COUNT(*) FILTER (WHERE status = 'Transfer')                     OVER() AS transfer_count,
            COUNT(*) FILTER (WHERE status = 'Passout')                      OVER() AS passout_count,
            COUNT(*) FILTER (WHERE outstanding > 0)                         OVER() AS dues_count
        FROM scored
        ORDER BY
            CASE WHEN v_col = 'name'  AND v_asc     THEN student_name    END ASC,
            CASE WHEN v_col = 'name'  AND NOT v_asc THEN student_name    END DESC,
            CASE WHEN v_col = 'left'  AND v_asc     THEN date_of_leaving END ASC,
            CASE WHEN v_col = 'left'  AND NOT v_asc THEN date_of_leaving END DESC,
            CASE WHEN v_col = 'dues'  AND v_asc     THEN outstanding     END ASC,
            CASE WHEN v_col = 'dues'  AND NOT v_asc THEN outstanding     END DESC,
            -- Default: most recently left first.
            date_of_leaving DESC NULLS LAST, student_id DESC
        LIMIT  COALESCE(p_page_size, 10)
        OFFSET v_offset;
    RETURN;
END;
$procedure$;

-- ============================================================================
-- Bulk student promotion — moving a class into the next academic session.
--
-- core.students holds ONE row per student: class_name, section and
-- academic_year live on that row, and there is no per-year enrolment table.
-- The unique (tenant_id, school_id, admission_no) constraint also forbids a
-- second row for the same student in a new year. So promotion is an in-place
-- UPDATE of the student row, exactly like the exit flow: the student_id never
-- changes, so the fee ledger, receipts and TC register keep pointing at it.
--
-- History is kept separately in core.student_promotion_history, because the
-- student row itself remembers nothing about the class it came from.
--
--   core.student_promotion_history  one row per student per promotion run
--   core.sp_class_ladder            classes in real teaching order
--   core.sp_student_promote         the promotion itself
--
-- outcome values:
--   Promote   moved up to the next class in the ladder, new session
--   Retain    stays in the same class, new session
--   PassOut   completed the final class -> inactive, TC-eligible
--
-- PREREQUISITE: the target session must already have its classes and sections
-- (see academic_session_rollover.sql). Classes are per-session rows, so a new
-- session is empty until the structure is copied forward, and promoting into an
-- empty session would write students onto classes that do not exist.
--
-- MONEY: Promote / Retain bill the target class's recurring fee structure for
-- the new session (once per student per session) and re-bill a kept bus route;
-- PassOut closes later dues like an exit. Depends on student_money_lifecycle.sql,
-- transport_module.sql and student_exit.sql -- apply those first.
-- ============================================================================

-- ── history ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS core.student_promotion_history (
    promotion_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     integer      NOT NULL,
    school_id     integer      NOT NULL,
    student_id    integer      NOT NULL REFERENCES core.students(student_id) ON DELETE CASCADE,
    from_year     varchar(20)  NOT NULL,
    from_class    varchar(50)  NOT NULL,
    from_section  varchar(20),
    to_year       varchar(20)  NOT NULL,
    to_class      varchar(50),
    to_section    varchar(20),
    outcome       varchar(20)  NOT NULL,
    dues_carried  numeric(12,2) NOT NULL DEFAULT 0,
    promoted_by   integer      NOT NULL DEFAULT 0,
    promoted_at   timestamptz  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_student_promotion_history_student
    ON core.student_promotion_history (student_id);
CREATE INDEX IF NOT EXISTS idx_student_promotion_history_year
    ON core.student_promotion_history (tenant_id, school_id, to_year);

COMMENT ON TABLE core.student_promotion_history IS
    'Audit trail of promotions. The student row is updated in place, so this is the only record of which class a student came from.';
COMMENT ON COLUMN core.student_promotion_history.dues_carried IS
    'Outstanding balance at the moment of promotion. The ledger is not year-scoped, so the dues simply follow the student; this is the snapshot.';


-- ── the class ladder ───────────────────────────────────────────────────────
-- config.sp_dropdown_common returns classes newest-id-first, which is NOT
-- teaching order — using it to work out "the next class" walks DOWN the
-- school. display_order is the column meant for this, so promotion (and the
-- page's "next class" preview) reads the ladder from here instead.
--
-- Classes are per-session rows, so the ladder MUST be scoped to one session.
-- Unscoped it returns every session's classes concatenated, which reads as
-- "1st, 1st, 2nd, 2nd, ..." the moment a second session has structure.
-- p_academic_year_name is optional; NULL means the current session.
DROP PROCEDURE IF EXISTS core.sp_class_ladder(integer, integer, integer, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_class_ladder(
    IN  p_tenant_id         integer,
    IN  p_school_id         integer,
    IN  p_action_user_id    integer,
    IN  p_academic_year_name character varying DEFAULT NULL,
    INOUT p_result          refcursor DEFAULT 'class_ladder_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_year varchar := NULLIF(TRIM(COALESCE(p_academic_year_name, '')), '');
    v_year_id integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        OPEN p_result FOR SELECT WHERE FALSE;
        RETURN;
    END IF;

    SELECT academic_year_id INTO v_year_id
    FROM   academic.academic_years
    WHERE  tenant_id = p_tenant_id
      AND  school_id = p_school_id
      AND  COALESCE(is_deleted, FALSE) = FALSE
      AND  (   (v_year IS NOT NULL AND academic_year_name = v_year)
            OR (v_year IS NULL     AND COALESCE(is_current, FALSE) = TRUE))
    LIMIT 1;

    IF v_year_id IS NULL THEN
        OPEN p_result FOR SELECT WHERE FALSE;
        RETURN;
    END IF;

    -- display_order comes back too: the Promotion page needs it to work out the
    -- next class exactly the way this proc's caller does (order from the SOURCE
    -- session, then the first higher class in the TARGET). Names alone are not
    -- enough once the two sessions hold different classes. Additive column —
    -- existing consumers read by name, so they are unaffected.
    OPEN p_result FOR
    SELECT class_name, display_order
    FROM academic.academic_classes
    WHERE tenant_id = p_tenant_id
      AND school_id = p_school_id
      AND academic_year_id = v_year_id
      AND COALESCE(is_deleted, FALSE) = FALSE
      AND COALESCE(is_active,  TRUE)  = TRUE
    ORDER BY display_order, academic_class_id;
    RETURN;
END;
$procedure$;


-- ── promote ────────────────────────────────────────────────────────────────
-- p_students is [{"studentId":1,"outcome":"promote"}, ...]. The target class
-- is NOT taken from the browser: it is derived here from the ladder above, so
-- a stale page cannot write the wrong class.
--
-- A student who cannot be promoted is skipped and reported, not fatal — one
-- student on a stale page should not roll back the whole class.
CREATE OR REPLACE PROCEDURE core.sp_student_promote(
    IN  p_tenant_id      integer,
    IN  p_school_id      integer,
    IN  p_action_user_id integer,
    IN  p_source_year    varchar,
    IN  p_target_year    varchar,
    IN  p_target_section varchar DEFAULT NULL,   -- NULL / 'keep' = keep the student's section
    IN  p_carry_dues     boolean DEFAULT TRUE,
    IN  p_students       jsonb   DEFAULT '[]'::jsonb,
    INOUT p_result       refcursor DEFAULT 'student_promote_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    r             record;
    v_src         varchar := TRIM(COALESCE(p_source_year, ''));
    v_tgt         varchar := TRIM(COALESCE(p_target_year, ''));
    v_sec         varchar := NULLIF(TRIM(COALESCE(p_target_section, '')), '');
    v_src_year_id integer;
    v_tgt_year_id integer;
    v_tgt_classes integer := 0;
    v_cur_order   integer;
    v_pick_order  integer;   -- display_order of an explicitly chosen target class
    v_outcome     varchar;
    v_next        varchar;
    v_to_class    varchar;
    v_to_section  varchar;
    v_dues        numeric(12,2);
    v_promoted    integer := 0;
    v_retained    integer := 0;
    v_passed      integer := 0;
    v_skipped     text[]  := '{}';
    v_tgt_start   date;
    v_plan        jsonb;
    v_billed      integer := 0;
    v_roll        varchar;   -- the roll number in the new class (see below)
    v_unbilled    text[]  := '{}';
    v_route       integer;
    v_stop        integer;
    v_bus         refcursor;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    IF v_src = '' OR v_tgt = '' THEN
        RAISE EXCEPTION 'Choose both the current and the new academic session.';
    END IF;

    IF LOWER(v_src) = LOWER(v_tgt) THEN
        RAISE EXCEPTION 'The new session must be different from the current session.';
    END IF;

    SELECT academic_year_id, start_date::date INTO v_tgt_year_id, v_tgt_start
    FROM   academic.academic_years
    WHERE  tenant_id = p_tenant_id
      AND  school_id = p_school_id
      AND  academic_year_name = v_tgt
      AND  COALESCE(is_deleted, FALSE) = FALSE
      AND  COALESCE(is_active,  TRUE)  = TRUE;

    IF v_tgt_year_id IS NULL THEN
        RAISE EXCEPTION 'Academic session % is not set up for this school.', v_tgt;
    END IF;

    -- The session EXISTING is not enough. Classes and sections are per-session
    -- rows, so a freshly created session is empty, and promoting into it writes
    -- students into a class that does not exist anywhere in the setup — they
    -- then vanish from every class-filtered page. Stop before that happens.
    SELECT COUNT(*) INTO v_tgt_classes
    FROM   academic.academic_classes
    WHERE  tenant_id = p_tenant_id
      AND  school_id = p_school_id
      AND  academic_year_id = v_tgt_year_id
      AND  COALESCE(is_deleted, FALSE) = FALSE
      AND  COALESCE(is_active,  TRUE)  = TRUE;

    IF v_tgt_classes = 0 THEN
        RAISE EXCEPTION 'Session % has no classes or sections yet. Open Settings > Classes & Sections, pick %, and copy the structure from the previous session before promoting.', v_tgt, v_tgt;
    END IF;

    -- Optional: used only to read the student's current position on the ladder.
    SELECT academic_year_id INTO v_src_year_id
    FROM   academic.academic_years
    WHERE  tenant_id = p_tenant_id
      AND  school_id = p_school_id
      AND  academic_year_name = v_src
      AND  COALESCE(is_deleted, FALSE) = FALSE;

    IF p_students IS NULL OR jsonb_array_length(p_students) = 0 THEN
        RAISE EXCEPTION 'No students were selected.';
    END IF;

    -- 'keep' is the page's own token for "leave the section alone".
    IF v_sec IS NOT NULL AND LOWER(v_sec) = 'keep' THEN
        v_sec := NULL;
    END IF;

    FOR r IN
        -- Column names are quoted so they match the camelCase JSON keys exactly —
        -- unquoted identifiers fold to lowercase and would never match "studentId".
        SELECT x."studentId"                             AS student_id,
               LOWER(TRIM(COALESCE(x.outcome, '')))       AS outcome,
               NULLIF(TRIM(COALESCE(x."toClass", '')), '') AS to_class
        FROM jsonb_to_recordset(p_students) AS x("studentId" integer, outcome text, "toClass" text)
    LOOP
        DECLARE
            s core.students%ROWTYPE;
        BEGIN
            SELECT * INTO s
            FROM core.students
            WHERE student_id = r.student_id
              AND tenant_id  = p_tenant_id
              AND school_id  = p_school_id
            FOR UPDATE;

            IF NOT FOUND THEN
                v_skipped := v_skipped || ('#' || COALESCE(r.student_id::text, '?') || ' (not found)');
                CONTINUE;
            END IF;

            IF NOT s.is_active THEN
                v_skipped := v_skipped || (s.student_name || ' (already left)');
                CONTINUE;
            END IF;

            -- Guards a double submit: after a successful run the student sits
            -- on the target year, so a repeat finds nothing to move.
            IF TRIM(COALESCE(s.academic_year, '')) <> v_src THEN
                v_skipped := v_skipped || (s.student_name || ' (not in ' || v_src || ')');
                CONTINUE;
            END IF;

            v_outcome := CASE r.outcome
                            WHEN 'promote' THEN 'Promote'
                            WHEN 'retain'  THEN 'Retain'
                            WHEN 'passout' THEN 'PassOut'
                            ELSE NULL
                         END;
            IF v_outcome IS NULL THEN
                v_skipped := v_skipped || (s.student_name || ' (unknown outcome)');
                CONTINUE;
            END IF;

            SELECT COALESCE(SUM(l.amount_due - l.amount_paid - COALESCE(l.concession, 0)), 0)
            INTO v_dues
            FROM core.student_ledger l
            WHERE l.student_id = s.student_id;
            v_dues := GREATEST(v_dues, 0);

            -- The ledger is not year-scoped, so dues follow the student no
            -- matter what. Unticking the box therefore means "do not take the
            -- dues into the new session" -> those students must settle first.
            IF NOT p_carry_dues AND v_dues > 0 AND v_outcome <> 'PassOut' THEN
                v_skipped := v_skipped || (s.student_name || ' (pending dues)');
                CONTINUE;
            END IF;

            -- 1. Work out where the student is going.
            IF v_outcome = 'Promote' THEN
                -- The student's rung on the ladder, read from the session they
                -- are leaving; fall back to the new session in case the old one
                -- was edited after they were admitted.
                SELECT display_order INTO v_cur_order
                FROM   academic.academic_classes
                WHERE  tenant_id = p_tenant_id
                  AND  school_id = p_school_id
                  AND  academic_year_id = COALESCE(v_src_year_id, v_tgt_year_id)
                  AND  class_name = s.class_name
                  AND  COALESCE(is_deleted, FALSE) = FALSE
                ORDER BY display_order, academic_class_id
                LIMIT 1;

                IF v_cur_order IS NULL THEN
                    SELECT display_order INTO v_cur_order
                    FROM   academic.academic_classes
                    WHERE  tenant_id = p_tenant_id
                      AND  school_id = p_school_id
                      AND  academic_year_id = v_tgt_year_id
                      AND  class_name = s.class_name
                      AND  COALESCE(is_deleted, FALSE) = FALSE
                    ORDER BY display_order, academic_class_id
                    LIMIT 1;
                END IF;

                IF v_cur_order IS NULL THEN
                    v_skipped := v_skipped || (s.student_name || ' (class ' || s.class_name || ' is not in the session setup)');
                    CONTINUE;
                END IF;

                IF r.to_class IS NOT NULL THEN
                    -- The office asked for a specific class (a double promotion,
                    -- 1st -> 3rd). Still has to be a real class in the TARGET
                    -- session, and still has to be ABOVE where they are now: this
                    -- operation only ever moves students up. Moving someone down
                    -- is a correction, and belongs on the student's own page where
                    -- it is one deliberate act rather than a bulk one.
                    SELECT display_order INTO v_pick_order
                    FROM   academic.academic_classes
                    WHERE  tenant_id = p_tenant_id
                      AND  school_id = p_school_id
                      AND  academic_year_id = v_tgt_year_id
                      AND  class_name = r.to_class
                      AND  COALESCE(is_deleted, FALSE) = FALSE
                      AND  COALESCE(is_active,  TRUE)  = TRUE
                    ORDER BY display_order, academic_class_id
                    LIMIT 1;

                    IF v_pick_order IS NULL THEN
                        v_skipped := v_skipped ||
                            (s.student_name || ' (chosen class ' || r.to_class || ' is not set up in ' || v_tgt || ')');
                        CONTINUE;
                    END IF;

                    IF v_pick_order <= v_cur_order THEN
                        v_skipped := v_skipped ||
                            (s.student_name || ' (' || r.to_class || ' is not above ' || s.class_name || ')');
                        CONTINUE;
                    END IF;

                    v_next := r.to_class;
                ELSE
                    -- Default: the next rung up. Read from the TARGET session, so a
                    -- student can only ever be moved into a class that exists there.
                    SELECT class_name INTO v_next
                    FROM   academic.academic_classes
                    WHERE  tenant_id = p_tenant_id
                      AND  school_id = p_school_id
                      AND  academic_year_id = v_tgt_year_id
                      AND  COALESCE(is_deleted, FALSE) = FALSE
                      AND  COALESCE(is_active,  TRUE)  = TRUE
                      AND  display_order > v_cur_order
                    ORDER BY display_order, academic_class_id
                    LIMIT 1;
                END IF;

                IF v_next IS NULL THEN
                    v_skipped := v_skipped || (s.student_name || ' (already in the final class — mark Pass Out)');
                    CONTINUE;
                END IF;

                v_to_class := v_next;

            ELSIF v_outcome = 'Retain' THEN
                v_to_class := s.class_name;

            ELSE
                v_to_class := NULL;   -- PassOut leaves the school; no class needed
            END IF;

            -- 2. A student may only land on a class + section that really exists
            --    in the target session. Carrying the old section forward blindly
            --    is how students used to end up in a section their new class has
            --    never had (1st-C -> 2nd-C, where 2nd only ever had A and B).
            IF v_outcome <> 'PassOut' THEN
                v_to_section := COALESCE(v_sec, s.section);

                IF NOT EXISTS (
                    SELECT 1
                    FROM   academic.academic_classes ac
                    WHERE  ac.tenant_id = p_tenant_id
                      AND  ac.school_id = p_school_id
                      AND  ac.academic_year_id = v_tgt_year_id
                      AND  ac.class_name = v_to_class
                      AND  COALESCE(ac.is_deleted, FALSE) = FALSE
                      AND  COALESCE(ac.is_active,  TRUE)  = TRUE
                ) THEN
                    v_skipped := v_skipped || (s.student_name || ' (' || v_to_class || ' is not set up in ' || v_tgt || ')');
                    CONTINUE;
                END IF;

                IF v_to_section IS NULL OR NOT EXISTS (
                    SELECT 1
                    FROM   academic.academic_class_sections acs
                    JOIN   academic.academic_classes ac
                           ON ac.academic_class_id = acs.academic_class_id
                    WHERE  ac.tenant_id = p_tenant_id
                      AND  ac.school_id = p_school_id
                      AND  ac.academic_year_id = v_tgt_year_id
                      AND  ac.class_name   = v_to_class
                      AND  acs.section_name = v_to_section
                      AND  COALESCE(ac.is_deleted,  FALSE) = FALSE
                      AND  COALESCE(acs.is_deleted, FALSE) = FALSE
                      AND  COALESCE(acs.is_active,  TRUE)  = TRUE
                ) THEN
                    v_skipped := v_skipped ||
                        (s.student_name || ' (section ' || COALESCE(v_to_section, '—') ||
                         ' does not exist in ' || v_to_class || ' for ' || v_tgt || ')');
                    CONTINUE;
                END IF;
            ELSE
                v_to_section := NULL;
            END IF;

            -- 3. Commit the move.
            --
            --    Two records are kept in step here: core.students carries the
            --    student's PRESENT position (overwritten), and
            --    core.student_enrolment gains a row per session so the position
            --    they are leaving is not lost. See student_enrolment.sql.
            -- Roll number in the new class: keep it, unless the student has none or
            -- someone already in that class-section uses it -- then the next free
            -- number (highest + 1). Renumbering a whole class is Students › Data Checks.
            v_roll := NULLIF(TRIM(COALESCE(s.roll_no, '')), '');
            IF v_outcome IN ('Promote', 'Retain') AND (v_roll IS NULL OR EXISTS (
                   SELECT 1 FROM core.students o
                    WHERE o.tenant_id = p_tenant_id AND o.school_id = p_school_id AND o.is_active
                      AND o.student_id <> s.student_id AND o.academic_year = v_tgt
                      AND o.class_name = v_to_class AND COALESCE(o.section, '') = COALESCE(v_to_section, '')
                      AND lower(TRIM(o.roll_no)) = lower(v_roll))) THEN
                -- counts those already moved in AND classmates of this run still to come,
                -- so a missing roll goes after everyone else's instead of taking roll 1
                SELECT (COALESCE(MAX(TRIM(x.roll_no)::int), 0) + 1)::text INTO v_roll
                  FROM (SELECT o.roll_no FROM core.students o
                         WHERE o.tenant_id = p_tenant_id AND o.school_id = p_school_id AND o.is_active
                           AND o.student_id <> s.student_id AND o.academic_year = v_tgt
                           AND o.class_name = v_to_class AND COALESCE(o.section, '') = COALESCE(v_to_section, '')
                        UNION ALL
                        SELECT o.roll_no FROM core.students o
                         WHERE o.student_id IN (SELECT (j->>'studentId')::int FROM jsonb_array_elements(p_students) j)
                           AND o.student_id <> s.student_id AND o.academic_year = s.academic_year
                           AND o.class_name = s.class_name AND COALESCE(o.section, '') = COALESCE(s.section, '')) x
                 WHERE TRIM(x.roll_no) ~ '^[0-9]{1,6}$';
            END IF;

            IF v_outcome = 'Promote' THEN
                UPDATE core.students
                SET class_name    = v_to_class,
                    roll_no       = v_roll,
                    section       = v_to_section,
                    academic_year = v_tgt,
                    updated_by    = p_action_user_id,
                    updated_at    = now()
                WHERE student_id = s.student_id;

                PERFORM core.fn_student_enrolment_close(
                    s.student_id, s.academic_year, 'Promoted', p_action_user_id);
                PERFORM core.fn_student_enrolment_open(
                    p_tenant_id, p_school_id, s.student_id,
                    v_tgt, v_to_class, v_to_section, v_roll, p_action_user_id);

                v_promoted := v_promoted + 1;

            ELSIF v_outcome = 'Retain' THEN
                UPDATE core.students
                SET section       = v_to_section,
                    roll_no       = v_roll,
                    academic_year = v_tgt,
                    updated_by    = p_action_user_id,
                    updated_at    = now()
                WHERE student_id = s.student_id;

                PERFORM core.fn_student_enrolment_close(
                    s.student_id, s.academic_year, 'Retained', p_action_user_id);
                PERFORM core.fn_student_enrolment_open(
                    p_tenant_id, p_school_id, s.student_id,
                    v_tgt, v_to_class, v_to_section, v_roll, p_action_user_id);

                v_retained := v_retained + 1;

            ELSE  -- PassOut: same shape as sp_student_exit, so they show up in
                  -- the Inactive list and stay eligible for a TC.
                UPDATE core.students
                SET status           = 'Passout',
                    is_active        = FALSE,
                    date_of_leaving  = CURRENT_DATE,
                    exit_recorded_by = p_action_user_id,
                    exit_recorded_at = now(),
                    updated_by       = p_action_user_id,
                    updated_at       = now()
                WHERE student_id = s.student_id;

                -- No new session opens; the last one just ends.
                PERFORM core.fn_student_enrolment_close(
                    s.student_id, s.academic_year, 'PassedOut', p_action_user_id);

                -- Same money rule as a manual exit: anything due after today
                -- is closed with a reason and the bus ends.
                PERFORM core.fn_student_leave_money(
                    p_tenant_id, p_school_id, s.student_id, CURRENT_DATE, p_action_user_id);

                v_passed := v_passed + 1;
            END IF;

            -- 4. Bill the new session (Promote and Retain).
            --
            --    The class's recurring fee structure for the TARGET session is
            --    billed exactly the way admission bills a plan
            --    (core.fn_student_bill_plan), from the session start. The
            --    admission fee and deposit are not charged again. Billing is
            --    once per student per session, so a repeated run never adds a
            --    second plan. Before this, promotion created no dues at all
            --    for the new year. Old unpaid dues are untouched: they carry.
            IF v_outcome IN ('Promote', 'Retain') THEN
                v_plan := core.fn_class_fee_plan(p_tenant_id, p_school_id, v_to_class, v_tgt);
                IF v_plan IS NULL THEN
                    v_unbilled := v_unbilled || (s.student_name || ' (' || v_to_class || ')');
                ELSIF core.fn_student_bill_plan(p_tenant_id, p_school_id, p_action_user_id,
                          s.student_id, v_tgt, COALESCE(v_tgt_start, CURRENT_DATE), v_plan) > 0 THEN
                    v_billed := v_billed + 1;
                END IF;

                -- A student who keeps a bus route is billed for it in the new
                -- session too, at the stop's current fare.
                v_route := NULL;
                SELECT route_id, stop_id INTO v_route, v_stop
                FROM core.student_transport
                WHERE student_id = s.student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
                  AND is_active = TRUE AND COALESCE(is_deleted, FALSE) = FALSE
                ORDER BY assignment_id DESC
                LIMIT 1;

                -- (not when the school's Transport module is off)
                IF v_route IS NOT NULL AND core.fn_module_on(p_tenant_id, p_school_id, 'transport') THEN
                    v_bus := 'promote_bus_' || s.student_id;
                    CALL core.sp_transport_assign_manage('SaveAssignment', p_tenant_id, p_school_id,
                         p_action_user_id, s.student_id, v_route, v_stop, v_tgt,
                         COALESCE(v_tgt_start, CURRENT_DATE), 12, v_bus);
                    CLOSE v_bus;
                END IF;
            END IF;

            INSERT INTO core.student_promotion_history (
                tenant_id, school_id, student_id,
                from_year, from_class, from_section,
                to_year, to_class, to_section,
                outcome, dues_carried, promoted_by)
            VALUES (
                p_tenant_id, p_school_id, s.student_id,
                s.academic_year, s.class_name, s.section,
                CASE WHEN v_outcome = 'PassOut' THEN s.academic_year ELSE v_tgt END,
                v_to_class, v_to_section,
                v_outcome, v_dues, p_action_user_id);
        END;
    END LOOP;

    IF v_promoted + v_retained + v_passed = 0 THEN
        RAISE EXCEPTION 'Nothing was promoted. %',
            COALESCE(NULLIF(array_to_string(v_skipped, '; '), ''), 'No matching students in ' || v_src || '.');
    END IF;

    OPEN p_result FOR
    SELECT TRUE                                   AS success,
           v_promoted                             AS promoted,
           v_retained                             AS retained,
           v_passed                               AS passed_out,
           COALESCE(array_length(v_skipped, 1), 0) AS skipped,
           array_to_string(v_skipped, '; ')       AS skipped_detail,
           v_promoted || ' promoted, ' || v_retained || ' retained, ' ||
           v_passed   || ' passed out. ' ||
           v_billed   || ' billed for ' || v_tgt || '.' ||
           CASE WHEN array_length(v_unbilled, 1) > 0
                THEN ' Not billed — no fee structure for ' || v_tgt || ': ' ||
                     array_to_string(v_unbilled, ', ') || '.'
                ELSE '' END                       AS message,
           v_billed                               AS billed;
    RETURN;
END;
$procedure$;

-- ============================================================================
-- Transport: live bus tracking
--
-- WHERE THE POSITION COMES FROM
-- The driver's own phone. A driver is a staff row (core.staff) with a login
-- (staff.user_id) who is the assigned driver of a vehicle
-- (core.transport_vehicles.driver_staff_id). The "My Bus" page in the browser
-- starts a trip and posts the phone's GPS position about every 15 seconds.
-- No other permission is needed: being the vehicle's driver IS the permission,
-- and every write below checks it again.
--
-- TABLES
--   core.transport_trips        one row per trip. The latest point is copied onto
--                               the trip row (last_lat, last_lng, ...) so the live
--                               map reads one row per running bus, never a
--                               "latest point per trip" scan over the points.
--   core.transport_trip_points  every accepted GPS point of a trip.
--   core.transport_route_shares parent share links, one live link per route. Only
--                               the sha256 of the token is stored (hex); the raw
--                               token is shown once and can be regenerated.
--
-- RULES
--   * One running trip per vehicle (unique partial index). Starting again while
--     a fresh trip runs resumes it; a stale trip is closed first.
--   * A trip with no point for 30 minutes is STALE and is closed (end_reason
--     'Stale') by fn_transport_close_stale_trips, which every read and write
--     below calls first. Staleness is measured on the SERVER's receive time,
--     so a phone with a wrong clock cannot keep a trip alive or kill it.
--   * Points: lat/lng in range and not (0,0), accuracy 0..2000 m, no timestamp
--     more than 2 minutes in the future or before the trip started, and a point
--     less than 5 s after the previous one is DROPPED (not an error).
--   * 30-DAY HISTORY: StartTrip deletes points older than 30 days and ended trips
--     that started more than 30 days ago, for every school. It is one indexed
--     DELETE, cheap enough to run at the start of each trip, so no scheduler
--     or cron job is needed. Nothing older than 30 days is ever read.
--
-- PROCS
--   core.fn_transport_close_stale_trips(tenant, school)
--   core.sp_transport_trip_manage      driver: MyBus, IsDriver, StartTrip, EndTrip, AddPoint
--   core.sp_transport_tracking_manage  staff : LiveList, TripHistory, TripPoints,
--                                              ShareList, ShareCreate, ShareRevoke
--   core.sp_transport_track_public     parent page: token hash -> that route's bus
--
-- Timestamps are timestamptz; text sent to the app is formatted in the session
-- time zone, which is the school's (school_timezone.sql sets Asia/Kolkata).
--
-- Target DB: PostgreSQL (educore). Safe to re-run. No inner BEGIN/COMMIT.
-- school_purge.sql deletes these three tables; apply it after this script.
-- ============================================================================

-- ── Tables ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS core.transport_trips
(
    trip_id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id        integer NOT NULL,
    school_id        integer NOT NULL,
    vehicle_id       integer NOT NULL REFERENCES core.transport_vehicles(vehicle_id) ON DELETE CASCADE,
    route_id         integer REFERENCES core.transport_routes(route_id) ON DELETE SET NULL,
    driver_staff_id  integer REFERENCES core.staff(staff_id) ON DELETE SET NULL,
    -- Snapshots, so history still reads right after a bus or route is renamed.
    vehicle_no       varchar(40),
    route_name       varchar(80),
    driver_name      varchar(150),
    started_by       integer,
    started_at       timestamptz NOT NULL DEFAULT now(),
    ended_at         timestamptz,
    end_reason       varchar(20),             -- Driver | Stale
    -- The latest accepted point (recorded_at = phone time, received_at = server time).
    last_lat         numeric(9,6),
    last_lng         numeric(9,6),
    last_accuracy_m  numeric(8,1),
    last_speed_mps   numeric(6,2),
    last_heading_deg numeric(5,1),
    last_recorded_at timestamptz,
    last_received_at timestamptz,
    point_count      integer NOT NULL DEFAULT 0,
    CONSTRAINT chk_transport_trips_scope CHECK ((tenant_id > 1) AND (school_id > 0))
);

-- One running trip per vehicle.
CREATE UNIQUE INDEX IF NOT EXISTS ux_transport_trips_running
    ON core.transport_trips(vehicle_id) WHERE ended_at IS NULL;
-- Live map: the running trips of one school.
CREATE INDEX IF NOT EXISTS ix_transport_trips_school_running
    ON core.transport_trips(tenant_id, school_id) WHERE ended_at IS NULL;
-- History list, newest first, and the 30-day purge of old trips.
CREATE INDEX IF NOT EXISTS ix_transport_trips_school_started
    ON core.transport_trips(tenant_id, school_id, started_at DESC);
CREATE INDEX IF NOT EXISTS ix_transport_trips_started
    ON core.transport_trips(started_at);

CREATE TABLE IF NOT EXISTS core.transport_trip_points
(
    point_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id    integer NOT NULL,
    school_id    integer NOT NULL,
    trip_id      integer NOT NULL REFERENCES core.transport_trips(trip_id) ON DELETE CASCADE,
    lat          numeric(9,6) NOT NULL,
    lng          numeric(9,6) NOT NULL,
    accuracy_m   numeric(8,1),
    speed_mps    numeric(6,2),
    heading_deg  numeric(5,1),
    recorded_at  timestamptz NOT NULL,
    received_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT chk_transport_trip_points_scope CHECK ((tenant_id > 1) AND (school_id > 0))
);
-- A trip's path in order (history playback).
CREATE INDEX IF NOT EXISTS ix_transport_trip_points_trip
    ON core.transport_trip_points(trip_id, recorded_at);
-- The 30-day purge.
CREATE INDEX IF NOT EXISTS ix_transport_trip_points_recorded
    ON core.transport_trip_points(recorded_at);

CREATE TABLE IF NOT EXISTS core.transport_route_shares
(
    share_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   integer NOT NULL,
    school_id   integer NOT NULL,
    route_id    integer NOT NULL REFERENCES core.transport_routes(route_id) ON DELETE CASCADE,
    token_hash  char(64) NOT NULL,            -- lowercase hex sha256 of the raw token
    created_by  integer,
    created_at  timestamptz NOT NULL DEFAULT now(),
    revoked_by  integer,
    revoked_at  timestamptz,
    CONSTRAINT chk_transport_route_shares_scope CHECK ((tenant_id > 1) AND (school_id > 0))
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_transport_route_shares_token
    ON core.transport_route_shares(token_hash);
-- One live link per route.
CREATE UNIQUE INDEX IF NOT EXISTS ux_transport_route_shares_live
    ON core.transport_route_shares(route_id) WHERE revoked_at IS NULL;


-- ── Stale trips ─────────────────────────────────────────────────────────────
-- A running trip with nothing received for 30 minutes is over: the phone was
-- switched off, the page was closed, or the driver forgot End Trip. It ends at
-- its last point (or its start, when it never sent one).
CREATE OR REPLACE FUNCTION core.fn_transport_close_stale_trips(p_tenant_id integer, p_school_id integer)
RETURNS integer
LANGUAGE plpgsql
AS $function$
DECLARE
    v_n integer;
BEGIN
    UPDATE core.transport_trips
       SET ended_at   = COALESCE(last_received_at, started_at),
           end_reason = 'Stale'
     WHERE tenant_id = p_tenant_id AND school_id = p_school_id
       AND ended_at IS NULL
       AND COALESCE(last_received_at, started_at) < now() - interval '30 minutes';
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END;
$function$;


-- ── Driver ──────────────────────────────────────────────────────────────────
DROP PROCEDURE IF EXISTS core.sp_transport_trip_manage(varchar, integer, integer, integer, integer, integer,
    numeric, numeric, numeric, numeric, numeric, timestamptz, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_transport_trip_manage(
    IN p_operation      varchar,
    IN p_tenant_id      integer,
    IN p_school_id      integer,
    IN p_action_user_id integer,
    IN p_vehicle_id     integer     DEFAULT NULL,
    IN p_trip_id        integer     DEFAULT NULL,
    IN p_lat            numeric     DEFAULT NULL,
    IN p_lng            numeric     DEFAULT NULL,
    IN p_accuracy       numeric     DEFAULT NULL,
    IN p_speed          numeric     DEFAULT NULL,
    IN p_heading        numeric     DEFAULT NULL,
    IN p_recorded_at    timestamptz DEFAULT NULL,
    INOUT p_result      refcursor   DEFAULT 'result_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_staff_id  integer;
    v_staff_nm  varchar(150);
    v_trip      core.transport_trips%ROWTYPE;
    v_vehicle   core.transport_vehicles%ROWTYPE;
    v_route_nm  varchar(80);
    v_at        timestamptz;
    v_speed     numeric;
    v_heading   numeric;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    -- Who is calling, as a member of staff of THIS school.
    SELECT staff_id, full_name INTO v_staff_id, v_staff_nm
      FROM core.staff
     WHERE user_id = p_action_user_id AND tenant_id = p_tenant_id AND school_id = p_school_id
       AND NOT COALESCE(is_deleted, FALSE)
       AND COALESCE(status, 'Active') <> 'Inactive'
     LIMIT 1;

    PERFORM core.fn_transport_close_stale_trips(p_tenant_id, p_school_id);

    IF p_operation IN ('MyBus', 'IsDriver') THEN
        -- The vehicles this user drives (none when they are not staff here).
        OPEN p_result FOR
        SELECT v.vehicle_id, v.vehicle_no, r.route_id, r.route_name,
               t.trip_id,
               to_char(t.started_at, 'YYYY-MM-DD HH24:MI:SS')       AS started_at,
               to_char(t.last_received_at, 'YYYY-MM-DD HH24:MI:SS') AS last_point_at,
               COALESCE(t.point_count, 0)                           AS point_count
          FROM core.transport_vehicles v
          LEFT JOIN core.transport_routes r
                 ON r.route_id = v.route_id AND r.tenant_id = v.tenant_id AND r.school_id = v.school_id
                AND NOT COALESCE(r.is_deleted, FALSE)
          LEFT JOIN core.transport_trips t ON t.vehicle_id = v.vehicle_id AND t.ended_at IS NULL
         WHERE v.tenant_id = p_tenant_id AND v.school_id = p_school_id
           AND v.driver_staff_id = v_staff_id
           AND v.is_active AND NOT COALESCE(v.is_deleted, FALSE)
         ORDER BY v.vehicle_no;
        RETURN;
    END IF;

    IF p_operation = 'StartTrip' THEN
        SELECT * INTO v_vehicle FROM core.transport_vehicles
         WHERE vehicle_id = p_vehicle_id AND tenant_id = p_tenant_id AND school_id = p_school_id
           AND is_active AND NOT COALESCE(is_deleted, FALSE);
        IF NOT FOUND OR v_staff_id IS NULL OR v_vehicle.driver_staff_id IS DISTINCT FROM v_staff_id THEN
            RAISE EXCEPTION 'You are not the driver of this bus.';
        END IF;

        -- 30-day retention, for every school (see the header). Indexed and cheap.
        DELETE FROM core.transport_trip_points WHERE recorded_at < now() - interval '30 days';
        DELETE FROM core.transport_trips
         WHERE ended_at IS NOT NULL AND started_at < now() - interval '30 days';

        -- A fresh trip already running on this bus (the page was reloaded): resume it.
        SELECT * INTO v_trip FROM core.transport_trips
         WHERE vehicle_id = v_vehicle.vehicle_id AND ended_at IS NULL;
        IF FOUND THEN
            OPEN p_result FOR
            SELECT TRUE AS success, 'Trip already running. Resumed.'::text AS message,
                   v_trip.trip_id AS trip_id, TRUE AS resumed;
            RETURN;
        END IF;

        SELECT route_name INTO v_route_nm FROM core.transport_routes
         WHERE route_id = v_vehicle.route_id AND tenant_id = p_tenant_id AND school_id = p_school_id
           AND NOT COALESCE(is_deleted, FALSE);

        INSERT INTO core.transport_trips
            (tenant_id, school_id, vehicle_id, route_id, driver_staff_id,
             vehicle_no, route_name, driver_name, started_by)
        VALUES
            (p_tenant_id, p_school_id, v_vehicle.vehicle_id,
             CASE WHEN v_route_nm IS NULL THEN NULL ELSE v_vehicle.route_id END,
             v_staff_id, v_vehicle.vehicle_no, v_route_nm, v_staff_nm, p_action_user_id)
        RETURNING * INTO v_trip;

        OPEN p_result FOR
        SELECT TRUE AS success, 'Trip started.'::text AS message, v_trip.trip_id AS trip_id, FALSE AS resumed;
        RETURN;
    END IF;

    IF p_operation NOT IN ('EndTrip', 'AddPoint') THEN
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;

    -- EndTrip / AddPoint: the trip must be this school's, and the caller must be
    -- the CURRENT driver of its bus.
    SELECT * INTO v_trip FROM core.transport_trips
     WHERE trip_id = p_trip_id AND tenant_id = p_tenant_id AND school_id = p_school_id;
    IF NOT FOUND OR v_staff_id IS NULL OR NOT EXISTS (
           SELECT 1 FROM core.transport_vehicles
            WHERE vehicle_id = v_trip.vehicle_id AND driver_staff_id = v_staff_id
              AND NOT COALESCE(is_deleted, FALSE)) THEN
        RAISE EXCEPTION 'You are not the driver of this bus.';
    END IF;

    IF p_operation = 'EndTrip' THEN
        IF v_trip.ended_at IS NOT NULL THEN
            OPEN p_result FOR SELECT TRUE AS success, 'This trip had already ended.'::text AS message;
            RETURN;
        END IF;
        UPDATE core.transport_trips SET ended_at = now(), end_reason = 'Driver'
         WHERE trip_id = v_trip.trip_id;
        OPEN p_result FOR SELECT TRUE AS success, 'Trip ended.'::text AS message;
        RETURN;
    END IF;

    -- AddPoint
    IF v_trip.ended_at IS NOT NULL THEN
        RAISE EXCEPTION 'This trip has ended. Start a new trip.';
    END IF;
    IF p_lat IS NULL OR p_lng IS NULL OR p_lat < -90 OR p_lat > 90 OR p_lng < -180 OR p_lng > 180 THEN
        RAISE EXCEPTION 'Invalid position.';
    END IF;
    IF p_lat = 0 AND p_lng = 0 THEN
        RAISE EXCEPTION 'Invalid position.';
    END IF;
    IF p_accuracy IS NULL OR p_accuracy < 0 OR p_accuracy > 2000 THEN
        RAISE EXCEPTION 'GPS accuracy is too poor to use (more than 2 km).';
    END IF;

    v_at := COALESCE(p_recorded_at, now());
    IF v_at > now() + interval '2 minutes' THEN
        RAISE EXCEPTION 'The position time is in the future. Check the phone''s clock.';
    END IF;
    IF v_at < v_trip.started_at - interval '1 minute' THEN
        RAISE EXCEPTION 'The position is older than the trip.';
    END IF;

    -- Too soon after the previous point (or out of order): dropped, not an error.
    IF v_trip.last_recorded_at IS NOT NULL AND v_at < v_trip.last_recorded_at + interval '5 seconds' THEN
        OPEN p_result FOR SELECT TRUE AS success, FALSE AS accepted, 'Too soon after the last point; skipped.'::text AS message;
        RETURN;
    END IF;

    -- Speed and heading are only extras: a nonsense value is dropped, not refused.
    v_speed   := CASE WHEN p_speed   BETWEEN 0 AND 100 THEN round(p_speed, 2)   END;   -- m/s
    v_heading := CASE WHEN p_heading BETWEEN 0 AND 360 THEN round(p_heading, 1) END;

    INSERT INTO core.transport_trip_points
        (tenant_id, school_id, trip_id, lat, lng, accuracy_m, speed_mps, heading_deg, recorded_at)
    VALUES
        (p_tenant_id, p_school_id, v_trip.trip_id, round(p_lat, 6), round(p_lng, 6),
         round(p_accuracy, 1), v_speed, v_heading, v_at);

    UPDATE core.transport_trips
       SET last_lat = round(p_lat, 6), last_lng = round(p_lng, 6),
           last_accuracy_m = round(p_accuracy, 1), last_speed_mps = v_speed, last_heading_deg = v_heading,
           last_recorded_at = v_at, last_received_at = now(),
           point_count = point_count + 1
     WHERE trip_id = v_trip.trip_id;

    OPEN p_result FOR SELECT TRUE AS success, TRUE AS accepted, 'Point saved.'::text AS message;
END;
$procedure$;


-- ── Staff: live map, history, share links ───────────────────────────────────
DROP PROCEDURE IF EXISTS core.sp_transport_tracking_manage(varchar, integer, integer, integer, integer, integer,
    integer, varchar, varchar, varchar, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_transport_tracking_manage(
    IN p_operation      varchar,
    IN p_tenant_id      integer,
    IN p_school_id      integer,
    IN p_action_user_id integer,
    IN p_vehicle_id     integer   DEFAULT NULL,
    IN p_trip_id        integer   DEFAULT NULL,
    IN p_route_id       integer   DEFAULT NULL,
    IN p_from_date      varchar   DEFAULT NULL,   -- ISO yyyy-MM-dd, school date
    IN p_to_date        varchar   DEFAULT NULL,
    IN p_token_hash     varchar   DEFAULT NULL,   -- ShareCreate: hex sha256 of the new token
    INOUT p_result      refcursor DEFAULT 'result_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_from date;
    v_to   date;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    PERFORM core.fn_transport_close_stale_trips(p_tenant_id, p_school_id);

    IF p_operation = 'LiveList' THEN
        OPEN p_result FOR
        SELECT t.trip_id, t.vehicle_id,
               COALESCE(v.vehicle_no, t.vehicle_no)                 AS vehicle_no,
               t.route_name, t.driver_name,
               to_char(t.started_at, 'YYYY-MM-DD HH24:MI:SS')       AS started_at,
               to_char(t.last_received_at, 'YYYY-MM-DD HH24:MI:SS') AS last_point_at,
               CASE WHEN t.last_received_at IS NULL THEN NULL
                    ELSE GREATEST(0, EXTRACT(EPOCH FROM now() - t.last_received_at))::int END AS age_seconds,
               t.last_lat AS lat, t.last_lng AS lng, t.last_accuracy_m AS accuracy_m,
               t.last_speed_mps AS speed_mps, t.last_heading_deg AS heading_deg, t.point_count
          FROM core.transport_trips t
          LEFT JOIN core.transport_vehicles v ON v.vehicle_id = t.vehicle_id
         WHERE t.tenant_id = p_tenant_id AND t.school_id = p_school_id AND t.ended_at IS NULL
         ORDER BY 3;

    ELSIF p_operation = 'TripHistory' THEN
        -- Dates are the school's calendar days; default = the last 7 days.
        v_to   := COALESCE(NULLIF(trim(p_to_date), '')::date, current_date);
        v_from := COALESCE(NULLIF(trim(p_from_date), '')::date, v_to - 6);
        OPEN p_result FOR
        SELECT t.trip_id, t.vehicle_id, t.vehicle_no, t.route_name, t.driver_name,
               to_char(t.started_at, 'YYYY-MM-DD HH24:MI:SS') AS started_at,
               to_char(t.ended_at,   'YYYY-MM-DD HH24:MI:SS') AS ended_at,
               t.end_reason, t.point_count,
               (t.ended_at IS NULL) AS is_running,
               GREATEST(0, EXTRACT(EPOCH FROM COALESCE(t.ended_at, now()) - t.started_at) / 60)::int AS duration_min
          FROM core.transport_trips t
         WHERE t.tenant_id = p_tenant_id AND t.school_id = p_school_id
           AND (COALESCE(p_vehicle_id, 0) = 0 OR t.vehicle_id = p_vehicle_id)
           AND t.started_at >= v_from::timestamptz
           AND t.started_at <  (v_to + 1)::timestamptz
         ORDER BY t.started_at DESC
         LIMIT 500;

    ELSIF p_operation = 'TripPoints' THEN
        -- Only a trip of this school; another school's trip id returns no rows.
        OPEN p_result FOR
        SELECT p.lat, p.lng, p.accuracy_m, p.speed_mps,
               to_char(p.recorded_at, 'YYYY-MM-DD HH24:MI:SS') AS recorded_at
          FROM core.transport_trip_points p
          JOIN core.transport_trips t ON t.trip_id = p.trip_id
         WHERE p.trip_id = p_trip_id
           AND t.tenant_id = p_tenant_id AND t.school_id = p_school_id
           AND p.tenant_id = p_tenant_id AND p.school_id = p_school_id
         ORDER BY p.recorded_at
         LIMIT 10000;

    ELSIF p_operation = 'ShareList' THEN
        OPEN p_result FOR
        SELECT s.route_id, to_char(s.created_at, 'YYYY-MM-DD HH24:MI:SS') AS created_at
          FROM core.transport_route_shares s
         WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id AND s.revoked_at IS NULL;

    ELSIF p_operation = 'ShareCreate' THEN
        -- Create, or regenerate: the old link stops working at once.
        IF NOT EXISTS (SELECT 1 FROM core.transport_routes
                        WHERE route_id = p_route_id AND tenant_id = p_tenant_id AND school_id = p_school_id
                          AND NOT COALESCE(is_deleted, FALSE)) THEN
            RAISE EXCEPTION 'Route not found.';
        END IF;
        IF p_token_hash IS NULL OR p_token_hash !~ '^[0-9a-f]{64}$' THEN
            RAISE EXCEPTION 'Invalid link token.';
        END IF;

        UPDATE core.transport_route_shares
           SET revoked_at = now(), revoked_by = p_action_user_id
         WHERE route_id = p_route_id AND tenant_id = p_tenant_id AND school_id = p_school_id
           AND revoked_at IS NULL;

        INSERT INTO core.transport_route_shares (tenant_id, school_id, route_id, token_hash, created_by)
        VALUES (p_tenant_id, p_school_id, p_route_id, p_token_hash, p_action_user_id);

        OPEN p_result FOR SELECT TRUE AS success, 'Parent link created.'::text AS message;

    ELSIF p_operation = 'ShareRevoke' THEN
        UPDATE core.transport_route_shares
           SET revoked_at = now(), revoked_by = p_action_user_id
         WHERE route_id = p_route_id AND tenant_id = p_tenant_id AND school_id = p_school_id
           AND revoked_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'This route has no parent link.';
        END IF;
        OPEN p_result FOR SELECT TRUE AS success, 'Parent link turned off.'::text AS message;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;


-- ── Parent page (no login) ──────────────────────────────────────────────────
-- The token's hash is the ONLY input; the school comes from the share row, never
-- from the caller. Rows:
--   none                     -> unknown or revoked link, route deleted, or the
--                               school switched Transport off
--   one row, trip_id NULL    -> valid link, no bus on a trip right now
--   one row per running bus  -> vehicle no. and last position
-- Nothing personal is returned: no driver, no phone, no students.
DROP PROCEDURE IF EXISTS core.sp_transport_track_public(varchar, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_transport_track_public(
    IN p_token_hash varchar,
    INOUT p_result  refcursor DEFAULT 'result_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_tenant integer;
    v_school integer;
    v_route  integer;
    v_name   varchar(80);
BEGIN
    SELECT s.tenant_id, s.school_id, s.route_id, r.route_name
      INTO v_tenant, v_school, v_route, v_name
      FROM core.transport_route_shares s
      JOIN core.transport_routes r ON r.route_id = s.route_id
           AND r.tenant_id = s.tenant_id AND r.school_id = s.school_id
           AND NOT COALESCE(r.is_deleted, FALSE)
     WHERE p_token_hash ~ '^[0-9a-f]{64}$'
       AND s.token_hash = p_token_hash
       AND s.revoked_at IS NULL
       AND core.fn_module_on(s.tenant_id, s.school_id, 'transport');   -- given and switched on

    IF v_route IS NULL THEN
        OPEN p_result FOR
        SELECT NULL::varchar AS route_name, NULL::integer AS trip_id, NULL::varchar AS vehicle_no,
               NULL::numeric AS lat, NULL::numeric AS lng, NULL::int AS age_seconds,
               NULL::text AS last_point_at
         WHERE FALSE;
        RETURN;
    END IF;

    PERFORM core.fn_transport_close_stale_trips(v_tenant, v_school);

    OPEN p_result FOR
    SELECT v_name AS route_name, t.trip_id, t.vehicle_no, t.last_lat AS lat, t.last_lng AS lng,
           CASE WHEN t.last_received_at IS NULL THEN NULL
                ELSE GREATEST(0, EXTRACT(EPOCH FROM now() - t.last_received_at))::int END AS age_seconds,
           to_char(t.last_received_at, 'HH24:MI') AS last_point_at
      FROM (SELECT 1) one
      LEFT JOIN core.transport_trips t
             ON t.tenant_id = v_tenant AND t.school_id = v_school
            AND t.route_id = v_route AND t.ended_at IS NULL
     ORDER BY t.vehicle_no;
END;
$procedure$;

