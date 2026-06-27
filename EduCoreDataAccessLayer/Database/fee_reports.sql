-- ============================================================================
-- Fee REPORTS — ERP → Fee → Reports
--
--   1. Collection Register : every (active) receipt in a date range, plus the
--      totals by payment mode and by fee head. School-wide (all cashiers).
--   2. Defaulters / Outstanding : students who still owe, with class-wise aging
--      (not-yet-due / 0-30 / 31-60 / 60+ days overdue).
--
-- Read-only aggregations over core.fee_payments / fee_payment_details /
-- student_ledger. Cancelled receipts are excluded from all collection figures.
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── 1. Collection register (receipts + mode + head summaries) ───────────────
CREATE OR REPLACE PROCEDURE core.sp_fee_collection_register(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_from           date,
    IN    p_to             date,
    INOUT p_receipts       refcursor DEFAULT 'receipts_cursor'::refcursor,
    INOUT p_modes          refcursor DEFAULT 'modes_cursor'::refcursor,
    INOUT p_heads          refcursor DEFAULT 'heads_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_from date;
    v_to   date;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;
    v_from := COALESCE(p_from, CURRENT_DATE);
    v_to   := COALESCE(p_to,   CURRENT_DATE);

    OPEN p_receipts FOR
    SELECT p.receipt_no,
           p.payment_date,
           p.amount,
           p.payment_mode,
           COALESCE(s.student_name, '—')  AS student_name,
           COALESCE(s.admission_no, '—')  AS admission_no,
           s.class_name,
           s.section
    FROM core.fee_payments p
    LEFT JOIN core.students s ON s.student_id = p.student_id
    WHERE p.tenant_id = p_tenant_id AND p.school_id = p_school_id
      AND p.is_cancelled = FALSE
      AND p.payment_date BETWEEN v_from AND v_to
    ORDER BY p.payment_date, p.payment_id;

    OPEN p_modes FOR
    SELECT payment_mode, COUNT(*) AS cnt, SUM(amount) AS amount
    FROM core.fee_payments
    WHERE tenant_id = p_tenant_id AND school_id = p_school_id
      AND is_cancelled = FALSE
      AND payment_date BETWEEN v_from AND v_to
    GROUP BY payment_mode
    ORDER BY payment_mode;

    OPEN p_heads FOR
    SELECT d.fee_head_name, COUNT(*) AS cnt, SUM(d.amount) AS amount
    FROM core.fee_payment_details d
    JOIN core.fee_payments p ON p.payment_id = d.payment_id
    WHERE p.tenant_id = p_tenant_id AND p.school_id = p_school_id
      AND p.is_cancelled = FALSE
      AND p.payment_date BETWEEN v_from AND v_to
    GROUP BY d.fee_head_name
    ORDER BY SUM(d.amount) DESC;
END;
$procedure$;

-- ── 2. Defaulters / outstanding with aging ──────────────────────────────────
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
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;

    OPEN p_result FOR
    WITH dues AS (
        SELECT sl.student_id,
               (sl.amount_due - sl.amount_paid - sl.concession) AS outstanding,
               sl.due_date
        FROM core.student_ledger sl
        WHERE sl.tenant_id = p_tenant_id AND sl.school_id = p_school_id
          AND sl.amount_due > sl.amount_paid + sl.concession
    )
    SELECT s.student_id,
           s.student_name,
           s.admission_no,
           s.class_name,
           s.section,
           s.roll_no,
           SUM(d.outstanding)                                                                        AS total_outstanding,
           COALESCE(SUM(d.outstanding) FILTER (WHERE d.due_date IS NULL OR d.due_date >= CURRENT_DATE), 0)              AS not_due,
           COALESCE(SUM(d.outstanding) FILTER (WHERE d.due_date < CURRENT_DATE AND (CURRENT_DATE - d.due_date) <= 30), 0) AS d0_30,
           COALESCE(SUM(d.outstanding) FILTER (WHERE (CURRENT_DATE - d.due_date) BETWEEN 31 AND 60), 0)                 AS d31_60,
           COALESCE(SUM(d.outstanding) FILTER (WHERE (CURRENT_DATE - d.due_date) > 60), 0)                             AS d60_plus
    FROM dues d
    JOIN core.students s ON s.student_id = d.student_id
    WHERE (NULLIF(trim(p_class), '')   IS NULL OR s.class_name = p_class)
      AND (NULLIF(trim(p_section), '') IS NULL OR s.section   = p_section)
    GROUP BY s.student_id, s.student_name, s.admission_no, s.class_name, s.section, s.roll_no
    HAVING SUM(d.outstanding) > 0
    ORDER BY SUM(d.outstanding) DESC;
END;
$procedure$;
