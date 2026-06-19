-- ============================================================================
-- Student Dues lookup
--  Returns a student's outstanding ledger installments (amount_due > amount_paid)
--  for the Fee Collection counter (ERP → Fee → Manage Fee). Payment recording and
--  ledger allocation already exist in core.sp_fee_payment_record.
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

CREATE OR REPLACE PROCEDURE core.sp_student_dues_get(
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
    SELECT
        ledger_id,
        fee_head_name,
        frequency,
        installment_label,
        due_date,
        amount_due,
        amount_paid,
        (amount_due - amount_paid) AS outstanding
    FROM core.student_ledger
    WHERE tenant_id  = p_tenant_id
      AND school_id  = p_school_id
      AND student_id = p_student_id
      AND amount_due > amount_paid
    ORDER BY due_date NULLS LAST, ledger_id;
END;
$procedure$;
