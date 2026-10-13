-- ============================================================================
-- Staff payroll: run a month, mark a payslip paid, adjustments, money trail.
--
-- Like the leave page, this screen existed with no backend — Run Payroll and
-- Mark Paid only set a TempData message.
--
-- DESIGN NOTES
--
--   * Salary comes from core.staff.monthly_salary, snapshotted onto the payroll
--     row at run time (monthly_salary). A later salary revision must not
--     silently rewrite last month's payslip — that is the whole reason the
--     amount is stored here rather than joined at read time.
--
--   * Days are SCHOOL working days (core.fn_school_working_days — the School
--     Calendar's weekly offs and holidays excluded, half days 0.5), the same
--     function the leave screen counts with.
--
--   * Pro-rata: a joiner is paid from the joining date, a leaver up to the last
--     working day (core.staff.last_working_date). paid_days = school working days
--     employed in the month; gross = salary x paid_days / working_days. Nobody is
--     paid for a month before they joined or after they left; a leaver IS paid
--     for the days worked in the final month, even when deactivated before the
--     run. Staff "On Leave" (long leave) get a payslip; their unpaid leave is LOP.
--
--   * LOP (Loss of Pay) is APPROVED 'Unpaid' leave inside the employed part of
--     the month, plus the days Staff Attendance (core.staff_attendance) marks
--     Absent / HalfDay (0.5) / Leave on a school working day that no approved
--     leave of any type covers (absent_days). Late costs nothing. A day covered
--     by approved leave is never counted twice. A school that does not mark staff
--     attendance gets exactly the old leave-only LOP. Amounts are worked from the salary, not from a rounded per-day
--     rate, so a month that is all LOP nets exactly 0:
--         gross      = ROUND(salary x paid_days / working_days, 2)
--         lop_amount = gross - ROUND(salary x (paid_days - lop_days) / working_days, 2)
--         net_pay    = gross - lop_amount + other_add - other_deduct   (never below 0)
--
--   * Adjustments (core.staff_payroll_adjustment) are the only way to change
--     pay beyond salary and LOP: Addition (arrears, bonus, encashment, a
--     correction owed), Deduction (fine, advance recovery, a correction taken
--     back) and Advance (money handed over early — recorded with its payment
--     mode/reference and deducted from that month). Each row keeps who, when,
--     how much, which month and why; it is never edited, only voided with a
--     reason while its month is unpaid.
--
--   * A PAID payslip is history: RUN skips it (and reports it when today's
--     figures would differ), the trigger trg_staff_payroll_paid_lock refuses any
--     UPDATE of it, and corrections go as an adjustment in an unpaid month.
--     Mark Paid records the payment mode and reference (UTR / cheque no.), so a
--     "Paid" flag can be matched to a bank statement.
--
--   * Every generate / regenerate / remove / pay / adjust writes a row to
--     core.staff_payroll_history (append-only: a trigger refuses UPDATE). Draft
--     figures may be recomputed, but the trail of what they were is kept.
--
--   * Payroll cannot be run for a future month.
--
--   * One row per staff per month, enforced by a unique index rather than by
--     the proc remembering to check.
--
-- Target DB: PostgreSQL. Safe to re-run. Needs staff_leave.sql (fn_school_working_days),
-- sp_staff_manage.sql (core.staff.last_working_date) and staff_attendance.sql.
-- ============================================================================

CREATE TABLE IF NOT EXISTS core.staff_payroll (
    payroll_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     integer NOT NULL,
    school_id     integer NOT NULL,
    staff_id      integer NOT NULL,

    pay_month     integer NOT NULL,          -- 1..12
    pay_year      integer NOT NULL,

    gross         numeric(12,2) NOT NULL DEFAULT 0,   -- earned for the employed days
    lop_days      numeric(5,1)  NOT NULL DEFAULT 0,
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

-- Oct 2026: pro-rata, half-day LOP, additions, how a payment was made.
DO $mig$
BEGIN
    IF (SELECT data_type FROM information_schema.columns
        WHERE table_schema = 'core' AND table_name = 'staff_payroll' AND column_name = 'lop_days') = 'integer' THEN
        ALTER TABLE core.staff_payroll ALTER COLUMN lop_days TYPE numeric(5,1);
    END IF;
END $mig$;

ALTER TABLE core.staff_payroll ADD COLUMN IF NOT EXISTS monthly_salary    numeric(12,2);  -- salary rate used
ALTER TABLE core.staff_payroll ADD COLUMN IF NOT EXISTS working_days      numeric(5,1);   -- school days in the month
ALTER TABLE core.staff_payroll ADD COLUMN IF NOT EXISTS paid_days         numeric(5,1);   -- of those, days employed
ALTER TABLE core.staff_payroll ADD COLUMN IF NOT EXISTS other_add         numeric(12,2) NOT NULL DEFAULT 0;
ALTER TABLE core.staff_payroll ADD COLUMN IF NOT EXISTS payment_mode      varchar(20);
ALTER TABLE core.staff_payroll ADD COLUMN IF NOT EXISTS payment_reference varchar(60);
ALTER TABLE core.staff_payroll ADD COLUMN IF NOT EXISTS absent_days       numeric(5,1) NOT NULL DEFAULT 0;  -- of lop_days, from Staff Attendance

ALTER TABLE core.staff_payroll DROP CONSTRAINT IF EXISTS chk_staff_payroll_mode;
ALTER TABLE core.staff_payroll ADD CONSTRAINT chk_staff_payroll_mode
    CHECK (payment_mode IS NULL OR payment_mode IN ('Cash', 'Bank Transfer', 'Cheque', 'UPI'));
-- A paid slip says how it was paid. NOT VALID: slips paid before this release
-- have no mode and stay as they are; every new payment must carry one.
ALTER TABLE core.staff_payroll DROP CONSTRAINT IF EXISTS chk_staff_payroll_paid_mode;
ALTER TABLE core.staff_payroll ADD CONSTRAINT chk_staff_payroll_paid_mode
    CHECK (status <> 'Paid' OR payment_mode IS NOT NULL) NOT VALID;

-- A paid payslip is never rewritten -- not by RUN, not by anything else.
CREATE OR REPLACE FUNCTION core.fn_staff_payroll_paid_lock()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
    IF OLD.status = 'Paid' THEN
        RAISE EXCEPTION 'This payslip is already paid and cannot be changed. Record an adjustment in an unpaid month instead.';
    END IF;
    RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_staff_payroll_paid_lock ON core.staff_payroll;
CREATE TRIGGER trg_staff_payroll_paid_lock
    BEFORE UPDATE ON core.staff_payroll
    FOR EACH ROW EXECUTE FUNCTION core.fn_staff_payroll_paid_lock();


-- Additions, deductions and advances against one staff member's month.
CREATE TABLE IF NOT EXISTS core.staff_payroll_adjustment (
    adjustment_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id         integer NOT NULL,
    school_id         integer NOT NULL,
    staff_id          integer NOT NULL,
    pay_month         integer NOT NULL,
    pay_year          integer NOT NULL,
    kind              varchar(20) NOT NULL,      -- Addition | Deduction | Advance
    amount            numeric(12,2) NOT NULL,
    reason            text NOT NULL,
    payment_mode      varchar(20),               -- Advance: how the money was handed over
    payment_reference varchar(60),
    created_by        integer NOT NULL,
    created_at        timestamptz NOT NULL DEFAULT now(),
    is_void           boolean NOT NULL DEFAULT FALSE,
    voided_by         integer,
    voided_at         timestamptz,
    void_reason       text,
    CONSTRAINT chk_staff_payroll_adj_kind   CHECK (kind IN ('Addition', 'Deduction', 'Advance')),
    CONSTRAINT chk_staff_payroll_adj_amount CHECK (amount > 0),
    CONSTRAINT chk_staff_payroll_adj_month  CHECK (pay_month BETWEEN 1 AND 12),
    CONSTRAINT chk_staff_payroll_adj_mode   CHECK (payment_mode IS NULL OR payment_mode IN ('Cash', 'Bank Transfer', 'Cheque', 'UPI'))
);
CREATE INDEX IF NOT EXISTS ix_staff_payroll_adj_period
    ON core.staff_payroll_adjustment (tenant_id, school_id, pay_year, pay_month, staff_id);


-- The money trail. One row per event; never updated.
CREATE TABLE IF NOT EXISTS core.staff_payroll_history (
    history_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id         integer NOT NULL,
    school_id         integer NOT NULL,
    payroll_id        integer,                   -- NULL for an adjustment made before the run
    staff_id          integer NOT NULL,
    pay_month         integer NOT NULL,
    pay_year          integer NOT NULL,
    action            varchar(30) NOT NULL,      -- GENERATED | REGENERATED | DRAFT_REMOVED | PAID
                                                 -- | ADJUSTMENT_ADDED | ADJUSTMENT_VOIDED
    gross             numeric(12,2),
    lop_days          numeric(5,1),
    lop_amount        numeric(12,2),
    other_add         numeric(12,2),
    other_deduct      numeric(12,2),
    net_pay           numeric(12,2),
    payment_mode      varchar(20),
    payment_reference varchar(60),
    note              text,
    action_by         integer NOT NULL,
    action_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_staff_payroll_history_staff
    ON core.staff_payroll_history (tenant_id, school_id, staff_id, pay_year, pay_month);

CREATE OR REPLACE FUNCTION core.fn_staff_payroll_history_lock()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
    RAISE EXCEPTION 'Payroll history cannot be changed.';
END;
$fn$;

DROP TRIGGER IF EXISTS trg_staff_payroll_history_lock ON core.staff_payroll_history;
CREATE TRIGGER trg_staff_payroll_history_lock
    BEFORE UPDATE ON core.staff_payroll_history
    FOR EACH ROW EXECUTE FUNCTION core.fn_staff_payroll_history_lock();


-- Display name of a user for the trail ('' when unknown).
CREATE OR REPLACE FUNCTION core.fn_payroll_user_name(p_user_id integer)
RETURNS text
LANGUAGE sql
STABLE
AS $fn$
    SELECT COALESCE((SELECT up.full_name FROM core.user_profiles up
                     WHERE up.user_id = p_user_id ORDER BY up.user_profile_id LIMIT 1),
                    (SELECT u.email FROM core.users u WHERE u.user_id = p_user_id), '');
$fn$;


-- ----------------------------------------------------------------------------
-- Build (or rebuild) ONE staff member's payslip for one month. Used by RUN for
-- every staff member and by an adjustment for the one it touches.
--
-- Returns what happened:
--   'made'         draft created or brought up to date (unchanged drafts stay as they are)
--   'negative'     draft made, but deductions exceed pay -- net held at 0
--   'removed'      the person was not employed that month; a stale draft was removed
--   'none'         not employed that month, nothing to do
--   'paid'         already paid, today's figures agree
--   'paid_differs' already paid, today's figures would differ (left untouched)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_staff_payslip_build(
    p_tenant_id integer, p_school_id integer, p_action_user_id integer,
    p_staff_id integer, p_month integer, p_year integer)
RETURNS text
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_start   date := make_date(p_year, p_month, 1);
    v_end     date := (make_date(p_year, p_month, 1) + INTERVAL '1 month' - INTERVAL '1 day')::date;
    v_work    numeric;
    v_has     boolean;
    v_emp     boolean;
    p         record;
    s         record;
    v_from    date;
    v_to      date;
    v_paid    numeric := 0;
    v_lop     numeric := 0;
    v_abs     numeric := 0;
    v_salary  numeric;
    v_gross   numeric;
    v_after   numeric;
    v_lop_amt numeric;
    v_add     numeric;
    v_ded     numeric;
    v_raw     numeric;
    v_net     numeric;
BEGIN
    v_work := core.fn_school_working_days(p_tenant_id, p_school_id, v_start, v_end);

    SELECT * INTO p FROM core.staff_payroll
    WHERE tenant_id = p_tenant_id AND school_id = p_school_id
      AND staff_id = p_staff_id AND pay_year = p_year AND pay_month = p_month;
    v_has := FOUND;

    SELECT st.status, st.monthly_salary,
           NULLIF(st.joining_date, '')::date      AS join_d,
           NULLIF(st.last_working_date, '')::date AS lwd
      INTO s
    FROM core.staff st
    WHERE st.staff_id = p_staff_id AND st.tenant_id = p_tenant_id
      AND st.school_id = p_school_id AND st.is_deleted = FALSE;

    -- Employed in this month? An Inactive row without a last working day was
    -- deactivated before that column existed: no honest dates, so no pay.
    v_emp := FOUND AND v_work > 0 AND (s.status <> 'Inactive' OR s.lwd IS NOT NULL);
    IF v_emp THEN
        v_from := GREATEST(v_start, COALESCE(s.join_d, v_start));
        v_to   := LEAST(v_end, COALESCE(s.lwd, v_end));
        v_emp  := v_from <= v_to;
    END IF;
    IF v_emp THEN
        v_paid := core.fn_school_working_days(p_tenant_id, p_school_id, v_from, v_to);
    END IF;

    IF NOT v_emp OR v_paid = 0 THEN
        IF v_has AND p.status = 'Paid' THEN
            RETURN 'paid_differs';
        END IF;
        IF v_has THEN
            DELETE FROM core.staff_payroll WHERE payroll_id = p.payroll_id;
            INSERT INTO core.staff_payroll_history
                (tenant_id, school_id, payroll_id, staff_id, pay_month, pay_year, action,
                 gross, lop_days, lop_amount, other_add, other_deduct, net_pay, note, action_by)
            VALUES (p_tenant_id, p_school_id, p.payroll_id, p_staff_id, p_month, p_year, 'DRAFT_REMOVED',
                    p.gross, p.lop_days, p.lop_amount, p.other_add, p.other_deduct, p.net_pay,
                    'Not employed in this month (joining date / last working day).', p_action_user_id);
            RETURN 'removed';
        END IF;
        RETURN 'none';
    END IF;

    -- LOP: approved Unpaid leave inside the employed part of the month.
    SELECT COALESCE(SUM(CASE WHEN l.half_day THEN l.days
                             ELSE core.fn_school_working_days(p_tenant_id, p_school_id,
                                      GREATEST(l.from_date::date, v_from), LEAST(l.to_date::date, v_to)) END), 0)
      INTO v_lop
    FROM core.staff_leave l
    WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
      AND l.staff_id = p_staff_id
      AND l.status = 'Approved'
      AND LOWER(l.leave_type) = 'unpaid'
      AND l.from_date::date <= v_to AND l.to_date::date >= v_from;

    -- Plus Staff Attendance: Absent / HalfDay / Leave on a school working day
    -- with no approved leave of any type (a covered day is paid leave, or is
    -- already in the Unpaid sum above). A half school day weighs 0.5.
    SELECT COALESCE(SUM(core.fn_school_working_days(p_tenant_id, p_school_id, a.att_date, a.att_date)
                        * CASE a.status WHEN 'HalfDay' THEN 0.5 ELSE 1 END), 0)
      INTO v_abs
    FROM core.staff_attendance a
    WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
      AND a.staff_id = p_staff_id
      AND a.att_date BETWEEN v_from AND v_to
      AND a.status IN ('Absent', 'HalfDay', 'Leave')
      AND NOT EXISTS (SELECT 1 FROM core.staff_leave l
                       WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
                         AND l.staff_id = p_staff_id AND l.status = 'Approved'
                         AND a.att_date BETWEEN l.from_date::date AND l.to_date::date);

    v_lop := LEAST(v_lop + v_abs, v_paid);
    v_abs := LEAST(v_abs, v_lop);

    v_salary  := COALESCE(s.monthly_salary, 0);
    v_gross   := ROUND(v_salary * v_paid / v_work, 2);
    v_after   := ROUND(v_salary * (v_paid - v_lop) / v_work, 2);
    v_lop_amt := v_gross - v_after;

    SELECT COALESCE(SUM(amount) FILTER (WHERE kind = 'Addition'), 0),
           COALESCE(SUM(amount) FILTER (WHERE kind IN ('Deduction', 'Advance')), 0)
      INTO v_add, v_ded
    FROM core.staff_payroll_adjustment
    WHERE tenant_id = p_tenant_id AND school_id = p_school_id
      AND staff_id = p_staff_id AND pay_year = p_year AND pay_month = p_month
      AND is_void = FALSE;

    v_raw := v_after + v_add - v_ded;
    v_net := GREATEST(v_raw, 0);

    IF v_has AND p.status = 'Paid' THEN
        IF p.gross = v_gross AND p.lop_days = v_lop AND p.other_add = v_add
           AND p.other_deduct = v_ded AND p.net_pay = v_net THEN
            RETURN 'paid';
        END IF;
        RETURN 'paid_differs';
    END IF;

    IF NOT v_has THEN
        INSERT INTO core.staff_payroll (
            tenant_id, school_id, staff_id, pay_month, pay_year,
            monthly_salary, working_days, paid_days,
            gross, lop_days, absent_days, lop_amount, other_add, other_deduct, net_pay,
            status, generated_by, generated_at)
        VALUES (
            p_tenant_id, p_school_id, p_staff_id, p_month, p_year,
            v_salary, v_work, v_paid,
            v_gross, v_lop, v_abs, v_lop_amt, v_add, v_ded, v_net,
            'Draft', p_action_user_id, now())
        RETURNING * INTO p;

        INSERT INTO core.staff_payroll_history
            (tenant_id, school_id, payroll_id, staff_id, pay_month, pay_year, action,
             gross, lop_days, lop_amount, other_add, other_deduct, net_pay, action_by)
        VALUES (p_tenant_id, p_school_id, p.payroll_id, p_staff_id, p_month, p_year, 'GENERATED',
                v_gross, v_lop, v_lop_amt, v_add, v_ded, v_net, p_action_user_id);

    ELSIF (p.monthly_salary, p.working_days, p.paid_days, p.gross, p.lop_days, p.absent_days, p.lop_amount,
           p.other_add, p.other_deduct, p.net_pay)
          IS DISTINCT FROM
          (v_salary, v_work, v_paid, v_gross, v_lop, v_abs, v_lop_amt, v_add, v_ded, v_net) THEN
        UPDATE core.staff_payroll
        SET monthly_salary = v_salary, working_days = v_work, paid_days = v_paid,
            gross = v_gross, lop_days = v_lop, absent_days = v_abs, lop_amount = v_lop_amt,
            other_add = v_add, other_deduct = v_ded, net_pay = v_net,
            generated_by = p_action_user_id, generated_at = now()
        WHERE payroll_id = p.payroll_id;

        INSERT INTO core.staff_payroll_history
            (tenant_id, school_id, payroll_id, staff_id, pay_month, pay_year, action,
             gross, lop_days, lop_amount, other_add, other_deduct, net_pay, note, action_by)
        VALUES (p_tenant_id, p_school_id, p.payroll_id, p_staff_id, p_month, p_year, 'REGENERATED',
                v_gross, v_lop, v_lop_amt, v_add, v_ded, v_net,
                format('Was gross %s, LOP %s, net %s.', p.gross, p.lop_amount, p.net_pay), p_action_user_id);
    END IF;

    RETURN CASE WHEN v_raw < 0 THEN 'negative' ELSE 'made' END;
END;
$fn$;


-- The signature grew trailing payment parameters; drop the old one so a
-- 9-argument call is not ambiguous between two overloads.
DROP PROCEDURE IF EXISTS core.sp_staff_payroll_manage(
    text, integer, integer, integer, integer, integer, integer, text, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_staff_payroll_manage(
    IN    p_operation         text,          -- LIST | RUN | MARK_PAID | HISTORY
    IN    p_tenant_id         integer,
    IN    p_school_id         integer,
    IN    p_action_user_id    integer,
    IN    p_month             integer DEFAULT NULL,
    IN    p_year              integer DEFAULT NULL,
    IN    p_payroll_id        integer DEFAULT NULL,
    IN    p_department        text    DEFAULT NULL,
    INOUT p_result            refcursor DEFAULT 'payroll_cursor'::refcursor,
    -- MARK_PAID: how it was paid. Last so positional callers still work.
    IN    p_payment_mode      text    DEFAULT NULL,
    IN    p_payment_reference text    DEFAULT NULL)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_start    date;
    v_end      date;
    v_work     numeric;
    v_made     integer := 0;
    v_skipped  integer := 0;
    v_differs  integer := 0;
    v_removed  integer := 0;
    v_negative integer := 0;
    v_out      text;
    v_status   text;
    v_mode     text;
    v_ref      text;
    r          record;
    v_slip     record;
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
               p.monthly_salary, p.working_days, p.paid_days,
               p.gross, p.lop_days, p.absent_days, p.lop_amount, p.other_add, p.other_deduct, p.net_pay,
               p.status, p.generated_at, p.paid_at, p.payment_mode, p.payment_reference,
               core.fn_payroll_user_name(p.paid_by) AS paid_by_name
        FROM core.staff_payroll p
        JOIN core.staff s ON s.staff_id = p.staff_id
        WHERE p.tenant_id = p_tenant_id AND p.school_id = p_school_id
          AND p.pay_month = p_month AND p.pay_year = p_year
          AND (p_department IS NULL OR TRIM(p_department) = ''
               OR LOWER(COALESCE(s.department, '')) = LOWER(TRIM(p_department)))
        ORDER BY s.full_name;
        RETURN;
    END IF;

    -- ── HISTORY: the money trail of one payslip's staff member and month ────
    IF p_operation = 'HISTORY' THEN
        SELECT staff_id, pay_month, pay_year INTO v_slip FROM core.staff_payroll
        WHERE payroll_id = p_payroll_id AND tenant_id = p_tenant_id AND school_id = p_school_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Payslip not found.';
        END IF;

        OPEN p_result FOR
        SELECT h.history_id, h.action, h.gross, h.lop_days, h.lop_amount, h.other_add,
               h.other_deduct, h.net_pay, h.payment_mode, h.payment_reference, h.note,
               h.action_at, core.fn_payroll_user_name(h.action_by) AS action_by_name
        FROM core.staff_payroll_history h
        WHERE h.tenant_id = p_tenant_id AND h.school_id = p_school_id
          AND h.staff_id = v_slip.staff_id AND h.pay_month = v_slip.pay_month AND h.pay_year = v_slip.pay_year
        ORDER BY h.action_at, h.history_id;
        RETURN;
    END IF;

    -- ── RUN ─────────────────────────────────────────────────────────────────
    IF p_operation = 'RUN' THEN
        IF p_month IS NULL OR p_year IS NULL THEN
            RAISE EXCEPTION 'Choose the payroll month.';
        END IF;
        IF p_month NOT BETWEEN 1 AND 12 THEN
            RAISE EXCEPTION 'Choose a month between 1 and 12.';
        END IF;

        v_start := make_date(p_year, p_month, 1);
        v_end   := (v_start + INTERVAL '1 month' - INTERVAL '1 day')::date;

        IF v_start > DATE_TRUNC('month', CURRENT_DATE)::date THEN
            RAISE EXCEPTION 'Payroll cannot be run for a future month.';
        END IF;

        v_work := core.fn_school_working_days(p_tenant_id, p_school_id, v_start, v_end);
        IF v_work = 0 THEN
            RAISE EXCEPTION 'That month has no working days on the school calendar.';
        END IF;

        -- One run per school and month at a time.
        PERFORM pg_advisory_xact_lock(p_school_id, p_year * 100 + p_month);

        -- Every staff row of the school (leavers too: their last month is owed),
        -- plus any draft whose staff row has gone, so stale drafts are removed.
        FOR r IN
            SELECT s.staff_id FROM core.staff s
            WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id AND s.is_deleted = FALSE
            UNION
            SELECT p2.staff_id FROM core.staff_payroll p2
            WHERE p2.tenant_id = p_tenant_id AND p2.school_id = p_school_id
              AND p2.pay_year = p_year AND p2.pay_month = p_month
        LOOP
            v_out := core.fn_staff_payslip_build(p_tenant_id, p_school_id, p_action_user_id,
                                                  r.staff_id, p_month, p_year);
            IF v_out IN ('made', 'negative') THEN v_made := v_made + 1; END IF;
            IF v_out = 'negative'            THEN v_negative := v_negative + 1; END IF;
            IF v_out IN ('paid', 'paid_differs') THEN v_skipped := v_skipped + 1; END IF;
            IF v_out = 'paid_differs'        THEN v_differs := v_differs + 1; END IF;
            IF v_out = 'removed'             THEN v_removed := v_removed + 1; END IF;
        END LOOP;

        OPEN p_result FOR
        SELECT TRUE AS success, v_made AS generated, v_skipped AS skipped, v_work AS working_days,
               v_made || ' payslip(s) generated for ' || trim_scale(v_work) || ' working day(s).'
               || CASE WHEN v_skipped > 0
                       THEN ' ' || v_skipped || ' already paid and left untouched.' ELSE '' END
               || CASE WHEN v_differs > 0
                       THEN ' ' || v_differs || ' paid payslip(s) differ from today''s salary/leave -- record an adjustment in an unpaid month if money is owed.' ELSE '' END
               || CASE WHEN v_removed > 0
                       THEN ' ' || v_removed || ' draft(s) removed for staff not employed that month.' ELSE '' END
               || CASE WHEN v_negative > 0
                       THEN ' ' || v_negative || ' payslip(s) have deductions larger than the pay; net held at zero.' ELSE '' END
               AS message;
        RETURN;
    END IF;

    -- ── MARK_PAID ───────────────────────────────────────────────────────────
    IF p_operation = 'MARK_PAID' THEN
        SELECT * INTO v_slip
        FROM core.staff_payroll
        WHERE payroll_id = p_payroll_id
          AND tenant_id = p_tenant_id AND school_id = p_school_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Payslip not found.';
        END IF;

        -- Paying twice would overwrite who paid it and when.
        IF v_slip.status = 'Paid' THEN
            RAISE EXCEPTION 'This payslip is already marked paid.';
        END IF;

        SELECT m INTO v_mode FROM unnest(ARRAY['Cash', 'Bank Transfer', 'Cheque', 'UPI']) AS m
        WHERE LOWER(m) = LOWER(TRIM(COALESCE(p_payment_mode, '')));
        IF v_mode IS NULL THEN
            RAISE EXCEPTION 'Choose how the salary was paid: Cash, Bank Transfer, Cheque or UPI.';
        END IF;
        v_ref := NULLIF(TRIM(COALESCE(p_payment_reference, '')), '');
        IF v_mode <> 'Cash' AND v_ref IS NULL THEN
            RAISE EXCEPTION 'Enter the % reference (UTR / cheque number / UPI id) so the payment can be traced.', v_mode;
        END IF;
        IF length(v_ref) > 60 THEN
            RAISE EXCEPTION 'The payment reference is too long (60 characters at most).';
        END IF;

        UPDATE core.staff_payroll
        SET status = 'Paid', paid_by = p_action_user_id, paid_at = now(),
            payment_mode = v_mode, payment_reference = v_ref
        WHERE payroll_id = p_payroll_id
          AND tenant_id = p_tenant_id AND school_id = p_school_id
          AND status = 'Draft';
        IF NOT FOUND THEN
            RAISE EXCEPTION 'This payslip is already marked paid.';
        END IF;

        INSERT INTO core.staff_payroll_history
            (tenant_id, school_id, payroll_id, staff_id, pay_month, pay_year, action,
             gross, lop_days, lop_amount, other_add, other_deduct, net_pay,
             payment_mode, payment_reference, action_by)
        VALUES (p_tenant_id, p_school_id, v_slip.payroll_id, v_slip.staff_id, v_slip.pay_month, v_slip.pay_year, 'PAID',
                v_slip.gross, v_slip.lop_days, v_slip.lop_amount, v_slip.other_add, v_slip.other_deduct, v_slip.net_pay,
                v_mode, v_ref, p_action_user_id);

        OPEN p_result FOR
        SELECT TRUE AS success, 0 AS generated, 0 AS skipped, 0::numeric AS working_days,
               'Payslip marked paid (' || v_mode || COALESCE(', ' || v_ref, '') || ').' AS message;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation %.', p_operation;
END;
$procedure$;


-- ----------------------------------------------------------------------------
-- Payroll adjustments: LIST | ADD | VOID.
--   ADD  : Addition / Deduction / Advance for one staff member's month. Refused
--          when that month is already paid (corrections go to an unpaid month)
--          or the person was not employed in it. A draft for that month is
--          rebuilt at once; a deduction that would push its net below zero is
--          refused.
--   VOID : cancels an adjustment (with a reason) while its month is unpaid.
-- Nothing is ever deleted or edited in place.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE core.sp_staff_payroll_adjust(
    IN    p_operation         text,
    IN    p_tenant_id         integer,
    IN    p_school_id         integer,
    IN    p_action_user_id    integer,
    IN    p_adjustment_id     integer DEFAULT NULL,
    IN    p_staff_id          integer DEFAULT NULL,
    IN    p_month             integer DEFAULT NULL,
    IN    p_year              integer DEFAULT NULL,
    IN    p_kind              text    DEFAULT NULL,
    IN    p_amount            numeric DEFAULT NULL,
    IN    p_reason            text    DEFAULT NULL,
    IN    p_payment_mode      text    DEFAULT NULL,
    IN    p_payment_reference text    DEFAULT NULL,
    INOUT p_result            refcursor DEFAULT 'payroll_adjust_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_start  date;
    v_end    date;
    v_kind   text;
    v_mode   text;
    v_ref    text;
    v_reason text := NULLIF(TRIM(COALESCE(p_reason, '')), '');
    v_id     integer;
    v_out    text;
    v_pid    integer;
    v_pstat  text;
    a        record;
    s        record;
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
        SELECT a2.adjustment_id, a2.staff_id, st.full_name, st.employee_code,
               a2.pay_month, a2.pay_year, a2.kind, a2.amount, a2.reason,
               a2.payment_mode, a2.payment_reference,
               a2.created_at, core.fn_payroll_user_name(a2.created_by) AS created_by_name,
               a2.is_void, a2.voided_at, a2.void_reason
        FROM core.staff_payroll_adjustment a2
        JOIN core.staff st ON st.staff_id = a2.staff_id
        WHERE a2.tenant_id = p_tenant_id AND a2.school_id = p_school_id
          AND a2.pay_month = p_month AND a2.pay_year = p_year
          AND (p_staff_id IS NULL OR a2.staff_id = p_staff_id)
        ORDER BY st.full_name, a2.created_at, a2.adjustment_id;
        RETURN;
    END IF;

    -- ── ADD ─────────────────────────────────────────────────────────────────
    IF p_operation = 'ADD' THEN
        IF p_month IS NULL OR p_year IS NULL OR p_month NOT BETWEEN 1 AND 12 THEN
            RAISE EXCEPTION 'Choose the payroll month.';
        END IF;
        v_start := make_date(p_year, p_month, 1);
        v_end   := (v_start + INTERVAL '1 month' - INTERVAL '1 day')::date;
        IF v_start > DATE_TRUNC('month', CURRENT_DATE)::date THEN
            RAISE EXCEPTION 'Adjustments cannot be made for a future month.';
        END IF;

        SELECT k INTO v_kind FROM unnest(ARRAY['Addition', 'Deduction', 'Advance']) AS k
        WHERE LOWER(k) = LOWER(TRIM(COALESCE(p_kind, '')));
        IF v_kind IS NULL THEN
            RAISE EXCEPTION 'Choose Addition, Deduction or Advance.';
        END IF;
        IF p_amount IS NULL OR p_amount <= 0 THEN
            RAISE EXCEPTION 'Enter an amount greater than zero.';
        END IF;
        IF p_amount <> ROUND(p_amount, 2) THEN
            RAISE EXCEPTION 'Amounts are in rupees and paise (two decimals at most).';
        END IF;
        IF v_reason IS NULL THEN
            RAISE EXCEPTION 'Give a reason for the adjustment.';
        END IF;

        IF v_kind = 'Advance' THEN
            SELECT m INTO v_mode FROM unnest(ARRAY['Cash', 'Bank Transfer', 'Cheque', 'UPI']) AS m
            WHERE LOWER(m) = LOWER(TRIM(COALESCE(p_payment_mode, '')));
            IF v_mode IS NULL THEN
                RAISE EXCEPTION 'Choose how the advance was paid: Cash, Bank Transfer, Cheque or UPI.';
            END IF;
            v_ref := NULLIF(TRIM(COALESCE(p_payment_reference, '')), '');
            IF v_mode <> 'Cash' AND v_ref IS NULL THEN
                RAISE EXCEPTION 'Enter the % reference so the advance can be traced.', v_mode;
            END IF;
        END IF;

        SELECT status, NULLIF(joining_date, '')::date AS join_d, NULLIF(last_working_date, '')::date AS lwd
          INTO s
        FROM core.staff
        WHERE staff_id = p_staff_id AND tenant_id = p_tenant_id
          AND school_id = p_school_id AND is_deleted = FALSE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Staff member not found.';
        END IF;
        IF (s.status = 'Inactive' AND s.lwd IS NULL)
           OR COALESCE(s.join_d, v_start) > v_end
           OR COALESCE(s.lwd, v_end) < v_start THEN
            RAISE EXCEPTION 'This staff member was not on the payroll in that month.';
        END IF;

        SELECT payroll_id, status INTO v_pid, v_pstat FROM core.staff_payroll
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND staff_id = p_staff_id AND pay_year = p_year AND pay_month = p_month;
        IF v_pstat = 'Paid' THEN
            RAISE EXCEPTION 'Salary for % is already paid. Record this against the next unpaid month.',
                to_char(v_start, 'FMMonth YYYY');
        END IF;

        INSERT INTO core.staff_payroll_adjustment
            (tenant_id, school_id, staff_id, pay_month, pay_year, kind, amount, reason,
             payment_mode, payment_reference, created_by)
        VALUES (p_tenant_id, p_school_id, p_staff_id, p_month, p_year, v_kind, p_amount, v_reason,
                v_mode, v_ref, p_action_user_id)
        RETURNING adjustment_id INTO v_id;

        -- A draft for that month picks the adjustment up straight away.
        IF v_pid IS NOT NULL THEN
            v_out := core.fn_staff_payslip_build(p_tenant_id, p_school_id, p_action_user_id,
                                                  p_staff_id, p_month, p_year);
            IF v_out = 'negative' THEN
                RAISE EXCEPTION 'This deduction is more than the pay left for that month.';
            END IF;
        END IF;

        INSERT INTO core.staff_payroll_history
            (tenant_id, school_id, payroll_id, staff_id, pay_month, pay_year, action,
             net_pay, payment_mode, payment_reference, note, action_by)
        VALUES (p_tenant_id, p_school_id, v_pid, p_staff_id, p_month, p_year, 'ADJUSTMENT_ADDED',
                (SELECT net_pay FROM core.staff_payroll WHERE payroll_id = v_pid),
                v_mode, v_ref,
                format('#%s %s %s: %s', v_id, v_kind, p_amount, v_reason), p_action_user_id);

        OPEN p_result FOR
        SELECT TRUE AS success, v_id AS adjustment_id,
               v_kind || ' of ' || p_amount || ' recorded'
               || CASE WHEN v_pid IS NULL THEN '. It is included when payroll is run for that month.'
                       ELSE ' and the draft payslip updated.' END AS message;
        RETURN;
    END IF;

    -- ── VOID ────────────────────────────────────────────────────────────────
    IF p_operation = 'VOID' THEN
        SELECT * INTO a FROM core.staff_payroll_adjustment
        WHERE adjustment_id = p_adjustment_id AND tenant_id = p_tenant_id AND school_id = p_school_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Adjustment not found.';
        END IF;
        IF a.is_void THEN
            RAISE EXCEPTION 'This adjustment is already void.';
        END IF;
        IF v_reason IS NULL THEN
            RAISE EXCEPTION 'Give a reason for voiding the adjustment.';
        END IF;

        SELECT payroll_id INTO v_pid FROM core.staff_payroll
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND staff_id = a.staff_id AND pay_year = a.pay_year AND pay_month = a.pay_month;
        IF v_pid IS NOT NULL AND (SELECT status FROM core.staff_payroll WHERE payroll_id = v_pid) = 'Paid' THEN
            RAISE EXCEPTION 'Salary for that month is already paid, so this adjustment stays. Record a correction in an unpaid month.';
        END IF;

        UPDATE core.staff_payroll_adjustment
        SET is_void = TRUE, voided_by = p_action_user_id, voided_at = now(), void_reason = v_reason
        WHERE adjustment_id = p_adjustment_id;

        IF v_pid IS NOT NULL THEN
            v_out := core.fn_staff_payslip_build(p_tenant_id, p_school_id, p_action_user_id,
                                                  a.staff_id, a.pay_month, a.pay_year);
            IF v_out = 'negative' THEN
                RAISE EXCEPTION 'Voiding this addition would leave less than the deductions for that month.';
            END IF;
        END IF;

        INSERT INTO core.staff_payroll_history
            (tenant_id, school_id, payroll_id, staff_id, pay_month, pay_year, action,
             net_pay, note, action_by)
        VALUES (p_tenant_id, p_school_id, v_pid, a.staff_id, a.pay_month, a.pay_year, 'ADJUSTMENT_VOIDED',
                (SELECT net_pay FROM core.staff_payroll WHERE payroll_id = v_pid),
                format('#%s %s %s voided: %s', a.adjustment_id, a.kind, a.amount, v_reason), p_action_user_id);

        OPEN p_result FOR
        SELECT TRUE AS success, a.adjustment_id AS adjustment_id, 'Adjustment voided.' AS message;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation %.', p_operation;
END;
$procedure$;
