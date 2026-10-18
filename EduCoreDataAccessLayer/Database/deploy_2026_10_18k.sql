-- Bundle 2026-10-18k: inventory item list shows opening stock (no bill) apart. Run with:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_18k.sql
-- Sources: inventory.sql (sp_inventory_manage only)

-- Drop every earlier signature first. CREATE OR REPLACE cannot change a
-- parameter list, so adding one leaves the old overload behind and every call
-- then fails with "is not unique" — the same trap as the two
-- sp_fee_payment_collect revisions.
DO $drop$
DECLARE r record;
BEGIN
    FOR r IN SELECT p.oid::regprocedure AS sig FROM pg_proc p
             JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'core' AND p.proname = 'sp_inventory_manage'
    LOOP
        EXECUTE 'DROP PROCEDURE ' || r.sig;
    END LOOP;
END $drop$;

CREATE OR REPLACE PROCEDURE core.sp_inventory_manage(
    IN  p_operation      text,
    IN  p_tenant_id      integer,
    IN  p_school_id      integer,
    IN  p_action_user_id integer,
    IN  p_item_id        integer DEFAULT NULL,
    IN  p_item_name      text    DEFAULT NULL,
    IN  p_sku            text    DEFAULT NULL,
    IN  p_category       text    DEFAULT NULL,
    IN  p_sub_category   text    DEFAULT NULL,
    IN  p_item_type      text    DEFAULT NULL,
    IN  p_unit_type      text    DEFAULT NULL,
    IN  p_opening_stock  numeric DEFAULT 0,
    IN  p_min_stock      numeric DEFAULT 0,
    IN  p_cost_price     numeric DEFAULT 0,
    IN  p_selling_price  numeric DEFAULT 0,
    IN  p_brand          text    DEFAULT NULL,
    IN  p_model          text    DEFAULT NULL,
    IN  p_description    text    DEFAULT NULL,
    IN  p_is_active      boolean DEFAULT NULL,
    IN  p_supplier_id    integer DEFAULT NULL,
    IN  p_supplier_name  text    DEFAULT NULL,
    IN  p_contact_person text    DEFAULT NULL,
    IN  p_mobile         text    DEFAULT NULL,
    IN  p_email          text    DEFAULT NULL,
    IN  p_address        text    DEFAULT NULL,
    IN  p_gstin          text    DEFAULT NULL,
    IN  p_movement_type  text    DEFAULT NULL,
    IN  p_quantity       numeric DEFAULT NULL,
    IN  p_issued_to      text    DEFAULT NULL,
    IN  p_remarks        text    DEFAULT NULL,
    IN  p_search         text    DEFAULT NULL,
    IN  p_filter_status  text    DEFAULT NULL,
    IN  p_location_id    integer DEFAULT NULL,   -- where it happens / "from" for a transfer
    IN  p_to_location_id integer DEFAULT NULL,   -- transfer destination
    IN  p_location_name  text    DEFAULT NULL,
    INOUT p_result       refcursor DEFAULT 'inventory_cursor'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_op      text := UPPER(COALESCE(p_operation, ''));
    v_type    text := TRIM(COALESCE(p_movement_type, ''));
    v_reason  text := NULLIF(TRIM(COALESCE(p_remarks, '')), '');
    v_id      integer;
    v_name    text;
    v_stock   numeric;
    v_unit    text;
    v_cost    numeric;
    v_active  boolean;
    v_new     numeric;
    v_qty     numeric;
    v_loc     integer;
    v_lname   text;
    v_lactive boolean;
    v_ldef    boolean;
    v_to      integer;
    v_tname   text;
    v_tactive boolean;
    v_lstock  numeric;
    v_n       integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    -- ── Items ───────────────────────────────────────────────────────────────
    IF v_op = 'LISTITEMS' THEN
        -- With p_location_id the stock columns are the stock AT that location;
        -- without it they are the school-wide total.
        OPEN p_result FOR
        SELECT i.item_id,
               i.item_name,
               COALESCE(i.sku, '')          AS sku,
               COALESCE(i.category, '')     AS category,
               COALESCE(i.sub_category, '') AS sub_category,
               i.item_type,
               i.unit_type,
               x.stock                      AS current_stock,
               i.min_stock,
               i.cost_price,
               i.selling_price,
               COALESCE(i.brand, '')       AS brand,
               COALESCE(i.model, '')       AS model,
               COALESCE(i.description, '') AS description,
               -- What the shelf is worth at the item's cost price (not at what
               -- each purchase actually paid) -- the page labels it that way.
               ROUND(x.stock * i.cost_price, 2) AS stock_value,
               -- Derived, never stored: one number cannot disagree with itself.
               CASE WHEN x.stock <= 0            THEN 'Out of Stock'
                    WHEN x.stock <= i.min_stock  THEN 'Low Stock'
                    ELSE 'Available' END         AS stock_status,
               i.is_active,
               (SELECT COUNT(*) FROM core.inventory_location_stock s
                 WHERE s.item_id = i.item_id AND s.quantity > 0)::int AS locations_held,
               -- Stock entered as "already in school" when the item was made: it
               -- has no supplier and no bill, so the list shows it apart.
               COALESCE((SELECT SUM(l.quantity) FROM core.inventory_stock_ledger l
                          WHERE l.tenant_id = i.tenant_id AND l.school_id = i.school_id
                            AND l.item_id = i.item_id AND l.movement_type = 'Opening'), 0) AS opening_qty
        FROM core.inventory_items i
        CROSS JOIN LATERAL (
            SELECT CASE WHEN p_location_id IS NULL THEN i.current_stock
                        ELSE COALESCE((SELECT s.quantity FROM core.inventory_location_stock s
                                       WHERE s.item_id = i.item_id
                                         AND s.location_id = p_location_id), 0)
                   END AS stock) x
        WHERE i.tenant_id = p_tenant_id AND i.school_id = p_school_id
          AND i.is_deleted = FALSE
          AND (NULLIF(TRIM(COALESCE(p_search, '')), '') IS NULL
               OR i.item_name ILIKE '%' || TRIM(p_search) || '%'
               OR COALESCE(i.sku, '') ILIKE '%' || TRIM(p_search) || '%'
               OR COALESCE(i.category, '') ILIKE '%' || TRIM(p_search) || '%')
          AND (NULLIF(TRIM(COALESCE(p_filter_status, '')), '') IS NULL
               OR CASE WHEN x.stock <= 0           THEN 'Out of Stock'
                       WHEN x.stock <= i.min_stock THEN 'Low Stock'
                       ELSE 'Available' END = TRIM(p_filter_status))
        ORDER BY i.item_name;
        RETURN;

    ELSIF v_op = 'GETITEM' THEN
        OPEN p_result FOR
        SELECT item_id, item_name, COALESCE(sku,'') AS sku,
               COALESCE(category,'') AS category, COALESCE(sub_category,'') AS sub_category,
               item_type, unit_type, current_stock, min_stock,
               cost_price, selling_price,
               COALESCE(brand,'') AS brand, COALESCE(model,'') AS model,
               COALESCE(description,'') AS description, is_active
        FROM core.inventory_items
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND item_id = p_item_id AND is_deleted = FALSE;
        RETURN;

    ELSIF v_op = 'SAVEITEM' THEN
        v_name := NULLIF(TRIM(COALESCE(p_item_name, '')), '');
        IF v_name IS NULL THEN
            RAISE EXCEPTION 'Item name is required.';
        END IF;
        IF COALESCE(p_min_stock, 0) < 0 THEN
            RAISE EXCEPTION 'Minimum stock cannot be negative.';
        END IF;
        IF COALESCE(p_opening_stock, 0) < 0 THEN
            RAISE EXCEPTION 'Opening stock cannot be negative.';
        END IF;
        IF COALESCE(p_cost_price, 0) < 0 OR COALESCE(p_selling_price, 0) < 0 THEN
            RAISE EXCEPTION 'A price cannot be negative.';
        END IF;
        -- Quantities and prices are stored with 2 decimals. Accepting a third
        -- and letting the column round it is how stock drifted from its ledger.
        IF COALESCE(p_opening_stock, 0) <> ROUND(COALESCE(p_opening_stock, 0), 2)
           OR COALESCE(p_min_stock, 0) <> ROUND(COALESCE(p_min_stock, 0), 2) THEN
            RAISE EXCEPTION 'A quantity can have at most 2 decimal places.';
        END IF;
        IF COALESCE(p_cost_price, 0) <> ROUND(COALESCE(p_cost_price, 0), 2)
           OR COALESCE(p_selling_price, 0) <> ROUND(COALESCE(p_selling_price, 0), 2) THEN
            RAISE EXCEPTION 'A price can have at most 2 decimal places.';
        END IF;

        -- Duplicates are caught here so the store keeper reads a sentence, not
        -- the unique index's name. The indexes stay as the last line of defence.
        IF EXISTS (SELECT 1 FROM core.inventory_items
                   WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                     AND is_deleted = FALSE AND item_id <> COALESCE(p_item_id, 0)
                     AND LOWER(TRIM(item_name)) = LOWER(v_name)) THEN
            RAISE EXCEPTION 'An item named "%" already exists.', v_name;
        END IF;
        IF NULLIF(TRIM(COALESCE(p_sku, '')), '') IS NOT NULL
           AND EXISTS (SELECT 1 FROM core.inventory_items
                       WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                         AND is_deleted = FALSE AND item_id <> COALESCE(p_item_id, 0)
                         AND LOWER(TRIM(sku)) = LOWER(TRIM(p_sku))) THEN
            RAISE EXCEPTION 'Another item already uses the code "%".', TRIM(p_sku);
        END IF;

        IF COALESCE(p_item_id, 0) > 0 THEN
            SELECT unit_type INTO v_unit FROM core.inventory_items
            WHERE tenant_id = p_tenant_id AND school_id = p_school_id
              AND item_id = p_item_id AND is_deleted = FALSE;
            IF v_unit IS NULL THEN
                RAISE EXCEPTION 'Item not found.';
            END IF;

            -- Once stock has moved, every past row was counted in this unit.
            -- Changing it would turn "3 Box" into "3 Piece" without a movement.
            IF NULLIF(TRIM(COALESCE(p_unit_type, '')), '') IS NOT NULL
               AND TRIM(p_unit_type) <> v_unit
               AND EXISTS (SELECT 1 FROM core.inventory_stock_ledger WHERE item_id = p_item_id) THEN
                RAISE EXCEPTION 'The unit cannot change once the item has stock history (it is counted in %).', v_unit;
            END IF;

            -- Editing never touches current_stock: stock only moves through the
            -- ledger, or an edit screen becomes a silent way to invent inventory.
            UPDATE core.inventory_items
               SET item_name    = v_name,
                   sku          = NULLIF(TRIM(COALESCE(p_sku, '')), ''),
                   category     = NULLIF(TRIM(COALESCE(p_category, '')), ''),
                   sub_category = NULLIF(TRIM(COALESCE(p_sub_category, '')), ''),
                   item_type    = COALESCE(NULLIF(TRIM(COALESCE(p_item_type,'')),''), item_type),
                   unit_type    = COALESCE(NULLIF(TRIM(COALESCE(p_unit_type,'')),''), unit_type),
                   min_stock    = COALESCE(p_min_stock, 0),
                   cost_price    = COALESCE(p_cost_price, 0),
                   selling_price = COALESCE(p_selling_price, 0),
                   brand        = NULLIF(TRIM(COALESCE(p_brand, '')), ''),
                   model        = NULLIF(TRIM(COALESCE(p_model, '')), ''),
                   description  = NULLIF(TRIM(COALESCE(p_description, '')), ''),
                   is_active    = COALESCE(p_is_active, is_active),
                   updated_by   = p_action_user_id,
                   updated_at   = now()
             WHERE tenant_id = p_tenant_id AND school_id = p_school_id
               AND item_id = p_item_id AND is_deleted = FALSE
             RETURNING item_id INTO v_id;
        ELSE
            -- Opening stock goes into the chosen location, else the default.
            -- Checked before the item is written.
            IF COALESCE(p_opening_stock, 0) > 0 THEN
                v_loc := COALESCE(p_location_id,
                                  core.fn_inventory_default_location(p_tenant_id, p_school_id, p_action_user_id));
                SELECT location_name, is_active INTO v_lname, v_lactive
                FROM core.inventory_locations
                WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND location_id = v_loc
                FOR SHARE;
                IF v_lname IS NULL THEN
                    RAISE EXCEPTION 'Store location not found.';
                END IF;
                IF NOT v_lactive THEN
                    RAISE EXCEPTION '% is inactive. Choose an active location.', v_lname;
                END IF;
            END IF;

            INSERT INTO core.inventory_items
                (tenant_id, school_id, item_name, sku, category, sub_category,
                 item_type, unit_type, current_stock, min_stock,
                 cost_price, selling_price, brand, model, description,
                 is_active, created_by)
            VALUES (p_tenant_id, p_school_id, v_name,
                    NULLIF(TRIM(COALESCE(p_sku, '')), ''),
                    NULLIF(TRIM(COALESCE(p_category, '')), ''),
                    NULLIF(TRIM(COALESCE(p_sub_category, '')), ''),
                    COALESCE(NULLIF(TRIM(COALESCE(p_item_type,'')),''), 'Consumable'),
                    COALESCE(NULLIF(TRIM(COALESCE(p_unit_type,'')),''), 'Piece'),
                    0, COALESCE(p_min_stock, 0),
                    COALESCE(p_cost_price, 0), COALESCE(p_selling_price, 0),
                    NULLIF(TRIM(COALESCE(p_brand, '')), ''),
                    NULLIF(TRIM(COALESCE(p_model, '')), ''),
                    NULLIF(TRIM(COALESCE(p_description, '')), ''),
                    COALESCE(p_is_active, TRUE), p_action_user_id)
            RETURNING item_id INTO v_id;

            -- Opening stock is a movement like any other, so the first number on
            -- the shelf has a date, an author and a location too.
            IF COALESCE(p_opening_stock, 0) > 0 THEN
                PERFORM core.fn_inventory_post_movement(
                    p_tenant_id, p_school_id, p_action_user_id, v_id, v_loc,
                    'Opening', p_opening_stock, COALESCE(p_cost_price, 0),
                    p_remarks => 'Opening stock');
            END IF;
        END IF;

        OPEN p_result FOR SELECT TRUE AS success, 'Item saved.' AS message, v_id AS item_id;
        RETURN;

    ELSIF v_op = 'DELETEITEM' THEN
        SELECT current_stock, item_name INTO v_stock, v_name
        FROM core.inventory_items
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND item_id = p_item_id AND is_deleted = FALSE;

        IF v_name IS NULL THEN
            RAISE EXCEPTION 'Item not found.';
        END IF;
        -- Deleting something still on the shelf loses track of real stock.
        IF v_stock <> 0 THEN
            RAISE EXCEPTION 'Cannot delete %: % still in stock. Issue or adjust it to zero first.',
                v_name, trim_scale(v_stock)::text;
        END IF;

        UPDATE core.inventory_items
           SET is_deleted = TRUE, is_active = FALSE,
               updated_by = p_action_user_id, updated_at = now()
         WHERE item_id = p_item_id;

        OPEN p_result FOR SELECT TRUE AS success, 'Item deleted.' AS message;
        RETURN;

    -- ── Stock movement ──────────────────────────────────────────────────────
    -- Issue / Damage take stock away, Return / Adjustment add it back, and
    -- StockTake records a physical count: p_quantity is the COUNTED figure and
    -- the movement is the difference, up or down. All of it happens AT one
    -- location (p_location_id, else the default), and the stock checked is the
    -- stock at that location.
    ELSIF v_op = 'MOVESTOCK' THEN
        IF v_type NOT IN ('Issue','Return','Damage','Adjustment','StockTake') THEN
            RAISE EXCEPTION 'Choose what kind of stock movement this is.';
        END IF;
        IF v_type = 'StockTake' THEN
            IF p_quantity IS NULL OR p_quantity < 0 THEN
                RAISE EXCEPTION 'Enter the quantity actually counted (0 or more).';
            END IF;
            IF v_reason IS NULL THEN
                RAISE EXCEPTION 'Give a reason for the stock-take difference.';
            END IF;
        ELSIF COALESCE(p_quantity, 0) <= 0 THEN
            RAISE EXCEPTION 'Enter a quantity greater than zero.';
        END IF;
        IF p_quantity <> ROUND(p_quantity, 2) THEN
            RAISE EXCEPTION 'A quantity can have at most 2 decimal places.';
        END IF;

        -- The item row is locked first by every stock writer, so two movements
        -- of one item queue up instead of both reading the same figure.
        SELECT item_name, unit_type, cost_price, is_active
          INTO v_name, v_unit, v_cost, v_active
        FROM core.inventory_items
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND item_id = p_item_id AND is_deleted = FALSE
        FOR UPDATE;

        IF v_name IS NULL THEN
            RAISE EXCEPTION 'Item not found.';
        END IF;
        -- An Inactive item is one the school has stopped handing out. Its old
        -- stock can still be returned, written off or counted.
        IF NOT v_active AND v_type = 'Issue' THEN
            RAISE EXCEPTION '% is marked Inactive and cannot be issued. Make it Active first.', v_name;
        END IF;

        v_loc := COALESCE(p_location_id,
                          core.fn_inventory_default_location(p_tenant_id, p_school_id, p_action_user_id));
        SELECT location_name, is_active INTO v_lname, v_lactive
        FROM core.inventory_locations
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND location_id = v_loc
        FOR SHARE;
        IF v_lname IS NULL THEN
            RAISE EXCEPTION 'Store location not found.';
        END IF;
        IF NOT v_lactive THEN
            RAISE EXCEPTION '% is inactive. Make it active before moving stock there.', v_lname;
        END IF;

        SELECT COALESCE((SELECT quantity FROM core.inventory_location_stock
                         WHERE item_id = p_item_id AND location_id = v_loc), 0)
          INTO v_stock;

        v_qty := CASE WHEN v_type IN ('Issue','Damage') THEN -p_quantity
                      WHEN v_type = 'StockTake'         THEN p_quantity - v_stock
                      ELSE p_quantity END;

        IF v_qty = 0 THEN
            RAISE EXCEPTION 'The count matches the % % on record at %, so there is nothing to adjust.',
                trim_scale(v_stock)::text, v_unit, v_lname;
        END IF;

        IF v_stock + v_qty < 0 THEN
            RAISE EXCEPTION 'Only % % of % left at %.',
                trim_scale(v_stock)::text, v_unit, v_name, v_lname;
        END IF;

        v_new := core.fn_inventory_post_movement(
            p_tenant_id, p_school_id, p_action_user_id, p_item_id, v_loc,
            v_type, v_qty, v_cost,
            p_issued_to => p_issued_to, p_remarks => p_remarks);

        OPEN p_result FOR
            SELECT TRUE AS success, 'Stock updated.' AS message, v_new AS current_stock;
        RETURN;

    -- ── Transfer between locations ──────────────────────────────────────────
    -- p_location_id = from (default location when blank), p_to_location_id = to.
    ELSIF v_op = 'TRANSFER' THEN
        IF COALESCE(p_quantity, 0) <= 0 THEN
            RAISE EXCEPTION 'Enter a quantity greater than zero.';
        END IF;
        IF p_quantity <> ROUND(p_quantity, 2) THEN
            RAISE EXCEPTION 'A quantity can have at most 2 decimal places.';
        END IF;
        IF p_to_location_id IS NULL THEN
            RAISE EXCEPTION 'Choose where the stock is going.';
        END IF;
        IF v_reason IS NULL THEN
            RAISE EXCEPTION 'Give a reason for the transfer.';
        END IF;

        SELECT item_name, unit_type, cost_price, is_active
          INTO v_name, v_unit, v_cost, v_active
        FROM core.inventory_items
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND item_id = p_item_id AND is_deleted = FALSE
        FOR UPDATE;
        IF v_name IS NULL THEN
            RAISE EXCEPTION 'Item not found.';
        END IF;
        IF NOT v_active THEN
            RAISE EXCEPTION '% is marked Inactive and cannot be transferred. Make it Active first.', v_name;
        END IF;

        v_loc := COALESCE(p_location_id,
                          core.fn_inventory_default_location(p_tenant_id, p_school_id, p_action_user_id));
        v_to  := p_to_location_id;
        IF v_loc = v_to THEN
            RAISE EXCEPTION 'Choose two different locations.';
        END IF;

        -- Both locations are read FOR SHARE, so neither can be deactivated
        -- half-way through (deactivating takes FOR UPDATE).
        SELECT location_name, is_active INTO v_lname, v_lactive
        FROM core.inventory_locations
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND location_id = v_loc
        FOR SHARE;
        SELECT location_name, is_active INTO v_tname, v_tactive
        FROM core.inventory_locations
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND location_id = v_to
        FOR SHARE;
        IF v_lname IS NULL OR v_tname IS NULL THEN
            RAISE EXCEPTION 'Store location not found.';
        END IF;
        IF NOT v_lactive THEN
            RAISE EXCEPTION '% is inactive. Make it active before moving stock from it.', v_lname;
        END IF;
        IF NOT v_tactive THEN
            RAISE EXCEPTION '% is inactive. Make it active before moving stock to it.', v_tname;
        END IF;

        SELECT COALESCE((SELECT quantity FROM core.inventory_location_stock
                         WHERE item_id = p_item_id AND location_id = v_loc), 0)
          INTO v_stock;
        IF v_stock < p_quantity THEN
            RAISE EXCEPTION 'Only % % of % left at %.',
                trim_scale(v_stock)::text, v_unit, v_name, v_lname;
        END IF;

        INSERT INTO core.inventory_transfers
            (tenant_id, school_id, item_id, from_location_id, to_location_id,
             quantity, reason, created_by)
        VALUES (p_tenant_id, p_school_id, p_item_id, v_loc, v_to,
                p_quantity, v_reason, p_action_user_id)
        RETURNING transfer_id INTO v_id;

        -- The pair: out of A, into B. The item's total ends where it started.
        PERFORM core.fn_inventory_post_movement(
            p_tenant_id, p_school_id, p_action_user_id, p_item_id, v_loc,
            'TransferOut', -p_quantity, v_cost, 'Transfer', v_id,
            p_remarks => v_reason);
        v_new := core.fn_inventory_post_movement(
            p_tenant_id, p_school_id, p_action_user_id, p_item_id, v_to,
            'TransferIn', p_quantity, v_cost, 'Transfer', v_id,
            p_remarks => v_reason);

        OPEN p_result FOR
            SELECT TRUE AS success,
                   format('Moved %s %s of %s from %s to %s.',
                          trim_scale(p_quantity)::text, v_unit, v_name, v_lname, v_tname) AS message,
                   v_new AS current_stock;
        RETURN;

    ELSIF v_op = 'LISTTRANSFERS' THEN
        -- Newest first; optionally one item, or one location on either side.
        OPEN p_result FOR
        SELECT t.transfer_id, t.transfer_date, t.item_id, i.item_name, i.unit_type,
               t.from_location_id, lf.location_name AS from_location,
               t.to_location_id,   lt.location_name AS to_location,
               t.quantity, t.reason,
               core.fn_inventory_user_name(t.created_by) AS created_by_name,
               to_char(t.created_at, 'YYYY-MM-DD HH24:MI') AS created_at
        FROM core.inventory_transfers t
        JOIN core.inventory_items i      ON i.item_id = t.item_id
        JOIN core.inventory_locations lf ON lf.location_id = t.from_location_id
        JOIN core.inventory_locations lt ON lt.location_id = t.to_location_id
        WHERE t.tenant_id = p_tenant_id AND t.school_id = p_school_id
          AND (p_item_id IS NULL OR t.item_id = p_item_id)
          AND (p_location_id IS NULL OR p_location_id IN (t.from_location_id, t.to_location_id))
        ORDER BY t.transfer_id DESC
        LIMIT 500;
        RETURN;

    ELSIF v_op = 'ITEMLEDGER' THEN
        -- Date order (newest first), then entry order within a day. A back-dated
        -- bill therefore sits on its own date, and `balance` is the running total
        -- in that same order, so the column reads top to bottom without jumps.
        -- balance_after is the figure at the moment the row was entered.
        -- location_balance is the same running figure for the row's location.
        OPEN p_result FOR
        SELECT x.* FROM (
            SELECT l.movement_id, l.movement_date, l.movement_type, l.quantity,
                   SUM(l.quantity) OVER (ORDER BY l.movement_date, l.movement_id) AS balance,
                   l.balance_after,
                   l.location_id,
                   COALESCE(loc.location_name, '') AS location_name,
                   SUM(l.quantity) OVER (PARTITION BY l.location_id
                                         ORDER BY l.movement_date, l.movement_id) AS location_balance,
                   l.location_balance_after,
                   -- For a transfer row: the location on the other side.
                   COALESCE(CASE WHEN l.movement_type = 'TransferOut' THEN lt.location_name
                                 WHEN l.movement_type = 'TransferIn'  THEN lf.location_name END, '') AS transfer_with,
                   l.unit_rate,
                   COALESCE(l.issued_to,'') AS issued_to,
                   COALESCE(l.remarks,'') AS remarks, l.reference_id,
                   COALESCE(p.invoice_no, '') AS invoice_no,
                   core.fn_inventory_user_name(l.created_by) AS created_by_name,
                   l.created_at
            FROM core.inventory_stock_ledger l
            LEFT JOIN core.inventory_locations loc ON loc.location_id = l.location_id
            LEFT JOIN core.inventory_purchases p
                   ON l.reference_type = 'Purchase' AND p.purchase_id = l.reference_id
            LEFT JOIN core.inventory_transfers t
                   ON l.reference_type = 'Transfer' AND t.transfer_id = l.reference_id
            LEFT JOIN core.inventory_locations lf ON lf.location_id = t.from_location_id
            LEFT JOIN core.inventory_locations lt ON lt.location_id = t.to_location_id
            WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
              AND l.item_id = p_item_id
        ) x
        ORDER BY x.movement_date DESC, x.movement_id DESC;
        RETURN;

    ELSIF v_op = 'ITEMSTOCK' THEN
        -- One item, location by location: every active location (0 when it
        -- holds none) plus any inactive one that still has a row.
        OPEN p_result FOR
        SELECT l.location_id, l.location_name, l.is_default, l.is_active,
               COALESCE(s.quantity, 0) AS quantity
        FROM core.inventory_locations l
        JOIN core.inventory_items i
          ON i.item_id = p_item_id AND i.tenant_id = p_tenant_id AND i.school_id = p_school_id
        LEFT JOIN core.inventory_location_stock s
               ON s.location_id = l.location_id AND s.item_id = i.item_id
        WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
          AND (l.is_active OR COALESCE(s.quantity, 0) <> 0)
        ORDER BY l.is_default DESC, l.location_name;
        RETURN;

    ELSIF v_op = 'RECOUNT' THEN
        -- Rebuild every stock figure from the ledger: each location's, then the
        -- item's total. The cache and the truth should already agree; this is
        -- how you prove it rather than assume it.
        INSERT INTO core.inventory_location_stock (tenant_id, school_id, item_id, location_id, quantity)
        SELECT l.tenant_id, l.school_id, l.item_id, l.location_id, SUM(l.quantity)
        FROM core.inventory_stock_ledger l
        JOIN core.inventory_items i ON i.item_id = l.item_id
        WHERE i.tenant_id = p_tenant_id AND i.school_id = p_school_id AND i.is_deleted = FALSE
        GROUP BY l.tenant_id, l.school_id, l.item_id, l.location_id
        ON CONFLICT (item_id, location_id)
        DO UPDATE SET quantity = EXCLUDED.quantity, updated_at = now();

        UPDATE core.inventory_location_stock s
           SET quantity = 0, updated_at = now()
         WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id
           AND s.quantity <> 0
           AND NOT EXISTS (SELECT 1 FROM core.inventory_stock_ledger l
                           WHERE l.item_id = s.item_id AND l.location_id = s.location_id);

        UPDATE core.inventory_items i
           SET current_stock = COALESCE((
                   SELECT SUM(l.quantity) FROM core.inventory_stock_ledger l
                   WHERE l.item_id = i.item_id), 0),
               updated_by = p_action_user_id, updated_at = now()
         WHERE i.tenant_id = p_tenant_id AND i.school_id = p_school_id
           AND i.is_deleted = FALSE;

        OPEN p_result FOR SELECT TRUE AS success, 'Stock recounted from the ledger.' AS message;
        RETURN;

    -- ── Locations ───────────────────────────────────────────────────────────
    ELSIF v_op = 'LISTLOCATIONS' THEN
        -- The default location is created here if the school has none yet, so
        -- every screen always has at least "Main Store" to offer.
        PERFORM core.fn_inventory_default_location(p_tenant_id, p_school_id, p_action_user_id);

        OPEN p_result FOR
        SELECT l.location_id, l.location_name, l.is_default, l.is_active,
               COUNT(s.item_id) FILTER (WHERE s.quantity > 0)::int AS item_count,
               COALESCE(SUM(s.quantity), 0)                        AS total_qty,
               COALESCE(SUM(ROUND(s.quantity * i.cost_price, 2)), 0) AS stock_value
        FROM core.inventory_locations l
        LEFT JOIN core.inventory_location_stock s ON s.location_id = l.location_id
        LEFT JOIN core.inventory_items i          ON i.item_id = s.item_id
        WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
        GROUP BY l.location_id, l.location_name, l.is_default, l.is_active
        ORDER BY l.is_default DESC, l.is_active DESC, l.location_name;
        RETURN;

    ELSIF v_op = 'SAVELOCATION' THEN
        v_name := NULLIF(TRIM(COALESCE(p_location_name, '')), '');
        IF v_name IS NULL THEN
            RAISE EXCEPTION 'Location name is required.';
        END IF;
        IF LENGTH(v_name) > 100 THEN
            RAISE EXCEPTION 'A location name can be at most 100 characters.';
        END IF;

        -- Make sure the default exists first, so a school's first new location
        -- does not end up as its only one with no "Main Store" beside it.
        PERFORM core.fn_inventory_default_location(p_tenant_id, p_school_id, p_action_user_id);

        IF EXISTS (SELECT 1 FROM core.inventory_locations
                   WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                     AND location_id <> COALESCE(p_location_id, 0)
                     AND LOWER(TRIM(location_name)) = LOWER(v_name)) THEN
            RAISE EXCEPTION 'A location named "%" already exists.', v_name;
        END IF;

        IF COALESCE(p_location_id, 0) > 0 THEN
            UPDATE core.inventory_locations
               SET location_name = v_name, updated_by = p_action_user_id, updated_at = now()
             WHERE tenant_id = p_tenant_id AND school_id = p_school_id
               AND location_id = p_location_id
            RETURNING location_id INTO v_id;
            IF v_id IS NULL THEN
                RAISE EXCEPTION 'Store location not found.';
            END IF;
        ELSE
            INSERT INTO core.inventory_locations (tenant_id, school_id, location_name, created_by)
            VALUES (p_tenant_id, p_school_id, v_name, p_action_user_id)
            RETURNING location_id INTO v_id;
        END IF;

        OPEN p_result FOR SELECT TRUE AS success, 'Location saved.' AS message, v_id AS location_id;
        RETURN;

    ELSIF v_op = 'SETLOCATIONACTIVE' THEN
        IF p_is_active IS NULL THEN
            RAISE EXCEPTION 'Say whether the location is active.';
        END IF;

        SELECT location_name, is_default INTO v_lname, v_ldef
        FROM core.inventory_locations
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND location_id = p_location_id
        FOR UPDATE;
        IF v_lname IS NULL THEN
            RAISE EXCEPTION 'Store location not found.';
        END IF;

        IF NOT p_is_active THEN
            -- Purchases and movements with no location land in the default.
            IF v_ldef THEN
                RAISE EXCEPTION '% is the default location and cannot be deactivated.', v_lname;
            END IF;
            -- Stock in a location nobody can pick would be stuck there.
            SELECT COUNT(*), COALESCE(SUM(quantity), 0) INTO v_n, v_stock
            FROM core.inventory_location_stock
            WHERE location_id = p_location_id AND quantity > 0;
            IF v_n > 0 THEN
                RAISE EXCEPTION '% still holds stock (% item(s), % in all). Transfer it out first.',
                    v_lname, v_n, trim_scale(v_stock)::text;
            END IF;
        END IF;

        UPDATE core.inventory_locations
           SET is_active = p_is_active, updated_by = p_action_user_id, updated_at = now()
         WHERE location_id = p_location_id;

        OPEN p_result FOR
            SELECT TRUE AS success,
                   CASE WHEN p_is_active THEN 'Location activated.' ELSE 'Location deactivated.' END AS message,
                   p_location_id AS location_id;
        RETURN;

    -- ── Suppliers ───────────────────────────────────────────────────────────
    ELSIF v_op = 'LISTSUPPLIERS' THEN
        -- Every live (not deleted) supplier, active or not, with what the school
        -- has bought from them. p_search matches name, contact, mobile or GSTIN;
        -- p_filter_status 'Active' / 'Inactive'.
        OPEN p_result FOR
        SELECT s.supplier_id, s.supplier_name, COALESCE(s.contact_person,'') AS contact_person,
               COALESCE(s.mobile,'') AS mobile, COALESCE(s.email,'') AS email,
               COALESCE(s.address,'') AS address, COALESCE(s.gstin,'') AS gstin, s.is_active,
               (SELECT COUNT(*) FROM core.inventory_purchases p
                 WHERE p.supplier_id = s.supplier_id AND p.is_cancelled = FALSE)::int AS bill_count,
               (SELECT COALESCE(SUM(p.grand_total), 0) FROM core.inventory_purchases p
                 WHERE p.supplier_id = s.supplier_id AND p.is_cancelled = FALSE) AS total_billed,
               COALESCE((SELECT MAX(p.purchase_date) FROM core.inventory_purchases p
                 WHERE p.supplier_id = s.supplier_id AND p.is_cancelled = FALSE)::text, '') AS last_bill_date
        FROM core.inventory_suppliers s
        WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id AND s.is_deleted = FALSE
          AND (NULLIF(TRIM(COALESCE(p_search, '')), '') IS NULL
               OR s.supplier_name ILIKE '%' || TRIM(p_search) || '%'
               OR COALESCE(s.contact_person, '') ILIKE '%' || TRIM(p_search) || '%'
               OR COALESCE(s.mobile, '') ILIKE '%' || TRIM(p_search) || '%'
               OR COALESCE(s.gstin, '') ILIKE '%' || TRIM(p_search) || '%')
          AND (NULLIF(TRIM(COALESCE(p_filter_status, '')), '') IS NULL
               OR (TRIM(p_filter_status) = 'Active'   AND s.is_active)
               OR (TRIM(p_filter_status) = 'Inactive' AND NOT s.is_active))
        ORDER BY s.supplier_name;
        RETURN;

    ELSIF v_op = 'SAVESUPPLIER' THEN
        v_name := NULLIF(TRIM(COALESCE(p_supplier_name, '')), '');
        IF v_name IS NULL THEN
            RAISE EXCEPTION 'Supplier name is required.';
        END IF;
        IF NULLIF(TRIM(COALESCE(p_email, '')), '') IS NOT NULL
           AND TRIM(p_email) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
            RAISE EXCEPTION 'Enter a valid email address.';
        END IF;
        IF NULLIF(TRIM(COALESCE(p_gstin, '')), '') IS NOT NULL
           AND UPPER(TRIM(p_gstin)) !~ '^[0-9A-Z]{15}$' THEN
            RAISE EXCEPTION 'A GSTIN is 15 letters and digits.';
        END IF;
        IF EXISTS (SELECT 1 FROM core.inventory_suppliers
                   WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                     AND is_deleted = FALSE AND supplier_id <> COALESCE(p_supplier_id, 0)
                     AND LOWER(TRIM(supplier_name)) = LOWER(v_name)) THEN
            RAISE EXCEPTION 'A supplier named "%" already exists.', v_name;
        END IF;

        IF COALESCE(p_supplier_id, 0) > 0 THEN
            -- Renaming never touches old bills: each keeps its own name snapshot.
            UPDATE core.inventory_suppliers
               SET supplier_name = v_name,
                   contact_person = NULLIF(TRIM(COALESCE(p_contact_person,'')),''),
                   mobile  = NULLIF(TRIM(COALESCE(p_mobile,'')),''),
                   email   = NULLIF(TRIM(COALESCE(p_email,'')),''),
                   address = NULLIF(TRIM(COALESCE(p_address,'')),''),
                   gstin   = NULLIF(UPPER(TRIM(COALESCE(p_gstin,''))),''),
                   updated_by = p_action_user_id, updated_at = now()
             WHERE tenant_id = p_tenant_id AND school_id = p_school_id
               AND supplier_id = p_supplier_id AND is_deleted = FALSE
             RETURNING supplier_id INTO v_id;

            IF v_id IS NULL THEN
                RAISE EXCEPTION 'Supplier not found.';
            END IF;
        ELSE
            INSERT INTO core.inventory_suppliers
                (tenant_id, school_id, supplier_name, contact_person, mobile,
                 email, address, gstin, created_by)
            VALUES (p_tenant_id, p_school_id, v_name,
                    NULLIF(TRIM(COALESCE(p_contact_person,'')),''),
                    NULLIF(TRIM(COALESCE(p_mobile,'')),''),
                    NULLIF(TRIM(COALESCE(p_email,'')),''),
                    NULLIF(TRIM(COALESCE(p_address,'')),''),
                    NULLIF(UPPER(TRIM(COALESCE(p_gstin,''))),''), p_action_user_id)
            RETURNING supplier_id INTO v_id;
        END IF;

        OPEN p_result FOR SELECT TRUE AS success, 'Supplier saved.' AS message, v_id AS supplier_id;
        RETURN;

    ELSIF v_op = 'SETSUPPLIERACTIVE' THEN
        -- An inactive supplier keeps its bills and can be re-activated; it just
        -- cannot be picked for a new bill.
        IF p_is_active IS NULL THEN
            RAISE EXCEPTION 'Say whether the supplier is active.';
        END IF;
        UPDATE core.inventory_suppliers
           SET is_active = p_is_active, updated_by = p_action_user_id, updated_at = now()
         WHERE tenant_id = p_tenant_id AND school_id = p_school_id
           AND supplier_id = p_supplier_id AND is_deleted = FALSE
         RETURNING supplier_id INTO v_id;
        IF v_id IS NULL THEN
            RAISE EXCEPTION 'Supplier not found.';
        END IF;

        OPEN p_result FOR
            SELECT TRUE AS success,
                   CASE WHEN p_is_active THEN 'Supplier activated.' ELSE 'Supplier deactivated.' END AS message,
                   v_id AS supplier_id;
        RETURN;

    ELSIF v_op = 'DELETESUPPLIER' THEN
        -- Soft delete: last year's invoice must keep naming its supplier.
        UPDATE core.inventory_suppliers
           SET is_deleted = TRUE, is_active = FALSE,
               updated_by = p_action_user_id, updated_at = now()
         WHERE tenant_id = p_tenant_id AND school_id = p_school_id
           AND supplier_id = p_supplier_id AND is_deleted = FALSE
         RETURNING supplier_id INTO v_id;

        IF v_id IS NULL THEN
            RAISE EXCEPTION 'Supplier not found.';
        END IF;

        OPEN p_result FOR SELECT TRUE AS success, 'Supplier removed.' AS message;
        RETURN;

    END IF;

    RAISE EXCEPTION 'Unknown operation %.', p_operation;
END;
$$;
