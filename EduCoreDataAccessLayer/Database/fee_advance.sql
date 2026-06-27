-- ============================================================================
-- Fee Collection — ADVANCE / credit wallet
--
-- A student carries a single advance balance (core.student_advance). Two flows
-- on the counter, both handled inside sp_fee_payment_collect:
--   • Overpay  → the surplus cash is CREDITED to the wallet (advance_credit).
--   • Use it   → p_advance_used DEBITS the wallet and funds part of the bill.
--
-- Funding rule for a receipt:
--   funded   = (non-advance tenders) + advance_used
--   settled  = dues cash + extras            (= fee_payments.amount)
--   surplus  = funded − settled  (≥ 0)       → credited to the wallet
--   wallet  += surplus − advance_used
-- Advance is recorded as an 'Advance' tender line so it shows in reports but is
-- never counted as cash (Day Close cash = mode 'Cash' only).
--
-- sp_fee_payment_collect drop-then-recreated (adds p_advance_used) → one overload.
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── 1. Wallet balance + advance columns on the receipt ──────────────────────
CREATE TABLE IF NOT EXISTS core.student_advance
(
    student_id  integer PRIMARY KEY REFERENCES core.students(student_id) ON DELETE CASCADE,
    tenant_id   integer       NOT NULL,
    school_id   integer       NOT NULL,
    balance     numeric(12,2) NOT NULL DEFAULT 0,
    updated_at  timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT chk_student_advance_scope CHECK ((tenant_id > 1) AND (school_id > 0))
);

ALTER TABLE core.fee_payments
    ADD COLUMN IF NOT EXISTS advance_used   numeric(12,2) NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS advance_credit numeric(12,2) NOT NULL DEFAULT 0;

-- ── 2. Read a student's advance balance ─────────────────────────────────────
CREATE OR REPLACE PROCEDURE core.sp_student_advance_get(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_student_id     integer,
    INOUT p_result         refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR p_student_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;

    OPEN p_result FOR
    SELECT COALESCE((SELECT balance FROM core.student_advance
                     WHERE tenant_id=p_tenant_id AND school_id=p_school_id AND student_id=p_student_id), 0) AS balance;
END;
$procedure$;

-- ── 3. Collect proc — now also handles advance (use + credit) ───────────────
DROP PROCEDURE IF EXISTS core.sp_fee_payment_collect(
    integer, integer, integer, integer, jsonb, jsonb,
    character varying, character varying, character varying, date, character varying,
    character varying, numeric, character varying, jsonb, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_fee_payment_collect(
    IN    p_tenant_id       integer,
    IN    p_school_id       integer,
    IN    p_action_user_id  integer,
    IN    p_student_id      integer,
    IN    p_items           jsonb,
    IN    p_extras          jsonb,
    IN    p_payment_mode    varchar,
    IN    p_reference_no    varchar  DEFAULT NULL,
    IN    p_remarks         varchar  DEFAULT NULL,
    IN    p_payment_date    date     DEFAULT NULL,
    IN    p_fin_year        varchar  DEFAULT NULL,
    IN    p_discount_type   varchar  DEFAULT NULL,
    IN    p_discount_value  numeric  DEFAULT 0,
    IN    p_discount_reason varchar  DEFAULT NULL,
    IN    p_tenders         jsonb    DEFAULT NULL,
    IN    p_advance_used    numeric  DEFAULT 0,
    INOUT p_result          refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_seq          integer;
    v_year         varchar(4);
    v_receipt      varchar(40);
    v_date         date;
    v_payment_id   integer;
    v_cash_total   numeric(12,2) := 0;
    v_conc_total   numeric(12,2) := 0;
    v_item         jsonb;
    v_ledger_id    integer;
    v_amount       numeric(12,2);
    v_concession   numeric(12,2);
    v_label        varchar(100);
    v_outstanding  numeric(12,2);
    v_has_items    boolean;
    v_has_extras   boolean;
    v_has_tenders  boolean;
    v_new_cash     numeric(12,2) := 0;
    v_adv_used     numeric(12,2);
    v_balance      numeric(12,2) := 0;
    v_funded       numeric(12,2);
    v_surplus      numeric(12,2);
    v_mode_count   integer := 0;
    v_mode         varchar(30);
    r_ledger       record;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR p_student_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;

    v_has_items   := p_items   IS NOT NULL AND jsonb_typeof(p_items)   = 'array' AND jsonb_array_length(p_items)   > 0;
    v_has_extras  := p_extras  IS NOT NULL AND jsonb_typeof(p_extras)  = 'array' AND jsonb_array_length(p_extras)  > 0;
    v_has_tenders := p_tenders IS NOT NULL AND jsonb_typeof(p_tenders) = 'array' AND jsonb_array_length(p_tenders) > 0;
    v_adv_used    := COALESCE(p_advance_used, 0);

    IF NOT v_has_items AND NOT v_has_extras THEN
        RAISE EXCEPTION 'Select at least one due or add an extra charge.';
    END IF;

    v_date := COALESCE(p_payment_date, CURRENT_DATE);
    v_year := left(COALESCE(NULLIF(trim(p_fin_year), ''), to_char(v_date, 'YYYY')), 4);

    IF v_has_items THEN
        FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
        LOOP
            v_ledger_id  := (v_item->>'ledgerId')::integer;
            v_amount     := COALESCE((v_item->>'amount')::numeric, 0);
            v_concession := COALESCE((v_item->>'concession')::numeric, 0);

            IF v_amount < 0 OR v_concession < 0 THEN
                RAISE EXCEPTION 'Amount and concession cannot be negative.';
            END IF;
            IF v_amount = 0 AND v_concession = 0 THEN
                CONTINUE;
            END IF;

            SELECT amount_due - amount_paid - concession
              INTO v_outstanding
            FROM core.student_ledger
            WHERE ledger_id = v_ledger_id
              AND tenant_id = p_tenant_id AND school_id = p_school_id AND student_id = p_student_id;

            IF NOT FOUND THEN
                RAISE EXCEPTION 'A selected due no longer exists. Please reload.';
            END IF;
            IF v_amount + v_concession > v_outstanding + 0.001 THEN
                RAISE EXCEPTION 'A payment line is more than its outstanding amount. Please reload.';
            END IF;

            v_cash_total := v_cash_total + v_amount;
            v_conc_total := v_conc_total + v_concession;
        END LOOP;
    END IF;

    IF v_has_extras THEN
        FOR v_item IN SELECT * FROM jsonb_array_elements(p_extras)
        LOOP
            v_amount := COALESCE((v_item->>'amount')::numeric, 0);
            IF v_amount < 0 THEN
                RAISE EXCEPTION 'Extra charge cannot be negative.';
            END IF;
            v_cash_total := v_cash_total + v_amount;
        END LOOP;
    END IF;

    IF v_cash_total <= 0 AND v_conc_total <= 0 THEN
        RAISE EXCEPTION 'Nothing to collect.';
    END IF;

    -- Advance to use must exist in the wallet.
    IF v_adv_used > 0 THEN
        SELECT COALESCE(balance, 0) INTO v_balance
        FROM core.student_advance
        WHERE tenant_id=p_tenant_id AND school_id=p_school_id AND student_id=p_student_id
        FOR UPDATE;
        v_balance := COALESCE(v_balance, 0);
        IF v_adv_used > v_balance + 0.01 THEN
            RAISE EXCEPTION 'Advance used (%) exceeds available balance (%).', v_adv_used, v_balance;
        END IF;
    END IF;

    -- Funding = new cash (non-advance tenders) + advance used. Surplus → credit.
    IF v_has_tenders THEN
        SELECT COALESCE(SUM((t->>'amount')::numeric), 0),
               COUNT(DISTINCT t->>'mode') FILTER (WHERE COALESCE((t->>'amount')::numeric,0) > 0)
          INTO v_new_cash, v_mode_count
        FROM jsonb_array_elements(p_tenders) t;
    ELSE
        v_new_cash := v_cash_total - v_adv_used;   -- no explicit split: exact funding
    END IF;

    v_funded  := v_new_cash + v_adv_used;
    IF v_funded < v_cash_total - 0.01 THEN
        RAISE EXCEPTION 'Payment (%) is less than the amount being settled (%).', v_funded, v_cash_total;
    END IF;
    v_surplus := v_funded - v_cash_total;          -- >= 0

    -- Header payment mode.
    IF v_has_tenders AND v_new_cash > 0 THEN
        IF v_mode_count <= 1 THEN
            SELECT NULLIF(trim(t->>'mode'), '') INTO v_mode
            FROM jsonb_array_elements(p_tenders) t
            WHERE COALESCE((t->>'amount')::numeric, 0) > 0
            LIMIT 1;
        ELSE
            v_mode := 'Mixed';
        END IF;
    ELSIF v_adv_used > 0 AND v_new_cash = 0 THEN
        v_mode := 'Advance';
    END IF;
    v_mode := COALESCE(v_mode, NULLIF(trim(p_payment_mode), ''), 'Cash');

    INSERT INTO core.receipt_counters (tenant_id, school_id, fin_year, last_seq)
    VALUES (p_tenant_id, p_school_id, v_year, 1)
    ON CONFLICT (tenant_id, school_id, fin_year)
    DO UPDATE SET last_seq = core.receipt_counters.last_seq + 1
    RETURNING last_seq INTO v_seq;

    v_receipt := 'RCP-' || v_year || '-' || lpad(v_seq::text, 4, '0');

    INSERT INTO core.fee_payments
        (tenant_id, school_id, student_id, payment_type, receipt_no, amount, concession_total,
         payment_mode, reference_no, remarks, payment_date, created_by,
         discount_type, discount_value, discount_reason, advance_used, advance_credit)
    VALUES
        (p_tenant_id, p_school_id, p_student_id, 'Fee', v_receipt, v_cash_total, v_conc_total,
         v_mode, NULLIF(trim(p_reference_no), ''), NULLIF(trim(p_remarks), ''),
         v_date, p_action_user_id,
         CASE WHEN v_conc_total > 0 THEN NULLIF(trim(p_discount_type), '') ELSE NULL END,
         CASE WHEN v_conc_total > 0 THEN COALESCE(p_discount_value, 0) ELSE 0 END,
         CASE WHEN v_conc_total > 0 THEN NULLIF(trim(p_discount_reason), '') ELSE NULL END,
         v_adv_used, v_surplus)
    RETURNING payment_id INTO v_payment_id;

    -- Adjust the wallet: debit what was used, credit the surplus.
    IF v_adv_used > 0 OR v_surplus > 0 THEN
        INSERT INTO core.student_advance (tenant_id, school_id, student_id, balance, updated_at)
        VALUES (p_tenant_id, p_school_id, p_student_id, v_surplus - v_adv_used, NOW())
        ON CONFLICT (student_id)
        DO UPDATE SET balance = core.student_advance.balance + v_surplus - v_adv_used, updated_at = NOW();
    END IF;

    -- Tender rows: the cash split, plus an 'Advance' line for wallet-funded part.
    IF v_has_tenders THEN
        FOR v_item IN SELECT * FROM jsonb_array_elements(p_tenders)
        LOOP
            v_amount := COALESCE((v_item->>'amount')::numeric, 0);
            IF v_amount <= 0 THEN CONTINUE; END IF;
            INSERT INTO core.fee_payment_tenders (payment_id, mode, amount, reference)
            VALUES (v_payment_id, COALESCE(NULLIF(trim(v_item->>'mode'), ''), 'Cash'),
                    v_amount, NULLIF(trim(v_item->>'reference'), ''));
        END LOOP;
    END IF;
    IF v_adv_used > 0 THEN
        INSERT INTO core.fee_payment_tenders (payment_id, mode, amount)
        VALUES (v_payment_id, 'Advance', v_adv_used);
    END IF;

    IF v_has_items THEN
        FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
        LOOP
            v_ledger_id  := (v_item->>'ledgerId')::integer;
            v_amount     := COALESCE((v_item->>'amount')::numeric, 0);
            v_concession := COALESCE((v_item->>'concession')::numeric, 0);

            IF v_amount = 0 AND v_concession = 0 THEN
                CONTINUE;
            END IF;

            SELECT * INTO r_ledger
            FROM core.student_ledger
            WHERE ledger_id = v_ledger_id
              AND tenant_id = p_tenant_id AND school_id = p_school_id AND student_id = p_student_id;

            UPDATE core.student_ledger
            SET amount_paid = amount_paid + v_amount,
                concession  = concession  + v_concession,
                status      = CASE WHEN amount_paid + v_amount + concession + v_concession >= amount_due
                                   THEN 'Paid' ELSE 'Partial' END,
                updated_at  = NOW()
            WHERE ledger_id = v_ledger_id;

            INSERT INTO core.fee_payment_details
                (payment_id, ledger_id, fee_head_name, installment_label, amount, concession, line_type)
            VALUES
                (v_payment_id, v_ledger_id, r_ledger.fee_head_name, r_ledger.installment_label,
                 v_amount, v_concession, 'Due');
        END LOOP;
    END IF;

    IF v_has_extras THEN
        FOR v_item IN SELECT * FROM jsonb_array_elements(p_extras)
        LOOP
            v_amount := COALESCE((v_item->>'amount')::numeric, 0);
            v_label  := COALESCE(NULLIF(trim(v_item->>'label'), ''), 'Extra Charge');
            IF v_amount <= 0 THEN
                CONTINUE;
            END IF;

            INSERT INTO core.fee_payment_details
                (payment_id, ledger_id, fee_head_name, installment_label, amount, concession, line_type)
            VALUES
                (v_payment_id, NULL, v_label, NULL, v_amount, 0, 'Extra');
        END LOOP;
    END IF;

    OPEN p_result FOR
    SELECT TRUE         AS success,
           'Payment recorded.' AS message,
           v_receipt    AS receipt_no,
           v_cash_total AS amount,
           v_conc_total AS concession_total,
           v_date       AS payment_date;
END;
$procedure$;

-- ── 4. Receipt header also returns advance used / credit ────────────────────
CREATE OR REPLACE PROCEDURE core.sp_fee_receipt_get(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_receipt_no     varchar,
    INOUT p_header         refcursor DEFAULT 'header_cursor'::refcursor,
    INOUT p_lines          refcursor DEFAULT 'lines_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_payment_id integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR p_receipt_no IS NULL THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;

    SELECT payment_id INTO v_payment_id
    FROM core.fee_payments
    WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND receipt_no = p_receipt_no;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Receipt not found.';
    END IF;

    OPEN p_header FOR
    SELECT p.receipt_no, p.payment_date, p.amount, p.concession_total, p.payment_mode,
           p.reference_no, p.remarks, p.payment_type,
           p.discount_type, p.discount_value, p.discount_reason,
           p.advance_used, p.advance_credit,
           COALESCE(s.student_name, e.student_name, 'Student') AS student_name,
           COALESCE(s.admission_no, '-')                       AS admission_no,
           COALESCE(s.class_name, e.class_name, '-')           AS class_name,
           s.section AS section, s.roll_no AS roll_no
    FROM core.fee_payments p
    LEFT JOIN core.students  s ON s.student_id = p.student_id
    LEFT JOIN core.enquiries e ON e.enquiry_id = p.enquiry_id
    WHERE p.payment_id = v_payment_id;

    OPEN p_lines FOR
    SELECT fee_head_name, installment_label, amount, concession, line_type
    FROM core.fee_payment_details
    WHERE payment_id = v_payment_id
    ORDER BY detail_id;
END;
$procedure$;
