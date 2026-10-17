-- Bundle 2026-10-17l: fee receipt prints the class of the session it was paid in, the session, and each line's session
-- ("(2027-28)" / "(Dues of 2025-26)"). Only core.sp_fee_receipt_get from fee_advance.sql. Run with:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_17l.sql

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
    WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND receipt_no = p_receipt_no;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Receipt not found.';
    END IF;

    OPEN p_header FOR
    SELECT p.receipt_no, p.payment_date, p.amount, p.concession_total, p.payment_mode,
           p.reference_no, p.remarks, p.payment_type,
           p.discount_type, p.discount_value, p.discount_reason, p.discount_approved_by,
           COALESCE(p.discount_amount, 0) AS discount_amount,
           p.advance_used, p.advance_credit,
           -- Who the receipt is FOR.
           COALESCE(p.student_id, 0) AS student_id,
           COALESCE(p.enquiry_id, 0) AS enquiry_id,
           COALESCE(s.student_name, e.student_name, 'Student') AS student_name,
           COALESCE(s.admission_no, '-')                       AS admission_no,
           -- the class of the session the payment was made in (core.student_enrolment):
           -- a child promoted early is still in the old class until that session ends
           COALESCE(en.class_name, s.class_name, e.class_name, '-') AS class_name,
           COALESCE(en.section, s.section) AS section,
           COALESCE(NULLIF(trim(en.roll_no), ''), s.roll_no) AS roll_no,
           CASE WHEN en.student_id IS NOT NULL THEN ses.yr END AS session,   -- only when the child was enrolled in it
           -- Who took it, and when.
           p.created_by,
           core.fn_user_display_name(p.created_by)             AS collected_by,
           p.created_at,
           -- Voided?
           p.is_cancelled,
           p.cancel_reason,
           p.cancel_authorized_by,
           p.cancelled_at,
           core.fn_user_display_name(p.cancelled_by)           AS cancelled_by_name,
           -- How it was paid, mode by mode.
           COALESCE((SELECT jsonb_agg(jsonb_build_object('mode', t.mode, 'amount', t.amount,
                                                         'reference', t.reference)
                                      ORDER BY t.tender_id)
                       FROM core.fee_payment_tenders t
                      WHERE t.payment_id = p.payment_id), '[]'::jsonb)::text AS tenders
    FROM core.fee_payments p
    LEFT JOIN core.students  s ON s.student_id = p.student_id
    LEFT JOIN core.enquiries e ON e.enquiry_id = p.enquiry_id
    LEFT JOIN LATERAL (SELECT core.fn_session_on(p.tenant_id, p.school_id, p.payment_date::date) AS yr) ses ON TRUE
    LEFT JOIN core.student_enrolment en ON en.student_id = p.student_id AND en.academic_year = ses.yr
    WHERE p.payment_id = v_payment_id;

    -- each line's session, and where Year-End carried it from (the receipt marks
    -- a fee of another session, e.g. "Dues of 2025-26")
    OPEN p_lines FOR
    SELECT d.fee_head_name, d.installment_label, d.amount, d.concession, d.line_type,
           l.academic_year, l.carried_from
    FROM core.fee_payment_details d
    LEFT JOIN core.student_ledger l ON l.ledger_id = d.ledger_id
    WHERE d.payment_id = v_payment_id
    ORDER BY d.detail_id;
END;
$procedure$;
