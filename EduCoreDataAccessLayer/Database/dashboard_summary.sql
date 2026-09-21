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
--   * A cancelled receipt (is_cancelled) is never counted as collection.
--   * Outstanding is read from core.student_ledger, the single source of truth
--     for money — never recomputed from payments.
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
        (SELECT COUNT(*) FROM core.students s
          WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id AND s.is_active)::int
            AS students,

        (SELECT COUNT(*) FROM core.staff st
          WHERE st.tenant_id = p_tenant_id AND st.school_id = p_school_id
            AND st.is_deleted = FALSE AND COALESCE(st.status,'Active') = 'Active')::int
            AS staff,

        -- Cancelled receipts are not collection.
        (SELECT COALESCE(SUM(fp.amount), 0) FROM core.fee_payments fp
          WHERE fp.tenant_id = p_tenant_id AND fp.school_id = p_school_id
            AND fp.payment_date::date = CURRENT_DATE
            AND COALESCE(fp.is_cancelled, FALSE) = FALSE)
            AS today_collection,

        (SELECT COALESCE(SUM(fp.amount), 0) FROM core.fee_payments fp
          WHERE fp.tenant_id = p_tenant_id AND fp.school_id = p_school_id
            AND fp.payment_date::date = CURRENT_DATE - 1
            AND COALESCE(fp.is_cancelled, FALSE) = FALSE)
            AS yesterday_collection,

        -- The ledger is the single source of truth for what is owed.
        (SELECT COALESCE(SUM(GREATEST(l.amount_due - l.amount_paid - COALESCE(l.concession,0), 0)), 0)
           FROM core.student_ledger l
          WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id)
            AS outstanding,

        (SELECT COUNT(DISTINCT l.student_id) FROM core.student_ledger l
          WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
            AND (l.amount_due - l.amount_paid - COALESCE(l.concession,0)) > 0)::int
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
           COALESCE((SELECT SUM(fp.amount) FROM core.fee_payments fp
                      WHERE fp.tenant_id = p_tenant_id AND fp.school_id = p_school_id
                        AND fp.payment_date::date = g.d::date
                        AND COALESCE(fp.is_cancelled, FALSE) = FALSE), 0) AS amount
    FROM generate_series(CURRENT_DATE - 6, CURRENT_DATE, INTERVAL '1 day') AS g(d)
    ORDER BY d;

    -- ── 3. Class-wise strength ──────────────────────────────────────────────
    OPEN p_classes FOR
    SELECT s.class_name, COUNT(*)::int AS students
    FROM core.students s
    LEFT JOIN academic.academic_classes ac
           ON ac.tenant_id = s.tenant_id AND ac.school_id = s.school_id
          AND ac.class_name = s.class_name AND COALESCE(ac.is_deleted, FALSE) = FALSE
    WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id AND s.is_active
    GROUP BY s.class_name, ac.display_order
    ORDER BY MIN(COALESCE(ac.display_order, 9999)), s.class_name;   -- teaching order

    -- ── 4. Collection by payment mode, this month ───────────────────────────
    OPEN p_modes FOR
    SELECT COALESCE(NULLIF(TRIM(fp.payment_mode), ''), 'Other') AS mode,
           SUM(fp.amount) AS amount
    FROM core.fee_payments fp
    WHERE fp.tenant_id = p_tenant_id AND fp.school_id = p_school_id
      AND COALESCE(fp.is_cancelled, FALSE) = FALSE
      AND fp.payment_date::date >= DATE_TRUNC('month', CURRENT_DATE)::date
    GROUP BY 1
    ORDER BY amount DESC;

    -- ── 5. Highest outstanding ──────────────────────────────────────────────
    OPEN p_defaulters FOR
    SELECT s.student_id, s.public_id, s.student_name, s.class_name, s.section,
           SUM(l.amount_due)                                  AS total,
           SUM(l.amount_paid)                                 AS paid,
           SUM(GREATEST(l.amount_due - l.amount_paid - COALESCE(l.concession,0), 0)) AS due,
           MAX(fp.payment_date)                               AS last_payment
    FROM core.student_ledger l
    JOIN core.students s ON s.student_id = l.student_id AND s.is_active
    LEFT JOIN core.fee_payments fp
           ON fp.student_id = s.student_id AND COALESCE(fp.is_cancelled, FALSE) = FALSE
    WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
    GROUP BY s.student_id, s.public_id, s.student_name, s.class_name, s.section
    HAVING SUM(GREATEST(l.amount_due - l.amount_paid - COALESCE(l.concession,0), 0)) > 0
    ORDER BY due DESC
    LIMIT 10;

    -- ── 6. Recent receipts ──────────────────────────────────────────────────
    OPEN p_recent FOR
    SELECT fp.receipt_no, fp.amount, fp.payment_mode, fp.payment_date,
           s.student_name, s.class_name
    FROM core.fee_payments fp
    JOIN core.students s ON s.student_id = fp.student_id
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
