-- Bundle 2026-10-18e: Cash Book shows books/uniform money under 'Books & Uniform sales' (not Fees); store summary
-- (bought, sold, cost, margin, collected, unpaid, stock). Run with:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_18e.sql
-- Sources: expense_cashbook.sql, inventory_student_sale.sql

-- ===== expense_cashbook.sql =====
-- ============================================================================
-- Expenses and the Cash Book (Finance › Expenses, Finance › Cash Book).
--
-- Expenses: what the school spends that is not stock -- electricity, diesel,
-- rent, repairs, events ... -- one row per payment, under a category the school
-- names itself (a default list is created the first time). An expense is never
-- edited or deleted: a wrong one is CANCELLED with a reason, like a fee receipt.
--
-- Cash Book: every rupee in and out, read from where it is already recorded,
-- so nothing is entered twice and nothing can disagree:
--   in   fee receipts            core.fn_fee_money_lines (the same lines Day Close
--                                and the Collection Register read; only real money
--                                modes -- 'Advance' and 'To wallet' are wallet
--                                bookkeeping, not cash)
--        supplier returns        core.inventory_purchase_returns
--   out  fee refunds             core.fee_refunds
--        salaries paid           core.staff_payroll (status Paid, on paid_at)
--        purchase bills          core.inventory_purchases
--        expenses                core.expenses
-- The part of a fee receipt paid against books / uniform sold by the store
-- (inventory_student_sale.sql) is shown under 'Books & Uniform sales', not 'Fees'.
-- A cancellation is a REVERSAL on the day it was cancelled (the rule Day Close
-- uses): the original stays on its own day, so a closed month does not change.
--
--   core.fn_school_money(tenant, school, from, to)  the lines above, one shape
--   core.sp_expense_manage   Categories | SaveCategory | SetCategoryActive |
--                            List | Save | Cancel | GetOpening | SetOpening
--   core.sp_cashbook         opening, lines with running balance, totals by
--                            category, month by month
--
-- Money is split into Cash (cash in hand) and Bank (UPI, card, cheque, transfer
-- ...): the opening balance is set once for each (Finance › Cash Book).
--
-- Needs fee_day_close.sql (fn_fee_money_lines). Re-runnable.
-- ============================================================================

INSERT INTO config.permissions (permission_key, module_group, display_name, sort_order)
VALUES ('expenses.view',   'Finance', 'Expenses & Cash Book — View',                 79),
       ('expenses.manage', 'Finance', 'Expenses & Cash Book — Add / cancel expenses', 80)
ON CONFLICT (permission_key) DO NOTHING;

CREATE TABLE IF NOT EXISTS core.expense_categories (
    category_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   integer NOT NULL,
    school_id   integer NOT NULL,
    name        varchar(60) NOT NULL,
    is_active   boolean NOT NULL DEFAULT TRUE,
    created_by  integer,
    created_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT chk_expense_cat_scope CHECK (tenant_id > 1 AND school_id > 0)
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_expense_cat_name
    ON core.expense_categories (tenant_id, school_id, lower(trim(name)));

CREATE TABLE IF NOT EXISTS core.expenses (
    expense_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     integer NOT NULL,
    school_id     integer NOT NULL,
    expense_date  date NOT NULL,
    category_id   integer NOT NULL REFERENCES core.expense_categories(category_id),
    amount        numeric(12,2) NOT NULL,
    payment_mode  varchar(20) NOT NULL DEFAULT 'Cash',
    paid_to       varchar(150),
    reference_no  varchar(60),
    remarks       varchar(300),
    is_cancelled  boolean NOT NULL DEFAULT FALSE,
    cancel_reason varchar(200),
    cancelled_by  integer,
    cancelled_at  timestamptz,
    created_by    integer NOT NULL DEFAULT 0,
    created_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT chk_expense_scope  CHECK (tenant_id > 1 AND school_id > 0),
    CONSTRAINT chk_expense_amount CHECK (amount > 0)
);
CREATE INDEX IF NOT EXISTS ix_expenses_date ON core.expenses (tenant_id, school_id, expense_date);

-- What the school had in hand on a date: the Cash Book starts from here.
CREATE TABLE IF NOT EXISTS core.cashbook_opening (
    tenant_id  integer NOT NULL,
    school_id  integer NOT NULL,
    as_on      date NOT NULL,
    cash       numeric(12,2) NOT NULL DEFAULT 0,
    bank       numeric(12,2) NOT NULL DEFAULT 0,
    updated_by integer,
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pk_cashbook_opening PRIMARY KEY (tenant_id, school_id)
);


-- Every rupee in or out between two dates, one row per entry.
--   kind      Fee receipt | Fee cancelled | Refund | Salary | Purchase |
--             Purchase cancelled | Supplier return | Expense | Expense cancelled
--   category  expenses: their category; the rest: the kind ("Salary", "Fees" ...)
--   mode      Cash, UPI, Card, Cheque ... (book = 'Cash' or 'Bank')
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
           AND NULLIF(pu.purchase_date, '')::date BETWEEN p_from AND p_to
        UNION ALL
        SELECT NULLIF(rt.return_date, '')::date, 'Supplier return', COALESCE(NULLIF(pu.invoice_no, ''), 'Bill #' || pu.purchase_id),
               COALESCE(pu.supplier_name, 'Supplier'), 'Store purchases',
               COALESCE(NULLIF(trim(pu.payment_mode), ''), 'Cash'), SUM(rt.amount), 0
          FROM core.inventory_purchase_returns rt
          JOIN core.inventory_purchases pu ON pu.purchase_id = rt.purchase_id
         WHERE rt.tenant_id = p_tenant_id AND rt.school_id = p_school_id
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
           AND pu.is_cancelled AND pu.cancelled_at::date BETWEEN p_from AND p_to
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


CREATE OR REPLACE PROCEDURE core.sp_expense_manage(
    IN    p_operation      varchar,
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_expense_id     integer DEFAULT NULL,
    IN    p_date           date    DEFAULT NULL,
    IN    p_category_id    integer DEFAULT NULL,
    IN    p_amount         numeric DEFAULT NULL,   -- SetOpening: cash
    IN    p_amount2        numeric DEFAULT NULL,   -- SetOpening: bank
    IN    p_mode           varchar DEFAULT NULL,
    IN    p_paid_to        varchar DEFAULT NULL,
    IN    p_reference      varchar DEFAULT NULL,
    IN    p_remarks        varchar DEFAULT NULL,
    IN    p_name           varchar DEFAULT NULL,   -- category name; Cancel: the reason
    IN    p_active         boolean DEFAULT NULL,
    IN    p_from           date    DEFAULT NULL,
    IN    p_to             date    DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'expense_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_id   integer;
    v_name varchar := NULLIF(trim(p_name), '');
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    -- A school that has never used expenses gets the usual heads to start with.
    IF NOT EXISTS (SELECT 1 FROM core.expense_categories WHERE tenant_id = p_tenant_id AND school_id = p_school_id) THEN
        INSERT INTO core.expense_categories (tenant_id, school_id, name, created_by)
        SELECT p_tenant_id, p_school_id, n, p_action_user_id
          FROM unnest(ARRAY['Electricity', 'Water', 'Rent', 'Diesel / Fuel', 'Repair & Maintenance', 'Stationery & Printing',
                            'Events & Functions', 'Cleaning & Housekeeping', 'Internet & Phone', 'Bank Charges', 'Other']) AS n;
    END IF;

    IF p_operation = 'Categories' THEN
        OPEN p_result FOR
        SELECT c.category_id, c.name, c.is_active,
               (SELECT COUNT(*) FROM core.expenses x WHERE x.category_id = c.category_id AND NOT x.is_cancelled)::int AS used
          FROM core.expense_categories c
         WHERE c.tenant_id = p_tenant_id AND c.school_id = p_school_id
         ORDER BY c.is_active DESC, c.name;
        RETURN;
    END IF;

    IF p_operation = 'SaveCategory' THEN
        IF v_name IS NULL THEN
            RAISE EXCEPTION 'Give the category a name.';
        END IF;
        IF EXISTS (SELECT 1 FROM core.expense_categories
                    WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                      AND lower(trim(name)) = lower(v_name) AND category_id IS DISTINCT FROM p_category_id) THEN
            RAISE EXCEPTION 'A category called "%" already exists.', v_name;
        END IF;
        IF p_category_id IS NULL THEN
            INSERT INTO core.expense_categories (tenant_id, school_id, name, created_by)
            VALUES (p_tenant_id, p_school_id, left(v_name, 60), p_action_user_id)
            RETURNING category_id INTO v_id;
        ELSE
            UPDATE core.expense_categories SET name = left(v_name, 60)
             WHERE category_id = p_category_id AND tenant_id = p_tenant_id AND school_id = p_school_id
            RETURNING category_id INTO v_id;
            IF v_id IS NULL THEN RAISE EXCEPTION 'Category not found.'; END IF;
        END IF;
        OPEN p_result FOR SELECT TRUE AS success, 'Category saved.' AS message, v_id AS id;
        RETURN;
    END IF;

    -- A category is never deleted (old expenses keep naming it); an inactive one
    -- just cannot be picked for a new expense.
    IF p_operation = 'SetCategoryActive' THEN
        UPDATE core.expense_categories SET is_active = COALESCE(p_active, TRUE)
         WHERE category_id = p_category_id AND tenant_id = p_tenant_id AND school_id = p_school_id
        RETURNING category_id INTO v_id;
        IF v_id IS NULL THEN RAISE EXCEPTION 'Category not found.'; END IF;
        OPEN p_result FOR SELECT TRUE AS success, CASE WHEN p_active THEN 'Category is active again.' ELSE 'Category hidden for new expenses.' END AS message, v_id AS id;
        RETURN;
    END IF;

    IF p_operation = 'List' THEN
        OPEN p_result FOR
        SELECT x.expense_id, x.expense_date::text AS expense_date, x.category_id, c.name AS category,
               x.amount, x.payment_mode, x.paid_to, x.reference_no, x.remarks,
               x.is_cancelled, x.cancel_reason, core.fn_user_display_name(x.cancelled_by) AS cancelled_by,
               to_char(x.cancelled_at, 'YYYY-MM-DD HH24:MI') AS cancelled_at,
               core.fn_user_display_name(x.created_by) AS created_by, to_char(x.created_at, 'YYYY-MM-DD HH24:MI') AS created_at
          FROM core.expenses x
          JOIN core.expense_categories c ON c.category_id = x.category_id
         WHERE x.tenant_id = p_tenant_id AND x.school_id = p_school_id
           AND x.expense_date BETWEEN COALESCE(p_from, DATE '2000-01-01') AND COALESCE(p_to, CURRENT_DATE)
           AND (p_category_id IS NULL OR x.category_id = p_category_id)
         ORDER BY x.expense_date DESC, x.expense_id DESC;
        RETURN;
    END IF;

    IF p_operation = 'Save' THEN
        IF p_date IS NULL THEN RAISE EXCEPTION 'Pick the date of the expense.'; END IF;
        IF p_date > CURRENT_DATE THEN RAISE EXCEPTION 'An expense cannot be dated in the future.'; END IF;
        IF COALESCE(p_amount, 0) <= 0 THEN RAISE EXCEPTION 'Enter the amount paid.'; END IF;
        IF p_amount <> round(p_amount, 2) THEN RAISE EXCEPTION 'The amount takes at most 2 decimals.'; END IF;
        IF NOT EXISTS (SELECT 1 FROM core.expense_categories
                        WHERE category_id = p_category_id AND tenant_id = p_tenant_id AND school_id = p_school_id AND is_active) THEN
            RAISE EXCEPTION 'Choose a category.';
        END IF;
        INSERT INTO core.expenses (tenant_id, school_id, expense_date, category_id, amount, payment_mode,
                                   paid_to, reference_no, remarks, created_by)
        VALUES (p_tenant_id, p_school_id, p_date, p_category_id, p_amount,
                COALESCE(NULLIF(trim(p_mode), ''), 'Cash'), left(NULLIF(trim(p_paid_to), ''), 150),
                left(NULLIF(trim(p_reference), ''), 60), left(NULLIF(trim(p_remarks), ''), 300), p_action_user_id)
        RETURNING expense_id INTO v_id;
        OPEN p_result FOR SELECT TRUE AS success, 'Expense saved (EXP-' || v_id || ').' AS message, v_id AS id;
        RETURN;
    END IF;

    IF p_operation = 'Cancel' THEN
        IF v_name IS NULL THEN RAISE EXCEPTION 'Give a reason for cancelling.'; END IF;
        UPDATE core.expenses
           SET is_cancelled = TRUE, cancel_reason = left(v_name, 200), cancelled_by = p_action_user_id, cancelled_at = now()
         WHERE expense_id = p_expense_id AND tenant_id = p_tenant_id AND school_id = p_school_id AND NOT is_cancelled
        RETURNING expense_id INTO v_id;
        IF v_id IS NULL THEN RAISE EXCEPTION 'Expense not found, or already cancelled.'; END IF;
        OPEN p_result FOR SELECT TRUE AS success, 'Expense EXP-' || v_id || ' cancelled.' AS message, v_id AS id;
        RETURN;
    END IF;

    IF p_operation = 'GetOpening' THEN
        OPEN p_result FOR
        SELECT o.as_on::text AS as_on, o.cash, o.bank, core.fn_user_display_name(o.updated_by) AS updated_by,
               to_char(o.updated_at, 'YYYY-MM-DD HH24:MI') AS updated_at
          FROM core.cashbook_opening o
         WHERE o.tenant_id = p_tenant_id AND o.school_id = p_school_id;
        RETURN;
    END IF;

    IF p_operation = 'SetOpening' THEN
        IF p_date IS NULL THEN RAISE EXCEPTION 'Pick the date of the opening balance.'; END IF;
        IF p_date > CURRENT_DATE THEN RAISE EXCEPTION 'The opening balance cannot be dated in the future.'; END IF;
        IF COALESCE(p_amount, 0) < 0 OR COALESCE(p_amount2, 0) < 0 THEN RAISE EXCEPTION 'Balances cannot be negative.'; END IF;
        INSERT INTO core.cashbook_opening (tenant_id, school_id, as_on, cash, bank, updated_by)
        VALUES (p_tenant_id, p_school_id, p_date, COALESCE(p_amount, 0), COALESCE(p_amount2, 0), p_action_user_id)
        ON CONFLICT (tenant_id, school_id)
        DO UPDATE SET as_on = EXCLUDED.as_on, cash = EXCLUDED.cash, bank = EXCLUDED.bank,
                      updated_by = EXCLUDED.updated_by, updated_at = now();
        OPEN p_result FOR SELECT TRUE AS success, 'Opening balance saved.' AS message, 0 AS id;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation.';
END;
$procedure$;


-- The Cash Book for a date range. p_book: 'All' | 'Cash' | 'Bank'.
--   p_summary  opening (from cashbook_opening + everything between it and p_from),
--              money in, money out, closing
--   p_lines    each entry, oldest first, with the running balance
--   p_heads    totals by category (in and out)
--   p_months   month by month: in, out, net
-- Days before the opening balance's date are not part of the book.
CREATE OR REPLACE PROCEDURE core.sp_cashbook(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_from           date,
    IN    p_to             date,
    IN    p_book           varchar DEFAULT 'All',
    INOUT p_summary        refcursor DEFAULT 'cashbook_summary'::refcursor,
    INOUT p_lines          refcursor DEFAULT 'cashbook_lines'::refcursor,
    INOUT p_heads          refcursor DEFAULT 'cashbook_heads'::refcursor,
    INOUT p_months         refcursor DEFAULT 'cashbook_months'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_book  varchar := COALESCE(NULLIF(trim(p_book), ''), 'All');
    v_as_on date;
    v_cash  numeric := 0;
    v_bank  numeric := 0;
    v_from  date;
    v_open  numeric := 0;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;
    IF p_from IS NULL OR p_to IS NULL OR p_to < p_from THEN
        RAISE EXCEPTION 'Choose a valid date range.';
    END IF;

    SELECT as_on, cash, bank INTO v_as_on, v_cash, v_bank
      FROM core.cashbook_opening WHERE tenant_id = p_tenant_id AND school_id = p_school_id;

    -- the book starts at the opening balance's date (or the first money ever, when none is set)
    v_from := GREATEST(p_from, COALESCE(v_as_on, p_from));
    v_open := CASE v_book WHEN 'Cash' THEN COALESCE(v_cash, 0) WHEN 'Bank' THEN COALESCE(v_bank, 0)
                          ELSE COALESCE(v_cash, 0) + COALESCE(v_bank, 0) END;
    IF v_from > COALESCE(v_as_on, DATE '2000-01-01') THEN
        SELECT v_open + COALESCE(SUM(m.money_in - m.money_out), 0) INTO v_open
          FROM core.fn_school_money(p_tenant_id, p_school_id, COALESCE(v_as_on, DATE '2000-01-01'), v_from - 1) m
         WHERE v_book = 'All' OR m.book = v_book;
    END IF;

    CREATE TEMP TABLE IF NOT EXISTS _cb_lines (line_date date, kind varchar, ref varchar, detail varchar, category varchar,
                                               mode varchar, book varchar, money_in numeric, money_out numeric) ON COMMIT DROP;
    TRUNCATE _cb_lines;
    IF v_from <= p_to THEN
        INSERT INTO _cb_lines
        SELECT * FROM core.fn_school_money(p_tenant_id, p_school_id, v_from, p_to) m
         WHERE v_book = 'All' OR m.book = v_book;
    END IF;

    OPEN p_summary FOR
    SELECT v_from::text AS book_from, v_as_on::text AS opening_as_on, v_open AS opening,
           COALESCE(SUM(money_in), 0) AS money_in, COALESCE(SUM(money_out), 0) AS money_out,
           v_open + COALESCE(SUM(money_in - money_out), 0) AS closing
      FROM _cb_lines;

    OPEN p_lines FOR
    SELECT line_date::text AS line_date, kind, ref, detail, category, mode, money_in, money_out,
           v_open + SUM(money_in - money_out) OVER (ORDER BY line_date, money_out, kind, ref ROWS UNBOUNDED PRECEDING) AS balance
      FROM _cb_lines
     ORDER BY line_date, money_out, kind, ref;

    OPEN p_heads FOR
    SELECT category, SUM(money_in) AS money_in, SUM(money_out) AS money_out, COUNT(*)::int AS entries
      FROM _cb_lines
     GROUP BY category
     ORDER BY SUM(money_out) DESC, SUM(money_in) DESC;

    OPEN p_months FOR
    SELECT to_char(line_date, 'YYYY-MM') AS month, SUM(money_in) AS money_in, SUM(money_out) AS money_out,
           SUM(money_in - money_out) AS net
      FROM _cb_lines
     GROUP BY 1
     ORDER BY 1;
END;
$procedure$;

-- ===== inventory_student_sale.sql =====
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
--   * A class set ("Class 3 books") is a list of items with quantities per class
--     (core.inventory_class_kits). Picking a student fills it in; the store can
--     still change any quantity before giving.
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
    INOUT p_result         refcursor DEFAULT 'student_sale_cursor'::refcursor)
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

    -- ── Items: what the store sells, with the class set's quantity when asked
    IF p_operation = 'Items' THEN
        v_loc := COALESCE(p_location_id, core.fn_inventory_default_location(p_tenant_id, p_school_id, p_action_user_id));
        OPEN p_result FOR
        SELECT i.item_id, i.item_name, COALESCE(NULLIF(trim(i.category), ''), 'Other') AS category,
               i.unit_type, i.selling_price,
               COALESCE((SELECT ls.quantity FROM core.inventory_location_stock ls
                          WHERE ls.item_id = i.item_id AND ls.location_id = v_loc), 0) AS in_stock,
               COALESCE((SELECT k.quantity FROM core.inventory_class_kits k
                          WHERE k.tenant_id = p_tenant_id AND k.school_id = p_school_id
                            AND k.item_id = i.item_id AND k.class_name = p_class), 0) AS kit_qty
          FROM core.inventory_items i
         WHERE i.tenant_id = p_tenant_id AND i.school_id = p_school_id
           AND NOT i.is_deleted AND i.is_active AND i.item_type = 'Saleable'
         ORDER BY 3, i.item_name;
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

            INSERT INTO core.student_ledger
                (tenant_id, school_id, student_id, fee_head_name, frequency, installment_label,
                 due_date, amount_due, status, academic_year)
            VALUES (p_tenant_id, p_school_id, p_student_id, it.category, 'One Time',
                    it.item_name || CASE WHEN r.qty <> 1 THEN ' × ' || trim(to_char(r.qty, 'FM999999990.##')) ELSE '' END,
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
--   cursor 2  the columns: the class set's items, plus anything a child of the
--             class was sold that session
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
       AND (EXISTS (SELECT 1 FROM core.inventory_class_kits k
                     WHERE k.tenant_id = p_tenant_id AND k.school_id = p_school_id
                       AND k.class_name = p_class AND k.item_id = i.item_id AND k.quantity > 0)
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
