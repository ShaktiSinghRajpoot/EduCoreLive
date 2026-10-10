-- ============================================================================
-- Fee REPORTS — ERP → Fee → Reports
--
--   1. Collection Register : receipts and cancellations in a date range, with
--      totals by TRUE payment mode and by fee head. School-wide (all cashiers),
--      optionally for one class / section.
--   2. Defaulters / Outstanding : who owes money that has FALLEN DUE, with
--      aging, plus registration fees part-paid before admission.
--
-- Rules shared with Day Close and the Dashboard (see fee_day_close.sql):
--   * money is read through core.fn_fee_money_lines (tenders, not the header);
--   * a receipt stays on the day it was issued, and a cancellation is a
--     negative line on the day it was cancelled -- so a past range never
--     changes when an old receipt is cancelled.
--
-- Apply AFTER fee_day_close.sql (it defines fn_fee_money_lines).
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── 1. Collection register (receipts + mode + head summaries) ───────────────
-- Grew p_class / p_section: drop the old signature so one overload exists.
DROP PROCEDURE IF EXISTS core.sp_fee_collection_register(integer, integer, integer, date, date, refcursor, refcursor, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_fee_collection_register(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_from           date,
    IN    p_to             date,
    IN    p_class          varchar DEFAULT NULL,
    IN    p_section        varchar DEFAULT NULL,
    INOUT p_receipts       refcursor DEFAULT 'receipts_cursor'::refcursor,
    INOUT p_modes          refcursor DEFAULT 'modes_cursor'::refcursor,
    INOUT p_heads          refcursor DEFAULT 'heads_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_from    date;
    v_to      date;
    v_class   varchar := NULLIF(trim(p_class), '');
    v_section varchar := NULLIF(trim(p_section), '');
    v_reghead varchar;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;
    -- A blank range is the month to date -- the same default as the refund
    -- register, because the page nets one against the other.
    v_from := COALESCE(p_from, date_trunc('month', CURRENT_DATE)::date);
    v_to   := COALESCE(p_to,   CURRENT_DATE);
    -- The school's own name for its registration head, not a hard-coded label.
    v_reghead := core.fn_registration_fee_head_name(p_tenant_id, p_school_id);

    -- The events in range: each receipt on its own day (+), each cancellation
    -- on the day it was cancelled (-). Filtered by the payer's class/section.
    CREATE TEMP TABLE IF NOT EXISTS tmp_reg_ev
        (payment_id integer, sgn integer, line_date date, entry varchar) ON COMMIT DROP;
    TRUNCATE tmp_reg_ev;
    INSERT INTO tmp_reg_ev
    SELECT x.payment_id, x.sgn, x.line_date, x.entry
    FROM (
        SELECT p.payment_id, 1 AS sgn, p.payment_date::date AS line_date, 'Receipt'::varchar AS entry
        FROM core.fee_payments p
        WHERE p.tenant_id = p_tenant_id AND p.school_id = p_school_id
          AND p.payment_date BETWEEN to_char(v_from, 'YYYY-MM-DD') AND to_char(v_to, 'YYYY-MM-DD')
        UNION ALL
        SELECT p.payment_id, -1, COALESCE(p.cancelled_at::date, p.payment_date::date), 'Cancellation'
        FROM core.fee_payments p
        WHERE p.tenant_id = p_tenant_id AND p.school_id = p_school_id
          AND COALESCE(p.is_cancelled, FALSE)
          AND COALESCE(p.cancelled_at::date, p.payment_date::date) BETWEEN v_from AND v_to
    ) x
    JOIN core.fee_payments p ON p.payment_id = x.payment_id
    LEFT JOIN core.students  s ON s.student_id = p.student_id
    LEFT JOIN core.enquiries e ON e.enquiry_id = p.enquiry_id
    WHERE (v_class   IS NULL OR COALESCE(s.class_name, e.class_name) = v_class)
      AND (v_section IS NULL OR lower(COALESCE(s.section, '')) = lower(v_section));

    OPEN p_receipts FOR
    -- A payment belongs to a STUDENT or an ENQUIRY (registration fee taken before
    -- the student exists); name and class come from whichever applies.
    SELECT ev.entry,
           p.receipt_no,
           p.payment_date,
           ev.line_date,
           ev.sgn * p.amount                                      AS amount,
           -- The real split, e.g. "Cash 1200.00 + UPI 800.00", never "Mixed".
           COALESCE((SELECT string_agg(t.mode || ' ' || to_char(t.amount, 'FM999999990.00'), ' + ' ORDER BY t.tender_id)
                       FROM core.fee_payment_tenders t WHERE t.payment_id = p.payment_id),
                    p.payment_mode)                               AS payment_mode,
           COALESCE(NULLIF(TRIM(p.payment_type), ''), 'Fee')      AS payment_type,
           COALESCE(s.student_name, e.student_name, '—')          AS student_name,
           COALESCE(s.admission_no,
                    CASE WHEN e.enquiry_id IS NOT NULL
                         THEN COALESCE(NULLIF(e.registration_number, ''), 'Registration')
                    END,
                    '—')                                          AS admission_no,
           COALESCE(s.class_name, e.class_name)                   AS class_name,
           s.section,
           p.reference_no,
           COALESCE(p.concession_total, 0) + COALESCE(p.discount_amount, 0) AS discount_total,
           COALESCE(
               (SELECT string_agg(DISTINCT d.fee_head_name, ', ' ORDER BY d.fee_head_name)
                FROM core.fee_payment_details d
                WHERE d.payment_id = p.payment_id),
               CASE WHEN p.payment_type = 'Registration' THEN v_reghead END,
               '—')                                               AS fee_heads,
           COALESCE(p.is_cancelled, FALSE)                        AS is_cancelled,
           p.cancelled_at,
           p.cancel_reason,
           core.fn_user_display_name(CASE WHEN ev.sgn = 1 THEN p.created_by
                                          ELSE COALESCE(p.cancelled_by, p.created_by) END) AS cashier_name
    FROM tmp_reg_ev ev
    JOIN core.fee_payments p   ON p.payment_id  = ev.payment_id
    LEFT JOIN core.students  s ON s.student_id  = p.student_id
    LEFT JOIN core.enquiries e ON e.enquiry_id  = p.enquiry_id
    ORDER BY ev.line_date, p.payment_id, ev.sgn DESC;

    -- By TRUE mode (tender lines). 'To wallet' takes an overpaid surplus back
    -- out so the panel sums to the receipts total.
    OPEN p_modes FOR
    SELECT ml.mode AS payment_mode, COUNT(DISTINCT ml.payment_id) AS cnt, SUM(ml.amount) AS amount
    FROM core.fn_fee_money_lines(p_tenant_id, p_school_id, v_from, v_to) ml
    WHERE EXISTS (SELECT 1 FROM tmp_reg_ev ev
                  WHERE ev.payment_id = ml.payment_id AND ev.entry = ml.entry)
    GROUP BY ml.mode
    HAVING SUM(ml.amount) <> 0
    ORDER BY ml.mode;

    -- Head-wise split. Receipt lines (+) and cancelled lines (-). A registration
    -- fee has no detail lines, so the whole receipt is its registration head.
    OPEN p_heads FOR
    SELECT COALESCE(d.fee_head_name,
                    CASE WHEN p.payment_type = 'Registration' THEN v_reghead ELSE 'Other' END) AS fee_head_name,
           COUNT(DISTINCT ev.payment_id)::int                                                AS cnt,
           SUM(ev.sgn * COALESCE(d.amount, p.amount))                                        AS amount
    FROM tmp_reg_ev ev
    JOIN core.fee_payments p ON p.payment_id = ev.payment_id
    LEFT JOIN core.fee_payment_details d ON d.payment_id = ev.payment_id
    GROUP BY 1
    HAVING SUM(ev.sgn * COALESCE(d.amount, p.amount)) <> 0
    ORDER BY SUM(ev.sgn * COALESCE(d.amount, p.amount)) DESC;
END;
$procedure$;

-- ── 2. Defaulters / outstanding with aging ──────────────────────────────────
-- What is OWED is what has fallen due (due_date on or before today; a charge
-- with no date counts as due). Instalments not yet due are shown in their own
-- "Not due" column for planning, but they are not a debt: a family that has
-- paid everything due so far is not a defaulter.
--
-- One rule for students who have left: if they still owe money that fell due,
-- they are listed (status says so), here and on the Fee Due list alike.
--
-- A registration fee part-paid before admission has no ledger yet; its balance
-- is listed as its own row (entry = 'Registration', student_id NULL).
CREATE OR REPLACE PROCEDURE core.sp_fee_defaulters_get(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_class          varchar,
    IN    p_section        varchar,
    INOUT p_result         refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_class   varchar := NULLIF(trim(p_class), '');
    v_section varchar := NULLIF(trim(p_section), '');
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;

    OPEN p_result FOR
    WITH dues AS (
        SELECT sl.student_id,
               (sl.amount_due - sl.amount_paid - COALESCE(sl.concession, 0)) AS outstanding,
               sl.due_date::date AS due_on,
               (sl.due_date IS NULL OR sl.due_date::date <= CURRENT_DATE)    AS is_due
        FROM core.student_ledger sl
        WHERE sl.tenant_id = p_tenant_id AND sl.school_id = p_school_id
          AND sl.amount_due > sl.amount_paid + COALESCE(sl.concession, 0)
    ),
    students AS (
        SELECT 'Student'::varchar AS entry,
               s.student_id,
               s.student_name,
               s.admission_no,
               s.class_name,
               s.section,
               s.roll_no,
               CASE WHEN COALESCE(s.is_active, TRUE) THEN 'Active'
                    ELSE COALESCE(NULLIF(trim(s.status), ''), 'Left') END                          AS student_status,
               COALESCE(SUM(d.outstanding) FILTER (WHERE d.is_due), 0)                             AS total_outstanding,
               COALESCE(SUM(d.outstanding) FILTER (WHERE NOT d.is_due), 0)                         AS not_due,
               COALESCE(SUM(d.outstanding) FILTER (WHERE d.is_due AND (d.due_on IS NULL OR CURRENT_DATE - d.due_on <= 30)), 0) AS d0_30,
               COALESCE(SUM(d.outstanding) FILTER (WHERE d.is_due AND CURRENT_DATE - d.due_on BETWEEN 31 AND 60), 0)          AS d31_60,
               COALESCE(SUM(d.outstanding) FILTER (WHERE d.is_due AND CURRENT_DATE - d.due_on > 60), 0)                      AS d60_plus
        FROM dues d
        JOIN core.students s ON s.student_id = d.student_id
                            AND s.tenant_id = p_tenant_id AND s.school_id = p_school_id
        WHERE (v_class   IS NULL OR s.class_name = v_class)
          AND (v_section IS NULL OR lower(COALESCE(s.section, '')) = lower(v_section))
        GROUP BY s.student_id, s.student_name, s.admission_no, s.class_name, s.section, s.roll_no,
                 s.is_active, s.status
        HAVING COALESCE(SUM(d.outstanding) FILTER (WHERE d.is_due), 0) > 0
    ),
    registrations AS (
        -- Not admitted yet, fee agreed, not fully settled.
        SELECT 'Registration'::varchar AS entry,
               NULL::integer AS student_id,
               e.student_name,
               COALESCE(NULLIF(e.registration_number, ''), 'Registration') AS admission_no,
               e.class_name,
               NULL::varchar AS section,
               NULL::varchar AS roll_no,
               'Registered'::varchar AS student_status,
               b.balance AS total_outstanding,
               0::numeric AS not_due,
               CASE WHEN COALESCE(CURRENT_DATE - b.since, 0) <= 30 THEN b.balance ELSE 0 END AS d0_30,
               CASE WHEN CURRENT_DATE - b.since BETWEEN 31 AND 60 THEN b.balance ELSE 0 END  AS d31_60,
               CASE WHEN CURRENT_DATE - b.since > 60 THEN b.balance ELSE 0 END               AS d60_plus
        FROM core.enquiries e
        CROSS JOIN LATERAL (
            SELECT e.registration_fee_amount
                     - core.fn_registration_fee_settled(p_tenant_id, p_school_id, e.enquiry_id) AS balance,
                   CASE WHEN e.registration_date ~ '^\d{4}-\d{2}-\d{2}'
                        THEN left(e.registration_date, 10)::date
                        ELSE e.created_at::date END AS since
        ) b
        WHERE e.tenant_id = p_tenant_id AND e.school_id = p_school_id
          AND COALESCE(e.is_active, TRUE)
          AND e.admission_id IS NULL
          AND COALESCE(e.registration_fee_amount, 0) > 0
          AND b.balance > 0.005
          AND v_section IS NULL
          AND (v_class IS NULL OR e.class_name = v_class)
    )
    SELECT * FROM students
    UNION ALL
    SELECT * FROM registrations
    ORDER BY total_outstanding DESC, student_name;
END;
$procedure$;
