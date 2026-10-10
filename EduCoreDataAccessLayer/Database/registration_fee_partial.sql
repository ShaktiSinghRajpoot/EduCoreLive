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
--
-- Two places can hold registration money:
--   * receipts taken against the enquiry (payment_type = 'Registration'), and
--   * after admission, the ledger row(s) the unpaid balance was carried onto
--     (installment_label = 'Registration' on the admitted student). Whatever is
--     paid or waived there at the fee counter settles the same fee.
-- Counting only the first made a registration read "Pending" for ever once the
-- family paid the carried balance at the counter. The admission proc calls this
-- BEFORE it writes the carried row, so the carry itself is never counted twice.
CREATE OR REPLACE FUNCTION core.fn_registration_fee_settled(
    p_tenant_id integer, p_school_id integer, p_enquiry_id integer)
RETURNS numeric
LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT SUM(COALESCE(p.amount, 0) + COALESCE(p.discount_amount, 0))
                       FROM core.fee_payments p
                      WHERE p.tenant_id = p_tenant_id
                        AND p.school_id = p_school_id
                        AND p.enquiry_id = p_enquiry_id
                        AND p.payment_type = 'Registration'
                        AND COALESCE(p.is_cancelled, FALSE) = FALSE), 0)
         + COALESCE((SELECT SUM(l.amount_paid + l.concession)
                       FROM core.student_ledger l
                       JOIN core.students s ON s.student_id = l.student_id
                      WHERE l.tenant_id = p_tenant_id
                        AND l.school_id = p_school_id
                        AND s.tenant_id = p_tenant_id
                        AND s.school_id = p_school_id
                        AND s.enquiry_id = p_enquiry_id
                        AND l.installment_label = 'Registration'), 0);
$$;

COMMENT ON FUNCTION core.fn_registration_fee_settled(integer, integer, integer) IS
    'Registration fee settled for an enquiry: cash plus waiver across every live registration receipt, plus anything paid on the carried Registration ledger row after admission. Derived on purpose - a stored total would drift and would survive a cancelled receipt.';


-- ── 2a. Is it paid? ────────────────────────────────────────────────────────
-- The one answer to "is this registration fee paid". Screens read this rather
-- than core.enquiries.registration_fee_paid, which is now only a cache: a flag
-- set by a button, by a browser tick, or left behind by a cancelled receipt
-- used to say "Paid" with no money behind it. Paid = a fee was agreed and none
-- of it is left. An old row with no agreed amount is paid only if it has money.
CREATE OR REPLACE FUNCTION core.fn_registration_fee_is_paid(
    p_tenant_id integer, p_school_id integer, p_enquiry_id integer)
RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT CASE
             WHEN COALESCE(e.registration_fee_amount, 0) > 0
               THEN core.fn_registration_fee_settled(p_tenant_id, p_school_id, p_enquiry_id)
                    >= e.registration_fee_amount - 0.005
             ELSE core.fn_registration_fee_settled(p_tenant_id, p_school_id, p_enquiry_id) > 0
           END
      FROM core.enquiries e
     WHERE e.enquiry_id = p_enquiry_id
       AND e.tenant_id  = p_tenant_id
       AND e.school_id  = p_school_id;
$$;


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
    v_mode      varchar;
    v_dtype     varchar := NULLIF(trim(p_discount_type), '');
    v_dvalue    numeric := 0;
    v_fee       numeric;
    v_stored    numeric;
    v_active    boolean;
    v_admission integer;
    v_regno     varchar;
    v_status    varchar;
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

    -- A discount is money the school chose not to take. Without a reason nobody
    -- can later say why, so it is refused here and not only in the controller.
    IF v_disc > 0 AND NULLIF(trim(p_discount_reason), '') IS NULL THEN
        RAISE EXCEPTION 'A reason is required for a registration discount.';
    END IF;

    -- One spelling per mode. Day Close counts cash with payment_mode = 'Cash',
    -- so a receipt saved as "cash" silently left the drawer total.
    v_mode := CASE lower(trim(COALESCE(p_payment_mode, '')))
                  WHEN 'cash'          THEN 'Cash'
                  WHEN 'upi'           THEN 'UPI'
                  WHEN 'card'          THEN 'Card'
                  WHEN 'cheque'        THEN 'Cheque'
                  WHEN 'bank transfer' THEN 'Bank Transfer'
              END;
    IF v_mode IS NULL THEN
        RAISE EXCEPTION 'Unknown payment mode "%". Use Cash, UPI, Card, Cheque or Bank Transfer.', p_payment_mode;
    END IF;

    -- A receipt is dated when the money arrives. A future date would also keep
    -- it out of today's Day Close.
    v_date := COALESCE(p_payment_date, CURRENT_DATE);
    IF v_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'A receipt cannot be dated in the future.';
    END IF;

    -- Lock the enquiry for the rest of this transaction. Two cashiers collecting
    -- at the same moment would otherwise both read the same "settled" figure and
    -- both pass the over-collection check below.
    SELECT registration_fee_amount, COALESCE(is_active, TRUE), admission_id,
           registration_number, status
      INTO v_stored, v_active, v_admission, v_regno, v_status
    FROM core.enquiries
    WHERE enquiry_id = p_enquiry_id AND tenant_id = p_tenant_id AND school_id = p_school_id
    FOR UPDATE;

    IF NOT FOUND OR NOT v_active THEN
        RAISE EXCEPTION 'Enquiry not found.';
    END IF;
    -- After admission any unpaid balance already sits on the student's ledger,
    -- so taking it here as well would charge the family twice.
    IF v_admission IS NOT NULL THEN
        RAISE EXCEPTION 'This student is already admitted. Collect any registration balance at the Fee counter.';
    END IF;
    IF NULLIF(trim(v_regno), '') IS NULL THEN
        RAISE EXCEPTION 'Register the enquiry before taking a registration fee.';
    END IF;
    IF v_status IN ('Not Interested', 'Dropped') THEN
        RAISE EXCEPTION 'This registration was withdrawn. Re-register it before taking money.';
    END IF;

    -- Freeze the agreed fee the first time, then leave it alone. The fallbacks
    -- matter: an already-stored amount wins, then what the caller says the fee is,
    -- and failing both, THIS payment is the fee. That last one is what keeps older
    -- callers working exactly as they did -- they hand over the full amount and
    -- never mention a fee, so the payment settles it and no balance appears.
    v_fee := COALESCE(NULLIF(v_stored, 0), NULLIF(COALESCE(p_fee_amount, 0), 0), v_cash + v_disc);

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

    -- Store what the discount WAS, not only what it came to: a percentage as the
    -- percentage (worked back from the agreed fee, which is what the controller
    -- took it of), a fixed discount as its amount.
    IF v_disc > 0 THEN
        v_dtype  := CASE WHEN v_dtype = 'Percentage' THEN 'Percentage' ELSE 'Fixed' END;
        v_dvalue := CASE WHEN v_dtype = 'Percentage' AND v_fee > 0
                         THEN ROUND(v_disc * 100 / v_fee, 2)
                         ELSE v_disc END;
    ELSE
        v_dtype := NULL;
    END IF;

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
         discount_amount, discount_type, discount_value, discount_reason)
    VALUES
        (p_tenant_id, p_school_id, NULL, p_enquiry_id, 'Registration', v_receipt,
         v_cash, v_mode, NULLIF(trim(p_reference_no), ''),
         NULLIF(trim(p_remarks), ''), v_date, p_action_user_id,
         v_disc, v_dtype, v_dvalue, NULLIF(trim(p_discount_reason), ''));

    -- Recompute from the receipts rather than adding to a running figure.
    v_settled := core.fn_registration_fee_settled(p_tenant_id, p_school_id, p_enquiry_id);
    v_balance := v_fee - v_settled;

    -- Keep the cached flag in step. Screens read fn_registration_fee_is_paid.
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


-- ── 3b. The summary two screens need ───────────────────────────────────────
-- The collect dialog has to show what is owed BEFORE taking money, and a part
-- payment receipt has to print the fee and the balance beside what was received
-- -- a slip saying only "900" tells the family nothing about the 100 still due.
-- Both want the same three numbers, so they ask the same place for them.
CREATE OR REPLACE PROCEDURE core.sp_registration_fee_summary(
    IN    p_tenant_id  integer,
    IN    p_school_id  integer,
    IN    p_enquiry_id integer,
    INOUT p_result     refcursor DEFAULT 'result_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR p_enquiry_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;

    OPEN p_result FOR
    SELECT
        e.enquiry_id,
        e.student_name,
        e.class_name,
        e.session,
        COALESCE(e.registration_fee_amount, 0) AS fee_amount,
        core.fn_registration_fee_settled(p_tenant_id, p_school_id, p_enquiry_id) AS settled_amount,
        GREATEST(COALESCE(e.registration_fee_amount, 0)
                 - core.fn_registration_fee_settled(p_tenant_id, p_school_id, p_enquiry_id), 0) AS balance_amount,
        -- Derived, never the stored flag (see fn_registration_fee_is_paid).
        COALESCE(core.fn_registration_fee_is_paid(p_tenant_id, p_school_id, p_enquiry_id), FALSE) AS is_paid
    FROM core.enquiries e
    WHERE e.enquiry_id = p_enquiry_id
      AND e.tenant_id = p_tenant_id
      AND e.school_id = p_school_id;
END;
$procedure$;

-- ── 3c. A receipt's own place in the story ─────────────────────────────────
-- The summary above answers "where does this fee stand NOW", which is what the
-- collect dialog needs. A receipt needs a different question: "what did this
-- family owe at the moment THIS receipt was written". Printing the current
-- balance on it means a receipt changes after it is issued -- collect the last
-- 100 and the earlier 900 receipt silently stops mentioning the balance it was
-- printed with. A receipt is a record of a moment, so it is computed as of
-- itself: everything settled up to and including it, and nothing after.
--
-- Ordered by payment_id, not date: two payments on one day still have an order,
-- and it is the order they were taken in.
--
-- "As of itself" also means a receipt cancelled LATER still counts for the
-- receipts written while it was live: the 300 receipt printed "balance 200",
-- and cancelling it next week must not make that printed slip say 500.
--
-- this_receipt is the CASH on this receipt. A discount is not money paid, so it
-- comes back separately as this_discount; the printed "Paid on this receipt"
-- used to show cash + discount (500 for a 400 payment).
CREATE OR REPLACE PROCEDURE core.sp_registration_receipt_context(
    IN    p_tenant_id  integer,
    IN    p_school_id  integer,
    IN    p_receipt_no varchar,
    INOUT p_result     refcursor DEFAULT 'result_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_payment_id integer;
    v_enquiry_id integer;
    v_cash       numeric;
    v_disc       numeric;
    v_at         timestamptz;
    v_before     numeric;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;

    SELECT p.payment_id, p.enquiry_id, COALESCE(p.amount, 0), COALESCE(p.discount_amount, 0),
           p.created_at::timestamptz
      INTO v_payment_id, v_enquiry_id, v_cash, v_disc, v_at
    FROM core.fee_payments p
    WHERE p.tenant_id = p_tenant_id AND p.school_id = p_school_id
      AND p.receipt_no = p_receipt_no
      AND p.payment_type = 'Registration';

    IF v_enquiry_id IS NULL THEN
        OPEN p_result FOR SELECT 0::numeric AS fee_amount, 0::numeric AS paid_before,
                                 0::numeric AS this_receipt, 0::numeric AS this_discount,
                                 0::numeric AS balance_after
                          WHERE FALSE;
        RETURN;
    END IF;

    -- Settled (cash + waiver) by every earlier receipt that was live when this
    -- one was written.
    SELECT COALESCE(SUM(COALESCE(q.amount, 0) + COALESCE(q.discount_amount, 0)), 0)
      INTO v_before
      FROM core.fee_payments q
     WHERE q.tenant_id = p_tenant_id AND q.school_id = p_school_id
       AND q.enquiry_id = v_enquiry_id
       AND q.payment_type = 'Registration'
       AND q.payment_id < v_payment_id
       AND (COALESCE(q.is_cancelled, FALSE) = FALSE OR q.cancelled_at > v_at);

    OPEN p_result FOR
    SELECT
        COALESCE(e.registration_fee_amount, 0) AS fee_amount,
        v_before                               AS paid_before,
        v_cash                                 AS this_receipt,
        v_disc                                 AS this_discount,
        GREATEST(COALESCE(e.registration_fee_amount, 0) - v_before - v_cash - v_disc, 0) AS balance_after
    FROM core.enquiries e
    WHERE e.enquiry_id = v_enquiry_id
      AND e.tenant_id = p_tenant_id AND e.school_id = p_school_id;
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


-- ── 5. Re-sync the cached flag ─────────────────────────────────────────────
-- Older code set registration_fee_paid from a button or a browser tick, and a
-- cancelled receipt never cleared it. Put every registered enquiry back in step
-- with its money. Safe to re-run.
UPDATE core.enquiries e
   SET registration_fee_paid = COALESCE(core.fn_registration_fee_is_paid(e.tenant_id, e.school_id, e.enquiry_id), FALSE)
 WHERE e.tenant_id > 1
   AND e.registration_fee_paid IS DISTINCT FROM
       COALESCE(core.fn_registration_fee_is_paid(e.tenant_id, e.school_id, e.enquiry_id), FALSE);
