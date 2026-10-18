-- Expenses and the Cash Book (18 Oct 2026). QA Test School (tenant 32, school 45, admin 62).
-- Everything is ROLLED BACK. Run from this folder:
--     psql ... -f expense_cashbook_tests.sql
\set ON_ERROR_STOP 1
BEGIN;

CREATE TEMP TABLE _r(n serial, ok boolean, name text, detail text) ON COMMIT DROP;
CREATE FUNCTION pg_temp.chk(p_ok boolean, p_name text, p_detail text DEFAULT '') RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO _r(ok, name, detail) VALUES (COALESCE(p_ok, FALSE), p_name, p_detail);
    RAISE NOTICE '[%] %  %', CASE WHEN COALESCE(p_ok, FALSE) THEN 'PASS' ELSE 'FAIL' END, p_name, p_detail;
END $$;

-- one call of sp_expense_manage, returning its message
CREATE FUNCTION pg_temp.ex(p_op text, p_id int DEFAULT NULL, p_date date DEFAULT NULL, p_cat int DEFAULT NULL,
                           p_amt numeric DEFAULT NULL, p_amt2 numeric DEFAULT NULL, p_mode text DEFAULT NULL, p_name text DEFAULT NULL,
                           p_t int DEFAULT 32, p_s int DEFAULT 45)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'ex'; r record;
BEGIN
    CALL core.sp_expense_manage(p_op, p_t, p_s, 62, p_id, p_date, p_cat, p_amt, p_amt2, p_mode, 'Test payee', NULL, NULL, p_name, NULL, NULL, NULL, c);
    FETCH c INTO r; CLOSE c;
    RETURN to_jsonb(r) ->> 'message';   -- a list (Categories) has no message
END $$;

-- the Cash Book's summary row for a range and book
CREATE FUNCTION pg_temp.cb(p_from date, p_to date, p_book text DEFAULT 'All',
                           OUT opening numeric, OUT money_in numeric, OUT money_out numeric, OUT closing numeric, OUT last_balance numeric)
LANGUAGE plpgsql AS $$
DECLARE a refcursor := 'cs'; b refcursor := 'cl'; c refcursor := 'ch'; d refcursor := 'cm'; r record;
BEGIN
    CALL core.sp_cashbook(32, 45, 62, p_from, p_to, p_book, a, b, c, d);
    FETCH a INTO r; opening := r.opening; money_in := r.money_in; money_out := r.money_out; closing := r.closing;
    last_balance := opening;
    LOOP FETCH b INTO r; EXIT WHEN NOT FOUND; last_balance := r.balance; END LOOP;
    CLOSE a; CLOSE b; CLOSE c; CLOSE d;
END $$;

DO $t$
DECLARE
    v_cat int; v_txt text; v_id int; r record; r2 record; v_n int; v_m int; v_fees numeric; v_store numeric;
    v_today date := CURRENT_DATE; v_month date := date_trunc('month', CURRENT_DATE)::date;
BEGIN
    DELETE FROM core.cashbook_opening WHERE tenant_id = 32 AND school_id = 45;

    RAISE NOTICE '== Expenses ==';
    v_txt := pg_temp.ex('Categories');
    SELECT COUNT(*) INTO v_n FROM core.expense_categories WHERE tenant_id = 32 AND school_id = 45;
    PERFORM pg_temp.chk(v_n >= 11, 'X1 a first use creates the usual categories', v_n || ' categories');
    SELECT category_id INTO v_cat FROM core.expense_categories WHERE tenant_id = 32 AND school_id = 45 AND name = 'Electricity';

    v_txt := pg_temp.ex('Save', NULL, v_today, v_cat, 2500, NULL, 'Cash');
    SELECT expense_id INTO v_id FROM core.expenses WHERE tenant_id = 32 AND amount = 2500 AND expense_date = v_today ORDER BY expense_id DESC LIMIT 1;
    PERFORM pg_temp.chk(v_id IS NOT NULL, 'X2 an electricity bill of Rs 2500 in cash is saved', v_txt);

    BEGIN v_txt := pg_temp.ex('Save', NULL, v_today + 1, v_cat, 100); PERFORM pg_temp.chk(FALSE, 'X3 no expense in the future', 'saved');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk(TRUE, 'X3 no expense in the future', SQLERRM); END;
    BEGIN v_txt := pg_temp.ex('Save', NULL, v_today, v_cat, 0); PERFORM pg_temp.chk(FALSE, 'X4 the amount must be more than 0', 'saved');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk(TRUE, 'X4 the amount must be more than 0', SQLERRM); END;
    BEGIN v_txt := pg_temp.ex('SaveCategory', NULL, NULL, NULL, NULL, NULL, NULL, 'electricity'); PERFORM pg_temp.chk(FALSE, 'X5 no second category with the same name', 'saved');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk(TRUE, 'X5 no second category with the same name', SQLERRM); END;
    BEGIN v_txt := pg_temp.ex('Cancel', v_id, NULL, NULL, NULL, NULL, NULL, 'x', 99001, 99001); PERFORM pg_temp.chk(FALSE, 'X6 another school cannot cancel it', 'cancelled');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk(TRUE, 'X6 another school cannot cancel it', SQLERRM); END;

    RAISE NOTICE '';
    RAISE NOTICE '== Cash Book ==';
    -- money in this month = the fee money lines in real modes (+ supplier returns / cancelled bills)
    SELECT COALESCE(SUM(amount), 0) INTO v_fees FROM core.fn_fee_money_lines(32, 45, v_month, v_today) WHERE mode NOT IN ('Advance', 'To wallet');
    SELECT * INTO r FROM pg_temp.cb(v_month, v_today);
    SELECT COALESCE(SUM(money_in), 0) AS fin, COALESCE(SUM(money_out), 0) AS fout INTO r2
      FROM core.fn_school_money(32, 45, v_month, v_today) WHERE category IN ('Fees', 'Books & Uniform sales');
    PERFORM pg_temp.chk(r2.fin - r2.fout = v_fees, 'C1 fees (+ store sales paid with them) = the Day Close money lines', 'net fees Rs ' || v_fees);
    PERFORM pg_temp.chk(r.money_out >= 2500, 'C2 the electricity bill is money out', 'out Rs ' || r.money_out);
    PERFORM pg_temp.chk(r.closing = r.opening + r.money_in - r.money_out AND r.last_balance = r.closing,
                        'C3 closing = opening + in - out, and the last running balance says the same', 'closing Rs ' || r.closing);

    SELECT * INTO r FROM pg_temp.cb(v_today, v_today, 'Cash');
    v_txt := pg_temp.ex('Cancel', v_id, NULL, NULL, NULL, NULL, NULL, 'Entered twice (test)');
    SELECT * INTO r2 FROM pg_temp.cb(v_today, v_today, 'Cash');
    PERFORM pg_temp.chk(r2.money_in - r.money_in = 2500 AND r2.closing - r.closing = 2500,
                        'C4 a cancelled expense comes back as money in on the day it was cancelled', v_txt);

    -- the QA store bill QABD-001 (bought 2000, returned 400, cancelled) nets to 0 in the book
    SELECT COALESCE(SUM(money_in - money_out), 0) INTO v_fees FROM core.fn_school_money(32, 45, DATE '2026-10-01', v_today) WHERE ref = 'QABD-001';
    SELECT COUNT(*) INTO v_n FROM core.inventory_purchases WHERE tenant_id = 32 AND invoice_no = 'QABD-001';
    PERFORM pg_temp.chk(v_n = 0 OR v_fees = 0, 'C5 a bought, part-returned, cancelled bill nets to 0', 'net Rs ' || v_fees);

    -- opening balance
    v_txt := pg_temp.ex('SetOpening', NULL, DATE '2026-10-01', NULL, 10000, 5000);
    SELECT * INTO r FROM pg_temp.cb(DATE '2026-10-01', v_today);
    PERFORM pg_temp.chk(r.opening = 15000, 'C6 the book from the opening date opens with cash + bank', 'opening Rs ' || r.opening);
    SELECT * INTO r2 FROM pg_temp.cb(DATE '2026-10-10', v_today);
    SELECT COALESCE(SUM(money_in - money_out), 0) INTO v_fees FROM core.fn_school_money(32, 45, DATE '2026-10-01', DATE '2026-10-09');
    PERFORM pg_temp.chk(r2.opening = 15000 + v_fees, 'C7 a later start carries the days before it', 'opening Rs ' || r2.opening);
    PERFORM pg_temp.chk(r2.closing = r.closing, 'C8 both ranges end on the same closing balance', 'Rs ' || r.closing);
    SELECT * INTO r FROM pg_temp.cb(DATE '2026-09-01', DATE '2026-09-30');
    PERFORM pg_temp.chk(r.money_in = 0 AND r.money_out = 0, 'C9 days before the opening date are not in the book');
    SELECT (pg_temp.cb(DATE '2026-10-01', v_today, 'Cash')).opening + (pg_temp.cb(DATE '2026-10-01', v_today, 'Bank')).opening INTO v_fees;
    PERFORM pg_temp.chk(v_fees = 15000, 'C10 cash book + bank book open at 10000 + 5000');

    -- books / uniform paid at Collect Fees show as sales, not fees, and the two add up to the receipts
    SELECT COALESCE(SUM(money_in - money_out), 0) INTO v_fees FROM core.fn_school_money(32, 45, v_month, v_today) WHERE category = 'Books & Uniform sales';
    SELECT COALESCE(SUM(d.amount), 0) INTO v_store FROM core.fee_payment_details d JOIN core.fee_payments p ON p.payment_id = d.payment_id
     WHERE p.tenant_id = 32 AND p.school_id = 45 AND NOT COALESCE(p.is_cancelled, FALSE)
       AND p.payment_date BETWEEN to_char(v_month, 'YYYY-MM-DD') AND to_char(v_today, 'YYYY-MM-DD')
       AND EXISTS (SELECT 1 FROM core.inventory_student_sale_lines sl WHERE sl.ledger_id = d.ledger_id);
    PERFORM pg_temp.chk(v_fees = v_store,
                        'C12 store items paid at Collect Fees are "Books & Uniform sales"', 'Rs ' || v_fees);
    BEGIN v_txt := pg_temp.ex('SetOpening', NULL, v_today + 3, NULL, 1, 1); PERFORM pg_temp.chk(FALSE, 'C11 no opening balance in the future', 'saved');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk(TRUE, 'C11 no opening balance in the future', SQLERRM); END;

    SELECT COUNT(*) FILTER (WHERE ok), COUNT(*) FILTER (WHERE NOT ok) INTO v_n, v_m FROM _r;
    RAISE NOTICE '';
    RAISE NOTICE '== % passed, % failed ==', v_n, v_m;
END $t$;

ROLLBACK;
