-- ============================================================================
-- Fee REFUND — ERP → Fee → Manage Fee → Payment History → Refund
--
-- Returns money the school is holding: a refundable deposit at TC time, or an
-- over-collected amount. A refund is money OUT — it never creates a new "due".
-- It is recorded as a refund voucher (core.fee_refunds) and increments the paid
-- ledger row's refund_amount so the same money can't be refunded twice. The
-- charge stays paid; refund_amount tracks how much of that cash was returned.
--
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
    ledger_id     integer,                       -- the paid charge being refunded
    refund_no     varchar(40),                   -- RFD-YYYY-NNNN (set just after insert)
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

-- ── 3. What can be refunded for a student ───────────────────────────────────
-- Any paid row that still has retained cash (amount_paid − refund_amount > 0).
-- Refundable-deposit heads are surfaced first.
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
    SELECT sl.ledger_id,
           sl.fee_head_name,
           sl.installment_label,
           sl.amount_paid,
           sl.refund_amount,
           (sl.amount_paid - sl.refund_amount) AS refundable,
           COALESCE(fh.is_refundable, FALSE)   AS is_refundable
    FROM core.student_ledger sl
    LEFT JOIN core.school_fee_heads fh
           ON fh.tenant_id = sl.tenant_id AND fh.school_id = sl.school_id
          AND fh.fee_head_name = sl.fee_head_name
    WHERE sl.tenant_id  = p_tenant_id
      AND sl.school_id  = p_school_id
      AND sl.student_id = p_student_id
      AND (sl.amount_paid - sl.refund_amount) > 0
    ORDER BY COALESCE(fh.is_refundable, FALSE) DESC, sl.due_date NULLS LAST, sl.ledger_id;
END;
$procedure$;

-- ── 4. Record a refund ──────────────────────────────────────────────────────
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
    v_id       integer;
    v_no       varchar(40);
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR p_student_id <= 0 OR p_ledger_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Refund amount must be greater than zero.';
    END IF;
    IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
        RAISE EXCEPTION 'A reason is required to refund.';
    END IF;

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
    IF p_amount > v_retained + 0.001 THEN
        OPEN p_result FOR SELECT FALSE AS success,
               'Amount exceeds the refundable balance (' || to_char(v_retained, 'FM999999990.00') || ').' AS message,
               NULL::varchar AS refund_no;
        RETURN;
    END IF;

    INSERT INTO core.fee_refunds
        (tenant_id, school_id, student_id, ledger_id, refund_no, amount, refund_mode, reason, authorized_by, refunded_by)
    VALUES
        (p_tenant_id, p_school_id, p_student_id, p_ledger_id, NULL, p_amount,
         COALESCE(NULLIF(trim(p_mode), ''), 'Cash'), trim(p_reason), NULLIF(trim(p_authorized_by), ''), p_action_user_id)
    RETURNING refund_id INTO v_id;

    v_no := 'RFD-' || to_char(CURRENT_DATE, 'YYYY') || '-' || lpad(v_id::text, 4, '0');
    UPDATE core.fee_refunds SET refund_no = v_no WHERE refund_id = v_id;

    UPDATE core.student_ledger
    SET refund_amount = refund_amount + p_amount,
        updated_at    = NOW()
    WHERE ledger_id = p_ledger_id;

    OPEN p_result FOR
    SELECT TRUE AS success,
           'Refund ' || v_no || ' recorded. ' || to_char(p_amount, 'FM999999990.00') || ' returned.' AS message,
           v_no AS refund_no;
END;
$procedure$;
