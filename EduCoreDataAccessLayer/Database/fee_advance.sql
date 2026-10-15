-- ============================================================================
-- Fee Collection — the COLLECT ENGINE, the ADVANCE wallet and the RECEIPT reprint
--
-- This file owns core.sp_fee_payment_collect and core.sp_fee_receipt_get (the
-- live definitions). Other fee scripts must not re-create them.
--
-- A student carries a single advance balance (core.student_advance). Two flows
-- on the counter, both handled inside sp_fee_payment_collect:
--   • Overpay  → the surplus cash is CREDITED to the wallet (advance_credit).
--   • Use it   → p_advance_used DEBITS the wallet and funds part of the bill.
--
-- Funding rule for a receipt:
--   funded   = (non-advance tenders) + advance_used
--   settled  = dues cash + extras            (= fee_payments.amount)
--   surplus  = funded − settled  (≥ 0)       → credited to the wallet
--   wallet  += surplus − advance_used
-- Advance is recorded as an 'Advance' tender line so it shows in reports but is
-- never counted as cash.
--
-- Rules the engine enforces (each one closed a real hole):
--   • the student must belong to this school (an extras-only receipt never
--     looked at a ledger row, so it was issued for any id at all);
--   • lines for the same due are merged and every due is locked FOR UPDATE, so
--     two lines -- or two counters -- can't both settle the same money;
--   • a concession needs a reason and is never allowed on a refundable deposit;
--   • tenders can't be negative and 'Advance' is not a tender mode (the wallet is
--     only drawn through p_advance_used, which is checked against the balance);
--   • advance used can't exceed the amount being settled;
--   • a cheque / DD tender needs its number;
--   • p_client_ref makes a retried request return the first receipt instead of
--     taking the money twice;
--   • a counter that has closed the day can't collect on it
--     (core.fn_fee_day_closed, owned by fee_day_close.sql -- apply that first).
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── 1. Wallet balance + advance columns on the receipt ──────────────────────
CREATE TABLE IF NOT EXISTS core.student_advance
(
    student_id  integer PRIMARY KEY REFERENCES core.students(student_id),
    tenant_id   integer       NOT NULL,
    school_id   integer       NOT NULL,
    balance     numeric(12,2) NOT NULL DEFAULT 0,
    updated_at  timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT chk_student_advance_scope CHECK ((tenant_id > 1) AND (school_id > 0))
);

ALTER TABLE core.fee_payments
    ADD COLUMN IF NOT EXISTS advance_used         numeric(12,2) NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS advance_credit       numeric(12,2) NOT NULL DEFAULT 0,
    -- Who approved a concession (the cashier is created_by).
    ADD COLUMN IF NOT EXISTS discount_approved_by varchar(80),
    -- One id per counter settlement; a retry with the same id is not a new payment.
    ADD COLUMN IF NOT EXISTS client_ref           varchar(64);

CREATE UNIQUE INDEX IF NOT EXISTS uq_fee_payments_client_ref
    ON core.fee_payments (tenant_id, school_id, client_ref)
    WHERE client_ref IS NOT NULL;

-- ── 2. A user's display name for receipts and history ──────────────────────
CREATE OR REPLACE FUNCTION core.fn_user_display_name(p_user_id integer)
RETURNS varchar
LANGUAGE sql
STABLE
AS $function$
    SELECT CASE WHEN p_user_id IS NULL THEN NULL ELSE
           COALESCE(
               (SELECT NULLIF(trim(up.full_name), '')
                  FROM core.user_profiles up
                 WHERE up.user_id = p_user_id
                 ORDER BY COALESCE(up.is_deleted, FALSE), up.user_profile_id DESC
                 LIMIT 1),
               (SELECT u.email FROM core.users u WHERE u.user_id = p_user_id),
               'User #' || p_user_id)
           END;
$function$;

-- ── 3. Read a student's advance balance ─────────────────────────────────────
CREATE OR REPLACE PROCEDURE core.sp_student_advance_get(
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
    SELECT COALESCE((SELECT balance FROM core.student_advance
                     WHERE tenant_id=p_tenant_id AND school_id=p_school_id AND student_id=p_student_id), 0) AS balance;
END;
$procedure$;

-- ── 4. The collect proc ─────────────────────────────────────────────────────
-- Older signatures: 16-arg (no advance) and 17-arg (no client ref / approver).
-- Exactly one overload may exist, or name-based CALL becomes ambiguous.
DROP PROCEDURE IF EXISTS core.sp_fee_payment_collect(
    integer, integer, integer, integer, jsonb, jsonb,
    character varying, character varying, character varying, date, character varying,
    character varying, numeric, character varying, jsonb, refcursor);
DROP PROCEDURE IF EXISTS core.sp_fee_payment_collect(
    integer, integer, integer, integer, jsonb, jsonb,
    character varying, character varying, character varying, date, character varying,
    character varying, numeric, character varying, jsonb, numeric, refcursor);

-- p_client_ref and p_discount_approved_by come AFTER p_result on purpose: every
-- existing positional caller passes the cursor 17th, and keeps working.
CREATE OR REPLACE PROCEDURE core.sp_fee_payment_collect(
    IN    p_tenant_id            integer,
    IN    p_school_id            integer,
    IN    p_action_user_id       integer,
    IN    p_student_id           integer,
    IN    p_items                jsonb,
    IN    p_extras               jsonb,
    IN    p_payment_mode         varchar,
    IN    p_reference_no         varchar  DEFAULT NULL,
    IN    p_remarks              varchar  DEFAULT NULL,
    IN    p_payment_date         date     DEFAULT NULL,
    IN    p_fin_year             varchar  DEFAULT NULL,
    IN    p_discount_type        varchar  DEFAULT NULL,
    IN    p_discount_value       numeric  DEFAULT 0,
    IN    p_discount_reason      varchar  DEFAULT NULL,
    IN    p_tenders              jsonb    DEFAULT NULL,
    IN    p_advance_used         numeric  DEFAULT 0,
    INOUT p_result               refcursor DEFAULT 'result_cursor'::refcursor,
    IN    p_client_ref           varchar  DEFAULT NULL,
    IN    p_discount_approved_by varchar  DEFAULT NULL
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_seq          integer;
    v_year         varchar(4);
    v_receipt      varchar(40);
    v_date         date;
    v_payment_id   integer;
    v_cash_total   numeric(12,2) := 0;
    v_conc_total   numeric(12,2) := 0;
    v_item         jsonb;
    v_amount       numeric(12,2);
    v_concession   numeric(12,2);
    v_label        varchar(100);
    v_note         varchar(40);
    v_outstanding  numeric(12,2);
    v_has_items    boolean;
    v_has_extras   boolean;
    v_has_tenders  boolean;
    v_new_cash     numeric(12,2) := 0;
    v_adv_used     numeric(12,2);
    v_balance      numeric(12,2) := 0;
    v_funded       numeric(12,2);
    v_surplus      numeric(12,2);
    v_mode_count   integer := 0;
    v_mode         varchar(30);
    v_reference    varchar(60);
    v_client_ref   varchar(64);

    v_lines        jsonb := '[]'::jsonb;
    r_item         record;
    r_ledger       record;
    r_prev         record;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR p_student_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;

    -- The student must be this school's. Lines are checked against the ledger
    -- below, but an extras-only receipt never touches a ledger row.
    IF NOT EXISTS (SELECT 1 FROM core.students
                    WHERE student_id = p_student_id
                      AND tenant_id = p_tenant_id AND school_id = p_school_id) THEN
        RAISE EXCEPTION 'Student not found in this school.';
    END IF;

    -- The TC says the account is settled: money taken after it (an overpayment that
    -- lands in the wallet, say) would sit on a child who has gone. Void the TC first.
    IF EXISTS (SELECT 1 FROM core.tc_register t
                WHERE t.tenant_id = p_tenant_id AND t.school_id = p_school_id
                  AND t.student_id = p_student_id AND t.is_void = FALSE) THEN
        RAISE EXCEPTION 'A Transfer Certificate has been issued for this student. Void it before collecting money.';
    END IF;

    -- A retry of a settlement that already went through returns that receipt.
    v_client_ref := NULLIF(trim(p_client_ref), '');
    IF v_client_ref IS NOT NULL THEN
        SELECT receipt_no, amount, concession_total, payment_date, student_id INTO r_prev
          FROM core.fee_payments
         WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND client_ref = v_client_ref;
        IF FOUND THEN
            IF r_prev.student_id IS DISTINCT FROM p_student_id THEN
                RAISE EXCEPTION 'This payment reference was already used for another student. Please reload.';
            END IF;
            OPEN p_result FOR
            SELECT TRUE AS success,
                   'Already recorded as ' || r_prev.receipt_no || '.' AS message,
                   r_prev.receipt_no AS receipt_no,
                   r_prev.amount AS amount,
                   r_prev.concession_total AS concession_total,
                   r_prev.payment_date AS payment_date;
            RETURN;
        END IF;
    END IF;

    v_has_items   := p_items   IS NOT NULL AND jsonb_typeof(p_items)   = 'array' AND jsonb_array_length(p_items)   > 0;
    v_has_extras  := p_extras  IS NOT NULL AND jsonb_typeof(p_extras)  = 'array' AND jsonb_array_length(p_extras)  > 0;
    v_has_tenders := p_tenders IS NOT NULL AND jsonb_typeof(p_tenders) = 'array' AND jsonb_array_length(p_tenders) > 0;
    v_adv_used    := COALESCE(p_advance_used, 0);

    IF NOT v_has_items AND NOT v_has_extras THEN
        RAISE EXCEPTION 'Select at least one due or add an extra charge.';
    END IF;

    v_date := COALESCE(p_payment_date, CURRENT_DATE);

    -- A cashier who has closed the day can't keep collecting on it (an admin
    -- can re-open it). core.fn_fee_day_closed lives in fee_day_close.sql.
    IF core.fn_fee_day_closed(p_tenant_id, p_school_id, p_action_user_id, v_date) THEN
        RAISE EXCEPTION 'Today is already closed for this counter. Ask an admin to re-open the day before collecting.';
    END IF;

    -- Was left(session_name, 4), which turned a session called "FY 26-27" into
    -- "FY 2" and put a space in every receipt number. See receipt_number_year.sql.
    v_year := core.fn_receipt_year(p_tenant_id, p_school_id, p_fin_year, v_date);

    -- ── Dues: merged per ledger row, locked, checked ──
    IF v_has_items THEN
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_items) e
                    WHERE COALESCE((e->>'amount')::numeric, 0) < 0
                       OR COALESCE((e->>'concession')::numeric, 0) < 0) THEN
            RAISE EXCEPTION 'Amount and concession cannot be negative.';
        END IF;

        -- Two lines for the same due used to be checked one at a time against
        -- the row as it was, so both passed and the due was paid twice over.
        -- Ordered by id so two counters always lock in the same order.
        FOR r_item IN
            SELECT (e->>'ledgerId')::integer                          AS ledger_id,
                   SUM(COALESCE((e->>'amount')::numeric, 0))          AS amount,
                   SUM(COALESCE((e->>'concession')::numeric, 0))      AS concession
              FROM jsonb_array_elements(p_items) e
             GROUP BY 1
             ORDER BY 1
        LOOP
            v_amount     := r_item.amount;
            v_concession := r_item.concession;
            IF v_amount = 0 AND v_concession = 0 THEN
                CONTINUE;
            END IF;

            SELECT * INTO r_ledger
              FROM core.student_ledger
             WHERE ledger_id = r_item.ledger_id
               AND tenant_id = p_tenant_id AND school_id = p_school_id AND student_id = p_student_id
               FOR UPDATE;

            IF NOT FOUND THEN
                RAISE EXCEPTION 'A selected due no longer exists. Please reload.';
            END IF;

            v_outstanding := r_ledger.amount_due - r_ledger.amount_paid - r_ledger.concession;
            IF v_amount + v_concession > v_outstanding + 0.001 THEN
                RAISE EXCEPTION 'A payment line is more than its outstanding amount. Please reload.';
            END IF;

            -- A deposit is held to be given back. Waiving part of it means the
            -- school "holds" money it never took, and the refund at exit is wrong.
            IF v_concession > 0 AND COALESCE(core.fn_ledger_head_refundable(r_ledger.ledger_id), FALSE) THEN
                RAISE EXCEPTION 'A concession cannot be given on a refundable deposit (%). Collect it in full or untick it.',
                                r_ledger.fee_head_name;
            END IF;

            v_lines := v_lines || jsonb_build_object(
                'ledgerId', r_ledger.ledger_id, 'amount', v_amount, 'concession', v_concession,
                'head', r_ledger.fee_head_name, 'label', r_ledger.installment_label);

            v_cash_total := v_cash_total + v_amount;
            v_conc_total := v_conc_total + v_concession;
        END LOOP;
    END IF;

    IF v_has_extras THEN
        FOR v_item IN SELECT * FROM jsonb_array_elements(p_extras)
        LOOP
            v_amount := COALESCE((v_item->>'amount')::numeric, 0);
            IF v_amount < 0 THEN
                RAISE EXCEPTION 'Extra charge cannot be negative.';
            END IF;
            v_cash_total := v_cash_total + v_amount;
        END LOOP;
    END IF;

    IF v_cash_total <= 0 AND v_conc_total <= 0 THEN
        RAISE EXCEPTION 'Nothing to collect.';
    END IF;

    -- Money given away needs a reason on record (the screens always asked;
    -- the engine did not).
    IF v_conc_total > 0 AND NULLIF(trim(p_discount_reason), '') IS NULL THEN
        RAISE EXCEPTION 'A reason is required for a concession.';
    END IF;

    -- ── Advance ──
    IF v_adv_used < 0 THEN
        RAISE EXCEPTION 'Advance used cannot be negative.';
    END IF;
    -- Drawing more than the bill took the excess out of the wallet and lost it.
    IF v_adv_used > v_cash_total + 0.001 THEN
        RAISE EXCEPTION 'Advance used (%) is more than the amount being settled (%).', v_adv_used, v_cash_total;
    END IF;
    IF v_adv_used > 0 THEN
        SELECT COALESCE(balance, 0) INTO v_balance
        FROM core.student_advance
        WHERE tenant_id=p_tenant_id AND school_id=p_school_id AND student_id=p_student_id
        FOR UPDATE;
        v_balance := COALESCE(v_balance, 0);
        IF v_adv_used > v_balance + 0.01 THEN
            RAISE EXCEPTION 'Advance used (%) exceeds available balance (%).', v_adv_used, v_balance;
        END IF;
    END IF;

    -- ── Tenders ──
    IF v_has_tenders THEN
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_tenders) t
                    WHERE COALESCE((t->>'amount')::numeric, 0) < 0) THEN
            RAISE EXCEPTION 'A payment amount cannot be negative.';
        END IF;
        -- The wallet is drawn only through p_advance_used, which is checked
        -- against the balance. An 'Advance' tender settled dues from nothing.
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_tenders) t
                    WHERE lower(trim(COALESCE(t->>'mode', ''))) = 'advance'
                      AND COALESCE((t->>'amount')::numeric, 0) > 0) THEN
            RAISE EXCEPTION 'Advance is used through "Use advance", not as a payment mode.';
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_tenders) t
                    WHERE lower(trim(COALESCE(t->>'mode', ''))) IN ('cheque', 'demand draft')
                      AND COALESCE((t->>'amount')::numeric, 0) > 0
                      AND NULLIF(trim(t->>'reference'), '') IS NULL) THEN
            RAISE EXCEPTION 'Enter the cheque / DD number for that payment.';
        END IF;

        SELECT COALESCE(SUM((t->>'amount')::numeric), 0),
               COUNT(DISTINCT t->>'mode') FILTER (WHERE COALESCE((t->>'amount')::numeric,0) > 0)
          INTO v_new_cash, v_mode_count
        FROM jsonb_array_elements(p_tenders) t
        WHERE COALESCE((t->>'amount')::numeric, 0) > 0;
    ELSE
        v_new_cash := v_cash_total - v_adv_used;   -- no explicit split: exact funding
    END IF;

    v_funded  := v_new_cash + v_adv_used;
    IF v_funded < v_cash_total - 0.01 THEN
        RAISE EXCEPTION 'Payment (%) is less than the amount being settled (%).', v_funded, v_cash_total;
    END IF;
    v_surplus := v_funded - v_cash_total;          -- >= 0

    -- Header payment mode.
    IF v_has_tenders AND v_new_cash > 0 THEN
        IF v_mode_count <= 1 THEN
            SELECT NULLIF(trim(t->>'mode'), '') INTO v_mode
            FROM jsonb_array_elements(p_tenders) t
            WHERE COALESCE((t->>'amount')::numeric, 0) > 0
            LIMIT 1;
        ELSE
            v_mode := 'Mixed';
        END IF;
    ELSIF v_adv_used > 0 AND v_new_cash = 0 THEN
        v_mode := 'Advance';
    END IF;
    v_mode := COALESCE(v_mode, NULLIF(trim(p_payment_mode), ''), 'Cash');

    -- Header reference: what the caller gave, else the tender references
    -- (cheque no, UPI ref) so the history list shows them.
    v_reference := NULLIF(trim(p_reference_no), '');
    IF v_reference IS NULL AND v_has_tenders THEN
        SELECT left(string_agg(trim(t->>'reference'), ', '), 60) INTO v_reference
        FROM jsonb_array_elements(p_tenders) t
        WHERE NULLIF(trim(t->>'reference'), '') IS NOT NULL
          AND COALESCE((t->>'amount')::numeric, 0) > 0;
    END IF;

    INSERT INTO core.receipt_counters (tenant_id, school_id, fin_year, last_seq)
    VALUES (p_tenant_id, p_school_id, v_year, 1)
    ON CONFLICT (tenant_id, school_id, fin_year)
    DO UPDATE SET last_seq = core.receipt_counters.last_seq + 1
    RETURNING last_seq INTO v_seq;

    v_receipt := 'RCP-' || v_year || '-' || lpad(v_seq::text, 4, '0');

    INSERT INTO core.fee_payments
        (tenant_id, school_id, student_id, payment_type, receipt_no, amount, concession_total,
         payment_mode, reference_no, remarks, payment_date, created_by,
         discount_type, discount_value, discount_reason, discount_approved_by,
         advance_used, advance_credit, client_ref)
    VALUES
        (p_tenant_id, p_school_id, p_student_id, 'Fee', v_receipt, v_cash_total, v_conc_total,
         v_mode, v_reference, NULLIF(trim(p_remarks), ''),
         v_date, p_action_user_id,
         CASE WHEN v_conc_total > 0 THEN NULLIF(trim(p_discount_type), '') ELSE NULL END,
         CASE WHEN v_conc_total > 0 THEN COALESCE(p_discount_value, 0) ELSE 0 END,
         CASE WHEN v_conc_total > 0 THEN NULLIF(trim(p_discount_reason), '') ELSE NULL END,
         CASE WHEN v_conc_total > 0 THEN NULLIF(trim(p_discount_approved_by), '') ELSE NULL END,
         v_adv_used, v_surplus, v_client_ref)
    RETURNING payment_id INTO v_payment_id;

    -- Adjust the wallet: debit what was used, credit the surplus. Using advance
    -- means the wallet row exists (its balance was checked and locked above), so
    -- that case is a plain UPDATE; an upsert would try to insert a negative row
    -- first and trip chk_student_advance_balance (fee_money_guards.sql).
    IF v_adv_used > 0 THEN
        UPDATE core.student_advance
           SET balance = balance + v_surplus - v_adv_used, updated_at = NOW()
         WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND student_id = p_student_id;
    ELSIF v_surplus > 0 THEN
        INSERT INTO core.student_advance (tenant_id, school_id, student_id, balance, updated_at)
        VALUES (p_tenant_id, p_school_id, p_student_id, v_surplus, NOW())
        ON CONFLICT (student_id)
        DO UPDATE SET balance = core.student_advance.balance + v_surplus, updated_at = NOW();
    END IF;

    -- Tender rows: the cash split, plus an 'Advance' line for wallet-funded part.
    IF v_has_tenders THEN
        FOR v_item IN SELECT * FROM jsonb_array_elements(p_tenders)
        LOOP
            v_amount := COALESCE((v_item->>'amount')::numeric, 0);
            IF v_amount <= 0 THEN CONTINUE; END IF;
            INSERT INTO core.fee_payment_tenders (payment_id, mode, amount, reference)
            VALUES (v_payment_id, COALESCE(NULLIF(trim(v_item->>'mode'), ''), 'Cash'),
                    v_amount, left(NULLIF(trim(v_item->>'reference'), ''), 60));
        END LOOP;
    END IF;
    IF v_adv_used > 0 THEN
        INSERT INTO core.fee_payment_tenders (payment_id, mode, amount)
        VALUES (v_payment_id, 'Advance', v_adv_used);
    END IF;

    -- Apply the merged lines (rows are already locked).
    FOR v_item IN SELECT * FROM jsonb_array_elements(v_lines)
    LOOP
        v_amount     := (v_item->>'amount')::numeric;
        v_concession := (v_item->>'concession')::numeric;

        UPDATE core.student_ledger
        SET amount_paid = amount_paid + v_amount,
            concession  = concession  + v_concession,
            status      = CASE WHEN amount_paid + v_amount + concession + v_concession >= amount_due
                               THEN 'Paid' ELSE 'Partial' END,
            updated_at  = NOW()
        WHERE ledger_id = (v_item->>'ledgerId')::integer;

        INSERT INTO core.fee_payment_details
            (payment_id, ledger_id, fee_head_name, installment_label, amount, concession, line_type)
        VALUES
            (v_payment_id, (v_item->>'ledgerId')::integer, v_item->>'head', v_item->>'label',
             v_amount, v_concession, 'Due');
    END LOOP;

    IF v_has_extras THEN
        FOR v_item IN SELECT * FROM jsonb_array_elements(p_extras)
        LOOP
            v_amount := COALESCE((v_item->>'amount')::numeric, 0);
            v_label  := COALESCE(NULLIF(trim(v_item->>'label'), ''), 'Extra Charge');
            -- The cashier's note ("lost library book") rides in the line's label slot.
            v_note   := left(NULLIF(trim(v_item->>'note'), ''), 40);
            IF v_amount <= 0 THEN
                CONTINUE;
            END IF;

            INSERT INTO core.fee_payment_details
                (payment_id, ledger_id, fee_head_name, installment_label, amount, concession, line_type)
            VALUES
                (v_payment_id, NULL, v_label, v_note, v_amount, 0, 'Extra');
        END LOOP;
    END IF;

    OPEN p_result FOR
    SELECT TRUE         AS success,
           'Payment recorded.' AS message,
           v_receipt    AS receipt_no,
           v_cash_total AS amount,
           v_conc_total AS concession_total,
           v_date       AS payment_date;
END;
$procedure$;

-- ── 5. Receipt reprint ──────────────────────────────────────────────────────
-- Header: what was taken and how, who took it, and -- if it was voided -- that
-- it is CANCELLED, by whom, when and why, so a reprint can never pass as a
-- valid receipt. `tenders` is the split (mode, amount, cheque no / UPI ref) as
-- JSON text. `discount_amount` is the registration-fee discount (registration
-- receipts carry it on the header instead of concession lines).
-- The cursor list is unchanged: positional callers keep working.
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
           COALESCE(s.class_name, e.class_name, '-')           AS class_name,
           s.section AS section, s.roll_no AS roll_no,
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
    WHERE p.payment_id = v_payment_id;

    OPEN p_lines FOR
    SELECT fee_head_name, installment_label, amount, concession, line_type
    FROM core.fee_payment_details
    WHERE payment_id = v_payment_id
    ORDER BY detail_id;
END;
$procedure$;
