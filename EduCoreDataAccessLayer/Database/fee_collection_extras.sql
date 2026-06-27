-- ============================================================================
-- Fee Collection — ad-hoc extra charges + payer-agnostic receipt
--
--   1. Receipt lines can now be "extra charges" not tied to a ledger due
--      (e.g. a late fine or a lost-book charge typed at the counter).
--      core.fee_payment_details.ledger_id becomes nullable and gains line_type.
--   2. core.sp_fee_payment_collect accepts an extra-charges array and records
--      each as a detail line (no ledger update), adding it to the receipt total.
--   3. core.sp_fee_receipt_get works for BOTH student-keyed (admission / manage
--      fee) and enquiry-keyed (registration) receipts, so one receipt component
--      serves every flow.
--
-- Target DB: PostgreSQL (educore). Safe to re-run. Builds on fee_collection_full_flow.sql.
-- ============================================================================

-- ── 1. Extra-charge support on receipt lines ────────────────────────────────
ALTER TABLE core.fee_payment_details
    ALTER COLUMN ledger_id DROP NOT NULL;

ALTER TABLE core.fee_payment_details
    ADD COLUMN IF NOT EXISTS line_type varchar(20) NOT NULL DEFAULT 'Due';   -- 'Due' | 'Extra'

-- ── 2. Collect payment — now also takes ad-hoc extra charges ────────────────
-- p_items  : dues picked, e.g. [{ "ledgerId":12, "amount":500, "concession":0 }]
-- p_extras : ad-hoc charges, e.g. [{ "label":"Late fine", "amount":200 }]
-- Receipt total = sum of dues cash + extras. Extras never touch the ledger.
CREATE OR REPLACE PROCEDURE core.sp_fee_payment_collect(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_student_id     integer,
    IN    p_items          jsonb,
    IN    p_extras         jsonb,
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

    -- Validate every line and add up the totals BEFORE writing anything, so a
    -- bad line aborts the whole receipt (all-or-nothing).
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

    -- Receipt number: RCP-<year>-<seq>
    INSERT INTO core.receipt_counters (tenant_id, school_id, fin_year, last_seq)
    VALUES (p_tenant_id, p_school_id, v_year, 1)
    ON CONFLICT (tenant_id, school_id, fin_year)
    DO UPDATE SET last_seq = core.receipt_counters.last_seq + 1
    RETURNING last_seq INTO v_seq;

    v_receipt := 'RCP-' || v_year || '-' || lpad(v_seq::text, 4, '0');

    INSERT INTO core.fee_payments
        (tenant_id, school_id, student_id, payment_type, receipt_no, amount, concession_total,
         payment_mode, reference_no, remarks, payment_date, created_by)
    VALUES
        (p_tenant_id, p_school_id, p_student_id, 'Fee', v_receipt, v_cash_total, v_conc_total,
         p_payment_mode, NULLIF(trim(p_reference_no), ''), NULLIF(trim(p_remarks), ''),
         v_date, p_action_user_id)
    RETURNING payment_id INTO v_payment_id;

    -- Apply each due to its ledger row and record the receipt line.
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

    -- Record ad-hoc extra charges as detail lines (no ledger row).
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

-- ── 3. Payer-agnostic receipt (student OR enquiry) ──────────────────────────
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

    -- Header resolves the payer from whichever key the payment carries: a
    -- student (admission / fee collection) or an enquiry (registration fee).
    OPEN p_header FOR
    SELECT p.receipt_no,
           p.payment_date,
           p.amount,
           p.concession_total,
           p.payment_mode,
           p.reference_no,
           p.remarks,
           p.payment_type,
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
