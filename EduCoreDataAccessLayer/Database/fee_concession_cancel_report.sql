-- ============================================================================
-- Fee Reports — Concession & Cancellation register (audit)
--   • Concessions: active receipts that carried a discount/waiver in the range.
--   • Cancellations: receipts voided in the range (with reason + authoriser).
-- One proc, two result sets. Read-only. Safe to re-run.
-- ============================================================================
CREATE OR REPLACE PROCEDURE core.sp_fee_concession_cancel_register(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_from           date,
    IN    p_to             date,
    INOUT p_concessions    refcursor DEFAULT 'concessions_cursor'::refcursor,
    INOUT p_cancels        refcursor DEFAULT 'cancels_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_from date := COALESCE(p_from, CURRENT_DATE);
    v_to   date := COALESCE(p_to,   CURRENT_DATE);
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;

    OPEN p_concessions FOR
    SELECT p.receipt_no, p.payment_date, p.concession_total,
           p.discount_type, p.discount_value, p.discount_reason,
           COALESCE(s.student_name, '—') AS student_name,
           COALESCE(s.admission_no, '—') AS admission_no
    FROM core.fee_payments p
    LEFT JOIN core.students s ON s.student_id = p.student_id
    WHERE p.tenant_id = p_tenant_id AND p.school_id = p_school_id
      AND p.is_cancelled = FALSE AND p.concession_total > 0
      AND p.payment_date BETWEEN v_from AND v_to
    ORDER BY p.payment_date, p.payment_id;

    OPEN p_cancels FOR
    SELECT p.receipt_no, p.payment_date, p.amount,
           p.cancel_reason, p.cancel_authorized_by, p.cancelled_at,
           COALESCE(s.student_name, '—') AS student_name,
           COALESCE(s.admission_no, '—') AS admission_no
    FROM core.fee_payments p
    LEFT JOIN core.students s ON s.student_id = p.student_id
    WHERE p.tenant_id = p_tenant_id AND p.school_id = p_school_id
      AND p.is_cancelled = TRUE
      AND p.cancelled_at::date BETWEEN v_from AND v_to
    ORDER BY p.cancelled_at DESC;
END;
$procedure$;
