-- ============================================================================
-- Fee Collection — persist the DISCOUNT metadata (type + value + reason)
--
-- The counter applies ONE discount per receipt (flat ₹ or %, with a reason) and
-- spreads it across the picked dues as per-line concession. The concession
-- AMOUNT was already stored (fee_payments.concession_total + per-line). This
-- adds the missing "why": discount_type / discount_value / discount_reason on
-- the receipt header, written by sp_fee_payment_collect and returned by
-- sp_fee_receipt_get so it can print on the receipt.
--
-- The collect proc is DROP-then-CREATE (3 new params) so exactly ONE overload
-- remains. Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── 1. Discount metadata on the receipt header ──────────────────────────────
ALTER TABLE core.fee_payments
    ADD COLUMN IF NOT EXISTS discount_type   varchar(10),               -- 'Flat' | 'Percent'
    ADD COLUMN IF NOT EXISTS discount_value  numeric(12,2) NOT NULL DEFAULT 0,  -- entered value (₹ or %)
    ADD COLUMN IF NOT EXISTS discount_reason varchar(250);

-- ── 2. Collect proc now also records the discount metadata ──────────────────
DROP PROCEDURE IF EXISTS core.sp_fee_payment_collect(
    integer, integer, integer, integer, jsonb, jsonb,
    character varying, character varying, character varying, date, character varying, refcursor);

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
    r_ledger       record;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR p_student_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;

    v_has_items  := p_items  IS NOT NULL AND jsonb_typeof(p_items)  = 'array' AND jsonb_array_length(p_items)  > 0;
    v_has_extras := p_extras IS NOT NULL AND jsonb_typeof(p_extras) = 'array' AND jsonb_array_length(p_extras) > 0;

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

    INSERT INTO core.receipt_counters (tenant_id, school_id, fin_year, last_seq)
    VALUES (p_tenant_id, p_school_id, v_year, 1)
    ON CONFLICT (tenant_id, school_id, fin_year)
    DO UPDATE SET last_seq = core.receipt_counters.last_seq + 1
    RETURNING last_seq INTO v_seq;

    v_receipt := 'RCP-' || v_year || '-' || lpad(v_seq::text, 4, '0');

    INSERT INTO core.fee_payments
        (tenant_id, school_id, student_id, payment_type, receipt_no, amount, concession_total,
         payment_mode, reference_no, remarks, payment_date, created_by,
         discount_type, discount_value, discount_reason)
    VALUES
        (p_tenant_id, p_school_id, p_student_id, 'Fee', v_receipt, v_cash_total, v_conc_total,
         p_payment_mode, NULLIF(trim(p_reference_no), ''), NULLIF(trim(p_remarks), ''),
         v_date, p_action_user_id,
         CASE WHEN v_conc_total > 0 THEN NULLIF(trim(p_discount_type), '') ELSE NULL END,
         CASE WHEN v_conc_total > 0 THEN COALESCE(p_discount_value, 0) ELSE 0 END,
         CASE WHEN v_conc_total > 0 THEN NULLIF(trim(p_discount_reason), '') ELSE NULL END)
    RETURNING payment_id INTO v_payment_id;

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

-- ── 3. Receipt header returns the discount metadata ─────────────────────────
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
    WHERE tenant_id = p_tenant_id AND school_id = p_school_id
      AND receipt_no = p_receipt_no;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Receipt not found.';
    END IF;

    OPEN p_header FOR
    SELECT p.receipt_no,
           p.payment_date,
           p.amount,
           p.concession_total,
           p.payment_mode,
           p.reference_no,
           p.remarks,
           p.payment_type,
           p.discount_type,
           p.discount_value,
           p.discount_reason,
           COALESCE(s.student_name, e.student_name, 'Student')       AS student_name,
           COALESCE(s.admission_no, '-')                             AS admission_no,
           COALESCE(s.class_name, e.class_name, '-')                 AS class_name,
           s.section                                                 AS section,
           s.roll_no                                                 AS roll_no
    FROM core.fee_payments p
    LEFT JOIN core.students  s ON s.student_id = p.student_id
    LEFT JOIN core.enquiries e ON e.enquiry_id = p.enquiry_id
    WHERE p.payment_id = v_payment_id;

    OPEN p_lines FOR
    SELECT fee_head_name,
           installment_label,
           amount,
           concession,
           line_type
    FROM core.fee_payment_details
    WHERE payment_id = v_payment_id
    ORDER BY detail_id;
END;
$procedure$;
