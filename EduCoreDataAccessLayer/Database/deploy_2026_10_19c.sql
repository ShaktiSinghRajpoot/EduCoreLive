-- Bundle 2026-10-19c: store extras -- supplier dues (credit bills + payments, Cash Book), order list, size exchange. Run with:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_19c.sql
-- Sources: inventory_store_extras.sql (all), inventory_student_sale.sql (sp_inventory_student_sale),
--          expense_cashbook.sql (fn_school_money), inventory.sql (sp_inventory_manage)

-- ============================================================================
-- Store: what real schools also do (19 Oct 2026)
--
--   * SUPPLIER DUES. A bill can be bought on credit (payment mode 'Credit'): it is
--     owed to the supplier, not paid, so the Cash Book leaves it out. The school
--     then pays the supplier in parts (core.inventory_supplier_payments); each
--     payment is money out in the Cash Book, and a cancelled one comes back on the
--     day it is cancelled (the Day Close rule). Rows are never deleted.
--       due = credit bills not cancelled (total - what went back to the supplier)
--             - payments not cancelled
--   * ORDER LIST. Before a session the office orders books and uniform: for every
--     item given to students, how many children of its classes are enrolled in
--     that session, how many already have it, the stock in hand and what is left
--     to order. Sizes ("Uniform - 24", "- 28") count as one line, like the register.
--
--   core.fn_supplier_due(tenant, school, supplier)
--   core.sp_inventory_supplier_pay   Pay | List | Cancel
--   core.sp_inventory_order_list     one session
-- The size exchange is the 'Exchange' operation of core.sp_inventory_student_sale
-- (inventory_student_sale.sql); the Cash Book lines are in fn_school_money
-- (expense_cashbook.sql).
-- ============================================================================

CREATE TABLE IF NOT EXISTS core.inventory_supplier_payments (
    payment_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     integer NOT NULL,
    school_id     integer NOT NULL,
    supplier_id   integer NOT NULL REFERENCES core.inventory_suppliers(supplier_id),
    pay_date      date NOT NULL DEFAULT CURRENT_DATE,
    amount        numeric(12,2) NOT NULL,
    payment_mode  varchar(30) NOT NULL DEFAULT 'Cash',
    reference_no  varchar(60),
    remarks       varchar(300),
    is_cancelled  boolean NOT NULL DEFAULT FALSE,
    cancel_reason varchar(200),
    cancelled_by  integer,
    cancelled_at  timestamptz,
    created_by    integer NOT NULL DEFAULT 0,
    created_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT chk_sup_pay_scope  CHECK (tenant_id > 1 AND school_id > 0),
    CONSTRAINT chk_sup_pay_amount CHECK (amount > 0)
);
CREATE INDEX IF NOT EXISTS ix_sup_pay_supplier ON core.inventory_supplier_payments (tenant_id, school_id, supplier_id);


-- What the school still owes one supplier (negative = paid ahead).
CREATE OR REPLACE FUNCTION core.fn_supplier_due(p_tenant_id integer, p_school_id integer, p_supplier_id integer)
RETURNS numeric
LANGUAGE sql
STABLE
AS $function$
    SELECT COALESCE((SELECT SUM(pu.grand_total
                                - COALESCE((SELECT SUM(rt.amount) FROM core.inventory_purchase_returns rt
                                             WHERE rt.purchase_id = pu.purchase_id), 0))
                       FROM core.inventory_purchases pu
                      WHERE pu.tenant_id = p_tenant_id AND pu.school_id = p_school_id
                        AND pu.supplier_id = p_supplier_id AND NOT pu.is_cancelled
                        AND pu.payment_mode = 'Credit'), 0)
         - COALESCE((SELECT SUM(sp.amount) FROM core.inventory_supplier_payments sp
                      WHERE sp.tenant_id = p_tenant_id AND sp.school_id = p_school_id
                        AND sp.supplier_id = p_supplier_id AND NOT sp.is_cancelled), 0);
$function$;


-- Pay a supplier, list their payments, cancel one.
CREATE OR REPLACE PROCEDURE core.sp_inventory_supplier_pay(
    IN    p_operation      varchar,
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_supplier_id    integer DEFAULT NULL,
    IN    p_amount         numeric DEFAULT NULL,
    IN    p_pay_date       varchar DEFAULT NULL,   -- yyyy-MM-dd, empty = today
    IN    p_payment_mode   varchar DEFAULT NULL,
    IN    p_reference_no   varchar DEFAULT NULL,
    IN    p_remarks        varchar DEFAULT NULL,
    IN    p_payment_id     integer DEFAULT NULL,
    IN    p_reason         varchar DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'supplier_pay_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_name varchar;
    v_due  numeric;
    v_date date;
    v_id   integer;
    r      record;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    IF p_operation = 'Pay' THEN
        SELECT supplier_name INTO v_name FROM core.inventory_suppliers
         WHERE supplier_id = p_supplier_id AND tenant_id = p_tenant_id AND school_id = p_school_id AND NOT is_deleted;
        IF v_name IS NULL THEN
            RAISE EXCEPTION 'Supplier not found.';
        END IF;
        IF COALESCE(p_amount, 0) <= 0 OR p_amount <> round(p_amount, 2) THEN
            RAISE EXCEPTION 'Enter the amount paid (at most 2 decimals).';
        END IF;
        v_date := COALESCE(NULLIF(trim(p_pay_date), '')::date, CURRENT_DATE);
        IF v_date > CURRENT_DATE THEN
            RAISE EXCEPTION 'A payment cannot be dated in the future.';
        END IF;
        IF NULLIF(trim(p_payment_mode), '') IS NULL OR trim(p_payment_mode) = 'Credit' THEN
            RAISE EXCEPTION 'Choose how it was paid (cash, UPI, bank, cheque).';
        END IF;
        v_due := core.fn_supplier_due(p_tenant_id, p_school_id, p_supplier_id);
        IF p_amount > v_due THEN
            RAISE EXCEPTION 'Only Rs % is due to %.', to_char(GREATEST(v_due, 0), 'FM99,99,99,990.00'), v_name;
        END IF;

        INSERT INTO core.inventory_supplier_payments
            (tenant_id, school_id, supplier_id, pay_date, amount, payment_mode, reference_no, remarks, created_by)
        VALUES (p_tenant_id, p_school_id, p_supplier_id, v_date, p_amount, left(trim(p_payment_mode), 30),
                NULLIF(left(trim(COALESCE(p_reference_no, '')), 60), ''), NULLIF(left(trim(COALESCE(p_remarks, '')), 300), ''),
                p_action_user_id)
        RETURNING payment_id INTO v_id;

        OPEN p_result FOR
        SELECT TRUE AS success, v_id AS payment_id,
               'Rs ' || to_char(p_amount, 'FM99,99,99,990.00') || ' paid to ' || v_name || '. Still due: Rs '
               || to_char(GREATEST(v_due - p_amount, 0), 'FM99,99,99,990.00') || '.' AS message;
        RETURN;
    END IF;

    IF p_operation = 'List' THEN
        OPEN p_result FOR
        SELECT sp.payment_id, sp.pay_date::text AS pay_date, sp.amount, sp.payment_mode,
               COALESCE(sp.reference_no, '') AS reference_no, COALESCE(sp.remarks, '') AS remarks,
               sp.is_cancelled, COALESCE(sp.cancel_reason, '') AS cancel_reason,
               core.fn_user_display_name(sp.created_by) AS paid_by
          FROM core.inventory_supplier_payments sp
         WHERE sp.tenant_id = p_tenant_id AND sp.school_id = p_school_id AND sp.supplier_id = p_supplier_id
         ORDER BY sp.pay_date DESC, sp.payment_id DESC;
        RETURN;
    END IF;

    IF p_operation = 'Cancel' THEN
        IF NULLIF(trim(p_reason), '') IS NULL THEN
            RAISE EXCEPTION 'Give a reason for cancelling the payment.';
        END IF;
        SELECT sp.payment_id, sp.is_cancelled, sp.amount INTO r
          FROM core.inventory_supplier_payments sp
         WHERE sp.payment_id = p_payment_id AND sp.tenant_id = p_tenant_id AND sp.school_id = p_school_id
           FOR UPDATE;
        IF r.payment_id IS NULL THEN
            RAISE EXCEPTION 'Payment not found.';
        END IF;
        IF r.is_cancelled THEN
            RAISE EXCEPTION 'This payment is already cancelled.';
        END IF;
        UPDATE core.inventory_supplier_payments
           SET is_cancelled = TRUE, cancel_reason = left(trim(p_reason), 200),
               cancelled_by = p_action_user_id, cancelled_at = now()
         WHERE payment_id = p_payment_id;
        OPEN p_result FOR
        SELECT TRUE AS success, 'Payment of Rs ' || to_char(r.amount, 'FM99,99,99,990.00') || ' cancelled. It is due again.' AS message;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation.';
END;
$procedure$;


-- What to order for a session: one line per item (sizes together).
CREATE OR REPLACE PROCEDURE core.sp_inventory_order_list(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_academic_year  varchar,
    INOUT p_result         refcursor DEFAULT 'order_list_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;
    IF NULLIF(trim(p_academic_year), '') IS NULL THEN
        RAISE EXCEPTION 'Choose the session.';
    END IF;

    OPEN p_result FOR
    WITH it AS (
        SELECT i.item_id, i.item_name, COALESCE(NULLIF(trim(i.category), ''), 'Other') AS category,
               i.unit_type, i.for_class, i.current_stock, core.fn_item_base_name(i.item_name) AS base
          FROM core.inventory_items i
         WHERE i.tenant_id = p_tenant_id AND i.school_id = p_school_id
           AND NOT i.is_deleted AND i.is_active AND i.item_type = 'Saleable'
    ), g AS (
        -- sizes share a line when the store sells two or more items with the same name before " - "
        SELECT it.*, CASE WHEN COUNT(*) OVER (PARTITION BY base) > 1 THEN base ELSE item_name END AS col
          FROM it
    ), kids AS (
        SELECT e.student_id, e.class_name
          FROM core.student_enrolment e
          JOIN core.students s ON s.student_id = e.student_id
         WHERE e.tenant_id = p_tenant_id AND e.school_id = p_school_id AND e.academic_year = p_academic_year
           AND COALESCE(e.status, '') NOT IN ('Left', 'PassedOut') AND COALESCE(s.is_active, TRUE)
    ), held AS (
        SELECT DISTINCT sa.student_id, g.col
          FROM core.inventory_student_sale_lines l
          JOIN core.inventory_student_sales sa ON sa.sale_id = l.sale_id
          JOIN g ON g.item_id = l.item_id
         WHERE sa.tenant_id = p_tenant_id AND sa.school_id = p_school_id
           AND sa.academic_year = p_academic_year AND l.returned_at IS NULL
    ), cols AS (
        SELECT col, MIN(category) AS category, MIN(unit_type) AS unit, SUM(current_stock) AS in_stock,
               BOOL_OR(for_class IS NULL) AS every_class,
               string_agg(CASE WHEN col <> item_name
                               THEN trim(regexp_replace(substr(item_name, length(col) + 1), '^\s*-\s*', '')) || ': '
                                    || trim(to_char(current_stock, 'FM999999990.##')) END,
                          ' · ' ORDER BY item_name) AS sizes
          FROM g GROUP BY col
    ), counted AS (
        SELECT c.*,
               (SELECT string_agg(DISTINCT x, ', ') FROM g g2, unnest(g2.for_class) x WHERE g2.col = c.col) AS classes,
               (SELECT COUNT(*) FROM kids k
                 WHERE EXISTS (SELECT 1 FROM g g2 WHERE g2.col = c.col
                                AND (g2.for_class IS NULL OR k.class_name = ANY (g2.for_class))))::int AS children,
               (SELECT COUNT(*) FROM held h JOIN kids k ON k.student_id = h.student_id WHERE h.col = c.col)::int AS have
          FROM cols c
    )
    SELECT col AS item, category, unit,
           CASE WHEN every_class THEN '' ELSE COALESCE(classes, '') END AS classes,
           children, have, GREATEST(children - have, 0) AS still_need,
           in_stock, GREATEST(children - have - in_stock, 0) AS to_order,
           COALESCE(sizes, '') AS sizes
      FROM counted
     ORDER BY category, col;
END;
$procedure$;

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
               i.unit_type, i.selling_price, array_to_string(i.for_class, '|') AS for_class,
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
           AND (p_class IS NULL OR i.for_class IS NULL OR p_class = ANY (i.for_class))
         ORDER BY 3, i.item_name;
        RETURN;
    END IF;

    -- ── Which classes an item is for (NULL = every class), as 'Class 9|Class 10|Class 11'
    IF p_operation = 'ItemClass' THEN
        OPEN p_result FOR
        SELECT i.item_id, array_to_string(i.for_class, '|') AS for_class FROM core.inventory_items i
         WHERE i.item_id = p_item_id AND i.tenant_id = p_tenant_id AND i.school_id = p_school_id;
        RETURN;
    END IF;
    IF p_operation = 'SetItemClass' THEN
        UPDATE core.inventory_items
           -- p_class: the class names joined by '|'; none (or 'All') = every class
           SET for_class = NULLIF(ARRAY(SELECT left(trim(x), 50)
                                          FROM unnest(string_to_array(COALESCE(p_class, ''), '|')) WITH ORDINALITY AS u(x, n)
                                         WHERE trim(x) NOT IN ('', 'All')
                                         ORDER BY n), '{}'::text[])
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

    -- ── Exchange: "28 is too small, give 32". The same sale line and fee line move to
    --    the other size: the first size goes back on the shelf, the new one comes off
    --    it (two stock movements, so History shows the swap). A paid line keeps its
    --    payment, so only a size of the same price can be swapped onto it; an unpaid
    --    line takes the new price.
    IF p_operation = 'Exchange' THEN
        SELECT l.line_id, l.item_id, l.quantity, l.amount, l.ledger_id, l.returned_at, sa.sale_id, sa.location_id,
               i.item_name, st.student_name || ' (' || COALESCE(st.admission_no, '-') || ')' AS who,
               sl.amount_paid, sl.concession, sl.status AS fee_status, sl.closed_amount
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
            RAISE EXCEPTION '% was returned; give the other size instead.', r.item_name;
        END IF;
        IF r.fee_status = 'Closed' OR COALESCE(r.closed_amount, 0) > 0 THEN
            RAISE EXCEPTION 'The fee line of % is closed, so it cannot be exchanged.', r.item_name;
        END IF;

        SELECT i.item_id, i.item_name, i.selling_price, i.cost_price, i.unit_type INTO it
          FROM core.inventory_items i
         WHERE i.item_id = p_item_id AND i.tenant_id = p_tenant_id AND i.school_id = p_school_id
           AND NOT i.is_deleted AND i.is_active AND i.item_type = 'Saleable';
        IF it.item_id IS NULL OR it.item_id = r.item_id
           OR core.fn_item_base_name(it.item_name) <> core.fn_item_base_name(r.item_name) THEN
            RAISE EXCEPTION 'Choose another size of %.', core.fn_item_base_name(r.item_name);
        END IF;
        IF round(r.quantity * it.selling_price, 2) <> r.amount
           AND (COALESCE(r.amount_paid, 0) > 0 OR COALESCE(r.concession, 0) > 0) THEN
            RAISE EXCEPTION '% costs Rs % and % is already paid at Rs %. Cancel that receipt first, or pick a size of the same price.',
                it.item_name, to_char(round(r.quantity * it.selling_price, 2), 'FM99,99,99,990.00'),
                r.item_name, to_char(r.amount, 'FM99,99,99,990.00');
        END IF;

        SELECT COALESCE((SELECT ls.quantity FROM core.inventory_location_stock ls
                          WHERE ls.item_id = it.item_id AND ls.location_id = r.location_id), 0) INTO v_stock;
        IF v_stock < r.quantity THEN
            RAISE EXCEPTION 'Only % % of % left in this store.', trim(to_char(v_stock, 'FM999999990.##')), it.unit_type, it.item_name;
        END IF;

        PERFORM core.fn_inventory_post_movement(
            p_tenant_id, p_school_id, p_action_user_id, r.item_id, r.location_id, 'Return', r.quantity, NULL,
            'StudentSale', p_line_id, NULL, r.who, left('Exchanged for ' || it.item_name, 200));
        PERFORM core.fn_inventory_post_movement(
            p_tenant_id, p_school_id, p_action_user_id, it.item_id, r.location_id, 'Issue', -r.quantity, it.cost_price,
            'StudentSale', r.sale_id, NULL, r.who, left('Exchanged from ' || r.item_name, 200));

        UPDATE core.inventory_student_sale_lines
           SET item_id = it.item_id, unit_price = it.selling_price, amount = round(r.quantity * it.selling_price, 2)
         WHERE line_id = p_line_id;
        UPDATE core.inventory_student_sales sa
           SET total = (SELECT COALESCE(SUM(l.amount), 0) FROM core.inventory_student_sale_lines l WHERE l.sale_id = sa.sale_id)
         WHERE sa.sale_id = r.sale_id;
        IF r.ledger_id IS NOT NULL THEN
            -- the fee line reads like the new size ("Uniform — 32") and, unpaid, takes its price
            UPDATE core.student_ledger
               SET installment_label = NULLIF(concat_ws(' ',
                       CASE WHEN position(' - ' IN it.item_name) > 0
                            THEN trim(right(it.item_name, position(' - ' IN reverse(it.item_name)) - 1)) END,
                       CASE WHEN r.quantity <> 1 THEN '× ' || trim(to_char(r.quantity, 'FM999999990.##')) END), ''),
                   amount_due = round(r.quantity * it.selling_price, 2),
                   updated_at = now()
             WHERE ledger_id = r.ledger_id;
        END IF;

        OPEN p_result FOR
        SELECT TRUE AS success, r.item_name || ' exchanged for ' || it.item_name || '.' AS message;
        RETURN;
    END IF;

    -- ── List: the latest sales, line by line
    IF p_operation = 'List' THEN
        OPEN p_result FOR
        SELECT l.line_id, sa.sale_id, sa.sale_date::text AS sale_date, sa.student_id,
               st.student_name, st.admission_no, sa.class_name, sa.academic_year,
               i.item_name, l.quantity, l.unit_price, l.amount,
               COALESCE(sl.amount_paid, 0) AS paid,
               l.item_id,
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

CREATE OR REPLACE FUNCTION core.fn_school_money(p_tenant_id integer, p_school_id integer, p_from date, p_to date)
RETURNS TABLE (line_date date, kind varchar, ref varchar, detail varchar, category varchar,
               mode varchar, book varchar, money_in numeric, money_out numeric)
LANGUAGE sql
STABLE
AS $function$
    WITH fee AS (
        -- fee receipts and their cancellations, real money only, per receipt and mode
        SELECT ml.line_date, CASE WHEN ml.entry = 'Cancellation' THEN 'Fee cancelled' ELSE 'Fee receipt' END AS kind,
               p.receipt_no AS ref,
               COALESCE(s.student_name, e.student_name, 'Student') AS detail,
               ml.mode, SUM(ml.amount) AS amount,
               -- the share of the receipt paid against books / uniform sold by the store
               -- (receipt lines whose fee line came from a store sale), so the book
               -- shows that money as sales, not as fees
               COALESCE((SELECT SUM(d.amount) FILTER (WHERE EXISTS (SELECT 1 FROM core.inventory_student_sale_lines sl
                                                                    WHERE sl.ledger_id = d.ledger_id))
                                / NULLIF(SUM(d.amount), 0)
                           FROM core.fee_payment_details d WHERE d.payment_id = p.payment_id), 0) AS store_share
          FROM core.fn_fee_money_lines(p_tenant_id, p_school_id, p_from, p_to) ml
          JOIN core.fee_payments p ON p.payment_id = ml.payment_id
          LEFT JOIN core.students  s ON s.student_id = p.student_id
          LEFT JOIN core.enquiries e ON e.enquiry_id = p.enquiry_id
         WHERE ml.mode NOT IN ('Advance', 'To wallet')
         GROUP BY ml.line_date, ml.entry, p.payment_id, p.receipt_no, s.student_name, e.student_name, ml.mode
    ), fee_split AS (
        SELECT f.*, round(f.amount * f.store_share, 2) AS store_amount FROM fee f
    ), x AS (
        SELECT line_date, kind, ref, detail, 'Fees'::varchar AS category, mode,
               GREATEST(amount - store_amount, 0) AS money_in, GREATEST(-(amount - store_amount), 0) AS money_out
          FROM fee_split
        UNION ALL
        SELECT line_date, kind, ref, detail, 'Books & Uniform sales'::varchar, mode,
               GREATEST(store_amount, 0), GREATEST(-store_amount, 0)
          FROM fee_split WHERE store_amount <> 0
        UNION ALL
        SELECT r.refunded_at::date, 'Refund', r.refund_no, st.student_name, 'Fee refunds',
               COALESCE(NULLIF(trim(r.refund_mode), ''), 'Cash'), 0, r.amount
          FROM core.fee_refunds r
          LEFT JOIN core.students st ON st.student_id = r.student_id
         WHERE r.tenant_id = p_tenant_id AND r.school_id = p_school_id
           AND r.refunded_at::date BETWEEN p_from AND p_to
        UNION ALL
        SELECT sp.paid_at::date, 'Salary', 'Salary ' || to_char(make_date(sp.pay_year, sp.pay_month, 1), 'Mon YYYY'),
               sf.full_name, 'Salary', COALESCE(NULLIF(trim(sp.payment_mode), ''), 'Bank Transfer'), 0, sp.net_pay
          FROM core.staff_payroll sp
          LEFT JOIN core.staff sf ON sf.staff_id = sp.staff_id
         WHERE sp.tenant_id = p_tenant_id AND sp.school_id = p_school_id
           AND sp.status = 'Paid' AND sp.paid_at IS NOT NULL
           AND sp.paid_at::date BETWEEN p_from AND p_to
        UNION ALL
        SELECT NULLIF(pu.purchase_date, '')::date, 'Purchase', COALESCE(NULLIF(pu.invoice_no, ''), 'Bill #' || pu.purchase_id),
               COALESCE(pu.supplier_name, 'Supplier'), 'Store purchases',
               COALESCE(NULLIF(trim(pu.payment_mode), ''), 'Cash'), 0, pu.grand_total
          FROM core.inventory_purchases pu
         WHERE pu.tenant_id = p_tenant_id AND pu.school_id = p_school_id
           AND COALESCE(pu.payment_mode, '') <> 'Credit'
           AND NULLIF(pu.purchase_date, '')::date BETWEEN p_from AND p_to
        UNION ALL
        SELECT NULLIF(rt.return_date, '')::date, 'Supplier return', COALESCE(NULLIF(pu.invoice_no, ''), 'Bill #' || pu.purchase_id),
               COALESCE(pu.supplier_name, 'Supplier'), 'Store purchases',
               COALESCE(NULLIF(trim(pu.payment_mode), ''), 'Cash'), SUM(rt.amount), 0
          FROM core.inventory_purchase_returns rt
          JOIN core.inventory_purchases pu ON pu.purchase_id = rt.purchase_id
         WHERE rt.tenant_id = p_tenant_id AND rt.school_id = p_school_id
           AND COALESCE(pu.payment_mode, '') <> 'Credit'
           AND NULLIF(rt.return_date, '')::date BETWEEN p_from AND p_to
         GROUP BY rt.return_date, pu.purchase_id, pu.invoice_no, pu.supplier_name, pu.payment_mode
        UNION ALL
        -- a cancelled bill gives back what was not already returned
        SELECT pu.cancelled_at::date, 'Purchase cancelled', COALESCE(NULLIF(pu.invoice_no, ''), 'Bill #' || pu.purchase_id),
               COALESCE(pu.supplier_name, 'Supplier'), 'Store purchases',
               COALESCE(NULLIF(trim(pu.payment_mode), ''), 'Cash'),
               pu.grand_total - COALESCE((SELECT SUM(rt.amount) FROM core.inventory_purchase_returns rt
                                           WHERE rt.purchase_id = pu.purchase_id), 0), 0
          FROM core.inventory_purchases pu
         WHERE pu.tenant_id = p_tenant_id AND pu.school_id = p_school_id
           AND COALESCE(pu.payment_mode, '') <> 'Credit'
           AND pu.is_cancelled AND pu.cancelled_at::date BETWEEN p_from AND p_to
        UNION ALL
        SELECT sp.pay_date, 'Supplier payment', 'SP-' || sp.payment_id, su.supplier_name, 'Store purchases',
               sp.payment_mode, 0, sp.amount
          FROM core.inventory_supplier_payments sp
          JOIN core.inventory_suppliers su ON su.supplier_id = sp.supplier_id
         WHERE sp.tenant_id = p_tenant_id AND sp.school_id = p_school_id
           AND sp.pay_date BETWEEN p_from AND p_to
        UNION ALL
        SELECT sp.cancelled_at::date, 'Supplier payment cancelled', 'SP-' || sp.payment_id, su.supplier_name, 'Store purchases',
               sp.payment_mode, sp.amount, 0
          FROM core.inventory_supplier_payments sp
          JOIN core.inventory_suppliers su ON su.supplier_id = sp.supplier_id
         WHERE sp.tenant_id = p_tenant_id AND sp.school_id = p_school_id
           AND sp.is_cancelled AND sp.cancelled_at::date BETWEEN p_from AND p_to
        UNION ALL
        SELECT ex.expense_date, 'Expense', 'EXP-' || ex.expense_id, COALESCE(ex.paid_to, ''), c.name, ex.payment_mode, 0, ex.amount
          FROM core.expenses ex
          JOIN core.expense_categories c ON c.category_id = ex.category_id
         WHERE ex.tenant_id = p_tenant_id AND ex.school_id = p_school_id
           AND ex.expense_date BETWEEN p_from AND p_to
        UNION ALL
        SELECT ex.cancelled_at::date, 'Expense cancelled', 'EXP-' || ex.expense_id, COALESCE(ex.paid_to, ''), c.name, ex.payment_mode, ex.amount, 0
          FROM core.expenses ex
          JOIN core.expense_categories c ON c.category_id = ex.category_id
         WHERE ex.tenant_id = p_tenant_id AND ex.school_id = p_school_id
           AND ex.is_cancelled AND ex.cancelled_at::date BETWEEN p_from AND p_to
    )
    SELECT x.line_date, x.kind::varchar, x.ref::varchar, x.detail::varchar, x.category::varchar, x.mode::varchar,
           (CASE WHEN x.mode = 'Cash' THEN 'Cash' ELSE 'Bank' END)::varchar AS book,
           x.money_in, x.money_out
      FROM x
     WHERE x.money_in <> 0 OR x.money_out <> 0;
$function$;

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
                            AND l.movement_type IN ('Adjustment', 'StockTake')), 0) AS added_qty,
               -- items given to students: which class it is for ('' = every class)
               COALESCE(array_to_string(i.for_class, '|'), '') AS for_class
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
                 WHERE p.supplier_id = s.supplier_id AND p.is_cancelled = FALSE)::text, '') AS last_bill_date,
               -- credit bills not yet paid (inventory_store_extras.sql)
               core.fn_supplier_due(p_tenant_id, p_school_id, s.supplier_id) AS due
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
