-- Store extras (19 Oct 2026): order list, size exchange, supplier dues + Cash Book.
-- QA Test School (tenant 32, school 45, admin 62). Everything is ROLLED BACK.
-- Run from this folder:   psql ... -f store_extras_tests.sql
\set ON_ERROR_STOP 1
BEGIN;

CREATE TEMP TABLE _r(n serial, ok boolean, name text, detail text) ON COMMIT DROP;
CREATE FUNCTION pg_temp.chk(p_ok boolean, p_name text, p_detail text DEFAULT '') RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO _r(ok, name, detail) VALUES (COALESCE(p_ok, FALSE), p_name, p_detail);
    RAISE NOTICE '[%] %  %', CASE WHEN COALESCE(p_ok, FALSE) THEN 'PASS' ELSE 'FAIL' END, p_name, p_detail;
END $$;

DO $t$
DECLARE
    c refcursor; c2 refcursor; r record;
    v_sup integer; v_item integer; v_size integer; v_line integer; v_ledger integer;
    v_s1 numeric; v_s2 numeric; v_n integer; v_due numeric; v_pid integer; v_pay integer; v_txt text;
BEGIN
    -- ── Order list ──
    c := 'o1'; CALL core.sp_inventory_order_list(32, 45, 62, '2026-27', c); v_n := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_n := v_n + 1;
        IF r.item = 'Uniform' THEN v_txt := r.sizes; END IF;
        IF r.still_need <> GREATEST(r.children - r.have, 0) OR r.to_order <> GREATEST(r.children - r.have - r.in_stock, 0) THEN
            PERFORM pg_temp.chk(FALSE, 'O1 need / order add up', r.item);
        END IF;
    END LOOP; CLOSE c;
    PERFORM pg_temp.chk(v_n > 0, 'O1 the order list has a line per item', v_n || ' lines');
    PERFORM pg_temp.chk(v_txt LIKE '%24:%' AND v_txt LIKE '%32:%', 'O2 the uniform sizes are one line with stock per size', COALESCE(v_txt, '(no Uniform line)'));
    BEGIN
        c := 'o2'; CALL core.sp_inventory_order_list(32, 45, 62, '', c);
        PERFORM pg_temp.chk(FALSE, 'O3 a session is required', 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk(TRUE, 'O3 a session is required', SQLERRM); END;

    -- ── Size exchange: an unpaid "Uniform - 24" line moves to "Uniform - 32" ──
    SELECT l.line_id, l.ledger_id INTO v_line, v_ledger
      FROM core.inventory_student_sale_lines l
      JOIN core.inventory_student_sales sa ON sa.sale_id = l.sale_id
      JOIN core.inventory_items i ON i.item_id = l.item_id
      JOIN core.student_ledger sl ON sl.ledger_id = l.ledger_id
     WHERE sa.tenant_id = 32 AND sa.school_id = 45 AND i.item_name = 'Uniform - 24'
       AND l.returned_at IS NULL AND sl.amount_paid = 0 AND sl.status <> 'Closed'
     ORDER BY l.line_id LIMIT 1;
    SELECT item_id INTO v_size FROM core.inventory_items WHERE tenant_id = 32 AND school_id = 45 AND item_name = 'Uniform - 32' AND NOT is_deleted;
    SELECT item_id INTO v_item FROM core.inventory_items WHERE tenant_id = 32 AND school_id = 45 AND item_name = 'Uniform - 24' AND NOT is_deleted;
    SELECT current_stock INTO v_s1 FROM core.inventory_items WHERE item_id = v_item;
    SELECT current_stock INTO v_s2 FROM core.inventory_items WHERE item_id = v_size;

    c := 'x1'; CALL core.sp_inventory_student_sale('Exchange', 32, 45, 62, p_line_id => v_line, p_item_id => v_size, p_result => c);
    FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk((SELECT item_id FROM core.inventory_student_sale_lines WHERE line_id = v_line) = v_size,
                        'X1 the sale line is now the new size', r.message);
    PERFORM pg_temp.chk((SELECT current_stock FROM core.inventory_items WHERE item_id = v_item) = v_s1 + 1
                    AND (SELECT current_stock FROM core.inventory_items WHERE item_id = v_size) = v_s2 - 1,
                        'X2 the old size back on the shelf, the new one off it');
    PERFORM pg_temp.chk((SELECT installment_label FROM core.student_ledger WHERE ledger_id = v_ledger) = '32',
                        'X3 the fee line reads the new size', (SELECT installment_label FROM core.student_ledger WHERE ledger_id = v_ledger));
    BEGIN
        c := 'x2'; CALL core.sp_inventory_student_sale('Exchange', 32, 45, 62, p_line_id => v_line, p_item_id => v_size, p_result => c);
        PERFORM pg_temp.chk(FALSE, 'X4 the same size again is refused', 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk(TRUE, 'X4 the same size again is refused', SQLERRM); END;
    SELECT item_id INTO v_pid FROM core.inventory_items WHERE tenant_id = 32 AND item_name = 'School Tie' AND NOT is_deleted LIMIT 1;
    BEGIN
        c := 'x3'; CALL core.sp_inventory_student_sale('Exchange', 32, 45, 62, p_line_id => v_line, p_item_id => v_pid, p_result => c);
        PERFORM pg_temp.chk(FALSE, 'X5 a different item is refused', 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk(TRUE, 'X5 a different item is refused', SQLERRM); END;

    -- ── Supplier dues ──
    SELECT supplier_id INTO v_sup FROM core.inventory_suppliers WHERE tenant_id = 32 AND school_id = 45 AND supplier_name = 'Sharma Uniform House';
    v_due := core.fn_supplier_due(32, 45, v_sup);
    c := 'p1'; c2 := 'p1b';
    CALL core.sp_inventory_purchase_manage('Save', 32, 45, 62, p_supplier_id => v_sup, p_purchase_date => CURRENT_DATE,
         p_invoice_no => 'ZZ-CREDIT-1', p_payment_mode => 'Credit',
         p_items => jsonb_build_array(jsonb_build_object('itemId', v_item, 'quantity', 10, 'unitPrice', 50, 'taxPercent', 0)),
         p_result => c, p_result2 => c2);
    CLOSE c; CLOSE c2;
    PERFORM pg_temp.chk(core.fn_supplier_due(32, 45, v_sup) = v_due + 500, 'S1 a credit bill is owed to the supplier',
                        'due ' || core.fn_supplier_due(32, 45, v_sup));
    PERFORM pg_temp.chk(NOT EXISTS (SELECT 1 FROM core.fn_school_money(32, 45, CURRENT_DATE, CURRENT_DATE) m WHERE m.ref = 'ZZ-CREDIT-1'),
                        'S2 the credit bill is not money out in the Cash Book');

    c := 'p2'; CALL core.sp_inventory_supplier_pay('Pay', 32, 45, 62, p_supplier_id => v_sup, p_amount => 200,
                    p_payment_mode => 'UPI', p_reference_no => 'UPI-1', p_result => c);
    FETCH c INTO r; v_pay := r.payment_id; CLOSE c;
    PERFORM pg_temp.chk(core.fn_supplier_due(32, 45, v_sup) = v_due + 300, 'S3 a payment lowers what is due', r.message);
    PERFORM pg_temp.chk(EXISTS (SELECT 1 FROM core.fn_school_money(32, 45, CURRENT_DATE, CURRENT_DATE) m
                                 WHERE m.ref = 'SP-' || v_pay AND m.money_out = 200 AND m.book = 'Bank'),
                        'S4 the payment is money out (bank) in the Cash Book');
    BEGIN
        c := 'p3'; CALL core.sp_inventory_supplier_pay('Pay', 32, 45, 62, p_supplier_id => v_sup, p_amount => v_due + 301,
                        p_payment_mode => 'Cash', p_result => c);
        PERFORM pg_temp.chk(FALSE, 'S5 paying more than is due is refused', 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk(TRUE, 'S5 paying more than is due is refused', SQLERRM); END;
    BEGIN
        c := 'p4'; CALL core.sp_inventory_supplier_pay('Pay', 32, 45, 62, p_supplier_id => v_sup, p_amount => 10,
                        p_payment_mode => 'Credit', p_result => c);
        PERFORM pg_temp.chk(FALSE, 'S6 a payment needs a real mode', 'accepted');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk(TRUE, 'S6 a payment needs a real mode', SQLERRM); END;

    c := 'p5'; CALL core.sp_inventory_supplier_pay('Cancel', 32, 45, 62, p_payment_id => v_pay, p_reason => 'wrong amount', p_result => c); CLOSE c;
    PERFORM pg_temp.chk(core.fn_supplier_due(32, 45, v_sup) = v_due + 500, 'S7 a cancelled payment is due again');
    PERFORM pg_temp.chk(EXISTS (SELECT 1 FROM core.fn_school_money(32, 45, CURRENT_DATE, CURRENT_DATE) m
                                 WHERE m.kind = 'Supplier payment cancelled' AND m.money_in = 200),
                        'S8 the cancel is money back in on the cancel day');
    PERFORM pg_temp.chk(EXISTS (SELECT 1 FROM core.inventory_supplier_payments WHERE payment_id = v_pay AND is_cancelled),
                        'S9 the payment row stays, marked cancelled');
    c := 'p6'; CALL core.sp_inventory_supplier_pay('List', 32, 45, 62, p_supplier_id => v_sup, p_result => c); v_n := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_n := v_n + 1; END LOOP; CLOSE c;
    PERFORM pg_temp.chk(v_n >= 1, 'S10 the supplier''s payments are listed', v_n || ' row(s)');

    SELECT COUNT(*) FILTER (WHERE ok), COUNT(*) FILTER (WHERE NOT ok) INTO v_n, v_pid FROM _r;
    RAISE NOTICE '== % passed, % failed ==', v_n, v_pid;
END $t$;

ROLLBACK;
