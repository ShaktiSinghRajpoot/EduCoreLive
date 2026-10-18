-- Bundle 2026-10-18h: Books & Uniform Register overview for store staff (core.sp_inventory_register_overview). Run with:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_18h.sql
-- Sources: inventory_student_sale.sql

-- ============================================================================
-- Books & uniform: the store sells to a student, the fee account carries it.
--
-- Builds on inventory.sql (items, stock by location, the stock ledger). An item
-- the school sells is an Inventory item of type 'Saleable' with a selling price
-- (Inventory › Items & Stock). Uniform sizes are separate items ("Shirt - 32").
--
--   * Selling takes the items off the shelf (an 'Issue' movement per item, so
--     the stock ledger says who got what) AND adds one fee line per item to the
--     student's ledger (core.student_ledger, frequency 'One Time', due today).
--     The parent pays now or later like any other fee: Collect Fees, the receipt,
--     the due list and reminders all see it without knowing about the store.
--     The fee line's session is the one the items are for: a child promoted
--     early who buys next year's books in March is charged in 2027-28.
--   * WHICH CLASS an item is for is set on the item itself (inventory_items.for_class:
--     empty = every class, else one class name). Picking a student ticks one of each
--     item for their class; an item sold in sizes ("Uniform - 24", "- 28" ...) is not
--     ticked, the store picks the size. (2026-10-18: this replaced the separate
--     "class sets" screen; core.inventory_class_kits is kept but no longer read.)
--   * Return (exchange a size, a wrong book): only while the fee line is unpaid.
--     The fee line is closed (core.fn_ledger_close, source 'Store') and the items
--     go back on the shelf ('Return' movement). A paid line must have its receipt
--     cancelled first, so money and stock never disagree.
--
--   core.sp_inventory_student_sale
--     Items    (p_academic_year + p_class -> that class's set) saleable items with price, stock, set qty
--     Student  (p_student_id)   the child, and their class in this and any later session
--     Sell     (p_student_id, p_academic_year, p_location_id, p_items [{itemId, qty}])
--     Return   (p_line_id, p_reason)
--     List     (p_student_id optional) the latest sales, line by line, paid or not
--     SaveKit  (p_class, p_items [{itemId, qty}]) replaces the class set
--
-- Needs inventory.sql, student_money_lifecycle.sql (fn_ledger_close) and
-- student_attendance.sql (fn_session_on). Re-runnable.
-- ============================================================================

CREATE TABLE IF NOT EXISTS core.inventory_class_kits (
    kit_line_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   integer NOT NULL,
    school_id   integer NOT NULL,
    class_name  varchar(50) NOT NULL,
    item_id     integer NOT NULL REFERENCES core.inventory_items(item_id),
    quantity    numeric(14,2) NOT NULL DEFAULT 1,
    updated_by  integer,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT chk_inv_kit_qty CHECK (quantity >= 0),     -- 0 = taken out of the set (rows are never deleted)
    CONSTRAINT uq_inv_kit_item UNIQUE (tenant_id, school_id, class_name, item_id)
);
-- The first version refused 0 and deleted rows on save; store rows are never hard-deleted.
ALTER TABLE core.inventory_class_kits DROP CONSTRAINT IF EXISTS chk_inv_kit_qty;
ALTER TABLE core.inventory_class_kits ADD CONSTRAINT chk_inv_kit_qty CHECK (quantity >= 0);

-- Which class a saleable item is for: NULL = every class.
ALTER TABLE core.inventory_items ADD COLUMN IF NOT EXISTS for_class varchar(50);

-- Moving from class sets: an item that was in exactly one class's set is for that
-- class; everything else stays "every class". Only items not yet set are touched.
UPDATE core.inventory_items i
   SET for_class = k.class_name
  FROM (SELECT item_id, MIN(class_name) AS class_name
          FROM core.inventory_class_kits WHERE quantity > 0
         GROUP BY item_id HAVING COUNT(DISTINCT class_name) = 1) k
 WHERE i.item_id = k.item_id AND i.for_class IS NULL;

-- "Uniform - 28" -> "Uniform": the name before the LAST " - " (sizes are separate
-- items with the size after it). A name without " - " is returned as it is.
CREATE OR REPLACE FUNCTION core.fn_item_base_name(p_name text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $function$
    SELECT CASE WHEN position(' - ' IN p_name) > 0
                THEN trim(left(p_name, length(p_name) - position(' - ' IN reverse(p_name)) - 2))
                ELSE p_name END;
$function$;

CREATE TABLE IF NOT EXISTS core.inventory_student_sales (
    sale_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     integer NOT NULL,
    school_id     integer NOT NULL,
    student_id    integer NOT NULL REFERENCES core.students(student_id),
    sale_date     date NOT NULL DEFAULT CURRENT_DATE,
    academic_year varchar(20),
    class_name    varchar(50),
    location_id   integer,
    total         numeric(12,2) NOT NULL DEFAULT 0,
    created_by    integer NOT NULL DEFAULT 0,
    created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_inv_student_sales ON core.inventory_student_sales (tenant_id, school_id, sale_date DESC);

CREATE TABLE IF NOT EXISTS core.inventory_student_sale_lines (
    line_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sale_id       integer NOT NULL REFERENCES core.inventory_student_sales(sale_id),
    item_id       integer NOT NULL REFERENCES core.inventory_items(item_id),
    quantity      numeric(14,2) NOT NULL,
    unit_price    numeric(14,2) NOT NULL,
    amount        numeric(12,2) NOT NULL,
    ledger_id     integer,                 -- the fee line it put on the student's account
    returned_at   timestamptz,
    returned_by   integer,
    return_reason varchar(200),
    CONSTRAINT chk_inv_sale_qty CHECK (quantity > 0)
);
CREATE INDEX IF NOT EXISTS ix_inv_sale_lines_sale ON core.inventory_student_sale_lines (sale_id);


DROP PROCEDURE IF EXISTS core.sp_inventory_student_sale(varchar, integer, integer, integer, integer, varchar, varchar,
                                                         integer, jsonb, integer, varchar, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_inventory_student_sale(
    IN    p_operation      varchar,
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_student_id     integer DEFAULT NULL,
    IN    p_academic_year  varchar DEFAULT NULL,
    IN    p_class          varchar DEFAULT NULL,
    IN    p_location_id    integer DEFAULT NULL,
    IN    p_items          jsonb   DEFAULT NULL,   -- [{"itemId": 5, "qty": 2}, ...]
    IN    p_line_id        integer DEFAULT NULL,
    IN    p_reason         varchar DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'student_sale_cursor'::refcursor,
    IN    p_item_id        integer DEFAULT NULL)   -- SetItemClass / ItemClass (last, so older callers still fit)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_today   date := CURRENT_DATE;
    v_current varchar := core.fn_session_on(p_tenant_id, p_school_id, CURRENT_DATE);
    v_loc     integer;
    v_sale    integer;
    v_total   numeric(12,2) := 0;
    v_ledger  integer;
    v_stock   numeric;
    v_name    text;
    v_class   varchar;
    v_year    varchar;
    v_n       integer := 0;
    r         record;
    it        record;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    -- ── Items: what the store sells. With p_class: only the items for that class
    --    (or every class), and kit_qty 1 on each one to tick -- not on an item sold
    --    in sizes, where the store picks the size.
    IF p_operation = 'Items' THEN
        v_loc := COALESCE(p_location_id, core.fn_inventory_default_location(p_tenant_id, p_school_id, p_action_user_id));
        OPEN p_result FOR
        SELECT i.item_id, i.item_name, COALESCE(NULLIF(trim(i.category), ''), 'Other') AS category,
               i.unit_type, i.selling_price, i.for_class,
               COALESCE((SELECT ls.quantity FROM core.inventory_location_stock ls
                          WHERE ls.item_id = i.item_id AND ls.location_id = v_loc), 0) AS in_stock,
               CASE WHEN p_class IS NULL THEN 0
                    WHEN EXISTS (SELECT 1 FROM core.inventory_items x
                                  WHERE x.tenant_id = i.tenant_id AND x.school_id = i.school_id AND x.item_id <> i.item_id
                                    AND NOT x.is_deleted AND x.is_active AND x.item_type = 'Saleable'
                                    AND core.fn_item_base_name(x.item_name) = core.fn_item_base_name(i.item_name)) THEN 0
                    ELSE 1 END AS kit_qty
          FROM core.inventory_items i
         WHERE i.tenant_id = p_tenant_id AND i.school_id = p_school_id
           AND NOT i.is_deleted AND i.is_active AND i.item_type = 'Saleable'
           AND (p_class IS NULL OR i.for_class IS NULL OR i.for_class = p_class)
         ORDER BY 3, i.item_name;
        RETURN;
    END IF;

    -- ── Which class an item is for (NULL = every class)
    IF p_operation = 'ItemClass' THEN
        OPEN p_result FOR
        SELECT i.item_id, i.for_class FROM core.inventory_items i
         WHERE i.item_id = p_item_id AND i.tenant_id = p_tenant_id AND i.school_id = p_school_id;
        RETURN;
    END IF;
    IF p_operation = 'SetItemClass' THEN
        UPDATE core.inventory_items
           SET for_class = CASE WHEN NULLIF(trim(p_class), '') IS NULL OR trim(p_class) = 'All' THEN NULL ELSE left(trim(p_class), 50) END
         WHERE item_id = p_item_id AND tenant_id = p_tenant_id AND school_id = p_school_id;
        OPEN p_result FOR SELECT TRUE AS success, 'Saved.' AS message;
        RETURN;
    END IF;

    -- ── Student: the child, and their class in this and any later session
    IF p_operation = 'Student' THEN
        OPEN p_result FOR
        SELECT s.student_id, s.student_name, s.admission_no,
               e.academic_year, e.class_name, e.section,
               (e.academic_year = v_current) AS is_current
          FROM core.students s
          JOIN core.student_enrolment e ON e.student_id = s.student_id
         WHERE s.student_id = p_student_id AND s.tenant_id = p_tenant_id AND s.school_id = p_school_id
           AND COALESCE(s.is_active, TRUE)
           AND COALESCE(e.status, '') NOT IN ('Left', 'PassedOut')
           AND (v_current IS NULL OR e.academic_year >= v_current)
         ORDER BY e.academic_year;
        RETURN;
    END IF;

    -- ── Sell: off the shelf, onto the fee account
    IF p_operation = 'Sell' THEN
        SELECT s.student_name || ' (' || COALESCE(s.admission_no, '-') || ')' INTO v_name
          FROM core.students s
         WHERE s.student_id = p_student_id AND s.tenant_id = p_tenant_id AND s.school_id = p_school_id
           AND COALESCE(s.is_active, TRUE);
        IF v_name IS NULL THEN
            RAISE EXCEPTION 'Student not found, or has left the school.';
        END IF;

        v_year := COALESCE(NULLIF(trim(p_academic_year), ''), v_current);
        SELECT e.class_name INTO v_class FROM core.student_enrolment e
         WHERE e.student_id = p_student_id AND e.academic_year = v_year
           AND COALESCE(e.status, '') NOT IN ('Left', 'PassedOut');
        IF v_class IS NULL THEN
            RAISE EXCEPTION 'The student is not enrolled in %.', v_year;
        END IF;

        IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array'
           OR NOT EXISTS (SELECT 1 FROM jsonb_to_recordset(p_items) AS x("itemId" integer, qty numeric) WHERE x.qty > 0) THEN
            RAISE EXCEPTION 'Choose at least one item.';
        END IF;

        v_loc := COALESCE(p_location_id, core.fn_inventory_default_location(p_tenant_id, p_school_id, p_action_user_id));

        INSERT INTO core.inventory_student_sales (tenant_id, school_id, student_id, academic_year, class_name, location_id, created_by)
        VALUES (p_tenant_id, p_school_id, p_student_id, v_year, v_class, v_loc, p_action_user_id)
        RETURNING sale_id INTO v_sale;

        -- the same item twice in the list counts once, with the quantities added
        FOR r IN
            SELECT x."itemId" AS item_id, SUM(x.qty) AS qty
              FROM jsonb_to_recordset(p_items) AS x("itemId" integer, qty numeric)
             WHERE x.qty > 0
             GROUP BY x."itemId"
        LOOP
            SELECT i.item_id, i.item_name, i.unit_type, i.selling_price, i.cost_price,
                   COALESCE(NULLIF(trim(i.category), ''), 'Store') AS category
              INTO it
              FROM core.inventory_items i
             WHERE i.item_id = r.item_id AND i.tenant_id = p_tenant_id AND i.school_id = p_school_id
               AND NOT i.is_deleted AND i.is_active AND i.item_type = 'Saleable';
            IF it.item_id IS NULL THEN
                RAISE EXCEPTION 'An item in the list is not for sale any more. Reload the page.';
            END IF;
            IF r.qty <> round(r.qty, 2) THEN
                RAISE EXCEPTION 'Quantity of % takes at most 2 decimals.', it.item_name;
            END IF;
            IF it.selling_price <= 0 THEN
                RAISE EXCEPTION '% has no selling price. Set it on Inventory › Items & Stock.', it.item_name;
            END IF;

            SELECT COALESCE((SELECT ls.quantity FROM core.inventory_location_stock ls
                              WHERE ls.item_id = it.item_id AND ls.location_id = v_loc), 0) INTO v_stock;
            IF v_stock < r.qty THEN
                RAISE EXCEPTION 'Only % % of % left in this store.', trim(to_char(v_stock, 'FM999999990.##')), it.unit_type, it.item_name;
            END IF;

            PERFORM core.fn_inventory_post_movement(
                p_tenant_id, p_school_id, p_action_user_id, it.item_id, v_loc, 'Issue', -r.qty, it.cost_price,
                'StudentSale', v_sale, NULL, v_name, 'Sold to student');

            -- the fee line reads like the item: head "Uniform", label "24 × 2" (size
            -- and quantity), so a receipt says "Uniform — 24" and not "Uniform — Uniform - 24"
            INSERT INTO core.student_ledger
                (tenant_id, school_id, student_id, fee_head_name, frequency, installment_label,
                 due_date, amount_due, status, academic_year)
            VALUES (p_tenant_id, p_school_id, p_student_id, core.fn_item_base_name(it.item_name), 'One Time',
                    NULLIF(concat_ws(' ',
                        CASE WHEN position(' - ' IN it.item_name) > 0
                             THEN trim(right(it.item_name, position(' - ' IN reverse(it.item_name)) - 1)) END,
                        CASE WHEN r.qty <> 1 THEN '× ' || trim(to_char(r.qty, 'FM999999990.##')) END), ''),
                    to_char(v_today, 'YYYY-MM-DD'), round(r.qty * it.selling_price, 2), 'Pending', v_year)
            RETURNING ledger_id INTO v_ledger;

            INSERT INTO core.inventory_student_sale_lines (sale_id, item_id, quantity, unit_price, amount, ledger_id)
            VALUES (v_sale, it.item_id, r.qty, it.selling_price, round(r.qty * it.selling_price, 2), v_ledger);

            v_total := v_total + round(r.qty * it.selling_price, 2);
            v_n := v_n + 1;
        END LOOP;

        UPDATE core.inventory_student_sales SET total = v_total WHERE sale_id = v_sale;

        OPEN p_result FOR
        SELECT TRUE AS success, v_sale AS sale_id, v_total AS total, v_year AS academic_year,
               v_n || ' item(s) given, Rs ' || to_char(v_total, 'FM99,99,99,990.00') || ' added to the fee account (' || v_year || ').' AS message;
        RETURN;
    END IF;

    -- ── Return: unpaid only; the fee line closes and the items go back on the shelf
    IF p_operation = 'Return' THEN
        IF NULLIF(trim(p_reason), '') IS NULL THEN
            RAISE EXCEPTION 'Give a reason for the return (wrong size, wrong book ...).';
        END IF;

        SELECT l.line_id, l.item_id, l.quantity, l.ledger_id, l.returned_at, sa.location_id, sa.student_id,
               i.item_name, st.student_name || ' (' || COALESCE(st.admission_no, '-') || ')' AS who,
               sl.amount_paid, sl.concession
          INTO r
          FROM core.inventory_student_sale_lines l
          JOIN core.inventory_student_sales sa ON sa.sale_id = l.sale_id
          JOIN core.inventory_items i ON i.item_id = l.item_id
          JOIN core.students st ON st.student_id = sa.student_id
          LEFT JOIN core.student_ledger sl ON sl.ledger_id = l.ledger_id
         WHERE l.line_id = p_line_id AND sa.tenant_id = p_tenant_id AND sa.school_id = p_school_id
           FOR UPDATE OF l;
        IF r.line_id IS NULL THEN
            RAISE EXCEPTION 'Sale line not found.';
        END IF;
        IF r.returned_at IS NOT NULL THEN
            RAISE EXCEPTION '% was already returned.', r.item_name;
        END IF;
        IF COALESCE(r.amount_paid, 0) > 0 OR COALESCE(r.concession, 0) > 0 THEN
            RAISE EXCEPTION '% is already paid (fully or in part). Cancel that receipt first, then return it.', r.item_name;
        END IF;

        IF r.ledger_id IS NOT NULL THEN
            PERFORM core.fn_ledger_close(r.ledger_id, left('Returned to store: ' || trim(p_reason), 200), 'Store', p_action_user_id);
        END IF;
        PERFORM core.fn_inventory_post_movement(
            p_tenant_id, p_school_id, p_action_user_id, r.item_id, r.location_id, 'Return', r.quantity, NULL,
            'StudentSale', p_line_id, NULL, r.who, left('Returned: ' || trim(p_reason), 200));

        UPDATE core.inventory_student_sale_lines
           SET returned_at = now(), returned_by = p_action_user_id, return_reason = left(trim(p_reason), 200)
         WHERE line_id = p_line_id;

        OPEN p_result FOR SELECT TRUE AS success, r.item_name || ' returned. It is off the fee account and back in stock.' AS message;
        RETURN;
    END IF;

    -- ── List: the latest sales, line by line
    IF p_operation = 'List' THEN
        OPEN p_result FOR
        SELECT l.line_id, sa.sale_id, sa.sale_date::text AS sale_date, sa.student_id,
               st.student_name, st.admission_no, sa.class_name, sa.academic_year,
               i.item_name, l.quantity, l.unit_price, l.amount,
               COALESCE(sl.amount_paid, 0) AS paid,
               COALESCE(sl.amount_due - sl.amount_paid - sl.concession, 0) AS open_amount,
               l.returned_at IS NOT NULL AS returned, l.return_reason,
               core.fn_user_display_name(sa.created_by) AS sold_by
          FROM core.inventory_student_sale_lines l
          JOIN core.inventory_student_sales sa ON sa.sale_id = l.sale_id
          JOIN core.students st ON st.student_id = sa.student_id
          JOIN core.inventory_items i ON i.item_id = l.item_id
          LEFT JOIN core.student_ledger sl ON sl.ledger_id = l.ledger_id
         WHERE sa.tenant_id = p_tenant_id AND sa.school_id = p_school_id
           AND (p_student_id IS NULL OR sa.student_id = p_student_id)
         ORDER BY sa.sale_id DESC, l.line_id
         LIMIT 300;
        RETURN;
    END IF;

    -- ── SaveKit: replace one class's set. Store rows are never deleted: an item
    --    taken out of the set keeps its row with quantity 0.
    IF p_operation = 'SaveKit' THEN
        IF NULLIF(trim(p_class), '') IS NULL THEN
            RAISE EXCEPTION 'Choose a class.';
        END IF;
        UPDATE core.inventory_class_kits
           SET quantity = 0, updated_by = p_action_user_id, updated_at = now()
         WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND class_name = trim(p_class) AND quantity <> 0;
        INSERT INTO core.inventory_class_kits (tenant_id, school_id, class_name, item_id, quantity, updated_by)
        SELECT p_tenant_id, p_school_id, trim(p_class), i.item_id, SUM(x.qty), p_action_user_id
          FROM jsonb_to_recordset(COALESCE(p_items, '[]'::jsonb)) AS x("itemId" integer, qty numeric)
          JOIN core.inventory_items i ON i.item_id = x."itemId" AND i.tenant_id = p_tenant_id AND i.school_id = p_school_id
                                     AND NOT i.is_deleted
         WHERE x.qty > 0
         GROUP BY i.item_id
        ON CONFLICT (tenant_id, school_id, class_name, item_id)
        DO UPDATE SET quantity = EXCLUDED.quantity, updated_by = EXCLUDED.updated_by, updated_at = now();
        GET DIAGNOSTICS v_n = ROW_COUNT;
        OPEN p_result FOR SELECT TRUE AS success, 'Set for ' || trim(p_class) || ' saved: ' || v_n || ' item(s).' AS message;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation.';
END;
$procedure$;


-- ============================================================================
-- Books & Uniform Register: who in a class has which item (✓ / ✗).
--
--   p_academic_year, p_class, p_section  -> one class-section of one session
--   cursor 1  the children (core.student_enrolment of that session), by roll
--   cursor 2  the columns: every item the store sells for this class (or for every
--             class), plus anything a child of the class was sold that session
--   cursor 3  what each child has: per item, quantity still held (sold minus
--             returned) and how much of it is unpaid
-- Who may see which class is decided by the app (store staff: any class; a
-- class teacher: their own). Read-only.
-- ============================================================================
CREATE OR REPLACE PROCEDURE core.sp_inventory_class_register(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_academic_year  varchar,
    IN    p_class          varchar,
    IN    p_section        varchar DEFAULT NULL,
    INOUT p_students       refcursor DEFAULT 'register_students'::refcursor,
    INOUT p_items          refcursor DEFAULT 'register_items'::refcursor,
    INOUT p_held           refcursor DEFAULT 'register_held'::refcursor)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    CREATE TEMP TABLE IF NOT EXISTS _reg_kids (student_id integer) ON COMMIT DROP;
    TRUNCATE _reg_kids;
    INSERT INTO _reg_kids
    SELECT e.student_id
      FROM core.student_enrolment e
      JOIN core.students s ON s.student_id = e.student_id
     WHERE e.tenant_id = p_tenant_id AND e.school_id = p_school_id
       AND e.academic_year = p_academic_year AND e.class_name = p_class
       AND (NULLIF(trim(p_section), '') IS NULL OR COALESCE(e.section, '') = trim(p_section))
       AND COALESCE(e.status, '') NOT IN ('Left', 'PassedOut')
       AND COALESCE(s.is_active, TRUE);

    OPEN p_students FOR
    SELECT s.student_id, s.student_name, s.admission_no, e.section,
           COALESCE(NULLIF(trim(e.roll_no), ''), s.roll_no) AS roll_no
      FROM _reg_kids k
      JOIN core.students s ON s.student_id = k.student_id
      JOIN core.student_enrolment e ON e.student_id = k.student_id AND e.academic_year = p_academic_year
     ORDER BY e.section, NULLIF(regexp_replace(COALESCE(NULLIF(trim(e.roll_no), ''), s.roll_no, ''), '\D', '', 'g'), '')::int NULLS LAST,
              s.student_name;

    OPEN p_items FOR
    SELECT i.item_id, i.item_name, COALESCE(NULLIF(trim(i.category), ''), 'Other') AS category
      FROM core.inventory_items i
     WHERE i.tenant_id = p_tenant_id AND i.school_id = p_school_id AND NOT i.is_deleted
       AND ((i.is_active AND i.item_type = 'Saleable' AND (i.for_class IS NULL OR i.for_class = p_class))
            OR EXISTS (SELECT 1 FROM core.inventory_student_sale_lines l
                         JOIN core.inventory_student_sales sa ON sa.sale_id = l.sale_id
                        WHERE l.item_id = i.item_id AND sa.academic_year = p_academic_year
                          AND sa.student_id IN (SELECT student_id FROM _reg_kids)))
     ORDER BY 3, i.item_name;

    OPEN p_held FOR
    SELECT sa.student_id, l.item_id,
           SUM(l.quantity) AS quantity,
           SUM(COALESCE(sl.amount_due - sl.amount_paid - sl.concession, 0)) AS unpaid
      FROM core.inventory_student_sale_lines l
      JOIN core.inventory_student_sales sa ON sa.sale_id = l.sale_id
      LEFT JOIN core.student_ledger sl ON sl.ledger_id = l.ledger_id
     WHERE sa.tenant_id = p_tenant_id AND sa.school_id = p_school_id
       AND sa.academic_year = p_academic_year
       AND l.returned_at IS NULL
       AND sa.student_id IN (SELECT student_id FROM _reg_kids)
     GROUP BY sa.student_id, l.item_id;
END;
$procedure$;


-- ============================================================================
-- Store summary: what the store bought and sold of the items it sells (type
-- 'Saleable') in a date range, what the children's families have paid of it,
-- the margin, and the stock still on the shelf. Read-only, one row.
--   bought      purchase bills of saleable items (cancelled bills left out,
--               supplier returns taken off)
--   sold        sales to students not returned (what went on fee accounts)
--   cost_of_sold  the same items at the cost they were issued at
--   collected / unpaid  of those fee lines, paid so far / still owed
--   stock_value saleable stock on hand now, at cost price
-- ============================================================================
CREATE OR REPLACE PROCEDURE core.sp_inventory_store_summary(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_from           date,
    IN    p_to             date,
    INOUT p_result         refcursor DEFAULT 'store_summary_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    OPEN p_result FOR
    WITH sold AS (
        SELECT l.amount, l.quantity, l.item_id,
               COALESCE(sl.amount_paid, 0) AS paid,
               COALESCE(sl.amount_due - sl.amount_paid - sl.concession, 0) AS open_amount,
               -- the rate the item left the shelf at (its Issue movement), else today's cost price
               COALESCE((SELECT m.unit_rate FROM core.inventory_stock_ledger m
                          WHERE m.reference_type = 'StudentSale' AND m.reference_id = sa.sale_id
                            AND m.item_id = l.item_id AND m.movement_type = 'Issue'
                          ORDER BY m.movement_id LIMIT 1), i.cost_price) AS unit_cost
          FROM core.inventory_student_sale_lines l
          JOIN core.inventory_student_sales sa ON sa.sale_id = l.sale_id
          JOIN core.inventory_items i ON i.item_id = l.item_id
          LEFT JOIN core.student_ledger sl ON sl.ledger_id = l.ledger_id
         WHERE sa.tenant_id = p_tenant_id AND sa.school_id = p_school_id
           AND sa.sale_date BETWEEN p_from AND p_to
           AND l.returned_at IS NULL
    )
    SELECT
        COALESCE((SELECT SUM(pi.line_total)
                    FROM core.inventory_purchase_items pi
                    JOIN core.inventory_purchases pu ON pu.purchase_id = pi.purchase_id
                    JOIN core.inventory_items i ON i.item_id = pi.item_id AND i.item_type = 'Saleable'
                   WHERE pu.tenant_id = p_tenant_id AND pu.school_id = p_school_id AND NOT pu.is_cancelled
                     AND NULLIF(pu.purchase_date, '')::date BETWEEN p_from AND p_to), 0)
      - COALESCE((SELECT SUM(rt.amount)
                    FROM core.inventory_purchase_returns rt
                    JOIN core.inventory_purchases pu ON pu.purchase_id = rt.purchase_id
                    JOIN core.inventory_items i ON i.item_id = rt.item_id AND i.item_type = 'Saleable'
                   WHERE rt.tenant_id = p_tenant_id AND rt.school_id = p_school_id AND NOT pu.is_cancelled
                     AND NULLIF(pu.purchase_date, '')::date BETWEEN p_from AND p_to), 0) AS bought,
        COALESCE((SELECT SUM(amount) FROM sold), 0)                       AS sold,
        COALESCE((SELECT SUM(round(quantity * unit_cost, 2)) FROM sold), 0) AS cost_of_sold,
        COALESCE((SELECT SUM(paid) FROM sold), 0)                         AS collected,
        COALESCE((SELECT SUM(open_amount) FROM sold), 0)                  AS unpaid,
        COALESCE((SELECT SUM(i.current_stock * i.cost_price) FROM core.inventory_items i
                   WHERE i.tenant_id = p_tenant_id AND i.school_id = p_school_id
                     AND NOT i.is_deleted AND i.item_type = 'Saleable'), 0) AS stock_value;
END;
$procedure$;


-- ============================================================================
-- Books & Uniform Register, every class at once (store staff's overview).
--   cursor 1  every child of the session (enrolment), with class, section and the
--             class's teaching order
--   cursor 2  the items: everything the store sells, plus anything given that session
--             (for_class tells which classes an item is for)
--   cursor 3  who holds what this session (sold, not returned)
-- The app adds it up per class-section ("Diary 2/3"). Read-only.
-- ============================================================================
CREATE OR REPLACE PROCEDURE core.sp_inventory_register_overview(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_academic_year  varchar,
    INOUT p_students       refcursor DEFAULT 'overview_students'::refcursor,
    INOUT p_items          refcursor DEFAULT 'overview_items'::refcursor,
    INOUT p_held           refcursor DEFAULT 'overview_held'::refcursor)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    OPEN p_students FOR
    SELECT e.student_id, e.class_name, COALESCE(e.section, '') AS section,
           COALESCE((SELECT c.display_order FROM academic.academic_classes c
                       JOIN academic.academic_years y ON y.academic_year_id = c.academic_year_id
                      WHERE c.tenant_id = p_tenant_id AND c.school_id = p_school_id
                        AND y.academic_year_name = p_academic_year AND c.class_name = e.class_name
                        AND NOT COALESCE(c.is_deleted, FALSE)
                      LIMIT 1), 999) AS class_order
      FROM core.student_enrolment e
      JOIN core.students s ON s.student_id = e.student_id
     WHERE e.tenant_id = p_tenant_id AND e.school_id = p_school_id
       AND e.academic_year = p_academic_year
       AND COALESCE(e.status, '') NOT IN ('Left', 'PassedOut')
       AND COALESCE(s.is_active, TRUE);

    OPEN p_items FOR
    SELECT i.item_id, i.item_name, COALESCE(NULLIF(trim(i.category), ''), 'Other') AS category, i.for_class
      FROM core.inventory_items i
     WHERE i.tenant_id = p_tenant_id AND i.school_id = p_school_id AND NOT i.is_deleted
       AND ((i.is_active AND i.item_type = 'Saleable')
            OR EXISTS (SELECT 1 FROM core.inventory_student_sale_lines l
                         JOIN core.inventory_student_sales sa ON sa.sale_id = l.sale_id
                        WHERE l.item_id = i.item_id AND sa.academic_year = p_academic_year))
     ORDER BY 3, i.item_name;

    OPEN p_held FOR
    SELECT DISTINCT sa.student_id, l.item_id
      FROM core.inventory_student_sale_lines l
      JOIN core.inventory_student_sales sa ON sa.sale_id = l.sale_id
     WHERE sa.tenant_id = p_tenant_id AND sa.school_id = p_school_id
       AND sa.academic_year = p_academic_year
       AND l.returned_at IS NULL;
END;
$procedure$;
