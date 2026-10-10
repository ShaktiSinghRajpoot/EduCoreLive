-- ============================================================================
-- Fee money GUARDS — database rules that stop the money tables going wrong
-- even if a procedure has a bug.
--
-- The procedures already refuse over-collection, over-refund and an overdrawn
-- wallet. These constraints are the second line: the same rules, enforced on
-- the rows themselves, so a future proc bug fails loudly instead of quietly
-- writing a ledger row that is "paid" more than it was due.
--
--   1. student_ledger: no negative amounts; paid + concession never above the
--      due; refunded never above paid.
--   2. student_advance: the wallet never goes below zero.
--   3. fee_payment_tenders: a tender line is always a positive amount.
--   4. Deleting a STUDENT can no longer silently erase their ledger or wallet
--      (ON DELETE CASCADE -> RESTRICT). Nothing in the app deletes students;
--      core.sp_school_purge deletes the ledger and wallet before the students,
--      so it keeps working.
--      Receipt lines and tenders still cascade from their receipt header on
--      purpose: no routine deletes a receipt except sp_school_purge, which
--      deletes headers only and relies on that cascade.
--
-- Run AFTER fee_refund.sql / fee_advance.sql. Checks existing data first and
-- stops with a message naming the bad rows rather than half-applying.
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

DO $guards$
DECLARE
    v_bad integer;
BEGIN
    -- ── 1. Ledger amounts ──
    SELECT COUNT(*) INTO v_bad FROM core.student_ledger
     WHERE amount_due < 0 OR amount_paid < 0 OR concession < 0 OR refund_amount < 0
        OR amount_paid + concession > amount_due
        OR refund_amount > amount_paid;
    IF v_bad > 0 THEN
        RAISE EXCEPTION 'fee_money_guards: % ledger row(s) already break the amount rules; fix them first.', v_bad;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid = 'core.student_ledger'::regclass AND conname = 'chk_student_ledger_amounts') THEN
        ALTER TABLE core.student_ledger
            ADD CONSTRAINT chk_student_ledger_amounts CHECK (
                amount_due >= 0 AND amount_paid >= 0 AND concession >= 0 AND refund_amount >= 0
                AND amount_paid + concession <= amount_due
                AND refund_amount <= amount_paid);
    END IF;

    -- ── 2. Wallet ──
    SELECT COUNT(*) INTO v_bad FROM core.student_advance WHERE balance < 0;
    IF v_bad > 0 THEN
        RAISE EXCEPTION 'fee_money_guards: % wallet(s) are already negative; fix them first.', v_bad;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid = 'core.student_advance'::regclass AND conname = 'chk_student_advance_balance') THEN
        ALTER TABLE core.student_advance
            ADD CONSTRAINT chk_student_advance_balance CHECK (balance >= 0);
    END IF;

    -- ── 3. Tender lines ──
    SELECT COUNT(*) INTO v_bad FROM core.fee_payment_tenders WHERE amount <= 0;
    IF v_bad > 0 THEN
        RAISE EXCEPTION 'fee_money_guards: % tender line(s) are zero or negative; fix them first.', v_bad;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid = 'core.fee_payment_tenders'::regclass AND conname = 'chk_fee_payment_tenders_amount') THEN
        ALTER TABLE core.fee_payment_tenders
            ADD CONSTRAINT chk_fee_payment_tenders_amount CHECK (amount > 0);
    END IF;

    -- ── 4. No cascade from students into money rows ──
    IF EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'student_ledger_student_id_fkey' AND confdeltype = 'c') THEN
        ALTER TABLE core.student_ledger DROP CONSTRAINT student_ledger_student_id_fkey;
        ALTER TABLE core.student_ledger
            ADD CONSTRAINT student_ledger_student_id_fkey
            FOREIGN KEY (student_id) REFERENCES core.students(student_id) ON DELETE RESTRICT;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'student_advance_student_id_fkey' AND confdeltype = 'c') THEN
        ALTER TABLE core.student_advance DROP CONSTRAINT student_advance_student_id_fkey;
        ALTER TABLE core.student_advance
            ADD CONSTRAINT student_advance_student_id_fkey
            FOREIGN KEY (student_id) REFERENCES core.students(student_id) ON DELETE RESTRICT;
    END IF;
END
$guards$;
