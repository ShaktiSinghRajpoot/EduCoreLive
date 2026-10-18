-- Bundle 2026-10-18d: Expenses and the Cash Book (expense_cashbook.sql); school purge covers them. Run with:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_18d.sql
-- Sources: expense_cashbook.sql, school_purge.sql

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
    WITH x AS (
        -- fee receipts and their cancellations, real money only
        SELECT ml.line_date, CASE WHEN ml.entry = 'Cancellation' THEN 'Fee cancelled' ELSE 'Fee receipt' END AS kind,
               p.receipt_no AS ref,
               COALESCE(s.student_name, e.student_name, 'Student') AS detail,
               'Fees'::varchar AS category, ml.mode,
               GREATEST(SUM(ml.amount), 0) AS money_in, GREATEST(-SUM(ml.amount), 0) AS money_out
          FROM core.fn_fee_money_lines(p_tenant_id, p_school_id, p_from, p_to) ml
          JOIN core.fee_payments p ON p.payment_id = ml.payment_id
          LEFT JOIN core.students  s ON s.student_id = p.student_id
          LEFT JOIN core.enquiries e ON e.enquiry_id = p.enquiry_id
         WHERE ml.mode NOT IN ('Advance', 'To wallet')
         GROUP BY ml.line_date, ml.entry, p.receipt_no, s.student_name, e.student_name, ml.mode
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

-- ===== school_purge.sql =====
-- ============================================================================
-- SCHOOL ARCHIVE + PURGE — permanently delete a school and all of its data.
--
-- WHY TWO PROCEDURES, NOT ONE
-- core.sp_school_archive is READ-ONLY and returns the school's entire data set as
-- JSON. core.sp_school_purge deletes. The caller runs archive first, writes the
-- file to disk, and only calls purge once that file exists. One combined proc
-- would mean a failed file write leaves the data already gone.
--
-- GUARDS ON PURGE (all enforced here, not just in the UI)
--   1. platform caller only (p_tenant_id = 1)
--   2. the school must already be CLOSED — closing is a separate, reversible act,
--      so purging always takes two deliberate steps
--   3. p_confirm_name must match the school name exactly
-- Any of these failing raises, and the whole thing rolls back.
--
-- COMPLETENESS IS SELF-CHECKED
-- The delete list below is explicit and ordered for foreign keys. After deleting,
-- the proc re-scans EVERY table in core/academic that has a school_id column and
-- raises if any row survived. So if someone adds a school-scoped table later and
-- forgets this proc, the purge FAILS LOUDLY and rolls back rather than silently
-- leaving orphans. That check is the actual guarantee — the list is just the plan.
--
-- core.fee_payment_details and core.fee_payment_tenders have no school_id but
-- cascade from core.fee_payments, so they need no explicit delete.
--
-- Oct 2026 (platform_access_security_tests.sql):
--   * the delete list now covers the modules added after it was written -- exams,
--     inventory, staff leave/payroll, enrolment, promotion history, day-close log.
--     A school that had run exams could not be purged at all (FK on exam_subjects).
--     Also the attendance / exam-mark edit history (academics_edit_history.sql).
--   * 2026-10-10: the result publish log and the grade scale (exam_results_publish.sql).
--   * 2026-10-10: inventory locations, location stock, transfers and supplier
--     returns (inventory.sql, store locations revision).
--   * 2026-10-11: live bus tracking -- trip points, trips and parent share links
--     (transport_live_tracking.sql). The share link's token_hash is stripped from
--     the archive like every other token_hash.
--   * the archive no longer carries secrets: password_reset_tokens is skipped and
--     password_hash / token_hash are stripped from every row. The file sits on disk.
--   * purging a tenant's ONLY school keeps the tenant and its roles (decision D-7):
--     roles are tenant-level rows (school_id NULL), which this purge never touches.
-- ============================================================================

-- ── ARCHIVE (read-only) ────────────────────────────────────────────────────
-- Built dynamically on purpose: it picks up any school-scoped table automatically,
-- so the archive can never fall behind the schema the way a hand-written list would.
CREATE OR REPLACE PROCEDURE core.sp_school_archive(
    IN p_tenant_id integer,
    IN p_school_id integer,
    INOUT p_result refcursor DEFAULT 'archive_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    r        record;
    v_json   jsonb;
    v_out    jsonb := '{}'::jsonb;
    v_rows   bigint;
    v_total  bigint := 0;
BEGIN
    IF p_tenant_id <> 1 THEN
        RAISE EXCEPTION 'Only the platform super admin can archive a school.';
    END IF;

    FOR r IN
        SELECT c.table_schema AS sch, c.table_name AS tbl
        FROM information_schema.columns c
        JOIN information_schema.tables t
          ON t.table_schema = c.table_schema AND t.table_name = c.table_name
         AND t.table_type = 'BASE TABLE'
        -- config is included: config.roles, config.role_permissions and
        -- config.lookup_value all carry a school_id for per-school overrides.
        -- Leaving it out was a real hole — purging a school stranded its role rows.
        WHERE c.column_name = 'school_id'
          AND c.table_schema IN ('core', 'academic', 'config')
          -- One-time reset codes are secrets with no archival value.
          AND NOT (c.table_schema = 'core' AND c.table_name = 'password_reset_tokens')
        ORDER BY 1, 2
    LOOP
        -- Secrets are stripped (password_hash, token_hash, user_sessions.refresh_token_hash):
        -- the archive is a file on disk.
        EXECUTE format('SELECT COALESCE(jsonb_agg(to_jsonb(x) - ''password_hash'' - ''token_hash'' - ''refresh_token_hash''), ''[]''::jsonb), count(*) FROM %I.%I x WHERE x.school_id = $1',
                       r.sch, r.tbl)
        INTO v_json, v_rows
        USING p_school_id;

        IF v_rows > 0 THEN
            v_out := v_out || jsonb_build_object(r.sch || '.' || r.tbl, v_json);
            v_total := v_total + v_rows;
        END IF;
    END LOOP;

    OPEN p_result FOR
    SELECT
        p_school_id                                   AS school_id,
        (SELECT school_code FROM core.schools WHERE school_id = p_school_id) AS school_code,
        (SELECT school_name FROM core.schools WHERE school_id = p_school_id) AS school_name,
        v_total                                       AS total_rows,
        jsonb_pretty(
            jsonb_build_object(
                'archived_at', to_char(NOW(), 'YYYY-MM-DD"T"HH24:MI:SS'),
                'school_id',   p_school_id,
                'data',        v_out
            )
        )                                             AS archive_json;
END;
$procedure$;

-- ── PURGE (destructive) ────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE core.sp_school_purge(
    IN p_tenant_id integer,
    IN p_school_id integer,
    IN p_action_user_id integer,
    IN p_confirm_name character varying,
    INOUT p_result refcursor DEFAULT 'purge_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_school_tenant integer;
    v_name          character varying;
    v_code          character varying;
    v_status        character varying;
    r               record;
    v_left          bigint;
BEGIN
    IF p_tenant_id <> 1 THEN
        RAISE EXCEPTION 'Only the platform super admin can purge a school.';
    END IF;

    SELECT s.tenant_id, s.school_name, s.school_code, COALESCE(st.status_code, 'UNKNOWN')
      INTO v_school_tenant, v_name, v_code, v_status
    FROM core.schools s
    LEFT JOIN config.school_statuses st ON st.school_status_id = s.status_id
    WHERE s.school_id = p_school_id;

    IF v_name IS NULL THEN
        RAISE EXCEPTION 'School not found.';
    END IF;

    -- Two deliberate steps: close first (reversible), purge second (not).
    IF v_status <> 'CLOSED' THEN
        RAISE EXCEPTION 'Only a Closed school can be purged. Set the status to Closed first.';
    END IF;

    IF p_confirm_name IS NULL OR TRIM(p_confirm_name) <> TRIM(v_name) THEN
        RAISE EXCEPTION 'Confirmation name does not match the school name.';
    END IF;

    -- Audit BEFORE the delete: admin_activity_logs is itself school-scoped, so a row
    -- written here would be wiped below. Logged against the platform tenant instead,
    -- with no school_id, so the record outlives the school.
    INSERT INTO core.admin_activity_logs
        (tenant_id, user_id, school_id, action, module_name, table_name, record_id, description, created_by, created_at)
    VALUES
        (1, p_action_user_id, NULL, 'SCHOOL_PURGE', 'SuperAdmin/Schools', 'core.schools', p_school_id,
         format('Permanently purged school %s (%s), tenant %s', v_code, v_name, v_school_tenant),
         p_action_user_id, NOW());

    -- ── Deletes, ordered so no foreign key is violated ─────────────────────
    -- academic: timetable and class_subjects reference sections/classes/subjects
    -- exams reference classes and subjects; marks reference students
    DELETE FROM academic.exam_result_log           WHERE school_id = p_school_id;
    DELETE FROM academic.grade_scale               WHERE school_id = p_school_id;
    DELETE FROM academic.exam_marks_history        WHERE school_id = p_school_id;
    DELETE FROM academic.exam_marks                WHERE school_id = p_school_id;
    DELETE FROM academic.exam_mark_sheets          WHERE school_id = p_school_id;
    DELETE FROM academic.exam_class_sections       WHERE school_id = p_school_id;
    DELETE FROM academic.exam_subjects             WHERE school_id = p_school_id;
    DELETE FROM academic.exams                     WHERE school_id = p_school_id;

    DELETE FROM academic.timetable                 WHERE school_id = p_school_id;
    DELETE FROM academic.class_subjects            WHERE school_id = p_school_id;
    DELETE FROM academic.period_structure          WHERE school_id = p_school_id;
    DELETE FROM academic.school_calendar           WHERE school_id = p_school_id;
    DELETE FROM academic.school_calendar_settings  WHERE school_id = p_school_id;
    DELETE FROM academic.school_events             WHERE school_id = p_school_id;
    DELETE FROM academic.academic_class_sections   WHERE school_id = p_school_id;
    DELETE FROM academic.academic_classes          WHERE school_id = p_school_id;
    DELETE FROM academic.school_subjects           WHERE school_id = p_school_id;
    DELETE FROM academic.academic_years            WHERE school_id = p_school_id;

    -- student-linked data before students
    DELETE FROM core.student_attendance_history    WHERE school_id = p_school_id;
    DELETE FROM core.student_attendance            WHERE school_id = p_school_id;
    DELETE FROM core.student_transport             WHERE school_id = p_school_id;
    DELETE FROM core.student_advance               WHERE school_id = p_school_id;
    DELETE FROM core.student_fee_plan              WHERE school_id = p_school_id;
    -- books & uniform sold to students (inventory_student_sale.sql): before the students and items
    DELETE FROM core.inventory_student_sale_lines l USING core.inventory_student_sales sa
     WHERE l.sale_id = sa.sale_id AND sa.school_id = p_school_id;
    DELETE FROM core.inventory_student_sales       WHERE school_id = p_school_id;
    DELETE FROM core.inventory_class_kits          WHERE school_id = p_school_id;
    -- expenses and the cash book's opening balance (expense_cashbook.sql)
    DELETE FROM core.expenses                      WHERE school_id = p_school_id;
    DELETE FROM core.expense_categories            WHERE school_id = p_school_id;
    DELETE FROM core.cashbook_opening              WHERE school_id = p_school_id;
    DELETE FROM core.student_ledger                WHERE school_id = p_school_id;
    DELETE FROM core.tc_register                   WHERE school_id = p_school_id;
    DELETE FROM core.tc_counters                   WHERE school_id = p_school_id;
    DELETE FROM core.student_enrolment             WHERE school_id = p_school_id;
    DELETE FROM core.student_promotion_history     WHERE school_id = p_school_id;
    DELETE FROM core.students                      WHERE school_id = p_school_id;

    -- enquiries (children cascade, deleted explicitly for clarity)
    DELETE FROM core.enquiry_followups             WHERE school_id = p_school_id;
    DELETE FROM core.enquiry_status_history        WHERE school_id = p_school_id;
    DELETE FROM core.enquiries                     WHERE school_id = p_school_id;

    -- money: fee_payment_details / _tenders cascade from fee_payments
    DELETE FROM core.fee_refunds                   WHERE school_id = p_school_id;
    DELETE FROM core.fee_reminder_log              WHERE school_id = p_school_id;
    DELETE FROM core.fee_day_close_log             WHERE school_id = p_school_id;
    DELETE FROM core.fee_day_close                 WHERE school_id = p_school_id;
    DELETE FROM core.fee_payments                  WHERE school_id = p_school_id;
    DELETE FROM core.school_fee_structure_details  WHERE school_id = p_school_id;
    DELETE FROM core.school_fee_structures         WHERE school_id = p_school_id;
    DELETE FROM core.school_fee_heads              WHERE school_id = p_school_id;

    -- counters / audit trails
    DELETE FROM core.admission_audit               WHERE school_id = p_school_id;
    DELETE FROM core.admission_counters            WHERE school_id = p_school_id;
    DELETE FROM core.registration_counters         WHERE school_id = p_school_id;
    DELETE FROM core.receipt_counters              WHERE school_id = p_school_id;

    -- transport: live tracking first (points -> trips -> vehicles/routes/staff,
    -- share links -> routes); vehicles reference routes and staff (SET NULL),
    -- stops cascade
    DELETE FROM core.transport_trip_points         WHERE school_id = p_school_id;
    DELETE FROM core.transport_trips               WHERE school_id = p_school_id;
    DELETE FROM core.transport_route_shares        WHERE school_id = p_school_id;
    DELETE FROM core.transport_stops               WHERE school_id = p_school_id;
    DELETE FROM core.transport_vehicles            WHERE school_id = p_school_id;
    DELETE FROM core.transport_routes              WHERE school_id = p_school_id;

    -- inventory: returns, transfers, location stock, purchase lines and the
    -- stock ledger reference items/purchases/locations, so they go first
    DELETE FROM core.inventory_purchase_returns    WHERE school_id = p_school_id;
    DELETE FROM core.inventory_transfers           WHERE school_id = p_school_id;
    DELETE FROM core.inventory_location_stock      WHERE school_id = p_school_id;
    DELETE FROM core.inventory_purchase_items      WHERE school_id = p_school_id;
    DELETE FROM core.inventory_stock_ledger        WHERE school_id = p_school_id;
    DELETE FROM core.inventory_purchases           WHERE school_id = p_school_id;
    DELETE FROM core.inventory_items               WHERE school_id = p_school_id;
    DELETE FROM core.inventory_locations           WHERE school_id = p_school_id;
    DELETE FROM core.inventory_suppliers           WHERE school_id = p_school_id;

    -- school configuration
    DELETE FROM core.school_documents              WHERE school_id = p_school_id;
    DELETE FROM core.school_working_hours          WHERE school_id = p_school_id;
    DELETE FROM core.school_admission_workflow_settings WHERE school_id = p_school_id;
    DELETE FROM core.school_settings               WHERE school_id = p_school_id;
    DELETE FROM core.school_contacts               WHERE school_id = p_school_id;
    DELETE FROM core.school_addresses              WHERE school_id = p_school_id;
    DELETE FROM core.school_profiles               WHERE school_id = p_school_id;

    -- people: staff references users, so staff first
    DELETE FROM core.admin_activity_logs           WHERE school_id = p_school_id;
    DELETE FROM core.login_attempts                WHERE school_id = p_school_id;
    DELETE FROM core.password_reset_tokens         WHERE school_id = p_school_id;
    DELETE FROM core.user_sessions                 WHERE school_id = p_school_id;
    DELETE FROM core.user_roles                    WHERE school_id = p_school_id;
    DELETE FROM core.user_profiles                 WHERE school_id = p_school_id;
    DELETE FROM core.staff_leave                   WHERE school_id = p_school_id;
    DELETE FROM core.staff_payroll_history         WHERE school_id = p_school_id;
    DELETE FROM core.staff_payroll_adjustment      WHERE school_id = p_school_id;
    DELETE FROM core.staff_payroll                 WHERE school_id = p_school_id;
    DELETE FROM core.staff                         WHERE school_id = p_school_id;
    DELETE FROM core.users                         WHERE school_id = p_school_id;

    -- config: per-school overrides. Only rows carrying THIS school's id go — the
    -- tenant-level rows (school_id NULL) and platform defaults (school_id 0) are
    -- shared and must survive. config.roles in particular holds a school's own
    -- role rows, which login joins on.
    DELETE FROM config.role_permissions            WHERE school_id = p_school_id;
    DELETE FROM config.roles                       WHERE school_id = p_school_id;
    DELETE FROM config.lookup_value                WHERE school_id = p_school_id;

    -- and finally the school itself
    DELETE FROM core.schools                       WHERE school_id = p_school_id;

    -- ── Completeness check ─────────────────────────────────────────────────
    -- Re-scan every school-scoped table. Anything left means the list above is out
    -- of date, so fail and roll the whole purge back rather than leave orphans.
    FOR r IN
        SELECT c.table_schema AS sch, c.table_name AS tbl
        FROM information_schema.columns c
        JOIN information_schema.tables t
          ON t.table_schema = c.table_schema AND t.table_name = c.table_name
         AND t.table_type = 'BASE TABLE'
        -- config is included: config.roles, config.role_permissions and
        -- config.lookup_value all carry a school_id for per-school overrides.
        -- Leaving it out was a real hole — purging a school stranded its role rows.
        WHERE c.column_name = 'school_id'
          AND c.table_schema IN ('core', 'academic', 'config')
    LOOP
        EXECUTE format('SELECT count(*) FROM %I.%I WHERE school_id = $1', r.sch, r.tbl)
        INTO v_left USING p_school_id;

        IF v_left > 0 THEN
            RAISE EXCEPTION
                'Purge incomplete: % row(s) remain in %.%. Add it to core.sp_school_purge.',
                v_left, r.sch, r.tbl;
        END IF;
    END LOOP;

    OPEN p_result FOR
    SELECT p_school_id AS school_id, v_code AS school_code, v_name AS school_name;
END;
$procedure$;
