-- ============================================================================
-- Collect Fee at Admission
--  1. Adds the "collect_fee_at_admission" workflow setting.
--  2. Adds a payments/receipts layer (fee_payments + receipt_counters) and a
--     proc that records a payment, issues a receipt number, and allocates the
--     amount across the student's outstanding ledger dues (oldest first).
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── 1. Workflow setting column ──────────────────────────────────────────────
ALTER TABLE core.school_admission_workflow_settings
    ADD COLUMN IF NOT EXISTS collect_fee_at_admission boolean NOT NULL DEFAULT FALSE;

-- ── 1b. Updated workflow manage proc (adds the new flag) ────────────────────
CREATE OR REPLACE PROCEDURE core.sp_school_admin_admission_workflow_manage(
    IN    p_operation                              varchar,
    IN    p_tenant_id                              integer,
    IN    p_school_id                              integer,
    IN    p_action_user_id                         integer,
    IN    p_enable_registration                    boolean       DEFAULT NULL,
    IN    p_registration_required_before_admission boolean       DEFAULT NULL,
    IN    p_enable_registration_fee                boolean       DEFAULT NULL,
    IN    p_registration_fee_amount                numeric       DEFAULT NULL,
    IN    p_auto_generate_registration_number      boolean       DEFAULT NULL,
    IN    p_registration_number_prefix             varchar       DEFAULT NULL,
    IN    p_collect_fee_at_admission               boolean       DEFAULT NULL,
    INOUT p_result                                 refcursor     DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_enable_reg  boolean;
    v_required    boolean;
    v_enable_fee  boolean;
    v_fee_amount  numeric(12,2);
    v_auto_num    boolean;
    v_prefix      varchar(20);
    v_collect     boolean;
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
            registration_fee_amount,
            auto_generate_registration_number,
            registration_number_prefix,
            collect_fee_at_admission
        FROM core.school_admission_workflow_settings
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND COALESCE(is_deleted, FALSE) = FALSE
        LIMIT 1;

    ELSIF p_operation = 'SaveAdmissionWorkflow' THEN
        v_enable_reg := COALESCE(p_enable_registration, FALSE);
        v_required   := v_enable_reg AND COALESCE(p_registration_required_before_admission, FALSE);
        v_enable_fee := v_enable_reg AND COALESCE(p_enable_registration_fee, FALSE);
        v_fee_amount := CASE WHEN v_enable_fee THEN COALESCE(p_registration_fee_amount, 0) ELSE 0 END;
        v_auto_num   := COALESCE(p_auto_generate_registration_number, TRUE);
        v_prefix     := COALESCE(NULLIF(trim(p_registration_number_prefix), ''), 'REG-');
        v_collect    := COALESCE(p_collect_fee_at_admission, FALSE);

        IF v_fee_amount < 0 THEN
            RAISE EXCEPTION 'Registration fee amount cannot be negative.';
        END IF;

        INSERT INTO core.school_admission_workflow_settings
        (
            tenant_id, school_id,
            enable_registration, registration_required_before_admission,
            enable_registration_fee, registration_fee_amount,
            auto_generate_registration_number, registration_number_prefix,
            collect_fee_at_admission,
            created_by, created_at, is_deleted, is_active
        )
        VALUES
        (
            p_tenant_id, p_school_id,
            v_enable_reg, v_required,
            v_enable_fee, v_fee_amount,
            v_auto_num, v_prefix,
            v_collect,
            p_action_user_id, NOW(), FALSE, TRUE
        )
        ON CONFLICT (tenant_id, school_id) DO UPDATE
        SET enable_registration                    = EXCLUDED.enable_registration,
            registration_required_before_admission = EXCLUDED.registration_required_before_admission,
            enable_registration_fee                = EXCLUDED.enable_registration_fee,
            registration_fee_amount                = EXCLUDED.registration_fee_amount,
            auto_generate_registration_number      = EXCLUDED.auto_generate_registration_number,
            registration_number_prefix             = EXCLUDED.registration_number_prefix,
            collect_fee_at_admission               = EXCLUDED.collect_fee_at_admission,
            is_deleted = FALSE, is_active = TRUE,
            updated_by = p_action_user_id, updated_at = NOW();

        OPEN p_result FOR SELECT TRUE AS success, 'Saved successfully.' AS message;
    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;

-- ── 2. Receipt counter (per financial year) ─────────────────────────────────
CREATE TABLE IF NOT EXISTS core.receipt_counters
(
    tenant_id integer NOT NULL,
    school_id integer NOT NULL,
    fin_year  varchar(12) NOT NULL,
    last_seq  integer NOT NULL DEFAULT 0,
    CONSTRAINT pk_receipt_counters PRIMARY KEY (tenant_id, school_id, fin_year)
);

-- ── 2b. Payments / receipts ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS core.fee_payments
(
    payment_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     integer NOT NULL,
    school_id     integer NOT NULL,
    student_id    integer NOT NULL,
    receipt_no    varchar(40) NOT NULL,
    amount        numeric(12,2) NOT NULL,
    payment_mode  varchar(30) NOT NULL,
    reference_no  varchar(60),
    remarks       varchar(200),
    payment_date  date NOT NULL DEFAULT CURRENT_DATE,
    created_by    integer NOT NULL,
    created_at    timestamp without time zone NOT NULL DEFAULT CURRENT_TIMESTAMP,
    is_active     boolean NOT NULL DEFAULT TRUE,
    CONSTRAINT chk_fee_payments_scope CHECK ((tenant_id > 1) AND (school_id > 0)),
    CONSTRAINT uq_fee_payments_receipt UNIQUE (tenant_id, school_id, receipt_no)
);

-- ── 2c. Record a payment → receipt + ledger allocation ──────────────────────
CREATE OR REPLACE PROCEDURE core.sp_fee_payment_record(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_student_id     integer,
    IN    p_amount         numeric,
    IN    p_payment_mode   varchar,
    IN    p_reference_no   varchar  DEFAULT NULL,
    IN    p_remarks        varchar  DEFAULT NULL,
    IN    p_payment_date   date     DEFAULT NULL,
    IN    p_fin_year       varchar  DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_seq        integer;
    v_year       varchar(4);
    v_receipt    varchar(40);
    v_remaining  numeric(12,2);
    v_pay        numeric(12,2);
    v_date       date;
    r            record;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR p_student_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;
    IF COALESCE(p_amount, 0) <= 0 THEN
        RAISE EXCEPTION 'Payment amount must be greater than zero.';
    END IF;

    v_date := COALESCE(p_payment_date, CURRENT_DATE);
    v_year := left(COALESCE(NULLIF(trim(p_fin_year), ''), to_char(v_date, 'YYYY')), 4);

    -- Receipt number: RCP-<year>-<seq>
    INSERT INTO core.receipt_counters (tenant_id, school_id, fin_year, last_seq)
    VALUES (p_tenant_id, p_school_id, v_year, 1)
    ON CONFLICT (tenant_id, school_id, fin_year)
    DO UPDATE SET last_seq = core.receipt_counters.last_seq + 1
    RETURNING last_seq INTO v_seq;

    v_receipt := 'RCP-' || v_year || '-' || lpad(v_seq::text, 4, '0');

    INSERT INTO core.fee_payments
        (tenant_id, school_id, student_id, receipt_no, amount, payment_mode,
         reference_no, remarks, payment_date, created_by)
    VALUES
        (p_tenant_id, p_school_id, p_student_id, v_receipt, p_amount, p_payment_mode,
         NULLIF(trim(p_reference_no), ''), NULLIF(trim(p_remarks), ''), v_date, p_action_user_id);

    -- Allocate across outstanding ledger dues, oldest first.
    v_remaining := p_amount;
    FOR r IN
        SELECT ledger_id, amount_due, COALESCE(amount_paid, 0) AS paid
        FROM core.student_ledger
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND student_id = p_student_id
          AND amount_due > COALESCE(amount_paid, 0)
        ORDER BY due_date NULLS LAST, ledger_id
    LOOP
        EXIT WHEN v_remaining <= 0;
        v_pay := LEAST(v_remaining, r.amount_due - r.paid);

        UPDATE core.student_ledger
        SET amount_paid = r.paid + v_pay,
            status      = CASE WHEN r.paid + v_pay >= amount_due THEN 'Paid' ELSE 'Partial' END,
            updated_at  = NOW()
        WHERE ledger_id = r.ledger_id;

        v_remaining := v_remaining - v_pay;
    END LOOP;

    OPEN p_result FOR
    SELECT TRUE AS success,
           'Payment recorded.' AS message,
           v_receipt AS receipt_no,
           p_amount  AS amount,
           v_date    AS payment_date;
END;
$procedure$;
