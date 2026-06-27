-- ============================================================================
-- Fee Collection — SPLIT TENDER (multiple payment modes on one receipt)
--
-- A receipt can now be paid with several modes (e.g. ₹5000 Cash + ₹5000 UPI).
-- Each mode+amount is stored in core.fee_payment_tenders. The receipt header
-- keeps a single payment_mode = the lone mode, or 'Mixed' when split.
--
-- core.v_fee_tender_lines expands every receipt into one row per mode (receipts
-- with no tender rows fall back to their header mode/amount), so Day Close and
-- the Collection Register break down by the TRUE mode, not 'Mixed'.
--
-- sp_fee_payment_collect is drop-then-recreated (adds p_tenders) → one overload.
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── 1. Tender rows ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS core.fee_payment_tenders
(
    tender_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    payment_id  integer       NOT NULL REFERENCES core.fee_payments(payment_id) ON DELETE CASCADE,
    mode        varchar(30)   NOT NULL,
    amount      numeric(12,2) NOT NULL,
    reference   varchar(60),
    created_at  timestamptz   NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_fee_payment_tenders_payment ON core.fee_payment_tenders(payment_id);

-- ── 2. Mode-line view (one row per mode per receipt) ────────────────────────
CREATE OR REPLACE VIEW core.v_fee_tender_lines AS
SELECT p.payment_id,
       p.tenant_id,
       p.school_id,
       p.created_by,
       p.payment_date,
       p.is_cancelled,
       COALESCE(t.mode,   p.payment_mode) AS mode,
       COALESCE(t.amount, p.amount)       AS amount
FROM core.fee_payments p
LEFT JOIN core.fee_payment_tenders t ON t.payment_id = p.payment_id;

-- ── 3. Collect proc — now also takes the tender split ───────────────────────
DROP PROCEDURE IF EXISTS core.sp_fee_payment_collect(
    integer, integer, integer, integer, jsonb, jsonb,
    character varying, character varying, character varying, date, character varying,
    character varying, numeric, character varying, refcursor);

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
    v_tender_sum   numeric(12,2) := 0;
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

    -- Resolve the header mode from the tender split (must reconcile to the cash).
    IF v_has_tenders THEN
        SELECT COALESCE(SUM((t->>'amount')::numeric), 0),
               COUNT(DISTINCT t->>'mode') FILTER (WHERE COALESCE((t->>'amount')::numeric,0) > 0)
          INTO v_tender_sum, v_mode_count
        FROM jsonb_array_elements(p_tenders) t;

        IF abs(v_tender_sum - v_cash_total) > 0.01 THEN
            RAISE EXCEPTION 'Payment split (%) does not match the amount collected (%).', v_tender_sum, v_cash_total;
        END IF;

        IF v_mode_count <= 1 THEN
            SELECT NULLIF(trim(t->>'mode'), '') INTO v_mode
            FROM jsonb_array_elements(p_tenders) t
            WHERE COALESCE((t->>'amount')::numeric, 0) > 0
            LIMIT 1;
        ELSE
            v_mode := 'Mixed';
        END IF;
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
         discount_type, discount_value, discount_reason)
    VALUES
        (p_tenant_id, p_school_id, p_student_id, 'Fee', v_receipt, v_cash_total, v_conc_total,
         v_mode, NULLIF(trim(p_reference_no), ''), NULLIF(trim(p_remarks), ''),
         v_date, p_action_user_id,
         CASE WHEN v_conc_total > 0 THEN NULLIF(trim(p_discount_type), '') ELSE NULL END,
         CASE WHEN v_conc_total > 0 THEN COALESCE(p_discount_value, 0) ELSE 0 END,
         CASE WHEN v_conc_total > 0 THEN NULLIF(trim(p_discount_reason), '') ELSE NULL END)
    RETURNING payment_id INTO v_payment_id;

    -- Store the tender split.
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

-- ── 4. Day collection — mode breakup + cash from the tender view ────────────
CREATE OR REPLACE PROCEDURE core.sp_fee_day_collection_get(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_date           date,
    INOUT p_summary        refcursor DEFAULT 'summary_cursor'::refcursor,
    INOUT p_modes          refcursor DEFAULT 'modes_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_date date;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;
    v_date := COALESCE(p_date, CURRENT_DATE);

    OPEN p_summary FOR
    SELECT
        v_date AS close_date,
        (SELECT COALESCE(SUM(amount),0) FROM core.fee_payments
           WHERE tenant_id=p_tenant_id AND school_id=p_school_id AND created_by=p_action_user_id
             AND payment_date=v_date AND is_cancelled=FALSE)                                   AS total_collected,
        (SELECT COUNT(*) FROM core.fee_payments
           WHERE tenant_id=p_tenant_id AND school_id=p_school_id AND created_by=p_action_user_id
             AND payment_date=v_date AND is_cancelled=FALSE)                                   AS receipt_count,
        (SELECT COUNT(*) FROM core.fee_payments
           WHERE tenant_id=p_tenant_id AND school_id=p_school_id AND created_by=p_action_user_id
             AND payment_date=v_date AND is_cancelled=TRUE)                                    AS cancelled_count,
        (SELECT COALESCE(SUM(amount),0) FROM core.v_fee_tender_lines
           WHERE tenant_id=p_tenant_id AND school_id=p_school_id AND created_by=p_action_user_id
             AND payment_date=v_date AND is_cancelled=FALSE AND mode='Cash')                   AS cash_collected,
        (SELECT COALESCE(SUM(amount),0) FROM core.fee_refunds
           WHERE tenant_id=p_tenant_id AND school_id=p_school_id AND refunded_by=p_action_user_id
             AND refunded_at::date=v_date)                                                     AS total_refunded,
        (SELECT COALESCE(SUM(amount),0) FROM core.fee_refunds
           WHERE tenant_id=p_tenant_id AND school_id=p_school_id AND refunded_by=p_action_user_id
             AND refunded_at::date=v_date AND refund_mode='Cash')                              AS cash_refunded,
        (dc.close_id IS NOT NULL)                                                              AS is_closed,
        COALESCE(dc.counted_cash,0)                                                            AS counted_cash,
        COALESCE(dc.difference,0)                                                              AS difference,
        dc.remarks                                                                             AS close_remarks,
        dc.closed_at                                                                           AS closed_at
    FROM (SELECT 1) x
    LEFT JOIN core.fee_day_close dc
           ON dc.tenant_id=p_tenant_id AND dc.school_id=p_school_id
          AND dc.close_date=v_date AND dc.cashier_id=p_action_user_id;

    OPEN p_modes FOR
    SELECT mode AS payment_mode, SUM(amount) AS amount, COUNT(*) AS cnt
    FROM core.v_fee_tender_lines
    WHERE tenant_id=p_tenant_id AND school_id=p_school_id AND created_by=p_action_user_id
      AND payment_date=v_date AND is_cancelled=FALSE
    GROUP BY mode
    ORDER BY mode;
END;
$procedure$;

-- ── 5. Day close — cash + breakup from the tender view ──────────────────────
CREATE OR REPLACE PROCEDURE core.sp_fee_day_close(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_date           date,
    IN    p_counted_cash   numeric,
    IN    p_remarks        varchar,
    INOUT p_result         refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_date           date;
    v_collected      numeric(12,2);
    v_refunded       numeric(12,2);
    v_cash_collected numeric(12,2);
    v_cash_refunded  numeric(12,2);
    v_expected       numeric(12,2);
    v_diff           numeric(12,2);
    v_modes          jsonb;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;
    v_date := COALESCE(p_date, CURRENT_DATE);

    SELECT COALESCE(SUM(amount),0)
      INTO v_collected
    FROM core.fee_payments
    WHERE tenant_id=p_tenant_id AND school_id=p_school_id AND created_by=p_action_user_id
      AND payment_date=v_date AND is_cancelled=FALSE;

    SELECT COALESCE(SUM(amount) FILTER (WHERE mode='Cash'),0)
      INTO v_cash_collected
    FROM core.v_fee_tender_lines
    WHERE tenant_id=p_tenant_id AND school_id=p_school_id AND created_by=p_action_user_id
      AND payment_date=v_date AND is_cancelled=FALSE;

    SELECT COALESCE(SUM(amount),0),
           COALESCE(SUM(amount) FILTER (WHERE refund_mode='Cash'),0)
      INTO v_refunded, v_cash_refunded
    FROM core.fee_refunds
    WHERE tenant_id=p_tenant_id AND school_id=p_school_id AND refunded_by=p_action_user_id
      AND refunded_at::date=v_date;

    v_expected := v_cash_collected - v_cash_refunded;
    v_diff     := COALESCE(p_counted_cash,0) - v_expected;

    v_modes := (SELECT jsonb_agg(jsonb_build_object('mode', mode, 'amount', amt))
                FROM (SELECT mode, SUM(amount) AS amt
                      FROM core.v_fee_tender_lines
                      WHERE tenant_id=p_tenant_id AND school_id=p_school_id AND created_by=p_action_user_id
                        AND payment_date=v_date AND is_cancelled=FALSE
                      GROUP BY mode) t);

    INSERT INTO core.fee_day_close
        (tenant_id, school_id, close_date, cashier_id, total_collected, total_refunded,
         expected_cash, counted_cash, difference, mode_breakup, remarks, closed_by)
    VALUES
        (p_tenant_id, p_school_id, v_date, p_action_user_id, v_collected, v_refunded,
         v_expected, COALESCE(p_counted_cash,0), v_diff, v_modes, NULLIF(trim(p_remarks), ''), p_action_user_id)
    ON CONFLICT (tenant_id, school_id, close_date, cashier_id)
    DO UPDATE SET total_collected = EXCLUDED.total_collected,
                  total_refunded  = EXCLUDED.total_refunded,
                  expected_cash   = EXCLUDED.expected_cash,
                  counted_cash    = EXCLUDED.counted_cash,
                  difference      = EXCLUDED.difference,
                  mode_breakup    = EXCLUDED.mode_breakup,
                  remarks         = EXCLUDED.remarks,
                  closed_by       = EXCLUDED.closed_by,
                  closed_at       = NOW();

    OPEN p_result FOR
    SELECT TRUE AS success,
           'Day ' || to_char(v_date, 'DD Mon YYYY') || ' closed. Expected cash '
             || to_char(v_expected, 'FM999999990.00') || ', difference '
             || to_char(v_diff, 'FM999999990.00') || '.' AS message,
           v_expected AS expected_cash,
           v_diff     AS difference;
END;
$procedure$;

-- ── 6. Collection register — mode breakup from the tender view ──────────────
CREATE OR REPLACE PROCEDURE core.sp_fee_collection_register(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_from           date,
    IN    p_to             date,
    INOUT p_receipts       refcursor DEFAULT 'receipts_cursor'::refcursor,
    INOUT p_modes          refcursor DEFAULT 'modes_cursor'::refcursor,
    INOUT p_heads          refcursor DEFAULT 'heads_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_from date;
    v_to   date;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;
    v_from := COALESCE(p_from, CURRENT_DATE);
    v_to   := COALESCE(p_to,   CURRENT_DATE);

    OPEN p_receipts FOR
    SELECT p.receipt_no, p.payment_date, p.amount, p.payment_mode,
           COALESCE(s.student_name, '—') AS student_name,
           COALESCE(s.admission_no, '—') AS admission_no,
           s.class_name, s.section
    FROM core.fee_payments p
    LEFT JOIN core.students s ON s.student_id = p.student_id
    WHERE p.tenant_id = p_tenant_id AND p.school_id = p_school_id
      AND p.is_cancelled = FALSE
      AND p.payment_date BETWEEN v_from AND v_to
    ORDER BY p.payment_date, p.payment_id;

    OPEN p_modes FOR
    SELECT mode AS payment_mode, COUNT(*) AS cnt, SUM(amount) AS amount
    FROM core.v_fee_tender_lines
    WHERE tenant_id = p_tenant_id AND school_id = p_school_id
      AND is_cancelled = FALSE
      AND payment_date BETWEEN v_from AND v_to
    GROUP BY mode
    ORDER BY mode;

    OPEN p_heads FOR
    SELECT d.fee_head_name, COUNT(*) AS cnt, SUM(d.amount) AS amount
    FROM core.fee_payment_details d
    JOIN core.fee_payments p ON p.payment_id = d.payment_id
    WHERE p.tenant_id = p_tenant_id AND p.school_id = p_school_id
      AND p.is_cancelled = FALSE
      AND p.payment_date BETWEEN v_from AND v_to
    GROUP BY d.fee_head_name
    ORDER BY SUM(d.amount) DESC;
END;
$procedure$;
