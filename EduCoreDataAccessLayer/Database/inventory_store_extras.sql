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
