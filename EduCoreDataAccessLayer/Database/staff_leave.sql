-- ============================================================================
-- Staff leave: apply, approve, reject.
--
-- The page existed with no backend at all — Apply/Approve/Reject just set a
-- TempData message and changed nothing. This is the real thing.
--
-- DESIGN NOTES
--
--   * Days are counted EXCLUDING SUNDAYS, the same rule the attendance register
--     uses. A Monday-to-Saturday leave is 6 days, not 7. Keeping one definition
--     of "a working day" across the app matters more than any one screen.
--
--   * Leave type 'Unpaid' is what payroll charges as Loss of Pay. Every other
--     type is paid leave and costs the staff member nothing. That one flag is
--     the only link between this table and payroll — deliberately not a separate
--     LOP register, which could drift out of step with the leave record.
--
--   * Overlap is refused. Two live requests covering the same day would be
--     counted twice by payroll, and it almost always means a duplicate entry.
--
--   * A decided request cannot be decided again — approve/reject record who and
--     when, and overwriting that would lose the history.
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
    days            integer NOT NULL,            -- working days, Sundays excluded
    reason          text,

    status          varchar(20) NOT NULL DEFAULT 'Pending',
    decision_remark text,

    applied_by      integer NOT NULL DEFAULT 0,
    applied_at      timestamptz NOT NULL DEFAULT now(),
    decided_by      integer,
    decided_at      timestamptz,

    CONSTRAINT chk_staff_leave_status CHECK (status IN ('Pending', 'Approved', 'Rejected')),
    CONSTRAINT chk_staff_leave_dates  CHECK (to_date >= from_date)
);

CREATE INDEX IF NOT EXISTS ix_staff_leave_staff
    ON core.staff_leave (tenant_id, school_id, staff_id, from_date);
CREATE INDEX IF NOT EXISTS ix_staff_leave_status
    ON core.staff_leave (tenant_id, school_id, status);


-- Working days between two dates, Sundays excluded. ONE definition, used by the
-- apply path and by payroll's LOP count so the two can never disagree.
CREATE OR REPLACE FUNCTION core.fn_working_days(p_from date, p_to date)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT COUNT(*)::int
    FROM generate_series(p_from, p_to, INTERVAL '1 day') AS g(d)
    WHERE EXTRACT(DOW FROM g.d) <> 0;
$fn$;


CREATE OR REPLACE PROCEDURE core.sp_staff_leave_manage(
    IN    p_operation      text,          -- LIST | APPLY | DECIDE
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_leave_id       integer DEFAULT NULL,
    IN    p_staff_id       integer DEFAULT NULL,
    IN    p_leave_type     text    DEFAULT NULL,
    IN    p_from_date      date    DEFAULT NULL,
    IN    p_to_date        date    DEFAULT NULL,
    IN    p_reason         text    DEFAULT NULL,
    IN    p_status         text    DEFAULT NULL,   -- DECIDE: Approved | Rejected
    IN    p_remark         text    DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'leave_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_days   integer;
    v_id     integer;
    v_status text;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    -- ── LIST ────────────────────────────────────────────────────────────────
    IF p_operation = 'LIST' THEN
        OPEN p_result FOR
        SELECT l.leave_id, l.staff_id, s.full_name, s.employee_code, s.designation,
               l.leave_type, l.from_date, l.to_date, l.days, l.reason,
               l.status, l.decision_remark, l.applied_at, l.decided_at,
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

    -- ── APPLY ───────────────────────────────────────────────────────────────
    IF p_operation = 'APPLY' THEN
        IF COALESCE(p_staff_id, 0) <= 0 THEN
            RAISE EXCEPTION 'Choose the staff member.';
        END IF;
        IF p_leave_type IS NULL OR TRIM(p_leave_type) = '' THEN
            RAISE EXCEPTION 'Choose the leave type.';
        END IF;
        IF p_from_date IS NULL OR p_to_date IS NULL THEN
            RAISE EXCEPTION 'Choose both the from and to dates.';
        END IF;
        IF p_to_date < p_from_date THEN
            RAISE EXCEPTION 'The to date cannot be before the from date.';
        END IF;

        IF NOT EXISTS (SELECT 1 FROM core.staff
                       WHERE staff_id = p_staff_id AND tenant_id = p_tenant_id
                         AND school_id = p_school_id AND is_deleted = FALSE) THEN
            RAISE EXCEPTION 'Staff member not found.';
        END IF;

        v_days := core.fn_working_days(p_from_date, p_to_date);

        -- A range that is only Sundays is nothing to approve.
        IF v_days = 0 THEN
            RAISE EXCEPTION 'That range has no working days in it (Sundays are not counted).';
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

        INSERT INTO core.staff_leave (
            tenant_id, school_id, staff_id, leave_type, from_date, to_date,
            days, reason, status, applied_by)
        VALUES (
            p_tenant_id, p_school_id, p_staff_id, TRIM(p_leave_type), p_from_date, p_to_date,
            v_days, NULLIF(TRIM(COALESCE(p_reason, '')), ''), 'Pending', p_action_user_id)
        RETURNING leave_id INTO v_id;

        OPEN p_result FOR
        SELECT TRUE AS success, v_id AS leave_id, v_days AS days,
               'Leave applied for ' || v_days || ' working day(s).' AS message;
        RETURN;
    END IF;

    -- ── DECIDE ──────────────────────────────────────────────────────────────
    IF p_operation = 'DECIDE' THEN
        IF p_status NOT IN ('Approved', 'Rejected') THEN
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

        OPEN p_result FOR
        SELECT TRUE AS success, p_leave_id AS leave_id, 0 AS days,
               'Leave ' || LOWER(p_status) || '.' AS message;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation %.', p_operation;
END;
$procedure$;
