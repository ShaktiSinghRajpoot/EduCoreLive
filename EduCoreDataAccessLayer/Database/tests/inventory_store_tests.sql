-- ============================================================================
-- Inventory / Store test suite -- the deeper pass.
--
-- inventory_tests.sql proves the happy rules: a ledger row per change, no stock
-- below zero, a purchase raises stock and a cancel reverses it. This suite goes
-- after the edges a store keeper actually hits -- a negative opening figure, a
-- decimal quantity with three places, the same item on two lines of one bill,
-- the same bill under a re-created supplier, a cancel after part of the goods
-- went out -- and after the one invariant that makes stock trustworthy:
--
--     current_stock = SUM(ledger quantity)  and  balance_after is a running sum
--
-- Runs inside ONE transaction and ROLLS BACK.
--
--     psql ... -f inventory_store_tests.sql
--
-- The first run of this suite found 10 bugs; they are fixed (see the change log
-- in docs/SCALING-AND-FIXES.md, 2026-10-10 "Inventory: deep test pass") and the
-- checks below now assert the corrected behaviour. Checks tagged "(rule)" pin a
-- business rule the school chose (D-1..D-11 in docs/test-cases/inventory_store.md).
--
-- COVERS
--   A. Item master edges          (ITM)
--   B. List, low stock, valuation (LST)
--   C. Stock movement edges       (MOV)
--   D. Suppliers                  (SUP)
--   E. Purchases                  (PUR)
--   F. Cancelling a purchase      (CAN)
--   G. The ledger IS the stock    (LED)
--   H. Scope                      (TEN)
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

-- current_stock minus the sum of the item's ledger. Zero means the cache is honest.
CREATE OR REPLACE FUNCTION pg_temp.drift(p_item integer)
RETURNS numeric LANGUAGE sql AS $$
    SELECT i.current_stock - COALESCE((SELECT SUM(l.quantity) FROM core.inventory_stock_ledger l
                                        WHERE l.item_id = i.item_id), 0)
    FROM core.inventory_items i WHERE i.item_id = p_item;
$$;

-- Rows of the item whose balance_after is not the running sum up to that row.
CREATE OR REPLACE FUNCTION pg_temp.bad_balances(p_item integer)
RETURNS integer LANGUAGE sql AS $$
    SELECT COUNT(*)::int FROM (
        SELECT balance_after,
               SUM(quantity) OVER (ORDER BY movement_id) AS running
        FROM core.inventory_stock_ledger WHERE item_id = p_item) x
    WHERE x.balance_after <> x.running;
$$;


DO $suite$
DECLARE
    c_tenant CONSTANT integer := 32;   -- QA Test School
    c_school CONSTANT integer := 45;
    c_user   CONSTANT integer := 62;
    o_tenant CONSTANT integer := 99001;   -- the other school (exists only inside the rolled-back test)
    o_school CONSTANT integer := 99001;

    c     refcursor;
    c2    refcursor;
    r     record;
    v_it  integer;     -- scratch item
    v_ti  integer;     -- "ZZS Tie": the item most checks use
    v_nb  integer;     -- "ZZS Notebook"
    v_sup integer;     -- "ZZS Uniform House"
    v_sp2 integer;     -- "ZZS Paper Mart"
    v_pid integer;
    v_p2  integer;
    v_n   integer;
    v_m   integer;
    v_dec numeric;
    v_d2  numeric;
    v_txt text;
    k_ok  boolean;
    k_msg text;
    v_dirty integer[] := '{}';   -- items an earlier FAILED check knocked out of true
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '========= INVENTORY / STORE TESTS (deep) =========';

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- A. Item master edges --------------------------------';

    c := 'a0';
    CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
         p_item_name => 'ZZS Tie', p_sku => 'ZZS-TIE', p_category => 'Uniform',
         p_unit_type => 'Piece', p_opening_stock => 50, p_min_stock => 10,
         p_cost_price => 40, p_selling_price => 70, p_result => c);
    FETCH c INTO k_ok, k_msg, v_ti;

    c := 'a0b';
    CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
         p_item_name => 'ZZS Notebook', p_category => 'Stationery',
         p_unit_type => 'Piece', p_opening_stock => 0, p_min_stock => 20,
         p_cost_price => 25, p_result => c);
    FETCH c INTO k_ok, k_msg, v_nb;
    PERFORM pg_temp.chk('ITM-00 fixture items created', v_ti IS NOT NULL AND v_nb IS NOT NULL,
                        format('tie=%s notebook=%s', v_ti, v_nb));

    -- A negative opening figure is a negative stock on day one, written as a
    -- legitimate "Opening" movement. MoveStock and Cancel both refuse below zero;
    -- SaveItem only checks "<> 0".
    BEGIN
        c := 'a1';
        CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
             p_item_name => 'ZZS Neg Opening', p_opening_stock => -5, p_result => c);
        FETCH c INTO k_ok, k_msg, v_it;
        SELECT current_stock INTO v_dec FROM core.inventory_items WHERE item_id = v_it;
        v_dirty := v_dirty || v_it;
        PERFORM pg_temp.chk('ITM-01 negative opening stock refused', FALSE,
                            format('accepted: current_stock = %s', v_dec));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('ITM-01 negative opening stock refused',
                            SQLERRM ILIKE 'Opening stock cannot be negative%', SQLERRM);
    END;

    BEGIN
        c := 'a2';
        CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
             p_item_name => 'ZZS Neg Cost', p_cost_price => -40, p_result => c);
        FETCH c INTO k_ok, k_msg, v_it;
        SELECT cost_price INTO v_dec FROM core.inventory_items WHERE item_id = v_it;
        PERFORM pg_temp.chk('ITM-02 negative cost price refused', FALSE,
                            format('accepted: cost_price = %s', v_dec));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('ITM-02 negative cost price refused',
                            SQLERRM ILIKE '%price cannot be negative%', SQLERRM);
    END;

    BEGIN
        c := 'a2b';
        CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
             p_item_name => 'ZZS Neg Sell', p_selling_price => -1, p_result => c);
        PERFORM pg_temp.chk('ITM-02b negative selling price refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('ITM-02b negative selling price refused',
                            SQLERRM ILIKE '%price cannot be negative%', SQLERRM);
    END;

    -- Quantities and prices are 2-decimal columns: a third decimal is refused,
    -- not silently rounded (that rounding is what made stock drift).
    BEGIN
        c := 'a2c';
        CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
             p_item_name => 'ZZS 3dp Open', p_opening_stock => 2.345, p_result => c);
        PERFORM pg_temp.chk('ITM-02c opening stock with 3 decimals refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('ITM-02c opening stock with 3 decimals refused',
                            SQLERRM ILIKE '%2 decimal places%', SQLERRM);
    END;
    BEGIN
        c := 'a2d';
        CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
             p_item_name => 'ZZS 3dp Cost', p_cost_price => 10.005, p_result => c);
        PERFORM pg_temp.chk('ITM-02d cost price with 3 decimals refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('ITM-02d cost price with 3 decimals refused',
                            SQLERRM ILIKE '%2 decimal places%', SQLERRM);
    END;

    BEGIN
        c := 'a3';
        CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
             p_item_name => 'ZZS Neg Min', p_min_stock => -1, p_result => c);
        PERFORM pg_temp.chk('ITM-03 negative reorder level refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('ITM-03 negative reorder level refused',
                            SQLERRM ILIKE '%minimum stock%', SQLERRM);
    END;

    -- "  zzs TIE  " is the same item as "ZZS Tie" to a human.
    BEGIN
        c := 'a4';
        CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
             p_item_name => '  zzs TIE  ', p_result => c);
        PERFORM pg_temp.chk('ITM-04 duplicate name ignoring case/spaces refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('ITM-04 duplicate name ignoring case/spaces refused',
                            SQLERRM ILIKE 'An item named "zzs TIE" already exists%', SQLERRM);
    END;

    BEGIN
        c := 'a5';
        CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
             p_item_name => 'ZZS Other', p_sku => ' zzs-tie ', p_result => c);
        PERFORM pg_temp.chk('ITM-05 duplicate SKU ignoring case/spaces refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('ITM-05 duplicate SKU ignoring case/spaces refused',
                            SQLERRM ILIKE 'Another item already uses the code%', SQLERRM);
    END;

    -- Editing must never move stock, even if the form posts an opening figure.
    SELECT COUNT(*) INTO v_m FROM core.inventory_stock_ledger WHERE item_id = v_ti;
    c := 'a6';
    CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
         p_item_id => v_ti, p_item_name => 'ZZS Tie', p_sku => 'ZZS-TIE',
         p_category => 'Uniform', p_opening_stock => 999, p_min_stock => 10,
         p_cost_price => 40, p_selling_price => 70, p_result => c);
    SELECT current_stock INTO v_dec FROM core.inventory_items WHERE item_id = v_ti;
    SELECT COUNT(*) INTO v_n FROM core.inventory_stock_ledger WHERE item_id = v_ti;
    PERFORM pg_temp.chk_eq('ITM-06 edit with opening 999 leaves stock at 50', v_dec, 50);
    PERFORM pg_temp.chk_eq('ITM-06b ...and writes no ledger row', v_n, v_m);

    BEGIN
        c := 'a7';
        CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
             p_item_id => v_nb, p_item_name => 'ZZS Tie', p_result => c);
        PERFORM pg_temp.chk('ITM-07 renaming onto another item''s name refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('ITM-07 renaming onto another item''s name refused',
                            SQLERRM ILIKE '%already exists%', SQLERRM);
    END;

    -- Another school editing our item by id.
    BEGIN
        c := 'a8';
        CALL core.sp_inventory_manage('SaveItem', o_tenant, o_school, c_user,
             p_item_id => v_ti, p_item_name => 'ZZS Hijacked', p_result => c);
        PERFORM pg_temp.chk('ITM-08 another school cannot edit our item', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('ITM-08 another school cannot edit our item',
                            SQLERRM ILIKE '%not found%', SQLERRM);
    END;
    SELECT item_name INTO v_txt FROM core.inventory_items WHERE item_id = v_ti;
    PERFORM pg_temp.chk('ITM-08b ...name unchanged', v_txt = 'ZZS Tie', format('got %s', v_txt));

    c := 'a9';
    CALL core.sp_inventory_manage('GetItem', o_tenant, o_school, c_user, p_item_id => v_ti, p_result => c);
    v_n := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_n := v_n + 1; END LOOP;
    PERFORM pg_temp.chk_eq('ITM-09 GetItem of our id from another school: 0 rows', v_n, 0);

    -- Names are stored verbatim; escaping is the page's job (EC.esc / Razor @).
    c := 'a10';
    CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
         p_item_name => 'ZZS <img src=x onerror=alert(1)>', p_result => c);
    FETCH c INTO k_ok, k_msg, v_it;
    SELECT item_name INTO v_txt FROM core.inventory_items WHERE item_id = v_it;
    PERFORM pg_temp.chk('ITM-10 HTML in a name is stored verbatim (not mangled)',
                        v_txt = 'ZZS <img src=x onerror=alert(1)>', v_txt);

    -- A purely numeric name must stay text end to end.
    c := 'a11';
    CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
         p_item_name => '00123', p_sku => '1e5', p_result => c);
    FETCH c INTO k_ok, k_msg, v_it;
    SELECT item_name || '|' || sku INTO v_txt FROM core.inventory_items WHERE item_id = v_it;
    PERFORM pg_temp.chk('ITM-11 numeric-looking name/SKU kept as text', v_txt = '00123|1e5', v_txt);

    BEGIN
        c := 'a12';
        CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
             p_item_name => 'ZZS Bad Type', p_item_type => 'Weird', p_result => c);
        PERFORM pg_temp.chk('ITM-12 unknown item type refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('ITM-12 unknown item type refused',
                            SQLERRM ILIKE '%chk_inv_item_type%', SQLERRM);
    END;

    BEGIN
        c := 'a13';
        CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
             p_item_name => repeat('Z', 151), p_result => c);
        PERFORM pg_temp.chk('ITM-13 name longer than 150 refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('ITM-13 name longer than 150 refused', TRUE, SQLERRM);
    END;

    -- An opening figure too big for numeric(14,2) must leave no half item.
    SELECT COUNT(*) INTO v_m FROM core.inventory_items WHERE tenant_id = c_tenant AND school_id = c_school;
    BEGIN
        c := 'a14';
        CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
             p_item_name => 'ZZS Huge', p_opening_stock => 1e13, p_result => c);
        PERFORM pg_temp.chk('ITM-14 opening stock beyond numeric(14,2) refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('ITM-14 opening stock beyond numeric(14,2) refused', TRUE, SQLERRM);
    END;
    SELECT COUNT(*) INTO v_n FROM core.inventory_items WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk_eq('ITM-14b ...and no item row was left behind', v_n, v_m);

    -- Opening stock: who and when.
    SELECT created_by, movement_date INTO v_n, v_txt FROM core.inventory_stock_ledger
     WHERE item_id = v_ti AND movement_type = 'Opening';
    PERFORM pg_temp.chk('ITM-15 Opening row records the author and today',
                        v_n = c_user AND v_txt = to_char(CURRENT_DATE, 'YYYY-MM-DD'),
                        format('by %s on %s', v_n, v_txt));

    -- Changing the unit after history exists would re-label every past movement
    -- ("3 Box" becomes "3 Piece"), so it is refused (rule D-8).
    c := 'a16';
    CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
         p_item_name => 'ZZS Unit Flip', p_unit_type => 'Box', p_opening_stock => 3, p_result => c);
    FETCH c INTO k_ok, k_msg, v_it;
    BEGIN
        c := 'a16b';
        CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
             p_item_id => v_it, p_item_name => 'ZZS Unit Flip', p_unit_type => 'Piece', p_result => c);
        PERFORM pg_temp.chk('ITM-16 unit cannot change once stock has moved (rule)', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('ITM-16 unit cannot change once stock has moved (rule)',
                            SQLERRM ILIKE '%unit cannot change%', SQLERRM);
    END;
    SELECT unit_type INTO v_txt FROM core.inventory_items WHERE item_id = v_it;
    PERFORM pg_temp.chk('ITM-16b ...the unit is still Box', v_txt = 'Box', format('got %s', v_txt));

    -- An item that has never moved may still fix its unit.
    c := 'a16c';
    CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
         p_item_name => 'ZZS Unit Fresh', p_unit_type => 'Box', p_result => c);
    FETCH c INTO k_ok, k_msg, v_it;
    c := 'a16d';
    CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
         p_item_id => v_it, p_item_name => 'ZZS Unit Fresh', p_unit_type => 'Set', p_result => c);
    SELECT unit_type INTO v_txt FROM core.inventory_items WHERE item_id = v_it;
    PERFORM pg_temp.chk('ITM-16c ...but an item with no history can change it', v_txt = 'Set',
                        format('got %s', v_txt));

    -- Delete: cross school, twice, and history left intact.
    BEGIN
        c := 'a17';
        CALL core.sp_inventory_manage('DeleteItem', o_tenant, o_school, c_user, p_item_id => v_nb, p_result => c);
        PERFORM pg_temp.chk('ITM-17 another school cannot delete our item', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('ITM-17 another school cannot delete our item',
                            SQLERRM ILIKE '%not found%', SQLERRM);
    END;
    SELECT COUNT(*) INTO v_n FROM core.inventory_items WHERE item_id = v_nb AND is_deleted = FALSE;
    PERFORM pg_temp.chk_eq('ITM-17b ...the item is still live', v_n, 1);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- B. List, low stock, valuation -----------------------';

    -- Tie: 50 on hand, min 10 -> Available.  Notebook: 0 -> Out of Stock.
    -- A third item sitting exactly ON its reorder level -> Low Stock.
    c := 'b0';
    CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
         p_item_name => 'ZZS Chalk', p_sku => 'ZZS-CHK', p_unit_type => 'Box',
         p_opening_stock => 5, p_min_stock => 5, p_cost_price => 12.5, p_result => c);
    FETCH c INTO k_ok, k_msg, v_it;

    c := 'b1';
    CALL core.sp_inventory_manage('ListItems', c_tenant, c_school, c_user, p_search => 'ZZS', p_result => c);
    v_txt := '';
    LOOP
        FETCH c INTO r; EXIT WHEN NOT FOUND;
        IF r.item_id IN (v_ti, v_nb, v_it) THEN
            v_txt := v_txt || r.item_name || '=' || r.stock_status || ';';
        END IF;
        IF r.item_id = v_it THEN v_dec := r.stock_value; END IF;
    END LOOP;
    PERFORM pg_temp.chk('LST-01 status: Available / Out of Stock / Low at the line',
                        v_txt = 'ZZS Chalk=Low Stock;ZZS Notebook=Out of Stock;ZZS Tie=Available;', v_txt);
    PERFORM pg_temp.chk_eq('LST-02 stock value = stock x cost (5 x 12.50)', v_dec, 62.50);

    c := 'b3';
    CALL core.sp_inventory_manage('ListItems', c_tenant, c_school, c_user,
         p_filter_status => 'Low Stock', p_result => c);
    v_n := 0; v_m := 0;
    LOOP
        FETCH c INTO r; EXIT WHEN NOT FOUND;
        v_n := v_n + 1;
        IF r.stock_status <> 'Low Stock' THEN v_m := v_m + 1; END IF;
        IF r.item_id = v_it THEN v_n := v_n + 1000; END IF;
    END LOOP;
    PERFORM pg_temp.chk('LST-03 low-stock filter returns only low items, incl. Chalk',
                        v_m = 0 AND v_n > 1000, format('%s row(s), %s not low', v_n % 1000, v_m));

    c := 'b4';
    CALL core.sp_inventory_manage('ListItems', c_tenant, c_school, c_user, p_search => '  zzs-chk ', p_result => c);
    v_n := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_n := v_n + 1; END LOOP;
    PERFORM pg_temp.chk_eq('LST-04 search by SKU, any case, trimmed', v_n, 1);

    -- The other school's two items never appear in ours.
    c := 'b5';
    CALL core.sp_inventory_manage('ListItems', c_tenant, c_school, c_user, p_result => c);
    v_n := 0;
    LOOP
        FETCH c INTO r; EXIT WHEN NOT FOUND;
        IF EXISTS (SELECT 1 FROM core.inventory_items WHERE item_id = r.item_id
                   AND (tenant_id <> c_tenant OR school_id <> c_school OR is_deleted)) THEN
            v_n := v_n + 1;
        END IF;
    END LOOP;
    PERFORM pg_temp.chk_eq('LST-05 list holds no foreign or deleted item', v_n, 0);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- C. Stock movement edges -----------------------------';

    -- Three decimal places used to be accepted and then rounded differently by
    -- the two numeric(14,2) columns (9.665 -> 9.67 on the item, -0.335 -> -0.34
    -- on the ledger), so stock drifted from its ledger. Now refused (rule D-11).
    c := 'c0';
    CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
         p_item_name => 'ZZS Cloth', p_unit_type => 'Kg', p_opening_stock => 10, p_result => c);
    FETCH c INTO k_ok, k_msg, v_it;
    BEGIN
        c := 'c1';
        CALL core.sp_inventory_manage('MoveStock', c_tenant, c_school, c_user,
             p_item_id => v_it, p_movement_type => 'Issue', p_quantity => 0.335, p_result => c);
        PERFORM pg_temp.chk('MOV-01 3-decimal quantity refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('MOV-01 3-decimal quantity refused',
                            SQLERRM ILIKE '%2 decimal places%', SQLERRM);
    END;
    c := 'c1b';
    CALL core.sp_inventory_manage('MoveStock', c_tenant, c_school, c_user,
         p_item_id => v_it, p_movement_type => 'Issue', p_quantity => 0.33, p_result => c);
    v_dec := pg_temp.drift(v_it);
    IF v_dec <> 0 THEN v_dirty := v_dirty || v_it; END IF;
    PERFORM pg_temp.chk('MOV-01b a 2-decimal issue keeps stock = sum(ledger)', v_dec = 0,
                        format('drift %s (stock %s)', v_dec,
                               (SELECT current_stock FROM core.inventory_items WHERE item_id = v_it)));
    v_n := pg_temp.bad_balances(v_it);
    PERFORM pg_temp.chk_eq('MOV-01c ...and balance_after is a running sum', v_n, 0);

    BEGIN
        c := 'c2';
        CALL core.sp_inventory_manage('MoveStock', c_tenant, c_school, c_user,
             p_item_id => v_ti, p_movement_type => 'Issue', p_quantity => -5, p_result => c);
        PERFORM pg_temp.chk('MOV-02 negative quantity refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('MOV-02 negative quantity refused', SQLERRM ILIKE '%greater than zero%', SQLERRM);
    END;

    -- 0.004 passes "> 0" but rounds to 0.00 in the ledger -- refused by the CHECK,
    -- and the item must not have moved.
    BEGIN
        c := 'c3';
        CALL core.sp_inventory_manage('MoveStock', c_tenant, c_school, c_user,
             p_item_id => v_ti, p_movement_type => 'Issue', p_quantity => 0.004, p_result => c);
        PERFORM pg_temp.chk('MOV-03 quantity that rounds to 0.00 refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('MOV-03 quantity that rounds to 0.00 refused', TRUE, SQLERRM);
    END;
    SELECT current_stock INTO v_dec FROM core.inventory_items WHERE item_id = v_ti;
    PERFORM pg_temp.chk_eq('MOV-03b ...stock untouched', v_dec, 50);

    BEGIN
        c := 'c4';
        CALL core.sp_inventory_manage('MoveStock', c_tenant, c_school, c_user,
             p_item_id => v_ti, p_movement_type => 'issue', p_quantity => 1, p_result => c);
        PERFORM pg_temp.chk('MOV-04 lowercase movement type refused, not guessed', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('MOV-04 lowercase movement type refused, not guessed', TRUE, SQLERRM);
    END;

    -- Issue to a class, with who / when / to-whom on the row.
    c := 'c5';
    CALL core.sp_inventory_manage('MoveStock', c_tenant, c_school, c_user,
         p_item_id => v_ti, p_movement_type => ' Issue ', p_quantity => 12,
         p_issued_to => '  Class 6B  ', p_remarks => 'term start', p_result => c);
    FETCH c INTO k_ok, k_msg, v_dec;
    PERFORM pg_temp.chk_eq('MOV-05 issue of 12 to a class leaves 38', v_dec, 38);
    SELECT * INTO r FROM core.inventory_stock_ledger WHERE item_id = v_ti ORDER BY movement_id DESC LIMIT 1;
    PERFORM pg_temp.chk('MOV-06 row keeps type, -qty, to, remarks, author, date',
                        r.movement_type = 'Issue' AND r.quantity = -12 AND r.issued_to = 'Class 6B'
                        AND r.remarks = 'term start' AND r.created_by = c_user
                        AND r.movement_date = to_char(CURRENT_DATE, 'YYYY-MM-DD'),
                        format('%s %s to=%s by=%s on %s', r.movement_type, r.quantity,
                               r.issued_to, r.created_by, r.movement_date));
    PERFORM pg_temp.chk_eq('MOV-06b ...valued at the item cost price (rate 40)', r.unit_rate, 40);

    -- Damaged goods.
    c := 'c7';
    CALL core.sp_inventory_manage('MoveStock', c_tenant, c_school, c_user,
         p_item_id => v_ti, p_movement_type => 'Damage', p_quantity => 3,
         p_remarks => 'torn in storage', p_result => c);
    FETCH c INTO k_ok, k_msg, v_dec;
    PERFORM pg_temp.chk_eq('MOV-07 damage of 3 leaves 35', v_dec, 35);

    -- Adjustment adds found stock; a count that finds LESS is a Stock-take.
    c := 'c8';
    CALL core.sp_inventory_manage('MoveStock', c_tenant, c_school, c_user,
         p_item_id => v_ti, p_movement_type => 'Adjustment', p_quantity => 1, p_result => c);
    FETCH c INTO k_ok, k_msg, v_dec;
    PERFORM pg_temp.chk_eq('MOV-08 Adjustment adds found stock (35 -> 36)', v_dec, 36);

    -- Stock-take (rule D-2): the quantity is what was COUNTED, the movement is
    -- the difference, it can go down, and it needs a reason.
    DECLARE v_st integer;
    BEGIN
        c := 'c8b';
        CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
             p_item_name => 'ZZS Count Me', p_opening_stock => 20, p_cost_price => 5, p_result => c);
        FETCH c INTO k_ok, k_msg, v_st;

        BEGIN
            c := 'c8c';
            CALL core.sp_inventory_manage('MoveStock', c_tenant, c_school, c_user,
                 p_item_id => v_st, p_movement_type => 'StockTake', p_quantity => 17, p_result => c);
            PERFORM pg_temp.chk('MOV-08b stock-take without a reason refused', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('MOV-08b stock-take without a reason refused',
                                SQLERRM ILIKE '%reason%', SQLERRM);
        END;

        c := 'c8d';
        CALL core.sp_inventory_manage('MoveStock', c_tenant, c_school, c_user,
             p_item_id => v_st, p_movement_type => 'StockTake', p_quantity => 17,
             p_remarks => 'annual count: 3 missing', p_result => c);
        FETCH c INTO k_ok, k_msg, v_dec;
        PERFORM pg_temp.chk_eq('MOV-08c counted 17 of 20: stock becomes 17', v_dec, 17);
        SELECT * INTO r FROM core.inventory_stock_ledger WHERE item_id = v_st ORDER BY movement_id DESC LIMIT 1;
        PERFORM pg_temp.chk('MOV-08d ...one StockTake row of -3 with the reason',
                            r.movement_type = 'StockTake' AND r.quantity = -3
                            AND r.remarks = 'annual count: 3 missing' AND r.balance_after = 17,
                            format('%s %s "%s" bal %s', r.movement_type, r.quantity, r.remarks, r.balance_after));

        c := 'c8e';
        CALL core.sp_inventory_manage('MoveStock', c_tenant, c_school, c_user,
             p_item_id => v_st, p_movement_type => 'StockTake', p_quantity => 18,
             p_remarks => 'one found behind the shelf', p_result => c);
        FETCH c INTO k_ok, k_msg, v_dec;
        PERFORM pg_temp.chk_eq('MOV-08e a count above stock moves it up (18)', v_dec, 18);

        BEGIN
            c := 'c8f';
            CALL core.sp_inventory_manage('MoveStock', c_tenant, c_school, c_user,
                 p_item_id => v_st, p_movement_type => 'StockTake', p_quantity => 18,
                 p_remarks => 'recount', p_result => c);
            PERFORM pg_temp.chk('MOV-08f a count equal to stock is refused (nothing to do)', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('MOV-08f a count equal to stock is refused (nothing to do)',
                                SQLERRM ILIKE '%nothing to adjust%', SQLERRM);
        END;
        BEGIN
            c := 'c8g';
            CALL core.sp_inventory_manage('MoveStock', c_tenant, c_school, c_user,
                 p_item_id => v_st, p_movement_type => 'StockTake', p_quantity => -1,
                 p_remarks => 'bad', p_result => c);
            PERFORM pg_temp.chk('MOV-08g a negative count is refused', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('MOV-08g a negative count is refused', TRUE, SQLERRM);
        END;

        c := 'c8h';
        CALL core.sp_inventory_manage('MoveStock', c_tenant, c_school, c_user,
             p_item_id => v_st, p_movement_type => 'StockTake', p_quantity => 0,
             p_remarks => 'all lost in the flood', p_result => c);
        FETCH c INTO k_ok, k_msg, v_dec;
        PERFORM pg_temp.chk_eq('MOV-08h a count of 0 empties the shelf', v_dec, 0);
        PERFORM pg_temp.chk_eq('MOV-08i ...stock = sum(ledger) through the stock-takes', pg_temp.drift(v_st), 0);
    END;

    -- Issuing exactly what is left is allowed and lands on zero.
    c := 'c9';
    CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
         p_item_name => 'ZZS Duster', p_opening_stock => 4, p_result => c);
    FETCH c INTO k_ok, k_msg, v_it;
    c := 'c9b';
    CALL core.sp_inventory_manage('MoveStock', c_tenant, c_school, c_user,
         p_item_id => v_it, p_movement_type => 'Issue', p_quantity => 4, p_result => c);
    FETCH c INTO k_ok, k_msg, v_dec;
    PERFORM pg_temp.chk_eq('MOV-09 issuing the exact balance lands on 0', v_dec, 0);

    BEGIN
        c := 'c10';
        CALL core.sp_inventory_manage('MoveStock', c_tenant, c_school, c_user,
             p_item_id => v_it, p_movement_type => 'Damage', p_quantity => 0.01, p_result => c);
        PERFORM pg_temp.chk('MOV-10 damage on an empty shelf refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('MOV-10 damage on an empty shelf refused', SQLERRM ILIKE 'Only %', SQLERRM);
    END;

    -- Deleted item: the history stays, but nothing new can be written to it.
    c := 'c11';
    CALL core.sp_inventory_manage('DeleteItem', c_tenant, c_school, c_user, p_item_id => v_it, p_result => c);
    BEGIN
        c := 'c11b';
        CALL core.sp_inventory_manage('MoveStock', c_tenant, c_school, c_user,
             p_item_id => v_it, p_movement_type => 'Return', p_quantity => 1, p_result => c);
        PERFORM pg_temp.chk('MOV-11 no movement on a deleted item', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('MOV-11 no movement on a deleted item', SQLERRM ILIKE '%not found%', SQLERRM);
    END;
    BEGIN
        c := 'c11c';
        CALL core.sp_inventory_manage('DeleteItem', c_tenant, c_school, c_user, p_item_id => v_it, p_result => c);
        PERFORM pg_temp.chk('MOV-11b deleting it twice refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('MOV-11b deleting it twice refused', TRUE, SQLERRM);
    END;
    c := 'c11d';
    CALL core.sp_inventory_manage('GetItem', c_tenant, c_school, c_user, p_item_id => v_it, p_result => c);
    v_n := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_n := v_n + 1; END LOOP;
    PERFORM pg_temp.chk_eq('MOV-11c GetItem of a deleted item: 0 rows', v_n, 0);
    c := 'c11e';
    CALL core.sp_inventory_manage('ItemLedger', c_tenant, c_school, c_user, p_item_id => v_it, p_result => c);
    v_n := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_n := v_n + 1; END LOOP;
    PERFORM pg_temp.chk_eq('MOV-11d ...but its ledger is still readable (2 rows)', v_n, 2);

    -- Too big for the column: refused whole, nothing moved.
    SELECT COUNT(*) INTO v_m FROM core.inventory_stock_ledger WHERE item_id = v_ti;
    BEGIN
        c := 'c12';
        CALL core.sp_inventory_manage('MoveStock', c_tenant, c_school, c_user,
             p_item_id => v_ti, p_movement_type => 'Return', p_quantity => 1e13, p_result => c);
        PERFORM pg_temp.chk('MOV-12 huge return refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('MOV-12 huge return refused', TRUE, SQLERRM);
    END;
    SELECT COUNT(*) INTO v_n FROM core.inventory_stock_ledger WHERE item_id = v_ti;
    PERFORM pg_temp.chk_eq('MOV-12b ...no ledger row written', v_n, v_m);

    -- An item marked Inactive still moves.
    c := 'c13';
    CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
         p_item_name => 'ZZS Old Badge', p_opening_stock => 2, p_is_active => FALSE, p_result => c);
    FETCH c INTO k_ok, k_msg, v_it;
    BEGIN
        c := 'c13b';
        CALL core.sp_inventory_manage('MoveStock', c_tenant, c_school, c_user,
             p_item_id => v_it, p_movement_type => 'Issue', p_quantity => 1, p_result => c);
        PERFORM pg_temp.chk('MOV-13 an Inactive item cannot be issued (rule)', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('MOV-13 an Inactive item cannot be issued (rule)',
                            SQLERRM ILIKE '%Inactive%', SQLERRM);
    END;
    -- ...but its old stock can still be written off.
    c := 'c13c';
    CALL core.sp_inventory_manage('MoveStock', c_tenant, c_school, c_user,
         p_item_id => v_it, p_movement_type => 'Damage', p_quantity => 2,
         p_remarks => 'old design, scrapped', p_result => c);
    FETCH c INTO k_ok, k_msg, v_dec;
    PERFORM pg_temp.chk_eq('MOV-13b ...but its stock can still be written off', v_dec, 0);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- D. Suppliers ----------------------------------------';

    c := 'd0';
    CALL core.sp_inventory_manage('SaveSupplier', c_tenant, c_school, c_user,
         p_supplier_name => 'ZZS Uniform House', p_gstin => '27AAAAA0000A1Z5', p_result => c);
    FETCH c INTO k_ok, k_msg, v_sup;
    c := 'd0b';
    CALL core.sp_inventory_manage('SaveSupplier', c_tenant, c_school, c_user,
         p_supplier_name => 'ZZS Paper Mart', p_result => c);
    FETCH c INTO k_ok, k_msg, v_sp2;
    PERFORM pg_temp.chk('SUP-00 two suppliers created', v_sup IS NOT NULL AND v_sp2 IS NOT NULL, '');

    BEGIN
        c := 'd1';
        CALL core.sp_inventory_manage('SaveSupplier', c_tenant, c_school, c_user,
             p_supplier_name => '   ', p_result => c);
        PERFORM pg_temp.chk('SUP-01 blank supplier name refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('SUP-01 blank supplier name refused', SQLERRM ILIKE '%required%', SQLERRM);
    END;

    BEGIN
        c := 'd2';
        CALL core.sp_inventory_manage('SaveSupplier', c_tenant, c_school, c_user,
             p_supplier_name => ' zzs uniform HOUSE ', p_result => c);
        PERFORM pg_temp.chk('SUP-02 duplicate supplier name refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('SUP-02 duplicate supplier name refused',
                            SQLERRM ILIKE 'A supplier named%already exists%', SQLERRM);
    END;

    BEGIN
        c := 'd3';
        CALL core.sp_inventory_manage('SaveSupplier', o_tenant, o_school, c_user,
             p_supplier_id => v_sup, p_supplier_name => 'ZZS Hijack', p_result => c);
        PERFORM pg_temp.chk('SUP-03 another school cannot edit our supplier', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('SUP-03 another school cannot edit our supplier',
                            SQLERRM ILIKE '%not found%', SQLERRM);
    END;

    BEGIN
        c := 'd4';
        CALL core.sp_inventory_manage('DeleteSupplier', o_tenant, o_school, c_user,
             p_supplier_id => v_sup, p_result => c);
        PERFORM pg_temp.chk('SUP-04 another school cannot delete our supplier', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('SUP-04 another school cannot delete our supplier',
                            SQLERRM ILIKE '%not found%', SQLERRM);
    END;
    SELECT supplier_name INTO v_txt FROM core.inventory_suppliers WHERE supplier_id = v_sup AND is_deleted = FALSE;
    PERFORM pg_temp.chk('SUP-04b ...supplier untouched', v_txt = 'ZZS Uniform House', format('got %s', v_txt));

    -- A supplier that belongs to the other school.
    DECLARE v_fsup integer;
    BEGIN
        c := 'd5';
        CALL core.sp_inventory_manage('SaveSupplier', o_tenant, o_school, c_user,
             p_supplier_name => 'ZZS Foreign Supplier', p_result => c);
        FETCH c INTO k_ok, k_msg, v_fsup;
        BEGIN
            c := 'd5b'; c2 := 'd5c';
            CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
                 p_supplier_id => v_fsup, p_purchase_date => CURRENT_DATE,
                 p_items => jsonb_build_array(jsonb_build_object(
                     'itemId', v_ti, 'quantity', 1, 'unitPrice', 1, 'taxPercent', 0)),
                 p_result => c, p_result2 => c2);
            PERFORM pg_temp.chk('SUP-05 buying from another school''s supplier refused', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('SUP-05 buying from another school''s supplier refused',
                                SQLERRM ILIKE '%supplier not found%', SQLERRM);
        END;
    END;

    -- Supplier list of the other school holds none of ours.
    c := 'd6';
    CALL core.sp_inventory_manage('ListSuppliers', o_tenant, o_school, c_user, p_result => c);
    v_n := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
        IF r.supplier_id IN (v_sup, v_sp2) THEN v_n := v_n + 1; END IF;
    END LOOP;
    PERFORM pg_temp.chk_eq('SUP-06 other school''s supplier list excludes ours', v_n, 0);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- E. Purchases ----------------------------------------';

    -- A real bill: 100 ties @ 40 + 5%, 200 notebooks @ 20 + 12%.
    --   ties      4000 + 200 = 4200
    --   notebooks 4000 + 480 = 4480        sub 8000, tax 680, grand 8680
    c := 'e1'; c2 := 'e1b';
    CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
         p_supplier_id => v_sup, p_purchase_date => CURRENT_DATE,
         p_invoice_no => 'ZZS-B-1', p_payment_mode => 'UPI', p_remarks => 'term order',
         p_items => jsonb_build_array(
             jsonb_build_object('itemId', v_ti, 'quantity', 100, 'unitPrice', 40, 'taxPercent', 5),
             jsonb_build_object('itemId', v_nb, 'quantity', 200, 'unitPrice', 20, 'taxPercent', 12)),
         p_result => c, p_result2 => c2);
    FETCH c INTO k_ok, k_msg, v_pid, v_dec;
    PERFORM pg_temp.chk_eq('PUR-01 multi-line GST bill: grand total 8680', v_dec, 8680);
    SELECT SUM(line_total) INTO v_d2 FROM core.inventory_purchase_items WHERE purchase_id = v_pid;
    PERFORM pg_temp.chk_eq('PUR-01b ...and the lines add up to the header', v_d2, 8680);
    SELECT current_stock INTO v_dec FROM core.inventory_items WHERE item_id = v_ti;
    PERFORM pg_temp.chk_eq('PUR-01c tie stock 36 + 100 = 136', v_dec, 136);

    SELECT COUNT(*) INTO v_n FROM core.inventory_stock_ledger
     WHERE reference_type = 'Purchase' AND reference_id = v_pid AND movement_type = 'Purchase'
       AND created_by = c_user AND movement_date = to_char(CURRENT_DATE, 'YYYY-MM-DD');
    PERFORM pg_temp.chk_eq('PUR-02 one Purchase movement per line, with author/date/ref', v_n, 2);
    SELECT unit_rate INTO v_dec FROM core.inventory_stock_ledger
     WHERE reference_id = v_pid AND movement_type = 'Purchase' AND item_id = v_nb;
    PERFORM pg_temp.chk_eq('PUR-02b ...valued at the bill''s own rate (20)', v_dec, 20);

    -- Invoice number is unique PER SUPPLIER: another supplier may reuse it ...
    c := 'e3'; c2 := 'e3b';
    CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
         p_supplier_id => v_sp2, p_purchase_date => CURRENT_DATE, p_invoice_no => 'ZZS-B-1',
         p_items => jsonb_build_array(jsonb_build_object(
             'itemId', v_nb, 'quantity', 10, 'unitPrice', 20, 'taxPercent', 0)),
         p_result => c, p_result2 => c2);
    FETCH c INTO k_ok, k_msg, v_n;
    PERFORM pg_temp.chk('PUR-03 same bill number from a different supplier allowed',
                        COALESCE(k_ok, FALSE), format('purchase_id=%s', v_n));

    -- ... but the same supplier may not, whatever the case or spacing.
    BEGIN
        c := 'e4'; c2 := 'e4b';
        CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
             p_supplier_id => v_sup, p_purchase_date => CURRENT_DATE, p_invoice_no => '  zzs-b-1 ',
             p_items => jsonb_build_array(jsonb_build_object(
                 'itemId', v_ti, 'quantity', 1, 'unitPrice', 40, 'taxPercent', 0)),
             p_result => c, p_result2 => c2);
        PERFORM pg_temp.chk('PUR-04 same bill/supplier with other case/spaces refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('PUR-04 same bill/supplier with other case/spaces refused',
                            SQLERRM ILIKE 'Bill%already entered%', SQLERRM);
    END;

    -- A new bill must name its supplier (18 Oct 2026; it used to be optional, rule D-7).
    BEGIN
        c := 'e5'; c2 := 'e5b';
        CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
             p_purchase_date => CURRENT_DATE, p_invoice_no => 'ZZS-CASH-9',
             p_items => jsonb_build_array(jsonb_build_object(
                 'itemId', v_nb, 'quantity', 1, 'unitPrice', 20, 'taxPercent', 0)),
             p_result => c, p_result2 => c2);
        PERFORM pg_temp.chk('PUR-05 a bill with no supplier is refused', FALSE, 'it was saved');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('PUR-05 a bill with no supplier is refused',
                            SQLERRM ILIKE 'Choose the supplier%', SQLERRM);
    END;
    -- The unique index is the backstop behind the proc's own check.
    BEGIN
        INSERT INTO core.inventory_purchases (tenant_id, school_id, supplier_id, purchase_date, invoice_no)
        VALUES (c_tenant, c_school, NULL, to_char(CURRENT_DATE, 'YYYY-MM-DD'), 'zzs-cash-9 ');
        INSERT INTO core.inventory_purchases (tenant_id, school_id, supplier_id, purchase_date, invoice_no)
        VALUES (c_tenant, c_school, NULL, to_char(CURRENT_DATE, 'YYYY-MM-DD'), 'ZZS-CASH-9');
        PERFORM pg_temp.chk('PUR-05b index refuses a repeat no-supplier bill too', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('PUR-05b index refuses a repeat no-supplier bill too',
                            SQLERRM ILIKE '%ux_inventory_purchase_invoice%', SQLERRM);
    END;

    -- Bad lines: refused whole, no half-purchase.
    SELECT COUNT(*) INTO v_m FROM core.inventory_purchases WHERE tenant_id = c_tenant AND school_id = c_school;
    SELECT current_stock INTO v_d2 FROM core.inventory_items WHERE item_id = v_ti;
    BEGIN
        c := 'e6'; c2 := 'e6b';
        CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
             p_supplier_id => v_sup, p_purchase_date => CURRENT_DATE,
             p_items => jsonb_build_array(
                 jsonb_build_object('itemId', v_ti, 'quantity', 1, 'unitPrice', 40, 'taxPercent', 0),
                 jsonb_build_object('itemId', v_nb, 'quantity', 1, 'unitPrice', 40, 'taxPercent', -18)),
             p_result => c, p_result2 => c2);
        PERFORM pg_temp.chk('PUR-06 negative tax % refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('PUR-06 negative tax % refused', SQLERRM ILIKE '%between 0 and 100%', SQLERRM);
    END;
    BEGIN
        c := 'e7'; c2 := 'e7b';
        CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
             p_supplier_id => v_sup, p_purchase_date => CURRENT_DATE,
             p_items => jsonb_build_array(jsonb_build_object(
                 'itemId', v_ti, 'quantity', 1, 'unitPrice', 40, 'taxPercent', 128)),
             p_result => c, p_result2 => c2);
        PERFORM pg_temp.chk('PUR-07 tax % above 100 refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('PUR-07 tax % above 100 refused', SQLERRM ILIKE '%between 0 and 100%', SQLERRM);
    END;
    BEGIN
        c := 'e8'; c2 := 'e8b';
        CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
             p_supplier_id => v_sup, p_purchase_date => CURRENT_DATE,
             p_items => jsonb_build_array(jsonb_build_object(
                 'itemId', v_ti, 'quantity', 1, 'unitPrice', -40, 'taxPercent', 0)),
             p_result => c, p_result2 => c2);
        PERFORM pg_temp.chk('PUR-08 negative unit price refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('PUR-08 negative unit price refused', SQLERRM ILIKE '%negative%', SQLERRM);
    END;
    BEGIN
        c := 'e9'; c2 := 'e9b';
        CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
             p_supplier_id => v_sup, p_purchase_date => CURRENT_DATE,
             p_items => '[{"itemId": null, "quantity": 1, "unitPrice": 1}]'::jsonb,
             p_result => c, p_result2 => c2);
        PERFORM pg_temp.chk('PUR-09 a line with no item refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('PUR-09 a line with no item refused', TRUE, SQLERRM);
    END;
    BEGIN
        c := 'e10'; c2 := 'e10b';
        CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
             p_supplier_id => v_sup, p_purchase_date => CURRENT_DATE,
             p_items => jsonb_build_array(jsonb_build_object('itemId', v_ti, 'unitPrice', 1)),
             p_result => c, p_result2 => c2);
        PERFORM pg_temp.chk('PUR-10 a line with no quantity refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('PUR-10 a line with no quantity refused', TRUE, SQLERRM);
    END;
    BEGIN
        c := 'e11'; c2 := 'e11b';
        CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
             p_supplier_id => v_sup, p_purchase_date => CURRENT_DATE,
             p_items => jsonb_build_object('itemId', v_ti, 'quantity', 1),
             p_result => c, p_result2 => c2);
        PERFORM pg_temp.chk('PUR-11 lines as an object, not an array, refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('PUR-11 lines as an object, not an array, refused', TRUE, SQLERRM);
    END;
    BEGIN
        c := 'e12'; c2 := 'e12b';
        CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
             p_supplier_id => 999999, p_purchase_date => CURRENT_DATE,
             p_items => jsonb_build_array(jsonb_build_object(
                 'itemId', v_ti, 'quantity', 1, 'unitPrice', 1, 'taxPercent', 0)),
             p_result => c, p_result2 => c2);
        PERFORM pg_temp.chk('PUR-12 unknown supplier id refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('PUR-12 unknown supplier id refused', TRUE, SQLERRM);
    END;
    BEGIN
        c := 'e13'; c2 := 'e13b';
        CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
             p_supplier_id => v_sup, p_purchase_date => NULL,
             p_items => jsonb_build_array(jsonb_build_object(
                 'itemId', v_ti, 'quantity', 1, 'unitPrice', 1, 'taxPercent', 0)),
             p_result => c, p_result2 => c2);
        PERFORM pg_temp.chk('PUR-13 no purchase date refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('PUR-13 no purchase date refused', SQLERRM ILIKE '%date%', SQLERRM);
    END;
    -- Huge: 1e9 x 1e6 does not fit numeric(14,2).
    BEGIN
        c := 'e14'; c2 := 'e14b';
        CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
             p_supplier_id => v_sup, p_purchase_date => CURRENT_DATE,
             p_items => jsonb_build_array(jsonb_build_object(
                 'itemId', v_ti, 'quantity', 1000000000, 'unitPrice', 1000000, 'taxPercent', 0)),
             p_result => c, p_result2 => c2);
        PERFORM pg_temp.chk('PUR-14 a bill too big for the columns refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('PUR-14 a bill too big for the columns refused', TRUE, SQLERRM);
    END;
    SELECT COUNT(*) INTO v_n FROM core.inventory_purchases WHERE tenant_id = c_tenant AND school_id = c_school;
    SELECT current_stock INTO v_dec FROM core.inventory_items WHERE item_id = v_ti;
    PERFORM pg_temp.chk('PUR-14b ...no purchase row and no stock change from PUR-06..14',
                        v_n = v_m AND v_dec = v_d2, format('purchases %s->%s, tie %s->%s', v_m, v_n, v_d2, v_dec));

    -- A free sample: price 0 is legitimate and still raises stock.
    c := 'e15'; c2 := 'e15b';
    CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
         p_supplier_id => v_sup, p_purchase_date => CURRENT_DATE, p_invoice_no => 'ZZS-FREE',
         p_items => jsonb_build_array(jsonb_build_object(
             'itemId', v_ti, 'quantity', 2, 'unitPrice', 0, 'taxPercent', 0)),
         p_result => c, p_result2 => c2);
    FETCH c INTO k_ok, k_msg, v_n, v_dec;
    PERFORM pg_temp.chk('PUR-15 zero-price line (free sample) accepted, total 0',
                        COALESCE(k_ok, FALSE) AND v_dec = 0, format('total %s', v_dec));

    -- Paise: 2.5 x 33.33 + 18%. The line and the header used to round
    -- differently (98.32 vs 98.33). Now each line rounds once (83.33 + 15.00)
    -- and the header is the sum of the lines.
    DECLARE v_p integer;
    BEGIN
        c := 'e16'; c2 := 'e16b';
        CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
             p_supplier_id => v_sup, p_purchase_date => CURRENT_DATE, p_invoice_no => 'ZZS-PAISE',
             p_items => jsonb_build_array(jsonb_build_object(
                 'itemId', v_ti, 'quantity', 2.5, 'unitPrice', 33.33, 'taxPercent', 18)),
             p_result => c, p_result2 => c2);
        FETCH c INTO k_ok, k_msg, v_p, v_dec;
        SELECT SUM(line_total) INTO v_d2 FROM core.inventory_purchase_items WHERE purchase_id = v_p;
        PERFORM pg_temp.chk('PUR-16 header total = sum of its line totals', v_dec = v_d2 AND v_dec = 98.33,
                            format('header %s, lines %s', v_dec, v_d2));
        SELECT sub_total + tax_total - grand_total INTO v_d2 FROM core.inventory_purchases WHERE purchase_id = v_p;
        PERFORM pg_temp.chk('PUR-16b sub + tax = grand on the stored header', v_d2 = 0,
                            format('sub+tax-grand = %s', v_d2));
    END;

    -- 3 decimals on a purchase: stock and ledger round the same way going UP.
    c := 'e17';
    CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
         p_item_name => 'ZZS Ink', p_unit_type => 'Liter', p_result => c);
    FETCH c INTO k_ok, k_msg, v_it;
    -- A 3-decimal quantity on a bill used to be stored as 1.01 on the line while
    -- the header was summed from the raw 1.005. Now refused (rule D-11).
    SELECT COUNT(*) INTO v_m FROM core.inventory_purchases WHERE tenant_id = c_tenant AND school_id = c_school;
    BEGIN
        c := 'e17b'; c2 := 'e17c';
        CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
             p_supplier_id => v_sup, p_purchase_date => CURRENT_DATE,
             p_items => jsonb_build_array(
                 jsonb_build_object('itemId', v_it, 'quantity', 1.005, 'unitPrice', 10, 'taxPercent', 0)),
             p_result => c, p_result2 => c2);
        PERFORM pg_temp.chk('PUR-17 3-decimal purchase quantity refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('PUR-17 3-decimal purchase quantity refused',
                            SQLERRM ILIKE '%2 decimal places%', SQLERRM);
    END;
    BEGIN
        c := 'e17d'; c2 := 'e17e';
        CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
             p_supplier_id => v_sup, p_purchase_date => CURRENT_DATE,
             p_items => jsonb_build_array(
                 jsonb_build_object('itemId', v_it, 'quantity', 1, 'unitPrice', 10.005, 'taxPercent', 0)),
             p_result => c, p_result2 => c2);
        PERFORM pg_temp.chk('PUR-17b 3-decimal unit price refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('PUR-17b 3-decimal unit price refused',
                            SQLERRM ILIKE '%2 decimal places%', SQLERRM);
    END;
    SELECT COUNT(*) INTO v_n FROM core.inventory_purchases WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk_eq('PUR-17c ...no bill was written', v_n, v_m);

    -- An Inactive item cannot be bought (rule D-6).
    DECLARE v_old integer;
    BEGIN
        c := 'e17f';
        CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
             p_item_name => 'ZZS Retired Cap', p_is_active => FALSE, p_result => c);
        FETCH c INTO k_ok, k_msg, v_old;
        BEGIN
            c := 'e17g'; c2 := 'e17h';
            CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
                 p_supplier_id => v_sup, p_purchase_date => CURRENT_DATE,
                 p_items => jsonb_build_array(
                     jsonb_build_object('itemId', v_old, 'quantity', 5, 'unitPrice', 50, 'taxPercent', 0)),
                 p_result => c, p_result2 => c2);
            PERFORM pg_temp.chk('PUR-17d an Inactive item cannot be purchased (rule)', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('PUR-17d an Inactive item cannot be purchased (rule)',
                                SQLERRM ILIKE '%Inactive%', SQLERRM);
        END;
    END;

    -- The same item on two lines of one bill (two sizes typed as one item, or a
    -- bill with a free line): each line is its own movement.
    SELECT current_stock INTO v_d2 FROM core.inventory_items WHERE item_id = v_nb;
    c := 'e18'; c2 := 'e18b';
    CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
         p_supplier_id => v_sup, p_purchase_date => CURRENT_DATE, p_invoice_no => 'ZZS-DUP',
         p_items => jsonb_build_array(
             jsonb_build_object('itemId', v_nb, 'quantity', 30, 'unitPrice', 20, 'taxPercent', 0),
             jsonb_build_object('itemId', v_nb, 'quantity', 20, 'unitPrice', 0,  'taxPercent', 0)),
         p_result => c, p_result2 => c2);
    FETCH c INTO k_ok, k_msg, v_p2;
    SELECT current_stock INTO v_dec FROM core.inventory_items WHERE item_id = v_nb;
    PERFORM pg_temp.chk_eq('PUR-18 same item on two lines: stock rises by 50', v_dec - v_d2, 50);
    PERFORM pg_temp.chk_eq('PUR-18b ...balances stay a running sum', pg_temp.bad_balances(v_nb), 0);

    -- Back-dated bill: allowed (no lower bound). Its movement carries the old
    -- date but the newest movement_id, so the ledger is NOT in date order.
    DECLARE v_p integer;
    BEGIN
        c := 'e19'; c2 := 'e19b';
        CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
             p_supplier_id => v_sup, p_purchase_date => DATE '2001-01-01', p_invoice_no => 'ZZS-OLD',
             p_items => jsonb_build_array(jsonb_build_object(
                 'itemId', v_ti, 'quantity', 1, 'unitPrice', 40, 'taxPercent', 0)),
             p_result => c, p_result2 => c2);
        FETCH c INTO k_ok, k_msg, v_p;
        SELECT movement_date INTO v_txt FROM core.inventory_stock_ledger
         WHERE item_id = v_ti ORDER BY movement_id DESC LIMIT 1;
        PERFORM pg_temp.chk('PUR-19 a back-dated bill is accepted, dated 2001 (rule)',
                            COALESCE(k_ok, FALSE) AND v_txt = '2001-01-01', v_txt);

        c := 'e19c'; c2 := 'e19d';
        CALL core.sp_inventory_purchase_manage('List', c_tenant, c_school, c_user,
             p_from_date => DATE '2001-01-01', p_to_date => DATE '2001-01-01',
             p_result => c, p_result2 => c2);
        v_n := 0; v_m := 0;
        LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
            v_n := v_n + 1; IF r.purchase_id = v_p THEN v_m := 1; END IF;
        END LOOP;
        PERFORM pg_temp.chk('PUR-20 date filter returns only that day''s bill',
                            v_n = 1 AND v_m = 1, format('%s row(s)', v_n));
    END;

    -- Renaming the item later must not rewrite what the bill said.
    c := 'e21';
    CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
         p_item_id => v_ti, p_item_name => 'ZZS Tie (Red)', p_sku => 'ZZS-TIE',
         p_category => 'Uniform', p_min_stock => 10, p_cost_price => 40,
         p_selling_price => 70, p_result => c);
    SELECT item_name INTO v_txt FROM core.inventory_purchase_items WHERE purchase_id = v_pid AND item_id = v_ti;
    PERFORM pg_temp.chk('PUR-21 bill line keeps the name it was bought under',
                        v_txt = 'ZZS Tie', format('line says %s', v_txt));

    -- Another school reading our bill.
    c := 'e22'; c2 := 'e22b';
    CALL core.sp_inventory_purchase_manage('Get', o_tenant, o_school, c_user,
         p_purchase_id => v_pid, p_result => c, p_result2 => c2);
    v_n := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_n := v_n + 1; END LOOP;
    LOOP FETCH c2 INTO r; EXIT WHEN NOT FOUND; v_n := v_n + 1; END LOOP;
    PERFORM pg_temp.chk_eq('PUR-22 Get of our bill from another school: 0 rows', v_n, 0);

    c := 'e23'; c2 := 'e23b';
    CALL core.sp_inventory_purchase_manage('List', o_tenant, o_school, c_user,
         p_result => c, p_result2 => c2);
    v_n := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
        IF r.purchase_id IN (SELECT purchase_id FROM core.inventory_purchases
                              WHERE tenant_id = c_tenant AND school_id = c_school) THEN v_n := v_n + 1; END IF;
    END LOOP;
    PERFORM pg_temp.chk_eq('PUR-23 other school''s purchase list excludes ours', v_n, 0);

    -- Supplier deleted after a bill: the bill still names it, it cannot be
    -- used again, and its name is free.
    c := 'e24';
    CALL core.sp_inventory_manage('DeleteSupplier', c_tenant, c_school, c_user,
         p_supplier_id => v_sp2, p_result => c);
    SELECT COUNT(*) INTO v_n FROM core.inventory_suppliers WHERE supplier_id = v_sp2 AND is_deleted;
    PERFORM pg_temp.chk_eq('SUP-07 delete supplier with a bill is a soft delete', v_n, 1);
    SELECT purchase_id INTO v_m FROM core.inventory_purchases WHERE supplier_id = v_sp2 LIMIT 1;
    c := 'e24b'; c2 := 'e24c';
    CALL core.sp_inventory_purchase_manage('Get', c_tenant, c_school, c_user,
         p_purchase_id => v_m, p_result => c, p_result2 => c2);
    FETCH c INTO r;
    PERFORM pg_temp.chk('SUP-08 its bill still shows the supplier name',
                        r.supplier_name = 'ZZS Paper Mart', format('got %s', r.supplier_name));
    BEGIN
        c := 'e24d'; c2 := 'e24e';
        CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
             p_supplier_id => v_sp2, p_purchase_date => CURRENT_DATE,
             p_items => jsonb_build_array(jsonb_build_object(
                 'itemId', v_nb, 'quantity', 1, 'unitPrice', 1, 'taxPercent', 0)),
             p_result => c, p_result2 => c2);
        PERFORM pg_temp.chk('SUP-09 a deleted supplier cannot take a new bill', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('SUP-09 a deleted supplier cannot take a new bill', TRUE, SQLERRM);
    END;
    -- Re-adding the same supplier gives a NEW id, and the invoice guard is keyed
    -- on supplier_id -- so the same physical bill goes in a second time.
    DECLARE v_sp3 integer;
    BEGIN
        c := 'e25';
        CALL core.sp_inventory_manage('SaveSupplier', c_tenant, c_school, c_user,
             p_supplier_name => 'ZZS Paper Mart', p_result => c);
        FETCH c INTO k_ok, k_msg, v_sp3;
        BEGIN
            c := 'e25b'; c2 := 'e25c';
            CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
                 p_supplier_id => v_sp3, p_purchase_date => CURRENT_DATE, p_invoice_no => 'ZZS-B-1',
                 p_items => jsonb_build_array(jsonb_build_object(
                     'itemId', v_nb, 'quantity', 10, 'unitPrice', 20, 'taxPercent', 0)),
                 p_result => c, p_result2 => c2);
            PERFORM pg_temp.chk('SUP-10 re-added supplier may reuse an old bill no. (rule D-9)',
                                TRUE, 'accepted: same bill counted twice');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('SUP-10 re-added supplier may reuse an old bill no. (rule D-9)',
                                FALSE, SQLERRM);
        END;
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- F. Cancelling a purchase ----------------------------';

    BEGIN
        c := 'f1'; c2 := 'f1b';
        CALL core.sp_inventory_purchase_manage('Cancel', o_tenant, o_school, c_user,
             p_purchase_id => v_pid, p_remarks => 'not yours', p_result => c, p_result2 => c2);
        PERFORM pg_temp.chk('CAN-01 another school cannot cancel our bill', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CAN-01 another school cannot cancel our bill',
                            SQLERRM ILIKE '%not found%', SQLERRM);
    END;
    SELECT COUNT(*) INTO v_n FROM core.inventory_purchases WHERE purchase_id = v_pid AND NOT is_cancelled;
    PERFORM pg_temp.chk_eq('CAN-01b ...the bill is still live', v_n, 1);

    -- Two-line bill where ONE line's goods have gone out: refused whole, and the
    -- line that could be reversed must not have been.
    DECLARE v_ch integer; v_p3 integer; v_tie_rows integer; v_tie_stock numeric;
    BEGIN
        SELECT item_id INTO v_ch FROM core.inventory_items
         WHERE tenant_id = c_tenant AND school_id = c_school AND item_name = 'ZZS Chalk' AND NOT is_deleted;
        c := 'f2'; c2 := 'f2b';
        CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
             p_supplier_id => v_sup, p_purchase_date => CURRENT_DATE, p_invoice_no => 'ZZS-B-3',
             p_items => jsonb_build_array(
                 jsonb_build_object('itemId', v_ti, 'quantity', 10, 'unitPrice', 40, 'taxPercent', 0),
                 jsonb_build_object('itemId', v_ch, 'quantity', 10, 'unitPrice', 12.5, 'taxPercent', 0)),
             p_result => c, p_result2 => c2);
        FETCH c INTO k_ok, k_msg, v_p3;
        -- chalk 5 + 10 = 15; issue 8 -> 7, less than the 10 the bill brought.
        c := 'f2c';
        CALL core.sp_inventory_manage('MoveStock', c_tenant, c_school, c_user,
             p_item_id => v_ch, p_movement_type => 'Issue', p_quantity => 8,
             p_issued_to => 'Class 3A', p_result => c);
        SELECT COUNT(*) INTO v_tie_rows FROM core.inventory_stock_ledger WHERE item_id = v_ti;
        SELECT current_stock INTO v_tie_stock FROM core.inventory_items WHERE item_id = v_ti;
        BEGIN
            c := 'f2d'; c2 := 'f2e';
            CALL core.sp_inventory_purchase_manage('Cancel', c_tenant, c_school, c_user,
                 p_purchase_id => v_p3, p_remarks => 'wrong bill', p_result => c, p_result2 => c2);
            PERFORM pg_temp.chk('CAN-02 cancel after part of the goods were issued refused',
                                FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('CAN-02 cancel after part of the goods were issued refused',
                                SQLERRM ILIKE 'Cannot cancel%', SQLERRM);
        END;
        SELECT COUNT(*) INTO v_n FROM core.inventory_stock_ledger WHERE item_id = v_ti;
        SELECT current_stock INTO v_dec FROM core.inventory_items WHERE item_id = v_ti;
        PERFORM pg_temp.chk('CAN-03 ...the reversible tie line was NOT half-reversed',
                            v_n = v_tie_rows AND v_dec = v_tie_stock,
                            format('tie rows %s->%s stock %s->%s', v_tie_rows, v_n, v_tie_stock, v_dec));
        SELECT current_stock INTO v_dec FROM core.inventory_items WHERE item_id = v_ch;
        PERFORM pg_temp.chk('CAN-03b ...chalk stays at 7 and the bill stays live',
                            v_dec = 7 AND EXISTS (SELECT 1 FROM core.inventory_purchases
                                                   WHERE purchase_id = v_p3 AND NOT is_cancelled),
                            format('chalk %s', v_dec));
    END;

    -- A clean cancel of the big bill: nothing is deleted, everything is kept.
    c := 'f4'; c2 := 'f4b';
    CALL core.sp_inventory_purchase_manage('Cancel', c_tenant, c_school, c_user,
         p_purchase_id => v_pid, p_remarks => '  supplier sent wrong size  ',
         p_result => c, p_result2 => c2);
    SELECT * INTO r FROM core.inventory_purchases WHERE purchase_id = v_pid;
    PERFORM pg_temp.chk('CAN-04 cancelled bill kept: totals, who, when, why',
                        r.is_cancelled AND r.grand_total = 8680 AND r.cancelled_by = c_user
                        AND r.cancelled_at IS NOT NULL AND r.cancel_reason = 'supplier sent wrong size',
                        format('total %s by %s reason "%s"', r.grand_total, r.cancelled_by, r.cancel_reason));
    SELECT COUNT(*) INTO v_n FROM core.inventory_purchase_items WHERE purchase_id = v_pid;
    PERFORM pg_temp.chk_eq('CAN-05 its two lines are still there', v_n, 2);
    SELECT COUNT(*) INTO v_n FROM core.inventory_stock_ledger
     WHERE reference_id = v_pid AND reference_type = 'Purchase';
    PERFORM pg_temp.chk_eq('CAN-06 ledger holds 2 Purchase + 2 PurchaseCancel rows', v_n, 4);
    SELECT COUNT(*) INTO v_n FROM core.inventory_stock_ledger
     WHERE reference_id = v_pid AND movement_type = 'PurchaseCancel'
       AND created_by = c_user AND remarks = 'supplier sent wrong size';
    PERFORM pg_temp.chk_eq('CAN-06b ...the reversals carry author and reason', v_n, 2);
    PERFORM pg_temp.chk_eq('CAN-07 tie: stock = sum(ledger) after cancel', pg_temp.drift(v_ti), 0);
    PERFORM pg_temp.chk_eq('CAN-07b tie: running balance correct after cancel', pg_temp.bad_balances(v_ti), 0);

    -- The corrected bill can now be entered under the same number.
    BEGIN
        c := 'f8'; c2 := 'f8b';
        CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
             p_supplier_id => v_sup, p_purchase_date => CURRENT_DATE, p_invoice_no => 'ZZS-B-1',
             p_items => jsonb_build_array(jsonb_build_object(
                 'itemId', v_ti, 'quantity', 100, 'unitPrice', 40, 'taxPercent', 5)),
             p_result => c, p_result2 => c2);
        PERFORM pg_temp.chk('CAN-08 cancelled bill no. can be re-entered corrected', TRUE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CAN-08 cancelled bill no. can be re-entered corrected', FALSE, SQLERRM);
    END;

    -- No reason given: refused by the proc itself (rule D-5), not only the page.
    DECLARE v_p integer;
    BEGIN
        c := 'f9'; c2 := 'f9b';
        CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
             p_supplier_id => v_sup, p_purchase_date => CURRENT_DATE, p_invoice_no => 'ZZS-NOREASON',
             p_items => jsonb_build_array(jsonb_build_object(
                 'itemId', v_ti, 'quantity', 1, 'unitPrice', 40, 'taxPercent', 0)),
             p_result => c, p_result2 => c2);
        FETCH c INTO k_ok, k_msg, v_p;
        BEGIN
            c := 'f9c'; c2 := 'f9d';
            CALL core.sp_inventory_purchase_manage('Cancel', c_tenant, c_school, c_user,
                 p_purchase_id => v_p, p_remarks => '   ', p_result => c, p_result2 => c2);
            PERFORM pg_temp.chk('CAN-09 cancel with a blank reason refused', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('CAN-09 cancel with a blank reason refused',
                                SQLERRM ILIKE '%reason%', SQLERRM);
        END;
        SELECT COUNT(*) INTO v_n FROM core.inventory_purchases WHERE purchase_id = v_p AND NOT is_cancelled;
        PERFORM pg_temp.chk_eq('CAN-09b ...the bill is still live', v_n, 1);
    END;

    -- THE ONE THAT MATTERS: cancel a bill that has the same item on two lines.
    -- The cancel loop used to read current_stock once for all lines, so the
    -- second line overwrote the first (stock 52 against a ledger of 22).
    c := 'f10'; c2 := 'f10b';
    CALL core.sp_inventory_purchase_manage('Cancel', c_tenant, c_school, c_user,
         p_purchase_id => v_p2, p_remarks => 'duplicate entry', p_result => c, p_result2 => c2);
    v_dec := pg_temp.drift(v_nb);
    IF v_dec <> 0 THEN v_dirty := v_dirty || v_nb; END IF;
    PERFORM pg_temp.chk('CAN-10 cancel of a 2-line same-item bill: stock = sum(ledger)',
                        v_dec = 0, format('drift %s (stock %s, ledger %s)', v_dec,
                        (SELECT current_stock FROM core.inventory_items WHERE item_id = v_nb),
                        (SELECT SUM(quantity) FROM core.inventory_stock_ledger WHERE item_id = v_nb)));
    PERFORM pg_temp.chk_eq('CAN-10b ...balance_after is a running sum', pg_temp.bad_balances(v_nb), 0);

    -- And the same stale read defeats the below-zero guard: bring in 30 + 20,
    -- issue 15 (35 left), then cancel -- 50 cannot come out of 35, but each
    -- line is checked against the stale 35 (35-30 and 35-20 both look fine).
    DECLARE v_bl integer; v_p integer;
    BEGIN
        c := 'f11';
        CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
             p_item_name => 'ZZS Blazer', p_result => c);
        FETCH c INTO k_ok, k_msg, v_bl;
        c := 'f11b'; c2 := 'f11c';
        CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
             p_supplier_id => v_sup, p_purchase_date => CURRENT_DATE, p_invoice_no => 'ZZS-BLZ',
             p_items => jsonb_build_array(
                 jsonb_build_object('itemId', v_bl, 'quantity', 30, 'unitPrice', 900, 'taxPercent', 0),
                 jsonb_build_object('itemId', v_bl, 'quantity', 20, 'unitPrice', 900, 'taxPercent', 0)),
             p_result => c, p_result2 => c2);
        FETCH c INTO k_ok, k_msg, v_p;
        c := 'f11d';
        CALL core.sp_inventory_manage('MoveStock', c_tenant, c_school, c_user,
             p_item_id => v_bl, p_movement_type => 'Issue', p_quantity => 15, p_result => c);
        BEGIN
            c := 'f11e'; c2 := 'f11f';
            CALL core.sp_inventory_purchase_manage('Cancel', c_tenant, c_school, c_user,
                 p_purchase_id => v_p, p_remarks => 'wrong', p_result => c, p_result2 => c2);
            v_dirty := v_dirty || v_bl;
            PERFORM pg_temp.chk('CAN-11 cancel cannot take a 2-line item below zero', FALSE,
                    format('accepted: stock %s, true (ledger) stock %s',
                           (SELECT current_stock FROM core.inventory_items WHERE item_id = v_bl),
                           (SELECT SUM(quantity) FROM core.inventory_stock_ledger WHERE item_id = v_bl)));
        EXCEPTION WHEN OTHERS THEN
            -- The message must name the bill's TOTAL for the item (50), not one line.
            PERFORM pg_temp.chk('CAN-11 cancel cannot take a 2-line item below zero',
                                SQLERRM ~* 'Cannot cancel: only 35(\.00)? Piece of ZZS Blazer left, and this purchase brought in 50(\.00)?',
                                SQLERRM);
        END;
        SELECT current_stock INTO v_dec FROM core.inventory_items WHERE item_id = v_bl;
        PERFORM pg_temp.chk('CAN-11b ...blazer stays at 35, matching its ledger',
                            v_dec = 35 AND pg_temp.drift(v_bl) = 0, format('stock %s', v_dec));
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- G. The ledger IS the stock --------------------------';

    -- History is in date order, newest first, then entry order within a day
    -- (rule D-4). The tie has a 2001 bill entered late: it must sit at the
    -- bottom, and the running balance must read cleanly in that order.
    DECLARE v_first record; v_prev_date text; v_prev_id integer; v_bad integer := 0;
            v_rows integer := 0; v_last record;
    BEGIN
        c := 'g1';
        CALL core.sp_inventory_manage('ItemLedger', c_tenant, c_school, c_user, p_item_id => v_ti, p_result => c);
        LOOP
            FETCH c INTO r; EXIT WHEN NOT FOUND;
            v_rows := v_rows + 1;
            IF v_rows = 1 THEN v_first := r; END IF;
            IF v_prev_date IS NOT NULL AND (r.movement_date > v_prev_date
               OR (r.movement_date = v_prev_date AND r.movement_id > v_prev_id)) THEN
                v_bad := v_bad + 1;
            END IF;
            v_prev_date := r.movement_date; v_prev_id := r.movement_id;
            v_last := r;
        END LOOP;
        PERFORM pg_temp.chk_eq('LED-01 history is date-desc, then entry-desc', v_bad, 0);
        PERFORM pg_temp.chk('LED-01b ...the 2001 bill is the oldest row',
                            v_last.movement_date = '2001-01-01', format('last row dated %s', v_last.movement_date));
        PERFORM pg_temp.chk('LED-01c ...top row''s balance = current stock',
                            v_first.balance = (SELECT current_stock FROM core.inventory_items WHERE item_id = v_ti),
                            format('balance %s', v_first.balance));
        PERFORM pg_temp.chk('LED-01d ...each row names who made it, with a rate',
                            NULLIF(v_first.created_by_name, '') IS NOT NULL AND v_first.unit_rate IS NOT NULL,
                            format('by "%s" at %s', v_first.created_by_name, v_first.unit_rate));
    END;

    c := 'g2';
    CALL core.sp_inventory_manage('ItemLedger', o_tenant, o_school, c_user, p_item_id => v_ti, p_result => c);
    v_n := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_n := v_n + 1; END LOOP;
    PERFORM pg_temp.chk_eq('LED-02 our item ledger from another school: 0 rows', v_n, 0);

    -- The whole fixture, minus any item an earlier FAILED check already reported.
    SELECT COUNT(*), string_agg(item_name, ', ') INTO v_n, v_txt
      FROM core.inventory_items
     WHERE tenant_id = c_tenant AND school_id = c_school
       AND NOT (item_id = ANY (v_dirty)) AND pg_temp.drift(item_id) <> 0;
    PERFORM pg_temp.chk_eq('LED-03 every other item: stock = sum(ledger)', v_n, 0);
    IF v_n > 0 THEN RAISE NOTICE '      drifted: %', v_txt; END IF;

    SELECT COUNT(*) INTO v_n
      FROM core.inventory_items
     WHERE tenant_id = c_tenant AND school_id = c_school
       AND NOT (item_id = ANY (v_dirty)) AND pg_temp.bad_balances(item_id) > 0;
    PERFORM pg_temp.chk_eq('LED-04 every other item: balance_after is a running sum', v_n, 0);

    SELECT COUNT(*) INTO v_n FROM core.inventory_items
     WHERE tenant_id = c_tenant AND school_id = c_school
       AND NOT (item_id = ANY (v_dirty)) AND current_stock < 0;
    PERFORM pg_temp.chk_eq('LED-05 no other item below zero', v_n, 0);
    RAISE NOTICE '      (items excluded after an earlier failed check: %)', COALESCE(array_length(v_dirty, 1), 0);

    -- Every bill written through the proc: sub = sum of its lines' qty x rate,
    -- grand = sum of its line totals, and sub + tax = grand.
    SELECT COUNT(*), string_agg(COALESCE(p.invoice_no, '#' || p.purchase_id), ', ') INTO v_n, v_txt
      FROM core.inventory_purchases p
     WHERE p.tenant_id = c_tenant AND p.school_id = c_school
       AND EXISTS (SELECT 1 FROM core.inventory_purchase_items WHERE purchase_id = p.purchase_id)
       AND (p.sub_total <> (SELECT SUM(ROUND(quantity * unit_price, 2))
                            FROM core.inventory_purchase_items WHERE purchase_id = p.purchase_id)
         OR p.grand_total <> (SELECT SUM(line_total)
                            FROM core.inventory_purchase_items WHERE purchase_id = p.purchase_id)
         OR p.sub_total + p.tax_total <> p.grand_total);
    PERFORM pg_temp.chk('LED-06 every bill: lines = header (sub, tax, grand)', v_n = 0,
                        format('%s bill(s) %s', v_n, COALESCE(v_txt, '')));

    -- The floors behind the procs.
    BEGIN
        UPDATE core.inventory_items SET current_stock = -1 WHERE item_id = v_ti;
        PERFORM pg_temp.chk('LED-06b the table itself refuses negative stock', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('LED-06b the table itself refuses negative stock',
                            SQLERRM ILIKE '%chk_inv_item_stock%', SQLERRM);
    END;

    -- Nothing in any inventory proc deletes or rewrites history. (The platform's
    -- sp_school_purge removes a whole school's rows on purpose; it is not a
    -- store operation and is tested with the platform suite.)
    SELECT COUNT(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'core' AND p.proname LIKE 'sp_inventory%'
       AND (p.prosrc ~* 'delete\s+from\s+core\.inventory_'
         OR p.prosrc ~* 'update\s+core\.inventory_stock_ledger'
         OR p.prosrc ~* 'update\s+core\.inventory_purchase_items');
    PERFORM pg_temp.chk_eq('LED-07 no proc hard-deletes inventory rows or edits the ledger', v_n, 0);

    -- Another school's Recount must not touch our cache.
    UPDATE core.inventory_items SET current_stock = current_stock + 777 WHERE item_id = v_ti;
    c := 'g8';
    CALL core.sp_inventory_manage('Recount', o_tenant, o_school, c_user, p_result => c);
    PERFORM pg_temp.chk_eq('LED-08 other school''s Recount leaves our item alone', pg_temp.drift(v_ti), 777);
    c := 'g8b';
    CALL core.sp_inventory_manage('Recount', c_tenant, c_school, c_user, p_result => c);
    PERFORM pg_temp.chk_eq('LED-08b ...our own Recount repairs it', pg_temp.drift(v_ti), 0);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- H. Scope --------------------------------------------';

    BEGIN
        c := 'h1'; c2 := 'h1b';
        CALL core.sp_inventory_purchase_manage('List', 1, 0, c_user, p_result => c, p_result2 => c2);
        PERFORM pg_temp.chk('TEN-01 platform scope purchase read refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('TEN-01 platform scope purchase read refused',
                            SQLERRM ILIKE '%scope%', SQLERRM);
    END;
    BEGIN
        c := 'h2';
        CALL core.sp_inventory_manage('Recount', 1, 0, c_user, p_result => c);
        PERFORM pg_temp.chk('TEN-02 platform scope Recount refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('TEN-02 platform scope Recount refused', SQLERRM ILIKE '%scope%', SQLERRM);
    END;
    BEGIN
        c := 'h3';
        CALL core.sp_inventory_manage('SaveItem', 24, 0, c_user, p_item_name => 'ZZS No School', p_result => c);
        PERFORM pg_temp.chk('TEN-03 school 0 refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('TEN-03 school 0 refused', SQLERRM ILIKE '%scope%', SQLERRM);
    END;

    -- Every row we wrote is ours; only the one deliberately foreign supplier is not.
    SELECT (SELECT COUNT(*) FROM core.inventory_items
             WHERE item_name LIKE 'ZZS%' AND (tenant_id <> c_tenant OR school_id <> c_school))
         + (SELECT COUNT(*) FROM core.inventory_suppliers
             WHERE supplier_name LIKE 'ZZS%' AND supplier_name <> 'ZZS Foreign Supplier'
               AND (tenant_id <> c_tenant OR school_id <> c_school))
         + (SELECT COUNT(*) FROM core.inventory_purchases
             WHERE invoice_no LIKE 'ZZS%' AND (tenant_id <> c_tenant OR school_id <> c_school))
         + (SELECT COUNT(*) FROM core.inventory_stock_ledger l JOIN core.inventory_items i USING (item_id)
             WHERE l.tenant_id <> i.tenant_id OR l.school_id <> i.school_id)
         + (SELECT COUNT(*) FROM core.inventory_purchase_items pi JOIN core.inventory_purchases p USING (purchase_id)
             WHERE pi.tenant_id <> p.tenant_id OR pi.school_id <> p.school_id)
      INTO v_n;
    PERFORM pg_temp.chk_eq('TEN-04 nothing leaked; every child row matches its parent''s school', v_n, 0);
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
