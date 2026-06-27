-- ============================================================================
-- Fee DAY CLOSE / shift reconciliation — ERP → Fee → Day Close
--
-- A cashier reconciles their day: the system totals the day's collection
-- mode-wise (Cash / UPI / Card / Cheque …, cancelled receipts excluded) and the
-- day's refunds, works out the EXPECTED cash in the drawer (cash collected −
-- cash refunded), the cashier enters the COUNTED cash, and the difference is
-- recorded. One close row per cashier per day (re-closing updates it).
--
-- Scope = the logged-in cashier's own receipts/refunds for the chosen date
-- (created_by / refunded_by = the action user).
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── 1. Day-close record ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS core.fee_day_close
(
    close_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       integer       NOT NULL,
    school_id       integer       NOT NULL,
    close_date      date          NOT NULL,
    cashier_id      integer       NOT NULL,
    total_collected numeric(12,2) NOT NULL DEFAULT 0,
    total_refunded  numeric(12,2) NOT NULL DEFAULT 0,
    expected_cash   numeric(12,2) NOT NULL DEFAULT 0,
    counted_cash    numeric(12,2) NOT NULL DEFAULT 0,
    difference      numeric(12,2) NOT NULL DEFAULT 0,
    mode_breakup    jsonb,
    remarks         varchar(250),
    closed_by       integer       NOT NULL,
    closed_at       timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT chk_fee_day_close_scope CHECK ((tenant_id > 1) AND (school_id > 0)),
    CONSTRAINT uq_fee_day_close UNIQUE (tenant_id, school_id, close_date, cashier_id)
);

-- ── 2. Day collection summary + mode-wise breakup ───────────────────────────
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
        (SELECT COALESCE(SUM(amount),0) FROM core.fee_payments
           WHERE tenant_id=p_tenant_id AND school_id=p_school_id AND created_by=p_action_user_id
             AND payment_date=v_date AND is_cancelled=FALSE AND payment_mode='Cash')           AS cash_collected,
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
    SELECT payment_mode, SUM(amount) AS amount, COUNT(*) AS cnt
    FROM core.fee_payments
    WHERE tenant_id=p_tenant_id AND school_id=p_school_id AND created_by=p_action_user_id
      AND payment_date=v_date AND is_cancelled=FALSE
    GROUP BY payment_mode
    ORDER BY payment_mode;
END;
$procedure$;

-- ── 3. Close the day (upsert reconciliation) ────────────────────────────────
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

    SELECT COALESCE(SUM(amount),0),
           COALESCE(SUM(amount) FILTER (WHERE payment_mode='Cash'),0)
      INTO v_collected, v_cash_collected
    FROM core.fee_payments
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

    v_modes := (SELECT jsonb_agg(jsonb_build_object('mode', payment_mode, 'amount', amt))
                FROM (SELECT payment_mode, SUM(amount) AS amt
                      FROM core.fee_payments
                      WHERE tenant_id=p_tenant_id AND school_id=p_school_id AND created_by=p_action_user_id
                        AND payment_date=v_date AND is_cancelled=FALSE
                      GROUP BY payment_mode) t);

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
