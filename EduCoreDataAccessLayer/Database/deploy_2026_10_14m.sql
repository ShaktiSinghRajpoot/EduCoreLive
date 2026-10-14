-- Bundle 2026-10-14m: QA round 3, batch 2a (day close remark, refunds only refundable heads, exit message amounts). Run with:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_14m.sql
-- Sources (re-runnable): fee_day_close.sql, fee_refund.sql, student_exit.sql

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
    ORDER BY (dc.reopened_at IS NULL) DESC, dc.closed_at DESC;
END;
$procedure$;


-- ============================================================================
-- Fee REFUND — ERP → Fee → Manage Fee → Payment History → Refund
--
-- Returns money the school is holding: a refundable deposit at TC time, an
-- over-collected amount, or the student's ADVANCE (wallet) balance at exit.
-- A refund is money OUT — it never creates a new "due". It is recorded as a
-- refund voucher (core.fee_refunds) and:
--   • against a charge: increments the ledger row's refund_amount, so the same
--     money can't be refunded twice (the charge stays paid);
--   • against the wallet (p_ledger_id = 0): debits core.student_advance. The
--     voucher has ledger_id NULL, which is how a wallet refund is recognised.
--
-- Voucher numbers are RFD-YYYY-NNNN, one gapless sequence per school per year
-- (kept in core.receipt_counters under fin_year 'RFD-YYYY'). Older vouchers
-- used the global refund_id; the sequence is seeded past them, so nothing clashes.
--
-- Needs core.fn_user_display_name (fee_advance.sql), core.fn_fee_day_closed
-- (fee_day_close.sql) and student_ledger.fee_head_id (student_money_lifecycle.sql).
-- A cashier who has closed today cannot refund until an admin re-opens the day.
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── 1. How much of a paid row has been refunded ─────────────────────────────
ALTER TABLE core.student_ledger
    ADD COLUMN IF NOT EXISTS refund_amount numeric(12,2) NOT NULL DEFAULT 0;

-- ── 2. Refund voucher record ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS core.fee_refunds
(
    refund_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     integer       NOT NULL,
    school_id     integer       NOT NULL,
    student_id    integer       NOT NULL,
    ledger_id     integer,                       -- the paid charge; NULL = advance wallet
    refund_no     varchar(40),                   -- RFD-YYYY-NNNN
    amount        numeric(12,2) NOT NULL,
    refund_mode   varchar(30)   NOT NULL,
    reason        varchar(250)  NOT NULL,
    authorized_by varchar(80),
    refunded_by   integer       NOT NULL,
    refunded_at   timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT chk_fee_refunds_scope CHECK ((tenant_id > 1) AND (school_id > 0)),
    CONSTRAINT uq_fee_refunds_no UNIQUE (tenant_id, school_id, refund_no)
);

CREATE INDEX IF NOT EXISTS idx_fee_refunds_student ON core.fee_refunds(student_id);

-- ── 3. Is a ledger row's fee head refundable? ───────────────────────────────
-- By the head's ID: the ledger row's own fee_head_id first, then the student's
-- fee plan (which also carries fee_head_id), and only for old rows with
-- neither, the school's live head of that name. A plain name join matched
-- deleted heads too, and returned the row twice when an old head shared the name.
CREATE OR REPLACE FUNCTION core.fn_ledger_head_refundable(p_ledger_id integer)
RETURNS boolean
LANGUAGE sql
STABLE
AS $function$
    SELECT COALESCE(
             (SELECT h.is_refundable
                FROM core.school_fee_heads h
               WHERE h.fee_head_id = l.fee_head_id),
             (SELECT h.is_refundable
                FROM core.student_fee_plan fp
                JOIN core.school_fee_heads h ON h.fee_head_id = fp.fee_head_id
               WHERE fp.tenant_id = l.tenant_id AND fp.school_id = l.school_id
                 AND fp.student_id = l.student_id
                 AND lower(fp.fee_head_name) = lower(l.fee_head_name)
               ORDER BY fp.fee_plan_id DESC
               LIMIT 1),
             (SELECT h.is_refundable
                FROM core.school_fee_heads h
               WHERE h.tenant_id = l.tenant_id AND h.school_id = l.school_id
                 AND lower(h.fee_head_name) = lower(l.fee_head_name)
                 AND COALESCE(h.is_deleted, FALSE) = FALSE
               LIMIT 1),
             FALSE)
      FROM core.student_ledger l
     WHERE l.ledger_id = p_ledger_id;
$function$;

-- ── 4. What can be refunded for a student ───────────────────────────────────
-- Any paid row that still has retained cash (amount_paid − refund_amount > 0),
-- refundable-deposit heads first, plus the advance wallet when it holds money
-- (ledger_id NULL, fee_head_name 'Advance balance').
CREATE OR REPLACE PROCEDURE core.sp_student_refundables_get(
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
    SELECT ledger_id, fee_head_name, installment_label, amount_paid, refund_amount, refundable, is_refundable
    FROM (
        SELECT sl.ledger_id,
               sl.fee_head_name,
               sl.installment_label,
               sl.amount_paid,
               sl.refund_amount,
               (sl.amount_paid - sl.refund_amount)                           AS refundable,
               COALESCE(core.fn_ledger_head_refundable(sl.ledger_id), FALSE) AS is_refundable,
               1 AS grp, sl.due_date
        FROM core.student_ledger sl
        WHERE sl.tenant_id  = p_tenant_id
          AND sl.school_id  = p_school_id
          AND sl.student_id = p_student_id
          AND (sl.amount_paid - sl.refund_amount) > 0
          -- only heads marked Refundable (deposits); tuition, admission etc. are not
          -- handed back — a wrong receipt is cancelled instead (QA BUG-083)
          AND COALESCE(core.fn_ledger_head_refundable(sl.ledger_id), FALSE)

        UNION ALL

        SELECT NULL::integer, 'Advance balance'::varchar, NULL::varchar,
               a.balance, 0::numeric, a.balance, TRUE, 0 AS grp, NULL::varchar
        FROM core.student_advance a
        WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
          AND a.student_id = p_student_id AND a.balance > 0
    ) x
    ORDER BY is_refundable DESC, grp, due_date NULLS LAST, ledger_id;
END;
$procedure$;

-- ── 5. Record a refund ──────────────────────────────────────────────────────
-- p_ledger_id > 0 refunds a paid charge; p_ledger_id = 0 refunds the wallet.
CREATE OR REPLACE PROCEDURE core.sp_fee_refund_record(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_student_id     integer,
    IN    p_ledger_id      integer,
    IN    p_amount         numeric,
    IN    p_mode           varchar,
    IN    p_reason         varchar,
    IN    p_authorized_by  varchar,
    INOUT p_result         refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_retained numeric(12,2);
    v_no       varchar(40);
    v_key      varchar(12);
    v_seq      integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR p_student_id <= 0 OR p_ledger_id IS NULL OR p_ledger_id < 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Refund amount must be greater than zero.';
    END IF;
    -- 0.004 used to pass the > 0 test and then round to a 0.00 voucher.
    IF p_amount <> ROUND(p_amount, 2) THEN
        RAISE EXCEPTION 'Refund amount can have at most two decimal places.';
    END IF;
    IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
        RAISE EXCEPTION 'A reason is required to refund.';
    END IF;

    -- Money going out today belongs to today's close for this cashier.
    IF core.fn_fee_day_closed(p_tenant_id, p_school_id, p_action_user_id, CURRENT_DATE) THEN
        RAISE EXCEPTION 'Today is already closed for this counter. Ask an admin to re-open the day first.';
    END IF;

    IF p_ledger_id = 0 THEN
        -- The advance wallet. Lock it so two refunds can't both spend it.
        SELECT balance INTO v_retained
        FROM core.student_advance
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND student_id = p_student_id
        FOR UPDATE;
        v_retained := COALESCE(v_retained, 0);
        IF v_retained <= 0 THEN
            OPEN p_result FOR SELECT FALSE AS success, 'There is no advance balance to refund.' AS message, NULL::varchar AS refund_no;
            RETURN;
        END IF;
    ELSE
        -- Lock the paid row so the retained amount can't be refunded twice.
        SELECT amount_paid - refund_amount INTO v_retained
        FROM core.student_ledger
        WHERE ledger_id = p_ledger_id
          AND tenant_id = p_tenant_id AND school_id = p_school_id AND student_id = p_student_id
        FOR UPDATE;

        IF NOT FOUND THEN
            OPEN p_result FOR SELECT FALSE AS success, 'Charge not found.' AS message, NULL::varchar AS refund_no;
            RETURN;
        END IF;
        IF NOT COALESCE(core.fn_ledger_head_refundable(p_ledger_id), FALSE) THEN
            OPEN p_result FOR SELECT FALSE AS success,
                   'This fee is not refundable. Mark its fee head as refundable, or cancel the receipt if it was taken by mistake.' AS message,
                   NULL::varchar AS refund_no;
            RETURN;
        END IF;
    END IF;

    IF p_amount > v_retained + 0.001 THEN
        OPEN p_result FOR SELECT FALSE AS success,
               'Amount exceeds the refundable balance (' || to_char(v_retained, 'FM999999990.00') || ').' AS message,
               NULL::varchar AS refund_no;
        RETURN;
    END IF;

    -- Per-school, per-year voucher sequence. The first time a school/year is
    -- used, start after any older voucher number already taken for it.
    v_key := 'RFD-' || to_char(CURRENT_DATE, 'YYYY');
    INSERT INTO core.receipt_counters (tenant_id, school_id, fin_year, last_seq)
    VALUES (p_tenant_id, p_school_id, v_key,
            1 + COALESCE((SELECT MAX(split_part(refund_no, '-', 3)::integer)
                            FROM core.fee_refunds
                           WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                             AND refund_no LIKE v_key || '-%'
                             AND split_part(refund_no, '-', 3) ~ '^\d+$'), 0))
    ON CONFLICT (tenant_id, school_id, fin_year)
    DO UPDATE SET last_seq = core.receipt_counters.last_seq + 1
    RETURNING last_seq INTO v_seq;

    v_no := v_key || '-' || lpad(v_seq::text, 4, '0');

    INSERT INTO core.fee_refunds
        (tenant_id, school_id, student_id, ledger_id, refund_no, amount, refund_mode, reason, authorized_by, refunded_by)
    VALUES
        (p_tenant_id, p_school_id, p_student_id, NULLIF(p_ledger_id, 0), v_no, p_amount,
         COALESCE(NULLIF(trim(p_mode), ''), 'Cash'), trim(p_reason), NULLIF(trim(p_authorized_by), ''), p_action_user_id);

    IF p_ledger_id = 0 THEN
        UPDATE core.student_advance
           SET balance = balance - p_amount, updated_at = NOW()
         WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND student_id = p_student_id;
    ELSE
        UPDATE core.student_ledger
        SET refund_amount = refund_amount + p_amount,
            updated_at    = NOW()
        WHERE ledger_id = p_ledger_id;
    END IF;

    OPEN p_result FOR
    SELECT TRUE AS success,
           'Refund ' || v_no || ' recorded. ' || to_char(p_amount, 'FM999999990.00') || ' returned.' AS message,
           v_no AS refund_no;
END;
$procedure$;

-- ── 6. A student's refund vouchers (Payment History) ────────────────────────
-- Refunds are money out, and the family's history must show them beside the
-- receipts. Kept as its own proc so the receipt-history cursor is unchanged.
CREATE OR REPLACE PROCEDURE core.sp_fee_refund_history_get(
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
    SELECT r.refund_no,
           to_char(r.refunded_at, 'YYYY-MM-DD')     AS refund_date,
           r.refunded_at,
           r.amount,
           r.refund_mode,
           r.reason,
           r.authorized_by,
           core.fn_user_display_name(r.refunded_by) AS refunded_by_name,
           CASE WHEN r.ledger_id IS NULL THEN 'Advance balance'
                ELSE COALESCE(sl.fee_head_name || COALESCE(' — ' || sl.installment_label, ''), 'Charge')
           END                                      AS against
    FROM core.fee_refunds r
    LEFT JOIN core.student_ledger sl ON sl.ledger_id = r.ledger_id
    WHERE r.tenant_id = p_tenant_id AND r.school_id = p_school_id AND r.student_id = p_student_id
    ORDER BY r.refunded_at DESC, r.refund_id DESC;
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
    v_restored := core.fn_student_restore_closed_dues(p_tenant_id, p_school_id, p_student_id, 'Exit');

    -- The bus assignment the exit ended (the latest one), if it was not
    -- replaced by another since.
    SELECT assignment_id INTO v_assign
      FROM core.student_transport
     WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
       AND is_active = FALSE AND COALESCE(is_deleted, FALSE) = FALSE
       AND end_reason LIKE 'Left on %'
     ORDER BY assignment_id DESC
     LIMIT 1;

    IF v_assign IS NOT NULL AND NOT EXISTS (
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


