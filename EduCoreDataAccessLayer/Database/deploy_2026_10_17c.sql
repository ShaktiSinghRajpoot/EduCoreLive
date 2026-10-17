-- Bundle 2026-10-17c: fee due list + collection register use the session's class, bus seats count riders whose bus has started, dashboard attendance (staff today + defaulters). Run with:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_17c.sql
-- Sources (re-runnable, in this order): fee_due_list.sql, fee_reports.sql, transport_module.sql, dashboard_attendance.sql

-- ============================================================================
-- Fee Due Reminders — server-side paged/filtered defaulters list.
--
-- One row per student who owes money that has FALLEN DUE (due_date on or before
-- today), with that total, how many days the OLDEST unpaid installment is
-- overdue, and an ageing bucket. Next months' instalments are not owed yet, so
-- they are not counted -- the amount here is the {due_amount} a reminder sends.
--
-- Same rule as core.sp_fee_defaulters_get, including for students who have left:
-- they are listed while they still owe (student_status says so), so the office
-- can chase them and the two screens total the same.
-- Separate from core.sp_fee_defaulters_get (the report proc, which returns the
-- full un-paged ageing breakdown) so the screen can page/filter/sort server-side.
--
-- total_count / sum_outstanding are window aggregates over the FULL filtered set
-- (before LIMIT) so the KPI tiles and pager stay correct on every page.
-- Sort column is whitelisted via CASE — never interpolated, so injection-safe.
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================
CREATE OR REPLACE PROCEDURE core.sp_fee_due_list(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_search         varchar   DEFAULT NULL,
    IN    p_class          varchar   DEFAULT NULL,
    IN    p_bucket         varchar   DEFAULT NULL,   -- 0-30 | 31-60 | 60+
    IN    p_page_no        integer   DEFAULT 1,
    IN    p_page_size      integer   DEFAULT 10,
    IN    p_sort_column    varchar   DEFAULT NULL,   -- name | class | due | days
    IN    p_sort_dir       varchar   DEFAULT 'desc',
    INOUT p_result         refcursor DEFAULT 'fee_due_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_offset integer;
    v_col    text;
    v_asc    boolean;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    IF p_page_no   IS NULL OR p_page_no   < 1 THEN p_page_no   := 1;  END IF;
    IF p_page_size IS NULL OR p_page_size < 1 THEN p_page_size := 10; END IF;
    v_offset := (p_page_no - 1) * p_page_size;

    v_col := lower(COALESCE(NULLIF(TRIM(p_sort_column), ''), ''));
    v_asc := (lower(COALESCE(p_sort_dir, 'desc')) <> 'desc');

    OPEN p_result FOR
    WITH dues AS (
        SELECT sl.student_id,
               (sl.amount_due - sl.amount_paid - COALESCE(sl.concession, 0)) AS outstanding,
               sl.due_date
        FROM core.student_ledger sl
        WHERE sl.tenant_id = p_tenant_id
          AND sl.school_id = p_school_id
          AND sl.amount_due > sl.amount_paid + COALESCE(sl.concession, 0)
          AND (sl.due_date IS NULL OR sl.due_date::date <= CURRENT_DATE)
    ),
    agg AS (
        -- the class of the session in progress (a child promoted early is still in
        -- the old one); a child admitted for next session shows that session after
        -- the class, so "Class 1 (2027-28)" is not mixed with this year's Class 1
        SELECT s.student_id, s.student_name, s.admission_no,
               COALESCE(e.class_name,
                        s.class_name || CASE WHEN s.academic_year IS DISTINCT FROM core.fn_session_on(p_tenant_id, p_school_id, CURRENT_DATE)
                                             THEN ' (' || s.academic_year || ')' ELSE '' END) AS class_name,
               COALESCE(e.section, s.section) AS section,
               COALESCE(NULLIF(TRIM(e.roll_no), ''), s.roll_no) AS roll_no, s.mobile,
               -- Parent email drives the Email reminder channel (father first, else mother).
               COALESCE(NULLIF(TRIM(s.father_email), ''), NULLIF(TRIM(s.mother_email), '')) AS parent_email,
               CASE WHEN COALESCE(s.is_active, TRUE) THEN 'Active'
                    ELSE COALESCE(NULLIF(TRIM(s.status), ''), 'Left') END AS student_status,
               -- money waiting in the student's advance wallet is set against what is due:
               -- a parent who overpaid is not a defaulter (no reminder, no admit-card hold)
               SUM(d.outstanding) - COALESCE(MAX(adv.balance), 0) AS total_outstanding,
               -- days the OLDEST unpaid installment is past its due date (0 = due today)
               COALESCE(MAX(CURRENT_DATE - d.due_date::date), 0) AS overdue_days
        FROM dues d
        JOIN core.students s ON s.student_id = d.student_id
        LEFT JOIN core.student_advance adv
               ON adv.student_id = s.student_id AND adv.tenant_id = p_tenant_id AND adv.school_id = p_school_id
        LEFT JOIN core.student_enrolment e
               ON e.student_id = s.student_id
              AND e.academic_year = core.fn_session_on(p_tenant_id, p_school_id, CURRENT_DATE)
        WHERE s.tenant_id = p_tenant_id
          AND s.school_id = p_school_id
          AND (p_class IS NULL OR TRIM(p_class) = '' OR COALESCE(e.class_name, s.class_name) = p_class)
          AND (p_search IS NULL OR TRIM(p_search) = ''
               OR s.student_name        ILIKE '%' || p_search || '%'
               OR s.admission_no        ILIKE '%' || p_search || '%'
               OR COALESCE(s.mobile,'') ILIKE '%' || p_search || '%')
        GROUP BY s.student_id, s.student_name, s.admission_no,
                 s.class_name, s.section, s.roll_no, s.academic_year, e.class_name, e.section, e.roll_no, s.mobile,
                 s.father_email, s.mother_email, s.is_active, s.status
        HAVING SUM(d.outstanding) - COALESCE(MAX(adv.balance), 0) > 0
    ),
    filtered AS (
        SELECT a.*,
               CASE WHEN a.overdue_days <= 30 THEN '0-30'
                    WHEN a.overdue_days <= 60 THEN '31-60'
                    ELSE '60+' END AS bucket
        FROM agg a
    )
    SELECT f.student_id, f.student_name, f.admission_no, f.class_name, f.section, f.roll_no,
           f.mobile, f.parent_email, f.student_status,
           f.total_outstanding, f.overdue_days, f.bucket,
           lr.sent_at                   AS last_reminder_at,
           COUNT(*)               OVER() AS total_count,
           SUM(f.total_outstanding) OVER() AS sum_outstanding
    FROM filtered f
    -- Most recent DELIVERED reminder for this student (drives the "Last" column).
    LEFT JOIN LATERAL (
        SELECT r.sent_at
        FROM core.fee_reminder_log r
        WHERE r.tenant_id = p_tenant_id AND r.school_id = p_school_id
          AND r.student_id = f.student_id
          AND COALESCE(r.channels_delivered, '') <> ''
        ORDER BY r.sent_at DESC
        LIMIT 1
    ) lr ON TRUE
    WHERE (p_bucket IS NULL OR TRIM(p_bucket) = '' OR f.bucket = p_bucket)
    ORDER BY
        CASE WHEN v_col = 'name'  AND v_asc     THEN student_name END ASC  NULLS LAST,
        CASE WHEN v_col = 'name'  AND NOT v_asc THEN student_name END DESC NULLS LAST,
        CASE WHEN v_col = 'class' AND v_asc     THEN class_name END ASC  NULLS LAST,
        CASE WHEN v_col = 'class' AND NOT v_asc THEN class_name END DESC NULLS LAST,
        CASE WHEN v_col = 'due'   AND v_asc     THEN total_outstanding END ASC,
        CASE WHEN v_col = 'due'   AND NOT v_asc THEN total_outstanding END DESC,
        CASE WHEN v_col = 'days'  AND v_asc     THEN overdue_days END ASC,
        CASE WHEN v_col = 'days'  AND NOT v_asc THEN overdue_days END DESC,
        total_outstanding DESC, student_name   -- stable default: biggest dues first
    LIMIT p_page_size OFFSET v_offset;
END;
$procedure$;

-- ============================================================================
-- Fee REPORTS — ERP → Fee → Reports
--
--   1. Collection Register : receipts and cancellations in a date range, with
--      totals by TRUE payment mode and by fee head. School-wide (all cashiers),
--      optionally for one class / section.
--   2. Defaulters / Outstanding : who owes money that has FALLEN DUE, with
--      aging, plus registration fees part-paid before admission.
--
-- Rules shared with Day Close and the Dashboard (see fee_day_close.sql):
--   * money is read through core.fn_fee_money_lines (tenders, not the header);
--   * a receipt stays on the day it was issued, and a cancellation is a
--     negative line on the day it was cancelled -- so a past range never
--     changes when an old receipt is cancelled.
--
-- Apply AFTER fee_day_close.sql (it defines fn_fee_money_lines).
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── 1. Collection register (receipts + mode + head summaries) ───────────────
-- Grew p_class / p_section: drop the old signature so one overload exists.
DROP PROCEDURE IF EXISTS core.sp_fee_collection_register(integer, integer, integer, date, date, refcursor, refcursor, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_fee_collection_register(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_from           date,
    IN    p_to             date,
    IN    p_class          varchar DEFAULT NULL,
    IN    p_section        varchar DEFAULT NULL,
    INOUT p_receipts       refcursor DEFAULT 'receipts_cursor'::refcursor,
    INOUT p_modes          refcursor DEFAULT 'modes_cursor'::refcursor,
    INOUT p_heads          refcursor DEFAULT 'heads_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_from    date;
    v_to      date;
    v_class   varchar := NULLIF(trim(p_class), '');
    v_section varchar := NULLIF(trim(p_section), '');
    v_reghead varchar;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;
    -- A blank range is the month to date -- the same default as the refund
    -- register, because the page nets one against the other.
    v_from := COALESCE(p_from, date_trunc('month', CURRENT_DATE)::date);
    v_to   := COALESCE(p_to,   CURRENT_DATE);
    -- The school's own name for its registration head, not a hard-coded label.
    v_reghead := core.fn_registration_fee_head_name(p_tenant_id, p_school_id);

    -- The events in range: each receipt on its own day (+), each cancellation
    -- on the day it was cancelled (-). Filtered by the payer's class/section.
    CREATE TEMP TABLE IF NOT EXISTS tmp_reg_ev
        (payment_id integer, sgn integer, line_date date, entry varchar) ON COMMIT DROP;
    TRUNCATE tmp_reg_ev;
    INSERT INTO tmp_reg_ev
    SELECT x.payment_id, x.sgn, x.line_date, x.entry
    FROM (
        SELECT p.payment_id, 1 AS sgn, p.payment_date::date AS line_date, 'Receipt'::varchar AS entry
        FROM core.fee_payments p
        WHERE p.tenant_id = p_tenant_id AND p.school_id = p_school_id
          AND p.payment_date BETWEEN to_char(v_from, 'YYYY-MM-DD') AND to_char(v_to, 'YYYY-MM-DD')
        UNION ALL
        SELECT p.payment_id, -1, COALESCE(p.cancelled_at::date, p.payment_date::date), 'Cancellation'
        FROM core.fee_payments p
        WHERE p.tenant_id = p_tenant_id AND p.school_id = p_school_id
          AND COALESCE(p.is_cancelled, FALSE)
          AND COALESCE(p.cancelled_at::date, p.payment_date::date) BETWEEN v_from AND v_to
    ) x
    JOIN core.fee_payments p ON p.payment_id = x.payment_id
    LEFT JOIN core.students  s ON s.student_id = p.student_id
    LEFT JOIN core.enquiries e ON e.enquiry_id = p.enquiry_id
    -- the class the child was in on the receipt's date, not after a later promotion
    LEFT JOIN core.student_enrolment en ON en.student_id = p.student_id
          AND en.academic_year = core.fn_session_on(p_tenant_id, p_school_id, p.payment_date::date)
    WHERE (v_class   IS NULL OR COALESCE(en.class_name, s.class_name, e.class_name) = v_class)
      AND (v_section IS NULL OR lower(COALESCE(en.section, s.section, '')) = lower(v_section));

    OPEN p_receipts FOR
    -- A payment belongs to a STUDENT or an ENQUIRY (registration fee taken before
    -- the student exists); name and class come from whichever applies.
    SELECT ev.entry,
           p.receipt_no,
           p.payment_date,
           ev.line_date,
           ev.sgn * p.amount                                      AS amount,
           -- The real split, e.g. "Cash 1200.00 + UPI 800.00", never "Mixed".
           COALESCE((SELECT string_agg(t.mode || ' ' || to_char(t.amount, 'FM999999990.00'), ' + ' ORDER BY t.tender_id)
                       FROM core.fee_payment_tenders t WHERE t.payment_id = p.payment_id),
                    p.payment_mode)                               AS payment_mode,
           COALESCE(NULLIF(TRIM(p.payment_type), ''), 'Fee')      AS payment_type,
           COALESCE(s.student_name, e.student_name, '—')          AS student_name,
           COALESCE(s.admission_no,
                    CASE WHEN e.enquiry_id IS NOT NULL
                         THEN COALESCE(NULLIF(e.registration_number, ''), 'Registration')
                    END,
                    '—')                                          AS admission_no,
           COALESCE(en.class_name, s.class_name, e.class_name)    AS class_name,
           COALESCE(en.section, s.section)                        AS section,
           p.reference_no,
           COALESCE(p.concession_total, 0) + COALESCE(p.discount_amount, 0) AS discount_total,
           COALESCE(
               (SELECT string_agg(DISTINCT d.fee_head_name, ', ' ORDER BY d.fee_head_name)
                FROM core.fee_payment_details d
                WHERE d.payment_id = p.payment_id),
               CASE WHEN p.payment_type = 'Registration' THEN v_reghead END,
               '—')                                               AS fee_heads,
           COALESCE(p.is_cancelled, FALSE)                        AS is_cancelled,
           p.cancelled_at,
           p.cancel_reason,
           core.fn_user_display_name(CASE WHEN ev.sgn = 1 THEN p.created_by
                                          ELSE COALESCE(p.cancelled_by, p.created_by) END) AS cashier_name
    FROM tmp_reg_ev ev
    JOIN core.fee_payments p   ON p.payment_id  = ev.payment_id
    LEFT JOIN core.students  s ON s.student_id  = p.student_id
    LEFT JOIN core.enquiries e ON e.enquiry_id  = p.enquiry_id
    LEFT JOIN core.student_enrolment en ON en.student_id = p.student_id
          AND en.academic_year = core.fn_session_on(p_tenant_id, p_school_id, p.payment_date::date)
    ORDER BY ev.line_date, p.payment_id, ev.sgn DESC;

    -- By TRUE mode (tender lines). 'To wallet' takes an overpaid surplus back
    -- out so the panel sums to the receipts total.
    OPEN p_modes FOR
    SELECT ml.mode AS payment_mode, COUNT(DISTINCT ml.payment_id) AS cnt, SUM(ml.amount) AS amount
    FROM core.fn_fee_money_lines(p_tenant_id, p_school_id, v_from, v_to) ml
    WHERE EXISTS (SELECT 1 FROM tmp_reg_ev ev
                  WHERE ev.payment_id = ml.payment_id AND ev.entry = ml.entry)
    GROUP BY ml.mode
    HAVING SUM(ml.amount) <> 0
    ORDER BY ml.mode;

    -- Head-wise split. Receipt lines (+) and cancelled lines (-). A registration
    -- fee has no detail lines, so the whole receipt is its registration head.
    OPEN p_heads FOR
    SELECT COALESCE(d.fee_head_name,
                    CASE WHEN p.payment_type = 'Registration' THEN v_reghead ELSE 'Other' END) AS fee_head_name,
           COUNT(DISTINCT ev.payment_id)::int                                                AS cnt,
           SUM(ev.sgn * COALESCE(d.amount, p.amount))                                        AS amount
    FROM tmp_reg_ev ev
    JOIN core.fee_payments p ON p.payment_id = ev.payment_id
    LEFT JOIN core.fee_payment_details d ON d.payment_id = ev.payment_id
    GROUP BY 1
    HAVING SUM(ev.sgn * COALESCE(d.amount, p.amount)) <> 0
    ORDER BY SUM(ev.sgn * COALESCE(d.amount, p.amount)) DESC;
END;
$procedure$;

-- ── 2. Defaulters / outstanding with aging ──────────────────────────────────
-- What is OWED is what has fallen due (due_date on or before today; a charge
-- with no date counts as due). Instalments not yet due are shown in their own
-- "Not due" column for planning, but they are not a debt: a family that has
-- paid everything due so far is not a defaulter.
--
-- One rule for students who have left: if they still owe money that fell due,
-- they are listed (status says so), here and on the Fee Due list alike.
--
-- A registration fee part-paid before admission has no ledger yet; its balance
-- is listed as its own row (entry = 'Registration', student_id NULL).
--
-- Session filter (p_academic_year; NULL or blank = all sessions). The session
-- a ledger row belongs to is the first of:
--   1. student_ledger.academic_year (written by fn_student_bill_plan since
--      2026-10-10, see student_money_lifecycle.sql);
--   2. the school's session whose start..end dates contain the row's due date;
--   3. the student's own session (core.students.academic_year);
--   4. the current session.
-- Rows billed before the column existed are blank in (1), so (2)/(3) place
-- them; anything still unplaced counts in the current session, which is the
-- report's default, so an old due is never dropped from the report.
-- A registration row belongs to its enquiry's session (core.enquiries.session),
-- else the current session.
-- Grew p_academic_year: drop the old signature so one overload exists.
DROP PROCEDURE IF EXISTS core.sp_fee_defaulters_get(integer, integer, integer, varchar, varchar, refcursor);
DROP PROCEDURE IF EXISTS core.sp_fee_defaulters_get(integer, integer, integer, varchar, varchar, varchar, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_fee_defaulters_get(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_class          varchar,
    IN    p_section        varchar,
    INOUT p_result         refcursor DEFAULT 'result_cursor'::refcursor,
    -- Last, so the older positional calls (..., p_section, cursor) still bind.
    IN    p_academic_year  varchar DEFAULT NULL
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_class   varchar := NULLIF(trim(p_class), '');
    v_section varchar := NULLIF(trim(p_section), '');
    v_year    varchar := lower(NULLIF(trim(p_academic_year), ''));
    v_current varchar;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;

    SELECT y.academic_year_name INTO v_current
    FROM academic.academic_years y
    WHERE y.tenant_id = p_tenant_id AND y.school_id = p_school_id
      AND y.is_current AND COALESCE(y.is_deleted, FALSE) = FALSE
    ORDER BY y.start_date DESC
    LIMIT 1;

    OPEN p_result FOR
    WITH dues AS (
        SELECT sl.student_id,
               (sl.amount_due - sl.amount_paid - COALESCE(sl.concession, 0)) AS outstanding,
               sl.due_date::date AS due_on,
               (sl.due_date IS NULL OR sl.due_date::date <= CURRENT_DATE)    AS is_due
        FROM core.student_ledger sl
        JOIN core.students s0 ON s0.student_id = sl.student_id
        LEFT JOIN LATERAL (
            SELECT y.academic_year_name
            FROM academic.academic_years y
            WHERE y.tenant_id = p_tenant_id AND y.school_id = p_school_id
              AND COALESCE(y.is_deleted, FALSE) = FALSE
              AND left(sl.due_date, 10) BETWEEN y.start_date AND y.end_date
            ORDER BY y.start_date
            LIMIT 1
        ) ys ON v_year IS NOT NULL
        WHERE sl.tenant_id = p_tenant_id AND sl.school_id = p_school_id
          AND sl.amount_due > sl.amount_paid + COALESCE(sl.concession, 0)
          AND (v_year IS NULL
               OR lower(COALESCE(NULLIF(trim(sl.academic_year), ''),
                                 ys.academic_year_name,
                                 NULLIF(trim(s0.academic_year), ''),
                                 v_current)) = v_year)
    ),
    students AS (
        SELECT 'Student'::varchar AS entry,
               s.student_id,
               s.student_name,
               s.admission_no,
               COALESCE(e.class_name, s.class_name) AS class_name,
               COALESCE(e.section, s.section)       AS section,
               COALESCE(NULLIF(trim(e.roll_no), ''), s.roll_no) AS roll_no,
               CASE WHEN COALESCE(s.is_active, TRUE) THEN 'Active'
                    ELSE COALESCE(NULLIF(trim(s.status), ''), 'Left') END                          AS student_status,
               COALESCE(SUM(d.outstanding) FILTER (WHERE d.is_due), 0)                             AS total_outstanding,
               COALESCE(SUM(d.outstanding) FILTER (WHERE NOT d.is_due), 0)                         AS not_due,
               COALESCE(SUM(d.outstanding) FILTER (WHERE d.is_due AND (d.due_on IS NULL OR CURRENT_DATE - d.due_on <= 30)), 0) AS d0_30,
               COALESCE(SUM(d.outstanding) FILTER (WHERE d.is_due AND CURRENT_DATE - d.due_on BETWEEN 31 AND 60), 0)          AS d31_60,
               COALESCE(SUM(d.outstanding) FILTER (WHERE d.is_due AND CURRENT_DATE - d.due_on > 60), 0)                      AS d60_plus
        FROM dues d
        JOIN core.students s ON s.student_id = d.student_id
                            AND s.tenant_id = p_tenant_id AND s.school_id = p_school_id
        -- with a session chosen, the class they had IN that session (a child
        -- promoted early still owes this year's fees as a member of the old class)
        LEFT JOIN core.student_enrolment e ON e.student_id = s.student_id AND v_year IS NOT NULL
                                          AND lower(e.academic_year) = v_year
        WHERE (v_class   IS NULL OR COALESCE(e.class_name, s.class_name) = v_class)
          AND (v_section IS NULL OR lower(COALESCE(e.section, s.section, '')) = lower(v_section))
        GROUP BY s.student_id, s.student_name, s.admission_no, e.class_name, e.section, e.roll_no,
                 s.class_name, s.section, s.roll_no, s.is_active, s.status
        HAVING COALESCE(SUM(d.outstanding) FILTER (WHERE d.is_due), 0) > 0
    ),
    registrations AS (
        -- Not admitted yet, fee agreed, not fully settled.
        SELECT 'Registration'::varchar AS entry,
               NULL::integer AS student_id,
               e.student_name,
               COALESCE(NULLIF(e.registration_number, ''), 'Registration') AS admission_no,
               e.class_name,
               NULL::varchar AS section,
               NULL::varchar AS roll_no,
               'Registered'::varchar AS student_status,
               b.balance AS total_outstanding,
               0::numeric AS not_due,
               CASE WHEN COALESCE(CURRENT_DATE - b.since, 0) <= 30 THEN b.balance ELSE 0 END AS d0_30,
               CASE WHEN CURRENT_DATE - b.since BETWEEN 31 AND 60 THEN b.balance ELSE 0 END  AS d31_60,
               CASE WHEN CURRENT_DATE - b.since > 60 THEN b.balance ELSE 0 END               AS d60_plus
        FROM core.enquiries e
        CROSS JOIN LATERAL (
            SELECT e.registration_fee_amount
                     - core.fn_registration_fee_settled(p_tenant_id, p_school_id, e.enquiry_id) AS balance,
                   CASE WHEN e.registration_date ~ '^\d{4}-\d{2}-\d{2}'
                        THEN left(e.registration_date, 10)::date
                        ELSE e.created_at::date END AS since
        ) b
        WHERE e.tenant_id = p_tenant_id AND e.school_id = p_school_id
          AND COALESCE(e.is_active, TRUE)
          AND e.admission_id IS NULL
          AND COALESCE(e.registration_fee_amount, 0) > 0
          AND b.balance > 0.005
          AND v_section IS NULL
          AND (v_class IS NULL OR e.class_name = v_class)
          AND (v_year IS NULL
               OR lower(COALESCE(NULLIF(trim(e.session), ''), v_current)) = v_year)
    )
    SELECT * FROM students
    UNION ALL
    SELECT * FROM registrations
    ORDER BY total_outstanding DESC, student_name;
END;
$procedure$;

-- ============================================================================
-- Transport Module — routes (+ per-stop fares), vehicles, student assignment
--
-- A student's monthly bus fee is the fare of the STOP they board at. Assigning a
-- student to a route+stop snapshots that fare and generates monthly 'Transport
-- Fee' dues in core.student_ledger, so the Fee Collection counter bills bus fee
-- automatically alongside tuition (same Monthly mechanism as student_master_fields.sql).
--
-- Tables : core.transport_routes, core.transport_stops, core.transport_vehicles,
--          core.student_transport
-- Procs  : sp_transport_route_manage, sp_transport_vehicle_manage,
--          sp_transport_assign_manage, sp_transport_routes_dropdown
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── Tables ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS core.transport_routes
(
    route_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   integer NOT NULL,
    school_id   integer NOT NULL,
    route_name  varchar(80)  NOT NULL,
    description varchar(200),
    is_active   boolean NOT NULL DEFAULT TRUE,
    is_deleted  boolean NOT NULL DEFAULT FALSE,
    created_by  integer,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  integer,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT chk_transport_routes_scope CHECK ((tenant_id > 1) AND (school_id > 0))
);

CREATE TABLE IF NOT EXISTS core.transport_stops
(
    stop_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    route_id      integer NOT NULL REFERENCES core.transport_routes(route_id) ON DELETE CASCADE,
    tenant_id     integer NOT NULL,
    school_id     integer NOT NULL,
    stop_name     varchar(80) NOT NULL,
    monthly_fare  numeric(12,2) NOT NULL DEFAULT 0,
    display_order integer NOT NULL DEFAULT 0,
    is_active     boolean NOT NULL DEFAULT TRUE,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_transport_stops_route ON core.transport_stops(route_id);

CREATE TABLE IF NOT EXISTS core.transport_vehicles
(
    vehicle_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id    integer NOT NULL,
    school_id    integer NOT NULL,
    vehicle_no   varchar(40) NOT NULL,
    capacity     integer,
    driver_name  varchar(100),
    driver_phone varchar(20),
    route_id     integer REFERENCES core.transport_routes(route_id) ON DELETE SET NULL,
    is_active    boolean NOT NULL DEFAULT TRUE,
    is_deleted   boolean NOT NULL DEFAULT FALSE,
    created_by   integer,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   integer,
    updated_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT chk_transport_vehicles_scope CHECK ((tenant_id > 1) AND (school_id > 0))
);

-- Driver is an EMPLOYEE (core.staff, designation "Driver"), not free text. The
-- name/phone columns above are kept as a snapshot of the linked staff at save
-- time (like other snapshots in this schema); driver_staff_id is the real link.
ALTER TABLE core.transport_vehicles
    ADD COLUMN IF NOT EXISTS driver_staff_id integer REFERENCES core.staff(staff_id) ON DELETE SET NULL;

-- One active assignment per student. stop_id/route_id are stored by value (no hard
-- FK) and the fare is snapshotted, so editing/removing a stop never corrupts a
-- student's billed history.
CREATE TABLE IF NOT EXISTS core.student_transport
(
    assignment_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     integer NOT NULL,
    school_id     integer NOT NULL,
    student_id    integer NOT NULL,
    route_id      integer NOT NULL,
    stop_id       integer NOT NULL,
    monthly_fare  numeric(12,2) NOT NULL DEFAULT 0,
    academic_year varchar(12),
    start_date    date NOT NULL DEFAULT CURRENT_DATE,
    is_active     boolean NOT NULL DEFAULT TRUE,
    is_deleted    boolean NOT NULL DEFAULT FALSE,
    created_by    integer,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    integer,
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT chk_student_transport_scope CHECK ((tenant_id > 1) AND (school_id > 0))
);
CREATE INDEX IF NOT EXISTS idx_student_transport_student ON core.student_transport(student_id);

-- ── Riders and seats per route ──────────────────────────────────────────────
-- Riders = students on the roll with an active assignment on the route.
-- Seats  = total capacity of the route's active vehicles. NULL when no active
-- vehicle on the route has a capacity set: the route then has no known limit
-- and assignment is not capped (a school that never registers buses still works).
-- p_on: count only riders whose bus has started by that date (a child booked
-- from April does not take a seat in October). NULL = every booked rider, used
-- where a future rider matters too (removing a vehicle, deleting a route).
-- The old 2-argument version is dropped: next to this one every short call
-- would be ambiguous.
DROP FUNCTION IF EXISTS core.fn_transport_route_riders(integer, integer);
CREATE OR REPLACE FUNCTION core.fn_transport_route_riders(p_route_id integer, p_except_student integer DEFAULT NULL,
                                                         p_on date DEFAULT NULL)
RETURNS integer LANGUAGE sql STABLE AS $fn$
    SELECT COUNT(DISTINCT a.student_id)::integer
    FROM core.student_transport a
    JOIN core.students st ON st.student_id = a.student_id AND st.is_active
    WHERE a.route_id = p_route_id
      AND a.is_active AND NOT COALESCE(a.is_deleted, FALSE)
      AND a.student_id IS DISTINCT FROM p_except_student
      AND (p_on IS NULL OR NULLIF(a.start_date::text, '')::date <= p_on);
$fn$;

CREATE OR REPLACE FUNCTION core.fn_transport_route_seats(p_route_id integer, p_except_vehicle integer DEFAULT NULL)
RETURNS integer LANGUAGE sql STABLE AS $fn$
    SELECT NULLIF(SUM(COALESCE(v.capacity, 0)), 0)::integer
    FROM core.transport_vehicles v
    WHERE v.route_id = p_route_id
      AND v.is_active AND NOT COALESCE(v.is_deleted, FALSE)
      AND v.vehicle_id IS DISTINCT FROM p_except_vehicle;
$fn$;

-- ── Routes (+ stops) manage ─────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE core.sp_transport_route_manage(
    IN    p_operation      varchar,
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_route_id       integer  DEFAULT NULL,
    IN    p_route_name     varchar  DEFAULT NULL,
    IN    p_description    varchar  DEFAULT NULL,
    IN    p_stops          jsonb    DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_route_id integer;
    v_stop     jsonb;
    v_stop_id  integer;
    v_keep     integer[] := ARRAY[]::integer[];
    v_busy     text;
    v_riders   integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    IF p_operation = 'GetRoutes' THEN
        OPEN p_result FOR
        SELECT r.route_id, r.route_name, r.description, r.is_active,
               COUNT(s.stop_id) FILTER (WHERE s.is_active)            AS stop_count,
               MIN(s.monthly_fare) FILTER (WHERE s.is_active)         AS min_fare,
               MAX(s.monthly_fare) FILTER (WHERE s.is_active)         AS max_fare,
               core.fn_transport_route_riders(r.route_id, NULL, CURRENT_DATE) AS riders,   -- riding today
               core.fn_transport_route_seats(r.route_id)              AS seats
        FROM core.transport_routes r
        LEFT JOIN core.transport_stops s ON s.route_id = r.route_id
        WHERE r.tenant_id = p_tenant_id AND r.school_id = p_school_id
          AND COALESCE(r.is_deleted, FALSE) = FALSE
        GROUP BY r.route_id, r.route_name, r.description, r.is_active
        ORDER BY r.route_name;

    ELSIF p_operation = 'GetStops' THEN
        OPEN p_result FOR
        SELECT stop_id, route_id, stop_name, monthly_fare, display_order
        FROM core.transport_stops
        WHERE route_id = p_route_id AND tenant_id = p_tenant_id AND school_id = p_school_id
          AND is_active = TRUE
        ORDER BY display_order, stop_id;

    ELSIF p_operation = 'SaveRoute' THEN
        IF COALESCE(NULLIF(trim(p_route_name), ''), '') = '' THEN
            RAISE EXCEPTION 'Route name is required.';
        END IF;

        -- One route per name (case and spaces ignored), or the Assign dropdown
        -- offers two "North Zone"s and nobody knows which one a child is on.
        IF EXISTS (SELECT 1 FROM core.transport_routes
                    WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                      AND NOT COALESCE(is_deleted, FALSE)
                      AND lower(regexp_replace(trim(route_name), '\s+', ' ', 'g'))
                          = lower(regexp_replace(trim(p_route_name), '\s+', ' ', 'g'))
                      AND route_id IS DISTINCT FROM NULLIF(p_route_id, 0)) THEN
            RAISE EXCEPTION 'A route called "%" already exists.', trim(p_route_name);
        END IF;

        -- A fare is money the parent pays; it cannot be negative.
        IF p_stops IS NOT NULL AND jsonb_typeof(p_stops) = 'array' AND EXISTS (
               SELECT 1 FROM jsonb_array_elements(p_stops) e
                WHERE COALESCE(NULLIF(trim(e->>'stopName'), ''), '') <> ''
                  AND COALESCE((e->>'monthlyFare')::numeric, 0) < 0) THEN
            RAISE EXCEPTION 'A stop fare cannot be negative.';
        END IF;

        IF COALESCE(p_route_id, 0) > 0 THEN
            UPDATE core.transport_routes
            SET route_name = trim(p_route_name), description = NULLIF(trim(p_description), ''),
                updated_by = p_action_user_id, updated_at = NOW()
            WHERE route_id = p_route_id AND tenant_id = p_tenant_id AND school_id = p_school_id
              AND NOT COALESCE(is_deleted, FALSE)
            RETURNING route_id INTO v_route_id;
            -- Another school's id, or a deleted route: say so, do not pretend.
            IF v_route_id IS NULL THEN
                RAISE EXCEPTION 'Route not found.';
            END IF;
        ELSE
            INSERT INTO core.transport_routes (tenant_id, school_id, route_name, description, created_by)
            VALUES (p_tenant_id, p_school_id, trim(p_route_name), NULLIF(trim(p_description), ''), p_action_user_id)
            RETURNING route_id INTO v_route_id;
        END IF;

        -- Sync stops: upsert provided ones, switch off any existing not in the list.
        -- A fare change applies to NEW assignments only: a child already on the
        -- stop keeps the fare snapshotted when they were assigned.
        IF p_stops IS NOT NULL AND jsonb_typeof(p_stops) = 'array' THEN
            FOR v_stop IN SELECT * FROM jsonb_array_elements(p_stops)
            LOOP
                IF COALESCE(NULLIF(trim(v_stop->>'stopName'), ''), '') = '' THEN
                    CONTINUE;
                END IF;
                v_stop_id := NULLIF((v_stop->>'stopId'), '')::integer;
                IF COALESCE(v_stop_id, 0) > 0 THEN
                    UPDATE core.transport_stops
                    SET stop_name = trim(v_stop->>'stopName'),
                        monthly_fare = COALESCE((v_stop->>'monthlyFare')::numeric, 0),
                        display_order = COALESCE((v_stop->>'displayOrder')::integer, 0),
                        is_active = TRUE, updated_at = NOW()
                    WHERE stop_id = v_stop_id AND route_id = v_route_id;
                    IF NOT FOUND THEN
                        v_stop_id := NULL;   -- not a stop of this route: ignore it
                    END IF;
                ELSE
                    INSERT INTO core.transport_stops
                        (route_id, tenant_id, school_id, stop_name, monthly_fare, display_order)
                    VALUES
                        (v_route_id, p_tenant_id, p_school_id, trim(v_stop->>'stopName'),
                         COALESCE((v_stop->>'monthlyFare')::numeric, 0),
                         COALESCE((v_stop->>'displayOrder')::integer, 0))
                    RETURNING stop_id INTO v_stop_id;
                END IF;
                IF v_stop_id IS NOT NULL THEN
                    v_keep := array_append(v_keep, v_stop_id);
                END IF;
            END LOOP;
        END IF;

        -- A stop that children board at cannot be taken off the route: they
        -- would stay assigned (and billed) at a stop that no longer exists.
        SELECT string_agg(DISTINCT s.stop_name, ', ') INTO v_busy
        FROM core.transport_stops s
        JOIN core.student_transport a ON a.stop_id = s.stop_id
             AND a.is_active AND NOT COALESCE(a.is_deleted, FALSE)
        JOIN core.students st ON st.student_id = a.student_id AND st.is_active
        WHERE s.route_id = v_route_id AND s.is_active
          AND NOT (s.stop_id = ANY(v_keep));
        IF v_busy IS NOT NULL THEN
            RAISE EXCEPTION 'Stop(s) % still have students assigned. Move them to another stop first.', v_busy;
        END IF;

        -- Removed stops are switched off, never deleted: past assignments and
        -- their history still point at them.
        UPDATE core.transport_stops
        SET is_active = FALSE, updated_at = NOW()
        WHERE route_id = v_route_id AND is_active AND NOT (stop_id = ANY(v_keep));

        OPEN p_result FOR SELECT TRUE AS success, 'Route saved.' AS message, v_route_id AS route_id;

    ELSIF p_operation = 'DeleteRoute' THEN
        PERFORM 1 FROM core.transport_routes
         WHERE route_id = p_route_id AND tenant_id = p_tenant_id AND school_id = p_school_id
           AND NOT COALESCE(is_deleted, FALSE);
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Route not found.';
        END IF;

        -- Children still riding it: refuse. A deleted route would keep billing
        -- them on a route nobody can see.
        v_riders := core.fn_transport_route_riders(p_route_id);
        IF v_riders > 0 THEN
            RAISE EXCEPTION '% student(s) are still assigned to this route. Move or remove them first.', v_riders;
        END IF;

        -- Soft delete: the row stays so past assignments keep their route name.
        UPDATE core.transport_routes
        SET is_deleted = TRUE, is_active = FALSE, updated_by = p_action_user_id, updated_at = NOW()
        WHERE route_id = p_route_id AND tenant_id = p_tenant_id AND school_id = p_school_id;

        -- A bus left pointing at a deleted route would still show it on Vehicles.
        UPDATE core.transport_vehicles
        SET route_id = NULL, updated_by = p_action_user_id, updated_at = NOW()
        WHERE route_id = p_route_id AND tenant_id = p_tenant_id AND school_id = p_school_id;

        OPEN p_result FOR SELECT TRUE AS success, 'Route deleted.' AS message;

    ELSIF p_operation = 'ToggleRouteStatus' THEN
        -- Switching a route off only stops NEW assignments; children already on
        -- it stay until they are moved.
        UPDATE core.transport_routes
        SET is_active = NOT is_active, updated_by = p_action_user_id, updated_at = NOW()
        WHERE route_id = p_route_id AND tenant_id = p_tenant_id AND school_id = p_school_id
          AND NOT COALESCE(is_deleted, FALSE);
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Route not found.';
        END IF;
        OPEN p_result FOR SELECT TRUE AS success, 'Route status updated.' AS message;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;

-- ── Vehicles manage ─────────────────────────────────────────────────────────
-- Old signature (free-text driver only) is dropped so the driver_staff_id param
-- can be added without creating an ambiguous overload.
DROP PROCEDURE IF EXISTS core.sp_transport_vehicle_manage(
    varchar, integer, integer, integer, integer, varchar, integer,
    varchar, varchar, integer, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_transport_vehicle_manage(
    IN    p_operation       varchar,
    IN    p_tenant_id       integer,
    IN    p_school_id       integer,
    IN    p_action_user_id  integer,
    IN    p_vehicle_id      integer  DEFAULT NULL,
    IN    p_vehicle_no      varchar  DEFAULT NULL,
    IN    p_capacity        integer  DEFAULT NULL,
    IN    p_driver_name     varchar  DEFAULT NULL,
    IN    p_driver_phone    varchar  DEFAULT NULL,
    IN    p_route_id        integer  DEFAULT NULL,
    IN    p_driver_staff_id integer  DEFAULT NULL,
    INOUT p_result          refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_dname  varchar(100);
    v_dphone varchar(20);
    v_route  integer;
    v_active boolean;
    v_riders integer;
    v_old_route  integer;   -- route the vehicle was on before this save
    v_old_seats  integer;   -- seats of that route before the save
    v_new_seats  integer;   -- seats of the chosen route before the save
    v_seats      integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    IF p_operation = 'GetVehicles' THEN
        OPEN p_result FOR
        SELECT v.vehicle_id, v.vehicle_no, v.capacity, v.driver_name, v.driver_phone,
               v.route_id, r.route_name, v.is_active, v.driver_staff_id
        FROM core.transport_vehicles v
        -- Only this school's live routes: a route id from anywhere else must
        -- never surface another school's route name here.
        LEFT JOIN core.transport_routes r ON r.route_id = v.route_id
             AND r.tenant_id = v.tenant_id AND r.school_id = v.school_id
             AND NOT COALESCE(r.is_deleted, FALSE)
        WHERE v.tenant_id = p_tenant_id AND v.school_id = p_school_id
          AND COALESCE(v.is_deleted, FALSE) = FALSE
        ORDER BY v.vehicle_no;

    ELSIF p_operation = 'GetDrivers' THEN
        -- Transport-type staff (drivers/conductors) for the vehicle dropdown.
        OPEN p_result FOR
        SELECT staff_id, full_name, mobile, designation
        FROM   core.staff
        WHERE  tenant_id = p_tenant_id AND school_id = p_school_id
          AND  COALESCE(is_deleted, FALSE) = FALSE
          AND  COALESCE(status, 'Active') <> 'Inactive'
          AND  (staff_type = 'Transport' OR designation ILIKE '%driver%' OR designation ILIKE '%conductor%')
        ORDER BY full_name;

    ELSIF p_operation = 'SaveVehicle' THEN
        IF COALESCE(NULLIF(trim(p_vehicle_no), ''), '') = '' THEN
            RAISE EXCEPTION 'Vehicle number is required.';
        END IF;

        -- A registration number is one vehicle. Compared without case, spaces
        -- or dashes so "RJ14-AB-1234" and "rj14 ab 1234" are the same bus.
        IF EXISTS (SELECT 1 FROM core.transport_vehicles
                    WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                      AND NOT COALESCE(is_deleted, FALSE)
                      AND upper(regexp_replace(vehicle_no, '[\s-]', '', 'g'))
                          = upper(regexp_replace(p_vehicle_no, '[\s-]', '', 'g'))
                      AND vehicle_id IS DISTINCT FROM NULLIF(p_vehicle_id, 0)) THEN
            RAISE EXCEPTION 'Vehicle % is already registered.', trim(p_vehicle_no);
        END IF;

        IF p_capacity IS NOT NULL AND p_capacity < 1 THEN
            RAISE EXCEPTION 'Capacity must be at least 1 seat (or left blank).';
        END IF;

        -- The route must be one of this school's live routes.
        IF COALESCE(p_route_id, 0) > 0 AND NOT EXISTS (
               SELECT 1 FROM core.transport_routes
                WHERE route_id = p_route_id AND tenant_id = p_tenant_id AND school_id = p_school_id
                  AND NOT COALESCE(is_deleted, FALSE)) THEN
            RAISE EXCEPTION 'Route not found.';
        END IF;

        IF COALESCE(p_driver_staff_id, 0) > 0 AND NOT EXISTS (
               SELECT 1 FROM core.staff
                WHERE staff_id = p_driver_staff_id AND tenant_id = p_tenant_id AND school_id = p_school_id
                  AND COALESCE(is_deleted, FALSE) = FALSE) THEN
            RAISE EXCEPTION 'Driver not found.';
        END IF;
        -- A driver who has left cannot be put on a bus (sp_staff_release_duties
        -- takes them off their bus when they leave).
        IF COALESCE(p_driver_staff_id, 0) > 0 AND EXISTS (
               SELECT 1 FROM core.staff
                WHERE staff_id = p_driver_staff_id AND COALESCE(status, 'Active') = 'Inactive') THEN
            RAISE EXCEPTION 'This driver is marked as left. Pick an active driver.';
        END IF;

        -- Seats before the save, to check below that children are not left
        -- without a seat when capacity is lowered or the bus moves route.
        SELECT route_id INTO v_old_route FROM core.transport_vehicles
         WHERE vehicle_id = NULLIF(COALESCE(p_vehicle_id, 0), 0)
           AND tenant_id = p_tenant_id AND school_id = p_school_id;
        v_old_seats := core.fn_transport_route_seats(v_old_route);
        v_new_seats := core.fn_transport_route_seats(NULLIF(COALESCE(p_route_id, 0), 0));

        -- Snapshot driver name/phone from the linked staff row (single source);
        -- fall back to any free-text passed in when no staff is linked.
        IF COALESCE(p_driver_staff_id, 0) > 0 THEN
            SELECT full_name, mobile INTO v_dname, v_dphone
            FROM   core.staff
            WHERE  staff_id = p_driver_staff_id
              AND  tenant_id = p_tenant_id AND school_id = p_school_id
              AND  COALESCE(is_deleted, FALSE) = FALSE;
        END IF;
        v_dname  := COALESCE(v_dname,  p_driver_name);
        v_dphone := COALESCE(v_dphone, p_driver_phone);

        IF COALESCE(p_vehicle_id, 0) > 0 THEN
            UPDATE core.transport_vehicles
            SET vehicle_no = trim(p_vehicle_no), capacity = p_capacity,
                driver_name = v_dname, driver_phone = v_dphone,
                driver_staff_id = NULLIF(COALESCE(p_driver_staff_id, 0), 0),
                route_id = NULLIF(COALESCE(p_route_id, 0), 0),
                updated_by = p_action_user_id, updated_at = NOW()
            WHERE vehicle_id = p_vehicle_id AND tenant_id = p_tenant_id AND school_id = p_school_id
              AND NOT COALESCE(is_deleted, FALSE);
            IF NOT FOUND THEN
                RAISE EXCEPTION 'Vehicle not found.';
            END IF;
        ELSE
            INSERT INTO core.transport_vehicles
                (tenant_id, school_id, vehicle_no, capacity, driver_name, driver_phone,
                 driver_staff_id, route_id, created_by)
            VALUES
                (p_tenant_id, p_school_id, trim(p_vehicle_no), p_capacity, v_dname, v_dphone,
                 NULLIF(COALESCE(p_driver_staff_id, 0), 0), NULLIF(COALESCE(p_route_id, 0), 0), p_action_user_id);
        END IF;

        -- Fewer seats than children riding: refused (the save is rolled back).
        -- Only when this save took seats away, so an old full route can still be edited.
        IF v_old_route IS NOT NULL THEN
            v_seats  := core.fn_transport_route_seats(v_old_route);
            v_riders := core.fn_transport_route_riders(v_old_route);
            IF v_seats IS NOT NULL AND v_seats < COALESCE(v_old_seats, 2147483647) AND v_riders > v_seats THEN
                RAISE EXCEPTION 'The route would have % seat(s) for % student(s). Move some students or add a vehicle first.', v_seats, v_riders;
            END IF;
        END IF;
        IF COALESCE(p_route_id, 0) > 0 AND p_route_id IS DISTINCT FROM v_old_route THEN
            v_seats  := core.fn_transport_route_seats(p_route_id);
            v_riders := core.fn_transport_route_riders(p_route_id);
            IF v_seats IS NOT NULL AND v_seats < COALESCE(v_new_seats, 2147483647) AND v_riders > v_seats THEN
                RAISE EXCEPTION 'The route would have % seat(s) for % student(s). Move some students or add a vehicle first.', v_seats, v_riders;
            END IF;
        END IF;
        OPEN p_result FOR SELECT TRUE AS success, 'Vehicle saved.' AS message;

    ELSIF p_operation IN ('DeleteVehicle', 'ToggleVehicleStatus') THEN
        SELECT route_id, is_active INTO v_route, v_active
        FROM core.transport_vehicles
        WHERE vehicle_id = p_vehicle_id AND tenant_id = p_tenant_id AND school_id = p_school_id
          AND NOT COALESCE(is_deleted, FALSE);
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Vehicle not found.';
        END IF;

        -- Taking a bus off the road (switching it off, or deleting it) is
        -- refused when it is the last active bus of a route children ride:
        -- they would be assigned to a route with no bus. Switching ON is free.
        IF v_active AND v_route IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM core.transport_vehicles
                            WHERE route_id = v_route AND vehicle_id <> p_vehicle_id
                              AND is_active AND NOT COALESCE(is_deleted, FALSE)) THEN
            v_riders := core.fn_transport_route_riders(v_route);
            IF v_riders > 0 THEN
                RAISE EXCEPTION 'This is the only active vehicle on its route and % student(s) ride it. Add or move another vehicle to the route first.', v_riders;
            END IF;
        END IF;

        IF p_operation = 'DeleteVehicle' THEN
            UPDATE core.transport_vehicles
            SET is_deleted = TRUE, is_active = FALSE, updated_by = p_action_user_id, updated_at = NOW()
            WHERE vehicle_id = p_vehicle_id;
            OPEN p_result FOR SELECT TRUE AS success, 'Vehicle deleted.' AS message;
        ELSE
            UPDATE core.transport_vehicles
            SET is_active = NOT is_active, updated_by = p_action_user_id, updated_at = NOW()
            WHERE vehicle_id = p_vehicle_id;
            OPEN p_result FOR SELECT TRUE AS success, 'Vehicle status updated.' AS message;
        END IF;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;

-- ── Routes + stops for cascading dropdowns ──────────────────────────────────
CREATE OR REPLACE PROCEDURE core.sp_transport_routes_dropdown(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    INOUT p_result         refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    OPEN p_result FOR
    SELECT r.route_id, r.route_name, s.stop_id, s.stop_name, s.monthly_fare,
           core.fn_transport_route_riders(r.route_id, NULL, CURRENT_DATE) AS riders,
           core.fn_transport_route_seats(r.route_id)  AS seats
    FROM core.transport_routes r
    JOIN core.transport_stops s ON s.route_id = r.route_id AND s.is_active = TRUE
    WHERE r.tenant_id = p_tenant_id AND r.school_id = p_school_id
      AND r.is_active = TRUE AND COALESCE(r.is_deleted, FALSE) = FALSE
    ORDER BY r.route_name, s.display_order, s.stop_id;
END;
$procedure$;

-- ── Student assignment (snapshots fare + generates monthly transport dues) ──
-- Depends on student_money_lifecycle.sql (fn_ledger_close and the close columns).
CREATE OR REPLACE PROCEDURE core.sp_transport_assign_manage(
    IN    p_operation      varchar,
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_student_id     integer,
    IN    p_route_id       integer  DEFAULT NULL,
    IN    p_stop_id        integer  DEFAULT NULL,
    IN    p_academic_year  varchar  DEFAULT NULL,
    IN    p_start_date     date     DEFAULT NULL,
    IN    p_months         integer  DEFAULT 12,
    INOUT p_result         refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_fare        numeric(12,2);
    v_stop_name   varchar(80);
    v_route_name  varchar(80);
    v_start       date;
    v_month_start date;
    v_i           integer;
    v_made        integer := 0;
    v_student_year varchar;
    v_year        varchar;
    v_sess_end    date;
    v_months      integer;
    v_max         integer;
    v_due         date;
    v_already     numeric(12,2);
    v_closed      numeric(12,2);
    v_reason      varchar(200);
    v_open        boolean;
    v_same_route  boolean;
    v_same_stop   boolean;
    v_seats       integer;
    v_riders      integer;
    r             record;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR p_student_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;

    IF p_operation = 'GetForStudent' THEN
        OPEN p_result FOR
        SELECT a.assignment_id, a.route_id, a.stop_id, a.monthly_fare, a.start_date,
               rt.route_name, s.stop_name
        FROM core.student_transport a
        -- "rt", not "r": r is a record variable of this proc, and PL/pgSQL read
        -- r.route_name as that (unassigned) variable -- every call failed.
        LEFT JOIN core.transport_routes rt ON rt.route_id = a.route_id
        LEFT JOIN core.transport_stops  s ON s.stop_id  = a.stop_id
        WHERE a.student_id = p_student_id AND a.tenant_id = p_tenant_id AND a.school_id = p_school_id
          AND a.is_active = TRUE AND COALESCE(a.is_deleted, FALSE) = FALSE
        ORDER BY a.assignment_id DESC
        LIMIT 1;

    ELSIF p_operation = 'SaveAssignment' THEN
        -- The student must be ours and still on the roll. Without this a stop
        -- of this school could be billed to ANY student id, including another
        -- school's, with the ledger rows written under this school's tenant.
        SELECT academic_year INTO v_student_year
        FROM core.students
        WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
          AND is_active = TRUE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Student not found, or no longer on the roll.';
        END IF;

        SELECT s.monthly_fare, s.stop_name, rt.route_name,
               (s.is_active AND rt.is_active AND NOT COALESCE(rt.is_deleted, FALSE))
          INTO v_fare, v_stop_name, v_route_name, v_open
        FROM core.transport_stops s
        JOIN core.transport_routes rt ON rt.route_id = s.route_id
        WHERE s.stop_id = p_stop_id AND s.route_id = p_route_id
          AND s.tenant_id = p_tenant_id AND s.school_id = p_school_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Selected stop not found.';
        END IF;

        -- Is the child already on this route / stop? Promotion re-bills a kept
        -- route for the new session through this same call, and that must keep
        -- working even if the route has since been closed or filled up.
        v_same_route := EXISTS (SELECT 1 FROM core.student_transport
                                 WHERE student_id = p_student_id AND route_id = p_route_id
                                   AND is_active AND NOT COALESCE(is_deleted, FALSE));
        v_same_stop  := EXISTS (SELECT 1 FROM core.student_transport
                                 WHERE student_id = p_student_id AND stop_id = p_stop_id
                                   AND is_active AND NOT COALESCE(is_deleted, FALSE));

        -- A switched-off route, a deleted route or a removed stop takes no new
        -- riders.
        IF NOT v_open AND NOT v_same_stop THEN
            RAISE EXCEPTION 'Route % / stop % is not in service. Pick an active route and stop.',
                v_route_name, v_stop_name;
        END IF;

        -- Seats: the route's active buses decide how many children it takes.
        -- Unlimited when no active bus on the route has a capacity set.
        IF NOT v_same_route THEN
            v_seats  := core.fn_transport_route_seats(p_route_id);
            -- riders already on the bus by the day this one starts
            v_riders := core.fn_transport_route_riders(p_route_id, p_student_id, COALESCE(p_start_date, CURRENT_DATE));
            IF v_seats IS NOT NULL AND v_riders >= v_seats THEN
                RAISE EXCEPTION 'Route % is full: % of % seats taken. Add a vehicle or pick another route.',
                    v_route_name, v_riders, v_seats;
            END IF;
        END IF;

        v_start := COALESCE(p_start_date, CURRENT_DATE);
        v_year  := COALESCE(NULLIF(TRIM(p_academic_year), ''), v_student_year);

        -- A start before the child joined would bill months they were not here.
        IF v_start < (SELECT NULLIF(admission_date, '')::date FROM core.students WHERE student_id = p_student_id) THEN
            RAISE EXCEPTION 'The bus start date is before the student''s admission date.';
        END IF;

        -- Bill to the end of the SESSION the assignment is for, read from its
        -- real end date. The controllers used to send a month count worked out
        -- from the session NAME on an April-March assumption, and this proc
        -- trusted it, so a 12-month count from October ran into the next session.
        SELECT NULLIF(end_date, '')::date, GREATEST(v_start, NULLIF(start_date, '')::date)
          INTO v_sess_end, v_start
        FROM academic.academic_years
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND academic_year_name = v_year AND COALESCE(is_deleted, FALSE) = FALSE
        LIMIT 1;
        -- (a start before the session begins is moved to the session's first day:
        --  an advance admission in February does not bill March of the old session)
        v_start := COALESCE(v_start, COALESCE(p_start_date, CURRENT_DATE));

        v_months := GREATEST(COALESCE(NULLIF(p_months, 0), 12), 1);
        IF v_sess_end IS NOT NULL THEN
            v_max := ((EXTRACT(YEAR FROM v_sess_end) * 12 + EXTRACT(MONTH FROM v_sess_end))
                    - (EXTRACT(YEAR FROM v_start)    * 12 + EXTRACT(MONTH FROM v_start)))::integer + 1;
            IF v_max <= 0 THEN
                RAISE EXCEPTION 'The start date is after session % ends.', v_year;
            END IF;
            v_months := LEAST(v_months, v_max);
        END IF;

        -- Replace the current assignment. Its unpaid dues from the start month
        -- on are CLOSED, not deleted: the row stays (a cancelled receipt may
        -- still point at it) with the reason, who and when, and only the part
        -- nobody paid is taken off. See student_money_lifecycle.sql.
        v_reason := 'Route changed on ' || to_char(v_start, 'YYYY-MM-DD');
        FOR r IN
            SELECT ledger_id FROM core.student_ledger
            WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
              AND fee_head_name = 'Transport Fee'
              AND due_date::date >= DATE_TRUNC('month', v_start)::date
              AND amount_due - amount_paid - concession > 0
        LOOP
            PERFORM core.fn_ledger_close(r.ledger_id, v_reason, 'Transport', p_action_user_id);
        END LOOP;

        UPDATE core.student_transport
        SET is_active = FALSE, is_deleted = TRUE,
            end_reason = 'Replaced by ' || COALESCE(v_route_name, '') || ' / ' || COALESCE(v_stop_name, '') ||
                         ' on ' || to_char(v_start, 'YYYY-MM-DD'),
            ended_by = p_action_user_id, ended_at = NOW(),
            updated_by = p_action_user_id, updated_at = NOW()
        WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
          AND is_active = TRUE;

        INSERT INTO core.student_transport
            (tenant_id, school_id, student_id, route_id, stop_id, monthly_fare,
             academic_year, start_date, created_by)
        VALUES
            (p_tenant_id, p_school_id, p_student_id, p_route_id, p_stop_id, v_fare,
             v_year, v_start, p_action_user_id);

        -- One 'Transport Fee' due per month. A month that already holds settled
        -- money (paid, or paid then closed) is only topped up to the new fare,
        -- so a part-paid month is never charged twice.
        v_month_start := DATE_TRUNC('month', v_start)::date;
        FOR v_i IN 0 .. v_months - 1 LOOP
            v_due := (v_month_start + make_interval(months => v_i))::date;

            SELECT COALESCE(SUM(amount_due), 0) INTO v_already
            FROM core.student_ledger
            WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
              AND fee_head_name = 'Transport Fee'
              AND due_date::date = v_due;

            IF v_already < v_fare THEN
                INSERT INTO core.student_ledger
                    (tenant_id, school_id, student_id, fee_head_name, frequency,
                     installment_label, due_date, amount_due, status, academic_year)
                VALUES
                    (p_tenant_id, p_school_id, p_student_id, 'Transport Fee', 'Monthly',
                     TO_CHAR(v_due, 'Mon YYYY'), v_due, v_fare - v_already, 'Pending', v_year);
                v_made := v_made + 1;
            END IF;
        END LOOP;

        OPEN p_result FOR
        SELECT TRUE AS success,
               'Transport assigned. ' || v_made || ' monthly due(s) generated.' AS message,
               v_fare AS monthly_fare, v_made AS months_generated;

    ELSIF p_operation = 'RemoveAssignment' THEN
        -- Unpaid bus dues from this month on are CLOSED with a reason (never
        -- deleted), including the unpaid part of a month that was paid in
        -- part. Money already taken stays on the row and can be refunded.
        v_reason := 'Transport removed on ' || to_char(CURRENT_DATE, 'YYYY-MM-DD');
        v_closed := 0;
        FOR r IN
            SELECT ledger_id FROM core.student_ledger
            WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
              AND fee_head_name = 'Transport Fee'
              AND due_date::date >= DATE_TRUNC('month', CURRENT_DATE)::date
              AND amount_due - amount_paid - concession > 0
        LOOP
            v_closed := v_closed + core.fn_ledger_close(r.ledger_id, v_reason, 'Transport', p_action_user_id);
        END LOOP;

        UPDATE core.student_transport
        SET is_active = FALSE, is_deleted = TRUE,
            end_reason = v_reason, ended_by = p_action_user_id, ended_at = NOW(),
            updated_by = p_action_user_id, updated_at = NOW()
        WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
          AND is_active = TRUE;

        OPEN p_result FOR SELECT TRUE AS success,
               'Transport removed.' ||
               CASE WHEN v_closed > 0
                    THEN ' ' || to_char(v_closed, 'FM99999990.00') || ' of unpaid bus fees closed.'
                    ELSE '' END AS message;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;

-- ============================================================================
-- Dashboard: staff attendance today, and attendance defaulters (students + staff).
--
--   p_staff_today  : active staff, marked today, present (Present / Late),
--                    absent, half day, on leave (marked Leave or approved leave)
--   p_student_def  : students of the session in progress (core.student_enrolment)
--                    with at least 5 days marked and attendance below p_threshold %,
--                    lowest first, top 10 + how many in all
--   p_staff_def    : staff with absences this month (Absent = 1, HalfDay = 0.5),
--                    most first, top 10 + how many in all; late marks shown beside
--
-- Read-only. Re-runnable.
-- ============================================================================
CREATE OR REPLACE PROCEDURE core.sp_dashboard_attendance(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_threshold      numeric DEFAULT 75,
    INOUT p_staff_today    refcursor DEFAULT 'da_staff_today'::refcursor,
    INOUT p_student_def    refcursor DEFAULT 'da_student_def'::refcursor,
    INOUT p_staff_def      refcursor DEFAULT 'da_staff_def'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_session varchar;
    v_month   date := date_trunc('month', CURRENT_DATE)::date;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;
    v_session := core.fn_session_on(p_tenant_id, p_school_id, CURRENT_DATE);

    -- ── staff today ─────────────────────────────────────────────────────────
    OPEN p_staff_today FOR
    WITH st AS (
        SELECT s.staff_id,
               a.status,
               EXISTS (SELECT 1 FROM core.staff_leave l
                        WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
                          AND l.staff_id = s.staff_id AND l.status = 'Approved'
                          AND CURRENT_DATE BETWEEN l.from_date::date AND l.to_date::date) AS on_leave
          FROM core.staff s
          LEFT JOIN core.staff_attendance a
                 ON a.staff_id = s.staff_id AND a.tenant_id = p_tenant_id AND a.school_id = p_school_id
                AND a.att_date = CURRENT_DATE
         WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id
           AND NOT COALESCE(s.is_deleted, FALSE) AND COALESCE(s.status, 'Active') = 'Active'
           AND (NULLIF(s.joining_date, '') IS NULL OR s.joining_date::date <= CURRENT_DATE)
    )
    SELECT COUNT(*)::int                                                      AS total,
           COUNT(status)::int                                                 AS marked,
           COUNT(*) FILTER (WHERE status IN ('Present', 'Late'))::int         AS present,
           COUNT(*) FILTER (WHERE status = 'Absent')::int                     AS absent,
           COUNT(*) FILTER (WHERE status = 'HalfDay')::int                    AS half_day,
           COUNT(*) FILTER (WHERE status = 'Leave' OR (status IS NULL AND on_leave))::int AS on_leave
      FROM st;

    -- ── students below the line, this session ───────────────────────────────
    OPEN p_student_def FOR
    WITH roll AS (
        SELECT e.student_id, e.class_name, e.section
          FROM core.student_enrolment e
         WHERE e.tenant_id = p_tenant_id AND e.school_id = p_school_id
           AND e.academic_year = v_session AND COALESCE(e.status, '') NOT IN ('Left', 'PassedOut')
    ),
    marks AS (
        SELECT a.student_id,
               COUNT(*)                                                    AS marked,
               COUNT(*) FILTER (WHERE a.status IN ('Present', 'Late'))     AS present
          FROM core.student_attendance a
         WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id AND a.academic_year = v_session
         GROUP BY a.student_id
    ),
    low AS (
        SELECT r.student_id, r.class_name, r.section, m.marked::int AS marked, m.present::int AS present,
               ROUND(m.present * 100.0 / m.marked, 1) AS percent
          FROM roll r JOIN marks m ON m.student_id = r.student_id
         WHERE m.marked >= 5 AND m.present * 100.0 / m.marked < p_threshold
    )
    SELECT s.public_id, s.student_name, l.class_name, l.section, l.marked, l.present, l.percent,
           COUNT(*) OVER ()::int AS total_count
      FROM low l JOIN core.students s ON s.student_id = l.student_id
     ORDER BY l.percent, s.student_name
     LIMIT 10;

    -- ── staff absences, this month ──────────────────────────────────────────
    OPEN p_staff_def FOR
    WITH m AS (
        SELECT a.staff_id,
               SUM(CASE a.status WHEN 'Absent' THEN 1 WHEN 'HalfDay' THEN 0.5 ELSE 0 END) AS absent_days,
               COUNT(*) FILTER (WHERE a.status = 'Late')::int                            AS late_days,
               COUNT(*)::int                                                             AS marked
          FROM core.staff_attendance a
         WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
           AND a.att_date BETWEEN v_month AND CURRENT_DATE
         GROUP BY a.staff_id
    )
    SELECT s.public_id, s.full_name, s.designation, m.absent_days, m.late_days, m.marked,
           COUNT(*) OVER ()::int AS total_count
      FROM m JOIN core.staff s ON s.staff_id = m.staff_id
     WHERE NOT COALESCE(s.is_deleted, FALSE) AND COALESCE(s.status, 'Active') = 'Active'
       AND (m.absent_days > 0 OR m.late_days >= 3)
     ORDER BY m.absent_days DESC, m.late_days DESC, s.full_name
     LIMIT 10;
END;
$procedure$;

