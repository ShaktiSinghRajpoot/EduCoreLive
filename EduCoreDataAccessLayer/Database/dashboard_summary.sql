-- ============================================================================
-- The landing dashboard, from real data.
--
-- This is the first page every user sees after signing in, and every number on
-- it was hardcoded — the same ₹13,201 and ₹1,41,912 for every school.
--
-- WHAT IS NOT IN HERE, and why. Three cards on that page cannot be answered
-- from anything the app records, so they are not faked:
--
--   * "Income vs Expense" — there is no expense module at all. Income alone on a
--     chart labelled income-vs-expense is worse than no chart.
--   * "Collection Target" — no target is configured anywhere; a progress ring
--     against an invented target means nothing.
--   * "Notice Board" — there is no notices table.
--
--   The calling page hides those cards rather than drawing empty ones.
--
-- CONVENTIONS kept in step with the rest of the app:
--   * Collection is read through core.fn_fee_money_lines (fee_day_close.sql),
--     exactly as Day Close and the Collection Register read it: a receipt counts
--     on the day it was issued, a cancellation is a negative on the day it was
--     cancelled (so yesterday's figure never changes), and modes are the real
--     tenders, never "Mixed". Apply this file AFTER fee_day_close.sql.
--   * Outstanding is read from core.student_ledger, the single source of truth
--     for money — never recomputed from payments. It is what has FALLEN DUE
--     (due_date on or before today), the same rule as Defaulters and the Fee Due
--     list; next months' instalments are not a debt yet. Students who have left
--     still count while they owe.
--   * "Today's attendance" counts only classes that actually took a register;
--     a class nobody marked is not a class that was absent.
--
-- Nine cursors, one round trip. The page draws a dozen cards and would otherwise
-- make a dozen calls on every sign-in.
--
-- Target DB: PostgreSQL. Safe to re-run.
-- ============================================================================

CREATE OR REPLACE PROCEDURE core.sp_dashboard_summary(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    INOUT p_kpi            refcursor DEFAULT 'db_kpi'::refcursor,
    INOUT p_trend          refcursor DEFAULT 'db_trend'::refcursor,
    INOUT p_classes        refcursor DEFAULT 'db_classes'::refcursor,
    INOUT p_modes          refcursor DEFAULT 'db_modes'::refcursor,
    INOUT p_defaulters     refcursor DEFAULT 'db_defaulters'::refcursor,
    INOUT p_recent         refcursor DEFAULT 'db_recent'::refcursor,
    INOUT p_approvals      refcursor DEFAULT 'db_approvals'::refcursor,
    INOUT p_events         refcursor DEFAULT 'db_events'::refcursor,
    INOUT p_birthdays      refcursor DEFAULT 'db_birthdays'::refcursor)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        OPEN p_kpi FOR SELECT 0 AS students, 0 AS staff, 0::numeric AS today_collection,
                              0::numeric AS outstanding, 0 AS due_students, 0 AS on_leave_today,
                              0::numeric AS yesterday_collection, 0 AS present_today,
                              0 AS marked_today;
        OPEN p_trend      FOR SELECT NULL::date AS d, 0::numeric AS amount WHERE FALSE;
        OPEN p_classes    FOR SELECT NULL::text AS class_name, 0 AS students WHERE FALSE;
        OPEN p_modes      FOR SELECT NULL::text AS mode, 0::numeric AS amount WHERE FALSE;
        OPEN p_defaulters FOR SELECT NULL::int AS student_id, NULL::text AS student_name WHERE FALSE;
        OPEN p_recent     FOR SELECT NULL::text AS receipt_no WHERE FALSE;
        OPEN p_approvals  FOR SELECT NULL::int AS leave_id WHERE FALSE;
        OPEN p_events     FOR SELECT NULL::date AS calendar_date WHERE FALSE;
        OPEN p_birthdays  FOR SELECT NULL::text AS name WHERE FALSE;
        RETURN;
    END IF;

    -- ── 1. Headline numbers ─────────────────────────────────────────────────
    OPEN p_kpi FOR
    SELECT
        -- Students on the roll of the session in progress (core.student_enrolment):
        -- a child admitted for next session does not count yet, a child promoted
        -- early still counts here until this session ends.
        (SELECT COUNT(DISTINCT e.student_id) FROM core.student_enrolment e
          WHERE e.tenant_id = p_tenant_id AND e.school_id = p_school_id
            AND e.academic_year = core.fn_session_on(p_tenant_id, p_school_id, CURRENT_DATE)
            AND COALESCE(e.status, '') NOT IN ('Left', 'PassedOut'))::int
            AS students,

        (SELECT COUNT(*) FROM core.staff st
          WHERE st.tenant_id = p_tenant_id AND st.school_id = p_school_id
            AND st.is_deleted = FALSE AND COALESCE(st.status,'Active') = 'Active')::int
            AS staff,

        -- Receipts issued today minus cancellations made today.
        (SELECT COALESCE(SUM(ml.amount), 0)
           FROM core.fn_fee_money_lines(p_tenant_id, p_school_id, CURRENT_DATE, CURRENT_DATE) ml)
            AS today_collection,

        (SELECT COALESCE(SUM(ml.amount), 0)
           FROM core.fn_fee_money_lines(p_tenant_id, p_school_id, CURRENT_DATE - 1, CURRENT_DATE - 1) ml)
            AS yesterday_collection,

        -- The ledger is the single source of truth for what is owed: rows that
        -- have fallen due, for students of this school.
        (SELECT COALESCE(SUM(l.amount_due - l.amount_paid - COALESCE(l.concession,0)), 0)
           FROM core.student_ledger l
           JOIN core.students s ON s.student_id = l.student_id
                               AND s.tenant_id = p_tenant_id AND s.school_id = p_school_id
          WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
            AND l.amount_due > l.amount_paid + COALESCE(l.concession,0)
            AND (l.due_date IS NULL OR l.due_date::date <= CURRENT_DATE))
            AS outstanding,

        (SELECT COUNT(DISTINCT l.student_id) FROM core.student_ledger l
           JOIN core.students s ON s.student_id = l.student_id
                               AND s.tenant_id = p_tenant_id AND s.school_id = p_school_id
          WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
            AND l.amount_due > l.amount_paid + COALESCE(l.concession,0)
            AND (l.due_date IS NULL OR l.due_date::date <= CURRENT_DATE))::int
            AS due_students,

        (SELECT COUNT(*) FROM core.staff_leave sl
          WHERE sl.tenant_id = p_tenant_id AND sl.school_id = p_school_id
            AND sl.status = 'Approved'
            AND CURRENT_DATE BETWEEN sl.from_date::date AND sl.to_date::date)::int
            AS on_leave_today,

        -- Today's attendance, over students whose class actually took a register.
        (SELECT COUNT(*) FROM core.student_attendance a
          WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
            AND a.attendance_date::date = CURRENT_DATE
            AND a.status NOT IN ('Absent', 'Leave'))::int
            AS present_today,

        (SELECT COUNT(*) FROM core.student_attendance a
          WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
            AND a.attendance_date::date = CURRENT_DATE)::int
            AS marked_today;

    -- ── 2. Collection, last 7 days ──────────────────────────────────────────
    -- generate_series so a day with no receipts is a zero on the chart rather
    -- than a missing point the line would skip over.
    OPEN p_trend FOR
    SELECT g.d::date AS d,
           COALESCE((SELECT SUM(ml.amount)
                       FROM core.fn_fee_money_lines(p_tenant_id, p_school_id, g.d::date, g.d::date) ml), 0) AS amount
    FROM generate_series(CURRENT_DATE - 6, CURRENT_DATE, INTERVAL '1 day') AS g(d)
    ORDER BY d;

    -- ── 3. Class-wise strength ──────────────────────────────────────────────
    -- The same roll, per class. The class is joined by its id: matching the name
    -- found it once per session, so every count doubled once a second session existed.
    OPEN p_classes FOR
    SELECT e.class_name, COUNT(DISTINCT e.student_id)::int AS students
    FROM core.student_enrolment e
    LEFT JOIN academic.academic_classes ac ON ac.academic_class_id = e.academic_class_id
    WHERE e.tenant_id = p_tenant_id AND e.school_id = p_school_id
      AND e.academic_year = core.fn_session_on(p_tenant_id, p_school_id, CURRENT_DATE)
      AND COALESCE(e.status, '') NOT IN ('Left', 'PassedOut')
    GROUP BY e.class_name
    ORDER BY MIN(COALESCE(ac.display_order, 9999)), e.class_name;   -- teaching order

    -- ── 4. Collection by payment mode, this month ───────────────────────────
    OPEN p_modes FOR
    -- By real tender. 'Advance' (paid from the wallet) and 'To wallet' (surplus
    -- saved to it) are not new money in a mode, so the chart leaves them out.
    SELECT ml.mode, SUM(ml.amount) AS amount
    FROM core.fn_fee_money_lines(p_tenant_id, p_school_id,
                                 DATE_TRUNC('month', CURRENT_DATE)::date, CURRENT_DATE) ml
    WHERE ml.mode NOT IN ('Advance', 'To wallet')
    GROUP BY ml.mode
    HAVING SUM(ml.amount) <> 0
    ORDER BY amount DESC;

    -- ── 5. Highest outstanding ──────────────────────────────────────────────
    OPEN p_defaulters FOR
    -- The ledger is summed FIRST and the last payment looked up on its own:
    -- joining payments into the ledger GROUP BY multiplied every figure by the
    -- number of receipts the student had.
    SELECT s.student_id, s.public_id, s.student_name, s.class_name, s.section,
           l.total, l.paid, l.due,
           (SELECT MAX(fp.payment_date) FROM core.fee_payments fp
             WHERE fp.tenant_id = p_tenant_id AND fp.school_id = p_school_id
               AND fp.student_id = s.student_id
               AND COALESCE(fp.is_cancelled, FALSE) = FALSE) AS last_payment
    FROM (SELECT ll.student_id,
                 SUM(ll.amount_due)  AS total,
                 SUM(ll.amount_paid) AS paid,
                 COALESCE(SUM(ll.amount_due - ll.amount_paid - COALESCE(ll.concession,0))
                          FILTER (WHERE ll.amount_due > ll.amount_paid + COALESCE(ll.concession,0)
                                    AND (ll.due_date IS NULL OR ll.due_date::date <= CURRENT_DATE)), 0) AS due
          FROM core.student_ledger ll
          WHERE ll.tenant_id = p_tenant_id AND ll.school_id = p_school_id
          GROUP BY ll.student_id) l
    JOIN core.students s ON s.student_id = l.student_id
                        AND s.tenant_id = p_tenant_id AND s.school_id = p_school_id
    WHERE l.due > 0
    ORDER BY l.due DESC
    LIMIT 10;

    -- ── 6. Recent receipts ──────────────────────────────────────────────────
    OPEN p_recent FOR
    -- A registration receipt has no student yet: name it from the enquiry.
    SELECT fp.receipt_no, fp.amount, fp.payment_mode, fp.payment_date,
           COALESCE(s.student_name, e.student_name) AS student_name,
           COALESCE(s.class_name, e.class_name)     AS class_name
    FROM core.fee_payments fp
    LEFT JOIN core.students  s ON s.student_id = fp.student_id
    LEFT JOIN core.enquiries e ON e.enquiry_id = fp.enquiry_id
    WHERE fp.tenant_id = p_tenant_id AND fp.school_id = p_school_id
      AND COALESCE(fp.is_cancelled, FALSE) = FALSE
    ORDER BY fp.payment_date DESC, fp.payment_id DESC
    LIMIT 8;

    -- ── 7. Pending approvals (leave is the only approval queue that exists) ─
    OPEN p_approvals FOR
    SELECT sl.leave_id, st.full_name, sl.leave_type, sl.from_date, sl.to_date,
           sl.days, sl.applied_at
    FROM core.staff_leave sl
    JOIN core.staff st ON st.staff_id = sl.staff_id
    WHERE sl.tenant_id = p_tenant_id AND sl.school_id = p_school_id
      AND sl.status = 'Pending'
    ORDER BY sl.applied_at
    LIMIT 8;

    -- ── 8. Upcoming calendar entries ────────────────────────────────────────
    OPEN p_events FOR
    SELECT c.calendar_date, c.title, c.day_type
    FROM academic.school_calendar c
    WHERE c.tenant_id = p_tenant_id AND c.school_id = p_school_id
      AND c.calendar_date::date >= CURRENT_DATE
    ORDER BY c.calendar_date
    LIMIT 6;

    -- ── 9. Birthdays today, students and staff together ─────────────────────
    -- Matched on day+month so the year (and leap years) do not matter.
    OPEN p_birthdays FOR
    SELECT s.student_name AS name, 'Student' AS who,
           s.class_name AS detail
    FROM core.students s
    WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id AND s.is_active
      AND s.dob IS NOT NULL
      AND EXTRACT(MONTH FROM s.dob::date) = EXTRACT(MONTH FROM CURRENT_DATE)
      AND EXTRACT(DAY   FROM s.dob::date) = EXTRACT(DAY   FROM CURRENT_DATE)
    UNION ALL
    SELECT st.full_name, 'Staff', COALESCE(st.designation, '')
    FROM core.staff st
    WHERE st.tenant_id = p_tenant_id AND st.school_id = p_school_id
      AND st.is_deleted = FALSE AND COALESCE(st.status,'Active') = 'Active'
      AND st.dob IS NOT NULL
      AND EXTRACT(MONTH FROM st.dob::date) = EXTRACT(MONTH FROM CURRENT_DATE)
      AND EXTRACT(DAY   FROM st.dob::date) = EXTRACT(DAY   FROM CURRENT_DATE);
END;
$procedure$;
