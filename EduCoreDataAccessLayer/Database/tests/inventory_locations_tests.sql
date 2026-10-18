-- ============================================================================
-- Inventory: store locations, transfers, returns to supplier, supplier screen.
--
-- inventory_tests.sql and inventory_store_tests.sql cover one shelf per school.
-- This suite covers the 2026-10-10b revision of inventory.sql (D-10):
--
--   * the migration: every existing movement and bill goes into the school's
--     default "Main Store", totals unchanged, and a re-run changes nothing
--   * stock per item per location, with
--         current_stock = SUM(location stock) = SUM(ledger)
--         location stock = SUM(ledger rows at that location)
--   * transfers (paired TransferOut / TransferIn rows)
--   * partial return to supplier, and cancelling a bill that has returns
--     (only the remainder is reversed)
--   * supplier active / inactive, search, bill counts
--   * tenant isolation for all of it
--
-- Runs inside ONE transaction and ROLLS BACK. It re-runs ../inventory.sql
-- twice inside that transaction to test the migration, so run it from any
-- directory with:
--
--     psql ... -f EduCoreDataAccessLayer/Database/tests/inventory_locations_tests.sql
--
-- Fixture: tenant 24 / school 34 / user 39. The other school is 23 / 33.
--
-- COVERS
--   M. Migration                      (MIG)
--   L. Locations                      (LOC)
--   V. Movements at a location        (MVL)
--   T. Transfers                      (TRF)
--   P. Purchases into a location      (PUL)
--   R. Return to supplier             (RET)
--   C. Cancel a bill with returns     (CWR)
--   S. Supplier screen                (SUL)
--   I. Invariants                     (INV)
--   K. Cursors / scope                (CUR, TEN)
-- ============================================================================

\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE TEMP TABLE _t(id serial, name text, ok boolean, detail text) ON COMMIT DROP;
CREATE TEMP TABLE _legacy(item_id integer, stock_before numeric) ON COMMIT DROP;
CREATE TEMP TABLE _snap(k text, v numeric) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.chk(p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO _t(name, ok, detail) VALUES (p_name, p_ok, p_detail);
    RAISE NOTICE '  [%] %  %', CASE WHEN p_ok THEN 'PASS' ELSE 'FAIL' END, rpad(p_name, 58), p_detail;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.chk_eq(p_name text, p_got numeric, p_want numeric)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.chk(p_name, p_got IS NOT DISTINCT FROM p_want,
                        format('got %s, expected %s', COALESCE(p_got::text,'NULL'), p_want));
END $$;

-- Stock of an item at one location (0 when it has no row).
CREATE OR REPLACE FUNCTION pg_temp.at(p_item integer, p_loc integer)
RETURNS numeric LANGUAGE sql AS $$
    SELECT COALESCE((SELECT quantity FROM core.inventory_location_stock
                     WHERE item_id = p_item AND location_id = p_loc), 0);
$$;

-- Items of a school whose three figures disagree:
-- current_stock, SUM(location stock), SUM(ledger).
CREATE OR REPLACE FUNCTION pg_temp.bad_items(p_tenant integer, p_school integer)
RETURNS integer LANGUAGE sql AS $$
    SELECT COUNT(*)::int FROM core.inventory_items i
    WHERE i.tenant_id = p_tenant AND i.school_id = p_school
      AND (i.current_stock <> COALESCE((SELECT SUM(s.quantity) FROM core.inventory_location_stock s
                                        WHERE s.item_id = i.item_id), 0)
        OR i.current_stock <> COALESCE((SELECT SUM(l.quantity) FROM core.inventory_stock_ledger l
                                        WHERE l.item_id = i.item_id), 0));
$$;

-- Item/location pairs whose stock is not the sum of the ledger rows at it.
CREATE OR REPLACE FUNCTION pg_temp.bad_pairs(p_tenant integer, p_school integer)
RETURNS integer LANGUAGE sql AS $$
    SELECT COUNT(*)::int FROM (
        SELECT COALESCE(s.item_id, l.item_id) AS item_id,
               COALESCE(s.quantity, 0) AS stock, COALESCE(l.qty, 0) AS moved
        FROM (SELECT * FROM core.inventory_location_stock
              WHERE tenant_id = p_tenant AND school_id = p_school) s
        FULL JOIN (SELECT item_id, location_id, SUM(quantity) AS qty
                   FROM core.inventory_stock_ledger
                   WHERE tenant_id = p_tenant AND school_id = p_school
                   GROUP BY item_id, location_id) l
               ON l.item_id = s.item_id AND l.location_id = s.location_id) x
    WHERE x.stock <> x.moved;
$$;

-- Ledger rows of a school whose balance_after (item total) or
-- location_balance_after is not the running sum up to that row.
CREATE OR REPLACE FUNCTION pg_temp.bad_balances(p_tenant integer, p_school integer)
RETURNS integer LANGUAGE sql AS $$
    SELECT COUNT(*)::int FROM (
        SELECT balance_after, location_balance_after,
               SUM(quantity) OVER (PARTITION BY item_id ORDER BY movement_id) AS run_item,
               SUM(quantity) OVER (PARTITION BY item_id, location_id ORDER BY movement_id) AS run_loc
        FROM core.inventory_stock_ledger
        WHERE tenant_id = p_tenant AND school_id = p_school) x
    WHERE x.balance_after <> x.run_item OR x.location_balance_after <> x.run_loc;
$$;


-- ════════════════════════════════════════════════════════════════════════════
-- M. Migration. Build "legacy" rows the way the old procs wrote them (no
-- location anywhere), then run inventory.sql twice.
-- ════════════════════════════════════════════════════════════════════════════
DO $legacy$
DECLARE
    v_a  integer;
    v_b  integer;
    v_cc integer;
    v_p  integer;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '========= INVENTORY LOCATIONS TESTS =========';
    RAISE NOTICE '';
    RAISE NOTICE '-- M. Migration ----------------------------------------';

    -- Only meaningful when the fixture school has no inventory yet.
    IF EXISTS (SELECT 1 FROM core.inventory_locations WHERE tenant_id = 24 AND school_id = 34) THEN
        RAISE NOTICE '  (school 34 already has locations; migration fixture still runs)';
    END IF;

    ALTER TABLE core.inventory_stock_ledger ALTER COLUMN location_id DROP NOT NULL;

    -- A: opening 50, issue 20, a bill of 5 => 35.  B: 10 in, 10 out => 0.
    -- C: never moved.
    INSERT INTO core.inventory_items (tenant_id, school_id, item_name, current_stock, cost_price, created_by)
    VALUES (24, 34, 'ZZL Legacy A', 35, 10, 39) RETURNING item_id INTO v_a;
    INSERT INTO core.inventory_items (tenant_id, school_id, item_name, current_stock, cost_price, created_by)
    VALUES (24, 34, 'ZZL Legacy B', 0, 5, 39) RETURNING item_id INTO v_b;
    INSERT INTO core.inventory_items (tenant_id, school_id, item_name, current_stock, created_by)
    VALUES (24, 34, 'ZZL Legacy C', 0, 39) RETURNING item_id INTO v_cc;

    INSERT INTO core.inventory_purchases (tenant_id, school_id, purchase_date, invoice_no, created_by)
    VALUES (24, 34, to_char(CURRENT_DATE, 'YYYY-MM-DD'), 'ZZL-LEGACY-1', 39) RETURNING purchase_id INTO v_p;
    INSERT INTO core.inventory_purchase_items (tenant_id, school_id, purchase_id, item_id, item_name, quantity, unit_price, line_total)
    VALUES (24, 34, v_p, v_a, 'ZZL Legacy A', 5, 10, 50);

    INSERT INTO core.inventory_stock_ledger
        (tenant_id, school_id, item_id, movement_type, quantity, balance_after, reference_type, reference_id, created_by)
    VALUES (24, 34, v_a, 'Opening',  50, 50, NULL, NULL, 39),
           (24, 34, v_a, 'Issue',   -20, 30, NULL, NULL, 39),
           (24, 34, v_b, 'Opening',  10, 10, NULL, NULL, 39),
           (24, 34, v_a, 'Purchase',  5, 35, 'Purchase', v_p, 39),
           (24, 34, v_b, 'Damage',  -10,  0, NULL, NULL, 39);

    INSERT INTO _legacy SELECT item_id, current_stock FROM core.inventory_items
     WHERE item_id IN (v_a, v_b, v_cc);
    INSERT INTO _snap VALUES ('purchase', v_p);
END
$legacy$;

-- The script is noisy on a re-run ("already exists, skipping").
SET client_min_messages = warning;
\ir ../inventory.sql
SET client_min_messages = notice;

DO $mig1$
DECLARE
    v_loc integer;
    v_n   integer;
    v_dec numeric;
    v_p   integer := (SELECT v::int FROM _snap WHERE k = 'purchase');
BEGIN
    SELECT COUNT(*) INTO v_n FROM core.inventory_locations
     WHERE tenant_id = 24 AND school_id = 34 AND is_default;
    PERFORM pg_temp.chk_eq('MIG-01 the school has exactly one default location', v_n, 1);
    SELECT location_id INTO v_loc FROM core.inventory_locations
     WHERE tenant_id = 24 AND school_id = 34 AND is_default;
    PERFORM pg_temp.chk('MIG-01b ...called "Main Store"',
                        (SELECT location_name FROM core.inventory_locations WHERE location_id = v_loc) = 'Main Store',
                        (SELECT location_name FROM core.inventory_locations WHERE location_id = v_loc));

    SELECT COUNT(*) INTO v_n FROM core.inventory_stock_ledger l
     WHERE l.item_id IN (SELECT item_id FROM _legacy) AND l.location_id IS DISTINCT FROM v_loc;
    PERFORM pg_temp.chk_eq('MIG-02 every legacy movement now sits in the default location', v_n, 0);

    SELECT COUNT(*) INTO v_n FROM core.inventory_stock_ledger WHERE location_id IS NULL;
    PERFORM pg_temp.chk_eq('MIG-02b no movement anywhere is left without a location', v_n, 0);

    PERFORM pg_temp.chk('MIG-03 the legacy bill went into the default location',
                        (SELECT location_id FROM core.inventory_purchases WHERE purchase_id = v_p) = v_loc, '');

    SELECT COUNT(*) INTO v_n FROM _legacy g JOIN core.inventory_items i USING (item_id)
     WHERE i.current_stock <> g.stock_before;
    PERFORM pg_temp.chk_eq('MIG-04 item totals are unchanged by the migration', v_n, 0);

    SELECT COUNT(*) INTO v_n FROM _legacy g
     WHERE g.stock_before <> COALESCE((SELECT SUM(quantity) FROM core.inventory_location_stock s
                                       WHERE s.item_id = g.item_id), 0);
    PERFORM pg_temp.chk_eq('MIG-04b ...and each equals the sum of its location stock', v_n, 0);

    SELECT pg_temp.at(item_id, v_loc) INTO v_dec FROM _legacy WHERE stock_before = 35;
    PERFORM pg_temp.chk_eq('MIG-04c Legacy A: 35 at Main Store', v_dec, 35);

    SELECT COUNT(*) INTO v_n FROM core.inventory_stock_ledger
     WHERE item_id IN (SELECT item_id FROM _legacy) AND location_balance_after IS NULL;
    PERFORM pg_temp.chk_eq('MIG-05 location_balance_after back-filled on old rows', v_n, 0);
    PERFORM pg_temp.chk_eq('MIG-05b ...as a running sum per location', pg_temp.bad_balances(24, 34), 0);

    -- The whole database, not only the fixture: three figures agree everywhere.
    SELECT COUNT(*) INTO v_n FROM core.inventory_items i
     WHERE i.current_stock <> COALESCE((SELECT SUM(s.quantity) FROM core.inventory_location_stock s
                                        WHERE s.item_id = i.item_id), 0);
    PERFORM pg_temp.chk_eq('MIG-06 every item in the database: total = sum of locations', v_n, 0);

    INSERT INTO _snap VALUES
        ('locs',  (SELECT COUNT(*) FROM core.inventory_locations)),
        ('rows',  (SELECT COUNT(*) FROM core.inventory_location_stock)),
        ('qty',   (SELECT COALESCE(SUM(quantity), 0) FROM core.inventory_location_stock)),
        ('moves', (SELECT COUNT(*) FROM core.inventory_stock_ledger));
END
$mig1$;

-- Run it again: nothing may be migrated twice.
SET client_min_messages = warning;
\ir ../inventory.sql
SET client_min_messages = notice;

DO $mig2$
BEGIN
    PERFORM pg_temp.chk('MIG-07 re-run: no new location, stock row, quantity or movement',
        (SELECT COUNT(*) FROM core.inventory_locations)                  = (SELECT v FROM _snap WHERE k = 'locs')
    AND (SELECT COUNT(*) FROM core.inventory_location_stock)             = (SELECT v FROM _snap WHERE k = 'rows')
    AND (SELECT COALESCE(SUM(quantity), 0) FROM core.inventory_location_stock) = (SELECT v FROM _snap WHERE k = 'qty')
    AND (SELECT COUNT(*) FROM core.inventory_stock_ledger)               = (SELECT v FROM _snap WHERE k = 'moves'),
        '');
    PERFORM pg_temp.chk('MIG-07b ledger.location_id is NOT NULL again',
        (SELECT is_nullable FROM information_schema.columns
          WHERE table_schema = 'core' AND table_name = 'inventory_stock_ledger'
            AND column_name = 'location_id') = 'NO', '');
END
$mig2$;


-- ════════════════════════════════════════════════════════════════════════════
-- The features.
-- ════════════════════════════════════════════════════════════════════════════
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
    v_main integer;    -- default location
    v_lab  integer;    -- "ZZL Science Lab"
    v_spt  integer;    -- "ZZL Sports Room"
    v_olc  integer;    -- the other school's location
    v_tie  integer;    -- "ZZL Tie": opening 50 at Main Store
    v_bal  integer;    -- "ZZL Ball"
    v_off  integer;    -- an Inactive item with stock
    v_sup  integer;
    v_sp2  integer;
    v_pid  integer;
    v_p2   integer;
    v_l1   integer;    -- bill lines
    v_l2   integer;
    v_l3   integer;
    v_n    integer;
    v_dec  numeric;
    v_d2   numeric;
    v_txt  text;
    k_ok   boolean;
    k_msg  text;
BEGIN
    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- L. Locations ----------------------------------------';

    c := 'l1';
    CALL core.sp_inventory_manage('ListLocations', c_tenant, c_school, c_user, p_result => c);
    v_n := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
        v_n := v_n + 1;
        IF r.is_default THEN v_main := r.location_id; END IF;
    END LOOP;
    PERFORM pg_temp.chk('LOC-01 ListLocations returns the default location', v_main IS NOT NULL,
                        format('%s row(s), default %s', v_n, v_main));

    c := 'l2';
    CALL core.sp_inventory_manage('SaveLocation', c_tenant, c_school, c_user,
         p_location_name => '  ZZL Science Lab ', p_result => c);
    FETCH c INTO k_ok, k_msg, v_lab;
    c := 'l2b';
    CALL core.sp_inventory_manage('SaveLocation', c_tenant, c_school, c_user,
         p_location_name => 'ZZL Sports Room', p_result => c);
    FETCH c INTO k_ok, k_msg, v_spt;
    PERFORM pg_temp.chk('LOC-02 two locations added, name trimmed',
                        v_lab IS NOT NULL AND v_spt IS NOT NULL
                        AND (SELECT location_name FROM core.inventory_locations WHERE location_id = v_lab) = 'ZZL Science Lab',
                        format('lab=%s sports=%s', v_lab, v_spt));

    BEGIN
        c := 'l3';
        CALL core.sp_inventory_manage('SaveLocation', c_tenant, c_school, c_user,
             p_location_name => ' zzl SCIENCE lab', p_result => c);
        PERFORM pg_temp.chk('LOC-03 duplicate name (other case/spaces) refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('LOC-03 duplicate name (other case/spaces) refused',
                            SQLERRM ILIKE 'A location named%already exists%', SQLERRM);
    END;
    BEGIN
        c := 'l4';
        CALL core.sp_inventory_manage('SaveLocation', c_tenant, c_school, c_user,
             p_location_name => '   ', p_result => c);
        PERFORM pg_temp.chk('LOC-04 blank name refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('LOC-04 blank name refused', SQLERRM ILIKE '%required%', SQLERRM);
    END;
    BEGIN
        c := 'l4b';
        CALL core.sp_inventory_manage('SaveLocation', c_tenant, c_school, c_user,
             p_location_name => repeat('Z', 101), p_result => c);
        PERFORM pg_temp.chk('LOC-04b name over 100 characters refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('LOC-04b name over 100 characters refused', SQLERRM ILIKE '%100 characters%', SQLERRM);
    END;

    c := 'l5';
    CALL core.sp_inventory_manage('SaveLocation', c_tenant, c_school, c_user,
         p_location_id => v_spt, p_location_name => 'ZZL Sports Store', p_result => c);
    PERFORM pg_temp.chk('LOC-05 rename works',
                        (SELECT location_name FROM core.inventory_locations WHERE location_id = v_spt) = 'ZZL Sports Store', '');
    BEGIN
        c := 'l5b';
        CALL core.sp_inventory_manage('SaveLocation', c_tenant, c_school, c_user,
             p_location_id => v_spt, p_location_name => 'ZZL Science Lab', p_result => c);
        PERFORM pg_temp.chk('LOC-05b rename onto another location''s name refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('LOC-05b rename onto another location''s name refused',
                            SQLERRM ILIKE '%already exists%', SQLERRM);
    END;

    -- The other school's own location, for the cross-school checks.
    c := 'l6';
    CALL core.sp_inventory_manage('SaveLocation', o_tenant, o_school, c_user,
         p_location_name => 'ZZL Foreign Room', p_result => c);
    FETCH c INTO k_ok, k_msg, v_olc;

    BEGIN
        c := 'l6b';
        CALL core.sp_inventory_manage('SaveLocation', o_tenant, o_school, c_user,
             p_location_id => v_lab, p_location_name => 'Hijacked', p_result => c);
        PERFORM pg_temp.chk('LOC-06 cross-school rename refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('LOC-06 cross-school rename refused', SQLERRM ILIKE '%not found%', SQLERRM);
    END;
    BEGIN
        c := 'l6c';
        CALL core.sp_inventory_manage('SetLocationActive', o_tenant, o_school, c_user,
             p_location_id => v_lab, p_is_active => FALSE, p_result => c);
        PERFORM pg_temp.chk('LOC-06b cross-school deactivate refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('LOC-06b cross-school deactivate refused', SQLERRM ILIKE '%not found%', SQLERRM);
    END;
    PERFORM pg_temp.chk('LOC-06c ...our lab unchanged',
                        (SELECT location_name = 'ZZL Science Lab' AND is_active
                           FROM core.inventory_locations WHERE location_id = v_lab), '');

    BEGIN
        c := 'l7';
        CALL core.sp_inventory_manage('SetLocationActive', c_tenant, c_school, c_user,
             p_location_id => v_main, p_is_active => FALSE, p_result => c);
        PERFORM pg_temp.chk('LOC-07 the default location cannot be deactivated', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('LOC-07 the default location cannot be deactivated',
                            SQLERRM ILIKE '%default location%', SQLERRM);
    END;

    c := 'l9';
    CALL core.sp_inventory_manage('ListLocations', o_tenant, o_school, c_user, p_result => c);
    v_n := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
        IF r.location_id IN (v_main, v_lab, v_spt) THEN v_n := v_n + 1; END IF;
    END LOOP;
    PERFORM pg_temp.chk_eq('LOC-09 other school''s list excludes our locations', v_n, 0);

    -- Items. Tie: 50 opening at Main Store (no location given). Ball: 12
    -- opening straight into the lab.
    c := 'l10';
    CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
         p_item_name => 'ZZL Tie', p_unit_type => 'Piece', p_opening_stock => 50,
         p_cost_price => 40, p_result => c);
    FETCH c INTO k_ok, k_msg, v_tie;
    c := 'l10b';
    CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
         p_item_name => 'ZZL Ball', p_unit_type => 'Piece', p_opening_stock => 12,
         p_cost_price => 100, p_location_id => v_lab, p_result => c);
    FETCH c INTO k_ok, k_msg, v_bal;
    PERFORM pg_temp.chk('LOC-10 opening stock: no location -> Main Store, chosen -> that location',
                        pg_temp.at(v_tie, v_main) = 50 AND pg_temp.at(v_bal, v_lab) = 12
                        AND pg_temp.at(v_bal, v_main) = 0,
                        format('tie@main=%s ball@lab=%s', pg_temp.at(v_tie, v_main), pg_temp.at(v_bal, v_lab)));
    PERFORM pg_temp.chk('LOC-10b the Opening row names the lab',
                        EXISTS (SELECT 1 FROM core.inventory_stock_ledger WHERE item_id = v_bal
                                AND movement_type = 'Opening' AND location_id = v_lab
                                AND location_balance_after = 12), '');

    BEGIN
        c := 'l11';
        CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
             p_item_name => 'ZZL Foreign Opening', p_opening_stock => 5,
             p_location_id => v_olc, p_result => c);
        PERFORM pg_temp.chk('LOC-11 opening stock into another school''s location refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('LOC-11 opening stock into another school''s location refused',
                            SQLERRM ILIKE '%location not found%', SQLERRM);
    END;
    PERFORM pg_temp.chk('LOC-11b ...and no half item was left',
                        NOT EXISTS (SELECT 1 FROM core.inventory_items WHERE item_name = 'ZZL Foreign Opening'), '');

    -- Sports Store: deactivate (empty), then opening stock into it is refused.
    c := 'l12';
    CALL core.sp_inventory_manage('SetLocationActive', c_tenant, c_school, c_user,
         p_location_id => v_spt, p_is_active => FALSE, p_result => c);
    PERFORM pg_temp.chk('LOC-12 an empty location can be deactivated',
                        NOT (SELECT is_active FROM core.inventory_locations WHERE location_id = v_spt), '');
    BEGIN
        c := 'l12b';
        CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
             p_item_name => 'ZZL Into Inactive', p_opening_stock => 5,
             p_location_id => v_spt, p_result => c);
        PERFORM pg_temp.chk('LOC-12b opening stock into an inactive location refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('LOC-12b opening stock into an inactive location refused',
                            SQLERRM ILIKE '%inactive%', SQLERRM);
    END;

    -- ListItems at a location shows the stock there.
    c := 'l13';
    CALL core.sp_inventory_manage('ListItems', c_tenant, c_school, c_user,
         p_location_id => v_lab, p_result => c);
    v_dec := NULL; v_d2 := NULL;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
        IF r.item_id = v_bal THEN v_dec := r.current_stock; END IF;
        IF r.item_id = v_tie THEN v_d2 := r.current_stock; END IF;
    END LOOP;
    PERFORM pg_temp.chk('LOC-13 ListItems at the lab: ball 12, tie 0',
                        v_dec = 12 AND v_d2 = 0, format('ball=%s tie=%s', v_dec, v_d2));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- V. Movements at a location --------------------------';

    -- The school has 12 balls, all in the lab: Main Store has none to issue.
    BEGIN
        c := 'v1';
        CALL core.sp_inventory_manage('MoveStock', c_tenant, c_school, c_user,
             p_item_id => v_bal, p_movement_type => 'Issue', p_quantity => 1,
             p_location_id => v_main, p_result => c);
        PERFORM pg_temp.chk('MVL-01 issue at a location that holds none refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('MVL-01 issue at a location that holds none refused',
                            SQLERRM ~* 'Only 0(.00)? Piece of ZZL Ball left at Main Store.*', SQLERRM);
    END;

    c := 'v2';
    CALL core.sp_inventory_manage('MoveStock', c_tenant, c_school, c_user,
         p_item_id => v_tie, p_movement_type => 'Issue', p_quantity => 5,
         p_issued_to => 'Class 4', p_result => c);
    FETCH c INTO k_ok, k_msg, v_dec;
    PERFORM pg_temp.chk('MVL-02 issue with no location comes out of Main Store',
                        v_dec = 45 AND pg_temp.at(v_tie, v_main) = 45, format('total %s', v_dec));

    -- Stock-take at the lab: counted 10 of the 12 there.
    c := 'v3';
    CALL core.sp_inventory_manage('MoveStock', c_tenant, c_school, c_user,
         p_item_id => v_bal, p_movement_type => 'StockTake', p_quantity => 10,
         p_location_id => v_lab, p_remarks => 'two missing', p_result => c);
    SELECT quantity INTO v_dec FROM core.inventory_stock_ledger
     WHERE item_id = v_bal ORDER BY movement_id DESC LIMIT 1;
    PERFORM pg_temp.chk('MVL-03 stock-take compares with the stock AT that location (-2)',
                        v_dec = -2 AND pg_temp.at(v_bal, v_lab) = 10, format('movement %s', v_dec));

    BEGIN
        c := 'v4';
        CALL core.sp_inventory_manage('MoveStock', c_tenant, c_school, c_user,
             p_item_id => v_tie, p_movement_type => 'Return', p_quantity => 1,
             p_location_id => v_spt, p_result => c);
        PERFORM pg_temp.chk('MVL-04 movement at an inactive location refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('MVL-04 movement at an inactive location refused', SQLERRM ILIKE '%inactive%', SQLERRM);
    END;
    BEGIN
        c := 'v5';
        CALL core.sp_inventory_manage('MoveStock', c_tenant, c_school, c_user,
             p_item_id => v_tie, p_movement_type => 'Return', p_quantity => 1,
             p_location_id => v_olc, p_result => c);
        PERFORM pg_temp.chk('MVL-05 movement at another school''s location refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('MVL-05 movement at another school''s location refused',
                            SQLERRM ILIKE '%location not found%', SQLERRM);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- T. Transfers ----------------------------------------';

    c := 't1';
    CALL core.sp_inventory_manage('Transfer', c_tenant, c_school, c_user,
         p_item_id => v_tie, p_location_id => v_main, p_to_location_id => v_lab,
         p_quantity => 10, p_remarks => '  for the lab display ', p_result => c);
    FETCH c INTO k_ok, k_msg, v_dec;
    PERFORM pg_temp.chk('TRF-01 transfer 10 ties Main -> Lab: 35 / 10, total still 45',
                        pg_temp.at(v_tie, v_main) = 35 AND pg_temp.at(v_tie, v_lab) = 10 AND v_dec = 45,
                        format('main=%s lab=%s total=%s; %s', pg_temp.at(v_tie, v_main),
                               pg_temp.at(v_tie, v_lab), v_dec, k_msg));
    SELECT * INTO r FROM core.inventory_transfers WHERE item_id = v_tie ORDER BY transfer_id DESC LIMIT 1;
    PERFORM pg_temp.chk('TRF-01b one transfer row: from, to, qty, trimmed reason, who',
                        r.from_location_id = v_main AND r.to_location_id = v_lab AND r.quantity = 10
                        AND r.reason = 'for the lab display' AND r.created_by = c_user
                        AND r.tenant_id = c_tenant AND r.school_id = c_school, '');
    SELECT COUNT(*) INTO v_n FROM core.inventory_stock_ledger
     WHERE reference_type = 'Transfer' AND reference_id = r.transfer_id
       AND ((movement_type = 'TransferOut' AND quantity = -10 AND location_id = v_main)
         OR (movement_type = 'TransferIn'  AND quantity =  10 AND location_id = v_lab))
       AND created_by = c_user AND remarks = 'for the lab display' AND unit_rate = 40;
    PERFORM pg_temp.chk_eq('TRF-01c paired ledger rows: Out -10 at Main, In +10 at Lab, rate, who', v_n, 2);

    SELECT COUNT(*) INTO v_n FROM core.inventory_stock_ledger WHERE item_id = v_tie;
    BEGIN
        c := 't2';
        CALL core.sp_inventory_manage('Transfer', c_tenant, c_school, c_user,
             p_item_id => v_tie, p_location_id => v_lab, p_to_location_id => v_main,
             p_quantity => 10.01, p_remarks => 'too many', p_result => c);
        PERFORM pg_temp.chk('TRF-02 more than the source holds refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('TRF-02 more than the source holds refused',
                            SQLERRM ~* 'Only 10(.00)? Piece of ZZL Tie left at ZZL Science Lab.*', SQLERRM);
    END;
    PERFORM pg_temp.chk('TRF-02b ...nothing written',
                        (SELECT COUNT(*) FROM core.inventory_stock_ledger WHERE item_id = v_tie) = v_n
                        AND pg_temp.at(v_tie, v_lab) = 10, '');
    BEGIN
        c := 't3';
        CALL core.sp_inventory_manage('Transfer', c_tenant, c_school, c_user,
             p_item_id => v_tie, p_location_id => v_lab, p_to_location_id => v_lab,
             p_quantity => 1, p_remarks => 'same', p_result => c);
        PERFORM pg_temp.chk('TRF-03 same location refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('TRF-03 same location refused', SQLERRM ILIKE '%two different locations%', SQLERRM);
    END;

    -- An Inactive item with stock.
    c := 't4';
    CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
         p_item_name => 'ZZL Old Blazer', p_opening_stock => 3, p_result => c);
    FETCH c INTO k_ok, k_msg, v_off;
    c := 't4b';
    CALL core.sp_inventory_manage('SaveItem', c_tenant, c_school, c_user,
         p_item_id => v_off, p_item_name => 'ZZL Old Blazer', p_is_active => FALSE, p_result => c);
    BEGIN
        c := 't4c';
        CALL core.sp_inventory_manage('Transfer', c_tenant, c_school, c_user,
             p_item_id => v_off, p_location_id => v_main, p_to_location_id => v_lab,
             p_quantity => 1, p_remarks => 'move', p_result => c);
        PERFORM pg_temp.chk('TRF-04 inactive item refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('TRF-04 inactive item refused', SQLERRM ILIKE '%Inactive%', SQLERRM);
    END;
    BEGIN
        c := 't5';
        CALL core.sp_inventory_manage('Transfer', c_tenant, c_school, c_user,
             p_item_id => v_tie, p_location_id => v_main, p_to_location_id => v_spt,
             p_quantity => 1, p_remarks => 'move', p_result => c);
        PERFORM pg_temp.chk('TRF-05 inactive destination refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('TRF-05 inactive destination refused', SQLERRM ILIKE '%ZZL Sports Store is inactive%', SQLERRM);
    END;
    BEGIN
        c := 't5b';
        CALL core.sp_inventory_manage('Transfer', c_tenant, c_school, c_user,
             p_item_id => v_tie, p_location_id => v_spt, p_to_location_id => v_main,
             p_quantity => 1, p_remarks => 'move', p_result => c);
        PERFORM pg_temp.chk('TRF-05b inactive source refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('TRF-05b inactive source refused', SQLERRM ILIKE '%inactive%', SQLERRM);
    END;
    BEGIN
        c := 't6';
        CALL core.sp_inventory_manage('Transfer', c_tenant, c_school, c_user,
             p_item_id => v_tie, p_location_id => v_main, p_to_location_id => v_lab,
             p_quantity => 1.005, p_remarks => 'move', p_result => c);
        PERFORM pg_temp.chk('TRF-06 three decimals refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('TRF-06 three decimals refused', SQLERRM ILIKE '%2 decimal places%', SQLERRM);
    END;
    BEGIN
        c := 't6b';
        CALL core.sp_inventory_manage('Transfer', c_tenant, c_school, c_user,
             p_item_id => v_tie, p_location_id => v_main, p_to_location_id => v_lab,
             p_quantity => 0, p_remarks => 'move', p_result => c);
        PERFORM pg_temp.chk('TRF-06b zero quantity refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('TRF-06b zero quantity refused', SQLERRM ILIKE '%greater than zero%', SQLERRM);
    END;
    BEGIN
        c := 't7';
        CALL core.sp_inventory_manage('Transfer', c_tenant, c_school, c_user,
             p_item_id => v_tie, p_location_id => v_main, p_to_location_id => v_lab,
             p_quantity => 1, p_remarks => '   ', p_result => c);
        PERFORM pg_temp.chk('TRF-07 blank reason refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('TRF-07 blank reason refused', SQLERRM ILIKE '%reason%', SQLERRM);
    END;
    BEGIN
        c := 't7b';
        CALL core.sp_inventory_manage('Transfer', c_tenant, c_school, c_user,
             p_item_id => v_tie, p_location_id => v_main,
             p_quantity => 1, p_remarks => 'move', p_result => c);
        PERFORM pg_temp.chk('TRF-07b no destination refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('TRF-07b no destination refused', SQLERRM ILIKE '%where the stock is going%', SQLERRM);
    END;
    BEGIN
        c := 't8';
        CALL core.sp_inventory_manage('Transfer', c_tenant, c_school, c_user,
             p_item_id => v_tie, p_location_id => v_main, p_to_location_id => v_olc,
             p_quantity => 1, p_remarks => 'move', p_result => c);
        PERFORM pg_temp.chk('TRF-08 transfer to another school''s location refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('TRF-08 transfer to another school''s location refused',
                            SQLERRM ILIKE '%location not found%', SQLERRM);
    END;
    BEGIN
        c := 't8b';
        CALL core.sp_inventory_manage('Transfer', o_tenant, o_school, c_user,
             p_item_id => v_tie, p_to_location_id => v_olc,
             p_quantity => 1, p_remarks => 'move', p_result => c);
        PERFORM pg_temp.chk('TRF-08b other school transferring our item refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('TRF-08b other school transferring our item refused',
                            SQLERRM ILIKE '%Item not found%', SQLERRM);
    END;
    PERFORM pg_temp.chk('TRF-08c ...our tie untouched (35 / 10)',
                        pg_temp.at(v_tie, v_main) = 35 AND pg_temp.at(v_tie, v_lab) = 10, '');

    c := 't9';
    CALL core.sp_inventory_manage('ListTransfers', c_tenant, c_school, c_user,
         p_item_id => v_tie, p_result => c);
    FETCH c INTO r;
    PERFORM pg_temp.chk('TRF-09 ListTransfers names both locations, qty and who',
                        r.from_location = 'Main Store'
                        AND r.to_location = 'ZZL Science Lab' AND r.quantity = 10
                        AND r.created_by_name <> '',
                        format('%s -> %s, %s, by %s', r.from_location, r.to_location, r.quantity, r.created_by_name));
    c := 't9b';
    CALL core.sp_inventory_manage('ListTransfers', o_tenant, o_school, c_user, p_result => c);
    v_n := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
        IF r.item_id = v_tie THEN v_n := v_n + 1; END IF;
    END LOOP;
    PERFORM pg_temp.chk_eq('TRF-09b other school sees none of our transfers', v_n, 0);

    c := 't10';
    CALL core.sp_inventory_manage('ItemLedger', c_tenant, c_school, c_user,
         p_item_id => v_tie, p_result => c);
    v_n := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
        IF r.movement_type = 'TransferOut' AND r.location_name = 'Main Store'
           AND r.transfer_with = 'ZZL Science Lab' THEN v_n := v_n + 1; END IF;
        IF r.movement_type = 'TransferIn' AND r.location_name = 'ZZL Science Lab'
           AND r.location_balance = 10 THEN v_n := v_n + 1; END IF;
    END LOOP;
    PERFORM pg_temp.chk_eq('TRF-10 history shows location, the other side and the location balance', v_n, 2);
    PERFORM pg_temp.chk_eq('TRF-11 balances stay running sums (item and location)', pg_temp.bad_balances(c_tenant, c_school), 0);

    -- ItemStock: one row per active location.
    c := 't12';
    CALL core.sp_inventory_manage('ItemStock', c_tenant, c_school, c_user,
         p_item_id => v_tie, p_result => c);
    v_dec := 0; v_n := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
        v_n := v_n + 1; v_dec := v_dec + r.quantity;
        IF r.location_id = v_spt THEN v_n := v_n + 100; END IF;   -- inactive and empty: hidden
    END LOOP;
    PERFORM pg_temp.chk('TRF-12 ItemStock: active locations only, adds up to the total (45)',
                        v_dec = 45 AND v_n < 100, format('%s rows, sum %s', v_n, v_dec));

    -- Deactivating a location that holds stock is refused; empty it, then it works.
    BEGIN
        c := 't13';
        CALL core.sp_inventory_manage('SetLocationActive', c_tenant, c_school, c_user,
             p_location_id => v_lab, p_is_active => FALSE, p_result => c);
        PERFORM pg_temp.chk('LOC-08 deactivating a location that holds stock refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('LOC-08 deactivating a location that holds stock refused',
                            SQLERRM ILIKE '%still holds stock%', SQLERRM);
    END;
    c := 't13b';
    CALL core.sp_inventory_manage('SetLocationActive', c_tenant, c_school, c_user,
         p_location_id => v_spt, p_is_active => TRUE, p_result => c);
    PERFORM pg_temp.chk('LOC-08b an inactive location can be re-activated',
                        (SELECT is_active FROM core.inventory_locations WHERE location_id = v_spt), '');

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- P. Purchases into a location -----------------------';

    c := 'p0';
    CALL core.sp_inventory_manage('SaveSupplier', c_tenant, c_school, c_user,
         p_supplier_name => 'ZZL Sports Mart', p_mobile => '9876500001',
         p_gstin => '27aaaaa0000a1z5', p_result => c);
    FETCH c INTO k_ok, k_msg, v_sup;
    c := 'p0b';
    CALL core.sp_inventory_manage('SaveSupplier', c_tenant, c_school, c_user,
         p_supplier_name => 'ZZL Paper House', p_result => c);
    FETCH c INTO k_ok, k_msg, v_sp2;

    -- Bill 1 into the lab: tie 20 @ 40 + 5%, ball 10 @ 100, tie again 5 @ 40.
    c := 'p1'; c2 := 'p1b';
    CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
         p_supplier_id => v_sup, p_purchase_date => CURRENT_DATE, p_invoice_no => 'ZZL-B-1',
         p_location_id => v_lab,
         p_items => jsonb_build_array(
             jsonb_build_object('itemId', v_tie, 'quantity', 20, 'unitPrice', 40, 'taxPercent', 5),
             jsonb_build_object('itemId', v_bal, 'quantity', 10, 'unitPrice', 100, 'taxPercent', 0),
             jsonb_build_object('itemId', v_tie, 'quantity', 5,  'unitPrice', 40, 'taxPercent', 5)),
         p_result => c, p_result2 => c2);
    FETCH c INTO k_ok, k_msg, v_pid, v_dec;
    SELECT MIN(purchase_item_id), MAX(purchase_item_id) INTO v_l1, v_l3
      FROM core.inventory_purchase_items WHERE purchase_id = v_pid;
    SELECT purchase_item_id INTO v_l2 FROM core.inventory_purchase_items
     WHERE purchase_id = v_pid AND item_id = v_bal;
    PERFORM pg_temp.chk('PUL-01 bill saved into the lab: tie 10+25 = 35 there, ball 10+10 = 20',
                        pg_temp.at(v_tie, v_lab) = 35 AND pg_temp.at(v_bal, v_lab) = 20
                        AND pg_temp.at(v_tie, v_main) = 35
                        AND (SELECT location_id FROM core.inventory_purchases WHERE purchase_id = v_pid) = v_lab,
                        format('tie@lab=%s ball@lab=%s', pg_temp.at(v_tie, v_lab), pg_temp.at(v_bal, v_lab)));
    SELECT COUNT(*) INTO v_n FROM core.inventory_stock_ledger
     WHERE reference_type = 'Purchase' AND reference_id = v_pid AND location_id = v_lab;
    PERFORM pg_temp.chk_eq('PUL-01b one Purchase movement per line, at the lab', v_n, 3);

    BEGIN
        c := 'p2'; c2 := 'p2b';
        CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
             p_purchase_date => CURRENT_DATE, p_location_id => v_olc,
             p_items => jsonb_build_array(jsonb_build_object('itemId', v_tie, 'quantity', 1, 'unitPrice', 1)),
             p_result => c, p_result2 => c2);
        PERFORM pg_temp.chk('PUL-02 bill into another school''s location refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('PUL-02 bill into another school''s location refused',
                            SQLERRM ILIKE '%location not found%', SQLERRM);
    END;

    -- Inactive supplier: no new bill. Active again: fine.
    c := 'p3';
    CALL core.sp_inventory_manage('SetSupplierActive', c_tenant, c_school, c_user,
         p_supplier_id => v_sp2, p_is_active => FALSE, p_result => c);
    BEGIN
        c := 'p3b'; c2 := 'p3c';
        CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
             p_supplier_id => v_sp2, p_purchase_date => CURRENT_DATE, p_invoice_no => 'ZZL-P-1',
             p_items => jsonb_build_array(jsonb_build_object('itemId', v_tie, 'quantity', 1, 'unitPrice', 1)),
             p_result => c, p_result2 => c2);
        PERFORM pg_temp.chk('PUL-03 inactive supplier cannot take a new bill', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('PUL-03 inactive supplier cannot take a new bill',
                            SQLERRM ILIKE '%ZZL Paper House is inactive%', SQLERRM);
    END;
    c := 'p3d';
    CALL core.sp_inventory_manage('SetSupplierActive', c_tenant, c_school, c_user,
         p_supplier_id => v_sp2, p_is_active => TRUE, p_result => c);
    c := 'p3e'; c2 := 'p3f';
    CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
         p_supplier_id => v_sp2, p_purchase_date => CURRENT_DATE, p_invoice_no => 'ZZL-P-1',
         p_items => jsonb_build_array(jsonb_build_object('itemId', v_tie, 'quantity', 2, 'unitPrice', 30)),
         p_result => c, p_result2 => c2);
    FETCH c INTO k_ok, k_msg, v_p2;
    PERFORM pg_temp.chk('PUL-03b ...re-activated, it can (no location -> Main Store, 35+2)',
                        v_p2 IS NOT NULL AND pg_temp.at(v_tie, v_main) = 37, format('bill %s', v_p2));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- R. Return to supplier -------------------------------';

    -- Return 5 of the first tie line: 5 x 40 = 200 + 5% = 210.
    c := 'r1'; c2 := 'r1b';
    CALL core.sp_inventory_purchase_manage('Return', c_tenant, c_school, c_user,
         p_purchase_id => v_pid, p_remarks => '  torn packing ',
         p_items => jsonb_build_array(jsonb_build_object('purchaseItemId', v_l1, 'quantity', 5)),
         p_result => c, p_result2 => c2);
    FETCH c INTO k_ok, k_msg, v_n, v_dec;
    PERFORM pg_temp.chk('RET-01 return 5 ties: lab 35 -> 30, worth 210',
                        pg_temp.at(v_tie, v_lab) = 30 AND v_dec = 210, format('%s', k_msg));
    SELECT * INTO r FROM core.inventory_purchase_returns WHERE purchase_id = v_pid;
    PERFORM pg_temp.chk('RET-01b return row: line, item, lab, qty, rate, tax, amount, trimmed reason, who',
                        r.purchase_item_id = v_l1 AND r.item_id = v_tie AND r.location_id = v_lab
                        AND r.quantity = 5 AND r.unit_price = 40 AND r.tax_percent = 5 AND r.amount = 210
                        AND r.reason = 'torn packing' AND r.created_by = c_user, '');
    PERFORM pg_temp.chk('RET-01c SupplierReturn movement -5 at the lab, linked to bill and line',
                        EXISTS (SELECT 1 FROM core.inventory_stock_ledger
                                WHERE movement_type = 'SupplierReturn' AND quantity = -5
                                  AND location_id = v_lab AND reference_type = 'Purchase'
                                  AND reference_id = v_pid AND purchase_item_id = v_l1
                                  AND unit_rate = 40 AND remarks = 'torn packing'), '');

    BEGIN
        c := 'r2'; c2 := 'r2b';
        CALL core.sp_inventory_purchase_manage('Return', c_tenant, c_school, c_user,
             p_purchase_id => v_pid, p_remarks => 'more',
             p_items => jsonb_build_array(jsonb_build_object('purchaseItemId', v_l1, 'quantity', 15.01)),
             p_result => c, p_result2 => c2);
        PERFORM pg_temp.chk('RET-02 more than bought minus returned refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('RET-02 more than bought minus returned refused',
                            SQLERRM ~* 'Only 15(.00)? Piece of ZZL Tie can still be returned.*bought 20(.00)?, already returned 5(.00)?.*', SQLERRM);
    END;
    BEGIN
        c := 'r3'; c2 := 'r3b';
        CALL core.sp_inventory_purchase_manage('Return', c_tenant, c_school, c_user,
             p_purchase_id => v_pid, p_remarks => 'split',
             p_items => jsonb_build_array(jsonb_build_object('purchaseItemId', v_l1, 'quantity', 10),
                                          jsonb_build_object('purchaseItemId', v_l1, 'quantity', 6)),
             p_result => c, p_result2 => c2);
        PERFORM pg_temp.chk('RET-03 the same line twice in one request adds up (16 > 15) refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('RET-03 the same line twice in one request adds up (16 > 15) refused',
                            SQLERRM ~* 'Only 15(.00)?.*', SQLERRM);
    END;
    BEGIN
        c := 'r4'; c2 := 'r4b';
        CALL core.sp_inventory_purchase_manage('Return', c_tenant, c_school, c_user,
             p_purchase_id => v_pid, p_remarks => '  ',
             p_items => jsonb_build_array(jsonb_build_object('purchaseItemId', v_l1, 'quantity', 1)),
             p_result => c, p_result2 => c2);
        PERFORM pg_temp.chk('RET-04 blank reason refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('RET-04 blank reason refused', SQLERRM ILIKE '%reason%', SQLERRM);
    END;
    BEGIN
        c := 'r5'; c2 := 'r5b';
        CALL core.sp_inventory_purchase_manage('Return', c_tenant, c_school, c_user,
             p_purchase_id => v_p2, p_remarks => 'wrong bill',
             p_items => jsonb_build_array(jsonb_build_object('purchaseItemId', v_l1, 'quantity', 1)),
             p_result => c, p_result2 => c2);
        PERFORM pg_temp.chk('RET-05 a line from another bill refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('RET-05 a line from another bill refused', SQLERRM ILIKE '%not on this bill%', SQLERRM);
    END;
    BEGIN
        c := 'r6'; c2 := 'r6b';
        CALL core.sp_inventory_purchase_manage('Return', c_tenant, c_school, c_user,
             p_purchase_id => v_pid, p_remarks => 'decimals',
             p_items => jsonb_build_array(jsonb_build_object('purchaseItemId', v_l1, 'quantity', 1.005)),
             p_result => c, p_result2 => c2);
        PERFORM pg_temp.chk('RET-06 three decimals refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('RET-06 three decimals refused', SQLERRM ILIKE '%2 decimal places%', SQLERRM);
    END;
    BEGIN
        c := 'r6c'; c2 := 'r6d';
        CALL core.sp_inventory_purchase_manage('Return', c_tenant, c_school, c_user,
             p_purchase_id => v_pid, p_remarks => 'zero',
             p_items => jsonb_build_array(jsonb_build_object('purchaseItemId', v_l1, 'quantity', 0)),
             p_result => c, p_result2 => c2);
        PERFORM pg_temp.chk('RET-06b zero quantity refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('RET-06b zero quantity refused', SQLERRM ILIKE '%greater than zero%', SQLERRM);
    END;

    -- Move 18 balls out of the lab (20 -> 2): returning 3 balls would drive the
    -- lab below zero even though the bill still allows 10.
    c := 'r7';
    CALL core.sp_inventory_manage('Transfer', c_tenant, c_school, c_user,
         p_item_id => v_bal, p_location_id => v_lab, p_to_location_id => v_spt,
         p_quantity => 18, p_remarks => 'sports day', p_result => c);
    BEGIN
        c := 'r7b'; c2 := 'r7c';
        CALL core.sp_inventory_purchase_manage('Return', c_tenant, c_school, c_user,
             p_purchase_id => v_pid, p_remarks => 'damaged',
             p_items => jsonb_build_array(jsonb_build_object('purchaseItemId', v_l2, 'quantity', 3)),
             p_result => c, p_result2 => c2);
        PERFORM pg_temp.chk('RET-07 cannot drive the bill''s location below zero', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('RET-07 cannot drive the bill''s location below zero',
                            SQLERRM ~* 'Cannot return: only 2(.00)? Piece of ZZL Ball left at ZZL Science Lab.*', SQLERRM);
    END;
    -- Two tie lines in one request must fit the lab's ties together: lab has
    -- 30, returning 15 + 5 = 20 is fine and is checked per item.
    c := 'r7d'; c2 := 'r7e';
    CALL core.sp_inventory_purchase_manage('Return', c_tenant, c_school, c_user,
         p_purchase_id => v_pid, p_remarks => 'wrong colour',
         p_items => jsonb_build_array(jsonb_build_object('purchaseItemId', v_l3, 'quantity', 2),
                                      jsonb_build_object('purchaseItemId', v_l2, 'quantity', 2)),
         p_result => c, p_result2 => c2);
    PERFORM pg_temp.chk('RET-07b a two-line return (tie 2, ball 2): lab tie 28, ball 0',
                        pg_temp.at(v_tie, v_lab) = 28 AND pg_temp.at(v_bal, v_lab) = 0,
                        format('tie=%s ball=%s', pg_temp.at(v_tie, v_lab), pg_temp.at(v_bal, v_lab)));

    BEGIN
        c := 'r8'; c2 := 'r8b';
        CALL core.sp_inventory_purchase_manage('Return', o_tenant, o_school, c_user,
             p_purchase_id => v_pid, p_remarks => 'foreign',
             p_items => jsonb_build_array(jsonb_build_object('purchaseItemId', v_l1, 'quantity', 1)),
             p_result => c, p_result2 => c2);
        PERFORM pg_temp.chk('RET-08 other school returning our bill refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('RET-08 other school returning our bill refused', SQLERRM ILIKE '%Purchase not found%', SQLERRM);
    END;

    -- Get: lines carry what went back; header carries the total returned.
    c := 'r9'; c2 := 'r9b';
    CALL core.sp_inventory_purchase_manage('Get', c_tenant, c_school, c_user,
         p_purchase_id => v_pid, p_result => c, p_result2 => c2);
    FETCH c INTO r;
    -- returned: tie 5 (210) + tie 2 (84) + ball 2 (200) = 494
    PERFORM pg_temp.chk('RET-09 Get header: location, who/when, returned amount 494',
                        r.location_name = 'ZZL Science Lab' AND r.created_by_name <> '' AND r.created_at <> ''
                        AND r.returned_amount = 494 AND NOT r.is_cancelled,
                        format('%s / %s / %s', r.location_name, r.created_by_name, r.returned_amount));
    v_n := 0;
    LOOP FETCH c2 INTO r; EXIT WHEN NOT FOUND;
        IF r.purchase_item_id = v_l1 AND r.returned_qty = 5 AND r.returned_amount = 210 THEN v_n := v_n + 1; END IF;
        IF r.purchase_item_id = v_l2 AND r.returned_qty = 2 AND r.returned_amount = 200 THEN v_n := v_n + 1; END IF;
        IF r.purchase_item_id = v_l3 AND r.returned_qty = 2 AND r.returned_amount = 84  THEN v_n := v_n + 1; END IF;
    END LOOP;
    PERFORM pg_temp.chk_eq('RET-09b Get lines: returned qty and amount per line', v_n, 3);

    c := 'r9c'; c2 := 'r9d';
    CALL core.sp_inventory_purchase_manage('Returns', c_tenant, c_school, c_user,
         p_purchase_id => v_pid, p_result => c, p_result2 => c2);
    v_n := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
        IF r.reason <> '' AND r.created_by_name <> '' AND r.location_name = 'ZZL Science Lab' THEN v_n := v_n + 1; END IF;
    END LOOP;
    PERFORM pg_temp.chk_eq('RET-09c Returns lists all 3, with reason, who and location', v_n, 3);
    c := 'r9e'; c2 := 'r9f';
    CALL core.sp_inventory_purchase_manage('Returns', o_tenant, o_school, c_user,
         p_purchase_id => v_pid, p_result => c, p_result2 => c2);
    FETCH c INTO r;
    PERFORM pg_temp.chk('RET-09d other school reads none of our returns', NOT FOUND, '');

    c := 'r10'; c2 := 'r10b';
    CALL core.sp_inventory_purchase_manage('List', c_tenant, c_school, c_user,
         p_result => c, p_result2 => c2);
    v_n := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
        IF r.purchase_id = v_pid AND r.returned_qty = 9 AND r.returned_amount = 494
           AND r.location_name = 'ZZL Science Lab' THEN v_n := 1; END IF;
    END LOOP;
    PERFORM pg_temp.chk_eq('RET-10 List shows returned qty (9), amount and location', v_n, 1);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- C. Cancel a bill with returns -----------------------';

    -- Remainder on bill 1: tie line1 15, ball 8, tie line3 3 => tie 18, ball 8.
    -- The lab holds tie 28 but ball 0: the cancel must be refused whole.
    SELECT COUNT(*) INTO v_n FROM core.inventory_stock_ledger WHERE reference_id = v_pid AND movement_type = 'PurchaseCancel';
    BEGIN
        c := 'c1'; c2 := 'c1b';
        CALL core.sp_inventory_purchase_manage('Cancel', c_tenant, c_school, c_user,
             p_purchase_id => v_pid, p_remarks => 'duplicate', p_result => c, p_result2 => c2);
        PERFORM pg_temp.chk('CWR-01 cancel refused when the remainder is no longer at the location', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CWR-01 cancel refused when the remainder is no longer at the location',
                            SQLERRM ~* 'Cannot cancel: only 0(.00)? Piece of ZZL Ball left, and this purchase brought in 8(.00)? to ZZL Science Lab.*', SQLERRM);
    END;
    PERFORM pg_temp.chk('CWR-01b ...nothing reversed, bill still live',
                        (SELECT COUNT(*) FROM core.inventory_stock_ledger WHERE reference_id = v_pid
                           AND movement_type = 'PurchaseCancel') = v_n
                        AND NOT (SELECT is_cancelled FROM core.inventory_purchases WHERE purchase_id = v_pid), '');

    -- Bring the balls back to the lab, then cancel: only the remainder goes.
    c := 'c2';
    CALL core.sp_inventory_manage('Transfer', c_tenant, c_school, c_user,
         p_item_id => v_bal, p_location_id => v_spt, p_to_location_id => v_lab,
         p_quantity => 18, p_remarks => 'back after sports day', p_result => c);
    c := 'c2b'; c2 := 'c2c';
    CALL core.sp_inventory_purchase_manage('Cancel', c_tenant, c_school, c_user,
         p_purchase_id => v_pid, p_remarks => 'duplicate bill', p_result => c, p_result2 => c2);
    FETCH c INTO k_ok, k_msg;
    PERFORM pg_temp.chk('CWR-02 cancel with returns reverses only the remainder (tie 28-18 = 10, ball 18-8 = 10)',
                        pg_temp.at(v_tie, v_lab) = 10 AND pg_temp.at(v_bal, v_lab) = 10,
                        format('tie=%s ball=%s; %s', pg_temp.at(v_tie, v_lab), pg_temp.at(v_bal, v_lab), k_msg));
    SELECT COUNT(*) INTO v_n FROM (
        SELECT purchase_item_id, SUM(quantity) AS net FROM core.inventory_stock_ledger
         WHERE reference_type = 'Purchase' AND reference_id = v_pid
         GROUP BY purchase_item_id) x
     WHERE x.purchase_item_id IS NOT NULL AND x.net <> 0;
    PERFORM pg_temp.chk('CWR-02b per line: Return + Cancel rows net out the returned/remaining part',
                        v_n = 0 AND (SELECT SUM(quantity) FROM core.inventory_stock_ledger
                                      WHERE reference_type = 'Purchase' AND reference_id = v_pid) = 0,
                        format('%s line(s) not netting to zero', v_n));
    PERFORM pg_temp.chk('CWR-02c cancel rows are at the lab, carry the reason and the line',
                        NOT EXISTS (SELECT 1 FROM core.inventory_stock_ledger WHERE reference_id = v_pid
                                    AND movement_type = 'PurchaseCancel'
                                    AND (location_id <> v_lab OR remarks <> 'duplicate bill' OR purchase_item_id IS NULL))
                        AND k_msg ILIKE '%already returned%', k_msg);

    BEGIN
        c := 'c3'; c2 := 'c3b';
        CALL core.sp_inventory_purchase_manage('Return', c_tenant, c_school, c_user,
             p_purchase_id => v_pid, p_remarks => 'late',
             p_items => jsonb_build_array(jsonb_build_object('purchaseItemId', v_l1, 'quantity', 1)),
             p_result => c, p_result2 => c2);
        PERFORM pg_temp.chk('CWR-03 return after cancel refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CWR-03 return after cancel refused', SQLERRM ILIKE '%cancelled%', SQLERRM);
    END;

    -- A bill fully returned can still be cancelled; it then moves no stock.
    DECLARE v_p3 integer; v_pl integer; v_cnt integer;
    BEGIN
        c := 'c4'; c2 := 'c4b';
        CALL core.sp_inventory_purchase_manage('Save', c_tenant, c_school, c_user,
             p_purchase_date => CURRENT_DATE, p_invoice_no => 'ZZL-FULL-1',
             p_items => jsonb_build_array(jsonb_build_object('itemId', v_tie, 'quantity', 4, 'unitPrice', 40)),
             p_result => c, p_result2 => c2);
        FETCH c INTO k_ok, k_msg, v_p3;
        SELECT purchase_item_id INTO v_pl FROM core.inventory_purchase_items WHERE purchase_id = v_p3;
        c := 'c4c'; c2 := 'c4d';
        CALL core.sp_inventory_purchase_manage('Return', c_tenant, c_school, c_user,
             p_purchase_id => v_p3, p_remarks => 'all wrong',
             p_items => jsonb_build_array(jsonb_build_object('purchaseItemId', v_pl, 'quantity', 4)),
             p_result => c, p_result2 => c2);
        SELECT COUNT(*) INTO v_cnt FROM core.inventory_stock_ledger WHERE item_id = v_tie;
        c := 'c4e'; c2 := 'c4f';
        CALL core.sp_inventory_purchase_manage('Cancel', c_tenant, c_school, c_user,
             p_purchase_id => v_p3, p_remarks => 'void', p_result => c, p_result2 => c2);
        PERFORM pg_temp.chk('CWR-04 a fully returned bill cancels with no stock movement',
                            (SELECT is_cancelled FROM core.inventory_purchases WHERE purchase_id = v_p3)
                            AND (SELECT COUNT(*) FROM core.inventory_stock_ledger WHERE item_id = v_tie) = v_cnt, '');
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- S. Supplier screen ----------------------------------';

    BEGIN
        c := 's1';
        CALL core.sp_inventory_manage('SaveSupplier', c_tenant, c_school, c_user,
             p_supplier_name => 'ZZL Bad Mail', p_email => 'not-an-email', p_result => c);
        PERFORM pg_temp.chk('SUL-01 invalid email refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('SUL-01 invalid email refused', SQLERRM ILIKE '%valid email%', SQLERRM);
    END;
    BEGIN
        c := 's1b';
        CALL core.sp_inventory_manage('SaveSupplier', c_tenant, c_school, c_user,
             p_supplier_name => 'ZZL Bad GST', p_gstin => '27ABC', p_result => c);
        PERFORM pg_temp.chk('SUL-01b GSTIN that is not 15 characters refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('SUL-01b GSTIN that is not 15 characters refused', SQLERRM ILIKE '%GSTIN%', SQLERRM);
    END;
    PERFORM pg_temp.chk('SUL-01c GSTIN stored in capitals',
                        (SELECT gstin FROM core.inventory_suppliers WHERE supplier_id = v_sup) = '27AAAAA0000A1Z5', '');

    c := 's2';
    CALL core.sp_inventory_manage('SetSupplierActive', c_tenant, c_school, c_user,
         p_supplier_id => v_sp2, p_is_active => FALSE, p_result => c);
    c := 's2b';
    CALL core.sp_inventory_manage('ListSuppliers', c_tenant, c_school, c_user, p_result => c);
    v_n := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
        IF r.supplier_id = v_sp2 AND NOT r.is_active THEN v_n := v_n + 1; END IF;
    END LOOP;
    PERFORM pg_temp.chk_eq('SUL-02 an inactive supplier is still listed, marked inactive', v_n, 1);
    c := 's2c';
    CALL core.sp_inventory_manage('ListSuppliers', c_tenant, c_school, c_user,
         p_filter_status => 'Active', p_result => c);
    v_n := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
        IF r.supplier_id = v_sp2 THEN v_n := v_n + 10; END IF;
        IF r.supplier_id = v_sup THEN v_n := v_n + 1; END IF;
    END LOOP;
    PERFORM pg_temp.chk_eq('SUL-02b filter Active excludes it, keeps the active one', v_n, 1);

    c := 's3';
    CALL core.sp_inventory_manage('ListSuppliers', c_tenant, c_school, c_user,
         p_search => ' 98765000 ', p_result => c);
    FETCH c INTO r;
    PERFORM pg_temp.chk('SUL-03 search by mobile finds the supplier', r.supplier_id = v_sup, '');
    c := 's3b';
    CALL core.sp_inventory_manage('ListSuppliers', c_tenant, c_school, c_user,
         p_search => 'aaaaa0000', p_result => c);
    FETCH c INTO r;
    PERFORM pg_temp.chk('SUL-03b search by GSTIN, any case', r.supplier_id = v_sup, '');

    -- Sports Mart: bill 1 (cancelled) does not count. Paper House: bill P-1 (60).
    c := 's4';
    CALL core.sp_inventory_manage('ListSuppliers', c_tenant, c_school, c_user, p_result => c);
    v_n := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
        IF r.supplier_id = v_sup AND r.bill_count = 0 AND r.total_billed = 0 THEN v_n := v_n + 1; END IF;
        IF r.supplier_id = v_sp2 AND r.bill_count = 1 AND r.total_billed = 60
           AND r.last_bill_date = to_char(CURRENT_DATE, 'YYYY-MM-DD') THEN v_n := v_n + 1; END IF;
    END LOOP;
    PERFORM pg_temp.chk_eq('SUL-04 bill count / total / last date count live bills only', v_n, 2);

    BEGIN
        c := 's5';
        CALL core.sp_inventory_manage('SetSupplierActive', o_tenant, o_school, c_user,
             p_supplier_id => v_sup, p_is_active => FALSE, p_result => c);
        PERFORM pg_temp.chk('SUL-05 cross-school deactivate refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('SUL-05 cross-school deactivate refused', SQLERRM ILIKE '%not found%', SQLERRM);
    END;

    c := 's6';
    CALL core.sp_inventory_manage('DeleteSupplier', c_tenant, c_school, c_user,
         p_supplier_id => v_sp2, p_result => c);
    PERFORM pg_temp.chk('SUL-06 delete a supplier with bills: soft delete, bill keeps the name',
                        (SELECT is_deleted FROM core.inventory_suppliers WHERE supplier_id = v_sp2)
                        AND (SELECT supplier_name FROM core.inventory_purchases WHERE purchase_id = v_p2) = 'ZZL Paper House', '');

    c := 's7'; c2 := 's7b';
    CALL core.sp_inventory_purchase_manage('List', c_tenant, c_school, c_user,
         p_supplier_id => v_sup, p_result => c, p_result2 => c2);
    v_n := 0; v_dec := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
        v_n := v_n + 1;
        IF r.purchase_id <> v_pid THEN v_dec := v_dec + 1; END IF;
    END LOOP;
    PERFORM pg_temp.chk('SUL-07 purchase List for one supplier returns only its bills',
                        v_n = 1 AND v_dec = 0, format('%s row(s)', v_n));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- I. Invariants ---------------------------------------';

    PERFORM pg_temp.chk_eq('INV-01 every item: current_stock = SUM(locations) = SUM(ledger)',
                           pg_temp.bad_items(c_tenant, c_school), 0);
    PERFORM pg_temp.chk_eq('INV-02 every item/location: stock = SUM(ledger at it)',
                           pg_temp.bad_pairs(c_tenant, c_school), 0);
    PERFORM pg_temp.chk_eq('INV-03 balance_after / location_balance_after are running sums',
                           pg_temp.bad_balances(c_tenant, c_school), 0);

    BEGIN
        UPDATE core.inventory_location_stock SET quantity = -1
         WHERE item_id = v_tie AND location_id = v_lab;
        PERFORM pg_temp.chk('INV-04 location stock below zero refused by the table', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('INV-04 location stock below zero refused by the table',
                            SQLERRM ILIKE '%chk_inv_loc_stock%', SQLERRM);
    END;

    UPDATE core.inventory_location_stock SET quantity = quantity + 7
     WHERE item_id = v_tie AND location_id = v_main;
    c := 'i5';
    CALL core.sp_inventory_manage('Recount', o_tenant, o_school, c_user, p_result => c);
    PERFORM pg_temp.chk_eq('INV-05 other school''s Recount leaves our location stock alone',
                           pg_temp.bad_pairs(c_tenant, c_school), 1);
    c := 'i5b';
    CALL core.sp_inventory_manage('Recount', c_tenant, c_school, c_user, p_result => c);
    PERFORM pg_temp.chk('INV-05b ...our Recount rebuilds it from the ledger',
                        pg_temp.bad_pairs(c_tenant, c_school) = 0 AND pg_temp.bad_items(c_tenant, c_school) = 0, '');

    SELECT COUNT(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'core' AND (p.proname LIKE 'sp_inventory%' OR p.proname LIKE 'fn_inventory%')
       AND (p.prosrc ~* 'delete\s+from\s+core\.inventory_'
         OR p.prosrc ~* 'update\s+core\.inventory_stock_ledger'
         OR p.prosrc ~* 'update\s+core\.inventory_purchase_items'
         OR p.prosrc ~* 'update\s+core\.inventory_purchase_returns'
         OR p.prosrc ~* 'update\s+core\.inventory_transfers');
    PERFORM pg_temp.chk_eq('INV-06 no proc deletes inventory rows or edits ledger/lines/returns/transfers', v_n, 0);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- K. Cursors and scope --------------------------------';

    -- The app FETCHes BOTH cursors after every purchase call.
    BEGIN
        c := 'k1'; c2 := 'k1b';
        CALL core.sp_inventory_purchase_manage('List', c_tenant, c_school, c_user, p_result => c, p_result2 => c2);
        FETCH c2 INTO r;
        c := 'k1c'; c2 := 'k1d';
        CALL core.sp_inventory_purchase_manage('Cancel', c_tenant, c_school, c_user,
             p_purchase_id => v_p2, p_remarks => 'cursor check', p_result => c, p_result2 => c2);
        FETCH c2 INTO r;
        PERFORM pg_temp.chk('CUR-01 List and Cancel open the second cursor too', TRUE, '');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('CUR-01 List and Cancel open the second cursor too', FALSE, SQLERRM);
    END;

    BEGIN
        c := 'k2';
        CALL core.sp_inventory_manage('ListLocations', 1, 0, c_user, p_result => c);
        PERFORM pg_temp.chk('TEN-L1 platform scope ListLocations refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('TEN-L1 platform scope ListLocations refused', SQLERRM ILIKE '%scope%', SQLERRM);
    END;

    c := 'k3';
    CALL core.sp_inventory_manage('ItemStock', o_tenant, o_school, c_user, p_item_id => v_tie, p_result => c);
    FETCH c INTO r;
    PERFORM pg_temp.chk('TEN-L2 other school''s ItemStock for our item: 0 rows', NOT FOUND, '');

    SELECT (SELECT COUNT(*) FROM core.inventory_location_stock s
              JOIN core.inventory_items i USING (item_id)
              JOIN core.inventory_locations l ON l.location_id = s.location_id
             WHERE s.tenant_id <> i.tenant_id OR s.school_id <> i.school_id
                OR l.tenant_id <> i.tenant_id OR l.school_id <> i.school_id)
         + (SELECT COUNT(*) FROM core.inventory_stock_ledger g
              JOIN core.inventory_locations l ON l.location_id = g.location_id
             WHERE g.tenant_id <> l.tenant_id OR g.school_id <> l.school_id)
         + (SELECT COUNT(*) FROM core.inventory_transfers t
              JOIN core.inventory_items i USING (item_id)
              JOIN core.inventory_locations lf ON lf.location_id = t.from_location_id
              JOIN core.inventory_locations lt ON lt.location_id = t.to_location_id
             WHERE t.school_id <> i.school_id OR lf.school_id <> i.school_id OR lt.school_id <> i.school_id)
         + (SELECT COUNT(*) FROM core.inventory_purchase_returns x
              JOIN core.inventory_purchases p USING (purchase_id)
              JOIN core.inventory_locations l ON l.location_id = x.location_id
             WHERE x.tenant_id <> p.tenant_id OR x.school_id <> p.school_id OR l.school_id <> p.school_id)
         + (SELECT COUNT(*) FROM core.inventory_purchases p
              JOIN core.inventory_locations l ON l.location_id = p.location_id
             WHERE l.tenant_id <> p.tenant_id OR l.school_id <> p.school_id)
      INTO v_n;
    PERFORM pg_temp.chk_eq('TEN-L3 every location reference stays inside its own school', v_n, 0);
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
            RAISE NOTICE '   %  %', rpad(r.name, 58), r.detail;
        END LOOP;
    END IF;
    RAISE NOTICE '';
END
$sum$;

ROLLBACK;
