-- ============================================================================
-- Inventory / store: items, suppliers, purchases, and stock movement.
--
-- The two pages existed as shells with no backend at all — the item list and the
-- purchase form rendered, saved nothing, and showed invented rows. This is the
-- real thing.
--
-- DESIGN NOTES
--
--   * STOCK IS A LEDGER, NOT A NUMBER. Every change writes a row to
--     core.inventory_stock_ledger saying what moved, how much, why and who did
--     it. `current_stock` on the item is a running total maintained in the SAME
--     transaction as the movement — a cache for the list screen, never the
--     source of truth. sp_inventory_manage 'Recount' rebuilds it from the ledger,
--     so the two can always be reconciled rather than argued about. This is the
--     same lesson as the fee ledger: a balance you only ever UPDATE drifts, and
--     nobody can tell you when or why.
--
--   * OPENING STOCK IS A MOVEMENT TOO. Creating an item with 40 in hand writes
--     an 'Opening' row rather than quietly seeding the number, so the very first
--     figure has a date and an author like every later one.
--
--   * STOCK CANNOT GO NEGATIVE. Issuing more than is on the shelf is refused by
--     name and amount ("Only 3 Piece of School Tie left"), because a negative
--     stock figure is never a real thing that happened — it is always a mistake
--     someone needs to correct at the time, not discover at audit.
--
--   * A PURCHASE IS IMMUTABLE ONCE SAVED. It can be CANCELLED, which reverses
--     its stock with a matching negative movement, but never edited in place.
--     An invoice that silently changes is worse than one that is wrong.
--
--   * Status (Available / Low Stock / Out of Stock) is DERIVED from
--     current_stock against min_stock, never stored. A stored status is one more
--     thing that can disagree with the quantity beside it.
--
--   * Suppliers are per school and soft-deleted, because a purchase from last
--     year must keep naming its supplier even after the school stops using them.
--
-- Target DB: PostgreSQL. Safe to re-run.
-- ============================================================================

-- ── Items ───────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS core.inventory_items (
    item_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id      integer NOT NULL,
    school_id      integer NOT NULL,

    item_name      varchar(150) NOT NULL,
    sku            varchar(60),
    category       varchar(60),
    sub_category   varchar(60),
    item_type      varchar(20) NOT NULL DEFAULT 'Consumable',
    unit_type      varchar(20) NOT NULL DEFAULT 'Piece',

    current_stock  numeric(14,2) NOT NULL DEFAULT 0,   -- running total, see notes
    min_stock      numeric(14,2) NOT NULL DEFAULT 0,

    -- Cost price is what gives the Value column and the Stock Value card a real
    -- source. It is the item's standard cost, not a running average of what was
    -- actually paid — purchases record their own unit price line by line, so the
    -- two can be compared rather than one overwriting the other.
    cost_price     numeric(14,2) NOT NULL DEFAULT 0,
    selling_price  numeric(14,2) NOT NULL DEFAULT 0,
    brand          varchar(80),
    model          varchar(80),
    description    text,

    is_active      boolean NOT NULL DEFAULT TRUE,
    is_deleted     boolean NOT NULL DEFAULT FALSE,
    created_by     integer NOT NULL DEFAULT 0,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_by     integer,
    updated_at     timestamptz,

    CONSTRAINT chk_inv_item_type CHECK (item_type IN ('Consumable','Reusable','Saleable')),
    CONSTRAINT chk_inv_item_min  CHECK (min_stock >= 0)
);

-- For a database created before these columns existed.
ALTER TABLE core.inventory_items ADD COLUMN IF NOT EXISTS cost_price    numeric(14,2) NOT NULL DEFAULT 0;
ALTER TABLE core.inventory_items ADD COLUMN IF NOT EXISTS selling_price numeric(14,2) NOT NULL DEFAULT 0;
ALTER TABLE core.inventory_items ADD COLUMN IF NOT EXISTS brand         varchar(80);
ALTER TABLE core.inventory_items ADD COLUMN IF NOT EXISTS model         varchar(80);
ALTER TABLE core.inventory_items ADD COLUMN IF NOT EXISTS description   text;

-- Two items with the same name in one school are a data-entry slip, not a plan.
CREATE UNIQUE INDEX IF NOT EXISTS ux_inventory_item_name
    ON core.inventory_items (tenant_id, school_id, LOWER(TRIM(item_name)))
    WHERE is_deleted = FALSE;

-- SKU is optional, but when given it has to be unique or it is not an SKU.
CREATE UNIQUE INDEX IF NOT EXISTS ux_inventory_item_sku
    ON core.inventory_items (tenant_id, school_id, LOWER(TRIM(sku)))
    WHERE is_deleted = FALSE AND sku IS NOT NULL AND TRIM(sku) <> '';

CREATE INDEX IF NOT EXISTS ix_inventory_item_school
    ON core.inventory_items (tenant_id, school_id, is_deleted);


-- ── Suppliers ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS core.inventory_suppliers (
    supplier_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id      integer NOT NULL,
    school_id      integer NOT NULL,

    supplier_name  varchar(150) NOT NULL,
    contact_person varchar(100),
    mobile         varchar(20),
    email          varchar(120),
    address        text,
    gstin          varchar(20),

    is_active      boolean NOT NULL DEFAULT TRUE,
    is_deleted     boolean NOT NULL DEFAULT FALSE,
    created_by     integer NOT NULL DEFAULT 0,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_by     integer,
    updated_at     timestamptz
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_inventory_supplier_name
    ON core.inventory_suppliers (tenant_id, school_id, LOWER(TRIM(supplier_name)))
    WHERE is_deleted = FALSE;


-- ── Purchases ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS core.inventory_purchases (
    purchase_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id      integer NOT NULL,
    school_id      integer NOT NULL,

    supplier_id    integer,
    supplier_name  varchar(150),      -- snapshot: the invoice keeps its own name
    purchase_date  date NOT NULL,
    invoice_no     varchar(60),
    payment_mode   varchar(30),
    remarks        text,

    sub_total      numeric(14,2) NOT NULL DEFAULT 0,
    tax_total      numeric(14,2) NOT NULL DEFAULT 0,
    grand_total    numeric(14,2) NOT NULL DEFAULT 0,

    is_cancelled   boolean NOT NULL DEFAULT FALSE,
    cancel_reason  text,
    cancelled_by   integer,
    cancelled_at   timestamptz,

    created_by     integer NOT NULL DEFAULT 0,
    created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_inventory_purchase_school
    ON core.inventory_purchases (tenant_id, school_id, purchase_date DESC);

-- One invoice number per supplier, so the same bill cannot be entered twice.
CREATE UNIQUE INDEX IF NOT EXISTS ux_inventory_purchase_invoice
    ON core.inventory_purchases (tenant_id, school_id, supplier_id, LOWER(TRIM(invoice_no)))
    WHERE is_cancelled = FALSE AND invoice_no IS NOT NULL AND TRIM(invoice_no) <> '';


CREATE TABLE IF NOT EXISTS core.inventory_purchase_items (
    purchase_item_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id      integer NOT NULL,
    school_id      integer NOT NULL,
    purchase_id    integer NOT NULL REFERENCES core.inventory_purchases(purchase_id),
    item_id        integer NOT NULL REFERENCES core.inventory_items(item_id),

    item_name      varchar(150),      -- snapshot, as on the invoice
    quantity       numeric(14,2) NOT NULL,
    unit_price     numeric(14,2) NOT NULL DEFAULT 0,
    tax_percent    numeric(6,2)  NOT NULL DEFAULT 0,
    line_total     numeric(14,2) NOT NULL DEFAULT 0,

    CONSTRAINT chk_inv_pi_qty CHECK (quantity > 0),
    CONSTRAINT chk_inv_pi_price CHECK (unit_price >= 0),
    CONSTRAINT chk_inv_pi_tax CHECK (tax_percent >= 0 AND tax_percent <= 100)
);

CREATE INDEX IF NOT EXISTS ix_inventory_purchase_items_pid
    ON core.inventory_purchase_items (purchase_id);


-- ── Stock movement ledger ───────────────────────────────────────────────────
-- Every change to stock, ever. Positive in, negative out.
CREATE TABLE IF NOT EXISTS core.inventory_stock_ledger (
    movement_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id      integer NOT NULL,
    school_id      integer NOT NULL,
    item_id        integer NOT NULL REFERENCES core.inventory_items(item_id),

    movement_date  date NOT NULL DEFAULT CURRENT_DATE,
    movement_type  varchar(20) NOT NULL,
    quantity       numeric(14,2) NOT NULL,      -- signed: + in, - out
    balance_after  numeric(14,2) NOT NULL,

    reference_type varchar(20),                 -- 'Purchase' | NULL
    reference_id   integer,                     -- purchase_id, when there is one
    issued_to      varchar(150),                -- for an Issue: who took it
    remarks        text,

    created_by     integer NOT NULL DEFAULT 0,
    created_at     timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT chk_inv_move_type CHECK (movement_type IN
        ('Opening','Purchase','Issue','Return','Damage','Adjustment','PurchaseCancel')),
    CONSTRAINT chk_inv_move_qty CHECK (quantity <> 0)
);

CREATE INDEX IF NOT EXISTS ix_inventory_ledger_item
    ON core.inventory_stock_ledger (tenant_id, school_id, item_id, movement_id DESC);


-- ════════════════════════════════════════════════════════════════════════════
-- Items, suppliers and stock movement
-- ════════════════════════════════════════════════════════════════════════════
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
    INOUT p_result       refcursor DEFAULT 'inventory_cursor'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_op      text := UPPER(COALESCE(p_operation, ''));
    v_id      integer;
    v_name    text;
    v_stock   numeric;
    v_unit    text;
    v_new     numeric;
    v_sign    smallint;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    -- ── Items ───────────────────────────────────────────────────────────────
    IF v_op = 'LISTITEMS' THEN
        OPEN p_result FOR
        SELECT i.item_id,
               i.item_name,
               COALESCE(i.sku, '')          AS sku,
               COALESCE(i.category, '')     AS category,
               COALESCE(i.sub_category, '') AS sub_category,
               i.item_type,
               i.unit_type,
               i.current_stock,
               i.min_stock,
               i.cost_price,
               i.selling_price,
               COALESCE(i.brand, '')       AS brand,
               COALESCE(i.model, '')       AS model,
               COALESCE(i.description, '') AS description,
               -- What the shelf is worth at standard cost.
               ROUND(i.current_stock * i.cost_price, 2) AS stock_value,
               -- Derived, never stored: one number cannot disagree with itself.
               CASE WHEN i.current_stock <= 0            THEN 'Out of Stock'
                    WHEN i.current_stock <= i.min_stock  THEN 'Low Stock'
                    ELSE 'Available' END                 AS stock_status,
               i.is_active
        FROM core.inventory_items i
        WHERE i.tenant_id = p_tenant_id AND i.school_id = p_school_id
          AND i.is_deleted = FALSE
          AND (NULLIF(TRIM(COALESCE(p_search, '')), '') IS NULL
               OR i.item_name ILIKE '%' || TRIM(p_search) || '%'
               OR COALESCE(i.sku, '') ILIKE '%' || TRIM(p_search) || '%'
               OR COALESCE(i.category, '') ILIKE '%' || TRIM(p_search) || '%')
          AND (NULLIF(TRIM(COALESCE(p_filter_status, '')), '') IS NULL
               OR CASE WHEN i.current_stock <= 0           THEN 'Out of Stock'
                       WHEN i.current_stock <= i.min_stock THEN 'Low Stock'
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

        IF COALESCE(p_item_id, 0) > 0 THEN
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

            IF v_id IS NULL THEN
                RAISE EXCEPTION 'Item not found.';
            END IF;
        ELSE
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
            -- the shelf has a date and an author too.
            IF COALESCE(p_opening_stock, 0) <> 0 THEN
                UPDATE core.inventory_items
                   SET current_stock = COALESCE(p_opening_stock, 0)
                 WHERE item_id = v_id;

                INSERT INTO core.inventory_stock_ledger
                    (tenant_id, school_id, item_id, movement_type, quantity,
                     balance_after, remarks, created_by)
                VALUES (p_tenant_id, p_school_id, v_id, 'Opening',
                        COALESCE(p_opening_stock, 0), COALESCE(p_opening_stock, 0),
                        'Opening stock', p_action_user_id);
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
                v_name, TRIM(TO_CHAR(v_stock, 'FM999999990.00'));
        END IF;

        UPDATE core.inventory_items
           SET is_deleted = TRUE, is_active = FALSE,
               updated_by = p_action_user_id, updated_at = now()
         WHERE item_id = p_item_id;

        OPEN p_result FOR SELECT TRUE AS success, 'Item deleted.' AS message;
        RETURN;

    -- ── Stock movement ──────────────────────────────────────────────────────
    ELSIF v_op = 'MOVESTOCK' THEN
        IF COALESCE(p_quantity, 0) <= 0 THEN
            RAISE EXCEPTION 'Enter a quantity greater than zero.';
        END IF;
        IF COALESCE(TRIM(p_movement_type), '') NOT IN ('Issue','Return','Damage','Adjustment') THEN
            RAISE EXCEPTION 'Choose what kind of stock movement this is.';
        END IF;

        SELECT item_name, current_stock, unit_type INTO v_name, v_stock, v_unit
        FROM core.inventory_items
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND item_id = p_item_id AND is_deleted = FALSE
        FOR UPDATE;

        IF v_name IS NULL THEN
            RAISE EXCEPTION 'Item not found.';
        END IF;

        -- Issue and Damage take stock away; Return and Adjustment add it back.
        v_sign := CASE WHEN TRIM(p_movement_type) IN ('Issue','Damage') THEN -1 ELSE 1 END;
        v_new  := v_stock + (v_sign * p_quantity);

        IF v_new < 0 THEN
            RAISE EXCEPTION 'Only % % of % left.',
                TRIM(TO_CHAR(v_stock, 'FM999999990.00')), v_unit, v_name;
        END IF;

        UPDATE core.inventory_items
           SET current_stock = v_new, updated_by = p_action_user_id, updated_at = now()
         WHERE item_id = p_item_id;

        INSERT INTO core.inventory_stock_ledger
            (tenant_id, school_id, item_id, movement_type, quantity, balance_after,
             issued_to, remarks, created_by)
        VALUES (p_tenant_id, p_school_id, p_item_id, TRIM(p_movement_type),
                v_sign * p_quantity, v_new,
                NULLIF(TRIM(COALESCE(p_issued_to, '')), ''),
                NULLIF(TRIM(COALESCE(p_remarks, '')), ''), p_action_user_id);

        OPEN p_result FOR
            SELECT TRUE AS success, 'Stock updated.' AS message, v_new AS current_stock;
        RETURN;

    ELSIF v_op = 'ITEMLEDGER' THEN
        OPEN p_result FOR
        SELECT l.movement_id, l.movement_date, l.movement_type, l.quantity,
               l.balance_after, COALESCE(l.issued_to,'') AS issued_to,
               COALESCE(l.remarks,'') AS remarks, l.reference_id
        FROM core.inventory_stock_ledger l
        WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
          AND l.item_id = p_item_id
        ORDER BY l.movement_id DESC;
        RETURN;

    ELSIF v_op = 'RECOUNT' THEN
        -- Rebuild current_stock from the ledger. The cache and the truth should
        -- already agree; this is how you prove it rather than assume it.
        UPDATE core.inventory_items i
           SET current_stock = COALESCE((
                   SELECT SUM(l.quantity) FROM core.inventory_stock_ledger l
                   WHERE l.item_id = i.item_id), 0),
               updated_by = p_action_user_id, updated_at = now()
         WHERE i.tenant_id = p_tenant_id AND i.school_id = p_school_id
           AND i.is_deleted = FALSE;

        OPEN p_result FOR SELECT TRUE AS success, 'Stock recounted from the ledger.' AS message;
        RETURN;

    -- ── Suppliers ───────────────────────────────────────────────────────────
    ELSIF v_op = 'LISTSUPPLIERS' THEN
        OPEN p_result FOR
        SELECT supplier_id, supplier_name, COALESCE(contact_person,'') AS contact_person,
               COALESCE(mobile,'') AS mobile, COALESCE(email,'') AS email,
               COALESCE(address,'') AS address, COALESCE(gstin,'') AS gstin, is_active
        FROM core.inventory_suppliers
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND is_deleted = FALSE
        ORDER BY supplier_name;
        RETURN;

    ELSIF v_op = 'SAVESUPPLIER' THEN
        v_name := NULLIF(TRIM(COALESCE(p_supplier_name, '')), '');
        IF v_name IS NULL THEN
            RAISE EXCEPTION 'Supplier name is required.';
        END IF;

        IF COALESCE(p_supplier_id, 0) > 0 THEN
            UPDATE core.inventory_suppliers
               SET supplier_name = v_name,
                   contact_person = NULLIF(TRIM(COALESCE(p_contact_person,'')),''),
                   mobile  = NULLIF(TRIM(COALESCE(p_mobile,'')),''),
                   email   = NULLIF(TRIM(COALESCE(p_email,'')),''),
                   address = NULLIF(TRIM(COALESCE(p_address,'')),''),
                   gstin   = NULLIF(TRIM(COALESCE(p_gstin,'')),''),
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
                    NULLIF(TRIM(COALESCE(p_gstin,'')),''), p_action_user_id)
            RETURNING supplier_id INTO v_id;
        END IF;

        OPEN p_result FOR SELECT TRUE AS success, 'Supplier saved.' AS message, v_id AS supplier_id;
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


-- ════════════════════════════════════════════════════════════════════════════
-- Purchases
-- ════════════════════════════════════════════════════════════════════════════
-- Same for the purchase proc.
DO $drop$
DECLARE r record;
BEGIN
    FOR r IN SELECT p.oid::regprocedure AS sig FROM pg_proc p
             JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'core' AND p.proname = 'sp_inventory_purchase_manage'
    LOOP
        EXECUTE 'DROP PROCEDURE ' || r.sig;
    END LOOP;
END $drop$;

CREATE OR REPLACE PROCEDURE core.sp_inventory_purchase_manage(
    IN  p_operation      text,
    IN  p_tenant_id      integer,
    IN  p_school_id      integer,
    IN  p_action_user_id integer,
    IN  p_purchase_id    integer DEFAULT NULL,
    IN  p_supplier_id    integer DEFAULT NULL,
    IN  p_purchase_date  date    DEFAULT NULL,
    IN  p_invoice_no     text    DEFAULT NULL,
    IN  p_payment_mode   text    DEFAULT NULL,
    IN  p_remarks        text    DEFAULT NULL,
    IN  p_items          jsonb   DEFAULT '[]'::jsonb,
    IN  p_from_date      date    DEFAULT NULL,
    IN  p_to_date        date    DEFAULT NULL,
    INOUT p_result       refcursor DEFAULT 'purchase_cursor',
    INOUT p_result2      refcursor DEFAULT 'purchase_cursor2'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_op     text := UPPER(COALESCE(p_operation, ''));
    v_pid    integer;
    v_supp   text;
    v_sub    numeric := 0;
    v_tax    numeric := 0;
    v_line   record;
    v_new    numeric;
    v_name   text;
    v_cnt    integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    IF v_op = 'LIST' THEN
        OPEN p_result FOR
        SELECT p.purchase_id, p.purchase_date,
               COALESCE(p.supplier_name, '') AS supplier_name,
               COALESCE(p.invoice_no, '')    AS invoice_no,
               COALESCE(p.payment_mode, '')  AS payment_mode,
               p.sub_total, p.tax_total, p.grand_total,
               p.is_cancelled,
               (SELECT COUNT(*) FROM core.inventory_purchase_items pi
                 WHERE pi.purchase_id = p.purchase_id)::int AS line_count
        FROM core.inventory_purchases p
        WHERE p.tenant_id = p_tenant_id AND p.school_id = p_school_id
          AND (p_from_date IS NULL OR p.purchase_date >= p_from_date)
          AND (p_to_date   IS NULL OR p.purchase_date <= p_to_date)
        ORDER BY p.purchase_date DESC, p.purchase_id DESC;
        RETURN;

    ELSIF v_op = 'GET' THEN
        OPEN p_result FOR
        SELECT purchase_id, purchase_date, supplier_id,
               COALESCE(supplier_name,'') AS supplier_name,
               COALESCE(invoice_no,'') AS invoice_no,
               COALESCE(payment_mode,'') AS payment_mode,
               COALESCE(remarks,'') AS remarks,
               sub_total, tax_total, grand_total, is_cancelled,
               COALESCE(cancel_reason,'') AS cancel_reason
        FROM core.inventory_purchases
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND purchase_id = p_purchase_id;

        OPEN p_result2 FOR
        SELECT pi.purchase_item_id, pi.item_id, COALESCE(pi.item_name,'') AS item_name,
               pi.quantity, pi.unit_price, pi.tax_percent, pi.line_total
        FROM core.inventory_purchase_items pi
        WHERE pi.tenant_id = p_tenant_id AND pi.school_id = p_school_id
          AND pi.purchase_id = p_purchase_id
        ORDER BY pi.purchase_item_id;
        RETURN;

    ELSIF v_op = 'SAVE' THEN
        IF p_purchase_date IS NULL THEN
            RAISE EXCEPTION 'Choose the purchase date.';
        END IF;
        IF p_purchase_date > CURRENT_DATE THEN
            RAISE EXCEPTION 'A purchase cannot be dated in the future.';
        END IF;
        IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
            RAISE EXCEPTION 'Add at least one item to the purchase.';
        END IF;

        SELECT supplier_name INTO v_supp FROM core.inventory_suppliers
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND supplier_id = p_supplier_id AND is_deleted = FALSE;

        IF p_supplier_id IS NOT NULL AND v_supp IS NULL THEN
            RAISE EXCEPTION 'Supplier not found.';
        END IF;

        -- Every line must name an item that belongs to THIS school, checked
        -- before anything is written, so a bad line cannot leave a half-purchase.
        FOR v_line IN
            SELECT * FROM jsonb_to_recordset(p_items)
                AS x("itemId" integer, quantity numeric, "unitPrice" numeric, "taxPercent" numeric)
        LOOP
            IF COALESCE(v_line.quantity, 0) <= 0 THEN
                RAISE EXCEPTION 'Every line needs a quantity greater than zero.';
            END IF;
            IF COALESCE(v_line."unitPrice", 0) < 0 THEN
                RAISE EXCEPTION 'A unit price cannot be negative.';
            END IF;

            SELECT item_name INTO v_name FROM core.inventory_items
            WHERE tenant_id = p_tenant_id AND school_id = p_school_id
              AND item_id = v_line."itemId" AND is_deleted = FALSE;

            IF v_name IS NULL THEN
                RAISE EXCEPTION 'One of the lines is not an item of this school.';
            END IF;
        END LOOP;

        INSERT INTO core.inventory_purchases
            (tenant_id, school_id, supplier_id, supplier_name, purchase_date,
             invoice_no, payment_mode, remarks, created_by)
        VALUES (p_tenant_id, p_school_id, p_supplier_id, v_supp, p_purchase_date,
                NULLIF(TRIM(COALESCE(p_invoice_no,'')),''),
                NULLIF(TRIM(COALESCE(p_payment_mode,'')),''),
                NULLIF(TRIM(COALESCE(p_remarks,'')),''), p_action_user_id)
        RETURNING purchase_id INTO v_pid;

        FOR v_line IN
            SELECT * FROM jsonb_to_recordset(p_items)
                AS x("itemId" integer, quantity numeric, "unitPrice" numeric, "taxPercent" numeric)
        LOOP
            SELECT item_name, current_stock INTO v_name, v_new
            FROM core.inventory_items
            WHERE item_id = v_line."itemId" FOR UPDATE;

            v_new := v_new + v_line.quantity;

            INSERT INTO core.inventory_purchase_items
                (tenant_id, school_id, purchase_id, item_id, item_name,
                 quantity, unit_price, tax_percent, line_total)
            VALUES (p_tenant_id, p_school_id, v_pid, v_line."itemId", v_name,
                    v_line.quantity, COALESCE(v_line."unitPrice", 0),
                    COALESCE(v_line."taxPercent", 0),
                    ROUND(v_line.quantity * COALESCE(v_line."unitPrice", 0)
                          * (1 + COALESCE(v_line."taxPercent", 0) / 100.0), 2));

            UPDATE core.inventory_items
               SET current_stock = v_new, updated_by = p_action_user_id, updated_at = now()
             WHERE item_id = v_line."itemId";

            INSERT INTO core.inventory_stock_ledger
                (tenant_id, school_id, item_id, movement_date, movement_type,
                 quantity, balance_after, reference_type, reference_id, created_by)
            VALUES (p_tenant_id, p_school_id, v_line."itemId", p_purchase_date,
                    'Purchase', v_line.quantity, v_new, 'Purchase', v_pid, p_action_user_id);

            v_sub := v_sub + (v_line.quantity * COALESCE(v_line."unitPrice", 0));
            v_tax := v_tax + ROUND(v_line.quantity * COALESCE(v_line."unitPrice", 0)
                                   * COALESCE(v_line."taxPercent", 0) / 100.0, 2);
        END LOOP;

        UPDATE core.inventory_purchases
           SET sub_total = ROUND(v_sub, 2), tax_total = ROUND(v_tax, 2),
               grand_total = ROUND(v_sub + v_tax, 2)
         WHERE purchase_id = v_pid;

        OPEN p_result FOR
            SELECT TRUE AS success, 'Purchase saved.' AS message,
                   v_pid AS purchase_id, ROUND(v_sub + v_tax, 2) AS grand_total;
        RETURN;

    ELSIF v_op = 'CANCEL' THEN
        -- A purchase is never edited, only cancelled, and cancelling reverses its
        -- stock with matching negative movements rather than deleting the
        -- originals. The invoice and its reversal both stay on the record.
        SELECT COUNT(*) INTO v_cnt FROM core.inventory_purchases
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND purchase_id = p_purchase_id AND is_cancelled = FALSE;

        IF v_cnt = 0 THEN
            RAISE EXCEPTION 'Purchase not found, or already cancelled.';
        END IF;

        FOR v_line IN
            SELECT pi.item_id, pi.quantity, i.item_name, i.current_stock, i.unit_type
            FROM core.inventory_purchase_items pi
            JOIN core.inventory_items i ON i.item_id = pi.item_id
            WHERE pi.purchase_id = p_purchase_id
            FOR UPDATE OF i
        LOOP
            v_new := v_line.current_stock - v_line.quantity;

            -- Refusing here is the honest answer: the goods have already been
            -- issued, so the purchase cannot simply be un-received.
            IF v_new < 0 THEN
                RAISE EXCEPTION 'Cannot cancel: only % % of % left, and this purchase brought in %.',
                    TRIM(TO_CHAR(v_line.current_stock, 'FM999999990.00')), v_line.unit_type,
                    v_line.item_name, TRIM(TO_CHAR(v_line.quantity, 'FM999999990.00'));
            END IF;

            UPDATE core.inventory_items
               SET current_stock = v_new, updated_by = p_action_user_id, updated_at = now()
             WHERE item_id = v_line.item_id;

            INSERT INTO core.inventory_stock_ledger
                (tenant_id, school_id, item_id, movement_type, quantity, balance_after,
                 reference_type, reference_id, remarks, created_by)
            VALUES (p_tenant_id, p_school_id, v_line.item_id, 'PurchaseCancel',
                    -v_line.quantity, v_new, 'Purchase', p_purchase_id,
                    NULLIF(TRIM(COALESCE(p_remarks,'')),''), p_action_user_id);
        END LOOP;

        UPDATE core.inventory_purchases
           SET is_cancelled = TRUE,
               cancel_reason = NULLIF(TRIM(COALESCE(p_remarks,'')),''),
               cancelled_by = p_action_user_id, cancelled_at = now()
         WHERE purchase_id = p_purchase_id;

        OPEN p_result FOR SELECT TRUE AS success, 'Purchase cancelled.' AS message;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation %.', p_operation;
END;
$$;
