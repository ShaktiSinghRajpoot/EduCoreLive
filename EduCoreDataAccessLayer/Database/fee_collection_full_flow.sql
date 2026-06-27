-- ============================================================================
-- Fee Collection — full counter flow (ERP → Fee → Manage Fee)
--
-- Makes the Fee Collection counter a complete, correct flow:
--   1. Per-item payment: the cashier ticks specific dues and pays each (full or
--      partial), optionally granting a concession (discount/waiver) per item.
--   2. The payment is allocated to EXACTLY the ledger rows the cashier picked
--      (no more silent oldest-first allocation that disagreed with the receipt).
--   3. Every receipt stores its line items, so receipts can be re-printed and a
--      student's payment history can be listed.
--
-- New objects:
--   • core.student_ledger.concession        (column)  — waiver granted on a due
--   • core.fee_payments.concession_total     (column)  — total waiver on a receipt
--   • core.fee_payment_details               (table)   — receipt line items
--   • core.sp_fee_payment_collect            (proc)    — item-based collection
--   • core.sp_fee_payment_history_get        (proc)    — receipts for a student
--   • core.sp_fee_receipt_get                (proc)    — one receipt + its lines
--   • core.sp_student_dues_get               (proc)    — now nets off concession
--
-- The old core.sp_fee_payment_record (lump-sum, oldest-first) is left untouched;
-- the admission "collect at admission" flow still uses it.
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── 1. Concession columns ───────────────────────────────────────────────────
ALTER TABLE core.student_ledger
    ADD COLUMN IF NOT EXISTS concession numeric(12,2) NOT NULL DEFAULT 0;

ALTER TABLE core.fee_payments
    ADD COLUMN IF NOT EXISTS concession_total numeric(12,2) NOT NULL DEFAULT 0;

-- ── 2. Receipt line items ───────────────────────────────────────────────────
-- One row per due that a receipt paid towards. Lets us re-print a receipt and
-- show exactly what each payment covered.
CREATE TABLE IF NOT EXISTS core.fee_payment_details
(
    detail_id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    payment_id        integer       NOT NULL REFERENCES core.fee_payments(payment_id) ON DELETE CASCADE,
    ledger_id         integer       NOT NULL,
    fee_head_name     varchar(100)  NOT NULL,
    installment_label varchar(40),
    amount            numeric(12,2) NOT NULL DEFAULT 0,   -- cash collected for this line
    concession        numeric(12,2) NOT NULL DEFAULT 0    -- waiver granted on this line
);

CREATE INDEX IF NOT EXISTS idx_fee_payment_details_payment
    ON core.fee_payment_details(payment_id);

-- ── 3. Student dues — outstanding now nets off concession ───────────────────
CREATE OR REPLACE PROCEDURE core.sp_student_dues_get(
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
    SELECT
        ledger_id,
        fee_head_name,
        frequency,
        installment_label,
        due_date,
        amount_due,
        amount_paid,
        concession,
        (amount_due - amount_paid - concession) AS outstanding
    FROM core.student_ledger
    WHERE tenant_id  = p_tenant_id
      AND school_id  = p_school_id
      AND student_id = p_student_id
      AND amount_due > amount_paid + concession
    ORDER BY due_date NULLS LAST, ledger_id;
END;
$procedure$;

-- ── 4. Collect payment against specific dues ────────────────────────────────
-- p_items is a JSON array of the picked dues, e.g.
--   [ { "ledgerId": 12, "amount": 500, "concession": 0 },
--     { "ledgerId": 13, "amount": 250, "concession": 50 } ]
-- Each line's cash + concession is applied to that exact ledger row, and a
-- receipt line is stored. The receipt total = sum of the cash amounts.
CREATE OR REPLACE PROCEDURE core.sp_fee_payment_collect(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_student_id     integer,
    IN    p_items          jsonb,
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
    v_outstanding  numeric(12,2);
    r_ledger       record;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR p_student_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;
    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'Select at least one due to collect.';
    END IF;

    v_date := COALESCE(p_payment_date, CURRENT_DATE);
    v_year := left(COALESCE(NULLIF(trim(p_fin_year), ''), to_char(v_date, 'YYYY')), 4);

    -- Validate every line and add up the totals BEFORE writing anything, so a
    -- bad line aborts the whole receipt (all-or-nothing).
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        v_ledger_id  := (v_item->>'ledgerId')::integer;
        v_amount     := COALESCE((v_item->>'amount')::numeric, 0);
        v_concession := COALESCE((v_item->>'concession')::numeric, 0);

        IF v_amount < 0 OR v_concession < 0 THEN
            RAISE EXCEPTION 'Amount and concession cannot be negative.';
        END IF;
        IF v_amount = 0 AND v_concession = 0 THEN
            CONTINUE;   -- nothing to do for this line
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

    IF v_cash_total <= 0 AND v_conc_total <= 0 THEN
        RAISE EXCEPTION 'Nothing to collect.';
    END IF;

    -- Receipt number: RCP-<year>-<seq>
    INSERT INTO core.receipt_counters (tenant_id, school_id, fin_year, last_seq)
    VALUES (p_tenant_id, p_school_id, v_year, 1)
    ON CONFLICT (tenant_id, school_id, fin_year)
    DO UPDATE SET last_seq = core.receipt_counters.last_seq + 1
    RETURNING last_seq INTO v_seq;

    v_receipt := 'RCP-' || v_year || '-' || lpad(v_seq::text, 4, '0');

    INSERT INTO core.fee_payments
        (tenant_id, school_id, student_id, receipt_no, amount, concession_total,
         payment_mode, reference_no, remarks, payment_date, created_by)
    VALUES
        (p_tenant_id, p_school_id, p_student_id, v_receipt, v_cash_total, v_conc_total,
         p_payment_mode, NULLIF(trim(p_reference_no), ''), NULLIF(trim(p_remarks), ''),
         v_date, p_action_user_id)
    RETURNING payment_id INTO v_payment_id;

    -- Apply each line to its ledger row and record the receipt line.
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
            (payment_id, ledger_id, fee_head_name, installment_label, amount, concession)
        VALUES
            (v_payment_id, v_ledger_id, r_ledger.fee_head_name, r_ledger.installment_label,
             v_amount, v_concession);
    END LOOP;

    OPEN p_result FOR
    SELECT TRUE         AS success,
           'Payment recorded.' AS message,
           v_receipt    AS receipt_no,
           v_cash_total AS amount,
           v_conc_total AS concession_total,
           v_date       AS payment_date;
END;
$procedure$;

-- ── 5. Payment history for a student ────────────────────────────────────────
CREATE OR REPLACE PROCEDURE core.sp_fee_payment_history_get(
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
    SELECT receipt_no,
           payment_date,
           amount,
           concession_total,
           payment_mode,
           reference_no
    FROM core.fee_payments
    WHERE tenant_id = p_tenant_id
      AND school_id = p_school_id
      AND student_id = p_student_id
      AND is_active = TRUE
    ORDER BY payment_date DESC, payment_id DESC;
END;
$procedure$;

-- ── 6. One receipt + its line items (for re-print) ──────────────────────────
-- Returns two result sets: [0] the receipt header (with student details),
-- [1] the receipt lines.
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
           s.student_name,
           s.admission_no,
           s.class_name,
           s.section,
           s.roll_no
    FROM core.fee_payments p
    JOIN core.students s ON s.student_id = p.student_id
    WHERE p.payment_id = v_payment_id;

    OPEN p_lines FOR
    SELECT fee_head_name,
           installment_label,
           amount,
           concession
    FROM core.fee_payment_details
    WHERE payment_id = v_payment_id
    ORDER BY detail_id;
END;
$procedure$;
