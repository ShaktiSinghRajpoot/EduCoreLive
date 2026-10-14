-- Bundle 2026-10-14t: my staff row returns staff_type (My Timetable menu for teaching staff only). Run with:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_14t.sql
-- Sources (re-runnable): staff_self_service.sql

-- ============================================================================
-- Staff self-service: "My Leave" and "My Payslip".
--
-- Every signed-in user who has a staff record in the school can see their own
-- leave balance and applications, apply for leave for themselves, cancel their
-- own request, and read their own payslips. No permission key is needed: being
-- that member of staff IS the permission.
--
-- DESIGN NOTES
--
--   * The staff id is NEVER taken from the caller. Each call resolves it from
--     the signed-in user (core.staff.user_id = p_action_user_id, same tenant and
--     school, not deleted) with core.fn_my_staff_id. A request for a leave or a
--     payslip that is not the caller's own reads as "not found".
--
--   * Leave rules are not copied. BALANCE, DAYS, APPLY and CANCEL call the HR
--     procedure core.sp_staff_leave_manage with the resolved staff id, so the
--     caps (core.fn_leave_entitlement), the School Calendar day count, half
--     days, overlap, joining / last working day, inactive staff and the cancel
--     rule (pending always; approved only before it starts and only when no
--     paid payslip covers it; reason required) are exactly the HR ones. A
--     request applied here goes in as Pending with applied_by = the staff
--     member's own user, and shows up in Leave Management and on the dashboard
--     like any other.
--
--   * Payslips: only rows that payroll has generated (Draft or Paid) for the
--     caller's own staff row. The payment reference (UTR / cheque / UPI id) and
--     who paid it are not returned; the mode and date are.
--
-- Re-runnable. No BEGIN/COMMIT inside: the caller decides the transaction.
-- ============================================================================


-- ── The caller's own staff row (NULL when the user is not staff here) ───────
CREATE OR REPLACE FUNCTION core.fn_my_staff_id(p_tenant_id integer, p_school_id integer, p_user_id integer)
RETURNS integer
LANGUAGE sql
STABLE
AS $function$
    SELECT s.staff_id
    FROM core.staff s
    WHERE s.user_id   = p_user_id
      AND s.tenant_id = p_tenant_id
      AND s.school_id = p_school_id
      AND s.is_deleted = FALSE
      AND p_tenant_id > 1 AND p_school_id > 0 AND p_user_id > 0
    ORDER BY s.staff_id
    LIMIT 1;
$function$;


-- ── My Leave ────────────────────────────────────────────────────────────────
--   ME       the caller's staff row (no row = not staff here)
--   LIST     the caller's own leave requests, newest first
--   BALANCE  per-type balance for the year of p_from_date (default: this year)
--   DAYS     day-count preview (same as Apply)
--   APPLY    a request for the caller -> Pending
--   CANCEL   withdraw one of the caller's own requests (reason required)
CREATE OR REPLACE PROCEDURE core.sp_staff_my_leave(
    IN    p_operation      text,
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_leave_id       integer DEFAULT NULL,
    IN    p_leave_type     text    DEFAULT NULL,
    IN    p_from_date      date    DEFAULT NULL,
    IN    p_to_date        date    DEFAULT NULL,
    IN    p_half_day       boolean DEFAULT FALSE,
    IN    p_reason         text    DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'my_leave_cursor')
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_staff integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    v_staff := core.fn_my_staff_id(p_tenant_id, p_school_id, p_action_user_id);

    -- ── ME ──────────────────────────────────────────────────────────────────
    IF p_operation = 'ME' THEN
        OPEN p_result FOR
        SELECT s.staff_id, s.full_name, s.employee_code, s.designation, s.department,
               s.status, s.joining_date,
               s.staff_type          -- Teaching / Non-Teaching / ... (menu: My Timetable)
        FROM core.staff s
        WHERE s.staff_id = v_staff;
        RETURN;
    END IF;

    -- ── LIST ────────────────────────────────────────────────────────────────
    IF p_operation = 'LIST' THEN
        OPEN p_result FOR
        SELECT l.leave_id, l.leave_type, l.from_date, l.to_date, l.days, l.half_day,
               l.reason, l.status, l.decision_remark,
               l.applied_at, core.fn_payroll_user_name(l.applied_by)   AS applied_by_name,
               l.decided_at, core.fn_payroll_user_name(l.decided_by)   AS decided_by_name,
               l.cancelled_at, core.fn_payroll_user_name(l.cancelled_by) AS cancelled_by_name,
               l.cancel_reason,
               -- Same rule CANCEL enforces, so the page only offers what will work.
               (l.status = 'Pending'
                OR (l.status = 'Approved'
                    AND l.from_date::date > CURRENT_DATE
                    AND NOT EXISTS (
                        SELECT 1 FROM core.staff_payroll p
                        WHERE p.tenant_id = p_tenant_id AND p.school_id = p_school_id
                          AND p.staff_id = l.staff_id AND p.status = 'Paid'
                          AND make_date(p.pay_year, p.pay_month, 1)
                              BETWEEN DATE_TRUNC('month', l.from_date::date)::date AND l.to_date::date))
               ) AS can_cancel
        FROM core.staff_leave l
        WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
          AND l.staff_id = v_staff
        ORDER BY l.from_date DESC, l.leave_id DESC;
        RETURN;
    END IF;

    -- Everything below acts on the caller's own staff row.
    IF v_staff IS NULL THEN
        RAISE EXCEPTION 'You do not have a staff record in this school.';
    END IF;

    IF p_operation IN ('BALANCE', 'DAYS') THEN
        CALL core.sp_staff_leave_manage(
            p_operation      => p_operation,
            p_tenant_id      => p_tenant_id,
            p_school_id      => p_school_id,
            p_action_user_id => p_action_user_id,
            p_staff_id       => v_staff,
            p_from_date      => COALESCE(p_from_date, CASE WHEN p_operation = 'BALANCE' THEN CURRENT_DATE END),
            p_to_date        => p_to_date,
            p_result         => p_result,
            p_half_day       => COALESCE(p_half_day, FALSE));
        RETURN;
    END IF;

    IF p_operation = 'APPLY' THEN
        CALL core.sp_staff_leave_manage(
            p_operation      => 'APPLY',
            p_tenant_id      => p_tenant_id,
            p_school_id      => p_school_id,
            p_action_user_id => p_action_user_id,
            p_staff_id       => v_staff,
            p_leave_type     => p_leave_type,
            p_from_date      => p_from_date,
            p_to_date        => p_to_date,
            p_reason         => p_reason,
            p_result         => p_result,
            p_half_day       => COALESCE(p_half_day, FALSE));
        RETURN;
    END IF;

    IF p_operation = 'CANCEL' THEN
        -- Only the caller's own request. Someone else's reads as not found.
        IF NOT EXISTS (SELECT 1 FROM core.staff_leave
                       WHERE leave_id = p_leave_id AND tenant_id = p_tenant_id
                         AND school_id = p_school_id AND staff_id = v_staff) THEN
            RAISE EXCEPTION 'Leave request not found.';
        END IF;

        CALL core.sp_staff_leave_manage(
            p_operation      => 'CANCEL',
            p_tenant_id      => p_tenant_id,
            p_school_id      => p_school_id,
            p_action_user_id => p_action_user_id,
            p_leave_id       => p_leave_id,
            p_remark         => p_reason,
            p_result         => p_result);
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation %.', p_operation;
END;
$procedure$;


-- ── My Payslip ──────────────────────────────────────────────────────────────
--   LIST  the caller's own generated payslips (Draft / Paid), newest first
--   GET   one of them, with the staff and school names for the printout
CREATE OR REPLACE PROCEDURE core.sp_staff_my_payslip(
    IN    p_operation      text,
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_payroll_id     integer DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'my_payslip_cursor')
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_staff integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    v_staff := core.fn_my_staff_id(p_tenant_id, p_school_id, p_action_user_id);

    IF p_operation NOT IN ('LIST', 'GET') THEN
        RAISE EXCEPTION 'Unknown operation %.', p_operation;
    END IF;

    -- No payment_reference and no paid_by: mode and date are enough for the
    -- staff member, and a UTR / cheque number stays with the office.
    OPEN p_result FOR
    SELECT p.payroll_id, p.pay_month, p.pay_year,
           p.monthly_salary, p.working_days, p.paid_days,
           p.gross, p.lop_days, p.absent_days, p.lop_amount, p.other_add, p.other_deduct, p.net_pay,
           p.status, p.generated_at, p.paid_at, p.payment_mode,
           s.full_name, s.employee_code, s.designation, s.department,
           COALESCE(NULLIF(TRIM(sc.display_name), ''), sc.school_name) AS school_name
    FROM core.staff_payroll p
    JOIN core.staff s ON s.staff_id = p.staff_id
    LEFT JOIN core.schools sc ON sc.school_id = p.school_id AND sc.tenant_id = p.tenant_id
    WHERE p.tenant_id = p_tenant_id AND p.school_id = p_school_id
      AND p.staff_id = v_staff
      AND (p_operation = 'LIST' OR p.payroll_id = p_payroll_id)
    ORDER BY p.pay_year DESC, p.pay_month DESC;
END;
$procedure$;
