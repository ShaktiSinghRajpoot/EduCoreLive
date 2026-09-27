-- ============================================================================
-- Registration fee: let a parent pay part of it.
--
-- Until now this was a yes/no. `enquiries.registration_fee_paid` is a boolean,
-- the collected amount was always the full Registration-point total, and
-- sp_registration_fee_record wrote one row to core.fee_payments and nothing
-- else -- no fee_payment_details, no student_ledger. So there was no due, and
-- with no due there was nowhere for a balance to live. A parent who said "I'll
-- pay the rest next week" could not be recorded at all.
--
-- WHY NOT THE LEDGER. The obvious move is to give registration a
-- core.student_ledger row like every other charge. It was measured and rejected:
-- 23 SQL files read that table and 30 places filter on student_id, and at
-- registration there IS no student -- only an enquiry -- so student_id would
-- have to become nullable and every one of those 30 could then silently include
-- or exclude enquiry rows. That is the whole billing core at risk for one small
-- feature.
--
-- WHAT THIS DOES INSTEAD. Two things were already true and do most of the work:
--   * core.fee_payments already carries enquiry_id with a nullable student_id,
--     so registration money already lands in the same table as every other
--     rupee and already shows in the reports. The "history of every
--     transaction" requirement is met by what exists.
--   * Nothing stops an enquiry having several payments -- no unique index.
--
-- So the only thing missing was the agreed amount. That goes on the enquiry.
-- The amount PAID is never stored: it is summed from the receipts each time it
-- is asked for. A stored running total would drift, and would have to be
-- unwound by hand when a receipt is cancelled; derived, cancelling a receipt
-- puts the balance back by itself.
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── 1. The agreed fee, frozen on the enquiry ───────────────────────────────
-- Frozen deliberately: a school that edits its Registration fee head next month
-- must not rewrite what this family was told, or what they still owe.
ALTER TABLE core.enquiries
    ADD COLUMN IF NOT EXISTS registration_fee_amount numeric(12,2) NOT NULL DEFAULT 0;

COMMENT ON COLUMN core.enquiries.registration_fee_amount IS
    'The registration fee agreed with this family, frozen at registration. What they have paid is summed from core.fee_payments, never stored.';


-- ── 2. What has been settled, and what is left ─────────────────────────────
-- "Settled" is cash + waiver: a discount is not owed, so it clears the balance
-- exactly as cash does. Cancelled receipts drop out on their own.
CREATE OR REPLACE FUNCTION core.fn_registration_fee_settled(
    p_tenant_id integer, p_school_id integer, p_enquiry_id integer)
RETURNS numeric
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(COALESCE(p.amount, 0) + COALESCE(p.discount_amount, 0)), 0)
      FROM core.fee_payments p
     WHERE p.tenant_id = p_tenant_id
       AND p.school_id = p_school_id
       AND p.enquiry_id = p_enquiry_id
       AND p.payment_type = 'Registration'
       AND COALESCE(p.is_cancelled, FALSE) = FALSE;
$$;

COMMENT ON FUNCTION core.fn_registration_fee_settled(integer, integer, integer) IS
    'Registration fee settled for an enquiry: cash plus waiver, across every live receipt. Derived on purpose - a stored total would drift and would survive a cancelled receipt.';


-- ── 2b. The name an unpaid balance is billed under ─────────────────────────
-- When a registration is only part paid and the enquiry becomes a student, the
-- remainder moves onto the student's ledger (see sp_admission_manage). Bill it
-- under the school's own Registration-point head when there is exactly one, so
-- the line matches the fee master and the reports group it with the rest of the
-- registration money. With none or several, a plain label beats guessing which
-- head was meant.
CREATE OR REPLACE FUNCTION core.fn_registration_fee_head_name(
    p_tenant_id integer, p_school_id integer)
RETURNS varchar
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        -- max() over the whole set, with HAVING count = 1: returns the name only
        -- when there is exactly one such head, and NULL otherwise.
        (SELECT max(h.fee_head_name)
           FROM core.school_fee_heads h
          WHERE h.tenant_id = p_tenant_id
            AND h.school_id = p_school_id
            AND h.collection_point = 'Registration'
            AND COALESCE(h.is_deleted, FALSE) = FALSE
          HAVING COUNT(*) = 1),
        'Registration Fee');
$$;

-- ── 3. Record a payment, in full or in part ────────────────────────────────
-- p_fee_amount is the agreed fee. It is stored the first time and then left
-- alone, so a later change to the fee head cannot move an existing balance.
DROP PROCEDURE IF EXISTS core.sp_registration_fee_record(
    integer, integer, integer, integer, numeric, character varying,
    character varying, character varying, date, character varying,
    numeric, character varying, character varying, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_registration_fee_record(
    IN    p_tenant_id       integer,
    IN    p_school_id       integer,
    IN    p_action_user_id  integer,
    IN    p_enquiry_id      integer,
    IN    p_amount          numeric,               -- cash collected NOW (may be part)
    IN    p_payment_mode    varchar,
    IN    p_reference_no    varchar  DEFAULT NULL,
    IN    p_remarks         varchar  DEFAULT NULL,
    IN    p_payment_date    date     DEFAULT NULL,
    IN    p_fin_year        varchar  DEFAULT NULL,
    IN    p_discount_amount numeric  DEFAULT 0,     -- server-computed, never trusted from client
    IN    p_discount_type   varchar  DEFAULT NULL,
    IN    p_discount_reason varchar  DEFAULT NULL,
    IN    p_fee_amount      numeric  DEFAULT 0,     -- the agreed fee for this enquiry
    INOUT p_result          refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_seq       integer;
    v_year      varchar(4);
    v_receipt   varchar(40);
    v_date      date;
    v_disc      numeric := COALESCE(p_discount_amount, 0);
    v_cash      numeric := COALESCE(p_amount, 0);
    v_fee       numeric;
    v_settled   numeric;
    v_balance   numeric;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR p_enquiry_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;
    IF v_cash < 0 OR v_disc < 0 THEN
        RAISE EXCEPTION 'Registration fee amount is invalid.';
    END IF;
    IF v_cash + v_disc <= 0 THEN
        RAISE EXCEPTION 'Enter an amount to collect.';
    END IF;

    -- Freeze the agreed fee the first time, then leave it alone. The fallbacks
    -- matter: an already-stored amount wins, then what the caller says the fee is,
    -- and failing both, THIS payment is the fee. That last one is what keeps older
    -- callers working exactly as they did -- they hand over the full amount and
    -- never mention a fee, so the payment settles it and no balance appears.
    SELECT COALESCE(NULLIF(registration_fee_amount, 0),
                    NULLIF(COALESCE(p_fee_amount, 0), 0),
                    v_cash + v_disc)
      INTO v_fee
    FROM core.enquiries
    WHERE enquiry_id = p_enquiry_id AND tenant_id = p_tenant_id AND school_id = p_school_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Enquiry not found.';
    END IF;

    UPDATE core.enquiries
       SET registration_fee_amount = v_fee
     WHERE enquiry_id = p_enquiry_id AND tenant_id = p_tenant_id AND school_id = p_school_id
       AND COALESCE(registration_fee_amount, 0) = 0;

    -- Refuse to take more than is owed. Taking it and leaving the excess
    -- unrecorded is how money goes missing; the fee counter handles advances.
    v_settled := core.fn_registration_fee_settled(p_tenant_id, p_school_id, p_enquiry_id);
    IF v_settled + v_cash + v_disc > v_fee + 0.005 THEN
        RAISE EXCEPTION 'Only % is outstanding on this registration; % was entered.',
            to_char(v_fee - v_settled, 'FM999,999,990.00'),
            to_char(v_cash + v_disc, 'FM999,999,990.00');
    END IF;

    v_date := COALESCE(p_payment_date, CURRENT_DATE);
    v_year := core.fn_receipt_year(p_tenant_id, p_school_id, p_fin_year, v_date);

    INSERT INTO core.receipt_counters (tenant_id, school_id, fin_year, last_seq)
    VALUES (p_tenant_id, p_school_id, v_year, 1)
    ON CONFLICT (tenant_id, school_id, fin_year)
    DO UPDATE SET last_seq = core.receipt_counters.last_seq + 1
    RETURNING last_seq INTO v_seq;

    v_receipt := 'RCP-' || v_year || '-' || lpad(v_seq::text, 4, '0');

    INSERT INTO core.fee_payments
        (tenant_id, school_id, student_id, enquiry_id, payment_type, receipt_no,
         amount, payment_mode, reference_no, remarks, payment_date, created_by,
         discount_amount, discount_type, discount_reason)
    VALUES
        (p_tenant_id, p_school_id, NULL, p_enquiry_id, 'Registration', v_receipt,
         v_cash, p_payment_mode, NULLIF(trim(p_reference_no), ''),
         NULLIF(trim(p_remarks), ''), v_date, p_action_user_id,
         v_disc, NULLIF(trim(p_discount_type), ''), NULLIF(trim(p_discount_reason), ''));

    -- Recompute from the receipts rather than adding to a running figure.
    v_settled := core.fn_registration_fee_settled(p_tenant_id, p_school_id, p_enquiry_id);
    v_balance := v_fee - v_settled;

    -- The flag now means "nothing left to pay", which is what every screen
    -- reading it already assumed it meant.
    UPDATE core.enquiries
       SET registration_fee_paid = (v_balance <= 0.005)
     WHERE enquiry_id = p_enquiry_id AND tenant_id = p_tenant_id AND school_id = p_school_id;

    OPEN p_result FOR
    SELECT TRUE                       AS success,
           CASE WHEN v_balance <= 0.005
                THEN 'Registration fee received in full.'
                ELSE format('Part payment received. %s still outstanding.',
                            to_char(v_balance, 'FM999,999,990.00'))
           END                        AS message,
           v_receipt                  AS receipt_no,
           v_cash                     AS amount,
           v_disc                     AS discount_amount,
           (v_cash + v_disc)          AS gross_amount,
           v_fee                      AS fee_amount,
           v_settled                  AS settled_amount,
           GREATEST(v_balance, 0)     AS balance_amount,
           v_date                     AS payment_date;
END;
$procedure$;


-- ── 4. Backfill: what was already collected in full ────────────────────────
-- Enquiries flagged paid under the old all-or-nothing rule have receipts but no
-- agreed amount. Take the amount from their own receipts, so their balance
-- reads zero rather than "the whole fee is outstanding".
UPDATE core.enquiries e
SET registration_fee_amount = t.settled
FROM (
    SELECT p.tenant_id, p.school_id, p.enquiry_id,
           SUM(COALESCE(p.amount, 0) + COALESCE(p.discount_amount, 0)) AS settled
      FROM core.fee_payments p
     WHERE p.enquiry_id IS NOT NULL
       AND p.payment_type = 'Registration'
       AND COALESCE(p.is_cancelled, FALSE) = FALSE
     GROUP BY 1, 2, 3
) t
WHERE t.enquiry_id = e.enquiry_id
  AND t.tenant_id  = e.tenant_id
  AND t.school_id  = e.school_id
  AND COALESCE(e.registration_fee_amount, 0) = 0
  AND t.settled > 0;
