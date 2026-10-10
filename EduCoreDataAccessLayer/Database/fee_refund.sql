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
