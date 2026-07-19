-- ============================================================================
-- Refund register — money OUT, for the Fee Reports screen.
--
-- WHY: the collection register only counts money IN. Without this, a school that
-- refunded ₹5,000 still reads "Total collected ₹39,178", which is wrong. The
-- reports screen pairs this with collections to show a NET figure:
--     Net = Collected − Refunded
--
-- Refunds are keyed to the paid ledger row they reverse (deposit returned at TC
-- time, over-collection returned, etc.) and are never deleted.
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================
CREATE OR REPLACE PROCEDURE core.sp_fee_refund_register(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_from           date      DEFAULT NULL,
    IN    p_to             date      DEFAULT NULL,
    INOUT p_rows           refcursor DEFAULT 'refund_rows_cursor'::refcursor,
    INOUT p_modes          refcursor DEFAULT 'refund_modes_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_from date;
    v_to   date;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    v_from := COALESCE(p_from, date_trunc('month', CURRENT_DATE)::date);
    v_to   := COALESCE(p_to,   CURRENT_DATE);

    OPEN p_rows FOR
    SELECT r.refund_no,
           r.refunded_at,
           r.amount,
           r.refund_mode,
           r.reason,
           r.authorized_by,
           COALESCE(s.student_name, '—') AS student_name,
           COALESCE(s.admission_no, '—') AS admission_no,
           s.class_name,
           s.section,
           -- What the refunded charge was for (the ledger row being reversed).
           l.fee_head_name,
           l.installment_label
    FROM core.fee_refunds r
    LEFT JOIN core.students      s ON s.student_id = r.student_id
    LEFT JOIN core.student_ledger l ON l.ledger_id  = r.ledger_id
    WHERE r.tenant_id = p_tenant_id AND r.school_id = p_school_id
      AND r.refunded_at::date BETWEEN v_from AND v_to
    ORDER BY r.refunded_at DESC;

    -- Mode-wise refund totals — cash refunds must be netted off the cash drawer.
    OPEN p_modes FOR
    SELECT COALESCE(NULLIF(TRIM(r.refund_mode), ''), 'Cash') AS refund_mode,
           COUNT(*)      AS cnt,
           SUM(r.amount) AS amount
    FROM core.fee_refunds r
    WHERE r.tenant_id = p_tenant_id AND r.school_id = p_school_id
      AND r.refunded_at::date BETWEEN v_from AND v_to
    GROUP BY COALESCE(NULLIF(TRIM(r.refund_mode), ''), 'Cash')
    ORDER BY SUM(r.amount) DESC;
END;
$procedure$;
