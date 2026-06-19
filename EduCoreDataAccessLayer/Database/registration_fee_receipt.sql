-- ============================================================================
-- Registration Fee Receipt
--  Lets the registration step record a real payment + receipt (instead of just
--  flipping a "fee paid" boolean). At registration there is no student yet, so a
--  payment can be keyed by enquiry_id instead of student_id, and no ledger
--  allocation is done. Reuses the existing receipt_counters sequence.
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── 1. Allow enquiry-keyed payments on fee_payments ─────────────────────────
ALTER TABLE core.fee_payments
    ALTER COLUMN student_id DROP NOT NULL;

ALTER TABLE core.fee_payments
    ADD COLUMN IF NOT EXISTS enquiry_id   integer,
    ADD COLUMN IF NOT EXISTS payment_type varchar(20) NOT NULL DEFAULT 'Fee';

-- A payment must belong to either a student (fee collection / admission) or an
-- enquiry (registration fee).
ALTER TABLE core.fee_payments DROP CONSTRAINT IF EXISTS chk_fee_payments_subject;
ALTER TABLE core.fee_payments
    ADD CONSTRAINT chk_fee_payments_subject
    CHECK (student_id IS NOT NULL OR enquiry_id IS NOT NULL);

-- ── 2. Record a registration fee → receipt (no ledger, no student) ──────────
CREATE OR REPLACE PROCEDURE core.sp_registration_fee_record(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_enquiry_id     integer,
    IN    p_amount         numeric,
    IN    p_payment_mode   varchar,
    IN    p_reference_no   varchar  DEFAULT NULL,
    IN    p_remarks        varchar  DEFAULT NULL,
    IN    p_payment_date   date     DEFAULT NULL,
    IN    p_fin_year       varchar  DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_seq     integer;
    v_year    varchar(4);
    v_receipt varchar(40);
    v_date    date;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR p_enquiry_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;
    IF COALESCE(p_amount, 0) <= 0 THEN
        RAISE EXCEPTION 'Payment amount must be greater than zero.';
    END IF;

    v_date := COALESCE(p_payment_date, CURRENT_DATE);
    v_year := left(COALESCE(NULLIF(trim(p_fin_year), ''), to_char(v_date, 'YYYY')), 4);

    -- Receipt number: RCP-<year>-<seq> (shared counter with fee payments).
    INSERT INTO core.receipt_counters (tenant_id, school_id, fin_year, last_seq)
    VALUES (p_tenant_id, p_school_id, v_year, 1)
    ON CONFLICT (tenant_id, school_id, fin_year)
    DO UPDATE SET last_seq = core.receipt_counters.last_seq + 1
    RETURNING last_seq INTO v_seq;

    v_receipt := 'RCP-' || v_year || '-' || lpad(v_seq::text, 4, '0');

    INSERT INTO core.fee_payments
        (tenant_id, school_id, student_id, enquiry_id, payment_type, receipt_no,
         amount, payment_mode, reference_no, remarks, payment_date, created_by)
    VALUES
        (p_tenant_id, p_school_id, NULL, p_enquiry_id, 'Registration', v_receipt,
         p_amount, p_payment_mode, NULLIF(trim(p_reference_no), ''),
         NULLIF(trim(p_remarks), ''), v_date, p_action_user_id);

    OPEN p_result FOR
    SELECT TRUE AS success,
           'Registration fee recorded.' AS message,
           v_receipt AS receipt_no,
           p_amount  AS amount,
           v_date    AS payment_date;
END;
$procedure$;
