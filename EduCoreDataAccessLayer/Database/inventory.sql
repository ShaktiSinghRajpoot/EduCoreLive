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
--   * REVISION 2026-10-10 (tests/inventory_store_tests.sql): a cancel re-reads
--     stock per line and checks per item (the same item on two lines used to
--     corrupt current_stock and slip past the zero floor); quantities and prices
--     take at most 2 decimals; no negative opening stock or prices; a bill
--     number is unique among no-supplier bills too; header total = sum of its
--     lines; Inactive items cannot be issued or bought; the unit is frozen once
--     stock has moved; a cancel needs a reason; new 'StockTake' movement (a
--     counted quantity, can go down); the ledger keeps the rate (unit_rate) and
--     the history shows who, in date order. Floors on the table itself:
--     current_stock >= 0, prices >= 0.
--
--   * REVISION 2026-10-10b (tests/inventory_locations_tests.sql): store
--     locations (stock per item per location, default "Main Store", existing
--     stock migrated into it), transfers between locations, partial return to
--     supplier, supplier active/inactive + search, purchase detail with
--     returns and who/when. See the "Store locations" section below. The
--     purchase proc now opens all its cursors on every branch (an unopened
--     one made the app's FETCH fail). Apply school_purge.sql after this file
--     (it deletes the new tables when a school is purged).
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
-- Bills with no supplier count as supplier 0: keyed on the raw supplier_id they
-- never collided (NULLs are all distinct), so a cash bill could go in twice.
-- Dropped and rebuilt on every run so an older definition is replaced.
DROP INDEX IF EXISTS core.ux_inventory_purchase_invoice;
CREATE UNIQUE INDEX ux_inventory_purchase_invoice
    ON core.inventory_purchases (tenant_id, school_id, COALESCE(supplier_id, 0), LOWER(TRIM(invoice_no)))
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

    unit_rate      numeric(14,2),               -- rate the movement is valued at
    reference_type varchar(20),                 -- 'Purchase' | NULL
    reference_id   integer,                     -- purchase_id, when there is one
    issued_to      varchar(150),                -- for an Issue: who took it
    remarks        text,

    created_by     integer NOT NULL DEFAULT 0,
    created_at     timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT chk_inv_move_type CHECK (movement_type IN
        ('Opening','Purchase','Issue','Return','Damage','Adjustment','StockTake','PurchaseCancel')),
    CONSTRAINT chk_inv_move_qty CHECK (quantity <> 0)
);

CREATE INDEX IF NOT EXISTS ix_inventory_ledger_item
    ON core.inventory_stock_ledger (tenant_id, school_id, item_id, movement_id DESC);

-- Added after the first release (safe to re-run):
--   * unit_rate: the rate each movement is valued at -- the bill's unit price
--     for a purchase or its cancel, the item's cost price for everything else.
--     Rows written before this column existed keep NULL ("not recorded").
--   * StockTake: a physical count, which can move stock DOWN as well as up.
--   * Hard floors behind the procs: stock and prices never below zero.
ALTER TABLE core.inventory_stock_ledger ADD COLUMN IF NOT EXISTS unit_rate numeric(14,2);

-- (chk_inv_move_type is set once, further down, with the transfer types too:
--  setting the shorter list here failed on a re-run once transfers existed.)

ALTER TABLE core.inventory_items DROP CONSTRAINT IF EXISTS chk_inv_item_stock;
ALTER TABLE core.inventory_items ADD CONSTRAINT chk_inv_item_stock CHECK (current_stock >= 0);
ALTER TABLE core.inventory_items DROP CONSTRAINT IF EXISTS chk_inv_item_price;
ALTER TABLE core.inventory_items ADD CONSTRAINT chk_inv_item_price
    CHECK (cost_price >= 0 AND selling_price >= 0);


-- ════════════════════════════════════════════════════════════════════════════
-- Store locations, transfers and returns to supplier (2026-10-10, D-10)
-- ════════════════════════════════════════════════════════════════════════════
--
--   * A school can keep stock in several places (Main Store, Science Lab,
--     Sports Room). Stock is held per item PER LOCATION in
--     core.inventory_location_stock. The item's current_stock stays as the
--     school-wide total, so:
--
--         current_stock = SUM(location stock) = SUM(ledger quantity)
--
--     and for every location:  location stock = SUM(ledger rows at it).
--     Every ledger row now names its location_id, and location_balance_after
--     is the location's figure after that row (balance_after stays the item's
--     total, so the old running-sum check still holds).
--
--   * Each school gets one default location, "Main Store" (renamable, never
--     deactivated). Purchases, opening stock and movements that do not name a
--     location go there. The migration below puts ALL existing stock and
--     history into it. It only touches rows that have no location yet, so a
--     re-run changes nothing.
--
--   * A TRANSFER moves stock between two locations of the same school in one
--     transaction: a core.inventory_transfers row (who / when / reason) plus a
--     paired 'TransferOut' (-qty at A) and 'TransferIn' (+qty at B) ledger row,
--     both pointing at the transfer (reference_type 'Transfer').
--
--   * A RETURN TO SUPPLIER takes some quantity of some lines of a bill back
--     out, at the location the bill went into. One
--     core.inventory_purchase_returns row per line returned, and a
--     'SupplierReturn' ledger row linked to the bill (reference_type
--     'Purchase') and to the bill line (purchase_item_id). ('Return' is taken:
--     it already means "came back into the store".)
--
--   * CANCELLING A BILL THAT HAS RETURNS cancels only the remainder: each line
--     reverses (bought - returned). What went back to the supplier already left
--     the shelf once, so reversing the full bill would take it out twice. A
--     fully returned bill can still be cancelled; it then moves no stock.
--     After a cancel nothing more can be returned.

CREATE TABLE IF NOT EXISTS core.inventory_locations (
    location_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id      integer NOT NULL,
    school_id      integer NOT NULL,
    location_name  varchar(100) NOT NULL,
    is_default     boolean NOT NULL DEFAULT FALSE,
    is_active      boolean NOT NULL DEFAULT TRUE,
    created_by     integer NOT NULL DEFAULT 0,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_by     integer,
    updated_at     timestamptz
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_inventory_location_name
    ON core.inventory_locations (tenant_id, school_id, LOWER(TRIM(location_name)));

-- One default location per school.
CREATE UNIQUE INDEX IF NOT EXISTS ux_inventory_location_default
    ON core.inventory_locations (tenant_id, school_id) WHERE is_default;

CREATE TABLE IF NOT EXISTS core.inventory_location_stock (
    tenant_id      integer NOT NULL,
    school_id      integer NOT NULL,
    item_id        integer NOT NULL REFERENCES core.inventory_items(item_id),
    location_id    integer NOT NULL REFERENCES core.inventory_locations(location_id),
    quantity       numeric(14,2) NOT NULL DEFAULT 0,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (item_id, location_id),
    CONSTRAINT chk_inv_loc_stock CHECK (quantity >= 0)
);

CREATE INDEX IF NOT EXISTS ix_inventory_location_stock_loc
    ON core.inventory_location_stock (location_id);

CREATE TABLE IF NOT EXISTS core.inventory_transfers (
    transfer_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id        integer NOT NULL,
    school_id        integer NOT NULL,
    item_id          integer NOT NULL REFERENCES core.inventory_items(item_id),
    from_location_id integer NOT NULL REFERENCES core.inventory_locations(location_id),
    to_location_id   integer NOT NULL REFERENCES core.inventory_locations(location_id),
    transfer_date    varchar(10) NOT NULL DEFAULT to_char(CURRENT_DATE, 'YYYY-MM-DD'),
    quantity         numeric(14,2) NOT NULL,
    reason           text NOT NULL,
    created_by       integer NOT NULL DEFAULT 0,
    created_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT chk_inv_tr_qty  CHECK (quantity > 0),
    CONSTRAINT chk_inv_tr_locs CHECK (from_location_id <> to_location_id)
);

CREATE INDEX IF NOT EXISTS ix_inventory_transfers_school
    ON core.inventory_transfers (tenant_id, school_id, transfer_id DESC);

CREATE TABLE IF NOT EXISTS core.inventory_purchase_returns (
    return_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id        integer NOT NULL,
    school_id        integer NOT NULL,
    purchase_id      integer NOT NULL REFERENCES core.inventory_purchases(purchase_id),
    purchase_item_id integer NOT NULL REFERENCES core.inventory_purchase_items(purchase_item_id),
    item_id          integer NOT NULL REFERENCES core.inventory_items(item_id),
    location_id      integer NOT NULL REFERENCES core.inventory_locations(location_id),
    return_date      varchar(10) NOT NULL DEFAULT to_char(CURRENT_DATE, 'YYYY-MM-DD'),
    quantity         numeric(14,2) NOT NULL,
    unit_price       numeric(14,2) NOT NULL DEFAULT 0,   -- the bill line's rate
    tax_percent      numeric(6,2)  NOT NULL DEFAULT 0,
    amount           numeric(14,2) NOT NULL DEFAULT 0,   -- base + tax, rounded like a bill line
    reason           text NOT NULL,
    created_by       integer NOT NULL DEFAULT 0,
    created_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT chk_inv_ret_qty CHECK (quantity > 0)
);

CREATE INDEX IF NOT EXISTS ix_inventory_purchase_returns_pid
    ON core.inventory_purchase_returns (purchase_id);

-- Where a bill's goods went, and where each movement happened.
ALTER TABLE core.inventory_purchases    ADD COLUMN IF NOT EXISTS location_id integer
    REFERENCES core.inventory_locations(location_id);
ALTER TABLE core.inventory_stock_ledger ADD COLUMN IF NOT EXISTS location_id integer
    REFERENCES core.inventory_locations(location_id);
ALTER TABLE core.inventory_stock_ledger ADD COLUMN IF NOT EXISTS location_balance_after numeric(14,2);
ALTER TABLE core.inventory_stock_ledger ADD COLUMN IF NOT EXISTS purchase_item_id integer;

ALTER TABLE core.inventory_stock_ledger DROP CONSTRAINT IF EXISTS chk_inv_move_type;
ALTER TABLE core.inventory_stock_ledger ADD CONSTRAINT chk_inv_move_type CHECK (movement_type IN
    ('Opening','Purchase','Issue','Return','Damage','Adjustment','StockTake','PurchaseCancel',
     'TransferOut','TransferIn','SupplierReturn'));

CREATE INDEX IF NOT EXISTS ix_inventory_ledger_location
    ON core.inventory_stock_ledger (item_id, location_id);


-- ── Helpers ─────────────────────────────────────────────────────────────────
-- The school's default location, created ("Main Store") the first time it is
-- needed. Safe under concurrency: the partial unique index allows one default.
CREATE OR REPLACE FUNCTION core.fn_inventory_default_location(
    p_tenant_id integer, p_school_id integer, p_user_id integer)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    v_id integer;
BEGIN
    SELECT location_id INTO v_id FROM core.inventory_locations
    WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND is_default;
    IF v_id IS NOT NULL THEN
        RETURN v_id;
    END IF;

    INSERT INTO core.inventory_locations (tenant_id, school_id, location_name, is_default, created_by)
    VALUES (p_tenant_id, p_school_id, 'Main Store', TRUE, COALESCE(p_user_id, 0))
    ON CONFLICT DO NOTHING
    RETURNING location_id INTO v_id;

    IF v_id IS NULL THEN
        -- Another session made the default first, or a location is already
        -- called "Main Store": use the default, else promote the oldest active one.
        SELECT location_id INTO v_id FROM core.inventory_locations
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND is_default;
        IF v_id IS NULL THEN
            UPDATE core.inventory_locations SET is_default = TRUE, is_active = TRUE
             WHERE location_id = (SELECT MIN(location_id) FROM core.inventory_locations
                                  WHERE tenant_id = p_tenant_id AND school_id = p_school_id)
            RETURNING location_id INTO v_id;
        END IF;
    END IF;
    RETURN v_id;
END;
$$;

-- Who did it, for the history screens: the latest profile name, else the email.
CREATE OR REPLACE FUNCTION core.fn_inventory_user_name(p_user_id integer)
RETURNS text
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(
        (SELECT pr.full_name FROM core.user_profiles pr
          WHERE pr.user_id = p_user_id AND COALESCE(pr.is_deleted, FALSE) = FALSE
          ORDER BY pr.user_profile_id DESC LIMIT 1),
        (SELECT u.email FROM core.users u WHERE u.user_id = p_user_id),
        'User #' || p_user_id);
$$;

-- Posts ONE stock movement: the location's stock, the item's total and the
-- ledger row, together. The caller has already locked the item row (FOR
-- UPDATE) and checked the rule ("only 3 left"); the CHECK constraints on both
-- stock columns are the last line of defence. Returns the item's new total.
CREATE OR REPLACE FUNCTION core.fn_inventory_post_movement(
    p_tenant_id        integer,
    p_school_id        integer,
    p_user_id          integer,
    p_item_id          integer,
    p_location_id      integer,
    p_type             text,
    p_qty              numeric,           -- signed: + in, - out
    p_rate             numeric,
    p_ref_type         text    DEFAULT NULL,
    p_ref_id           integer DEFAULT NULL,
    p_purchase_item_id integer DEFAULT NULL,
    p_issued_to        text    DEFAULT NULL,
    p_remarks          text    DEFAULT NULL,
    p_date             date    DEFAULT NULL)
RETURNS numeric
LANGUAGE plpgsql
AS $$
DECLARE
    v_loc numeric;
    v_new numeric;
BEGIN
    -- UPDATE first, INSERT only when the pair has no row yet. (An INSERT ... ON
    -- CONFLICT would check the negative quantity against the floor before it
    -- ever saw the existing row.)
    UPDATE core.inventory_location_stock
       SET quantity = quantity + p_qty, updated_at = now()
     WHERE item_id = p_item_id AND location_id = p_location_id
    RETURNING quantity INTO v_loc;

    IF NOT FOUND THEN
        INSERT INTO core.inventory_location_stock (tenant_id, school_id, item_id, location_id, quantity)
        VALUES (p_tenant_id, p_school_id, p_item_id, p_location_id, p_qty)
        RETURNING quantity INTO v_loc;
    END IF;

    UPDATE core.inventory_items
       SET current_stock = current_stock + p_qty,
           updated_by = p_user_id, updated_at = now()
     WHERE item_id = p_item_id
    RETURNING current_stock INTO v_new;

    INSERT INTO core.inventory_stock_ledger
        (tenant_id, school_id, item_id, location_id, movement_date, movement_type,
         quantity, balance_after, location_balance_after, unit_rate,
         reference_type, reference_id, purchase_item_id, issued_to, remarks, created_by)
    VALUES (p_tenant_id, p_school_id, p_item_id, p_location_id, COALESCE(p_date, CURRENT_DATE), p_type,
            p_qty, v_new, v_loc, p_rate,
            p_ref_type, p_ref_id, p_purchase_item_id,
            NULLIF(TRIM(COALESCE(p_issued_to, '')), ''),
            NULLIF(TRIM(COALESCE(p_remarks, '')), ''), p_user_id);

    RETURN v_new;
END;
$$;


-- ── Migration: everything that exists today goes into "Main Store" ─────────
-- Only rows with no location are touched, so running this again is a no-op.
DO $migrate$
DECLARE
    r     record;
    v_loc integer;
BEGIN
    FOR r IN
        SELECT tenant_id, school_id FROM core.inventory_items
        UNION SELECT tenant_id, school_id FROM core.inventory_stock_ledger
        UNION SELECT tenant_id, school_id FROM core.inventory_purchases
    LOOP
        v_loc := core.fn_inventory_default_location(r.tenant_id, r.school_id, 0);

        UPDATE core.inventory_stock_ledger SET location_id = v_loc
         WHERE tenant_id = r.tenant_id AND school_id = r.school_id AND location_id IS NULL;

        UPDATE core.inventory_purchases SET location_id = v_loc
         WHERE tenant_id = r.tenant_id AND school_id = r.school_id AND location_id IS NULL;
    END LOOP;

    -- The location's running figure, for rows written before locations existed.
    UPDATE core.inventory_stock_ledger l
       SET location_balance_after = x.running
      FROM (SELECT movement_id,
                   SUM(quantity) OVER (PARTITION BY item_id, location_id ORDER BY movement_id) AS running
              FROM core.inventory_stock_ledger) x
     WHERE x.movement_id = l.movement_id
       AND l.location_balance_after IS NULL;

    -- A stock row for every item/location pair that has history but no row yet.
    -- Built from the ledger (the truth); on a consistent database that equals
    -- current_stock, which the test suite checks.
    INSERT INTO core.inventory_location_stock (tenant_id, school_id, item_id, location_id, quantity)
    SELECT l.tenant_id, l.school_id, l.item_id, l.location_id, SUM(l.quantity)
    FROM core.inventory_stock_ledger l
    WHERE NOT EXISTS (SELECT 1 FROM core.inventory_location_stock s
                      WHERE s.item_id = l.item_id AND s.location_id = l.location_id)
    GROUP BY l.tenant_id, l.school_id, l.item_id, l.location_id;
END
$migrate$;

-- From now on every movement names its location.
ALTER TABLE core.inventory_stock_ledger ALTER COLUMN location_id SET NOT NULL;


-- ════════════════════════════════════════════════════════════════════════════
-- Items, suppliers, locations and stock movement
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
                            AND l.item_id = i.item_id AND l.movement_type = 'Opening'), 0) AS opening_qty,
               -- Stock added by hand later (an Adjustment, or a stock-take that
               -- counted more): no bill either, so it is shown with the opening.
               COALESCE((SELECT SUM(l.quantity) FROM core.inventory_stock_ledger l
                          WHERE l.tenant_id = i.tenant_id AND l.school_id = i.school_id
                            AND l.item_id = i.item_id AND l.quantity > 0
                            AND l.movement_type IN ('Adjustment', 'StockTake')), 0) AS added_qty
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


-- ════════════════════════════════════════════════════════════════════════════
-- Purchases
-- ════════════════════════════════════════════════════════════════════════════
-- EVERY branch opens both cursors (an unused one as an empty result).
-- The app FETCHes each refcursor parameter after the call, and a cursor that
-- was never opened fails that FETCH ("cursor does not exist") -- which is what
-- the List / Save / Cancel calls did before this revision.
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
    IN  p_location_id    integer DEFAULT NULL,   -- where a new bill's goods go
    INOUT p_result       refcursor DEFAULT 'purchase_cursor',
    INOUT p_result2      refcursor DEFAULT 'purchase_cursor2'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_op      text := UPPER(COALESCE(p_operation, ''));
    v_inv     text := NULLIF(TRIM(COALESCE(p_invoice_no, '')), '');
    v_reason  text := NULLIF(TRIM(COALESCE(p_remarks, '')), '');
    v_pid     integer;
    v_supp    text;
    v_sactive boolean;
    v_sub     numeric := 0;
    v_tax     numeric := 0;
    v_base    numeric;
    v_ltax    numeric;
    v_line    record;
    v_new     numeric;
    v_name    text;
    v_active  boolean;
    v_cnt     integer;
    v_dup     text;
    v_loc     integer;
    v_lname   text;
    v_lactive boolean;
    v_cancel  boolean;
    v_left    numeric;
    v_amt     numeric := 0;
    v_ret     numeric := 0;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    IF v_op = 'LIST' THEN
        -- p_supplier_id narrows it to one supplier's bills (supplier screen).
        OPEN p_result FOR
        SELECT p.purchase_id, p.purchase_date,
               COALESCE(p.supplier_name, '') AS supplier_name,
               COALESCE(p.invoice_no, '')    AS invoice_no,
               COALESCE(p.payment_mode, '')  AS payment_mode,
               p.sub_total, p.tax_total, p.grand_total,
               p.is_cancelled,
               (SELECT COUNT(*) FROM core.inventory_purchase_items pi
                 WHERE pi.purchase_id = p.purchase_id)::int AS line_count,
               (SELECT COALESCE(SUM(pi.quantity), 0) FROM core.inventory_purchase_items pi
                 WHERE pi.purchase_id = p.purchase_id) AS item_qty,
               COALESCE(loc.location_name, '') AS location_name,
               (SELECT COALESCE(SUM(r.quantity), 0) FROM core.inventory_purchase_returns r
                 WHERE r.purchase_id = p.purchase_id) AS returned_qty,
               (SELECT COALESCE(SUM(r.amount), 0) FROM core.inventory_purchase_returns r
                 WHERE r.purchase_id = p.purchase_id) AS returned_amount
        FROM core.inventory_purchases p
        LEFT JOIN core.inventory_locations loc ON loc.location_id = p.location_id
        WHERE p.tenant_id = p_tenant_id AND p.school_id = p_school_id
          AND (p_from_date IS NULL OR p.purchase_date::date >= p_from_date)
          AND (p_to_date   IS NULL OR p.purchase_date::date <= p_to_date)
          AND (p_supplier_id IS NULL OR p.supplier_id = p_supplier_id)
        ORDER BY p.purchase_date DESC, p.purchase_id DESC;
        OPEN p_result2 FOR SELECT 1 WHERE FALSE;
        RETURN;

    ELSIF v_op = 'GET' THEN
        -- Header, then the lines with what has gone back to the supplier.
        OPEN p_result FOR
        SELECT p.purchase_id, p.purchase_date, p.supplier_id,
               COALESCE(p.supplier_name,'') AS supplier_name,
               COALESCE(p.invoice_no,'') AS invoice_no,
               COALESCE(p.payment_mode,'') AS payment_mode,
               COALESCE(p.remarks,'') AS remarks,
               p.sub_total, p.tax_total, p.grand_total, p.is_cancelled,
               COALESCE(p.cancel_reason,'') AS cancel_reason,
               p.location_id, COALESCE(loc.location_name, '') AS location_name,
               core.fn_inventory_user_name(p.created_by) AS created_by_name,
               to_char(p.created_at, 'YYYY-MM-DD HH24:MI') AS created_at,
               CASE WHEN p.cancelled_by IS NULL THEN ''
                    ELSE core.fn_inventory_user_name(p.cancelled_by) END AS cancelled_by_name,
               COALESCE(to_char(p.cancelled_at, 'YYYY-MM-DD HH24:MI'), '') AS cancelled_at,
               (SELECT COALESCE(SUM(r.amount), 0) FROM core.inventory_purchase_returns r
                 WHERE r.purchase_id = p.purchase_id) AS returned_amount
        FROM core.inventory_purchases p
        LEFT JOIN core.inventory_locations loc ON loc.location_id = p.location_id
        WHERE p.tenant_id = p_tenant_id AND p.school_id = p_school_id
          AND p.purchase_id = p_purchase_id;

        OPEN p_result2 FOR
        SELECT pi.purchase_item_id, pi.item_id, COALESCE(pi.item_name,'') AS item_name,
               pi.quantity, pi.unit_price, pi.tax_percent, pi.line_total,
               COALESCE(i.unit_type, '') AS unit_type,
               COALESCE(r.qty, 0) AS returned_qty,
               COALESCE(r.amt, 0) AS returned_amount
        FROM core.inventory_purchase_items pi
        LEFT JOIN core.inventory_items i ON i.item_id = pi.item_id
        LEFT JOIN (SELECT purchase_item_id, SUM(quantity) AS qty, SUM(amount) AS amt
                   FROM core.inventory_purchase_returns GROUP BY purchase_item_id) r
               ON r.purchase_item_id = pi.purchase_item_id
        WHERE pi.tenant_id = p_tenant_id AND pi.school_id = p_school_id
          AND pi.purchase_id = p_purchase_id
        ORDER BY pi.purchase_item_id;
        RETURN;

    ELSIF v_op = 'RETURNS' THEN
        -- The returns to supplier made against one bill. (Its own operation, not
        -- a third cursor on GET: an extra INOUT parameter would break every
        -- existing CALL that passes only p_result and p_result2.)
        OPEN p_result FOR
        SELECT r.return_id, r.return_date, r.purchase_item_id, r.item_id,
               COALESCE(pi.item_name, '') AS item_name,
               r.quantity, r.unit_price, r.tax_percent, r.amount, r.reason,
               COALESCE(loc.location_name, '') AS location_name,
               core.fn_inventory_user_name(r.created_by) AS created_by_name,
               to_char(r.created_at, 'YYYY-MM-DD HH24:MI') AS created_at
        FROM core.inventory_purchase_returns r
        JOIN core.inventory_purchase_items pi ON pi.purchase_item_id = r.purchase_item_id
        LEFT JOIN core.inventory_locations loc ON loc.location_id = r.location_id
        WHERE r.tenant_id = p_tenant_id AND r.school_id = p_school_id
          AND r.purchase_id = p_purchase_id
        ORDER BY r.return_id;
        OPEN p_result2 FOR SELECT 1 WHERE FALSE;
        RETURN;

    ELSIF v_op = 'SAVE' THEN
        IF p_purchase_date IS NULL THEN
            RAISE EXCEPTION 'Choose the purchase date.';
        END IF;
        -- CURRENT_DATE is the school's date: the database runs on its timezone.
        IF p_purchase_date > CURRENT_DATE THEN
            RAISE EXCEPTION 'A purchase cannot be dated in the future.';
        END IF;
        IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
            RAISE EXCEPTION 'Add at least one item to the purchase.';
        END IF;

        SELECT supplier_name, is_active INTO v_supp, v_sactive FROM core.inventory_suppliers
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND supplier_id = p_supplier_id AND is_deleted = FALSE;

        -- Every new bill names who supplied it (old bills without one stay as they are).
        IF p_supplier_id IS NULL THEN
            RAISE EXCEPTION 'Choose the supplier. No fixed shop? Add one called "Local market".';
        END IF;
        IF v_supp IS NULL THEN
            RAISE EXCEPTION 'Supplier not found.';
        END IF;
        -- An inactive supplier keeps its old bills but takes no new ones.
        IF p_supplier_id IS NOT NULL AND NOT v_sactive THEN
            RAISE EXCEPTION 'Supplier % is inactive and cannot be used for a new bill. Make it active first.', v_supp;
        END IF;

        -- The goods go into the chosen location, else the default one.
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
            RAISE EXCEPTION '% is inactive. Choose an active location for the goods.', v_lname;
        END IF;

        -- The same bill cannot go in twice -- per supplier, and among bills with
        -- no supplier too (supplier 0 here, matching the unique index).
        IF v_inv IS NOT NULL THEN
            SELECT purchase_date INTO v_dup FROM core.inventory_purchases
            WHERE tenant_id = p_tenant_id AND school_id = p_school_id
              AND is_cancelled = FALSE
              AND COALESCE(supplier_id, 0) = COALESCE(p_supplier_id, 0)
              AND LOWER(TRIM(invoice_no)) = LOWER(v_inv)
            LIMIT 1;
            IF v_dup IS NOT NULL THEN
                RAISE EXCEPTION 'Bill % from % is already entered (dated %).',
                    v_inv, COALESCE(v_supp, 'no supplier'), v_dup;
            END IF;
        END IF;

        -- Every line must name an active item of THIS school, checked before
        -- anything is written, so a bad line cannot leave a half-purchase.
        FOR v_line IN
            SELECT * FROM jsonb_to_recordset(p_items)
                AS x("itemId" integer, quantity numeric, "unitPrice" numeric, "taxPercent" numeric)
        LOOP
            IF COALESCE(v_line.quantity, 0) <= 0 THEN
                RAISE EXCEPTION 'Every line needs a quantity greater than zero.';
            END IF;
            IF v_line.quantity <> ROUND(v_line.quantity, 2) THEN
                RAISE EXCEPTION 'A quantity can have at most 2 decimal places.';
            END IF;
            IF COALESCE(v_line."unitPrice", 0) < 0 THEN
                RAISE EXCEPTION 'A unit price cannot be negative.';
            END IF;
            IF COALESCE(v_line."unitPrice", 0) <> ROUND(COALESCE(v_line."unitPrice", 0), 2) THEN
                RAISE EXCEPTION 'A unit price can have at most 2 decimal places.';
            END IF;
            IF COALESCE(v_line."taxPercent", 0) < 0 OR COALESCE(v_line."taxPercent", 0) > 100 THEN
                RAISE EXCEPTION 'Tax must be between 0 and 100 percent.';
            END IF;

            v_name := NULL; v_active := NULL;
            SELECT item_name, is_active INTO v_name, v_active FROM core.inventory_items
            WHERE tenant_id = p_tenant_id AND school_id = p_school_id
              AND item_id = v_line."itemId" AND is_deleted = FALSE;

            IF v_name IS NULL THEN
                RAISE EXCEPTION 'One of the lines is not an item of this school.';
            END IF;
            IF NOT v_active THEN
                RAISE EXCEPTION '% is marked Inactive and cannot be purchased. Make it Active first.', v_name;
            END IF;
        END LOOP;

        INSERT INTO core.inventory_purchases
            (tenant_id, school_id, supplier_id, supplier_name, purchase_date,
             invoice_no, payment_mode, remarks, location_id, created_by)
        VALUES (p_tenant_id, p_school_id, p_supplier_id, v_supp, p_purchase_date,
                v_inv,
                NULLIF(TRIM(COALESCE(p_payment_mode,'')),''),
                v_reason, v_loc, p_action_user_id)
        RETURNING purchase_id INTO v_pid;

        FOR v_line IN
            SELECT * FROM jsonb_to_recordset(p_items)
                AS x("itemId" integer, quantity numeric, "unitPrice" numeric, "taxPercent" numeric)
        LOOP
            -- Lock the item; the movement helper re-reads it, so the same item
            -- on two lines adds up.
            SELECT item_name INTO v_name
            FROM core.inventory_items
            WHERE item_id = v_line."itemId" FOR UPDATE;

            -- Each line is rounded once, and the header is the sum of the lines,
            -- so the bill's total always equals the totals printed on its lines.
            v_base := ROUND(v_line.quantity * COALESCE(v_line."unitPrice", 0), 2);
            v_ltax := ROUND(v_base * COALESCE(v_line."taxPercent", 0) / 100.0, 2);

            INSERT INTO core.inventory_purchase_items
                (tenant_id, school_id, purchase_id, item_id, item_name,
                 quantity, unit_price, tax_percent, line_total)
            VALUES (p_tenant_id, p_school_id, v_pid, v_line."itemId", v_name,
                    v_line.quantity, COALESCE(v_line."unitPrice", 0),
                    COALESCE(v_line."taxPercent", 0), v_base + v_ltax)
            RETURNING purchase_item_id INTO v_cnt;

            -- The movement names its bill AND its bill line.
            PERFORM core.fn_inventory_post_movement(
                p_tenant_id, p_school_id, p_action_user_id, v_line."itemId", v_loc,
                'Purchase', v_line.quantity, COALESCE(v_line."unitPrice", 0),
                'Purchase', v_pid, v_cnt, p_date => p_purchase_date);

            v_sub := v_sub + v_base;
            v_tax := v_tax + v_ltax;
        END LOOP;

        UPDATE core.inventory_purchases
           SET sub_total = v_sub, tax_total = v_tax, grand_total = v_sub + v_tax
         WHERE purchase_id = v_pid;

        OPEN p_result FOR
            SELECT TRUE AS success, 'Purchase saved.' AS message,
                   v_pid AS purchase_id, v_sub + v_tax AS grand_total;
        OPEN p_result2 FOR SELECT 1 WHERE FALSE;
        RETURN;

    -- ── Return to supplier ──────────────────────────────────────────────────
    -- p_items = [{"purchaseItemId": n, "quantity": q}, ...], p_remarks = reason.
    -- Takes stock out at the location the bill went into. Per line: no more
    -- than bought minus already returned. Per item: no more than that location
    -- holds now.
    ELSIF v_op = 'RETURN' THEN
        IF v_reason IS NULL THEN
            RAISE EXCEPTION 'Give a reason for the return.';
        END IF;
        IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
            RAISE EXCEPTION 'Choose at least one line to return.';
        END IF;

        -- Lock the bill: a return and a cancel of the same bill queue up.
        SELECT is_cancelled, location_id INTO v_cancel, v_loc
        FROM core.inventory_purchases
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND purchase_id = p_purchase_id
        FOR UPDATE;
        IF v_cancel IS NULL THEN
            RAISE EXCEPTION 'Purchase not found.';
        END IF;
        IF v_cancel THEN
            RAISE EXCEPTION 'This purchase is cancelled, so nothing on it can be returned.';
        END IF;
        v_loc := COALESCE(v_loc, core.fn_inventory_default_location(p_tenant_id, p_school_id, p_action_user_id));
        SELECT location_name INTO v_lname FROM core.inventory_locations WHERE location_id = v_loc;

        -- Each requested line on its own: a real quantity, on THIS bill.
        FOR v_line IN
            SELECT * FROM jsonb_to_recordset(p_items) AS x("purchaseItemId" integer, quantity numeric)
        LOOP
            IF COALESCE(v_line.quantity, 0) <= 0 THEN
                RAISE EXCEPTION 'Every returned line needs a quantity greater than zero.';
            END IF;
            IF v_line.quantity <> ROUND(v_line.quantity, 2) THEN
                RAISE EXCEPTION 'A quantity can have at most 2 decimal places.';
            END IF;
            IF NOT EXISTS (SELECT 1 FROM core.inventory_purchase_items
                           WHERE purchase_item_id = v_line."purchaseItemId"
                             AND purchase_id = p_purchase_id) THEN
                RAISE EXCEPTION 'One of the lines is not on this bill.';
            END IF;
        END LOOP;

        -- Lock the items in a fixed order.
        PERFORM 1 FROM core.inventory_items
        WHERE item_id IN (SELECT item_id FROM core.inventory_purchase_items WHERE purchase_id = p_purchase_id)
        ORDER BY item_id
        FOR UPDATE;

        -- Per LINE (the same line twice in one request adds up): bought minus
        -- already returned.
        FOR v_line IN
            SELECT pi.purchase_item_id, pi.item_name, pi.quantity AS bought, i.unit_type,
                   COALESCE((SELECT SUM(r.quantity) FROM core.inventory_purchase_returns r
                             WHERE r.purchase_item_id = pi.purchase_item_id), 0) AS returned,
                   x.qty
            FROM (SELECT "purchaseItemId" AS pid, SUM(quantity) AS qty
                  FROM jsonb_to_recordset(p_items) AS j("purchaseItemId" integer, quantity numeric)
                  GROUP BY "purchaseItemId") x
            JOIN core.inventory_purchase_items pi ON pi.purchase_item_id = x.pid
            JOIN core.inventory_items i ON i.item_id = pi.item_id
        LOOP
            IF v_line.qty > v_line.bought - v_line.returned THEN
                RAISE EXCEPTION 'Only % % of % can still be returned on this bill (bought %, already returned %).',
                    trim_scale(v_line.bought - v_line.returned)::text, v_line.unit_type,
                    v_line.item_name,
                    trim_scale(v_line.bought)::text,
                    trim_scale(v_line.returned)::text;
            END IF;
        END LOOP;

        -- Per ITEM (two lines of one item come out of the same shelf): what the
        -- location holds now.
        FOR v_line IN
            SELECT i.item_name, i.unit_type, SUM(x.qty) AS qty,
                   COALESCE((SELECT s.quantity FROM core.inventory_location_stock s
                             WHERE s.item_id = i.item_id AND s.location_id = v_loc), 0) AS at_loc
            FROM (SELECT "purchaseItemId" AS pid, SUM(quantity) AS qty
                  FROM jsonb_to_recordset(p_items) AS j("purchaseItemId" integer, quantity numeric)
                  GROUP BY "purchaseItemId") x
            JOIN core.inventory_purchase_items pi ON pi.purchase_item_id = x.pid
            JOIN core.inventory_items i ON i.item_id = pi.item_id
            GROUP BY i.item_id, i.item_name, i.unit_type
        LOOP
            IF v_line.at_loc < v_line.qty THEN
                RAISE EXCEPTION 'Cannot return: only % % of % left at %.',
                    trim_scale(v_line.at_loc)::text, v_line.unit_type,
                    v_line.item_name, v_lname;
            END IF;
        END LOOP;

        -- Write: one return row and one ledger row per line.
        FOR v_line IN
            SELECT pi.purchase_item_id, pi.item_id, pi.unit_price, pi.tax_percent, x.qty
            FROM (SELECT "purchaseItemId" AS pid, SUM(quantity) AS qty
                  FROM jsonb_to_recordset(p_items) AS j("purchaseItemId" integer, quantity numeric)
                  GROUP BY "purchaseItemId") x
            JOIN core.inventory_purchase_items pi ON pi.purchase_item_id = x.pid
            ORDER BY pi.purchase_item_id
        LOOP
            -- Valued like a bill line: base and tax each rounded once.
            v_base := ROUND(v_line.qty * v_line.unit_price, 2);
            v_ltax := ROUND(v_base * v_line.tax_percent / 100.0, 2);

            INSERT INTO core.inventory_purchase_returns
                (tenant_id, school_id, purchase_id, purchase_item_id, item_id, location_id,
                 quantity, unit_price, tax_percent, amount, reason, created_by)
            VALUES (p_tenant_id, p_school_id, p_purchase_id, v_line.purchase_item_id,
                    v_line.item_id, v_loc, v_line.qty, v_line.unit_price, v_line.tax_percent,
                    v_base + v_ltax, v_reason, p_action_user_id);

            PERFORM core.fn_inventory_post_movement(
                p_tenant_id, p_school_id, p_action_user_id, v_line.item_id, v_loc,
                'SupplierReturn', -v_line.qty, v_line.unit_price,
                'Purchase', p_purchase_id, v_line.purchase_item_id,
                p_remarks => v_reason);

            v_amt := v_amt + v_base + v_ltax;
            v_cnt := COALESCE(v_cnt, 0) + 1;
        END LOOP;

        OPEN p_result FOR
            SELECT TRUE AS success,
                   format('Returned %s line(s) to the supplier, worth %s.', v_cnt,
                          TRIM(TO_CHAR(v_amt, 'FM999999990.00'))) AS message,
                   p_purchase_id AS purchase_id, v_amt AS grand_total;
        OPEN p_result2 FOR SELECT 1 WHERE FALSE;
        RETURN;

    ELSIF v_op = 'CANCEL' THEN
        -- A purchase is never edited, only cancelled, and cancelling reverses its
        -- stock with matching negative movements rather than deleting the
        -- originals. The invoice and its reversal both stay on the record.
        --
        -- With returns: only the REMAINDER of each line (bought - returned) is
        -- reversed. The returned part already left the shelf with its own
        -- 'SupplierReturn' row; reversing it again would take it out twice.
        IF v_reason IS NULL THEN
            RAISE EXCEPTION 'Give a reason for cancelling this purchase.';
        END IF;

        SELECT location_id INTO v_loc FROM core.inventory_purchases
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND purchase_id = p_purchase_id AND is_cancelled = FALSE
        FOR UPDATE;
        GET DIAGNOSTICS v_cnt = ROW_COUNT;

        IF v_cnt = 0 THEN
            RAISE EXCEPTION 'Purchase not found, or already cancelled.';
        END IF;
        v_loc := COALESCE(v_loc, core.fn_inventory_default_location(p_tenant_id, p_school_id, p_action_user_id));
        SELECT location_name INTO v_lname FROM core.inventory_locations WHERE location_id = v_loc;

        -- Lock the bill's items first, in a fixed order.
        PERFORM 1 FROM core.inventory_items
        WHERE item_id IN (SELECT item_id FROM core.inventory_purchase_items
                          WHERE purchase_id = p_purchase_id)
        ORDER BY item_id
        FOR UPDATE;

        -- Check per ITEM, not per line: a bill with the same item on two lines
        -- has to take both lines out of what is on the shelf now -- the shelf
        -- being the location the bill went into.
        FOR v_line IN
            SELECT i.item_name, i.unit_type,
                   COALESCE((SELECT s.quantity FROM core.inventory_location_stock s
                             WHERE s.item_id = i.item_id AND s.location_id = v_loc), 0) AS at_loc,
                   SUM(pi.quantity - COALESCE((SELECT SUM(r.quantity) FROM core.inventory_purchase_returns r
                                               WHERE r.purchase_item_id = pi.purchase_item_id), 0)) AS qty
            FROM core.inventory_purchase_items pi
            JOIN core.inventory_items i ON i.item_id = pi.item_id
            WHERE pi.purchase_id = p_purchase_id
            GROUP BY i.item_id, i.item_name, i.unit_type
        LOOP
            -- Refusing here is the honest answer: the goods have already been
            -- issued (or moved), so the purchase cannot simply be un-received.
            IF v_line.at_loc - v_line.qty < 0 THEN
                RAISE EXCEPTION 'Cannot cancel: only % % of % left, and this purchase brought in % to %.',
                    trim_scale(v_line.at_loc)::text, v_line.unit_type,
                    v_line.item_name, trim_scale(v_line.qty)::text, v_lname;
            END IF;
        END LOOP;

        -- Reverse line by line; the helper re-reads the stock each time, so a
        -- second line for the same item starts from the first line's result.
        FOR v_line IN
            SELECT pi.purchase_item_id, pi.item_id, pi.unit_price,
                   pi.quantity - COALESCE((SELECT SUM(r.quantity) FROM core.inventory_purchase_returns r
                                           WHERE r.purchase_item_id = pi.purchase_item_id), 0) AS qty
            FROM core.inventory_purchase_items pi
            WHERE pi.purchase_id = p_purchase_id
            ORDER BY pi.purchase_item_id
        LOOP
            IF v_line.qty > 0 THEN
                PERFORM core.fn_inventory_post_movement(
                    p_tenant_id, p_school_id, p_action_user_id, v_line.item_id, v_loc,
                    'PurchaseCancel', -v_line.qty, v_line.unit_price,
                    'Purchase', p_purchase_id, v_line.purchase_item_id,
                    p_remarks => v_reason);
            END IF;
        END LOOP;

        SELECT COALESCE(SUM(quantity), 0) INTO v_ret
        FROM core.inventory_purchase_returns WHERE purchase_id = p_purchase_id;

        UPDATE core.inventory_purchases
           SET is_cancelled = TRUE,
               cancel_reason = v_reason,
               cancelled_by = p_action_user_id, cancelled_at = now()
         WHERE purchase_id = p_purchase_id;

        OPEN p_result FOR
            SELECT TRUE AS success,
                   CASE WHEN v_ret > 0
                        THEN 'Purchase cancelled. What was already returned to the supplier stays returned; only the rest was taken out of stock.'
                        ELSE 'Purchase cancelled.' END AS message;
        OPEN p_result2 FOR SELECT 1 WHERE FALSE;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation %.', p_operation;
END;
$$;
