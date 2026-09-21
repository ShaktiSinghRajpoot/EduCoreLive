-- ============================================================================
-- Staff payroll: run a month, mark a payslip paid.
--
-- Like the leave page, this screen existed with no backend — Run Payroll and
-- Mark Paid only set a TempData message.
--
-- DESIGN NOTES
--
--   * Gross comes from core.staff.monthly_salary, snapshotted onto the payroll
--     row at run time. A later salary revision must not silently rewrite last
--     month's payslip — that is the whole reason the amount is stored here
--     rather than joined at read time.
--
--   * LOP (Loss of Pay) is APPROVED 'Unpaid' leave overlapping the month,
--     counted in working days (Sundays excluded) by core.fn_working_days — the
--     same function the leave screen uses, so the two can never disagree. A
--     pending unpaid leave does not cost anything until somebody approves it.
--
--   * Per-day rate = gross / working days IN THAT MONTH, not a flat 30. A
--     February day is worth more than a July day, and staff notice.
--
--   * A PAID month cannot be re-run. Re-running would recompute a payslip the
--     school has already acted on. Draft rows are replaced freely.
--
--   * One row per staff per month, enforced by a unique index rather than by
--     the proc remembering to check.
--
-- Target DB: PostgreSQL. Safe to re-run.
-- ============================================================================

CREATE TABLE IF NOT EXISTS core.staff_payroll (
    payroll_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     integer NOT NULL,
    school_id     integer NOT NULL,
    staff_id      integer NOT NULL,

    pay_month     integer NOT NULL,          -- 1..12
    pay_year      integer NOT NULL,

    gross         numeric(12,2) NOT NULL DEFAULT 0,   -- snapshot of monthly_salary
    lop_days      integer       NOT NULL DEFAULT 0,
    lop_amount    numeric(12,2) NOT NULL DEFAULT 0,
    other_deduct  numeric(12,2) NOT NULL DEFAULT 0,
    net_pay       numeric(12,2) NOT NULL DEFAULT 0,

    status        varchar(20) NOT NULL DEFAULT 'Draft',
    generated_by  integer NOT NULL DEFAULT 0,
    generated_at  timestamptz NOT NULL DEFAULT now(),
    paid_by       integer,
    paid_at       timestamptz,

    CONSTRAINT chk_staff_payroll_status CHECK (status IN ('Draft', 'Paid')),
    CONSTRAINT chk_staff_payroll_month  CHECK (pay_month BETWEEN 1 AND 12)
);

-- One payslip per staff per month. A constraint, not a convention.
CREATE UNIQUE INDEX IF NOT EXISTS ux_staff_payroll_period
    ON core.staff_payroll (tenant_id, school_id, staff_id, pay_year, pay_month);


CREATE OR REPLACE PROCEDURE core.sp_staff_payroll_manage(
    IN    p_operation      text,          -- LIST | RUN | MARK_PAID
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_month          integer DEFAULT NULL,
    IN    p_year           integer DEFAULT NULL,
    IN    p_payroll_id     integer DEFAULT NULL,
    IN    p_department     text    DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'payroll_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_start    date;
    v_end      date;
    v_work     integer;
    v_made     integer := 0;
    v_skipped  integer := 0;
    v_status   text;
    r          record;
    v_lop      integer;
    v_rate     numeric(12,2);
    v_lop_amt  numeric(12,2);
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    -- ── LIST ────────────────────────────────────────────────────────────────
    IF p_operation = 'LIST' THEN
        IF p_month IS NULL OR p_year IS NULL THEN
            RAISE EXCEPTION 'Choose the payroll month.';
        END IF;

        OPEN p_result FOR
        SELECT p.payroll_id, p.staff_id, s.full_name, s.employee_code,
               s.designation, s.department,
               p.pay_month, p.pay_year,
               p.gross, p.lop_days, p.lop_amount, p.other_deduct, p.net_pay,
               p.status, p.paid_at
        FROM core.staff_payroll p
        JOIN core.staff s ON s.staff_id = p.staff_id
        WHERE p.tenant_id = p_tenant_id AND p.school_id = p_school_id
          AND p.pay_month = p_month AND p.pay_year = p_year
          AND (p_department IS NULL OR TRIM(p_department) = ''
               OR LOWER(COALESCE(s.department, '')) = LOWER(TRIM(p_department)))
        ORDER BY s.full_name;
        RETURN;
    END IF;

    -- ── RUN ─────────────────────────────────────────────────────────────────
    IF p_operation = 'RUN' THEN
        IF p_month IS NULL OR p_year IS NULL THEN
            RAISE EXCEPTION 'Choose the payroll month.';
        END IF;

        v_start := make_date(p_year, p_month, 1);
        v_end   := (v_start + INTERVAL '1 month' - INTERVAL '1 day')::date;
        v_work  := core.fn_working_days(v_start, v_end);

        IF v_work = 0 THEN
            RAISE EXCEPTION 'That month has no working days.';
        END IF;

        FOR r IN
            SELECT s.staff_id, COALESCE(s.monthly_salary, 0) AS gross
            FROM core.staff s
            WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id
              AND s.is_deleted = FALSE
              AND COALESCE(s.status, 'Active') = 'Active'
        LOOP
            -- A payslip already paid is history; leave it exactly as it is.
            SELECT status INTO v_status
            FROM core.staff_payroll
            WHERE tenant_id = p_tenant_id AND school_id = p_school_id
              AND staff_id = r.staff_id AND pay_year = p_year AND pay_month = p_month;

            IF FOUND AND v_status = 'Paid' THEN
                v_skipped := v_skipped + 1;
                CONTINUE;
            END IF;

            -- LOP: approved UNPAID leave, only the part inside this month, in
            -- working days. Pending leave costs nothing until it is approved.
            SELECT COALESCE(SUM(core.fn_working_days(
                        GREATEST(l.from_date::date, v_start),
                        LEAST(l.to_date::date,   v_end))), 0)
              INTO v_lop
            FROM core.staff_leave l
            WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
              AND l.staff_id  = r.staff_id
              AND l.status    = 'Approved'
              AND LOWER(l.leave_type) = 'unpaid'
              AND l.from_date::date <= v_end AND l.to_date::date >= v_start;

            -- Per-day on THIS month's working days, not a flat 30.
            v_rate    := ROUND(r.gross / v_work, 2);
            v_lop_amt := ROUND(v_rate * v_lop, 2);

            -- Never pay a negative salary, however many days were lost.
            INSERT INTO core.staff_payroll (
                tenant_id, school_id, staff_id, pay_month, pay_year,
                gross, lop_days, lop_amount, other_deduct, net_pay,
                status, generated_by, generated_at)
            VALUES (
                p_tenant_id, p_school_id, r.staff_id, p_month, p_year,
                r.gross, v_lop, v_lop_amt, 0, GREATEST(r.gross - v_lop_amt, 0),
                'Draft', p_action_user_id, now())
            ON CONFLICT (tenant_id, school_id, staff_id, pay_year, pay_month)
            DO UPDATE SET
                gross        = EXCLUDED.gross,
                lop_days     = EXCLUDED.lop_days,
                lop_amount   = EXCLUDED.lop_amount,
                net_pay      = EXCLUDED.net_pay,
                generated_by = EXCLUDED.generated_by,
                generated_at = EXCLUDED.generated_at;

            v_made := v_made + 1;
        END LOOP;

        OPEN p_result FOR
        SELECT TRUE AS success, v_made AS generated, v_skipped AS skipped, v_work AS working_days,
               v_made || ' payslip(s) generated for ' || v_work || ' working day(s)'
               || CASE WHEN v_skipped > 0
                       THEN '. ' || v_skipped || ' already paid and left untouched.'
                       ELSE '.' END AS message;
        RETURN;
    END IF;

    -- ── MARK_PAID ───────────────────────────────────────────────────────────
    IF p_operation = 'MARK_PAID' THEN
        SELECT status INTO v_status
        FROM core.staff_payroll
        WHERE payroll_id = p_payroll_id
          AND tenant_id = p_tenant_id AND school_id = p_school_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Payslip not found.';
        END IF;

        -- Paying twice would overwrite who paid it and when.
        IF v_status = 'Paid' THEN
            RAISE EXCEPTION 'This payslip is already marked paid.';
        END IF;

        UPDATE core.staff_payroll
        SET status = 'Paid', paid_by = p_action_user_id, paid_at = now()
        WHERE payroll_id = p_payroll_id
          AND tenant_id = p_tenant_id AND school_id = p_school_id;

        OPEN p_result FOR
        SELECT TRUE AS success, 0 AS generated, 0 AS skipped, 0 AS working_days,
               'Payslip marked paid.' AS message;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation %.', p_operation;
END;
$procedure$;
