-- ============================================================================
-- core.sp_student_dues_get -- the fee counter's list of open dues.
--
-- Supersedes the copies in student_dues.sql (old: ignores concession) and
-- fee_collection_full_flow.sql. Same columns as the live version, plus
-- is_refundable so the counter can tag a refundable deposit and keep a
-- discount off it (the collect proc refuses a concession on one anyway).
--
-- Needs core.fn_ledger_head_refundable (fee_refund.sql).
-- Target DB: PostgreSQL. Safe to re-run.
-- ============================================================================

CREATE OR REPLACE PROCEDURE core.sp_student_dues_get(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_student_id     integer,
    INOUT p_result         refcursor DEFAULT 'result_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR p_student_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;

    OPEN p_result FOR
    SELECT
        ledger_id,
        fee_head_name,
        frequency,
        installment_label,
        due_date,
        amount_due,
        amount_paid,
        concession,
        (amount_due - amount_paid - concession) AS outstanding,
        core.fn_ledger_head_refundable(ledger_id) AS is_refundable,
        academic_year            -- the student profile splits dues by session
    FROM core.student_ledger
    WHERE tenant_id  = p_tenant_id
      AND school_id  = p_school_id
      AND student_id = p_student_id
      AND amount_due > amount_paid + concession
    ORDER BY due_date NULLS LAST, ledger_id;
END;
$procedure$;
