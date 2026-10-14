-- ============================================================================
-- Fee DAY CLOSE / shift reconciliation — ERP → Fee → Day Close
--
-- A cashier reconciles their day: the system totals the day's collection
-- mode-wise, the day's refunds, works out the EXPECTED cash in the drawer, the
-- cashier enters the COUNTED cash, and the difference is recorded.
--
-- Scope = the logged-in cashier's own drawer for the chosen date.
--
-- THE RULES (2026-10-10, "a closed day never changes"):
--
--   1. Money is read from the TENDERS, not the receipt header. A Cash+UPI
--      receipt puts its cash in the drawer, an overpayment puts the whole
--      amount handed over in the drawer (the surplus goes to the wallet), and
--      a payment from the wallet puts nothing in it. The header only says
--      "Mixed" or the settled amount, which is why expected cash used to be
--      wrong. core.fn_fee_money_lines is the ONE place that turns receipts
--      into money lines; Day Close, the Collection Register and the Dashboard
--      all read it, so they cannot disagree.
--
--   2. A cancellation is a REVERSAL on the day it was cancelled, in the drawer
--      of whoever cancelled it. The original receipt stays on its own day. So
--      cancelling last week's receipt does not rewrite last week -- it shows up
--      today, which is when the money actually went back.
--
--   3. A closed day is LOCKED. core.fn_fee_day_closed tells the collect and
--      cancel procedures to refuse. A close can only be changed by RE-OPENING
--      it (reason required); every close and re-open is kept in
--      core.fee_day_close_log, so an earlier count is never overwritten.
--
--   4. A future date can not be closed, and counted cash can not be negative.
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── 1. Day-close record (one row per cashier per day = the CURRENT state) ───
CREATE TABLE IF NOT EXISTS core.fee_day_close
(
    close_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       integer       NOT NULL,
    school_id       integer       NOT NULL,
    close_date      varchar(10)   NOT NULL,          -- ISO text, like every date column
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

-- A re-opened day keeps its row (so the last count is still visible) but is no
-- longer closed.
ALTER TABLE core.fee_day_close ADD COLUMN IF NOT EXISTS reopened_at   timestamptz;
ALTER TABLE core.fee_day_close ADD COLUMN IF NOT EXISTS reopened_by   integer;
ALTER TABLE core.fee_day_close ADD COLUMN IF NOT EXISTS reopen_reason varchar(250);

-- ── 2. History: every close and every re-open, never updated ───────────────
CREATE TABLE IF NOT EXISTS core.fee_day_close_log
(
    log_id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       integer       NOT NULL,
    school_id       integer       NOT NULL,
    close_date      varchar(10)   NOT NULL,
    cashier_id      integer       NOT NULL,
    action          varchar(10)   NOT NULL,          -- Close | Reopen
    total_collected numeric(12,2) NOT NULL DEFAULT 0,
    total_refunded  numeric(12,2) NOT NULL DEFAULT 0,
    expected_cash   numeric(12,2) NOT NULL DEFAULT 0,
    counted_cash    numeric(12,2) NOT NULL DEFAULT 0,
    difference      numeric(12,2) NOT NULL DEFAULT 0,
    mode_breakup    jsonb,
    note            varchar(250),                    -- close remarks / re-open reason
    action_by       integer       NOT NULL,
    action_at       timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT chk_fee_day_close_log_action CHECK (action IN ('Close', 'Reopen')),
    CONSTRAINT fk_fee_day_close_log_school FOREIGN KEY (tenant_id, school_id)
        REFERENCES core.schools (tenant_id, school_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ix_fee_day_close_log_day
    ON core.fee_day_close_log (tenant_id, school_id, close_date, cashier_id);

-- Closes made before the log existed get their one Close entry, once.
INSERT INTO core.fee_day_close_log
    (tenant_id, school_id, close_date, cashier_id, action, total_collected, total_refunded,
     expected_cash, counted_cash, difference, mode_breakup, note, action_by, action_at)
SELECT dc.tenant_id, dc.school_id, dc.close_date, dc.cashier_id, 'Close', dc.total_collected, dc.total_refunded,
       dc.expected_cash, dc.counted_cash, dc.difference, dc.mode_breakup, dc.remarks, dc.closed_by, dc.closed_at
FROM core.fee_day_close dc
WHERE NOT EXISTS (SELECT 1 FROM core.fee_day_close_log l
                  WHERE l.tenant_id = dc.tenant_id AND l.school_id = dc.school_id
                    AND l.close_date = dc.close_date AND l.cashier_id = dc.cashier_id);

-- ── 3. Is this cashier's day closed? ───────────────────────────────────────
-- Called by the collect and cancel procedures to refuse money into a closed day.
CREATE OR REPLACE FUNCTION core.fn_fee_day_closed(p_tenant_id integer, p_school_id integer,
                                                  p_user_id integer, p_date date)
RETURNS boolean
LANGUAGE sql
STABLE
AS $function$
    SELECT EXISTS (
        SELECT 1 FROM core.fee_day_close dc
        WHERE dc.tenant_id  = p_tenant_id
          AND dc.school_id  = p_school_id
          AND dc.cashier_id = p_user_id
          AND dc.close_date = to_char(COALESCE(p_date, CURRENT_DATE), 'YYYY-MM-DD')
          AND dc.reopened_at IS NULL);
$function$;

-- ── 4. Money lines: receipts and cancellations, by tender ──────────────────
-- One row per piece of money, for every screen that totals collection.
--   entry  'Receipt'      on the receipt's payment_date, for its cashier (+)
--          'Cancellation' on the day it was cancelled, for whoever did it (-)
--   mode   each tender row (Cash / UPI / ... / Advance). A receipt with no
--          tender row (registration fee, older receipts) falls back to its
--          header mode for the money that came in. A surplus credited to the
--          wallet is its own negative 'To wallet' line.
-- So for every receipt the lines sum to fee_payments.amount (what was settled),
-- and the 'Cash' lines are exactly the cash that crossed the counter.
CREATE OR REPLACE FUNCTION core.fn_fee_money_lines(p_tenant_id integer, p_school_id integer,
                                                   p_from date, p_to date)
RETURNS TABLE (payment_id integer, user_id integer, line_date date, entry varchar, mode varchar, amount numeric)
LANGUAGE sql
STABLE
AS $function$
    WITH ev AS (
        SELECT p.payment_id, p.created_by AS user_id, p.payment_date::date AS line_date,
               'Receipt'::varchar AS entry, 1 AS sgn,
               p.amount, p.payment_mode,
               COALESCE(p.advance_used, 0) AS adv_used, COALESCE(p.advance_credit, 0) AS adv_credit
        FROM core.fee_payments p
        WHERE p.tenant_id = p_tenant_id AND p.school_id = p_school_id
          AND p.payment_date BETWEEN to_char(p_from, 'YYYY-MM-DD') AND to_char(p_to, 'YYYY-MM-DD')
        UNION ALL
        SELECT p.payment_id, COALESCE(p.cancelled_by, p.created_by),
               COALESCE(p.cancelled_at::date, p.payment_date::date),
               'Cancellation'::varchar, -1,
               p.amount, p.payment_mode,
               COALESCE(p.advance_used, 0), COALESCE(p.advance_credit, 0)
        FROM core.fee_payments p
        WHERE p.tenant_id = p_tenant_id AND p.school_id = p_school_id
          AND COALESCE(p.is_cancelled, FALSE)
          AND COALESCE(p.cancelled_at::date, p.payment_date::date) BETWEEN p_from AND p_to
    )
    SELECT ev.payment_id, ev.user_id, ev.line_date, ev.entry, t.mode::varchar, ev.sgn * t.amount
    FROM ev JOIN core.fee_payment_tenders t ON t.payment_id = ev.payment_id
    UNION ALL
    SELECT ev.payment_id, ev.user_id, ev.line_date, ev.entry,
           COALESCE(NULLIF(trim(ev.payment_mode), ''), 'Cash')::varchar,
           ev.sgn * (ev.amount - ev.adv_used + ev.adv_credit)
    FROM ev
    WHERE NOT EXISTS (SELECT 1 FROM core.fee_payment_tenders t
                      WHERE t.payment_id = ev.payment_id AND t.mode <> 'Advance')
      AND ev.amount - ev.adv_used + ev.adv_credit <> 0
    UNION ALL
    SELECT ev.payment_id, ev.user_id, ev.line_date, ev.entry, 'To wallet'::varchar, -ev.sgn * ev.adv_credit
    FROM ev
    WHERE ev.adv_credit > 0;
$function$;

-- A display name for an audit column ("who").
-- Same definition as fee_advance.sql (keep the two identical; run order must not matter).
CREATE OR REPLACE FUNCTION core.fn_user_display_name(p_user_id integer)
RETURNS varchar
LANGUAGE sql
STABLE
AS $function$
    SELECT CASE WHEN p_user_id IS NULL THEN NULL ELSE
           COALESCE(
               (SELECT NULLIF(trim(up.full_name), '')
                  FROM core.user_profiles up
                 WHERE up.user_id = p_user_id
                 ORDER BY COALESCE(up.is_deleted, FALSE), up.user_profile_id DESC
                 LIMIT 1),
               (SELECT u.email FROM core.users u WHERE u.user_id = p_user_id),
               'User #' || p_user_id)
           END;
$function$;

-- ── 5. Day collection summary + mode-wise breakup + close history ──────────
-- Signature grew a third cursor (history): drop the two-cursor version first so
-- exactly one overload exists.
DROP PROCEDURE IF EXISTS core.sp_fee_day_collection_get(integer, integer, integer, date, refcursor, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_fee_day_collection_get(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_date           date,
    INOUT p_summary        refcursor DEFAULT 'summary_cursor'::refcursor,
    INOUT p_modes          refcursor DEFAULT 'modes_cursor'::refcursor,
    INOUT p_history        refcursor DEFAULT 'history_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_date date;
    v_iso  varchar(10);
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;
    v_date := COALESCE(p_date, CURRENT_DATE);
    v_iso  := to_char(v_date, 'YYYY-MM-DD');

    OPEN p_summary FOR
    WITH ml AS (SELECT * FROM core.fn_fee_money_lines(p_tenant_id, p_school_id, v_date, v_date))
    SELECT
        v_date AS close_date,
        (SELECT COALESCE(SUM(amount), 0) FROM ml WHERE user_id = p_action_user_id)            AS total_collected,
        (SELECT COUNT(*) FROM core.fee_payments
           WHERE tenant_id = p_tenant_id AND school_id = p_school_id
             AND created_by = p_action_user_id AND payment_date = v_iso)                       AS receipt_count,
        (SELECT COUNT(DISTINCT payment_id) FROM ml
           WHERE user_id = p_action_user_id AND entry = 'Cancellation')                        AS cancelled_count,
        (SELECT COALESCE(-SUM(amount), 0) FROM ml
           WHERE user_id = p_action_user_id AND entry = 'Cancellation')                        AS cancelled_amount,
        (SELECT COALESCE(SUM(amount), 0) FROM ml
           WHERE user_id = p_action_user_id AND mode = 'Cash')                                 AS cash_collected,

        -- The same day for the WHOLE school, every cashier. Not part of this
        -- cashier's reconciliation -- it lets the page explain a zero.
        (SELECT COALESCE(SUM(amount), 0) FROM ml)                                              AS school_collected,
        (SELECT COUNT(*) FROM core.fee_payments
           WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND payment_date = v_iso)  AS school_receipts,

        (SELECT COALESCE(SUM(amount), 0) FROM core.fee_refunds
           WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND refunded_by = p_action_user_id
             AND refunded_at::date = v_date)                                                   AS total_refunded,
        (SELECT COALESCE(SUM(amount), 0) FROM core.fee_refunds
           WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND refunded_by = p_action_user_id
             AND refunded_at::date = v_date
             AND COALESCE(NULLIF(trim(refund_mode), ''), 'Cash') = 'Cash')                     AS cash_refunded,
        (dc.close_id IS NOT NULL AND dc.reopened_at IS NULL)                                   AS is_closed,
        COALESCE(dc.counted_cash, 0)                                                           AS counted_cash,
        COALESCE(dc.difference, 0)                                                             AS difference,
        dc.remarks                                                                             AS close_remarks,
        dc.closed_at                                                                           AS closed_at,
        COALESCE(dc.total_collected, 0)                                                        AS closed_total_collected,
        COALESCE(dc.expected_cash, 0)                                                          AS closed_expected_cash,
        dc.reopened_at                                                                         AS reopened_at,
        dc.reopen_reason                                                                       AS reopen_reason
    FROM (SELECT 1) x
    LEFT JOIN core.fee_day_close dc
           ON dc.tenant_id = p_tenant_id AND dc.school_id = p_school_id
          AND dc.close_date = v_iso AND dc.cashier_id = p_action_user_id;

    -- By TRUE mode. 'To wallet' is the surplus a parent overpaid: it is in the
    -- Cash/UPI line already, so it is taken back out to keep the total = Collected.
    OPEN p_modes FOR
    SELECT ml.mode AS payment_mode, SUM(ml.amount) AS amount, COUNT(DISTINCT ml.payment_id) AS cnt
    FROM core.fn_fee_money_lines(p_tenant_id, p_school_id, v_date, v_date) ml
    WHERE ml.user_id = p_action_user_id
    GROUP BY ml.mode
    HAVING SUM(ml.amount) <> 0
    ORDER BY ml.mode;

    -- Every close and re-open of this drawer for this day, newest first.
    OPEN p_history FOR
    SELECT l.action, l.action_at, core.fn_user_display_name(l.action_by) AS action_by_name,
           l.total_collected, l.expected_cash, l.counted_cash, l.difference, l.note
    FROM core.fee_day_close_log l
    WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
      AND l.close_date = v_iso AND l.cashier_id = p_action_user_id
    ORDER BY l.action_at DESC, l.log_id DESC;
END;
$procedure$;

-- ── 6. Close the day ────────────────────────────────────────────────────────
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
    v_iso            varchar(10);
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
    v_iso  := to_char(v_date, 'YYYY-MM-DD');

    IF v_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'A future date can not be closed.';
    END IF;
    IF p_counted_cash IS NULL OR p_counted_cash < 0 THEN
        RAISE EXCEPTION 'Enter the cash counted in the drawer (zero or more).';
    END IF;
    IF core.fn_fee_day_closed(p_tenant_id, p_school_id, p_action_user_id, v_date) THEN
        RAISE EXCEPTION 'This day is already closed. Re-open it first to record a new count.';
    END IF;

    SELECT COALESCE(SUM(amount), 0),
           COALESCE(SUM(amount) FILTER (WHERE mode = 'Cash'), 0)
      INTO v_collected, v_cash_collected
    FROM core.fn_fee_money_lines(p_tenant_id, p_school_id, v_date, v_date)
    WHERE user_id = p_action_user_id;

    SELECT COALESCE(SUM(amount), 0),
           COALESCE(SUM(amount) FILTER (WHERE COALESCE(NULLIF(trim(refund_mode), ''), 'Cash') = 'Cash'), 0)
      INTO v_refunded, v_cash_refunded
    FROM core.fee_refunds
    WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND refunded_by = p_action_user_id
      AND refunded_at::date = v_date;

    v_expected := v_cash_collected - v_cash_refunded;
    v_diff     := p_counted_cash - v_expected;

    -- A drawer that does not tally needs a reason on record (QA BUG-097).
    IF v_diff <> 0 AND NULLIF(trim(p_remarks), '') IS NULL THEN
        RAISE EXCEPTION 'The cash is % by Rs %. Write a remark explaining the difference.',
            CASE WHEN v_diff < 0 THEN 'short' ELSE 'over' END, to_char(abs(v_diff), 'FM99,99,99,990.00');
    END IF;

    v_modes := (SELECT jsonb_agg(jsonb_build_object('mode', mode, 'amount', amt) ORDER BY mode)
                FROM (SELECT mode, SUM(amount) AS amt
                      FROM core.fn_fee_money_lines(p_tenant_id, p_school_id, v_date, v_date)
                      WHERE user_id = p_action_user_id
                      GROUP BY mode HAVING SUM(amount) <> 0) t);

    -- The current-state row. A re-opened day's row is re-used (its last count is
    -- already in the log), so the unique key still holds.
    INSERT INTO core.fee_day_close
        (tenant_id, school_id, close_date, cashier_id, total_collected, total_refunded,
         expected_cash, counted_cash, difference, mode_breakup, remarks, closed_by)
    VALUES
        (p_tenant_id, p_school_id, v_iso, p_action_user_id, v_collected, v_refunded,
         v_expected, p_counted_cash, v_diff, v_modes, NULLIF(trim(p_remarks), ''), p_action_user_id)
    ON CONFLICT (tenant_id, school_id, close_date, cashier_id)
    DO UPDATE SET total_collected = EXCLUDED.total_collected,
                  total_refunded  = EXCLUDED.total_refunded,
                  expected_cash   = EXCLUDED.expected_cash,
                  counted_cash    = EXCLUDED.counted_cash,
                  difference      = EXCLUDED.difference,
                  mode_breakup    = EXCLUDED.mode_breakup,
                  remarks         = EXCLUDED.remarks,
                  closed_by       = EXCLUDED.closed_by,
                  closed_at       = NOW(),
                  reopened_at     = NULL,
                  reopened_by     = NULL,
                  reopen_reason   = NULL;

    INSERT INTO core.fee_day_close_log
        (tenant_id, school_id, close_date, cashier_id, action, total_collected, total_refunded,
         expected_cash, counted_cash, difference, mode_breakup, note, action_by)
    VALUES
        (p_tenant_id, p_school_id, v_iso, p_action_user_id, 'Close', v_collected, v_refunded,
         v_expected, p_counted_cash, v_diff, v_modes, NULLIF(trim(p_remarks), ''), p_action_user_id);

    OPEN p_result FOR
    SELECT TRUE AS success,
           'Day ' || to_char(v_date, 'DD Mon YYYY') || ' closed. Expected cash Rs '
             || to_char(v_expected, 'FM99,99,99,990.00')
             || CASE WHEN v_diff = 0 THEN ', the drawer tallies.'
                     WHEN v_diff < 0 THEN ', short by Rs ' || to_char(-v_diff, 'FM99,99,99,990.00') || '.'
                     ELSE ', over by Rs ' || to_char(v_diff, 'FM99,99,99,990.00') || '.' END AS message,
           v_expected AS expected_cash,
           v_diff     AS difference;
END;
$procedure$;

-- ── 7. Re-open a closed day ─────────────────────────────────────────────────
-- p_cashier_id is the drawer being re-opened (an admin can re-open another
-- cashier's day). The last count stays in fee_day_close and in the log.
CREATE OR REPLACE PROCEDURE core.sp_fee_day_reopen(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_cashier_id     integer,
    IN    p_date           date,
    IN    p_reason         varchar,
    INOUT p_result         refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_date date;
    v_iso  varchar(10);
    r      core.fee_day_close%ROWTYPE;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR COALESCE(p_cashier_id, 0) <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;
    IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
        RAISE EXCEPTION 'A reason is required to re-open a closed day.';
    END IF;
    v_date := COALESCE(p_date, CURRENT_DATE);
    v_iso  := to_char(v_date, 'YYYY-MM-DD');

    SELECT * INTO r FROM core.fee_day_close
    WHERE tenant_id = p_tenant_id AND school_id = p_school_id
      AND close_date = v_iso AND cashier_id = p_cashier_id AND reopened_at IS NULL
    FOR UPDATE;

    IF NOT FOUND THEN
        OPEN p_result FOR SELECT FALSE AS success, 'This day is not closed.' AS message;
        RETURN;
    END IF;

    UPDATE core.fee_day_close
       SET reopened_at = NOW(), reopened_by = p_action_user_id, reopen_reason = trim(p_reason)
     WHERE close_id = r.close_id;

    INSERT INTO core.fee_day_close_log
        (tenant_id, school_id, close_date, cashier_id, action, total_collected, total_refunded,
         expected_cash, counted_cash, difference, mode_breakup, note, action_by)
    VALUES
        (p_tenant_id, p_school_id, v_iso, p_cashier_id, 'Reopen', r.total_collected, r.total_refunded,
         r.expected_cash, r.counted_cash, r.difference, r.mode_breakup, trim(p_reason), p_action_user_id);

    OPEN p_result FOR
    SELECT TRUE AS success,
           'Day ' || to_char(v_date, 'DD Mon YYYY') || ' re-opened. Close it again after the correction.' AS message;
END;
$procedure$;

-- ── 8. Every counter closed on a date (for re-opening someone else's day) ────
-- Day Close is per cashier, so an admin could not see -- let alone re-open --
-- the drawer an accountant had closed (QA BUG-067). This lists each cashier's
-- close row for the date; the page shows it only to users with fees.reopen,
-- and ReopenDay then passes that row's cashier_id to sp_fee_day_reopen.
-- Counters that took money on the date but were never closed are listed too
-- (closed_at NULL, "Not closed yet"), so the admin sees every drawer -- e.g.
-- the front desk's registration-fee cash (QA BUG-099).
CREATE OR REPLACE PROCEDURE core.sp_fee_day_close_list(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_date           date,
    INOUT p_result         refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_iso varchar(10);
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;
    v_iso := to_char(COALESCE(p_date, CURRENT_DATE), 'YYYY-MM-DD');

    OPEN p_result FOR
    SELECT dc.cashier_id,
           core.fn_user_display_name(dc.cashier_id)  AS cashier_name,
           dc.closed_at, dc.total_collected, dc.expected_cash, dc.counted_cash, dc.difference,
           (dc.reopened_at IS NULL)                  AS is_closed,
           dc.reopened_at,
           core.fn_user_display_name(dc.reopened_by) AS reopened_by_name,
           dc.reopen_reason
    FROM core.fee_day_close dc
    WHERE dc.tenant_id = p_tenant_id AND dc.school_id = p_school_id
      AND dc.close_date = v_iso

    UNION ALL

    -- never closed: what the drawer took today, and the cash it should hold
    SELECT ml.user_id,
           core.fn_user_display_name(ml.user_id),
           NULL::timestamp,
           SUM(ml.amount),
           COALESCE(SUM(ml.amount) FILTER (WHERE ml.mode = 'Cash'), 0)
             - COALESCE((SELECT SUM(r.amount) FROM core.fee_refunds r
                          WHERE r.tenant_id = p_tenant_id AND r.school_id = p_school_id
                            AND r.refunded_by = ml.user_id
                            AND r.refunded_at::date = COALESCE(p_date, CURRENT_DATE)
                            AND COALESCE(NULLIF(trim(r.refund_mode), ''), 'Cash') = 'Cash'), 0),
           0::numeric, 0::numeric,
           FALSE, NULL::timestamp, NULL::varchar, NULL::varchar
    FROM core.fn_fee_money_lines(p_tenant_id, p_school_id, COALESCE(p_date, CURRENT_DATE), COALESCE(p_date, CURRENT_DATE)) ml
    WHERE NOT EXISTS (SELECT 1 FROM core.fee_day_close dc
                      WHERE dc.tenant_id = p_tenant_id AND dc.school_id = p_school_id
                        AND dc.close_date = v_iso AND dc.cashier_id = ml.user_id)
    GROUP BY ml.user_id

    -- not closed first (they need attention), then the latest close
    ORDER BY 3 DESC NULLS FIRST;
END;
$procedure$;
