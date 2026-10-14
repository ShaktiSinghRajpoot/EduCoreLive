-- ============================================================================
-- Staff leave: apply, approve, reject, cancel; balance and day-count previews.
--
-- The page existed with no backend at all — Apply/Approve/Reject just set a
-- TempData message and changed nothing. This is the real thing.
--
-- DESIGN NOTES
--
--   * Days are counted on the SCHOOL CALENDAR (core.fn_school_working_days):
--     the school's weekly off days and declared holidays are not leave days, a
--     Sunday declared a working day is, and a half school day counts 0.5. Payroll
--     uses the same function for the month's working days and for Loss of Pay,
--     so the leave screen and the payslip can never disagree. (Until Oct 2026
--     this counted "every day except Sunday", ignoring the School Calendar.)
--
--   * Leave types are a fixed list: Casual, Sick, Earned, Maternity, Comp-off,
--     Unpaid. 'Unpaid' is what payroll charges as Loss of Pay; every other type
--     is paid leave. An unknown word used to be accepted and silently paid.
--
--   * Paid types have a yearly entitlement (core.fn_leave_entitlement — the same
--     figures the Leave page shows): Casual 12, Sick 10, Earned 15, Maternity 90
--     days per calendar year. Pending + approved days count against it, so two
--     pending requests cannot together exceed it. Anything beyond is applied as
--     Unpaid (LOP). Comp-off and Unpaid are not capped (there is no comp-off
--     ledger to cap against).
--
--   * Overlap is refused. Two live requests covering the same day would be
--     counted twice by payroll, and it almost always means a duplicate entry.
--
--   * Refused as well: leave for an inactive staff member, leave before the
--     joining date or after the last working day.
--
--   * A half day (p_half_day) is one full working day counted as 0.5.
--
--   * A decided request cannot be decided again — approve/reject record who and
--     when, and overwriting that would lose the history.
--
--   * CANCEL withdraws a request without pretending it was refused: a pending
--     request always; an approved one only before it starts and only if no
--     salary covering those dates has been paid. Who, when and why are kept in
--     cancelled_by / cancelled_at / cancel_reason; the original decision stays.
--
-- p_half_day is the LAST parameter (after p_result) so existing positional
-- callers keep working.
--
-- Target DB: PostgreSQL. Safe to re-run.
-- ============================================================================

CREATE TABLE IF NOT EXISTS core.staff_leave (
    leave_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       integer NOT NULL,
    school_id       integer NOT NULL,
    staff_id        integer NOT NULL,

    leave_type      varchar(30) NOT NULL,
    from_date       date NOT NULL,
    to_date         date NOT NULL,
    days            numeric(5,1) NOT NULL,       -- school working days (0.5 = half day)
    reason          text,

    status          varchar(20) NOT NULL DEFAULT 'Pending',
    decision_remark text,

    applied_by      integer NOT NULL DEFAULT 0,
    applied_at      timestamptz NOT NULL DEFAULT now(),
    decided_by      integer,
    decided_at      timestamptz,

    CONSTRAINT chk_staff_leave_status CHECK (status IN ('Pending', 'Approved', 'Rejected', 'Cancelled')),
    CONSTRAINT chk_staff_leave_dates  CHECK (to_date >= from_date)
);

CREATE INDEX IF NOT EXISTS ix_staff_leave_staff
    ON core.staff_leave (tenant_id, school_id, staff_id, from_date);
CREATE INDEX IF NOT EXISTS ix_staff_leave_status
    ON core.staff_leave (tenant_id, school_id, status);

-- Oct 2026: half days, cancellation trail.
DO $mig$
BEGIN
    IF (SELECT data_type FROM information_schema.columns
        WHERE table_schema = 'core' AND table_name = 'staff_leave' AND column_name = 'days') = 'integer' THEN
        ALTER TABLE core.staff_leave ALTER COLUMN days TYPE numeric(5,1);
    END IF;
END $mig$;

ALTER TABLE core.staff_leave ADD COLUMN IF NOT EXISTS half_day      boolean NOT NULL DEFAULT FALSE;
ALTER TABLE core.staff_leave ADD COLUMN IF NOT EXISTS cancelled_by  integer;
ALTER TABLE core.staff_leave ADD COLUMN IF NOT EXISTS cancelled_at  timestamptz;
ALTER TABLE core.staff_leave ADD COLUMN IF NOT EXISTS cancel_reason text;

ALTER TABLE core.staff_leave DROP CONSTRAINT IF EXISTS chk_staff_leave_status;
ALTER TABLE core.staff_leave ADD CONSTRAINT chk_staff_leave_status
    CHECK (status IN ('Pending', 'Approved', 'Rejected', 'Cancelled'));


-- Every day except Sunday. Kept for older callers; leave and payroll now use
-- core.fn_school_working_days below.
CREATE OR REPLACE FUNCTION core.fn_working_days(p_from date, p_to date)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT COUNT(*)::int
    FROM generate_series(p_from, p_to, INTERVAL '1 day') AS g(d)
    WHERE EXTRACT(DOW FROM g.d) <> 0;
$fn$;


-- School working days between two dates, on THIS school's calendar
-- (academic.fn_school_day_type: declared day first, then the weekly off days).
-- working = 1, half_day = 0.5, weekly_off / holiday = 0. ONE definition, used by
-- leave apply, the leave preview, and payroll (month days, pro-rata, LOP).
CREATE OR REPLACE FUNCTION core.fn_school_working_days(
    p_tenant_id integer, p_school_id integer, p_from date, p_to date)
RETURNS numeric
LANGUAGE sql
STABLE
AS $fn$
    SELECT COALESCE(SUM(CASE academic.fn_school_day_type(p_tenant_id, p_school_id, g.d::date)
                            WHEN 'working'  THEN 1
                            WHEN 'half_day' THEN 0.5
                            ELSE 0 END), 0)::numeric
    FROM generate_series(p_from, p_to, INTERVAL '1 day') AS g(d);
$fn$;


-- Yearly entitlement of a paid leave type, in days. NULL = not capped.
-- The Leave page shows the same figures.
CREATE OR REPLACE FUNCTION core.fn_leave_entitlement(p_leave_type text)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT CASE p_leave_type
               WHEN 'Casual'    THEN 12
               WHEN 'Sick'      THEN 10
               WHEN 'Earned'    THEN 15
               WHEN 'Maternity' THEN 90
               ELSE NULL END::numeric;
$fn$;


-- The signature grew a trailing p_half_day; drop the old one so a 13-argument
-- call is not ambiguous between two overloads.
DROP PROCEDURE IF EXISTS core.sp_staff_leave_manage(
    text, integer, integer, integer, integer, integer, text, date, date, text, text, text, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_staff_leave_manage(
    IN    p_operation      text,          -- LIST | APPLY | DECIDE | CANCEL | BALANCE | DAYS
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_leave_id       integer DEFAULT NULL,
    IN    p_staff_id       integer DEFAULT NULL,
    IN    p_leave_type     text    DEFAULT NULL,
    IN    p_from_date      date    DEFAULT NULL,   -- BALANCE: any date in the year wanted
    IN    p_to_date        date    DEFAULT NULL,
    IN    p_reason         text    DEFAULT NULL,
    IN    p_status         text    DEFAULT NULL,   -- DECIDE: Approved | Rejected
    IN    p_remark         text    DEFAULT NULL,   -- DECIDE remark / CANCEL reason
    INOUT p_result         refcursor DEFAULT 'leave_cursor'::refcursor,
    IN    p_half_day       boolean DEFAULT FALSE)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    c_types  CONSTANT text[] := ARRAY['Casual', 'Sick', 'Earned', 'Maternity', 'Comp-off', 'Unpaid'];
    v_days   numeric;
    v_id     integer;
    v_status text;
    v_type   text;
    v_cap    numeric;
    v_used   numeric;
    v_year   integer;
    v_join   date;
    v_lwd    date;
    v_from   date;
    v_to     date;
    v_staff  integer;
    v_note   text := '';
    v_list   text;
    v_n      integer;
    v_name   text;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    -- ── LIST ────────────────────────────────────────────────────────────────
    IF p_operation = 'LIST' THEN
        OPEN p_result FOR
        SELECT l.leave_id, l.staff_id, s.full_name, s.employee_code, s.designation,
               l.leave_type, l.from_date, l.to_date, l.days, l.half_day, l.reason,
               l.status, l.decision_remark, l.applied_at, l.decided_at,
               l.cancel_reason, l.cancelled_at,
               -- "on leave today" for the page KPI, decided here so every caller
               -- agrees on what today means.
               (l.status = 'Approved'
                AND CURRENT_DATE BETWEEN l.from_date::date AND l.to_date::date) AS on_leave_today
        FROM core.staff_leave l
        JOIN core.staff s ON s.staff_id = l.staff_id
        WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
          AND (p_staff_id IS NULL OR l.staff_id = p_staff_id)
          AND (p_status IS NULL OR TRIM(p_status) = '' OR l.status = p_status)
        ORDER BY l.applied_at DESC, l.leave_id DESC;
        RETURN;
    END IF;

    -- ── DAYS: what APPLY would count, for the form's preview ────────────────
    IF p_operation = 'DAYS' THEN
        v_days := 0;
        IF p_from_date IS NOT NULL AND p_to_date IS NOT NULL AND p_to_date >= p_from_date THEN
            v_days := core.fn_school_working_days(p_tenant_id, p_school_id, p_from_date, p_to_date);
            IF COALESCE(p_half_day, FALSE) THEN
                v_days := CASE WHEN p_from_date = p_to_date AND v_days = 1 THEN 0.5 ELSE 0 END;
            END IF;
        END IF;
        OPEN p_result FOR
        SELECT TRUE AS success, NULL::integer AS leave_id, v_days AS days,
               trim_scale(v_days) || ' working day(s)' AS message;
        RETURN;
    END IF;

    -- ── BALANCE: entitlement, taken, pending, left — per type, for one year ─
    IF p_operation = 'BALANCE' THEN
        IF NOT EXISTS (SELECT 1 FROM core.staff
                       WHERE staff_id = p_staff_id AND tenant_id = p_tenant_id
                         AND school_id = p_school_id AND is_deleted = FALSE) THEN
            RAISE EXCEPTION 'Staff member not found.';
        END IF;
        v_year := EXTRACT(YEAR FROM COALESCE(p_from_date, CURRENT_DATE))::int;

        OPEN p_result FOR
        SELECT t.leave_type,
               core.fn_leave_entitlement(t.leave_type) AS entitled,
               COALESCE(SUM(l.days) FILTER (WHERE l.status = 'Approved'), 0) AS taken,
               COALESCE(SUM(l.days) FILTER (WHERE l.status = 'Pending'), 0)  AS pending,
               core.fn_leave_entitlement(t.leave_type)
                 - COALESCE(SUM(l.days) FILTER (WHERE l.status IN ('Approved', 'Pending')), 0) AS remaining,
               v_year AS year
        FROM unnest(c_types) WITH ORDINALITY AS t(leave_type, ord)
        LEFT JOIN core.staff_leave l
               ON l.tenant_id = p_tenant_id AND l.school_id = p_school_id
              AND l.staff_id = p_staff_id AND l.leave_type = t.leave_type
              AND l.status IN ('Approved', 'Pending')
              AND EXTRACT(YEAR FROM l.from_date::date) = v_year
        GROUP BY t.leave_type, t.ord
        ORDER BY t.ord;
        RETURN;
    END IF;

    -- ── APPLY ───────────────────────────────────────────────────────────────
    IF p_operation = 'APPLY' THEN
        IF COALESCE(p_staff_id, 0) <= 0 THEN
            RAISE EXCEPTION 'Choose the staff member.';
        END IF;
        IF p_leave_type IS NULL OR TRIM(p_leave_type) = '' THEN
            RAISE EXCEPTION 'Choose the leave type.';
        END IF;
        -- Stored in its canonical spelling, so payroll's 'Unpaid' check and the
        -- balance totals always match.
        SELECT t INTO v_type FROM unnest(c_types) AS t WHERE LOWER(t) = LOWER(TRIM(p_leave_type));
        IF v_type IS NULL THEN
            RAISE EXCEPTION 'Unknown leave type "%". Choose Casual, Sick, Earned, Maternity, Comp-off or Unpaid.', TRIM(p_leave_type);
        END IF;
        IF p_from_date IS NULL OR p_to_date IS NULL THEN
            RAISE EXCEPTION 'Choose both the from and to dates.';
        END IF;
        IF p_to_date < p_from_date THEN
            RAISE EXCEPTION 'The to date cannot be before the from date.';
        END IF;

        SELECT status, NULLIF(joining_date, '')::date, NULLIF(last_working_date, '')::date
          INTO v_status, v_join, v_lwd
        FROM core.staff
        WHERE staff_id = p_staff_id AND tenant_id = p_tenant_id
          AND school_id = p_school_id AND is_deleted = FALSE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Staff member not found.';
        END IF;
        IF v_status = 'Inactive' THEN
            RAISE EXCEPTION 'This staff member is inactive. Leave can only be recorded for current staff.';
        END IF;
        IF v_join IS NOT NULL AND p_from_date < v_join THEN
            RAISE EXCEPTION 'Leave cannot start before the joining date (%).', to_char(v_join, 'DD Mon YYYY');
        END IF;
        IF v_lwd IS NOT NULL AND p_to_date > v_lwd THEN
            RAISE EXCEPTION 'Leave cannot run past the last working day (%).', to_char(v_lwd, 'DD Mon YYYY');
        END IF;

        v_days := core.fn_school_working_days(p_tenant_id, p_school_id, p_from_date, p_to_date);

        IF COALESCE(p_half_day, FALSE) THEN
            IF p_from_date <> p_to_date THEN
                RAISE EXCEPTION 'A half-day leave is for a single date.';
            END IF;
            IF v_days <> 1 THEN
                RAISE EXCEPTION 'A half-day leave must be on a full working day.';
            END IF;
            v_days := 0.5;
        END IF;

        -- A range of only holidays / weekly offs is nothing to approve.
        IF v_days = 0 THEN
            RAISE EXCEPTION 'That range has no working days in it (weekly offs and school holidays are not counted).';
        END IF;

        -- Overlapping a live request is almost always a duplicate, and payroll
        -- would charge the days twice.
        IF EXISTS (
            SELECT 1 FROM core.staff_leave
            WHERE tenant_id = p_tenant_id AND school_id = p_school_id
              AND staff_id  = p_staff_id
              AND status IN ('Pending', 'Approved')
              AND from_date::date <= p_to_date AND to_date::date >= p_from_date
        ) THEN
            RAISE EXCEPTION 'This staff member already has a pending or approved leave overlapping those dates.';
        END IF;

        -- Yearly entitlement of a paid type: pending + approved count against it.
        v_cap := core.fn_leave_entitlement(v_type);
        IF v_cap IS NOT NULL THEN
            v_year := EXTRACT(YEAR FROM p_from_date)::int;
            SELECT COALESCE(SUM(days), 0) INTO v_used
            FROM core.staff_leave
            WHERE tenant_id = p_tenant_id AND school_id = p_school_id
              AND staff_id = p_staff_id AND leave_type = v_type
              AND status IN ('Pending', 'Approved')
              AND EXTRACT(YEAR FROM from_date::date) = v_year;

            IF v_used + v_days > v_cap THEN
                RAISE EXCEPTION 'Only % day(s) of % leave left for % (% asked for). Apply the rest as Unpaid leave.',
                    trim_scale(GREATEST(v_cap - v_used, 0)), v_type, v_year, trim_scale(v_days);
            END IF;
        END IF;

        INSERT INTO core.staff_leave (
            tenant_id, school_id, staff_id, leave_type, from_date, to_date,
            days, half_day, reason, status, applied_by)
        VALUES (
            p_tenant_id, p_school_id, p_staff_id, v_type, p_from_date, p_to_date,
            v_days, COALESCE(p_half_day, FALSE), NULLIF(TRIM(COALESCE(p_reason, '')), ''), 'Pending', p_action_user_id)
        RETURNING leave_id INTO v_id;

        OPEN p_result FOR
        SELECT TRUE AS success, v_id AS leave_id, v_days AS days,
               'Leave applied for ' || trim_scale(v_days) || ' working day(s).' AS message;
        RETURN;
    END IF;

    -- ── DECIDE ──────────────────────────────────────────────────────────────
    IF p_operation = 'DECIDE' THEN
        IF p_status IS NULL OR p_status NOT IN ('Approved', 'Rejected') THEN
            RAISE EXCEPTION 'A leave request can only be approved or rejected.';
        END IF;

        SELECT status INTO v_status
        FROM core.staff_leave
        WHERE leave_id = p_leave_id AND tenant_id = p_tenant_id AND school_id = p_school_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Leave request not found.';
        END IF;

        -- Deciding twice would overwrite who decided it and when.
        IF v_status <> 'Pending' THEN
            RAISE EXCEPTION 'This request was already %.', LOWER(v_status);
        END IF;

        UPDATE core.staff_leave
        SET status          = p_status,
            decision_remark = NULLIF(TRIM(COALESCE(p_remark, '')), ''),
            decided_by      = p_action_user_id,
            decided_at      = now()
        WHERE leave_id = p_leave_id AND tenant_id = p_tenant_id AND school_id = p_school_id;

        -- What the approval leaves to arrange, said in the same message (QA BUG-115,
        -- BUG-090): the class charge, the periods to cover, and salary already paid.
        IF p_status = 'Approved' THEN
            SELECT l.from_date::date, l.to_date::date, l.staff_id, l.leave_type, s.full_name
              INTO v_from, v_to, v_staff, v_type, v_name
              FROM core.staff_leave l JOIN core.staff s ON s.staff_id = l.staff_id
             WHERE l.leave_id = p_leave_id;

            SELECT string_agg(DISTINCT c.class_name || '-' || sec.section_name, ', ') INTO v_list
              FROM academic.academic_class_sections sec
              JOIN academic.academic_classes c ON c.academic_class_id = sec.academic_class_id
              JOIN academic.academic_years y   ON y.academic_year_id  = sec.academic_year_id
             WHERE sec.tenant_id = p_tenant_id AND sec.school_id = p_school_id
               AND sec.class_teacher_staff_id = v_staff AND NOT COALESCE(sec.is_deleted, FALSE)
               AND v_from <= y.end_date::date AND v_to >= y.start_date::date;
            IF v_list IS NOT NULL THEN
                v_note := v_note || ' ' || v_name || ' is class teacher of ' || v_list
                       || ': a teacher with a period there that day can take the register.';
            END IF;

            SELECT COUNT(*) INTO v_n
              FROM generate_series(v_from, v_to, interval '1 day') d(day)
              JOIN academic.timetable t
                ON t.tenant_id = p_tenant_id AND t.school_id = p_school_id AND t.staff_id = v_staff
               AND t.day_of_week = EXTRACT(ISODOW FROM d.day)::int
              JOIN academic.academic_years y ON y.academic_year_id = t.academic_year_id
                                            AND d.day::date BETWEEN y.start_date::date AND y.end_date::date;
            IF v_n > 0 THEN
                v_note := v_note || ' ' || v_n || ' timetable period(s) need a substitute -- Staff Attendance > Substitutes.';
            END IF;

            IF LOWER(v_type) = 'unpaid' AND EXISTS (
                   SELECT 1 FROM core.staff_payroll p
                    WHERE p.tenant_id = p_tenant_id AND p.school_id = p_school_id
                      AND p.staff_id = v_staff AND p.status = 'Paid'
                      AND make_date(p.pay_year, p.pay_month, 1)
                          BETWEEN DATE_TRUNC('month', v_from)::date AND v_to) THEN
                v_note := v_note || ' Salary for that month is already paid, so this unpaid leave is not deducted:'
                       || ' add a deduction in Payroll > Adjustments of the next unpaid month.';
            END IF;
        END IF;

        OPEN p_result FOR
        SELECT TRUE AS success, p_leave_id AS leave_id, 0::numeric AS days,
               'Leave ' || LOWER(p_status) || '.' || v_note AS message;
        RETURN;
    END IF;

    -- ── CANCEL ──────────────────────────────────────────────────────────────
    IF p_operation = 'CANCEL' THEN
        SELECT status, from_date::date, to_date::date, staff_id
          INTO v_status, v_from, v_to, v_staff
        FROM core.staff_leave
        WHERE leave_id = p_leave_id AND tenant_id = p_tenant_id AND school_id = p_school_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Leave request not found.';
        END IF;
        IF NULLIF(TRIM(COALESCE(p_remark, '')), '') IS NULL THEN
            RAISE EXCEPTION 'Give a reason for cancelling.';
        END IF;

        IF v_status = 'Approved' THEN
            IF v_from <= CURRENT_DATE THEN
                RAISE EXCEPTION 'This leave has already started, so it cannot be cancelled.';
            END IF;
            IF EXISTS (SELECT 1 FROM core.staff_payroll p
                       WHERE p.tenant_id = p_tenant_id AND p.school_id = p_school_id
                         AND p.staff_id = v_staff AND p.status = 'Paid'
                         AND make_date(p.pay_year, p.pay_month, 1)
                             BETWEEN DATE_TRUNC('month', v_from)::date AND v_to) THEN
                RAISE EXCEPTION 'Salary for that month is already paid, so this leave cannot be cancelled. Record a payroll adjustment instead.';
            END IF;
        ELSIF v_status <> 'Pending' THEN
            RAISE EXCEPTION 'Only a pending or approved request can be cancelled. This one was %.', LOWER(v_status);
        END IF;

        UPDATE core.staff_leave
        SET status        = 'Cancelled',
            cancelled_by  = p_action_user_id,
            cancelled_at  = now(),
            cancel_reason = TRIM(p_remark)
        WHERE leave_id = p_leave_id AND tenant_id = p_tenant_id AND school_id = p_school_id;

        OPEN p_result FOR
        SELECT TRUE AS success, p_leave_id AS leave_id, 0::numeric AS days,
               'Leave cancelled.' AS message;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation %.', p_operation;
END;
$procedure$;
