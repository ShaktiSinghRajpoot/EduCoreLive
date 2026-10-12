-- ============================================================================
-- Fee Reports — Concession & Cancellation register (audit)
--   • Concessions: every receipt issued in the range that carried a discount,
--     concession or waiver -- fee counter concessions (concession_total) AND
--     registration discounts (discount_amount) -- with who gave it. A receipt
--     cancelled later stays listed, flagged, so a past range never changes;
--     the page totals only the live ones.
--   • Cancellations: receipts voided in the range, with reason, authoriser and
--     the USER who cancelled (the authoriser is free text; the user is not).
-- Blank range = month to date, the same default as the other registers.
-- Apply AFTER fee_day_close.sql (fn_user_display_name).
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
    v_from date := COALESCE(p_from, date_trunc('month', CURRENT_DATE)::date);
    v_to   date := COALESCE(p_to,   CURRENT_DATE);
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;

    OPEN p_concessions FOR
    SELECT p.receipt_no, p.payment_date, p.concession_total,
           COALESCE(p.concession_total, 0) + COALESCE(p.discount_amount, 0) AS concession_amount,
           COALESCE(NULLIF(TRIM(p.payment_type), ''), 'Fee') AS payment_type,
           p.discount_type, p.discount_value, p.discount_reason,
           p.discount_approved_by,   -- picked by the cashier; given_by_name is who entered it
           COALESCE(p.is_cancelled, FALSE) AS is_cancelled,
           core.fn_user_display_name(p.created_by) AS given_by_name,
           COALESCE(s.student_name, e.student_name, '—') AS student_name,
           COALESCE(s.admission_no,
                    CASE WHEN e.enquiry_id IS NOT NULL
                         THEN COALESCE(NULLIF(e.registration_number, ''), 'Registration') END,
                    '—') AS admission_no
    FROM core.fee_payments p
    LEFT JOIN core.students  s ON s.student_id = p.student_id
    LEFT JOIN core.enquiries e ON e.enquiry_id = p.enquiry_id
    WHERE p.tenant_id = p_tenant_id AND p.school_id = p_school_id
      AND COALESCE(p.concession_total, 0) + COALESCE(p.discount_amount, 0) > 0
      AND p.payment_date BETWEEN to_char(v_from, 'YYYY-MM-DD') AND to_char(v_to, 'YYYY-MM-DD')
    ORDER BY p.payment_date, p.payment_id;

    OPEN p_cancels FOR
    SELECT p.receipt_no, p.payment_date, p.amount,
           p.cancel_reason, p.cancel_authorized_by, p.cancelled_at,
           p.cancelled_by,
           core.fn_user_display_name(p.cancelled_by) AS cancelled_by_name,
           core.fn_user_display_name(p.created_by)   AS collected_by_name,
           COALESCE(s.student_name, e.student_name, '—') AS student_name,
           COALESCE(s.admission_no,
                    CASE WHEN e.enquiry_id IS NOT NULL
                         THEN COALESCE(NULLIF(e.registration_number, ''), 'Registration') END,
                    '—') AS admission_no
    FROM core.fee_payments p
    LEFT JOIN core.students  s ON s.student_id = p.student_id
    LEFT JOIN core.enquiries e ON e.enquiry_id = p.enquiry_id
    WHERE p.tenant_id = p_tenant_id AND p.school_id = p_school_id
      AND p.is_cancelled = TRUE
      AND p.cancelled_at::date BETWEEN v_from AND v_to
    ORDER BY p.cancelled_at DESC;
END;
$procedure$;
