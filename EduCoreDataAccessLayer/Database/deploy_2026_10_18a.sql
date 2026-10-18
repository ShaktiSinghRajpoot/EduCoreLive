-- Bundle 2026-10-18a: School Calendar events (+ exams on the calendar), books & uniform sold to students on the fee account,
-- school purge covers both. Run with:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_18a.sql
-- Sources: school_events.sql, inventory_student_sale.sql, school_purge.sql

-- ===== school_events.sql =====
-- ============================================================================
-- School events on the School Calendar (PTM, annual function, sports day,
-- trip, staff meeting ...).
--
-- The calendar already says WHICH DAYS the school runs (school_calendar.sql:
-- holiday / half day / working). An event does not change that -- a PTM on a
-- Saturday is still whatever that Saturday is -- so events live in their own
-- table and may span several days or share a day with another event.
--
--   academic.sp_school_events_manage
--     List    (p_start_date..p_end_date) -> events AND exams overlapping the range,
--             one shape: kind = 'Event' | 'Exam'. Exams come from the Exam
--             Schedule (academic.exams) and only while the Exams module is on.
--     Save    (p_event_id NULL = new)    -> success, message, event_id
--     Delete  (soft)                     -> success, message
--
-- Re-runnable.
-- ============================================================================

CREATE TABLE IF NOT EXISTS academic.school_events (
    event_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   integer NOT NULL,
    school_id   integer NOT NULL,
    title       varchar(120) NOT NULL,
    event_type  varchar(20)  NOT NULL DEFAULT 'Event',   -- PTM | Event | Sports | Trip | Meeting | Other
    start_date  date NOT NULL,
    end_date    date NOT NULL,
    start_time  time,
    end_time    time,
    for_whom    varchar(120),                              -- free text ("Class 1-5 parents"); NULL = everyone
    notes       text,
    is_deleted  boolean NOT NULL DEFAULT FALSE,
    created_by  integer,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  integer,
    updated_at  timestamptz,

    CONSTRAINT chk_school_events_scope CHECK (tenant_id > 1 AND school_id > 0),
    CONSTRAINT chk_school_events_dates CHECK (end_date >= start_date),
    CONSTRAINT chk_school_events_type  CHECK (event_type IN ('PTM','Event','Sports','Trip','Meeting','Other'))
);

CREATE INDEX IF NOT EXISTS ix_school_events_date
    ON academic.school_events (tenant_id, school_id, start_date) WHERE NOT is_deleted;


CREATE OR REPLACE PROCEDURE academic.sp_school_events_manage(
    IN    p_operation      varchar,
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_event_id       integer DEFAULT NULL,
    IN    p_title          varchar DEFAULT NULL,
    IN    p_event_type     varchar DEFAULT NULL,
    IN    p_start_date     date    DEFAULT NULL,
    IN    p_end_date       date    DEFAULT NULL,
    IN    p_start_time     time    DEFAULT NULL,
    IN    p_end_time       time    DEFAULT NULL,
    IN    p_for_whom       varchar DEFAULT NULL,
    IN    p_notes          text    DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'school_events_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_title varchar := NULLIF(trim(p_title), '');
    v_type  varchar := COALESCE(NULLIF(trim(p_event_type), ''), 'Event');
    v_id    integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    -- ── List: everything on the calendar between two dates
    IF p_operation = 'List' THEN
        OPEN p_result FOR
        SELECT 'Event' AS kind, ev.event_id AS id, ev.title, ev.event_type,
               ev.start_date::text AS start_date, ev.end_date::text AS end_date,
               to_char(ev.start_time, 'HH24:MI') AS start_time, to_char(ev.end_time, 'HH24:MI') AS end_time,
               ev.for_whom, ev.notes, NULL::varchar AS status
          FROM academic.school_events ev
         WHERE ev.tenant_id = p_tenant_id AND ev.school_id = p_school_id AND NOT ev.is_deleted
           AND ev.start_date <= p_end_date AND ev.end_date >= p_start_date
        UNION ALL
        -- the exam period from the Exam Schedule, with the classes that sit it
        SELECT 'Exam', x.exam_id, x.exam_name, 'Exam',
               NULLIF(x.start_date::text, '')::date::text, NULLIF(x.end_date::text, '')::date::text, NULL, NULL,
               (SELECT string_agg(DISTINCT c.class_name, ', ')
                  FROM academic.exam_subjects es
                  JOIN academic.academic_classes c ON c.academic_class_id = es.academic_class_id
                 WHERE es.exam_id = x.exam_id),
               NULL, x.status
          FROM academic.exams x
         WHERE x.tenant_id = p_tenant_id AND x.school_id = p_school_id AND NOT x.is_deleted
           -- exam dates are stored as text (dates_as_text migration)
           AND NULLIF(x.start_date::text, '')::date <= p_end_date AND NULLIF(x.end_date::text, '')::date >= p_start_date
           AND core.fn_module_on(p_tenant_id, p_school_id, 'exams')
         ORDER BY 5, 3;
        RETURN;
    END IF;

    -- ── Save: add or change one event
    IF p_operation = 'Save' THEN
        IF v_title IS NULL THEN
            RAISE EXCEPTION 'Give the event a name.';
        END IF;
        IF v_type NOT IN ('PTM','Event','Sports','Trip','Meeting','Other') THEN
            RAISE EXCEPTION 'Unknown event type.';
        END IF;
        IF p_start_date IS NULL THEN
            RAISE EXCEPTION 'Pick the date of the event.';
        END IF;
        IF COALESCE(p_end_date, p_start_date) < p_start_date THEN
            RAISE EXCEPTION 'The event ends before it starts.';
        END IF;
        IF p_start_time IS NOT NULL AND p_end_time IS NOT NULL AND p_end_time <= p_start_time THEN
            RAISE EXCEPTION 'The end time must be after the start time.';
        END IF;

        IF p_event_id IS NULL THEN
            INSERT INTO academic.school_events
                (tenant_id, school_id, title, event_type, start_date, end_date, start_time, end_time,
                 for_whom, notes, created_by)
            VALUES (p_tenant_id, p_school_id, left(v_title, 120), v_type, p_start_date, COALESCE(p_end_date, p_start_date),
                    p_start_time, p_end_time, left(NULLIF(trim(p_for_whom), ''), 120), NULLIF(trim(p_notes), ''),
                    p_action_user_id)
            RETURNING event_id INTO v_id;
        ELSE
            UPDATE academic.school_events
               SET title = left(v_title, 120), event_type = v_type,
                   start_date = p_start_date, end_date = COALESCE(p_end_date, p_start_date),
                   start_time = p_start_time, end_time = p_end_time,
                   for_whom = left(NULLIF(trim(p_for_whom), ''), 120), notes = NULLIF(trim(p_notes), ''),
                   updated_by = p_action_user_id, updated_at = now()
             WHERE event_id = p_event_id AND tenant_id = p_tenant_id AND school_id = p_school_id AND NOT is_deleted
            RETURNING event_id INTO v_id;
            IF v_id IS NULL THEN
                RAISE EXCEPTION 'Event not found.';
            END IF;
        END IF;

        OPEN p_result FOR SELECT TRUE AS success, 'Event saved.' AS message, v_id AS event_id;
        RETURN;
    END IF;

    -- ── Delete (soft: kept for the record)
    IF p_operation = 'Delete' THEN
        UPDATE academic.school_events
           SET is_deleted = TRUE, updated_by = p_action_user_id, updated_at = now()
         WHERE event_id = p_event_id AND tenant_id = p_tenant_id AND school_id = p_school_id AND NOT is_deleted
        RETURNING event_id INTO v_id;
        IF v_id IS NULL THEN
            RAISE EXCEPTION 'Event not found.';
        END IF;
        OPEN p_result FOR SELECT TRUE AS success, 'Event removed.' AS message, v_id AS event_id;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation.';
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
    CONSTRAINT chk_inv_kit_qty CHECK (quantity > 0),
    CONSTRAINT uq_inv_kit_item UNIQUE (tenant_id, school_id, class_name, item_id)
);

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

    -- ── SaveKit: replace one class's set
    IF p_operation = 'SaveKit' THEN
        IF NULLIF(trim(p_class), '') IS NULL THEN
            RAISE EXCEPTION 'Choose a class.';
        END IF;
        DELETE FROM core.inventory_class_kits
         WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND class_name = trim(p_class);
        INSERT INTO core.inventory_class_kits (tenant_id, school_id, class_name, item_id, quantity, updated_by)
        SELECT p_tenant_id, p_school_id, trim(p_class), i.item_id, SUM(x.qty), p_action_user_id
          FROM jsonb_to_recordset(COALESCE(p_items, '[]'::jsonb)) AS x("itemId" integer, qty numeric)
          JOIN core.inventory_items i ON i.item_id = x."itemId" AND i.tenant_id = p_tenant_id AND i.school_id = p_school_id
                                     AND NOT i.is_deleted
         WHERE x.qty > 0
         GROUP BY i.item_id;
        GET DIAGNOSTICS v_n = ROW_COUNT;
        OPEN p_result FOR SELECT TRUE AS success, 'Set for ' || trim(p_class) || ' saved: ' || v_n || ' item(s).' AS message;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation.';
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
