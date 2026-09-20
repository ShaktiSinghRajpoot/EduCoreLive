-- ============================================================================
-- Inventory test suite.
--
-- Stock is money on a shelf. The rules worth testing are the ones that stop the
-- number drifting away from what is actually there: that every change leaves a
-- ledger row, that the running total matches the sum of those rows, and that
-- nothing can take stock below zero.
--
-- Runs inside ONE transaction and ROLLS BACK.
--
--     psql ... -f inventory_tests.sql
--
-- COVERS
--   A. Item master — name, duplicates, SKU
--   B. Opening stock is a movement
--   C. Stock movement — in, out, and the floor at zero
--   D. The ledger IS the stock (recount agrees)
--   E. Purchases — totals, stock, and the invoice guard
--   F. Cancelling a purchase reverses it
--   G. Deleting an item that still has stock
--   H. Scope
-- ============================================================================

\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE TEMP TABLE _t(id serial, name text, ok boolean, detail text) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.chk(p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO _t(name, ok, detail) VALUES (p_name, p_ok, p_detail);
    RAISE NOTICE '  [%] %  %', CASE WHEN p_ok THEN 'PASS' ELSE 'FAIL' END, rpad(p_name, 54), p_detail;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.chk_eq(p_name text, p_got numeric, p_want numeric)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.chk(p_name, p_got IS NOT DISTINCT FROM p_want,
                        format('got %s, expected %s', COALESCE(p_got::text,'NULL'), p_want));
END $$;


DO $suite$
DECLARE
    c_tenant CONSTANT integer := 24;
    c_school CONSTANT integer := 34;
    c_user   CONSTANT integer := 39;

    c     refcursor;
    c2    refcursor;
    v_it1 integer;    -- the item most checks use
    v_it2 integer;
    v_sup integer;
    v_pid integer;
    v_n   integer;
    v_dec numeric;
    v_txt text;
    k_ok  boolean;
    k_msg text;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '========= INVENTORY TESTS =========';

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- A. Item master --------------------------------------';

    BEGIN
        c := 'a1';
        CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
             p_item_name => '   ', p_result => c);
        PERFORM pg_temp.chk('A1 blank item name refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('A1 blank item name refused', TRUE, SQLERRM);
    END;

    c := 'a2';
    CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
         p_item_name => 'ZZ School Tie', p_sku => 'ZZ-TIE-001',
         p_category => 'Uniform', p_item_type => 'Saleable', p_unit_type => 'Piece',
         p_opening_stock => 40, p_min_stock => 10, p_cost_price => 45,
         p_selling_price => 80, p_result => c);
    FETCH c INTO k_ok, k_msg, v_it1;
    PERFORM pg_temp.chk('A2 item created', COALESCE(k_ok, FALSE), format('item_id=%s', v_it1));

    -- The same name twice in one school is a data-entry slip, not a plan.
    BEGIN
        c := 'a3';
        CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
             p_item_name => 'ZZ School Tie', p_result => c);
        PERFORM pg_temp.chk('A3 duplicate item name refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('A3 duplicate item name refused', TRUE, SQLERRM);
    END;

    -- An SKU that is not unique is not an SKU.
    BEGIN
        c := 'a4';
        CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
             p_item_name => 'ZZ Other Item', p_sku => 'ZZ-TIE-001', p_result => c);
        PERFORM pg_temp.chk('A4 duplicate SKU refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('A4 duplicate SKU refused', TRUE, SQLERRM);
    END;

    -- ...but a blank SKU is fine, and more than one item may have none.
    c := 'a5';
    CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
         p_item_name => 'ZZ Notebook', p_category => 'Stationery',
         p_unit_type => 'Piece', p_opening_stock => 0, p_min_stock => 20,
         p_cost_price => 25, p_result => c);
    FETCH c INTO k_ok, k_msg, v_it2;
    PERFORM pg_temp.chk('A5 an item without an SKU is allowed', COALESCE(k_ok, FALSE), k_msg);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- B. Opening stock is a movement ----------------------';

    SELECT current_stock INTO v_dec FROM core.inventory_items WHERE item_id = v_it1;
    PERFORM pg_temp.chk_eq('B1 opening stock is on the item', v_dec, 40);

    SELECT COUNT(*), MAX(movement_type) INTO v_n, v_txt
      FROM core.inventory_stock_ledger WHERE item_id = v_it1;
    PERFORM pg_temp.chk_eq('B2 ...and it wrote exactly one ledger row', v_n, 1);
    PERFORM pg_temp.chk('B3 ...recorded as Opening', v_txt = 'Opening', format('got %s', v_txt));

    -- An item that starts empty has nothing to record.
    SELECT COUNT(*) INTO v_n FROM core.inventory_stock_ledger WHERE item_id = v_it2;
    PERFORM pg_temp.chk_eq('B4 zero opening stock writes no movement', v_n, 0);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- C. Stock movement -----------------------------------';

    c := 'c1';
    CALL core.sp_inventory_manage('MoveStock', c_tenant, c_school, c_user,
         p_item_id => v_it1, p_movement_type => 'Issue', p_quantity => 12,
         p_issued_to => 'Class 5A', p_result => c);
    FETCH c INTO k_ok, k_msg, v_dec;
    PERFORM pg_temp.chk_eq('C1 issuing 12 leaves 28', v_dec, 28);

    SELECT quantity, balance_after, issued_to INTO v_dec, v_n, v_txt
      FROM core.inventory_stock_ledger
     WHERE item_id = v_it1 ORDER BY movement_id DESC LIMIT 1;
    PERFORM pg_temp.chk_eq('C2 an issue is recorded as NEGATIVE', v_dec, -12);
    PERFORM pg_temp.chk('C3 ...with who it went to', v_txt = 'Class 5A', format('got %s', v_txt));

    c := 'c4';
    CALL core.sp_inventory_manage('MoveStock', c_tenant, c_school, c_user,
         p_item_id => v_it1, p_movement_type => 'Return', p_quantity => 2, p_result => c);
    FETCH c INTO k_ok, k_msg, v_dec;
    PERFORM pg_temp.chk_eq('C4 a return adds it back', v_dec, 30);

    c := 'c5';
    CALL core.sp_inventory_manage('MoveStock', c_tenant, c_school, c_user,
         p_item_id => v_it1, p_movement_type => 'Damage', p_quantity => 5, p_result => c);
    FETCH c INTO k_ok, k_msg, v_dec;
    PERFORM pg_temp.chk_eq('C5 damage takes it away', v_dec, 25);

    -- THE ONE THAT MATTERS: stock cannot go below zero. A negative figure is
    -- never something that really happened.
    BEGIN
        c := 'c6';
        CALL core.sp_inventory_manage('MoveStock', c_tenant, c_school, c_user,
             p_item_id => v_it1, p_movement_type => 'Issue', p_quantity => 999, p_result => c);
        PERFORM pg_temp.chk('C6 issuing more than is there is refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C6 issuing more than is there is refused', TRUE, SQLERRM);
    END;

    SELECT current_stock INTO v_dec FROM core.inventory_items WHERE item_id = v_it1;
    PERFORM pg_temp.chk_eq('C7 ...and the refused issue changed nothing', v_dec, 25);

    BEGIN
        c := 'c8';
        CALL core.sp_inventory_manage('MoveStock', c_tenant, c_school, c_user,
             p_item_id => v_it1, p_movement_type => 'Issue', p_quantity => 0, p_result => c);
        PERFORM pg_temp.chk('C8 a zero quantity is refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C8 a zero quantity is refused', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'c9';
        CALL core.sp_inventory_manage('MoveStock', c_tenant, c_school, c_user,
             p_item_id => v_it1, p_movement_type => 'Teleport', p_quantity => 1, p_result => c);
        PERFORM pg_temp.chk('C9 an invented movement type is refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C9 an invented movement type is refused', TRUE, SQLERRM);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- D. The ledger IS the stock --------------------------';

    -- current_stock is a cache. If it ever stops matching the sum of the
    -- movements, every screen is quoting a number nobody can justify.
    SELECT SUM(quantity) INTO v_dec FROM core.inventory_stock_ledger WHERE item_id = v_it1;
    PERFORM pg_temp.chk_eq('D1 the ledger sums to the running total', v_dec, 25);

    SELECT balance_after INTO v_dec FROM core.inventory_stock_ledger
     WHERE item_id = v_it1 ORDER BY movement_id DESC LIMIT 1;
    PERFORM pg_temp.chk_eq('D2 the last row carries the same balance', v_dec, 25);

    -- Break the cache on purpose, then prove Recount repairs it.
    UPDATE core.inventory_items SET current_stock = 9999 WHERE item_id = v_it1;
    c := 'd3';
    CALL core.sp_inventory_manage('Recount', c_tenant, c_school, c_user, p_result => c);

    SELECT current_stock INTO v_dec FROM core.inventory_items WHERE item_id = v_it1;
    PERFORM pg_temp.chk_eq('D3 Recount rebuilds the total from the ledger', v_dec, 25);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- E. Purchases ----------------------------------------';

    c := 'e0';
    CALL core.sp_inventory_manage('SaveSupplier', c_tenant, c_school, c_user,
         p_supplier_name => 'ZZ Uniform House', p_mobile => '9990001234', p_result => c);
    FETCH c INTO k_ok, k_msg, v_sup;
    PERFORM pg_temp.chk('E0 supplier created', COALESCE(k_ok, FALSE), format('supplier_id=%s', v_sup));

    BEGIN
        c := 'e1'; c2 := 'e1b';
        CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
             p_supplier_id => v_sup, p_purchase_date => CURRENT_DATE,
             p_items => '[]'::jsonb, p_result => c, p_result2 => c2);
        PERFORM pg_temp.chk('E1 a purchase with no lines is refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('E1 a purchase with no lines is refused', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'e2'; c2 := 'e2b';
        CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
             p_supplier_id => v_sup, p_purchase_date => CURRENT_DATE + 5,
             p_items => jsonb_build_array(jsonb_build_object(
                 'itemId', v_it1, 'quantity', 1, 'unitPrice', 10, 'taxPercent', 0)),
             p_result => c, p_result2 => c2);
        PERFORM pg_temp.chk('E2 a future-dated purchase is refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('E2 a future-dated purchase is refused', TRUE, SQLERRM);
    END;

    -- 100 ties at 50 with 10% tax, plus 200 notebooks at 20 with no tax.
    c := 'e3'; c2 := 'e3b';
    CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
         p_supplier_id => v_sup, p_purchase_date => CURRENT_DATE,
         p_invoice_no => 'ZZ-INV-001', p_payment_mode => 'Bank Transfer',
         p_items => jsonb_build_array(
             jsonb_build_object('itemId', v_it1, 'quantity', 100, 'unitPrice', 50, 'taxPercent', 10),
             jsonb_build_object('itemId', v_it2, 'quantity', 200, 'unitPrice', 20, 'taxPercent', 0)),
         p_result => c, p_result2 => c2);
    FETCH c INTO k_ok, k_msg, v_pid, v_dec;
    PERFORM pg_temp.chk('E3 purchase saved', COALESCE(k_ok, FALSE), k_msg);

    -- 100x50 = 5000, +10% = 500;  200x20 = 4000, no tax.  5000+4000+500 = 9500
    PERFORM pg_temp.chk_eq('E4 grand total is lines plus their own tax', v_dec, 9500);

    SELECT sub_total, tax_total INTO v_dec, v_n FROM core.inventory_purchases
     WHERE purchase_id = v_pid;
    PERFORM pg_temp.chk_eq('E5 sub total excludes tax', v_dec, 9000);

    SELECT tax_total INTO v_dec FROM core.inventory_purchases WHERE purchase_id = v_pid;
    PERFORM pg_temp.chk_eq('E6 tax is only on the taxed line', v_dec, 500);

    -- The point of the whole screen: stock went up.
    SELECT current_stock INTO v_dec FROM core.inventory_items WHERE item_id = v_it1;
    PERFORM pg_temp.chk_eq('E7 the purchase raised the stock (25 + 100)', v_dec, 125);

    SELECT movement_type, reference_id INTO v_txt, v_n
      FROM core.inventory_stock_ledger WHERE item_id = v_it1 ORDER BY movement_id DESC LIMIT 1;
    PERFORM pg_temp.chk('E8 ...through a Purchase movement', v_txt = 'Purchase', format('got %s', v_txt));
    PERFORM pg_temp.chk_eq('E9 ...pointing back at the invoice', v_n, v_pid);

    -- The same bill entered twice is the classic store-room mistake.
    BEGIN
        c := 'e10'; c2 := 'e10b';
        CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
             p_supplier_id => v_sup, p_purchase_date => CURRENT_DATE,
             p_invoice_no => 'ZZ-INV-001',
             p_items => jsonb_build_array(jsonb_build_object(
                 'itemId', v_it1, 'quantity', 1, 'unitPrice', 10, 'taxPercent', 0)),
             p_result => c, p_result2 => c2);
        PERFORM pg_temp.chk('E10 the same invoice number twice is refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('E10 the same invoice number twice is refused', TRUE, SQLERRM);
    END;

    -- A line naming an item from nowhere must not leave a half-written purchase.
    DECLARE v_before integer;
    BEGIN
        SELECT COUNT(*) INTO v_before FROM core.inventory_purchases
         WHERE tenant_id = c_tenant AND school_id = c_school;
        BEGIN
            c := 'e11'; c2 := 'e11b';
            CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
                 p_supplier_id => v_sup, p_purchase_date => CURRENT_DATE,
                 p_items => jsonb_build_array(jsonb_build_object(
                     'itemId', 999999, 'quantity', 1, 'unitPrice', 10, 'taxPercent', 0)),
                 p_result => c, p_result2 => c2);
            PERFORM pg_temp.chk('E11 a line with an unknown item is refused', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('E11 a line with an unknown item is refused', TRUE, SQLERRM);
        END;
        SELECT COUNT(*) INTO v_n FROM core.inventory_purchases
         WHERE tenant_id = c_tenant AND school_id = c_school;
        PERFORM pg_temp.chk_eq('E12 ...and no half-purchase was left behind', v_n, v_before);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- F. Cancelling a purchase ----------------------------';

    c := 'f1'; c2 := 'f1b';
    CALL core.sp_inventory_purchase_manage('Cancel', c_tenant, c_school, c_user,
         p_purchase_id => v_pid, p_remarks => 'wrong supplier',
         p_result => c, p_result2 => c2);

    SELECT current_stock INTO v_dec FROM core.inventory_items WHERE item_id = v_it1;
    PERFORM pg_temp.chk_eq('F1 cancelling took the stock back out', v_dec, 25);

    SELECT movement_type INTO v_txt FROM core.inventory_stock_ledger
     WHERE item_id = v_it1 ORDER BY movement_id DESC LIMIT 1;
    PERFORM pg_temp.chk('F2 ...with a reversal row, not by deleting the original',
                        v_txt = 'PurchaseCancel', format('got %s', v_txt));

    SELECT COUNT(*) INTO v_n FROM core.inventory_stock_ledger
     WHERE item_id = v_it1 AND movement_type = 'Purchase';
    PERFORM pg_temp.chk_eq('F3 the original Purchase row survives', v_n, 1);

    SELECT is_cancelled, cancel_reason INTO k_ok, v_txt FROM core.inventory_purchases
     WHERE purchase_id = v_pid;
    PERFORM pg_temp.chk('F4 the invoice is marked cancelled', COALESCE(k_ok, FALSE), '');
    PERFORM pg_temp.chk('F5 ...with the reason kept', v_txt = 'wrong supplier', format('got %s', v_txt));

    BEGIN
        c := 'f6'; c2 := 'f6b';
        CALL core.sp_inventory_purchase_manage('Cancel', c_tenant, c_school, c_user,
             p_purchase_id => v_pid, p_result => c, p_result2 => c2);
        PERFORM pg_temp.chk('F6 cancelling twice is refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('F6 cancelling twice is refused', TRUE, SQLERRM);
    END;

    -- A purchase whose goods have already gone out cannot be un-received.
    DECLARE v_p2 integer;
    BEGIN
        c := 'f7'; c2 := 'f7b';
        CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
             p_supplier_id => v_sup, p_purchase_date => CURRENT_DATE,
             p_invoice_no => 'ZZ-INV-002',
             p_items => jsonb_build_array(jsonb_build_object(
                 'itemId', v_it1, 'quantity', 10, 'unitPrice', 50, 'taxPercent', 0)),
             p_result => c, p_result2 => c2);
        FETCH c INTO k_ok, k_msg, v_p2;

        -- Issue everything, so there is nothing left to reverse.
        c := 'f7c';
        CALL core.sp_inventory_manage('MoveStock', c_tenant, c_school, c_user,
             p_item_id => v_it1, p_movement_type => 'Issue', p_quantity => 35, p_result => c);

        BEGIN
            c := 'f7d'; c2 := 'f7e';
            CALL core.sp_inventory_purchase_manage('Cancel', c_tenant, c_school, c_user,
                 p_purchase_id => v_p2, p_result => c, p_result2 => c2);
            PERFORM pg_temp.chk('F7 cannot cancel once the goods are gone', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('F7 cannot cancel once the goods are gone', TRUE, SQLERRM);
        END;
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- G. Deleting an item ---------------------------------';

    -- A fresh item with stock of its own. The earlier two are both at zero by
    -- now — the notebook's purchase was reversed in F, and the ties were all
    -- issued — so neither could show this rule.
    DECLARE v_it3 integer;
    BEGIN
        c := 'g0';
        CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
             p_item_name => 'ZZ Sports Ball', p_category => 'Sports',
             p_unit_type => 'Piece', p_opening_stock => 6, p_result => c);
        FETCH c INTO k_ok, k_msg, v_it3;

        BEGIN
            c := 'g1';
            CALL core.sp_inventory_manage('DeleteItem', c_tenant, c_school, c_user,
                 p_item_id => v_it3, p_result => c);
            PERFORM pg_temp.chk('G1 deleting an item with stock is refused', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('G1 deleting an item with stock is refused', TRUE, SQLERRM);
        END;

        -- Take it to zero, then it can go.
        c := 'g2';
        CALL core.sp_inventory_manage('MoveStock', c_tenant, c_school, c_user,
             p_item_id => v_it3, p_movement_type => 'Issue', p_quantity => 6, p_result => c);

        c := 'g3';
        CALL core.sp_inventory_manage('DeleteItem', c_tenant, c_school, c_user,
             p_item_id => v_it3, p_result => c);

        SELECT is_deleted INTO k_ok FROM core.inventory_items WHERE item_id = v_it3;
        PERFORM pg_temp.chk('G2 an empty item can be deleted', COALESCE(k_ok, FALSE), '');

        -- Soft delete: the history of what passed through it is still there.
        SELECT COUNT(*) INTO v_n FROM core.inventory_stock_ledger WHERE item_id = v_it3;
        PERFORM pg_temp.chk('G3 ...and its stock history survives', v_n > 0, format('%s row(s)', v_n));

        -- And the name it used is free again, because the unique index only
        -- covers rows that are not deleted.
        c := 'g4';
        CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
             p_item_name => 'ZZ Sports Ball', p_result => c);
        FETCH c INTO k_ok, k_msg, v_n;
        PERFORM pg_temp.chk('G4 the deleted name can be used again',
                            COALESCE(k_ok, FALSE), k_msg);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- H. Scope --------------------------------------------';

    SELECT COUNT(*) INTO v_n FROM core.inventory_items
     WHERE item_id = v_it1 AND tenant_id = 23 AND school_id = 33;
    PERFORM pg_temp.chk_eq('H1 our item belongs to no other school', v_n, 0);

    BEGIN
        c := 'h2';
        CALL core.sp_inventory_manage('MoveStock', 23, 33, c_user,
             p_item_id => v_it1, p_movement_type => 'Issue', p_quantity => 1, p_result => c);
        PERFORM pg_temp.chk('H2 another school cannot move our stock', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('H2 another school cannot move our stock', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'h3';
        CALL core.sp_inventory_manage('SaveItem', 1, 0, c_user,
             p_item_name => 'ZZ Platform Item', p_result => c);
        PERFORM pg_temp.chk('H3 platform scope refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('H3 platform scope refused', TRUE, SQLERRM);
    END;

    BEGIN
        c := 'h4'; c2 := 'h4b';
        CALL core.sp_inventory_purchase_manage('Save', 23, 33, c_user,
             p_purchase_date => CURRENT_DATE,
             p_items => jsonb_build_array(jsonb_build_object(
                 'itemId', v_it1, 'quantity', 1, 'unitPrice', 10, 'taxPercent', 0)),
             p_result => c, p_result2 => c2);
        PERFORM pg_temp.chk('H4 another school cannot buy against our item', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('H4 another school cannot buy against our item', TRUE, SQLERRM);
    END;
END
$suite$;


DO $sum$
DECLARE p integer; f integer; r record;
BEGIN
    SELECT COUNT(*) FILTER (WHERE ok), COUNT(*) FILTER (WHERE NOT ok) INTO p, f FROM _t;
    RAISE NOTICE '';
    RAISE NOTICE '========== RESULT: % passed, % failed ==========', p, f;
    IF f > 0 THEN
        RAISE NOTICE 'failures:';
        FOR r IN SELECT name, detail FROM _t WHERE NOT ok ORDER BY id LOOP
            RAISE NOTICE '   %  %', rpad(r.name, 54), r.detail;
        END LOOP;
    END IF;
    RAISE NOTICE '';
END
$sum$;

ROLLBACK;
