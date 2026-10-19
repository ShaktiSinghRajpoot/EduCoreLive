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
--             Purchase cancelled | Supplier return | Supplier payment |
--             Supplier payment cancelled | Expense | Expense cancelled
--   A bill bought on credit (payment mode 'Credit') moves no money: the payments
--   to the supplier do (inventory_store_extras.sql).
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
