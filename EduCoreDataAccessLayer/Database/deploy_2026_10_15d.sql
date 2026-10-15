-- Bundle 2026-10-15d: real-world flow fixes (leaving / TC / re-admit, class change, fee heads, calendar, staff leaving, session dates, admission pay-today). Run with:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_15d.sql
-- Sources (re-runnable, in this order): student_money_lifecycle.sql, student_exit.sql, transfer_certificate.sql, fee_receipt_cancel.sql, fee_advance.sql, student_master_fields.sql, student_update.sql, exam_marks.sql, fee_head_cascade_delete.sql, fee_head_identity.sql, school_calendar.sql, sp_staff_manage.sql, academic_year_class_section_fixes.sql

-- ============================================================================
-- Student money across the lifecycle — the shared building blocks.
--
-- Apply this BEFORE the procs that use it:
--     student_money_lifecycle.sql   (this file)
--     student_master_fields.sql     (sp_admission_manage)
--     transport_module.sql          (sp_transport_assign_manage)
--     student_exit.sql              (sp_student_exit)
--     student_promotion.sql         (sp_student_promote)
--     student_update.sql            (sp_student_update)
--     transfer_certificate.sql      (sp_tc_manage)
--     student_list.sql              (sp_student_list)
--
-- Re-runnable: columns are added IF NOT EXISTS and every routine is CREATE OR
-- REPLACE. Nothing here touches existing rows.
--
-- WHY
--   1. A charge is never hard-deleted. When a due stops applying (the student
--      left, the bus was removed, the route changed, the class changed) the
--      unpaid part is CLOSED: amount_due drops to what was settled, the amount
--      taken off is kept in closed_amount, with the reason, the source, who and
--      when. Every existing "outstanding = amount_due - amount_paid -
--      concession" formula then reads 0 for that row without being changed,
--      receipt lines keep pointing at a real row, and a Reactivate can put
--      back exactly what an Exit closed (close_source = 'Exit').
--   2. Admission, promotion and a class change bill a fee plan the SAME way.
--      The month arithmetic (charge-from policy, quarter snapping, session end)
--      lives in fn_plan_periods, and fn_student_bill_plan writes the plan and
--      its ledger rows. sp_admission_manage used to hold this inline, so
--      promotion could not reuse it and never billed the new session.
--   3. A plan is billed at most once per student per session
--      (student_fee_plan.academic_year), so re-running a promotion can never
--      create a second plan.
-- ============================================================================

-- ── Columns ─────────────────────────────────────────────────────────────────
ALTER TABLE core.student_ledger
    ADD COLUMN IF NOT EXISTS academic_year  varchar(20),
    ADD COLUMN IF NOT EXISTS fee_head_id    integer,
    ADD COLUMN IF NOT EXISTS closed_amount  numeric(12,2) NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS close_reason   varchar(200),
    ADD COLUMN IF NOT EXISTS close_source   varchar(30),
    ADD COLUMN IF NOT EXISTS closed_by      integer,
    ADD COLUMN IF NOT EXISTS closed_at      timestamptz;

-- Which session a frozen plan belongs to, and whether it is still the one in
-- force (a class change replaces it for the rest of the session).
ALTER TABLE core.student_fee_plan
    ADD COLUMN IF NOT EXISTS academic_year varchar(20),
    ADD COLUMN IF NOT EXISTS is_current    boolean NOT NULL DEFAULT TRUE;

-- Why and when a bus assignment ended. 'Exit' is what Reactivate looks for.
ALTER TABLE core.student_transport
    ADD COLUMN IF NOT EXISTS end_reason varchar(200),
    ADD COLUMN IF NOT EXISTS ended_by   integer,
    ADD COLUMN IF NOT EXISTS ended_at   timestamptz;


-- ── fn_fee_plan_problem ─────────────────────────────────────────────────────
-- NULL when the plan is acceptable, otherwise the message to show. The plan
-- reaches the database from the admission form, so a negative amount or the
-- same head twice must be refused here and not just in the browser.
CREATE OR REPLACE FUNCTION core.fn_fee_plan_problem(p_plan jsonb)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    v_item jsonb;
    v_name text;
    v_seen text[] := '{}';
BEGIN
    IF p_plan IS NULL OR jsonb_typeof(p_plan) <> 'array' THEN
        RETURN NULL;
    END IF;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_plan)
    LOOP
        v_name := COALESCE(NULLIF(TRIM(v_item->>'feeHeadName'), ''), 'Fee');

        IF COALESCE((v_item->>'amount')::numeric, 0) < 0 THEN
            RETURN format('The amount for %s cannot be negative.', v_name);
        END IF;

        IF LOWER(v_name) = ANY (v_seen) THEN
            RETURN format('%s appears twice in the fee plan.', v_name);
        END IF;
        v_seen := v_seen || LOWER(v_name);
    END LOOP;

    RETURN NULL;
END;
$$;


-- ── fn_plan_periods ─────────────────────────────────────────────────────────
-- The instalments one fee head produces in a session, starting from p_from.
--   * Monthly / Quarterly / Half Yearly: one row per cycle up to the session
--     end month. The first month is p_from's month, or the session start when
--     the session bills from SessionStart (unless p_force_from). Never before
--     the session starts; cycles longer than a month snap to the school's own
--     quarters / halves counted from the session start.
--     A cycle that started before p_from is due on p_from, not on the 1st.
--   * Anything else: one row dated p_from ('Admission' for One Time, else 'Annual').
-- Moved here unchanged from sp_admission_manage so promotion, class change and
-- the admission preview count months exactly the way admission bills them.
CREATE OR REPLACE FUNCTION core.fn_plan_periods(
    p_tenant_id     integer,
    p_school_id     integer,
    p_academic_year varchar,
    p_frequency     varchar,
    p_from          date,
    p_force_from    boolean DEFAULT FALSE)
RETURNS TABLE(due_date date, label varchar)
LANGUAGE plpgsql
AS $$
DECLARE
    v_sess_start  date;
    v_sess_end    date;
    v_charge_from varchar;
    v_step        integer;
    v_month_start date;
    v_month_end   date;
    v_sess_month  date;
    v_cycles      integer;
    v_m           date;
    v_period_end  date;
BEGIN
    SELECT y.start_date, y.end_date,
           COALESCE(NULLIF(TRIM(y.charge_fees_from), ''), 'AdmissionMonth')
      INTO v_sess_start, v_sess_end, v_charge_from
      FROM academic.academic_years y
     WHERE y.tenant_id = p_tenant_id AND y.school_id = p_school_id
       AND y.academic_year_name = COALESCE(p_academic_year, '')
       AND COALESCE(y.is_deleted, FALSE) = FALSE
     LIMIT 1;
    v_charge_from := COALESCE(v_charge_from, 'AdmissionMonth');

    v_step := CASE lower(trim(COALESCE(p_frequency, '')))
                  WHEN 'monthly'     THEN 1
                  WHEN 'quarterly'   THEN 3
                  WHEN 'half yearly' THEN 6
                  ELSE 0
              END;

    IF v_step = 0 THEN
        due_date := p_from;
        label    := CASE WHEN p_frequency = 'One Time' THEN 'Admission' ELSE 'Annual' END;
        RETURN NEXT;
        RETURN;
    END IF;

    IF v_charge_from = 'SessionStart' AND v_sess_start IS NOT NULL AND NOT p_force_from THEN
        v_month_start := DATE_TRUNC('month', v_sess_start)::date;
    ELSE
        v_month_start := DATE_TRUNC('month', p_from)::date;
    END IF;

    IF v_sess_start IS NOT NULL AND v_month_start < DATE_TRUNC('month', v_sess_start)::date THEN
        v_month_start := DATE_TRUNC('month', v_sess_start)::date;
    END IF;

    IF v_step > 1 AND v_sess_start IS NOT NULL THEN
        v_sess_month := DATE_TRUNC('month', v_sess_start)::date;
        v_cycles := FLOOR(
            ( (EXTRACT(YEAR FROM v_month_start) * 12 + EXTRACT(MONTH FROM v_month_start))
            - (EXTRACT(YEAR FROM v_sess_month)  * 12 + EXTRACT(MONTH FROM v_sess_month)) ) / v_step );
        v_month_start := (v_sess_month + make_interval(months => v_cycles * v_step))::date;
    END IF;

    IF v_sess_end IS NOT NULL THEN
        v_month_end := DATE_TRUNC('month', v_sess_end)::date;
    ELSE
        v_month_end := (v_month_start + INTERVAL '11 months')::date;
    END IF;

    v_m := v_month_start;
    WHILE v_m <= v_month_end LOOP
        v_period_end := LEAST((v_m + make_interval(months => v_step - 1))::date, v_month_end);
        -- A cycle that began before the joining day falls due ON the joining day,
        -- so a student admitted on 14 Oct is not overdue for October on day one
        -- (QA BUG-100).
        due_date := GREATEST(v_m, p_from);
        label    := CASE WHEN v_step = 1 OR v_period_end = v_m
                         THEN TO_CHAR(v_m, 'Mon YYYY')
                         ELSE TO_CHAR(v_m, 'Mon YYYY') || ' - ' || TO_CHAR(v_period_end, 'Mon YYYY')
                    END;
        RETURN NEXT;
        v_m := (v_m + make_interval(months => v_step))::date;
    END LOOP;
END;
$$;


-- ── fn_student_bill_plan ────────────────────────────────────────────────────
-- Freezes a fee plan for one student and one session and writes its ledger
-- rows. Returns the number of ledger rows written, or 0 when that session
-- already has a plan in force for the student (re-running promotion, a
-- double submit) — billing is never done twice. p_not_before skips any
-- instalment due before that date (a class change bills only what is left).
DROP FUNCTION IF EXISTS core.fn_student_bill_plan(integer, integer, integer, integer, varchar, date, jsonb, boolean);

CREATE OR REPLACE FUNCTION core.fn_student_bill_plan(
    p_tenant_id      integer,
    p_school_id      integer,
    p_action_user_id integer,
    p_student_id     integer,
    p_academic_year  varchar,
    p_from           date,
    p_plan           jsonb,
    p_force_from     boolean DEFAULT FALSE,
    p_not_before     date    DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    v_item    jsonb;
    v_problem text;
    v_name    varchar;
    v_freq    varchar;
    v_amount  numeric(12,2);
    v_head_id integer;
    v_made    integer := 0;
    p         record;
BEGIN
    IF p_plan IS NULL OR jsonb_typeof(p_plan) <> 'array' OR jsonb_array_length(p_plan) = 0 THEN
        RETURN 0;
    END IF;

    v_problem := core.fn_fee_plan_problem(p_plan);
    IF v_problem IS NOT NULL THEN
        RAISE EXCEPTION '%', v_problem;
    END IF;

    IF EXISTS (SELECT 1 FROM core.student_fee_plan
                WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
                  AND academic_year = p_academic_year AND is_current) THEN
        RETURN 0;
    END IF;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_plan)
    LOOP
        v_name   := COALESCE(NULLIF(TRIM(v_item->>'feeHeadName'), ''), 'Fee');
        v_freq   := COALESCE(NULLIF(TRIM(v_item->>'frequency'), ''), 'Yearly');
        v_amount := COALESCE((v_item->>'amount')::numeric, 0);

        v_head_id := NULLIF(NULLIF(v_item->>'feeHeadId', ''), '0')::integer;
        IF v_head_id IS NULL THEN
            SELECT h.fee_head_id INTO v_head_id
              FROM core.school_fee_heads h
             WHERE h.tenant_id = p_tenant_id AND h.school_id = p_school_id
               AND TRIM(h.fee_head_name) = v_name
               AND COALESCE(h.is_deleted, FALSE) = FALSE
             ORDER BY h.fee_head_id
             LIMIT 1;
        END IF;

        INSERT INTO core.student_fee_plan (
            tenant_id, school_id, student_id,
            fee_head_id, fee_head_name, frequency, amount, is_optional,
            academic_year, is_current
        ) VALUES (
            p_tenant_id, p_school_id, p_student_id,
            v_head_id, v_name, v_freq, v_amount,
            COALESCE((v_item->>'isOptional')::boolean, FALSE),
            p_academic_year, TRUE
        );

        FOR p IN SELECT * FROM core.fn_plan_periods(p_tenant_id, p_school_id, p_academic_year,
                                                    v_freq, p_from, p_force_from) f
                  WHERE p_not_before IS NULL OR f.due_date >= p_not_before
        LOOP
            INSERT INTO core.student_ledger (
                tenant_id, school_id, student_id,
                fee_head_name, fee_head_id, frequency, installment_label,
                due_date, amount_due, status, academic_year
            ) VALUES (
                p_tenant_id, p_school_id, p_student_id,
                v_name, v_head_id, v_freq, p.label,
                p.due_date, v_amount, 'Pending', p_academic_year
            );
            v_made := v_made + 1;
        END LOOP;
    END LOOP;

    RETURN v_made;
END;
$$;


-- ── fn_class_fee_plan ───────────────────────────────────────────────────────
-- The recurring part of a class's fee structure for a session, as a plan.
-- Used when a student moves into a class without being admitted again
-- (promotion, a class change), so Admission- and Registration-point heads —
-- the admission fee, the security deposit — are NOT charged a second time.
-- NULL when the class has no structure for that session.
CREATE OR REPLACE FUNCTION core.fn_class_fee_plan(
    p_tenant_id     integer,
    p_school_id     integer,
    p_class_name    varchar,
    p_academic_year varchar)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT jsonb_agg(jsonb_build_object(
               'feeHeadId',   h.fee_head_id,
               'feeHeadName', TRIM(h.fee_head_name),
               'frequency',   COALESCE(NULLIF(TRIM(d.frequency), ''), h.frequency, 'Yearly'),
               'amount',      COALESCE(d.amount, 0))
           ORDER BY h.fee_head_name)
      FROM core.school_fee_structures fs
      JOIN core.school_fee_structure_details d
        ON d.fee_structure_id = fs.fee_structure_id
       AND COALESCE(d.is_deleted, FALSE) = FALSE
       AND COALESCE(d.is_selected, TRUE)
      JOIN core.school_fee_heads h
        ON h.fee_head_id = d.fee_head_id
       AND h.tenant_id = fs.tenant_id AND h.school_id = fs.school_id
       AND COALESCE(h.is_deleted, FALSE) = FALSE
       AND COALESCE(h.is_active, TRUE)
     WHERE fs.tenant_id = p_tenant_id AND fs.school_id = p_school_id
       AND fs.class_name = p_class_name AND fs.academic_year = p_academic_year
       AND COALESCE(fs.is_deleted, FALSE) = FALSE
       AND COALESCE(NULLIF(TRIM(h.collection_point), ''), 'Recurring') NOT IN ('Admission', 'Registration');
$$;


-- ── fn_ledger_close / fn_ledger_reopen ──────────────────────────────────────
-- Close the UNPAID part of one ledger row (see WHY 1). Returns the amount
-- taken off, 0 when nothing was owed on it.
CREATE OR REPLACE FUNCTION core.fn_ledger_close(
    p_ledger_id      integer,
    p_reason         varchar,
    p_source         varchar,
    p_action_user_id integer)
RETURNS numeric
LANGUAGE plpgsql
AS $$
DECLARE
    v_open numeric(12,2);
BEGIN
    SELECT amount_due - amount_paid - concession INTO v_open
      FROM core.student_ledger WHERE ledger_id = p_ledger_id
       FOR UPDATE;

    IF COALESCE(v_open, 0) <= 0 THEN
        RETURN 0;
    END IF;

    UPDATE core.student_ledger
       SET closed_amount = closed_amount + v_open,
           amount_due    = amount_paid + concession,
           status        = 'Closed',
           close_reason  = p_reason,
           close_source  = p_source,
           closed_by     = p_action_user_id,
           closed_at     = now(),
           updated_at    = now()
     WHERE ledger_id = p_ledger_id;

    RETURN v_open;
END;
$$;

-- Put a closed row back exactly as it was. Returns the amount restored.
CREATE OR REPLACE FUNCTION core.fn_ledger_reopen(p_ledger_id integer)
RETURNS numeric
LANGUAGE plpgsql
AS $$
DECLARE
    v_closed numeric(12,2);
BEGIN
    SELECT closed_amount INTO v_closed
      FROM core.student_ledger WHERE ledger_id = p_ledger_id
       FOR UPDATE;

    IF COALESCE(v_closed, 0) <= 0 THEN
        RETURN 0;
    END IF;

    UPDATE core.student_ledger
       SET amount_due    = amount_due + closed_amount,
           closed_amount = 0,
           status        = CASE WHEN amount_paid + concession <= 0 THEN 'Pending'
                                WHEN amount_paid + concession >= amount_due + closed_amount THEN 'Paid'
                                ELSE 'Partial' END,
           close_reason  = NULL,
           close_source  = NULL,
           closed_by     = NULL,
           closed_at     = NULL,
           updated_at    = now()
     WHERE ledger_id = p_ledger_id;

    RETURN v_closed;
END;
$$;


-- ── fn_student_close_future_dues ────────────────────────────────────────────
-- Close every instalment due AFTER p_after that still has something owing.
-- Dues up to and including p_after stay owed. Returns the total closed.
CREATE OR REPLACE FUNCTION core.fn_student_close_future_dues(
    p_tenant_id      integer,
    p_school_id      integer,
    p_student_id     integer,
    p_after          date,
    p_reason         varchar,
    p_source         varchar,
    p_action_user_id integer)
RETURNS numeric
LANGUAGE plpgsql
AS $$
DECLARE
    r       record;
    v_total numeric(12,2) := 0;
BEGIN
    FOR r IN
        SELECT ledger_id FROM core.student_ledger
         WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
           AND due_date IS NOT NULL AND due_date::date > p_after
           AND amount_due - amount_paid - concession > 0
         ORDER BY due_date, ledger_id
    LOOP
        v_total := v_total + core.fn_ledger_close(r.ledger_id, p_reason, p_source, p_action_user_id);
    END LOOP;
    RETURN v_total;
END;
$$;

-- Reopen every row of this student closed by p_source. Returns the total.
CREATE OR REPLACE FUNCTION core.fn_student_restore_closed_dues(
    p_tenant_id  integer,
    p_school_id  integer,
    p_student_id integer,
    p_source     varchar)
RETURNS numeric
LANGUAGE plpgsql
AS $$
DECLARE
    r       record;
    v_total numeric(12,2) := 0;
BEGIN
    FOR r IN
        SELECT ledger_id FROM core.student_ledger
         WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
           AND close_source = p_source AND closed_amount > 0
    LOOP
        v_total := v_total + core.fn_ledger_reopen(r.ledger_id);
    END LOOP;
    RETURN v_total;
END;
$$;


-- ── sp_plan_instalments ─────────────────────────────────────────────────────
-- How many instalments each billing cycle produces for someone joining a
-- session today. The admission form uses it for the annual estimate and an
-- "Estimated annual" concession, which used to assume 12 months even for a
-- student billed for six. due_now = how many of them are already due on the
-- joining day (the first one always is), so "Collect at admission" can include
-- them instead of the parent finding them due a minute later.
CREATE OR REPLACE PROCEDURE core.sp_plan_instalments(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_academic_year  varchar,
    IN    p_from           date DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'plan_instalments_cursor')
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    OPEN p_result FOR
    SELECT f.frequency,
           (SELECT COUNT(*) FROM core.fn_plan_periods(p_tenant_id, p_school_id, p_academic_year,
                                                      f.frequency, COALESCE(p_from, CURRENT_DATE)))::integer AS instalments,
           (SELECT COUNT(*) FROM core.fn_plan_periods(p_tenant_id, p_school_id, p_academic_year,
                                                      f.frequency, COALESCE(p_from, CURRENT_DATE)) pp
             WHERE pp.due_date <= COALESCE(p_from, CURRENT_DATE))::integer AS due_now
      FROM (VALUES ('Monthly'), ('Quarterly'), ('Half Yearly'), ('Yearly'), ('One Time')) AS f(frequency);
END;
$$;


-- ── sp_student_fee_totals ───────────────────────────────────────────────────
-- Whole-ledger totals for one student, for the Student Dashboard. It used to
-- add up sp_student_dues_get, which returns only rows still owing, so a fully
-- paid charge vanished from "Total Paid".
CREATE OR REPLACE PROCEDURE core.sp_student_fee_totals(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_student_id     integer,
    INOUT p_result         refcursor DEFAULT 'student_fee_totals_cursor')
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    OPEN p_result FOR
    SELECT COALESCE(SUM(amount_due), 0)                               AS total_due,
           COALESCE(SUM(amount_paid), 0)                              AS total_paid,
           COALESCE(SUM(concession), 0)                               AS total_concession,
           COALESCE(SUM(refund_amount), 0)                            AS total_refunded,
           COALESCE(SUM(closed_amount), 0)                            AS total_closed,
           COALESCE(SUM(amount_due - amount_paid - concession), 0)    AS outstanding,
           COALESCE((SELECT balance FROM core.student_advance a
                      WHERE a.student_id = p_student_id
                        AND a.tenant_id = p_tenant_id AND a.school_id = p_school_id), 0) AS advance_balance
      FROM core.student_ledger
     WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id;
END;
$$;


-- ── sp_student_history_get ──────────────────────────────────────────────────
-- One timeline of everything that changed a student's place or money outside
-- a receipt: admission, concessions, exit / reactivate, promotion (with the
-- dues carried), class changes, bus assignments, closed dues and refunds.
-- admission_audit and student_promotion_history were written but never read,
-- so none of this was visible anywhere.
CREATE OR REPLACE PROCEDURE core.sp_student_history_get(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_student_id     integer,
    INOUT p_result         refcursor DEFAULT 'student_history_cursor')
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    OPEN p_result FOR
    SELECT h.happened_at, h.action, h.detail, h.amount, u.email AS done_by
      FROM (
        SELECT a.created_at AS happened_at, a.action, a.detail, NULL::numeric AS amount, a.action_by AS by_id
          FROM core.admission_audit a
         WHERE a.student_id = p_student_id AND a.tenant_id = p_tenant_id AND a.school_id = p_school_id
        UNION ALL
        SELECT ph.promoted_at, 'Promotion: ' || ph.outcome,
               ph.from_year || ' ' || COALESCE(ph.from_class, '') || COALESCE('-' || ph.from_section, '') ||
               ' -> ' || ph.to_year || ' ' || COALESCE(ph.to_class, '') || COALESCE('-' || ph.to_section, '') ||
               '; dues carried ' || COALESCE(ph.dues_carried, 0)::text,
               ph.dues_carried, ph.promoted_by
          FROM core.student_promotion_history ph
         WHERE ph.student_id = p_student_id AND ph.tenant_id = p_tenant_id AND ph.school_id = p_school_id
        UNION ALL
        SELECT l.closed_at, 'Due closed',
               l.fee_head_name || ' ' || COALESCE(l.installment_label, '') || ' — ' || COALESCE(l.close_reason, ''),
               l.closed_amount, l.closed_by
          FROM core.student_ledger l
         WHERE l.student_id = p_student_id AND l.tenant_id = p_tenant_id AND l.school_id = p_school_id
           AND l.closed_amount > 0
        UNION ALL
        SELECT t.created_at, 'Transport assigned',
               COALESCE(r.route_name, '') || ' / ' || COALESCE(s.stop_name, '') ||
               ' at ' || t.monthly_fare::text || ' a month from ' || t.start_date,
               t.monthly_fare, t.created_by
          FROM core.student_transport t
          LEFT JOIN core.transport_routes r ON r.route_id = t.route_id
          LEFT JOIN core.transport_stops  s ON s.stop_id  = t.stop_id
         WHERE t.student_id = p_student_id AND t.tenant_id = p_tenant_id AND t.school_id = p_school_id
        UNION ALL
        SELECT COALESCE(t.ended_at, t.updated_at), 'Transport ended',
               COALESCE(r.route_name, '') || ' — ' || COALESCE(t.end_reason, 'replaced'),
               NULL, COALESCE(t.ended_by, t.updated_by)
          FROM core.student_transport t
          LEFT JOIN core.transport_routes r ON r.route_id = t.route_id
         WHERE t.student_id = p_student_id AND t.tenant_id = p_tenant_id AND t.school_id = p_school_id
           AND t.is_active = FALSE
        UNION ALL
        SELECT f.refunded_at, 'Refund ' || COALESCE(f.refund_no, ''),
               COALESCE(f.refund_mode, '') || ' — ' || COALESCE(f.reason, ''),
               f.amount, f.refunded_by
          FROM core.fee_refunds f
         WHERE f.student_id = p_student_id AND f.tenant_id = p_tenant_id AND f.school_id = p_school_id
      ) h
      LEFT JOIN core.users u ON u.user_id = h.by_id
     ORDER BY h.happened_at DESC NULLS LAST;
END;
$$;


-- ============================================================================
-- Student exit flow — the foundation the Transfer Certificate sits on.
--
-- A student who leaves is NOT deleted: the record stays, is_active goes FALSE
-- and status records how they left. Fee ledger, receipts and (later) the TC
-- register all keep pointing at the same student_id.
--
--   core.sp_student_exit        mark a student as left (or undo it)
--   core.sp_student_exit_list   the real "Inactive / Left" list
--
-- status values used here:
--   Active     still studying
--   Transfer   left for another school   -> eligible for a TC
--   Passout    completed the final class -> eligible for a TC
--   Struck Off removed by the school (long absence, discipline)
--   Withdrawn  parents withdrew, no TC sought
-- ============================================================================

-- ── columns ────────────────────────────────────────────────────────────────
ALTER TABLE core.students
    ADD COLUMN IF NOT EXISTS date_of_leaving  date,
    ADD COLUMN IF NOT EXISTS leaving_reason   varchar(300),
    ADD COLUMN IF NOT EXISTS exit_recorded_by integer,
    ADD COLUMN IF NOT EXISTS exit_recorded_at timestamptz;

COMMENT ON COLUMN core.students.date_of_leaving IS
    'Last day at this school. Printed on the TC, so it is set once at exit.';


-- ── money when a student leaves / comes back ───────────────────────────────
-- Depends on student_money_lifecycle.sql (fn_student_close_future_dues,
-- fn_student_restore_closed_dues and the close columns).
--
-- Leaving: every instalment due AFTER the leaving date is CLOSED (never
-- deleted) with the reason 'Left on <date>', who and when, and the bus
-- assignment ends. Dues up to the leaving date stay owed. Before this, tuition
-- and bus fees for every month to March stayed on a leaver's ledger, and the TC
-- was refused for months the child never attended.
--
-- Coming back (Reactivate): exactly what the exit closed is put back — the rows
-- closed with close_source 'Exit' and the bus assignment ended by it.
CREATE OR REPLACE FUNCTION core.fn_student_leave_money(
    p_tenant_id      integer,
    p_school_id      integer,
    p_student_id     integer,
    p_date_of_leaving date,
    p_action_user_id integer)
RETURNS numeric
LANGUAGE plpgsql
AS $$
DECLARE
    v_reason varchar(200) := 'Left on ' || to_char(p_date_of_leaving, 'YYYY-MM-DD');
    v_closed numeric(12,2);
BEGIN
    v_closed := core.fn_student_close_future_dues(
        p_tenant_id, p_school_id, p_student_id, p_date_of_leaving,
        v_reason, 'Exit', p_action_user_id);

    -- A refundable deposit (caution money) still unpaid is not owed by someone who
    -- is leaving: it would only be collected to be handed back. Close it as well.
    SELECT v_closed + COALESCE(SUM(core.fn_ledger_close(l.ledger_id, v_reason, 'Exit', p_action_user_id)), 0)
      INTO v_closed
      FROM core.student_ledger l
      JOIN core.school_fee_heads h ON h.fee_head_id = l.fee_head_id AND COALESCE(h.is_refundable, FALSE)
     WHERE l.student_id = p_student_id AND l.tenant_id = p_tenant_id AND l.school_id = p_school_id
       AND l.amount_due - l.amount_paid - l.concession > 0;

    UPDATE core.student_transport
       SET is_active  = FALSE,
           end_reason = v_reason,
           ended_by   = p_action_user_id,
           ended_at   = now(),
           updated_by = p_action_user_id,
           updated_at = now()
     WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
       AND is_active = TRUE;

    RETURN v_closed;
END;
$$;

CREATE OR REPLACE FUNCTION core.fn_student_return_money(
    p_tenant_id      integer,
    p_school_id      integer,
    p_student_id     integer,
    p_action_user_id integer)
RETURNS numeric
LANGUAGE plpgsql
AS $$
DECLARE
    v_restored numeric(12,2);
    v_assign   integer;
BEGIN
    -- Put back only the fees from this month on: the months the child was away
    -- are not billed again (re-admitted in January after leaving in July).
    SELECT COALESCE(SUM(core.fn_ledger_reopen(l.ledger_id)), 0) INTO v_restored
      FROM core.student_ledger l
     WHERE l.student_id = p_student_id AND l.tenant_id = p_tenant_id AND l.school_id = p_school_id
       AND l.close_source = 'Exit' AND l.closed_amount > 0
       AND (l.due_date IS NULL OR l.due_date::date >= date_trunc('month', CURRENT_DATE)::date);

    -- The bus assignment the exit ended (the latest one), if it was not
    -- replaced by another since.
    SELECT assignment_id INTO v_assign
      FROM core.student_transport
     WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
       AND is_active = FALSE AND COALESCE(is_deleted, FALSE) = FALSE
       AND end_reason LIKE 'Left on %'
     ORDER BY assignment_id DESC
     LIMIT 1;

    IF v_assign IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM core.student_transport
         WHERE student_id = p_student_id AND is_active = TRUE) THEN
        UPDATE core.student_transport
           SET is_active  = TRUE,
               end_reason = NULL, ended_by = NULL, ended_at = NULL,
               updated_by = p_action_user_id, updated_at = now()
         WHERE assignment_id = v_assign;
    END IF;

    RETURN v_restored;
END;
$$;


-- ── mark / unmark a student as left ────────────────────────────────────────
CREATE OR REPLACE PROCEDURE core.sp_student_exit(
    IN  p_operation      varchar,    -- 'Exit' | 'Undo'
    IN  p_tenant_id      integer,
    IN  p_school_id      integer,
    IN  p_action_user_id integer,
    IN  p_student_id     integer,
    IN  p_status         varchar DEFAULT NULL,  -- Transfer | Passout | Struck Off | Withdrawn
    IN  p_date_of_leaving date   DEFAULT NULL,
    IN  p_reason         varchar DEFAULT NULL,
    INOUT p_result       refcursor DEFAULT 'student_exit_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_name   varchar;
    v_active boolean;
    v_year   varchar;   -- session the student is sitting in (for the enrolment row)
    v_dues   numeric(12,2);
    v_closed numeric(12,2);
    v_prepaid numeric(12,2);   -- already paid for months after the leaving date
    v_current varchar;         -- the school's current session
    v_roll   varchar;
    s        core.students%ROWTYPE;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    SELECT * INTO s
    FROM core.students
    WHERE student_id = p_student_id
      AND tenant_id  = p_tenant_id
      AND school_id  = p_school_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Student not found.';
    END IF;
    v_name := s.student_name; v_active := s.is_active; v_year := s.academic_year;

    IF p_operation = 'Exit' THEN
        IF NOT v_active THEN
            RAISE EXCEPTION '% has already left.', v_name;
        END IF;

        IF COALESCE(TRIM(p_status), '') NOT IN ('Transfer', 'Passout', 'Struck Off', 'Withdrawn') THEN
            RAISE EXCEPTION 'Choose how the student left.';
        END IF;

        IF p_date_of_leaving IS NULL THEN
            RAISE EXCEPTION 'Date of leaving is required.';
        END IF;
        -- A future date made the child disappear from homework, exams and ID cards
        -- while still coming to school. Mark them as left on the day they leave.
        IF p_date_of_leaving > CURRENT_DATE THEN
            RAISE EXCEPTION 'The date of leaving cannot be in the future. Mark % as left on the day they leave.', v_name;
        END IF;
        IF s.admission_date IS NOT NULL AND p_date_of_leaving < s.admission_date::date THEN
            RAISE EXCEPTION 'The date of leaving cannot be before the admission date (%).', to_char(s.admission_date::date, 'DD Mon YYYY');
        END IF;

        -- Fees already paid for months after leaving: not closed (they were paid),
        -- so the office is told how much, to refund it or keep it as the school decides.
        SELECT COALESCE(SUM(l.amount_paid), 0) INTO v_prepaid
          FROM core.student_ledger l
         WHERE l.student_id = p_student_id AND l.tenant_id = p_tenant_id AND l.school_id = p_school_id
           AND l.due_date IS NOT NULL AND l.due_date::date > p_date_of_leaving AND l.amount_paid > 0;

        -- Instalments after the leaving date are closed and the bus ends.
        v_closed := core.fn_student_leave_money(
            p_tenant_id, p_school_id, p_student_id, p_date_of_leaving, p_action_user_id);

        -- What is still owed (up to the leaving date) does NOT block the exit:
        -- the student has physically left either way. It is reported so the
        -- office can chase it, and the TC step checks it again.
        SELECT COALESCE(SUM(l.amount_due - l.amount_paid - COALESCE(l.concession, 0)), 0)
        INTO v_dues
        FROM core.student_ledger l
        WHERE l.student_id = p_student_id;

        UPDATE core.students
        SET status           = TRIM(p_status),
            is_active        = FALSE,
            date_of_leaving  = p_date_of_leaving,
            leaving_reason   = NULLIF(TRIM(p_reason), ''),
            exit_recorded_by = p_action_user_id,
            exit_recorded_at = now(),
            updated_by       = p_action_user_id,
            updated_at       = now()
        WHERE student_id = p_student_id;

        -- Close the session they were in. is_current stays TRUE: this is still
        -- their latest enrolment, it just ended early.
        PERFORM core.fn_student_enrolment_close(
            p_student_id, v_year,
            CASE WHEN TRIM(p_status) = 'Passout' THEN 'PassedOut' ELSE 'Left' END,
            p_action_user_id);

        INSERT INTO core.admission_audit (tenant_id, school_id, student_id, action, detail, action_by)
        VALUES (p_tenant_id, p_school_id, p_student_id, 'StudentExited',
                TRIM(p_status) || ' on ' || to_char(p_date_of_leaving, 'YYYY-MM-DD') ||
                COALESCE(' (' || NULLIF(TRIM(p_reason), '') || ')', '') ||
                '; ' || to_char(v_closed, 'FM99999990.00') || ' of later dues closed' ||
                '; ' || to_char(GREATEST(v_dues, 0), 'FM99999990.00') || ' still owed',
                p_action_user_id);

        OPEN p_result FOR
        SELECT TRUE AS success,
               v_name || ' marked as ' || TRIM(p_status) || '.' ||
               CASE WHEN v_closed > 0
                    THEN ' Rs ' || to_char(v_closed, 'FM99,99,99,990.00') || ' of fees due after the leaving date closed.'
                    ELSE '' END ||
               CASE WHEN v_prepaid > 0
                    THEN ' Rs ' || to_char(v_prepaid, 'FM99,99,99,990.00') || ' was already paid for months after leaving.'
                    ELSE '' END AS message,
               GREATEST(v_dues, 0) AS outstanding,
               v_closed AS closed_amount;

    ELSIF p_operation = 'Undo' THEN
        IF v_active THEN
            RAISE EXCEPTION '% is already an active student.', v_name;
        END IF;

        -- A live TC says the child has left. Void it first, so the register
        -- and the roll never disagree.
        IF EXISTS (SELECT 1 FROM core.tc_register
                    WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                      AND student_id = p_student_id AND is_void = FALSE) THEN
            RAISE EXCEPTION 'A Transfer Certificate has been issued for %. Void it before re-activating.', v_name;
        END IF;

        -- Re-admitting puts the child back in the session they left. Once that
        -- session is over they would land in last year's class with no fees for
        -- this year, so that is a new admission instead.
        SELECT y.academic_year_name INTO v_current
          FROM academic.academic_years y
         WHERE y.tenant_id = p_tenant_id AND y.school_id = p_school_id
           AND COALESCE(y.is_current, FALSE) AND NOT COALESCE(y.is_deleted, FALSE)
         LIMIT 1;
        IF v_current IS NOT NULL AND v_year IS DISTINCT FROM v_current THEN
            RAISE EXCEPTION '% left in %, which is not the current session (%). Admit them again for % instead.',
                v_name, COALESCE(v_year, 'an earlier session'), v_current, v_current;
        END IF;

        -- Their roll number may have been given to someone else meanwhile.
        v_roll := NULLIF(TRIM(COALESCE(s.roll_no, '')), '');
        IF v_roll IS NULL OR EXISTS (
               SELECT 1 FROM core.students o
                WHERE o.tenant_id = p_tenant_id AND o.school_id = p_school_id AND o.is_active
                  AND o.student_id <> p_student_id AND o.academic_year = v_year
                  AND o.class_name = s.class_name AND COALESCE(o.section, '') = COALESCE(s.section, '')
                  AND lower(TRIM(o.roll_no)) = lower(v_roll)) THEN
            SELECT (COALESCE(MAX(TRIM(o.roll_no)::int), 0) + 1)::text INTO v_roll
              FROM core.students o
             WHERE o.tenant_id = p_tenant_id AND o.school_id = p_school_id AND o.is_active
               AND o.student_id <> p_student_id AND o.academic_year = v_year
               AND o.class_name = s.class_name AND COALESCE(o.section, '') = COALESCE(s.section, '')
               AND TRIM(o.roll_no) ~ '^[0-9]{1,6}$';
        END IF;

        v_closed := core.fn_student_return_money(p_tenant_id, p_school_id, p_student_id, p_action_user_id);

        -- The exit details are cleared on the student row (they describe a
        -- leaving that no longer stands) but kept here, with the restore.
        INSERT INTO core.admission_audit (tenant_id, school_id, student_id, action, detail, action_by)
        VALUES (p_tenant_id, p_school_id, p_student_id, 'StudentReactivated',
                'Was ' || COALESCE(s.status, '?') || ' on ' || COALESCE(s.date_of_leaving::text, '?') ||
                COALESCE(' (' || s.leaving_reason || ')', '') ||
                ', recorded by user ' || COALESCE(s.exit_recorded_by::text, '?') ||
                ' at ' || COALESCE(LEFT(s.exit_recorded_at::text, 16), '?') ||
                '; ' || to_char(v_closed, 'FM99999990.00') || ' of dues restored',
                p_action_user_id);

        UPDATE core.students
        SET status           = 'Active',
            is_active        = TRUE,
            roll_no          = v_roll,
            date_of_leaving  = NULL,
            leaving_reason   = NULL,
            exit_recorded_by = NULL,
            exit_recorded_at = NULL,
            updated_by       = p_action_user_id,
            updated_at       = now()
        WHERE student_id = p_student_id;

        -- Put them back on the roll for the session they were in.
        PERFORM core.fn_student_enrolment_close(
            p_student_id, v_year, 'Active', p_action_user_id);

        OPEN p_result FOR
        SELECT TRUE AS success,
               v_name || ' re-activated.' ||
               CASE WHEN v_closed > 0
                    THEN ' Rs ' || to_char(v_closed, 'FM99,99,99,990.00') || ' of dues closed at exit restored.'
                    ELSE '' END AS message,
               0::numeric AS outstanding,
               v_closed AS closed_amount;
    ELSE
        RAISE EXCEPTION 'Unknown operation %.', p_operation;
    END IF;
END;
$procedure$;


-- ── the "Inactive / Left" list ─────────────────────────────────────────────
-- Same shape as sp_student_list: search + filters + whitelisted sort +
-- pagination, with window aggregates so the tiles stay right across pages.
CREATE OR REPLACE PROCEDURE core.sp_student_exit_list(
    IN  p_tenant_id      integer,
    IN  p_school_id      integer,
    IN  p_action_user_id integer,
    IN  p_search         text    DEFAULT NULL,
    IN  p_filter_status  text    DEFAULT NULL,   -- Transfer | Passout | Struck Off | Withdrawn
    IN  p_filter_dues    text    DEFAULT NULL,   -- 'pending' | 'clear'
    IN  p_page_no        integer DEFAULT 1,
    IN  p_page_size      integer DEFAULT 10,
    IN  p_sort_column    text    DEFAULT NULL,
    IN  p_sort_dir       text    DEFAULT 'desc',
    INOUT p_result       refcursor DEFAULT 'student_exit_list_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_offset integer;
    v_col    text;
    v_asc    boolean;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        OPEN p_result FOR SELECT WHERE FALSE;
        RETURN;
    END IF;

    v_offset := (GREATEST(COALESCE(p_page_no, 1), 1) - 1) * COALESCE(p_page_size, 10);
    v_col    := LOWER(TRIM(COALESCE(p_sort_column, '')));
    v_asc    := LOWER(TRIM(COALESCE(p_sort_dir, 'desc'))) <> 'desc';

    OPEN p_result FOR
        WITH filtered AS (
            SELECT
                s.student_id, s.admission_no, s.student_name,
                s.class_name, s.section, s.academic_year,
                s.guardian_name, s.mobile,
                s.admission_date, s.date_of_leaving,
                s.status, s.leaving_reason,
                -- The uuid opens the (read-only) Student Dashboard of a leaver;
                -- has_tc stops the page offering a second TC.
                s.public_id,
                EXISTS (SELECT 1 FROM core.tc_register t
                         WHERE t.student_id = s.student_id AND t.tenant_id = s.tenant_id
                           AND t.school_id = s.school_id AND NOT t.is_void) AS has_tc,
                COALESCE((
                    SELECT SUM(l.amount_due - l.amount_paid - COALESCE(l.concession, 0))
                    FROM core.student_ledger l
                    WHERE l.student_id = s.student_id
                ), 0) AS outstanding
            FROM core.students s
            WHERE s.tenant_id = p_tenant_id
              AND s.school_id = p_school_id
              AND s.is_active = FALSE
              -- strpos, not LIKE: a typed % or _ is a character, not a wildcard.
              AND (
                  p_search IS NULL OR TRIM(p_search) = ''
                  OR strpos(LOWER(s.student_name), LOWER(TRIM(p_search))) > 0
                  OR strpos(LOWER(s.admission_no), LOWER(TRIM(p_search))) > 0
                  OR strpos(COALESCE(s.mobile, ''), TRIM(p_search)) > 0
              )
              AND (p_filter_status IS NULL OR TRIM(p_filter_status) = ''
                   OR LOWER(s.status) = LOWER(TRIM(p_filter_status)))
        ),
        scored AS (
            SELECT * FROM filtered f
            WHERE p_filter_dues IS NULL OR TRIM(p_filter_dues) = ''
               OR (LOWER(TRIM(p_filter_dues)) = 'pending' AND f.outstanding > 0)
               OR (LOWER(TRIM(p_filter_dues)) = 'clear'   AND f.outstanding <= 0)
        )
        SELECT
            student_id, admission_no, student_name, class_name, section,
            academic_year, guardian_name, mobile, admission_date,
            date_of_leaving, status, leaving_reason, public_id, has_tc,
            GREATEST(outstanding, 0) AS outstanding,
            COUNT(*)                                                        OVER() AS total_count,
            COUNT(*) FILTER (WHERE status = 'Transfer')                     OVER() AS transfer_count,
            COUNT(*) FILTER (WHERE status = 'Passout')                      OVER() AS passout_count,
            COUNT(*) FILTER (WHERE outstanding > 0)                         OVER() AS dues_count
        FROM scored
        ORDER BY
            CASE WHEN v_col = 'name'  AND v_asc     THEN student_name    END ASC,
            CASE WHEN v_col = 'name'  AND NOT v_asc THEN student_name    END DESC,
            CASE WHEN v_col = 'left'  AND v_asc     THEN date_of_leaving END ASC,
            CASE WHEN v_col = 'left'  AND NOT v_asc THEN date_of_leaving END DESC,
            CASE WHEN v_col = 'dues'  AND v_asc     THEN outstanding     END ASC,
            CASE WHEN v_col = 'dues'  AND NOT v_asc THEN outstanding     END DESC,
            -- Default: most recently left first.
            date_of_leaving DESC NULLS LAST, student_id DESC
        LIMIT  COALESCE(p_page_size, 10)
        OFFSET v_offset;
    RETURN;
END;
$procedure$;


-- ============================================================================
-- Transfer Certificate (TC) — issue, register and reprint.
--
-- A TC is a LEGAL document. Once issued it must reprint identically forever, so
-- its content is FROZEN into core.tc_register at issue time — never recomputed
-- from the (mutable) student row afterwards. A reprint is stamped DUPLICATE.
--
-- Sits on top of the student-exit flow (student_exit.sql): a TC can only be
-- issued for a student who has already left (is_active = FALSE). Dues MUST be
-- clear — that is the real gate (exit only *reported* dues; the TC blocks on them).
--
--   core.tc_counters    per-school / per-year gap-free number series
--   core.tc_register    the frozen certificate (one issued TC per row)
--   core.sp_tc_manage   Issue | Print | Get | List | Void
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── default TC print format (next to receipt_format) ────────────────────────
-- Two templates, not two paper sizes:
--   Basic  the everyday private-school TC (the common set of particulars).
--   Board  adds the fields CBSE / ICSE / State boards require (exam & result,
--          subjects, attendance, fees-paid-upto, activities, date of application…).
ALTER TABLE core.school_settings
    ADD COLUMN IF NOT EXISTS tc_format varchar(20) NOT NULL DEFAULT 'Basic';

ALTER TABLE core.school_settings DROP CONSTRAINT IF EXISTS chk_school_settings_tc_format;
-- Migrate any earlier value before re-adding the (stricter) constraint.
UPDATE core.school_settings SET tc_format = 'Basic'
    WHERE tc_format NOT IN ('Basic', 'Board') OR tc_format IS NULL;
ALTER TABLE core.school_settings ALTER COLUMN tc_format SET DEFAULT 'Basic';
ALTER TABLE core.school_settings
    ADD CONSTRAINT chk_school_settings_tc_format
    CHECK (tc_format IN ('Basic', 'Board'));


-- ── read/write the default TC format (mirrors sp_school_receipt_format_manage) ──
CREATE OR REPLACE PROCEDURE core.sp_school_tc_format_manage(
    IN    p_operation      varchar,          -- 'Get' | 'Save'
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_tc_format      varchar   DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'tc_format_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_format varchar(20);
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    IF p_operation = 'Save' THEN
        v_format := CASE WHEN p_tc_format IN ('Basic', 'Board')
                         THEN p_tc_format ELSE 'Basic' END;

        INSERT INTO core.school_settings (tenant_id, school_id, tc_format, created_by, created_at, is_deleted, is_active)
        VALUES (p_tenant_id, p_school_id, v_format, p_action_user_id, NOW(), FALSE, TRUE)
        ON CONFLICT (tenant_id, school_id) DO UPDATE
            SET tc_format  = EXCLUDED.tc_format,
                updated_by = p_action_user_id,
                updated_at = NOW();

        OPEN p_result FOR SELECT TRUE AS success, v_format AS tc_format;

    ELSE   -- Get
        OPEN p_result FOR
        SELECT COALESCE(NULLIF(TRIM(s.tc_format), ''), 'Basic') AS tc_format
        FROM core.school_settings s
        WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id
          AND COALESCE(s.is_deleted, FALSE) = FALSE
        LIMIT 1;
    END IF;
END;
$procedure$;


-- ── number series: TC-<year>-<seq>, gap-free per school (mirrors receipt_counters)
CREATE TABLE IF NOT EXISTS core.tc_counters (
    tenant_id integer NOT NULL,
    school_id integer NOT NULL,
    fin_year  varchar(4) NOT NULL,
    last_seq  integer NOT NULL DEFAULT 0,
    PRIMARY KEY (tenant_id, school_id, fin_year)
);


-- ── the frozen certificate ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS core.tc_register (
    tc_id        serial PRIMARY KEY,
    tenant_id    integer NOT NULL,
    school_id    integer NOT NULL,
    student_id   integer NOT NULL,
    tc_no        varchar(40) NOT NULL,
    format       varchar(20) NOT NULL DEFAULT 'Basic',
    issue_date   date NOT NULL DEFAULT CURRENT_DATE,

    -- Frozen snapshot of the student as they were on the day the TC was issued.
    admission_no   varchar(50),
    student_name   varchar(150),
    gender         varchar(20),
    dob            date,
    father_name    varchar(150),
    mother_name    varchar(150),
    class_name     varchar(50),
    section        varchar(20),
    academic_year  varchar(20),
    admission_date date,
    date_of_leaving date,
    religion       varchar(50),
    category       varchar(50),
    nationality    varchar(50),
    address        text,
    udise_no       varchar(30),        -- snapshot of the student's UDISE / PEN id

    -- Entered on the issue form (also part of the legal record).
    reason_for_leaving varchar(300),
    conduct            varchar(50),    -- Good | Satisfactory | Excellent ...
    result             varchar(100),   -- e.g. "Promoted to Class VI" / "Passed"
    remarks            varchar(500),
    outstanding_at_issue numeric(12,2) NOT NULL DEFAULT 0,

    -- Board-format extras (CBSE/ICSE/State). Optional; only the Board template
    -- prints them, but they are frozen like everything else once entered.
    exam_result      varchar(150),     -- last exam taken + result, e.g. "Annual 2025-26, Passed"
    failed_status    varchar(30),      -- No | Once | Twice (whether failed before)
    subjects_studied varchar(300),
    fees_paid_upto   varchar(50),      -- month up to which fees are paid
    working_days     integer,          -- total working days in the session
    days_present     integer,          -- days the student was present
    activities       varchar(300),     -- games / NCC / Scouts-Guides / co-curricular
    application_date date,             -- date the parent applied for the certificate

    -- Reprint tracking: the first print is the original, every later one DUPLICATE.
    print_count  integer NOT NULL DEFAULT 0,

    is_void      boolean NOT NULL DEFAULT FALSE,
    void_reason  varchar(300),
    voided_by    integer,
    voided_at    timestamptz,

    issued_by    integer,
    issued_at    timestamptz NOT NULL DEFAULT now()
);

-- One live TC number per school; a voided one frees nothing (numbers never reused).
CREATE UNIQUE INDEX IF NOT EXISTS ux_tc_register_no
    ON core.tc_register (tenant_id, school_id, tc_no);

-- A student can hold only ONE live (non-void) TC. Re-issuing needs the old one voided.
CREATE UNIQUE INDEX IF NOT EXISTS ux_tc_register_student_live
    ON core.tc_register (tenant_id, school_id, student_id)
    WHERE is_void = FALSE;

-- Board-format columns for a tc_register that already exists (idempotent).
ALTER TABLE core.tc_register
    ADD COLUMN IF NOT EXISTS udise_no         varchar(30),
    ADD COLUMN IF NOT EXISTS exam_result      varchar(150),
    ADD COLUMN IF NOT EXISTS failed_status    varchar(30),
    ADD COLUMN IF NOT EXISTS subjects_studied varchar(300),
    ADD COLUMN IF NOT EXISTS fees_paid_upto   varchar(50),
    ADD COLUMN IF NOT EXISTS working_days     integer,
    ADD COLUMN IF NOT EXISTS days_present     integer,
    ADD COLUMN IF NOT EXISTS activities       varchar(300),
    ADD COLUMN IF NOT EXISTS application_date date;


-- ── issue / print / read / list / void ──────────────────────────────────────
-- Drop the earlier (pre-Board) 15-arg signature so only one overload survives —
-- CREATE OR REPLACE keeps a differing arg list as a separate overload otherwise.
DROP PROCEDURE IF EXISTS core.sp_tc_manage(
    varchar, integer, integer, integer, integer, integer,
    varchar, varchar, varchar, varchar, varchar,
    text, integer, integer, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_tc_manage(
    IN    p_operation      varchar,     -- 'Issue' | 'Print' | 'Get' | 'List' | 'Void'
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_tc_id          integer DEFAULT NULL,
    IN    p_student_id     integer DEFAULT NULL,
    IN    p_format         varchar DEFAULT NULL,   -- Issue: chosen format (Basic | Board)
    IN    p_conduct        varchar DEFAULT NULL,
    IN    p_result         varchar DEFAULT NULL,
    IN    p_reason         varchar DEFAULT NULL,
    IN    p_remarks        varchar DEFAULT NULL,
    -- Board-format extras (all optional; ignored by the Basic template)
    IN    p_exam_result    varchar DEFAULT NULL,
    IN    p_failed_status  varchar DEFAULT NULL,
    IN    p_subjects       varchar DEFAULT NULL,
    IN    p_fees_paid_upto varchar DEFAULT NULL,
    IN    p_working_days   integer DEFAULT NULL,
    IN    p_days_present   integer DEFAULT NULL,
    IN    p_activities     varchar DEFAULT NULL,
    IN    p_application_date date  DEFAULT NULL,
    IN    p_search         text    DEFAULT NULL,    -- List
    IN    p_page_no        integer DEFAULT 1,
    IN    p_page_size      integer DEFAULT 10,
    INOUT p_result_cur     refcursor DEFAULT 'tc_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    s        core.students%ROWTYPE;
    v_dues   numeric(12,2);
    v_year   varchar(4);
    v_seq    integer;
    v_tc_no  varchar(40);
    v_new_id integer;
    v_public uuid;
    v_fmt    varchar(20);
    v_offset integer;
    v_was_printed boolean;
    v_wallet numeric(12,2);
    v_work   integer;
    v_pres   integer;
    v_upto   varchar(50);
    v_days   integer;
    v_held   numeric(12,2);   -- refundable deposit paid and not yet refunded
    e        record;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    -- ───────────────────────────── Issue ─────────────────────────────
    IF p_operation = 'Issue' THEN
        SELECT * INTO s
        FROM core.students
        WHERE student_id = p_student_id
          AND tenant_id  = p_tenant_id
          AND school_id  = p_school_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Student not found.';
        END IF;

        -- A TC is only for a student who has actually left, and only for the
        -- reasons that warrant one (a plain withdrawal does not get a TC).
        IF s.is_active THEN
            RAISE EXCEPTION 'Mark % as left before issuing a Transfer Certificate.', s.student_name;
        END IF;
        IF COALESCE(s.status, '') NOT IN ('Transfer', 'Passout', 'Struck Off') THEN
            RAISE EXCEPTION 'A Transfer Certificate is not issued for status "%".', s.status;
        END IF;

        -- The gate: dues must be clear. Unlike exit (which only reported them),
        -- the TC is withheld until the account is settled.
        SELECT COALESCE(SUM(l.amount_due - l.amount_paid - COALESCE(l.concession, 0)), 0)
        INTO v_dues
        FROM core.student_ledger l
        WHERE l.student_id = p_student_id;

        IF v_dues > 0 THEN
            -- RAISE has no printf specifiers; format the amount ourselves.
            RAISE EXCEPTION 'Clear the pending dues of % before issuing the certificate.',
                to_char(v_dues, 'FM99,99,99,990.00');
        END IF;

        -- Money the school still holds for the family blocks the TC too. An
        -- advance balance (overpayment / prepaid) has to be refunded first,
        -- with a voucher, or it would simply stay with the school after the
        -- child has gone.
        SELECT COALESCE(balance, 0) INTO v_wallet
        FROM core.student_advance
        WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id;

        IF COALESCE(v_wallet, 0) > 0 THEN
            RAISE EXCEPTION 'Refund the advance balance of % to the family before issuing the certificate.',
                to_char(v_wallet, 'FM99,99,99,990.00');
        END IF;

        -- One live TC per student. If a valid one already exists, re-open it
        -- rather than minting a second number (reprint is the correct path).
        IF EXISTS (SELECT 1 FROM core.tc_register
                   WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                     AND student_id = p_student_id AND is_void = FALSE) THEN
            RAISE EXCEPTION 'A Transfer Certificate has already been issued for %. Use reprint.', s.student_name;
        END IF;

        -- The Board particulars are printed on a legal document, so they have
        -- to make sense: no negative days, never more days present than
        -- working days, and nobody applies for a TC after it was issued.
        IF COALESCE(p_working_days, 0) < 0 OR COALESCE(p_days_present, 0) < 0 THEN
            RAISE EXCEPTION 'Working days and days present cannot be negative.';
        END IF;
        IF p_working_days IS NOT NULL AND p_days_present IS NOT NULL
           AND p_days_present > p_working_days THEN
            RAISE EXCEPTION 'Days present (%) cannot be more than working days (%).',
                p_days_present, p_working_days;
        END IF;
        IF p_application_date IS NOT NULL AND p_application_date > CURRENT_DATE THEN
            RAISE EXCEPTION 'The date of application cannot be after the date of issue.';
        END IF;

        -- Left just after promotion: the student has hardly studied in the new class.
        -- Fewer than 30 register days in the new session -> the TC is written for the
        -- session they finished (class last studied, its attendance, its fees), the
        -- way a school writes it ("last studied Class 8, qualified for Class 9").
        SELECT COUNT(*) INTO v_days
          FROM core.fn_attendance_student_days(p_tenant_id, p_school_id, p_student_id, s.academic_year);
        IF v_days < 30 THEN
            SELECT en.academic_year, en.class_name, en.section INTO e
              FROM core.student_enrolment en
             WHERE en.student_id = p_student_id AND en.academic_year <> s.academic_year
             ORDER BY en.academic_year DESC
             LIMIT 1;
            IF e.academic_year IS NOT NULL THEN
                s.academic_year := e.academic_year;
                s.class_name    := e.class_name;
                s.section       := e.section;
            END IF;
        END IF;

        -- Left blank on the form, these come from the school's own records
        -- (QA BUG-085): working days = days the register of the student's section
        -- was taken this session, days present = their Present / Late days, and
        -- fees paid up to = the last fee line paid before the first unpaid one.
        -- Working days are the days the student was on the register: from joining,
        -- across a section move, up to leaving (core.fn_attendance_student_days).
        v_work := p_working_days;
        IF v_work IS NULL THEN
            SELECT NULLIF(COUNT(*), 0)::int INTO v_work
              FROM core.fn_attendance_student_days(p_tenant_id, p_school_id, p_student_id, s.academic_year) d
             WHERE s.date_of_leaving IS NULL OR d.day <= s.date_of_leaving::date;
        END IF;
        v_pres := p_days_present;
        IF v_pres IS NULL AND v_work IS NOT NULL THEN
            SELECT COUNT(*)::int INTO v_pres
              FROM core.student_attendance a
             WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
               AND a.student_id = p_student_id AND a.academic_year = s.academic_year
               AND a.status IN ('Present', 'Late')
               AND (s.date_of_leaving IS NULL OR a.attendance_date::date <= s.date_of_leaving::date);
        END IF;
        v_upto := NULLIF(TRIM(p_fees_paid_upto), '');
        IF v_upto IS NULL THEN
            SELECT l.installment_label INTO v_upto
              FROM core.student_ledger l
             WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
               AND l.student_id = p_student_id AND l.academic_year = s.academic_year
               AND l.amount_paid + COALESCE(l.concession, 0) >= l.amount_due
               AND COALESCE(l.closed_amount, 0) = 0       -- closed at leaving = not paid
               AND l.amount_due > 0
               AND l.due_date < COALESCE(
                     (SELECT MIN(u.due_date) FROM core.student_ledger u
                       WHERE u.tenant_id = p_tenant_id AND u.school_id = p_school_id
                         AND u.student_id = p_student_id AND u.academic_year = s.academic_year
                         AND u.amount_paid + COALESCE(u.concession, 0) + COALESCE(u.closed_amount, 0) < u.amount_due),
                     '9999-12-31')
             -- the last MONTH paid ("Oct 2026"); "Annual" / "Admission" only when no month is paid
             ORDER BY (l.installment_label ~ '^[A-Z][a-z]{2} [0-9]{4}') DESC, l.due_date DESC, l.ledger_id DESC
             LIMIT 1;
        END IF;

        v_fmt  := CASE WHEN p_format IN ('Basic', 'Board') THEN p_format ELSE 'Basic' END;
        -- The series restarts on 1 January (calendar year), not at the session
        -- start. Kept on purpose: the school confirmed it (2026-10-10).
        v_year := to_char(CURRENT_DATE, 'YYYY');

        -- Gap-free number, atomic per (school, year).
        INSERT INTO core.tc_counters (tenant_id, school_id, fin_year, last_seq)
        VALUES (p_tenant_id, p_school_id, v_year, 1)
        ON CONFLICT (tenant_id, school_id, fin_year)
        DO UPDATE SET last_seq = core.tc_counters.last_seq + 1
        RETURNING last_seq INTO v_seq;

        v_tc_no := 'TC-' || v_year || '-' || lpad(v_seq::text, 4, '0');

        INSERT INTO core.tc_register (
            tenant_id, school_id, student_id, tc_no, format, issue_date,
            admission_no, student_name, gender, dob, father_name, mother_name,
            class_name, section, academic_year, admission_date, date_of_leaving,
            religion, category, nationality, address, udise_no,
            reason_for_leaving, conduct, result, remarks, outstanding_at_issue,
            exam_result, failed_status, subjects_studied, fees_paid_upto,
            working_days, days_present, activities, application_date,
            issued_by, issued_at)
        VALUES (
            p_tenant_id, p_school_id, p_student_id, v_tc_no, v_fmt, CURRENT_DATE,
            s.admission_no, s.student_name, s.gender, s.dob, s.guardian_name, s.mother_name,
            s.class_name, s.section, s.academic_year, s.admission_date, s.date_of_leaving,
            s.religion, s.category, s.nationality, s.address, s.udise_student_id,
            NULLIF(TRIM(COALESCE(p_reason, s.leaving_reason)), ''),
            NULLIF(TRIM(p_conduct), ''), NULLIF(TRIM(p_result), ''),
            NULLIF(TRIM(p_remarks), ''), 0,
            NULLIF(TRIM(p_exam_result), ''), NULLIF(TRIM(p_failed_status), ''),
            NULLIF(TRIM(p_subjects), ''), v_upto,
            v_work, v_pres, NULLIF(TRIM(p_activities), ''), p_application_date,
            p_action_user_id, now())
        RETURNING tc_id, public_id INTO v_new_id, v_public;

        -- A refundable deposit still held is not a reason to refuse the TC, but the
        -- office should return it now (Collect Fees > Refund).
        SELECT COALESCE(SUM(l.amount_paid), 0)
               - COALESCE((SELECT SUM(r.amount) FROM core.fee_refunds r
                            WHERE r.student_id = p_student_id AND r.tenant_id = p_tenant_id AND r.school_id = p_school_id
                              AND r.ledger_id IN (SELECT l2.ledger_id FROM core.student_ledger l2
                                                    JOIN core.school_fee_heads h2 ON h2.fee_head_id = l2.fee_head_id
                                                   WHERE l2.student_id = p_student_id AND COALESCE(h2.is_refundable, FALSE))), 0)
          INTO v_held
          FROM core.student_ledger l
          JOIN core.school_fee_heads h ON h.fee_head_id = l.fee_head_id AND COALESCE(h.is_refundable, FALSE)
         WHERE l.student_id = p_student_id AND l.tenant_id = p_tenant_id AND l.school_id = p_school_id;

        OPEN p_result_cur FOR
        SELECT TRUE AS success,
               'Transfer Certificate ' || v_tc_no || ' issued for ' || s.student_name || '.'
               || CASE WHEN v_held > 0 THEN ' A refundable deposit of Rs ' || to_char(v_held, 'FM99,99,99,990.00')
                       || ' is still held: return it from Collect Fees > Refund.' ELSE '' END AS message,
               v_new_id AS tc_id, v_tc_no AS tc_no,
               -- The page opens Tc/Print by this uuid (the int id is not routable).
               v_public AS public_id;
        RETURN;
    END IF;

    -- ─────────────────────────── Print / Get ──────────────────────────
    -- Print marks the certificate printed: the first Print is the original,
    -- every later one comes back with was_duplicate = TRUE so the page can
    -- stamp DUPLICATE. The page calls it only from an explicit POST when the
    -- user presses Print (TcController.MarkPrinted) -- opening or refreshing the
    -- page uses Get, which never marks anything.
    -- A VOIDED certificate is never printed: it would come out looking valid.
    IF p_operation IN ('Print', 'Get') THEN
        IF p_operation = 'Print' THEN
            SELECT (print_count > 0) INTO v_was_printed
            FROM core.tc_register
            WHERE tc_id = p_tc_id AND tenant_id = p_tenant_id AND school_id = p_school_id;

            IF NOT FOUND THEN
                RAISE EXCEPTION 'Certificate not found.';
            END IF;

            IF EXISTS (SELECT 1 FROM core.tc_register
                        WHERE tc_id = p_tc_id AND is_void) THEN
                RAISE EXCEPTION 'This certificate was voided and cannot be printed.';
            END IF;

            UPDATE core.tc_register
            SET print_count = print_count + 1
            WHERE tc_id = p_tc_id AND tenant_id = p_tenant_id AND school_id = p_school_id;
        END IF;

        OPEN p_result_cur FOR
        SELECT r.*,
               CASE WHEN p_operation = 'Print' THEN v_was_printed
                    ELSE (r.print_count > 0) END AS was_duplicate
        FROM core.tc_register r
        WHERE r.tc_id = p_tc_id
          AND r.tenant_id = p_tenant_id AND r.school_id = p_school_id;
        RETURN;
    END IF;

    -- ───────────────────────────── List ──────────────────────────────
    IF p_operation = 'List' THEN
        v_offset := (GREATEST(COALESCE(p_page_no, 1), 1) - 1) * COALESCE(p_page_size, 10);

        OPEN p_result_cur FOR
        WITH filtered AS (
            SELECT r.tc_id, r.public_id, r.tc_no, r.format, r.issue_date, r.student_id,
                   r.admission_no, r.student_name, r.class_name, r.section,
                   r.academic_year, r.date_of_leaving, r.is_void, r.print_count,
                   -- Why, who and when a number was retired, for the Register.
                   r.void_reason, r.voided_at, u.email AS voided_by_name
            FROM core.tc_register r
            LEFT JOIN core.users u ON u.user_id = r.voided_by
            WHERE r.tenant_id = p_tenant_id AND r.school_id = p_school_id
              -- strpos, not LIKE: a typed % or _ is a character, not a wildcard.
              AND (p_search IS NULL OR TRIM(p_search) = ''
                   OR strpos(LOWER(r.student_name), LOWER(TRIM(p_search))) > 0
                   OR strpos(LOWER(r.tc_no), LOWER(TRIM(p_search))) > 0
                   OR strpos(LOWER(COALESCE(r.admission_no, '')), LOWER(TRIM(p_search))) > 0)
        )
        SELECT tc_id, public_id, tc_no, format, issue_date, student_id, admission_no,
               student_name, class_name, section, academic_year, date_of_leaving,
               is_void, print_count, void_reason, voided_at, voided_by_name,
               COUNT(*) OVER() AS total_count
        FROM filtered
        ORDER BY tc_id DESC
        LIMIT COALESCE(p_page_size, 10) OFFSET v_offset;
        RETURN;
    END IF;

    -- ───────────────────────────── Void ──────────────────────────────
    -- A mistaken TC is voided, not deleted — the number is retired for audit and
    -- the student becomes eligible for a fresh issue.
    IF p_operation = 'Void' THEN
        -- A retired certificate number must say why it was retired.
        IF COALESCE(TRIM(p_reason), '') = '' THEN
            RAISE EXCEPTION 'A reason is required to void a certificate.';
        END IF;

        UPDATE core.tc_register
        SET is_void = TRUE, void_reason = NULLIF(TRIM(p_reason), ''),
            voided_by = p_action_user_id, voided_at = now()
        WHERE tc_id = p_tc_id AND tenant_id = p_tenant_id AND school_id = p_school_id
          AND is_void = FALSE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Certificate not found or already void.';
        END IF;

        OPEN p_result_cur FOR SELECT TRUE AS success, 'Certificate voided.' AS message;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation %.', p_operation;
END;
$procedure$;


-- ============================================================================
-- Fee receipt CANCEL (void) — ERP → Fee → Manage Fee → Payment History
--
-- Cancelling a receipt must REVERSE exactly what was applied: for every receipt
-- line that hit a ledger row, give back the cash and the concession so the due
-- re-opens, and mirror the advance wallet. The receipt itself is never deleted —
-- it is marked Cancelled (reason, authoriser, cancelled_by, cancelled_at) for
-- the audit trail, and still re-prints as a CANCELLED copy. Extras (ledger_id
-- NULL) have no due to reverse and drop out of the live balance with the receipt.
--
-- A cancel is refused when reversing it would rewrite money that has already
-- moved on:
--   • a line's ledger row has been REFUNDED (the cash already went back out;
--     reversing would leave the row "refunded" more than it was paid);
--   • the advance this receipt CREDITED has since been spent (reversing would
--     drive the wallet negative). Cancel the receipts that used it first.
--
-- A REGISTRATION receipt has no ledger lines. Cancelling one recomputes the
-- enquiry's registration_fee_paid from its live receipts, and -- if the enquiry
-- has already become a student -- raises a due on the student's ledger for the
-- reversed amount, so it is chased instead of silently forgotten.
--
-- Old receipts can be cancelled on a later day; the reversal belongs to the
-- day it was cancelled (cancelled_at), which is how day close reads it. So a
-- cashier who has already closed TODAY cannot cancel until an admin re-opens it.
--
-- Needs core.fn_user_display_name (fee_advance.sql) and core.fn_fee_day_closed
-- (fee_day_close.sql).
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── 1. Cancellation columns on the receipt header ───────────────────────────
ALTER TABLE core.fee_payments
    ADD COLUMN IF NOT EXISTS is_cancelled         boolean      NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS cancel_reason        varchar(250),
    ADD COLUMN IF NOT EXISTS cancel_authorized_by varchar(80),
    ADD COLUMN IF NOT EXISTS cancelled_by         integer,
    ADD COLUMN IF NOT EXISTS cancelled_at         timestamptz;

-- ── 2. Cancel a receipt and reverse its ledger allocation ───────────────────
CREATE OR REPLACE PROCEDURE core.sp_fee_receipt_cancel(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_receipt_no     varchar,
    IN    p_reason         varchar,
    IN    p_authorized_by  varchar,
    INOUT p_result         refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_payment_id   integer;
    v_amount       numeric(12,2);
    v_student_id   integer;
    v_enquiry_id   integer;
    v_type         varchar(20);
    v_adv_credit   numeric(12,2);
    v_adv_used     numeric(12,2);
    v_balance      numeric(12,2);
    v_refunded     varchar(200);
    v_extra_msg    text := '';
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR p_receipt_no IS NULL THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;
    IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
        RAISE EXCEPTION 'A reason is required to cancel a receipt.';
    END IF;

    -- The reversal belongs to TODAY for the cashier doing it. If that cashier
    -- has already closed today, cancelling now would change a closed day.
    IF core.fn_fee_day_closed(p_tenant_id, p_school_id, p_action_user_id, CURRENT_DATE) THEN
        RAISE EXCEPTION 'Today is already closed for this counter. Ask an admin to re-open the day first.';
    END IF;

    -- Lock the receipt so two cashiers can't cancel/collect it at once.
    SELECT payment_id, amount, student_id, enquiry_id, payment_type,
           COALESCE(advance_credit, 0), COALESCE(advance_used, 0)
      INTO v_payment_id, v_amount, v_student_id, v_enquiry_id, v_type, v_adv_credit, v_adv_used
    FROM core.fee_payments
    WHERE tenant_id = p_tenant_id AND school_id = p_school_id
      AND receipt_no = p_receipt_no
      AND is_cancelled = FALSE
    FOR UPDATE;

    IF NOT FOUND THEN
        OPEN p_result FOR SELECT FALSE AS success, 'Receipt not found or already cancelled.' AS message, p_receipt_no AS receipt_no;
        RETURN;
    END IF;

    -- A Transfer Certificate says the account is settled. Cancelling a receipt now
    -- would make money due on a child who has gone; void the TC first.
    IF v_student_id IS NOT NULL AND EXISTS (
           SELECT 1 FROM core.tc_register t
            WHERE t.tenant_id = p_tenant_id AND t.school_id = p_school_id
              AND t.student_id = v_student_id AND t.is_void = FALSE) THEN
        RAISE EXCEPTION 'A Transfer Certificate has been issued for this student. Void it before cancelling a receipt.';
    END IF;

    -- Lock the ledger rows this receipt touched, and refuse if any of their
    -- money has already been refunded.
    SELECT string_agg(DISTINCT sl.fee_head_name || COALESCE(' ' || sl.installment_label, ''), ', ')
      INTO v_refunded
      FROM core.student_ledger sl
      JOIN core.fee_payment_details d ON d.ledger_id = sl.ledger_id
     WHERE d.payment_id = v_payment_id
       AND sl.tenant_id = p_tenant_id AND sl.school_id = p_school_id
       AND sl.refund_amount > 0;
    PERFORM 1 FROM core.student_ledger sl
      JOIN core.fee_payment_details d ON d.ledger_id = sl.ledger_id
     WHERE d.payment_id = v_payment_id
       AND sl.tenant_id = p_tenant_id AND sl.school_id = p_school_id
       FOR UPDATE OF sl;
    IF v_refunded IS NOT NULL THEN
        RAISE EXCEPTION 'This receipt cannot be cancelled: money on % has already been refunded.', v_refunded;
    END IF;

    -- The credit this receipt put in the wallet must still be there to take back.
    IF v_student_id IS NOT NULL AND (v_adv_credit <> 0 OR v_adv_used <> 0) THEN
        SELECT COALESCE(balance, 0) INTO v_balance
          FROM core.student_advance
         WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND student_id = v_student_id
           FOR UPDATE;
        v_balance := COALESCE(v_balance, 0);
        IF v_balance - v_adv_credit + v_adv_used < -0.001 THEN
            RAISE EXCEPTION 'This receipt cannot be cancelled: the % advance it created has already been used (balance %). Cancel the receipts that used it first.',
                            to_char(v_adv_credit, 'FM999999990.00'), to_char(v_balance, 'FM999999990.00');
        END IF;
    END IF;

    -- Reverse every line that hit a real ledger row (extras have no ledger row).
    -- A line that was CLOSED (student left, class or bus changed) stays closed: the
    -- cancelled money joins the closed part instead of coming back as a due.
    UPDATE core.student_ledger sl
    SET amount_paid = sl.amount_paid - d.amount,
        concession  = sl.concession  - d.concession,
        amount_due  = CASE WHEN COALESCE(sl.closed_amount, 0) > 0
                           THEN sl.amount_due - d.amount - d.concession ELSE sl.amount_due END,
        closed_amount = CASE WHEN COALESCE(sl.closed_amount, 0) > 0
                             THEN sl.closed_amount + d.amount + d.concession ELSE sl.closed_amount END,
        status      = CASE
                        WHEN COALESCE(sl.closed_amount, 0) > 0 THEN sl.status
                        WHEN (sl.amount_paid - d.amount) + (sl.concession - d.concession) <= 0 THEN 'Pending'
                        WHEN (sl.amount_paid - d.amount) + (sl.concession - d.concession) >= sl.amount_due THEN 'Paid'
                        ELSE 'Partial'
                      END,
        updated_at  = NOW()
    FROM core.fee_payment_details d
    WHERE d.payment_id = v_payment_id
      AND d.ledger_id IS NOT NULL
      AND sl.ledger_id = d.ledger_id
      AND sl.tenant_id = p_tenant_id
      AND sl.school_id = p_school_id;

    -- Put the advance wallet back where it was: take the credit back out, put
    -- the used amount back in.
    IF v_student_id IS NOT NULL AND (v_adv_credit <> 0 OR v_adv_used <> 0) THEN
        UPDATE core.student_advance
           SET balance    = balance - v_adv_credit + v_adv_used,
               updated_at = NOW()
         WHERE tenant_id = p_tenant_id AND school_id = p_school_id
           AND student_id = v_student_id;
    END IF;

    -- Mark the receipt cancelled (kept on record for audit).
    UPDATE core.fee_payments
    SET is_cancelled         = TRUE,
        cancel_reason        = trim(p_reason),
        cancel_authorized_by = NULLIF(trim(p_authorized_by), ''),
        cancelled_by         = p_action_user_id,
        cancelled_at         = NOW()
    WHERE payment_id = v_payment_id;

    -- A registration receipt: keep the enquiry's paid flag true to its receipts,
    -- and if the family is already a student, put the money back on their account.
    IF v_type = 'Registration' THEN
        IF v_enquiry_id IS NOT NULL THEN
            UPDATE core.enquiries e
               SET registration_fee_paid =
                       (core.fn_registration_fee_settled(p_tenant_id, p_school_id, e.enquiry_id) > 0
                        AND COALESCE(e.registration_fee_amount, 0)
                            - core.fn_registration_fee_settled(p_tenant_id, p_school_id, e.enquiry_id) <= 0.005)
             WHERE e.enquiry_id = v_enquiry_id
               AND e.tenant_id = p_tenant_id AND e.school_id = p_school_id;
        END IF;

        IF v_student_id IS NOT NULL AND v_amount > 0 THEN
            INSERT INTO core.student_ledger
                (tenant_id, school_id, student_id, fee_head_name, frequency, installment_label,
                 due_date, amount_due, amount_paid, concession, status)
            VALUES
                (p_tenant_id, p_school_id, v_student_id,
                 core.fn_registration_fee_head_name(p_tenant_id, p_school_id), 'One Time',
                 left('Reversed ' || p_receipt_no, 40),
                 to_char(CURRENT_DATE, 'YYYY-MM-DD'), v_amount, 0, 0, 'Pending');
            v_extra_msg := ' ' || to_char(v_amount, 'FM999999990.00') || ' is now due on the student''s account.';
        END IF;
    END IF;

    OPEN p_result FOR
    SELECT TRUE AS success,
           'Receipt ' || p_receipt_no || ' cancelled. ' || to_char(v_amount, 'FM999999990.00') || ' reversed.' || v_extra_msg AS message,
           p_receipt_no AS receipt_no;
END;
$procedure$;

-- ── 3. History: every receipt, cancelled ones flagged, with who and when ────
-- Refund vouchers come from core.sp_fee_refund_history_get (fee_refund.sql),
-- so this cursor keeps one row per receipt.
CREATE OR REPLACE PROCEDURE core.sp_fee_payment_history_get(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_student_id     integer,
    INOUT p_result         refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR p_student_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;

    OPEN p_result FOR
    SELECT receipt_no,
           payment_date,
           amount,
           concession_total,
           payment_mode,
           reference_no,
           is_cancelled,
           cancel_reason,
           payment_type,
           advance_used,
           advance_credit,
           created_by,
           core.fn_user_display_name(created_by)   AS collected_by,
           created_at,
           cancelled_by,
           core.fn_user_display_name(cancelled_by) AS cancelled_by_name,
           cancelled_at,
           cancel_authorized_by
    FROM core.fee_payments
    WHERE tenant_id = p_tenant_id
      AND school_id = p_school_id
      AND student_id = p_student_id
      AND is_active = TRUE
    ORDER BY payment_date DESC, payment_id DESC;
END;
$procedure$;


-- ============================================================================
-- Fee Collection — the COLLECT ENGINE, the ADVANCE wallet and the RECEIPT reprint
--
-- This file owns core.sp_fee_payment_collect and core.sp_fee_receipt_get (the
-- live definitions). Other fee scripts must not re-create them.
--
-- A student carries a single advance balance (core.student_advance). Two flows
-- on the counter, both handled inside sp_fee_payment_collect:
--   • Overpay  → the surplus cash is CREDITED to the wallet (advance_credit).
--   • Use it   → p_advance_used DEBITS the wallet and funds part of the bill.
--
-- Funding rule for a receipt:
--   funded   = (non-advance tenders) + advance_used
--   settled  = dues cash + extras            (= fee_payments.amount)
--   surplus  = funded − settled  (≥ 0)       → credited to the wallet
--   wallet  += surplus − advance_used
-- Advance is recorded as an 'Advance' tender line so it shows in reports but is
-- never counted as cash.
--
-- Rules the engine enforces (each one closed a real hole):
--   • the student must belong to this school (an extras-only receipt never
--     looked at a ledger row, so it was issued for any id at all);
--   • lines for the same due are merged and every due is locked FOR UPDATE, so
--     two lines -- or two counters -- can't both settle the same money;
--   • a concession needs a reason and is never allowed on a refundable deposit;
--   • tenders can't be negative and 'Advance' is not a tender mode (the wallet is
--     only drawn through p_advance_used, which is checked against the balance);
--   • advance used can't exceed the amount being settled;
--   • a cheque / DD tender needs its number;
--   • p_client_ref makes a retried request return the first receipt instead of
--     taking the money twice;
--   • a counter that has closed the day can't collect on it
--     (core.fn_fee_day_closed, owned by fee_day_close.sql -- apply that first).
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── 1. Wallet balance + advance columns on the receipt ──────────────────────
CREATE TABLE IF NOT EXISTS core.student_advance
(
    student_id  integer PRIMARY KEY REFERENCES core.students(student_id),
    tenant_id   integer       NOT NULL,
    school_id   integer       NOT NULL,
    balance     numeric(12,2) NOT NULL DEFAULT 0,
    updated_at  timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT chk_student_advance_scope CHECK ((tenant_id > 1) AND (school_id > 0))
);

ALTER TABLE core.fee_payments
    ADD COLUMN IF NOT EXISTS advance_used         numeric(12,2) NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS advance_credit       numeric(12,2) NOT NULL DEFAULT 0,
    -- Who approved a concession (the cashier is created_by).
    ADD COLUMN IF NOT EXISTS discount_approved_by varchar(80),
    -- One id per counter settlement; a retry with the same id is not a new payment.
    ADD COLUMN IF NOT EXISTS client_ref           varchar(64);

CREATE UNIQUE INDEX IF NOT EXISTS uq_fee_payments_client_ref
    ON core.fee_payments (tenant_id, school_id, client_ref)
    WHERE client_ref IS NOT NULL;

-- ── 2. A user's display name for receipts and history ──────────────────────
CREATE OR REPLACE FUNCTION core.fn_user_display_name(p_user_id integer)
RETURNS varchar
LANGUAGE sql
STABLE
AS $function$
    SELECT CASE WHEN p_user_id IS NULL THEN NULL ELSE
           COALESCE(
               (SELECT NULLIF(trim(up.full_name), '')
                  FROM core.user_profiles up
                 WHERE up.user_id = p_user_id
                 ORDER BY COALESCE(up.is_deleted, FALSE), up.user_profile_id DESC
                 LIMIT 1),
               (SELECT u.email FROM core.users u WHERE u.user_id = p_user_id),
               'User #' || p_user_id)
           END;
$function$;

-- ── 3. Read a student's advance balance ─────────────────────────────────────
CREATE OR REPLACE PROCEDURE core.sp_student_advance_get(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_student_id     integer,
    INOUT p_result         refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR p_student_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;

    OPEN p_result FOR
    SELECT COALESCE((SELECT balance FROM core.student_advance
                     WHERE tenant_id=p_tenant_id AND school_id=p_school_id AND student_id=p_student_id), 0) AS balance;
END;
$procedure$;

-- ── 4. The collect proc ─────────────────────────────────────────────────────
-- Older signatures: 16-arg (no advance) and 17-arg (no client ref / approver).
-- Exactly one overload may exist, or name-based CALL becomes ambiguous.
DROP PROCEDURE IF EXISTS core.sp_fee_payment_collect(
    integer, integer, integer, integer, jsonb, jsonb,
    character varying, character varying, character varying, date, character varying,
    character varying, numeric, character varying, jsonb, refcursor);
DROP PROCEDURE IF EXISTS core.sp_fee_payment_collect(
    integer, integer, integer, integer, jsonb, jsonb,
    character varying, character varying, character varying, date, character varying,
    character varying, numeric, character varying, jsonb, numeric, refcursor);

-- p_client_ref and p_discount_approved_by come AFTER p_result on purpose: every
-- existing positional caller passes the cursor 17th, and keeps working.
CREATE OR REPLACE PROCEDURE core.sp_fee_payment_collect(
    IN    p_tenant_id            integer,
    IN    p_school_id            integer,
    IN    p_action_user_id       integer,
    IN    p_student_id           integer,
    IN    p_items                jsonb,
    IN    p_extras               jsonb,
    IN    p_payment_mode         varchar,
    IN    p_reference_no         varchar  DEFAULT NULL,
    IN    p_remarks              varchar  DEFAULT NULL,
    IN    p_payment_date         date     DEFAULT NULL,
    IN    p_fin_year             varchar  DEFAULT NULL,
    IN    p_discount_type        varchar  DEFAULT NULL,
    IN    p_discount_value       numeric  DEFAULT 0,
    IN    p_discount_reason      varchar  DEFAULT NULL,
    IN    p_tenders              jsonb    DEFAULT NULL,
    IN    p_advance_used         numeric  DEFAULT 0,
    INOUT p_result               refcursor DEFAULT 'result_cursor'::refcursor,
    IN    p_client_ref           varchar  DEFAULT NULL,
    IN    p_discount_approved_by varchar  DEFAULT NULL
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_seq          integer;
    v_year         varchar(4);
    v_receipt      varchar(40);
    v_date         date;
    v_payment_id   integer;
    v_cash_total   numeric(12,2) := 0;
    v_conc_total   numeric(12,2) := 0;
    v_item         jsonb;
    v_amount       numeric(12,2);
    v_concession   numeric(12,2);
    v_label        varchar(100);
    v_note         varchar(40);
    v_outstanding  numeric(12,2);
    v_has_items    boolean;
    v_has_extras   boolean;
    v_has_tenders  boolean;
    v_new_cash     numeric(12,2) := 0;
    v_adv_used     numeric(12,2);
    v_balance      numeric(12,2) := 0;
    v_funded       numeric(12,2);
    v_surplus      numeric(12,2);
    v_mode_count   integer := 0;
    v_mode         varchar(30);
    v_reference    varchar(60);
    v_client_ref   varchar(64);

    v_lines        jsonb := '[]'::jsonb;
    r_item         record;
    r_ledger       record;
    r_prev         record;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR p_student_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;

    -- The student must be this school's. Lines are checked against the ledger
    -- below, but an extras-only receipt never touches a ledger row.
    IF NOT EXISTS (SELECT 1 FROM core.students
                    WHERE student_id = p_student_id
                      AND tenant_id = p_tenant_id AND school_id = p_school_id) THEN
        RAISE EXCEPTION 'Student not found in this school.';
    END IF;

    -- The TC says the account is settled: money taken after it (an overpayment that
    -- lands in the wallet, say) would sit on a child who has gone. Void the TC first.
    IF EXISTS (SELECT 1 FROM core.tc_register t
                WHERE t.tenant_id = p_tenant_id AND t.school_id = p_school_id
                  AND t.student_id = p_student_id AND t.is_void = FALSE) THEN
        RAISE EXCEPTION 'A Transfer Certificate has been issued for this student. Void it before collecting money.';
    END IF;

    -- A retry of a settlement that already went through returns that receipt.
    v_client_ref := NULLIF(trim(p_client_ref), '');
    IF v_client_ref IS NOT NULL THEN
        SELECT receipt_no, amount, concession_total, payment_date, student_id INTO r_prev
          FROM core.fee_payments
         WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND client_ref = v_client_ref;
        IF FOUND THEN
            IF r_prev.student_id IS DISTINCT FROM p_student_id THEN
                RAISE EXCEPTION 'This payment reference was already used for another student. Please reload.';
            END IF;
            OPEN p_result FOR
            SELECT TRUE AS success,
                   'Already recorded as ' || r_prev.receipt_no || '.' AS message,
                   r_prev.receipt_no AS receipt_no,
                   r_prev.amount AS amount,
                   r_prev.concession_total AS concession_total,
                   r_prev.payment_date AS payment_date;
            RETURN;
        END IF;
    END IF;

    v_has_items   := p_items   IS NOT NULL AND jsonb_typeof(p_items)   = 'array' AND jsonb_array_length(p_items)   > 0;
    v_has_extras  := p_extras  IS NOT NULL AND jsonb_typeof(p_extras)  = 'array' AND jsonb_array_length(p_extras)  > 0;
    v_has_tenders := p_tenders IS NOT NULL AND jsonb_typeof(p_tenders) = 'array' AND jsonb_array_length(p_tenders) > 0;
    v_adv_used    := COALESCE(p_advance_used, 0);

    IF NOT v_has_items AND NOT v_has_extras THEN
        RAISE EXCEPTION 'Select at least one due or add an extra charge.';
    END IF;

    v_date := COALESCE(p_payment_date, CURRENT_DATE);

    -- A cashier who has closed the day can't keep collecting on it (an admin
    -- can re-open it). core.fn_fee_day_closed lives in fee_day_close.sql.
    IF core.fn_fee_day_closed(p_tenant_id, p_school_id, p_action_user_id, v_date) THEN
        RAISE EXCEPTION 'Today is already closed for this counter. Ask an admin to re-open the day before collecting.';
    END IF;

    -- Was left(session_name, 4), which turned a session called "FY 26-27" into
    -- "FY 2" and put a space in every receipt number. See receipt_number_year.sql.
    v_year := core.fn_receipt_year(p_tenant_id, p_school_id, p_fin_year, v_date);

    -- ── Dues: merged per ledger row, locked, checked ──
    IF v_has_items THEN
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_items) e
                    WHERE COALESCE((e->>'amount')::numeric, 0) < 0
                       OR COALESCE((e->>'concession')::numeric, 0) < 0) THEN
            RAISE EXCEPTION 'Amount and concession cannot be negative.';
        END IF;

        -- Two lines for the same due used to be checked one at a time against
        -- the row as it was, so both passed and the due was paid twice over.
        -- Ordered by id so two counters always lock in the same order.
        FOR r_item IN
            SELECT (e->>'ledgerId')::integer                          AS ledger_id,
                   SUM(COALESCE((e->>'amount')::numeric, 0))          AS amount,
                   SUM(COALESCE((e->>'concession')::numeric, 0))      AS concession
              FROM jsonb_array_elements(p_items) e
             GROUP BY 1
             ORDER BY 1
        LOOP
            v_amount     := r_item.amount;
            v_concession := r_item.concession;
            IF v_amount = 0 AND v_concession = 0 THEN
                CONTINUE;
            END IF;

            SELECT * INTO r_ledger
              FROM core.student_ledger
             WHERE ledger_id = r_item.ledger_id
               AND tenant_id = p_tenant_id AND school_id = p_school_id AND student_id = p_student_id
               FOR UPDATE;

            IF NOT FOUND THEN
                RAISE EXCEPTION 'A selected due no longer exists. Please reload.';
            END IF;

            v_outstanding := r_ledger.amount_due - r_ledger.amount_paid - r_ledger.concession;
            IF v_amount + v_concession > v_outstanding + 0.001 THEN
                RAISE EXCEPTION 'A payment line is more than its outstanding amount. Please reload.';
            END IF;

            -- A deposit is held to be given back. Waiving part of it means the
            -- school "holds" money it never took, and the refund at exit is wrong.
            IF v_concession > 0 AND COALESCE(core.fn_ledger_head_refundable(r_ledger.ledger_id), FALSE) THEN
                RAISE EXCEPTION 'A concession cannot be given on a refundable deposit (%). Collect it in full or untick it.',
                                r_ledger.fee_head_name;
            END IF;

            v_lines := v_lines || jsonb_build_object(
                'ledgerId', r_ledger.ledger_id, 'amount', v_amount, 'concession', v_concession,
                'head', r_ledger.fee_head_name, 'label', r_ledger.installment_label);

            v_cash_total := v_cash_total + v_amount;
            v_conc_total := v_conc_total + v_concession;
        END LOOP;
    END IF;

    IF v_has_extras THEN
        FOR v_item IN SELECT * FROM jsonb_array_elements(p_extras)
        LOOP
            v_amount := COALESCE((v_item->>'amount')::numeric, 0);
            IF v_amount < 0 THEN
                RAISE EXCEPTION 'Extra charge cannot be negative.';
            END IF;
            v_cash_total := v_cash_total + v_amount;
        END LOOP;
    END IF;

    IF v_cash_total <= 0 AND v_conc_total <= 0 THEN
        RAISE EXCEPTION 'Nothing to collect.';
    END IF;

    -- Money given away needs a reason on record (the screens always asked;
    -- the engine did not).
    IF v_conc_total > 0 AND NULLIF(trim(p_discount_reason), '') IS NULL THEN
        RAISE EXCEPTION 'A reason is required for a concession.';
    END IF;

    -- ── Advance ──
    IF v_adv_used < 0 THEN
        RAISE EXCEPTION 'Advance used cannot be negative.';
    END IF;
    -- Drawing more than the bill took the excess out of the wallet and lost it.
    IF v_adv_used > v_cash_total + 0.001 THEN
        RAISE EXCEPTION 'Advance used (%) is more than the amount being settled (%).', v_adv_used, v_cash_total;
    END IF;
    IF v_adv_used > 0 THEN
        SELECT COALESCE(balance, 0) INTO v_balance
        FROM core.student_advance
        WHERE tenant_id=p_tenant_id AND school_id=p_school_id AND student_id=p_student_id
        FOR UPDATE;
        v_balance := COALESCE(v_balance, 0);
        IF v_adv_used > v_balance + 0.01 THEN
            RAISE EXCEPTION 'Advance used (%) exceeds available balance (%).', v_adv_used, v_balance;
        END IF;
    END IF;

    -- ── Tenders ──
    IF v_has_tenders THEN
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_tenders) t
                    WHERE COALESCE((t->>'amount')::numeric, 0) < 0) THEN
            RAISE EXCEPTION 'A payment amount cannot be negative.';
        END IF;
        -- The wallet is drawn only through p_advance_used, which is checked
        -- against the balance. An 'Advance' tender settled dues from nothing.
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_tenders) t
                    WHERE lower(trim(COALESCE(t->>'mode', ''))) = 'advance'
                      AND COALESCE((t->>'amount')::numeric, 0) > 0) THEN
            RAISE EXCEPTION 'Advance is used through "Use advance", not as a payment mode.';
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_tenders) t
                    WHERE lower(trim(COALESCE(t->>'mode', ''))) IN ('cheque', 'demand draft')
                      AND COALESCE((t->>'amount')::numeric, 0) > 0
                      AND NULLIF(trim(t->>'reference'), '') IS NULL) THEN
            RAISE EXCEPTION 'Enter the cheque / DD number for that payment.';
        END IF;

        SELECT COALESCE(SUM((t->>'amount')::numeric), 0),
               COUNT(DISTINCT t->>'mode') FILTER (WHERE COALESCE((t->>'amount')::numeric,0) > 0)
          INTO v_new_cash, v_mode_count
        FROM jsonb_array_elements(p_tenders) t
        WHERE COALESCE((t->>'amount')::numeric, 0) > 0;
    ELSE
        v_new_cash := v_cash_total - v_adv_used;   -- no explicit split: exact funding
    END IF;

    v_funded  := v_new_cash + v_adv_used;
    IF v_funded < v_cash_total - 0.01 THEN
        RAISE EXCEPTION 'Payment (%) is less than the amount being settled (%).', v_funded, v_cash_total;
    END IF;
    v_surplus := v_funded - v_cash_total;          -- >= 0

    -- Header payment mode.
    IF v_has_tenders AND v_new_cash > 0 THEN
        IF v_mode_count <= 1 THEN
            SELECT NULLIF(trim(t->>'mode'), '') INTO v_mode
            FROM jsonb_array_elements(p_tenders) t
            WHERE COALESCE((t->>'amount')::numeric, 0) > 0
            LIMIT 1;
        ELSE
            v_mode := 'Mixed';
        END IF;
    ELSIF v_adv_used > 0 AND v_new_cash = 0 THEN
        v_mode := 'Advance';
    END IF;
    v_mode := COALESCE(v_mode, NULLIF(trim(p_payment_mode), ''), 'Cash');

    -- Header reference: what the caller gave, else the tender references
    -- (cheque no, UPI ref) so the history list shows them.
    v_reference := NULLIF(trim(p_reference_no), '');
    IF v_reference IS NULL AND v_has_tenders THEN
        SELECT left(string_agg(trim(t->>'reference'), ', '), 60) INTO v_reference
        FROM jsonb_array_elements(p_tenders) t
        WHERE NULLIF(trim(t->>'reference'), '') IS NOT NULL
          AND COALESCE((t->>'amount')::numeric, 0) > 0;
    END IF;

    INSERT INTO core.receipt_counters (tenant_id, school_id, fin_year, last_seq)
    VALUES (p_tenant_id, p_school_id, v_year, 1)
    ON CONFLICT (tenant_id, school_id, fin_year)
    DO UPDATE SET last_seq = core.receipt_counters.last_seq + 1
    RETURNING last_seq INTO v_seq;

    v_receipt := 'RCP-' || v_year || '-' || lpad(v_seq::text, 4, '0');

    INSERT INTO core.fee_payments
        (tenant_id, school_id, student_id, payment_type, receipt_no, amount, concession_total,
         payment_mode, reference_no, remarks, payment_date, created_by,
         discount_type, discount_value, discount_reason, discount_approved_by,
         advance_used, advance_credit, client_ref)
    VALUES
        (p_tenant_id, p_school_id, p_student_id, 'Fee', v_receipt, v_cash_total, v_conc_total,
         v_mode, v_reference, NULLIF(trim(p_remarks), ''),
         v_date, p_action_user_id,
         CASE WHEN v_conc_total > 0 THEN NULLIF(trim(p_discount_type), '') ELSE NULL END,
         CASE WHEN v_conc_total > 0 THEN COALESCE(p_discount_value, 0) ELSE 0 END,
         CASE WHEN v_conc_total > 0 THEN NULLIF(trim(p_discount_reason), '') ELSE NULL END,
         CASE WHEN v_conc_total > 0 THEN NULLIF(trim(p_discount_approved_by), '') ELSE NULL END,
         v_adv_used, v_surplus, v_client_ref)
    RETURNING payment_id INTO v_payment_id;

    -- Adjust the wallet: debit what was used, credit the surplus. Using advance
    -- means the wallet row exists (its balance was checked and locked above), so
    -- that case is a plain UPDATE; an upsert would try to insert a negative row
    -- first and trip chk_student_advance_balance (fee_money_guards.sql).
    IF v_adv_used > 0 THEN
        UPDATE core.student_advance
           SET balance = balance + v_surplus - v_adv_used, updated_at = NOW()
         WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND student_id = p_student_id;
    ELSIF v_surplus > 0 THEN
        INSERT INTO core.student_advance (tenant_id, school_id, student_id, balance, updated_at)
        VALUES (p_tenant_id, p_school_id, p_student_id, v_surplus, NOW())
        ON CONFLICT (student_id)
        DO UPDATE SET balance = core.student_advance.balance + v_surplus, updated_at = NOW();
    END IF;

    -- Tender rows: the cash split, plus an 'Advance' line for wallet-funded part.
    IF v_has_tenders THEN
        FOR v_item IN SELECT * FROM jsonb_array_elements(p_tenders)
        LOOP
            v_amount := COALESCE((v_item->>'amount')::numeric, 0);
            IF v_amount <= 0 THEN CONTINUE; END IF;
            INSERT INTO core.fee_payment_tenders (payment_id, mode, amount, reference)
            VALUES (v_payment_id, COALESCE(NULLIF(trim(v_item->>'mode'), ''), 'Cash'),
                    v_amount, left(NULLIF(trim(v_item->>'reference'), ''), 60));
        END LOOP;
    END IF;
    IF v_adv_used > 0 THEN
        INSERT INTO core.fee_payment_tenders (payment_id, mode, amount)
        VALUES (v_payment_id, 'Advance', v_adv_used);
    END IF;

    -- Apply the merged lines (rows are already locked).
    FOR v_item IN SELECT * FROM jsonb_array_elements(v_lines)
    LOOP
        v_amount     := (v_item->>'amount')::numeric;
        v_concession := (v_item->>'concession')::numeric;

        UPDATE core.student_ledger
        SET amount_paid = amount_paid + v_amount,
            concession  = concession  + v_concession,
            status      = CASE WHEN amount_paid + v_amount + concession + v_concession >= amount_due
                               THEN 'Paid' ELSE 'Partial' END,
            updated_at  = NOW()
        WHERE ledger_id = (v_item->>'ledgerId')::integer;

        INSERT INTO core.fee_payment_details
            (payment_id, ledger_id, fee_head_name, installment_label, amount, concession, line_type)
        VALUES
            (v_payment_id, (v_item->>'ledgerId')::integer, v_item->>'head', v_item->>'label',
             v_amount, v_concession, 'Due');
    END LOOP;

    IF v_has_extras THEN
        FOR v_item IN SELECT * FROM jsonb_array_elements(p_extras)
        LOOP
            v_amount := COALESCE((v_item->>'amount')::numeric, 0);
            v_label  := COALESCE(NULLIF(trim(v_item->>'label'), ''), 'Extra Charge');
            -- The cashier's note ("lost library book") rides in the line's label slot.
            v_note   := left(NULLIF(trim(v_item->>'note'), ''), 40);
            IF v_amount <= 0 THEN
                CONTINUE;
            END IF;

            INSERT INTO core.fee_payment_details
                (payment_id, ledger_id, fee_head_name, installment_label, amount, concession, line_type)
            VALUES
                (v_payment_id, NULL, v_label, v_note, v_amount, 0, 'Extra');
        END LOOP;
    END IF;

    OPEN p_result FOR
    SELECT TRUE         AS success,
           'Payment recorded.' AS message,
           v_receipt    AS receipt_no,
           v_cash_total AS amount,
           v_conc_total AS concession_total,
           v_date       AS payment_date;
END;
$procedure$;

-- ── 5. Receipt reprint ──────────────────────────────────────────────────────
-- Header: what was taken and how, who took it, and -- if it was voided -- that
-- it is CANCELLED, by whom, when and why, so a reprint can never pass as a
-- valid receipt. `tenders` is the split (mode, amount, cheque no / UPI ref) as
-- JSON text. `discount_amount` is the registration-fee discount (registration
-- receipts carry it on the header instead of concession lines).
-- The cursor list is unchanged: positional callers keep working.
CREATE OR REPLACE PROCEDURE core.sp_fee_receipt_get(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_receipt_no     varchar,
    INOUT p_header         refcursor DEFAULT 'header_cursor'::refcursor,
    INOUT p_lines          refcursor DEFAULT 'lines_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_payment_id integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR p_receipt_no IS NULL THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;

    SELECT payment_id INTO v_payment_id
    FROM core.fee_payments
    WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND receipt_no = p_receipt_no;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Receipt not found.';
    END IF;

    OPEN p_header FOR
    SELECT p.receipt_no, p.payment_date, p.amount, p.concession_total, p.payment_mode,
           p.reference_no, p.remarks, p.payment_type,
           p.discount_type, p.discount_value, p.discount_reason, p.discount_approved_by,
           COALESCE(p.discount_amount, 0) AS discount_amount,
           p.advance_used, p.advance_credit,
           -- Who the receipt is FOR.
           COALESCE(p.student_id, 0) AS student_id,
           COALESCE(p.enquiry_id, 0) AS enquiry_id,
           COALESCE(s.student_name, e.student_name, 'Student') AS student_name,
           COALESCE(s.admission_no, '-')                       AS admission_no,
           COALESCE(s.class_name, e.class_name, '-')           AS class_name,
           s.section AS section, s.roll_no AS roll_no,
           -- Who took it, and when.
           p.created_by,
           core.fn_user_display_name(p.created_by)             AS collected_by,
           p.created_at,
           -- Voided?
           p.is_cancelled,
           p.cancel_reason,
           p.cancel_authorized_by,
           p.cancelled_at,
           core.fn_user_display_name(p.cancelled_by)           AS cancelled_by_name,
           -- How it was paid, mode by mode.
           COALESCE((SELECT jsonb_agg(jsonb_build_object('mode', t.mode, 'amount', t.amount,
                                                         'reference', t.reference)
                                      ORDER BY t.tender_id)
                       FROM core.fee_payment_tenders t
                      WHERE t.payment_id = p.payment_id), '[]'::jsonb)::text AS tenders
    FROM core.fee_payments p
    LEFT JOIN core.students  s ON s.student_id = p.student_id
    LEFT JOIN core.enquiries e ON e.enquiry_id = p.enquiry_id
    WHERE p.payment_id = v_payment_id;

    OPEN p_lines FOR
    SELECT fee_head_name, installment_label, amount, concession, line_type
    FROM core.fee_payment_details
    WHERE payment_id = v_payment_id
    ORDER BY detail_id;
END;
$procedure$;


-- ============================================================
--  Student master expansion — real-ERP admission record
--  Adds identity/demographics, previous school, full parent
--  details, and a documents checklist to core.students, and
--  extends core.sp_admission_manage (SaveAdmission) to persist
--  them. Parameters bind by name (Npgsql StoredProcedure), so
--  the new params are additive and safe for existing callers.
--
--  Depends on student_money_lifecycle.sql (fn_fee_plan_problem,
--  fn_student_bill_plan) -- apply that first.
-- ============================================================

-- ── 1. New columns (idempotent) ─────────────────────────────
ALTER TABLE core.students
    ADD COLUMN IF NOT EXISTS blood_group          varchar(5),
    ADD COLUMN IF NOT EXISTS religion             varchar(40),
    ADD COLUMN IF NOT EXISTS category             varchar(20),   -- General/OBC/SC/ST/EWS
    ADD COLUMN IF NOT EXISTS nationality          varchar(40),
    ADD COLUMN IF NOT EXISTS mother_tongue        varchar(40),
    ADD COLUMN IF NOT EXISTS id_proof_no          varchar(30),   -- Aadhaar / birth-cert no
    ADD COLUMN IF NOT EXISTS prev_school_name     varchar(150),
    ADD COLUMN IF NOT EXISTS prev_board           varchar(40),
    ADD COLUMN IF NOT EXISTS prev_class           varchar(40),
    ADD COLUMN IF NOT EXISTS prev_tc_no           varchar(50),
    ADD COLUMN IF NOT EXISTS father_occupation    varchar(80),
    ADD COLUMN IF NOT EXISTS father_qualification varchar(80),
    ADD COLUMN IF NOT EXISTS father_email         varchar(120),
    ADD COLUMN IF NOT EXISTS mother_occupation    varchar(80),
    ADD COLUMN IF NOT EXISTS mother_qualification varchar(80),
    ADD COLUMN IF NOT EXISTS mother_email         varchar(120),
    ADD COLUMN IF NOT EXISTS annual_income        numeric(12,2),
    ADD COLUMN IF NOT EXISTS documents            jsonb;         -- [{name,status}]

-- ── 2. Replace the admission proc with the extended signature ──
--  Widening the parameter list is a NEW signature, so CREATE OR REPLACE alone
--  would leave the OLD overload behind and calls fail with "procedure is not
--  unique". A hard-coded DROP-by-signature goes stale every time a param is
--  added (that is exactly what bit us), so instead drop ANY overload that
--  predates the current parameter set — identified by the absence of
--  p_apaar_id. After the CREATE below there is always exactly one.
DO $$
DECLARE r record;
BEGIN
    FOR r IN
        SELECT oid FROM pg_proc
        WHERE proname = 'sp_admission_manage'
          AND pg_get_function_identity_arguments(oid) NOT ILIKE '%p_apaar_id%'
    LOOP
        EXECUTE 'DROP PROCEDURE ' || r.oid::regprocedure;
    END LOOP;
END $$;

CREATE OR REPLACE PROCEDURE core.sp_admission_manage(
    IN p_operation text,
    IN p_tenant_id integer,
    IN p_school_id integer,
    IN p_action_user_id integer,
    IN p_student_id integer DEFAULT NULL::integer,
    IN p_admission_no text DEFAULT NULL::text,
    IN p_roll_no text DEFAULT NULL::text,
    IN p_student_name text DEFAULT NULL::text,
    IN p_gender text DEFAULT NULL::text,
    IN p_dob date DEFAULT NULL::date,
    IN p_class_name text DEFAULT NULL::text,
    IN p_section text DEFAULT NULL::text,
    IN p_academic_year text DEFAULT NULL::text,
    IN p_admission_date date DEFAULT NULL::date,
    IN p_guardian_name text DEFAULT NULL::text,
    IN p_mother_name text DEFAULT NULL::text,
    IN p_mobile text DEFAULT NULL::text,
    IN p_alt_mobile text DEFAULT NULL::text,
    IN p_address text DEFAULT NULL::text,
    -- ── new student-master fields ──
    IN p_blood_group text DEFAULT NULL::text,
    IN p_religion text DEFAULT NULL::text,
    IN p_category text DEFAULT NULL::text,
    IN p_nationality text DEFAULT NULL::text,
    IN p_mother_tongue text DEFAULT NULL::text,
    IN p_id_proof_no text DEFAULT NULL::text,
    IN p_apaar_id text DEFAULT NULL::text,
    IN p_udise_student_id text DEFAULT NULL::text,
    IN p_prev_school_name text DEFAULT NULL::text,
    IN p_prev_board text DEFAULT NULL::text,
    IN p_prev_class text DEFAULT NULL::text,
    IN p_prev_tc_no text DEFAULT NULL::text,
    IN p_father_occupation text DEFAULT NULL::text,
    IN p_father_qualification text DEFAULT NULL::text,
    IN p_father_email text DEFAULT NULL::text,
    IN p_mother_occupation text DEFAULT NULL::text,
    IN p_mother_qualification text DEFAULT NULL::text,
    IN p_mother_email text DEFAULT NULL::text,
    IN p_annual_income numeric DEFAULT NULL::numeric,
    IN p_documents jsonb DEFAULT NULL::jsonb,
    -- ── fee snapshot / concession ──
    IN p_pay_today_total numeric DEFAULT 0,
    IN p_monthly_total numeric DEFAULT 0,
    IN p_yearly_total numeric DEFAULT 0,
    IN p_annual_total numeric DEFAULT 0,
    IN p_concession_type text DEFAULT NULL::text,
    IN p_concession_value numeric DEFAULT 0,
    IN p_concession_amount numeric DEFAULT 0,
    IN p_concession_reason text DEFAULT NULL::text,
    IN p_concession_cap numeric DEFAULT 100000,
    IN p_fee_plan_json jsonb DEFAULT NULL::jsonb,
    IN p_enquiry_id integer DEFAULT NULL::integer,
    -- ── list/filter ──
    IN p_page_number integer DEFAULT 1,
    IN p_page_size integer DEFAULT 10,
    IN p_search text DEFAULT NULL::text,
    IN p_filter_class text DEFAULT NULL::text,
    IN p_filter_section text DEFAULT NULL::text,
    IN p_filter_gender text DEFAULT NULL::text,
    IN p_filter_year text DEFAULT NULL::text,
    IN p_filter_status text DEFAULT NULL::text,
    INOUT p_result refcursor DEFAULT 'admission_cursor'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_student_id    INTEGER;
    v_admission_no  TEXT;
    v_seq           INTEGER;
    v_year          VARCHAR(20);
    v_adm_date      DATE;
    v_approval      VARCHAR(20);
    v_dup           INTEGER;
    v_item          JSONB;
    v_month_start   DATE;
    v_month_end     DATE;
    v_m             DATE;
    v_i             INTEGER;
    v_sess_start    DATE;
    v_sess_end      DATE;
    v_charge_from   VARCHAR(20);
    v_freq          VARCHAR(30);
    v_step          INTEGER;
    v_period_end    DATE;
    v_sess_month    DATE;
    v_cycles        INTEGER;
    v_reg_balance   NUMERIC;
    v_reg_agreed    NUMERIC;
    v_roll          TEXT;
    v_dup_adm       TEXT;
BEGIN

    -- ── SaveAdmission ────────────────────────────────────────
    IF p_operation = 'SaveAdmission' THEN

        IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
            OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                'Invalid tenant/school context.' AS message, NULL::TEXT AS admission_no;
            RETURN;
        END IF;

        v_year     := COALESCE(p_academic_year, '');
        v_adm_date := COALESCE(p_admission_date, CURRENT_DATE);

        -- ── What a student record must have to be a student ──────────────────
        -- The screen asks for these and the controller re-checks them, but the
        -- proc is the last thing between a request and a real child's record, and
        -- it used to accept anything. Each refusal below was reproduced first: a
        -- student with a blank name, one sitting in a class that does not exist,
        -- one admitted in 2027, and one born after the day they joined.
        IF COALESCE(TRIM(p_student_name), '') = '' THEN
            OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                'Student name is required.' AS message, NULL::TEXT AS admission_no;
            RETURN;
        END IF;

        -- A student in a class that does not exist is an orphan: no class list
        -- shows them, no fee structure matches, and promotion cannot move them.
        IF COALESCE(TRIM(p_class_name), '') = '' OR NOT EXISTS (
               SELECT 1 FROM academic.academic_classes ac
               JOIN academic.academic_years ay
                 ON ay.academic_year_id = ac.academic_year_id
               WHERE ac.tenant_id = p_tenant_id AND ac.school_id = p_school_id
                 AND ac.class_name = TRIM(p_class_name)
                 AND ay.academic_year_name = v_year
                 AND COALESCE(ac.is_deleted, FALSE) = FALSE) THEN
            OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                format('%s is not a class in %s.', COALESCE(NULLIF(TRIM(p_class_name),''),'(blank)'), v_year) AS message,
                NULL::TEXT AS admission_no;
            RETURN;
        END IF;

        -- Nobody is admitted for a day that has not happened. A future date also
        -- lands the first instalment outside the session it belongs to.
        IF v_adm_date > CURRENT_DATE THEN
            OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                'Admission date cannot be in the future.' AS message, NULL::TEXT AS admission_no;
            RETURN;
        END IF;

        IF p_dob IS NOT NULL AND p_dob > CURRENT_DATE THEN
            OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                'Date of birth cannot be in the future.' AS message, NULL::TEXT AS admission_no;
            RETURN;
        END IF;

        IF p_dob IS NOT NULL AND p_dob > v_adm_date THEN
            OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                'Date of birth cannot be after the admission date.' AS message,
                NULL::TEXT AS admission_no;
            RETURN;
        END IF;

        -- Session window AND its billing policy, from the one row that owns both.
        -- The window drives session-end-aware billing (a mid-session joiner is
        -- billed only up to the session's end month). "Charge recurring fees
        -- from" is AdmissionMonth (default, real-world norm — pay only enrolled
        -- months) or SessionStart (the full session from April). It lives on the
        -- year, not the school, so a session cannot be re-billed by a setting
        -- someone changed months later — see fee_charge_from_per_year.sql.
        SELECT start_date, end_date,
               COALESCE(NULLIF(TRIM(charge_fees_from), ''), 'AdmissionMonth')
          INTO v_sess_start, v_sess_end, v_charge_from
        FROM academic.academic_years
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND academic_year_name = v_year
          AND COALESCE(is_deleted, FALSE) = FALSE
        LIMIT 1;

        -- No matching year row (a back-dated or free-typed session name).
        v_charge_from := COALESCE(v_charge_from, 'AdmissionMonth');

        -- The fee plan arrives from the admission form. A negative amount or the
        -- same head twice is refused before anything is written.
        IF core.fn_fee_plan_problem(p_fee_plan_json) IS NOT NULL THEN
            OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                core.fn_fee_plan_problem(p_fee_plan_json) AS message, NULL::TEXT AS admission_no;
            RETURN;
        END IF;

        -- An enquiry becomes ONE student. The row is locked so two clerks
        -- converting the same enquiry at once cannot both get through.
        IF p_enquiry_id IS NOT NULL AND p_enquiry_id > 0 THEN
            PERFORM 1 FROM core.enquiries
             WHERE enquiry_id = p_enquiry_id
               AND tenant_id = p_tenant_id AND school_id = p_school_id
               FOR UPDATE;
            IF EXISTS (SELECT 1 FROM core.enquiries e
                        JOIN core.students s ON s.student_id = e.admission_id
                       WHERE e.enquiry_id = p_enquiry_id
                         AND e.tenant_id = p_tenant_id AND e.school_id = p_school_id) THEN
                OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                    'This enquiry has already been admitted.' AS message, NULL::TEXT AS admission_no;
                RETURN;
            END IF;
        END IF;

        -- Two identical submits arriving together both passed the COUNT below
        -- before either inserted. A transaction-scoped advisory lock on the
        -- same name + dob + mobile makes the second one wait for the first and
        -- then see its row. Released automatically at commit / rollback.
        PERFORM pg_advisory_xact_lock(hashtext(
            'admission:' || p_tenant_id || ':' || p_school_id || ':' ||
            regexp_replace(LOWER(TRIM(COALESCE(p_student_name, ''))), '\s+', ' ', 'g') || ':' ||
            COALESCE(p_dob::text, '') || ':' || COALESCE(p_mobile, '')));

        -- Duplicate guard: same name + dob + mobile already admitted. Name is
        -- whitespace-collapsed + lower-cased so trivial typos ("Rahul  Kumar" vs
        -- "Rahul Kumar", different casing) no longer slip a duplicate through.
        SELECT COUNT(*) INTO v_dup
        FROM core.students
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND is_active = TRUE
          AND regexp_replace(LOWER(TRIM(student_name)), '\s+', ' ', 'g')
              = regexp_replace(LOWER(TRIM(COALESCE(p_student_name, ''))), '\s+', ' ', 'g')
          AND COALESCE(dob::date, DATE '1900-01-01') = COALESCE(p_dob, DATE '1900-01-01')
          AND COALESCE(mobile, '') = COALESCE(p_mobile, '');
        IF v_dup > 0 THEN
            OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                'A student with the same name, DOB and mobile already exists.' AS message,
                NULL::TEXT AS admission_no;
            RETURN;
        END IF;

        -- The same child who LEFT earlier in this session comes back: re-admit the
        -- old record (Students > Left Students > Re-admit) so their history, dues
        -- and admission number stay one record, instead of making a second student.
        SELECT admission_no INTO v_dup_adm
        FROM core.students
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND is_active = FALSE
          AND academic_year = v_year
          AND regexp_replace(LOWER(TRIM(student_name)), '\s+', ' ', 'g')
              = regexp_replace(LOWER(TRIM(COALESCE(p_student_name, ''))), '\s+', ' ', 'g')
          AND COALESCE(dob::date, DATE '1900-01-01') = COALESCE(p_dob, DATE '1900-01-01')
          AND COALESCE(mobile, '') = COALESCE(p_mobile, '')
        LIMIT 1;
        IF v_dup_adm IS NOT NULL THEN
            OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                'This child left earlier this session (' || v_dup_adm || '). Re-admit them from Students > Left Students instead of a new admission.' AS message,
                NULL::TEXT AS admission_no;
            RETURN;
        END IF;

        -- Aadhaar: 12 digits when filled (the same rule as Edit Student).
        IF NULLIF(TRIM(COALESCE(p_id_proof_no, '')), '') IS NOT NULL
           AND TRIM(p_id_proof_no) !~ '^[0-9]{12}$' THEN
            OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                'Aadhaar number must be 12 digits.' AS message, NULL::TEXT AS admission_no;
            RETURN;
        END IF;

        -- A roll number belongs to one child per class + section + session.
        IF NULLIF(TRIM(COALESCE(p_roll_no, '')), '') IS NOT NULL AND EXISTS (
               SELECT 1 FROM core.students o
                WHERE o.tenant_id = p_tenant_id AND o.school_id = p_school_id AND o.is_active
                  AND o.academic_year = v_year AND o.class_name = TRIM(p_class_name)
                  AND COALESCE(o.section, '') = COALESCE(TRIM(p_section), '')
                  AND LOWER(TRIM(o.roll_no)) = LOWER(TRIM(p_roll_no))) THEN
            OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                format('Roll no %s is already used in %s.', TRIM(p_roll_no),
                       TRIM(p_class_name) || COALESCE('-' || NULLIF(TRIM(p_section), ''), '')) AS message,
                NULL::TEXT AS admission_no;
            RETURN;
        END IF;

        -- No roll number typed: give the next one in the class + section
        -- (highest numeric roll + 1), so a new child is never "-" on the register,
        -- admit card or result sheet (QA BUG-074). It can be changed in Edit Student.
        v_roll := NULLIF(TRIM(COALESCE(p_roll_no, '')), '');
        IF v_roll IS NULL AND NULLIF(TRIM(COALESCE(p_section, '')), '') IS NOT NULL THEN
            SELECT (COALESCE(MAX(TRIM(o.roll_no)::int), 0) + 1)::text INTO v_roll
              FROM core.students o
             WHERE o.tenant_id = p_tenant_id AND o.school_id = p_school_id AND o.is_active
               AND o.academic_year = v_year AND o.class_name = TRIM(p_class_name)
               AND COALESCE(o.section, '') = TRIM(p_section)
               AND TRIM(o.roll_no) ~ '^[0-9]{1,6}$';
        END IF;

        -- Admission number: use supplied value or auto-generate per school+year
        IF p_admission_no IS NULL OR TRIM(p_admission_no) = '' THEN
            INSERT INTO core.admission_counters (tenant_id, school_id, academic_year, last_seq)
            VALUES (p_tenant_id, p_school_id, v_year, 1)
            ON CONFLICT (tenant_id, school_id, academic_year)
            DO UPDATE SET last_seq = core.admission_counters.last_seq + 1
            RETURNING last_seq INTO v_seq;

            -- LEFT(v_year, 4) took the first four characters of the session's
            -- NAME, so "FY 26-27" produced ADM-FY 2-0002. core.fn_receipt_year
            -- was written for exactly this when receipt numbers hit it; the
            -- admission number was left on the old expression. It reads the
            -- session's real start date, falls back to any four-digit year in the
            -- name, then to the admission date.
            v_admission_no := 'ADM-' ||
                core.fn_receipt_year(p_tenant_id, p_school_id, v_year, v_adm_date) ||
                '-' || LPAD(v_seq::TEXT, 4, '0');
        ELSE
            -- Normalise a typed number before it becomes this child's identity.
            -- TRIM alone was not enough: 'ADM-2026-0099' and 'adm-2026-0099'
            -- passed the collision check as different strings, so two students
            -- ended up holding the same admission number. Upper-case it and
            -- collapse any inner run of spaces, then compare the same way.
            v_admission_no := UPPER(REGEXP_REPLACE(TRIM(p_admission_no), '\s+', ' ', 'g'));

            -- Reject collision with an existing admission number. Compared on
            -- the normalised form so an old row typed in another case still
            -- counts as taken.
            IF EXISTS (SELECT 1 FROM core.students
                       WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                         AND UPPER(REGEXP_REPLACE(TRIM(admission_no), '\s+', ' ', 'g'))
                             = v_admission_no) THEN
                OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                    'Admission number already in use.' AS message,
                    v_admission_no AS admission_no;
                RETURN;
            END IF;
        END IF;

        -- Concession approval gate
        v_approval := CASE WHEN COALESCE(p_concession_amount, 0) > COALESCE(p_concession_cap, 100000)
                           THEN 'Pending Approval' ELSE 'Approved' END;

        INSERT INTO core.students (
            tenant_id, school_id,
            admission_no, roll_no, student_name, gender, dob,
            class_name, section, academic_year, admission_date,
            guardian_name, mother_name, mobile, alt_mobile, address,
            blood_group, religion, category, nationality, mother_tongue, id_proof_no,
            apaar_id, udise_student_id,
            prev_school_name, prev_board, prev_class, prev_tc_no,
            father_occupation, father_qualification, father_email,
            mother_occupation, mother_qualification, mother_email,
            annual_income, documents,
            pay_today_total, monthly_total, yearly_total, annual_total,
            concession_type, concession_value, concession_amount, concession_reason,
            enquiry_id, status, approval_status,
            created_by, updated_by
        ) VALUES (
            p_tenant_id, p_school_id,
            v_admission_no, v_roll, p_student_name, p_gender, p_dob,
            p_class_name, p_section, v_year, v_adm_date,
            p_guardian_name, p_mother_name, p_mobile, p_alt_mobile, p_address,
            p_blood_group, p_religion, p_category, p_nationality, p_mother_tongue, p_id_proof_no,
            p_apaar_id, p_udise_student_id,
            p_prev_school_name, p_prev_board, p_prev_class, p_prev_tc_no,
            p_father_occupation, p_father_qualification, p_father_email,
            p_mother_occupation, p_mother_qualification, p_mother_email,
            p_annual_income, p_documents,
            COALESCE(p_pay_today_total, 0), COALESCE(p_monthly_total, 0),
            COALESCE(p_yearly_total, 0), COALESCE(p_annual_total, 0),
            p_concession_type, COALESCE(p_concession_value, 0),
            COALESCE(p_concession_amount, 0), p_concession_reason,
            p_enquiry_id, 'Active', v_approval,
            p_action_user_id, p_action_user_id
        )
        RETURNING student_id INTO v_student_id;

        -- Open the student's first enrolment row (see student_enrolment.sql).
        -- core.students still carries class/section/year; this is the parallel
        -- per-session record that keeps the history once they are promoted.
        PERFORM core.fn_student_enrolment_open(
            p_tenant_id, p_school_id, v_student_id,
            v_year, p_class_name, p_section, v_roll, p_action_user_id);

        -- Freeze the fee plan + generate ledger rows. The month arithmetic
        -- (charge-from policy, quarter snapping, session end) moved to
        -- core.fn_plan_periods / core.fn_student_bill_plan in
        -- student_money_lifecycle.sql, so promotion and a class change bill a
        -- plan exactly the way admission does. The plan was validated above.
        PERFORM core.fn_student_bill_plan(
            p_tenant_id, p_school_id, p_action_user_id, v_student_id,
            v_year, v_adm_date, p_fee_plan_json);

        -- Carry an unpaid registration balance onto the student as a real due.
        -- A family can pay part of the registration fee (registration_fee_partial.sql)
        -- and the remainder is derived from the receipts against their enquiry. That
        -- works until the enquiry becomes a student: every screen that chases money
        -- reads core.student_ledger, which is keyed on student_id, so from that moment
        -- the balance would sit on a record nobody opens again and never be collected.
        -- It becomes an ordinary due here -- visible at the fee counter, in the due
        -- list, on reminders and in the reports -- in the same transaction as the
        -- admission, because a balance that can be lost between two calls is a bug
        -- this codebase has been bitten by before.
        --
        -- The agreed fee is frozen on the enquiry only by the FIRST receipt
        -- (sp_registration_fee_record). A family registered without paying anything
        -- therefore had 0 agreed, 0 - 0 = 0 was carried, and the whole fee vanished
        -- at admission (QA BUG-046). When nothing was agreed, a registered enquiry
        -- falls back to the fee the registration screen asks for -- the class-wise
        -- Registration-point amount from the Fee Structure, else the active
        -- Registration heads' default amounts (SchoolSettingsService.
        -- GetCollectionPointResolvedTotalAsync) -- but only while the school has
        -- the registration fee switched on. That amount is frozen on the enquiry so
        -- its "Fee Pending" badge clears once the carried due is paid.
        --
        -- Nothing sums an enquiry's balance into a student's dues, so this is not
        -- double counting.
        IF p_enquiry_id IS NOT NULL AND p_enquiry_id > 0 THEN
            SELECT COALESCE(e.registration_fee_amount, 0)
              INTO v_reg_agreed
            FROM core.enquiries e
            WHERE e.enquiry_id = p_enquiry_id
              AND e.tenant_id = p_tenant_id AND e.school_id = p_school_id;

            IF COALESCE(v_reg_agreed, 0) <= 0 THEN
                SELECT COALESCE(
                         (SELECT NULLIF(SUM(d.amount), 0)
                            FROM core.school_fee_structures s
                            JOIN core.school_fee_structure_details d ON d.fee_structure_id = s.fee_structure_id
                            JOIN core.school_fee_heads h             ON h.fee_head_id = d.fee_head_id
                           WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id
                             AND s.class_name = e.class_name AND s.academic_year = e.session
                             AND COALESCE(s.is_deleted, FALSE) = FALSE
                             AND COALESCE(d.is_deleted, FALSE) = FALSE
                             AND COALESCE(d.is_selected, FALSE)
                             AND h.collection_point = 'Registration'),
                         (SELECT SUM(h.default_amount)
                            FROM core.school_fee_heads h
                           WHERE h.tenant_id = p_tenant_id AND h.school_id = p_school_id
                             AND COALESCE(h.is_active, TRUE)
                             AND COALESCE(h.is_deleted, FALSE) = FALSE
                             AND h.collection_point = 'Registration'),
                         0)
                  INTO v_reg_agreed
                FROM core.enquiries e
                WHERE e.enquiry_id = p_enquiry_id
                  AND e.tenant_id = p_tenant_id AND e.school_id = p_school_id
                  AND COALESCE(TRIM(e.registration_number), '') <> ''
                  AND EXISTS (SELECT 1 FROM core.school_admission_workflow_settings w
                               WHERE w.tenant_id = p_tenant_id AND w.school_id = p_school_id
                                 AND COALESCE(w.is_deleted, FALSE) = FALSE
                                 AND COALESCE(w.enable_registration, FALSE)
                                 AND COALESCE(w.enable_registration_fee, FALSE));

                IF COALESCE(v_reg_agreed, 0) > 0 THEN
                    UPDATE core.enquiries
                       SET registration_fee_amount = ROUND(v_reg_agreed, 2)
                     WHERE enquiry_id = p_enquiry_id
                       AND tenant_id = p_tenant_id AND school_id = p_school_id
                       AND COALESCE(registration_fee_amount, 0) = 0;
                END IF;
            END IF;

            v_reg_balance := COALESCE(v_reg_agreed, 0)
                             - core.fn_registration_fee_settled(p_tenant_id, p_school_id, p_enquiry_id);

            IF COALESCE(v_reg_balance, 0) > 0.005 THEN
                INSERT INTO core.student_ledger (
                    tenant_id, school_id, student_id,
                    fee_head_name, frequency, installment_label,
                    due_date, amount_due, status, academic_year
                ) VALUES (
                    p_tenant_id, p_school_id, v_student_id,
                    core.fn_registration_fee_head_name(p_tenant_id, p_school_id),
                    'One Time', 'Registration',
                    v_adm_date, ROUND(v_reg_balance, 2), 'Pending', v_year
                );

                INSERT INTO core.admission_audit (tenant_id, school_id, student_id, action, detail, action_by)
                VALUES (p_tenant_id, p_school_id, v_student_id, 'RegistrationBalanceCarried',
                        'Unpaid registration balance ' || ROUND(v_reg_balance, 2)::TEXT ||
                        ' carried from enquiry ' || p_enquiry_id::TEXT, p_action_user_id);
            END IF;
        END IF;

        -- Audit
        INSERT INTO core.admission_audit (tenant_id, school_id, student_id, action, detail, action_by)
        VALUES (p_tenant_id, p_school_id, v_student_id, 'AdmissionCreated',
                'Admission ' || v_admission_no || ' created for ' || COALESCE(p_student_name,''),
                p_action_user_id);

        IF COALESCE(p_concession_amount, 0) > 0 THEN
            INSERT INTO core.admission_audit (tenant_id, school_id, student_id, action, detail, action_by)
            VALUES (p_tenant_id, p_school_id, v_student_id, 'ConcessionApplied',
                    'Concession ' || p_concession_amount::TEXT || ' (' ||
                    COALESCE(p_concession_reason, 'no reason') || ') status=' || v_approval,
                    p_action_user_id);
        END IF;

        -- Close the loop: link + confirm enquiry
        IF p_enquiry_id IS NOT NULL AND p_enquiry_id > 0 THEN
            UPDATE core.enquiries
            SET admission_id = v_student_id,
                status       = 'Admission Confirmed',
                updated_by   = p_action_user_id,
                updated_at   = NOW()
            WHERE enquiry_id = p_enquiry_id
              AND tenant_id  = p_tenant_id
              AND school_id  = p_school_id
              AND is_active  = TRUE;

            INSERT INTO core.enquiry_status_history (
                enquiry_id, tenant_id, school_id,
                status_from, status_to, change_note, changed_by
            )
            SELECT p_enquiry_id, p_tenant_id, p_school_id,
                   NULL, 'Admission Confirmed',
                   'Converted to admission ' || v_admission_no, p_action_user_id
            WHERE EXISTS (SELECT 1 FROM core.enquiries
                          WHERE enquiry_id = p_enquiry_id
                            AND tenant_id = p_tenant_id AND school_id = p_school_id);

            INSERT INTO core.admission_audit (tenant_id, school_id, student_id, action, detail, action_by)
            VALUES (p_tenant_id, p_school_id, v_student_id, 'ConvertedFromEnquiry',
                    'Linked from enquiry #' || p_enquiry_id::TEXT, p_action_user_id);

            -- Money the family already paid follows them onto the student record.
            -- A registration fee is taken before any student exists, so its
            -- receipt is booked against the enquiry with student_id NULL. Nothing
            -- pointed it at the student afterwards, and the fee history reads
            -- student_id only — so the amount they had paid was invisible on the
            -- child's record and could only be found by going back to the enquiry.
            --
            -- enquiry_id is deliberately left in place: the receipt really was
            -- taken against the enquiry, and that is where it came from. This adds
            -- the second half of a link that only ever existed one way, since the
            -- student row already carries the enquiry it came from.
            UPDATE core.fee_payments
               SET student_id = v_student_id
             WHERE tenant_id  = p_tenant_id
               AND school_id  = p_school_id
               AND enquiry_id = p_enquiry_id
               AND student_id IS NULL;
        END IF;

        OPEN p_result FOR
            SELECT v_student_id AS student_id, 1 AS success,
                   'Admission saved.' AS message, v_admission_no AS admission_no;
        RETURN;

    -- ── GetStudents (filtered + paginated) ───────────────────
    ELSIF p_operation = 'GetStudents' THEN
        OPEN p_result FOR
            WITH filtered AS (
                SELECT
                    s.student_id, s.admission_no, s.roll_no, s.student_name,
                    s.gender, s.dob,
                    -- When a session is asked for, report the class/section the
                    -- student held IN THAT SESSION, not their present one.
                    COALESCE(e.class_name,    s.class_name)    AS class_name,
                    COALESCE(e.section,       s.section)       AS section,
                    COALESCE(e.academic_year, s.academic_year) AS academic_year,
                    s.admission_date, s.guardian_name, s.mobile,
                    s.annual_total, s.status, s.approval_status, s.enquiry_id,
                    -- Concession settles a due as surely as cash does. Leaving
                    -- it out showed a fully settled student as owing / Partial.
                    COALESCE((
                        SELECT CASE
                            WHEN SUM(l.amount_due - l.amount_paid - l.concession) <= 0 THEN 'Paid'
                            WHEN SUM(l.amount_paid + l.concession) = 0 THEN 'Pending'
                            ELSE 'Partial' END
                        FROM core.student_ledger l
                        WHERE l.student_id = s.student_id
                    ), 'Pending') AS fee_status,
                    COALESCE((
                        SELECT SUM(l.amount_due - l.amount_paid - l.concession)
                        FROM core.student_ledger l
                        WHERE l.student_id = s.student_id
                    ), 0) AS fee_due
                FROM core.students s
                -- Per-session position (core.student_enrolment). students.academic_year
                -- only holds where a student is NOW, so filtering on it loses everyone
                -- who has since been promoted. Matches only when a session is asked
                -- for; otherwise e.* is NULL and the COALESCEs fall back to students.
                LEFT JOIN core.student_enrolment e
                       ON e.student_id    = s.student_id
                      AND e.academic_year = NULLIF(TRIM(COALESCE(p_filter_year, '')), '')
                WHERE s.tenant_id = p_tenant_id
                  AND s.school_id = p_school_id
                  AND s.is_active = TRUE
                  -- strpos, not LIKE: a typed % or _ is a character, not a
                  -- wildcard; inner runs of spaces are collapsed on both sides.
                  AND (
                      p_search IS NULL OR TRIM(p_search) = ''
                      OR strpos(regexp_replace(LOWER(s.student_name), '\s+', ' ', 'g'),
                                regexp_replace(LOWER(TRIM(p_search)), '\s+', ' ', 'g')) > 0
                      OR strpos(LOWER(s.admission_no), LOWER(TRIM(p_search))) > 0
                      OR strpos(regexp_replace(LOWER(COALESCE(s.guardian_name,'')), '\s+', ' ', 'g'),
                                regexp_replace(LOWER(TRIM(p_search)), '\s+', ' ', 'g')) > 0
                      OR strpos(COALESCE(s.mobile,''), TRIM(p_search)) > 0
                  )
                  -- Enrolled in the requested session at all.
                  AND (NULLIF(TRIM(COALESCE(p_filter_year, '')), '') IS NULL
                       OR e.enrolment_id IS NOT NULL)
                  -- "Active" in a given session means the session's own
                  -- enrolment is still open: a child already promoted, retained
                  -- into the next session or passed out has left that roster
                  -- (the Promotion page reloaded the moved children otherwise).
                  AND (NULLIF(TRIM(COALESCE(p_filter_year, '')), '') IS NULL
                       OR LOWER(COALESCE(TRIM(p_filter_status), '')) <> 'active'
                       OR e.status = 'Active')
                  -- Class/section are matched against that session's position.
                  AND (p_filter_class   IS NULL OR TRIM(p_filter_class)   = '' OR LOWER(COALESCE(e.class_name, s.class_name)) = LOWER(TRIM(p_filter_class)))
                  AND (p_filter_section IS NULL OR TRIM(p_filter_section) = '' OR LOWER(COALESCE(e.section, s.section, '')) = LOWER(TRIM(p_filter_section)))
                  AND (p_filter_gender  IS NULL OR TRIM(p_filter_gender)  = '' OR LOWER(COALESCE(s.gender,''))  = LOWER(TRIM(p_filter_gender)))
                  AND (p_filter_status  IS NULL OR TRIM(p_filter_status)  = '' OR LOWER(s.status) = LOWER(TRIM(p_filter_status)))
            )
            SELECT *, COUNT(*) OVER() AS total_count
            FROM filtered
            ORDER BY admission_date DESC, student_id DESC
            LIMIT  COALESCE(p_page_size,   10)
            OFFSET (COALESCE(p_page_number, 1) - 1) * COALESCE(p_page_size, 10);
        RETURN;

    -- ── GetStudentById ───────────────────────────────────────
    ELSIF p_operation = 'GetStudentById' THEN
        OPEN p_result FOR
            -- Leavers included: the Student Dashboard shows a left student
            -- read-only (fees, receipts, history). Edit Student refuses them
            -- in the controller by reading is_active.
            SELECT s.*
            FROM core.students s
            WHERE s.student_id = p_student_id
              AND s.tenant_id  = p_tenant_id
              AND s.school_id  = p_school_id;
        RETURN;

    -- ── DeleteStudent (soft) ─────────────────────────────────
    ELSIF p_operation = 'DeleteStudent' THEN
        UPDATE core.students
        SET is_active = FALSE, updated_by = p_action_user_id, updated_at = NOW()
        WHERE student_id = p_student_id
          AND tenant_id  = p_tenant_id
          AND school_id  = p_school_id;
        OPEN p_result FOR SELECT 1 AS success;
        RETURN;

    END IF;

    -- Fallback
    OPEN p_result FOR SELECT 0 AS student_id WHERE FALSE;

END;
$procedure$;

-- ============================================================================
-- The admission number the next save WOULD generate.
--
-- Read-only: it does not touch core.admission_counters. The admission form shows
-- it as a placeholder so the office knows what is coming, but it is a preview
-- and not a reservation — two clerks with the form open see the same number and
-- whoever saves first takes it. The number is only allocated inside
-- sp_admission_manage, under the counter's own ON CONFLICT.
--
-- Kept beside that generator deliberately: the two must agree on the format, and
-- they will not if they live apart. Both use core.fn_receipt_year, which reads
-- the session's real start year rather than the first four characters of its
-- name (that produced ADM-FY 2-0001).
-- ============================================================================
CREATE OR REPLACE PROCEDURE core.sp_next_admission_no(
    IN  p_tenant_id      integer,
    IN  p_school_id      integer,
    IN  p_action_user_id integer,
    IN  p_academic_year  varchar,
    INOUT p_result       refcursor DEFAULT 'next_adm_cursor'
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    OPEN p_result FOR
    SELECT 'ADM-'
        || core.fn_receipt_year(p_tenant_id, p_school_id, p_academic_year, CURRENT_DATE)
        || '-'
        || LPAD((COALESCE(c.last_seq, 0) + 1)::text, 4, '0') AS admission_no
    FROM (SELECT 1) x
    LEFT JOIN core.admission_counters c
           ON c.tenant_id     = p_tenant_id
          AND c.school_id     = p_school_id
          AND c.academic_year = COALESCE(TRIM(p_academic_year), '');
END;
$$;


-- ============================================================================
-- Edit an existing student.
--
-- WHY THIS EXISTS. core.sp_admission_manage's 'SaveAdmission' is INSERT-only —
-- it always creates a new student — so the Edit Student page had no way to save
-- and was left as a stub. This adds the missing update path.
--
-- WHAT IT DELIBERATELY DOES NOT TOUCH:
--
--   * paid or past instalments. A CLASS change is a money event, though: the
--     new class may cost more or less. When the new class has a fee structure
--     for the student's session, the old class's recurring instalments due
--     AFTER today are CLOSED (reason 'Moved from X to Y on <date>', never
--     deleted) and the new class's recurring heads are billed from next month
--     through core.fn_student_bill_plan -- the same billing admission uses.
--     When it has none, fees are left as they are and the message says so.
--     Every class / section change writes an admission_audit row.
--   * academic_year. The session only ever changes through promotion, and the
--     class must exist in the student's CURRENT session.
--
-- The student's enrolment row for the session follows a class/section change,
-- so lists filtered by session show the class the student is really in.
--
-- Depends on student_money_lifecycle.sql -- apply it first.
--   * admission_no. It is the school's permanent reference, printed on
--     receipts and the TC. Re-issuing one is not an edit.
--
-- Validation (2026-10-10): the edit path now refuses what admission refuses
-- -- a DOB in the future or after the admission date, a mobile that is not 10
-- digits, an Aadhaar that is not 12 digits, an unknown gender -- plus a second
-- active student with the same name + DOB + mobile and a roll number already
-- held in the same class + section + session. Each rule only fires when that
-- value is CHANGED, so an old row that predates a rule can still be edited.
-- Every changed field is written to admission_audit (old -> new, who, when).
--
-- Also here: core.sp_class_setup_sections, the sections a class HAS in a
-- session's setup (Edit Student and Promotion section dropdowns). The older
-- sp_class_active_sections lists only sections that already hold students, so
-- an empty section could never be picked; attendance still uses that one.
--
-- Target DB: PostgreSQL. Safe to re-run. Additive — a new operation on an
-- existing proc, so no signature change and nothing else is affected.
--
-- 2026-10-12: the rest of the admission form became editable (mother tongue,
-- APAAR / UDISE, previous board / class / TC, both parents' occupation /
-- qualification / email, annual income). Admission saved
-- them but nothing could change or even show them afterwards. They arrive
-- AFTER p_result and are written only when p_extended is TRUE: an app that does
-- not know them (the old build, during a deploy) passes nothing and the stored
-- values are kept, instead of every one of them being blanked. The old
-- signature is dropped first so exactly one overload exists.
-- ============================================================================

DROP PROCEDURE IF EXISTS core.sp_student_update(integer, integer, integer, integer,
    text, text, text, date, text, text, text, text, text, text, text, text, text, text, text, text, text, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_student_update(
    IN  p_tenant_id       integer,
    IN  p_school_id       integer,
    IN  p_action_user_id  integer,
    IN  p_student_id      integer,
    IN  p_student_name    text    DEFAULT NULL,
    IN  p_roll_no         text    DEFAULT NULL,
    IN  p_gender          text    DEFAULT NULL,
    IN  p_dob             date    DEFAULT NULL,
    IN  p_class_name      text    DEFAULT NULL,
    IN  p_section         text    DEFAULT NULL,
    IN  p_guardian_name   text    DEFAULT NULL,
    IN  p_mother_name     text    DEFAULT NULL,
    IN  p_mobile          text    DEFAULT NULL,
    IN  p_alt_mobile      text    DEFAULT NULL,
    IN  p_address         text    DEFAULT NULL,
    IN  p_blood_group     text    DEFAULT NULL,
    IN  p_religion        text    DEFAULT NULL,
    IN  p_category        text    DEFAULT NULL,
    IN  p_nationality     text    DEFAULT NULL,
    IN  p_id_proof_no     text    DEFAULT NULL,
    IN  p_prev_school     text    DEFAULT NULL,
    INOUT p_result        refcursor DEFAULT 'student_update_cursor'::refcursor,
    IN  p_extended        boolean DEFAULT FALSE,
    IN  p_mother_tongue   text    DEFAULT NULL,
    IN  p_apaar_id        text    DEFAULT NULL,
    IN  p_udise_student_id text   DEFAULT NULL,
    IN  p_prev_board      text    DEFAULT NULL,
    IN  p_prev_class      text    DEFAULT NULL,
    IN  p_prev_tc_no      text    DEFAULT NULL,
    IN  p_father_occupation    text DEFAULT NULL,
    IN  p_father_qualification text DEFAULT NULL,
    IN  p_father_email         text DEFAULT NULL,
    IN  p_mother_occupation    text DEFAULT NULL,
    IN  p_mother_qualification text DEFAULT NULL,
    IN  p_mother_email         text DEFAULT NULL,
    IN  p_annual_income   numeric DEFAULT NULL)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_name   text := NULLIF(TRIM(COALESCE(p_student_name, '')), '');
    v_cls    text := NULLIF(TRIM(COALESCE(p_class_name, '')), '');
    v_sec    text := NULLIF(TRIM(COALESCE(p_section, '')), '');
    s        core.students%ROWTYPE;
    v_class_id   integer;
    v_class_moved boolean;
    v_moved   boolean;
    v_plan    jsonb;
    v_from    date := (DATE_TRUNC('month', CURRENT_DATE) + INTERVAL '1 month')::date;
    v_reason  varchar(200);
    v_closed  numeric(12,2) := 0;
    v_billed  integer := 0;
    v_note    text := '';
    v_prepaid numeric(12,2);
    v_last_id integer;   -- highest ledger id before the new class is billed
    v_running integer;   -- new lines dropped for a cycle already running
    r         record;
    v_roll    text := NULLIF(TRIM(COALESCE(p_roll_no, '')), '');
    v_gender  text := NULLIF(TRIM(COALESCE(p_gender, '')), '');
    v_mobile  text := NULLIF(TRIM(COALESCE(p_mobile, '')), '');
    v_alt     text := NULLIF(TRIM(COALESCE(p_alt_mobile, '')), '');
    v_idp     text := NULLIF(TRIM(COALESCE(p_id_proof_no, '')), '');
    v_dob     text;
    v_changes text[] := '{}';
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR COALESCE(p_student_id, 0) <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    IF v_name IS NULL THEN
        RAISE EXCEPTION 'Student name is required.';
    END IF;

    -- The row must be this school's. Scoped here as well as in the UPDATE so the
    -- caller gets "not found" rather than a silent no-op.
    SELECT * INTO s
    FROM core.students
    WHERE student_id = p_student_id
      AND tenant_id  = p_tenant_id
      AND school_id  = p_school_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Student not found.';
    END IF;

    v_cls := COALESCE(v_cls, s.class_name);

    -- The class must exist in the student's OWN session. Checking "any class
    -- this school ever had" let a student sit in a class that only exists in
    -- another session, where no roster or fee structure for this one finds them.
    SELECT ac.academic_class_id INTO v_class_id
    FROM academic.academic_classes ac
    JOIN academic.academic_years ay ON ay.academic_year_id = ac.academic_year_id
    WHERE ac.tenant_id = p_tenant_id AND ac.school_id = p_school_id
      AND ac.class_name = v_cls
      AND ay.academic_year_name = s.academic_year
      AND COALESCE(ac.is_deleted, FALSE) = FALSE
    ORDER BY ac.display_order, ac.academic_class_id
    LIMIT 1;

    IF v_class_id IS NULL THEN
        RAISE EXCEPTION 'Class % is not set up for session %.', v_cls, s.academic_year;
    END IF;

    -- A section must be one that class has (when the class has sections at all).
    IF v_sec IS NOT NULL
       AND EXISTS (SELECT 1 FROM academic.academic_class_sections
                    WHERE academic_class_id = v_class_id AND COALESCE(is_deleted, FALSE) = FALSE)
       AND NOT EXISTS (SELECT 1 FROM academic.academic_class_sections
                        WHERE academic_class_id = v_class_id AND section_name = v_sec
                          AND COALESCE(is_deleted, FALSE) = FALSE) THEN
        RAISE EXCEPTION 'Section % does not exist in class %.', v_sec, v_cls;
    END IF;

    v_class_moved := v_cls <> COALESCE(s.class_name, '');
    v_moved       := v_class_moved OR COALESCE(v_sec, '') <> COALESCE(s.section, '');
    v_dob         := COALESCE(p_dob::text, s.dob);

    -- ── Same rules as admission (sp_admission_manage / AdmissionController) ──
    -- Each fires only when the value changes, so legacy rows stay editable.
    IF v_dob IS DISTINCT FROM s.dob THEN
        IF v_dob::date > CURRENT_DATE THEN
            RAISE EXCEPTION 'Date of birth cannot be in the future.';
        END IF;
        IF s.admission_date IS NOT NULL AND v_dob::date > s.admission_date::date THEN
            RAISE EXCEPTION 'Date of birth cannot be after the admission date (%).', s.admission_date;
        END IF;
    END IF;

    IF v_mobile IS DISTINCT FROM s.mobile AND v_mobile IS NOT NULL AND v_mobile !~ '^[0-9]{10}$' THEN
        RAISE EXCEPTION 'Mobile number must be 10 digits.';
    END IF;
    IF v_alt IS DISTINCT FROM s.alt_mobile AND v_alt IS NOT NULL AND v_alt !~ '^[0-9]{10}$' THEN
        RAISE EXCEPTION 'Alternate mobile must be 10 digits.';
    END IF;
    IF v_idp IS DISTINCT FROM s.id_proof_no AND v_idp IS NOT NULL AND v_idp !~ '^[0-9]{12}$' THEN
        RAISE EXCEPTION 'Aadhaar number must be 12 digits.';
    END IF;

    -- The extended fields (see header). Same "only when changed" rule.
    IF p_extended THEN
        IF NULLIF(TRIM(COALESCE(p_apaar_id, '')), '') IS DISTINCT FROM s.apaar_id
           AND NULLIF(TRIM(COALESCE(p_apaar_id, '')), '') !~ '^[0-9]{12}$' THEN
            RAISE EXCEPTION 'APAAR ID must be 12 digits.';
        END IF;
        IF NULLIF(TRIM(COALESCE(p_father_email, '')), '') IS DISTINCT FROM s.father_email
           AND NULLIF(TRIM(COALESCE(p_father_email, '')), '') !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' THEN
            RAISE EXCEPTION 'Father email is not a valid email address.';
        END IF;
        IF NULLIF(TRIM(COALESCE(p_mother_email, '')), '') IS DISTINCT FROM s.mother_email
           AND NULLIF(TRIM(COALESCE(p_mother_email, '')), '') !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' THEN
            RAISE EXCEPTION 'Mother email is not a valid email address.';
        END IF;
        IF p_annual_income IS NOT NULL AND p_annual_income < 0 THEN
            RAISE EXCEPTION 'Annual income cannot be negative.';
        END IF;
    END IF;

    -- Gender drives the Male / Female counts; store the canonical spelling.
    IF v_gender IS NOT NULL THEN
        v_gender := CASE lower(v_gender) WHEN 'male' THEN 'Male' WHEN 'female' THEN 'Female'
                                         WHEN 'other' THEN 'Other' ELSE v_gender END;
        IF v_gender IS DISTINCT FROM s.gender AND v_gender NOT IN ('Male', 'Female', 'Other') THEN
            RAISE EXCEPTION 'Gender must be Male, Female or Other.';
        END IF;
    END IF;

    -- Editing one child into another's identity: same rule as admission's
    -- duplicate guard (name whitespace/case-insensitive + DOB + mobile).
    IF (v_name IS DISTINCT FROM s.student_name OR v_dob IS DISTINCT FROM s.dob
        OR v_mobile IS DISTINCT FROM s.mobile)
       AND EXISTS (SELECT 1 FROM core.students o
                    WHERE o.tenant_id = p_tenant_id AND o.school_id = p_school_id
                      AND o.is_active AND o.student_id <> p_student_id
                      AND regexp_replace(LOWER(TRIM(o.student_name)), '\s+', ' ', 'g')
                          = regexp_replace(LOWER(v_name), '\s+', ' ', 'g')
                      AND COALESCE(o.dob, '') = COALESCE(v_dob, '')
                      AND COALESCE(o.mobile, '') = COALESCE(v_mobile, '')) THEN
        RAISE EXCEPTION 'Another student with the same name, date of birth and mobile already exists.';
    END IF;

    -- A roll number belongs to one child per class + section + session: the
    -- attendance register and the ID card sheet are keyed on it.
    IF v_roll IS NOT NULL
       AND (v_roll IS DISTINCT FROM s.roll_no OR v_moved)
       AND EXISTS (SELECT 1 FROM core.students o
                    WHERE o.tenant_id = p_tenant_id AND o.school_id = p_school_id
                      AND o.is_active AND o.student_id <> p_student_id
                      AND o.academic_year = s.academic_year
                      AND o.class_name = v_cls
                      AND COALESCE(o.section, '') = COALESCE(v_sec, '')
                      AND LOWER(TRIM(o.roll_no)) = LOWER(v_roll)) THEN
        RAISE EXCEPTION 'Roll no % is already used in %.', v_roll, v_cls || COALESCE('-' || v_sec, '');
    END IF;

    -- What changed, for the audit row written below (old -> new).
    IF v_name   IS DISTINCT FROM s.student_name THEN v_changes := v_changes || ('Name: ' || COALESCE(s.student_name, '-') || ' -> ' || v_name); END IF;
    IF v_roll   IS DISTINCT FROM s.roll_no      THEN v_changes := v_changes || ('Roll: ' || COALESCE(s.roll_no, '-') || ' -> ' || COALESCE(v_roll, '-')); END IF;
    IF v_gender IS DISTINCT FROM s.gender       THEN v_changes := v_changes || ('Gender: ' || COALESCE(s.gender, '-') || ' -> ' || COALESCE(v_gender, '-')); END IF;
    IF v_dob    IS DISTINCT FROM s.dob          THEN v_changes := v_changes || ('DOB: ' || COALESCE(s.dob, '-') || ' -> ' || COALESCE(v_dob, '-')); END IF;
    IF NULLIF(TRIM(COALESCE(p_guardian_name, '')), '') IS DISTINCT FROM s.guardian_name THEN
        v_changes := v_changes || ('Guardian: ' || COALESCE(s.guardian_name, '-') || ' -> ' || COALESCE(NULLIF(TRIM(p_guardian_name), ''), '-')); END IF;
    IF NULLIF(TRIM(COALESCE(p_mother_name, '')), '') IS DISTINCT FROM s.mother_name THEN
        v_changes := v_changes || ('Mother: ' || COALESCE(s.mother_name, '-') || ' -> ' || COALESCE(NULLIF(TRIM(p_mother_name), ''), '-')); END IF;
    IF v_mobile IS DISTINCT FROM s.mobile       THEN v_changes := v_changes || ('Mobile: ' || COALESCE(s.mobile, '-') || ' -> ' || COALESCE(v_mobile, '-')); END IF;
    IF v_alt    IS DISTINCT FROM s.alt_mobile   THEN v_changes := v_changes || ('Alt mobile: ' || COALESCE(s.alt_mobile, '-') || ' -> ' || COALESCE(v_alt, '-')); END IF;
    IF NULLIF(TRIM(COALESCE(p_address, '')), '') IS DISTINCT FROM s.address THEN v_changes := v_changes || 'Address changed'::text; END IF;
    -- The Aadhaar number itself is not copied into the audit text.
    IF v_idp    IS DISTINCT FROM s.id_proof_no  THEN v_changes := v_changes || 'Aadhaar changed'::text; END IF;
    IF NULLIF(TRIM(COALESCE(p_blood_group, '')), '') IS DISTINCT FROM s.blood_group THEN
        v_changes := v_changes || ('Blood group: ' || COALESCE(s.blood_group, '-') || ' -> ' || COALESCE(NULLIF(TRIM(p_blood_group), ''), '-')); END IF;
    IF NULLIF(TRIM(COALESCE(p_religion, '')), '') IS DISTINCT FROM s.religion
       OR NULLIF(TRIM(COALESCE(p_category, '')), '') IS DISTINCT FROM s.category
       OR NULLIF(TRIM(COALESCE(p_nationality, '')), '') IS DISTINCT FROM s.nationality
       OR NULLIF(TRIM(COALESCE(p_prev_school, '')), '') IS DISTINCT FROM s.prev_school_name THEN
        v_changes := v_changes || 'Religion / category / nationality / previous school changed'::text; END IF;
    IF p_extended THEN
        IF NULLIF(TRIM(COALESCE(p_mother_tongue, '')), '') IS DISTINCT FROM s.mother_tongue
           OR NULLIF(TRIM(COALESCE(p_apaar_id, '')), '') IS DISTINCT FROM s.apaar_id
           OR NULLIF(TRIM(COALESCE(p_udise_student_id, '')), '') IS DISTINCT FROM s.udise_student_id THEN
            v_changes := v_changes || 'Mother tongue / APAAR / UDISE changed'::text; END IF;
        IF NULLIF(TRIM(COALESCE(p_prev_board, '')), '') IS DISTINCT FROM s.prev_board
           OR NULLIF(TRIM(COALESCE(p_prev_class, '')), '') IS DISTINCT FROM s.prev_class
           OR NULLIF(TRIM(COALESCE(p_prev_tc_no, '')), '') IS DISTINCT FROM s.prev_tc_no THEN
            v_changes := v_changes || 'Previous board / class / TC changed'::text; END IF;
        IF NULLIF(TRIM(COALESCE(p_father_occupation, '')), '') IS DISTINCT FROM s.father_occupation
           OR NULLIF(TRIM(COALESCE(p_father_qualification, '')), '') IS DISTINCT FROM s.father_qualification
           OR NULLIF(TRIM(COALESCE(p_father_email, '')), '') IS DISTINCT FROM s.father_email
           OR NULLIF(TRIM(COALESCE(p_mother_occupation, '')), '') IS DISTINCT FROM s.mother_occupation
           OR NULLIF(TRIM(COALESCE(p_mother_qualification, '')), '') IS DISTINCT FROM s.mother_qualification
           OR NULLIF(TRIM(COALESCE(p_mother_email, '')), '') IS DISTINCT FROM s.mother_email
           OR p_annual_income IS DISTINCT FROM s.annual_income THEN
            v_changes := v_changes || 'Parent occupation / qualification / email / income changed'::text; END IF;
    END IF;

    UPDATE core.students
    SET student_name   = v_name,
        roll_no        = v_roll,
        gender         = v_gender,
        dob            = v_dob,
        class_name     = v_cls,
        section        = v_sec,
        guardian_name  = NULLIF(TRIM(COALESCE(p_guardian_name, '')), ''),
        mother_name    = NULLIF(TRIM(COALESCE(p_mother_name, '')), ''),
        mobile         = v_mobile,
        alt_mobile     = v_alt,
        address        = NULLIF(TRIM(COALESCE(p_address, '')), ''),
        blood_group    = NULLIF(TRIM(COALESCE(p_blood_group, '')), ''),
        religion       = NULLIF(TRIM(COALESCE(p_religion, '')), ''),
        category       = NULLIF(TRIM(COALESCE(p_category, '')), ''),
        nationality    = NULLIF(TRIM(COALESCE(p_nationality, '')), ''),
        id_proof_no    = v_idp,
        prev_school_name = NULLIF(TRIM(COALESCE(p_prev_school, '')), ''),
        mother_tongue        = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_mother_tongue, '')), '') ELSE mother_tongue END,
        apaar_id             = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_apaar_id, '')), '') ELSE apaar_id END,
        udise_student_id     = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_udise_student_id, '')), '') ELSE udise_student_id END,
        prev_board           = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_prev_board, '')), '') ELSE prev_board END,
        prev_class           = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_prev_class, '')), '') ELSE prev_class END,
        prev_tc_no           = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_prev_tc_no, '')), '') ELSE prev_tc_no END,
        father_occupation    = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_father_occupation, '')), '') ELSE father_occupation END,
        father_qualification = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_father_qualification, '')), '') ELSE father_qualification END,
        father_email         = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_father_email, '')), '') ELSE father_email END,
        mother_occupation    = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_mother_occupation, '')), '') ELSE mother_occupation END,
        mother_qualification = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_mother_qualification, '')), '') ELSE mother_qualification END,
        mother_email         = CASE WHEN p_extended THEN NULLIF(TRIM(COALESCE(p_mother_email, '')), '') ELSE mother_email END,
        annual_income        = CASE WHEN p_extended THEN p_annual_income ELSE annual_income END,
        updated_by     = p_action_user_id,
        updated_at     = NOW()
    WHERE student_id = p_student_id
      AND tenant_id  = p_tenant_id
      AND school_id  = p_school_id;

    IF v_moved OR v_roll IS DISTINCT FROM s.roll_no THEN
        -- The per-session record follows the move and the roll number (see
        -- student_enrolment.sql): Enrolment History and the next promotion read it.
        UPDATE core.student_enrolment
        SET class_name        = v_cls,
            academic_class_id = v_class_id,
            section           = v_sec,
            roll_no           = v_roll,
            updated_by        = p_action_user_id,
            updated_at        = now()
        WHERE student_id = p_student_id AND academic_year = s.academic_year;
    END IF;

    IF array_length(v_changes, 1) > 0 THEN
        INSERT INTO core.admission_audit (tenant_id, school_id, student_id, action, detail, action_by)
        VALUES (p_tenant_id, p_school_id, p_student_id, 'StudentEdited',
                array_to_string(v_changes, '; '), p_action_user_id);
    END IF;

    IF v_class_moved AND s.is_active THEN
        -- Only the cycle heads (monthly / quarterly / half-yearly) follow the
        -- class: one-time and yearly charges were already billed for the year.
        SELECT jsonb_agg(e) INTO v_plan
        FROM jsonb_array_elements(core.fn_class_fee_plan(p_tenant_id, p_school_id, v_cls, s.academic_year)) e
        WHERE lower(e->>'frequency') IN ('monthly', 'quarterly', 'half yearly');

        -- Fees already PAID for later months of the old class: closing nothing and
        -- billing the new class for the same months would charge the parent twice.
        SELECT COALESCE(SUM(amount_paid), 0) INTO v_prepaid
          FROM core.student_ledger
         WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
           AND fee_head_name <> 'Transport Fee'
           AND lower(frequency) IN ('monthly', 'quarterly', 'half yearly')
           AND (academic_year = s.academic_year OR academic_year IS NULL)
           AND due_date IS NOT NULL AND due_date::date >= v_from AND amount_paid > 0;
        IF v_plan IS NOT NULL AND v_prepaid > 0 THEN
            RAISE EXCEPTION 'Rs % is already paid for months after this one in %. Cancel those receipts (or refund) before moving the class, so the new class is not billed for paid months.',
                to_char(v_prepaid, 'FM99,99,99,990.00'), s.class_name;
        END IF;

        IF v_plan IS NULL THEN
            v_note := ' No fee structure for ' || v_cls || ' in ' || s.academic_year || ': fees were not changed.';
        ELSE
            v_reason := 'Moved from ' || COALESCE(s.class_name, '?') || ' to ' || v_cls ||
                        ' on ' || to_char(CURRENT_DATE, 'YYYY-MM-DD');
            FOR r IN
                SELECT ledger_id FROM core.student_ledger
                WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
                  AND fee_head_name <> 'Transport Fee'
                  AND lower(frequency) IN ('monthly', 'quarterly', 'half yearly')
                  AND (academic_year = s.academic_year OR academic_year IS NULL)
                  AND due_date IS NOT NULL AND due_date::date > CURRENT_DATE
                  AND amount_due - amount_paid - concession > 0
            LOOP
                v_closed := v_closed + core.fn_ledger_close(r.ledger_id, v_reason, 'ClassChange', p_action_user_id);
            END LOOP;

            -- The new class's plan is the one in force for the rest of the session.
            UPDATE core.student_fee_plan SET is_current = FALSE
            WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
              AND is_current AND (academic_year = s.academic_year OR academic_year IS NULL);

            SELECT COALESCE(MAX(ledger_id), 0) INTO v_last_id FROM core.student_ledger;

            v_billed := core.fn_student_bill_plan(p_tenant_id, p_school_id, p_action_user_id,
                            p_student_id, s.academic_year, v_from, v_plan, TRUE, v_from);

            -- A quarter or half-year that is already running stays with the old class
            -- (its line is still open), so the new class's line for that same cycle is
            -- taken off again -- it was just made here, nothing is paid on it. Without
            -- this the running quarter was charged twice.
            DELETE FROM core.student_ledger
             WHERE student_id = p_student_id AND ledger_id > v_last_id
               AND lower(frequency) IN ('quarterly', 'half yearly')
               AND installment_label ~ '^[A-Z][a-z]{2} [0-9]{4}'
               AND to_date(left(installment_label, 8), 'Mon YYYY') < v_from;
            GET DIAGNOSTICS v_running = ROW_COUNT;
            v_billed := v_billed - v_running;

            v_note := ' Fees: ' || to_char(v_closed, 'FM99999990.00') || ' of ' || s.class_name ||
                      ' instalments closed, ' || v_billed || ' ' || v_cls || ' instalment(s) billed from ' ||
                      to_char(v_from, 'Mon YYYY') || '.';
        END IF;

        INSERT INTO core.admission_audit (tenant_id, school_id, student_id, action, detail, action_by)
        VALUES (p_tenant_id, p_school_id, p_student_id, 'ClassChanged',
                COALESCE(s.class_name, '?') || COALESCE('-' || s.section, '') || ' -> ' ||
                v_cls || COALESCE('-' || v_sec, '') || '.' || v_note,
                p_action_user_id);
    ELSIF v_moved THEN
        INSERT INTO core.admission_audit (tenant_id, school_id, student_id, action, detail, action_by)
        VALUES (p_tenant_id, p_school_id, p_student_id, 'SectionChanged',
                v_cls || COALESCE('-' || s.section, '') || ' -> ' || v_cls || COALESCE('-' || v_sec, ''),
                p_action_user_id);
    END IF;

    OPEN p_result FOR
    SELECT TRUE AS success, 'Student updated successfully.' || v_note AS message, p_student_id AS student_id;
END;
$procedure$;


-- ── Sections a class HAS in a session's setup ───────────────────────────────
-- NULL session = the current one. Read from academic_class_sections, not from
-- students, so an empty section (a new 5-C) can be picked.
CREATE OR REPLACE PROCEDURE core.sp_class_setup_sections(
    IN    p_tenant_id     integer,
    IN    p_school_id     integer,
    IN    p_class         varchar,
    IN    p_academic_year varchar DEFAULT NULL,
    INOUT p_result        refcursor DEFAULT 'class_setup_sections_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        OPEN p_result FOR SELECT WHERE FALSE;
        RETURN;
    END IF;

    OPEN p_result FOR
    SELECT DISTINCT TRIM(cs.section_name) AS section, MIN(cs.display_order) AS display_order
    FROM academic.academic_class_sections cs
    JOIN academic.academic_classes ac ON ac.academic_class_id = cs.academic_class_id
    JOIN academic.academic_years   ay ON ay.academic_year_id  = ac.academic_year_id
    WHERE ac.tenant_id = p_tenant_id AND ac.school_id = p_school_id
      AND LOWER(ac.class_name) = LOWER(TRIM(COALESCE(p_class, '')))
      AND COALESCE(ac.is_deleted, FALSE) = FALSE
      AND COALESCE(cs.is_deleted, FALSE) = FALSE
      AND COALESCE(ay.is_deleted, FALSE) = FALSE
      AND (   (NULLIF(TRIM(COALESCE(p_academic_year, '')), '') IS NULL AND COALESCE(ay.is_current, FALSE))
           OR ay.academic_year_name = TRIM(p_academic_year))
    GROUP BY TRIM(cs.section_name)
    ORDER BY 2, 1;
END;
$procedure$;


-- ============================================================================
-- Exam marks — the Marks Entry sheet behind an exam's per-class datesheet.
--
--   academic.exam_marks              one row per student per exam-subject
--   academic.exam_mark_sheets        the finalize/lock state of one sheet
--   academic.fn_exam_sheet_roster    who sits a sheet (ONE definition, two callers)
--   academic.sp_school_admin_exam_marks_manage
--         GetExamClasses | GetClassSetup | GetSheet | SaveMarks | ReopenSheet | GetMarkScope
--
-- A SHEET is one (exam, class, section, subject) — what a teacher fills in one
-- sitting. The exam is school-wide (see exam_schedule.sql), so the selector
-- cascade is Exam -> Class -> Section -> Subject. The class is part of the sheet
-- key: section 'A' exists in every class, so leaving it out would collide.
--
-- The roster comes from core.student_enrolment, NOT core.students: an exam on a
-- past session must list who was in that class THEN. Reading core.students would
-- show only the students who happen not to have been promoted since.
-- (See the 2026-08-12 entry in docs/SCALING-AND-FIXES.md.)
--
-- Grades are NOT stored. A grade is derived from the percentage + the school's
-- grade scale (exam_results_publish.sql) whenever a result is read.
--
-- RESULTS PUBLISHED = LOCKED. Once an exam's results are published
-- (academic.exams.results_status), SaveMarks and ReopenSheet refuse until the
-- results are unpublished. GetSheet says so, so the page can lock the grid.
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

CREATE TABLE IF NOT EXISTS academic.exam_marks (
    exam_mark_id      serial PRIMARY KEY,
    tenant_id         integer NOT NULL,
    school_id         integer NOT NULL,
    exam_id           integer NOT NULL,
    academic_class_id integer NOT NULL,
    subject_id        integer NOT NULL,
    student_id        integer NOT NULL,
    -- The session row the student sat this paper in. Carried from day one so
    -- marks stay attached to the session, not to the student's present class.
    enrolment_id      integer,
    -- Snapshot of the section the sheet was filled for.
    section           varchar(20) NOT NULL DEFAULT '',
    marks_obtained    numeric(6,2),
    is_absent         boolean NOT NULL DEFAULT FALSE,
    remarks           varchar(200),
    created_by        integer,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_by        integer,
    updated_at        timestamptz,

    CONSTRAINT chk_exam_marks_scope  CHECK (tenant_id > 1 AND school_id > 0),
    CONSTRAINT chk_exam_marks_value  CHECK (marks_obtained IS NULL OR marks_obtained >= 0),
    -- An absent student has no marks; the two can never disagree.
    CONSTRAINT chk_exam_marks_absent CHECK (NOT (is_absent AND marks_obtained IS NOT NULL)),
    CONSTRAINT fk_exam_marks_exam    FOREIGN KEY (exam_id)
        REFERENCES academic.exams (exam_id) ON DELETE CASCADE,
    CONSTRAINT fk_exam_marks_subject FOREIGN KEY (subject_id)
        REFERENCES academic.school_subjects (subject_id),
    CONSTRAINT fk_exam_marks_student FOREIGN KEY (student_id)
        REFERENCES core.students (student_id) ON DELETE CASCADE,
    -- A student sits a subject once per exam, whatever the section.
    CONSTRAINT uq_exam_marks UNIQUE (exam_id, subject_id, student_id)
);

CREATE INDEX IF NOT EXISTS ix_exam_marks_sheet
    ON academic.exam_marks (exam_id, academic_class_id, subject_id, section);

-- The lock lives on the SHEET, not on each mark — a half-finalized sheet is not
-- a state that should be representable.
CREATE TABLE IF NOT EXISTS academic.exam_mark_sheets (
    sheet_id          serial PRIMARY KEY,
    tenant_id         integer NOT NULL,
    school_id         integer NOT NULL,
    exam_id           integer NOT NULL,
    academic_class_id integer NOT NULL,
    subject_id        integer NOT NULL,
    -- '' rather than NULL: NULLs do not compare equal, so a nullable section
    -- would let the same sheet be created twice.
    section           varchar(20) NOT NULL DEFAULT '',
    is_finalized      boolean NOT NULL DEFAULT FALSE,
    finalized_by      integer,
    finalized_at      timestamptz,
    reopened_by       integer,
    reopened_at       timestamptz,

    CONSTRAINT chk_exam_mark_sheets_scope CHECK (tenant_id > 1 AND school_id > 0),
    CONSTRAINT fk_exam_mark_sheets_exam   FOREIGN KEY (exam_id)
        REFERENCES academic.exams (exam_id) ON DELETE CASCADE,
    CONSTRAINT uq_exam_mark_sheets UNIQUE (exam_id, academic_class_id, subject_id, section)
);


-- ── Who sits one sheet ──────────────────────────────────────────────────────
-- Output columns are out_-prefixed so the body can reference the real columns
-- without Postgres treating the name as the OUT variable.
CREATE OR REPLACE FUNCTION academic.fn_exam_sheet_roster(
    p_tenant_id integer,
    p_school_id integer,
    p_year_id   integer,
    p_class_id  integer,
    p_section   varchar)
RETURNS TABLE (
    out_student_id   integer,
    out_enrolment_id integer,
    out_roll_no      text,
    out_student_name text,
    out_gender       text)
LANGUAGE sql
STABLE
AS $function$
    SELECT
        e.student_id,
        e.enrolment_id,
        -- roll_no is not captured yet on most rows; fall back so the # column
        -- always shows something stable.
        COALESCE(NULLIF(TRIM(e.roll_no), ''),
                 NULLIF(TRIM(s.roll_no), ''),
                 NULLIF(TRIM(s.admission_no), ''), '')::text,
        s.student_name::text,
        COALESCE(s.gender, '')::text
    FROM core.student_enrolment e
    JOIN core.students s ON s.student_id = e.student_id
    WHERE e.tenant_id = p_tenant_id
      AND e.school_id = p_school_id
      AND e.academic_year_id  = p_year_id
      AND e.academic_class_id = p_class_id
      AND LOWER(COALESCE(TRIM(e.section), '')) = LOWER(COALESCE(TRIM(p_section), ''))
      -- A student who left mid-session does not sit the paper. 'Promoted' and
      -- 'PassedOut' are normal outcomes of a finished session and must stay.
      AND COALESCE(e.status, '') <> 'Left'
    ORDER BY
        CASE WHEN COALESCE(NULLIF(TRIM(e.roll_no), ''), NULLIF(TRIM(s.roll_no), '')) ~ '^[0-9]+$'
             THEN lpad(COALESCE(NULLIF(TRIM(e.roll_no), ''), TRIM(s.roll_no)), 6, '0')
             ELSE NULL END NULLS LAST,
        s.student_name;
$function$;


CREATE OR REPLACE PROCEDURE academic.sp_school_admin_exam_marks_manage(
    IN    p_operation         character varying,
    IN    p_tenant_id         integer,
    IN    p_school_id         integer,
    IN    p_action_user_id    integer,
    IN    p_exam_id           integer   DEFAULT NULL,
    IN    p_academic_class_id integer   DEFAULT NULL,
    IN    p_subject_id        integer   DEFAULT NULL,
    IN    p_section           character varying DEFAULT NULL,
    IN    p_items             text      DEFAULT NULL,
    IN    p_finalize          boolean   DEFAULT FALSE,
    INOUT p_result            refcursor DEFAULT 'exam_marks_cursor'::refcursor,
    INOUT p_result2           refcursor DEFAULT 'exam_marks_cursor2'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_section text;
    v_year_id integer;
    v_max     numeric;
    v_pass    numeric;
    v_paper   date;
    v_old_sec text;      -- section of a moved student's finalised mark
    v_final   boolean;
    v_items   jsonb;
    v_item    jsonb;
    v_sid     integer;
    v_marks   numeric;
    v_absent  boolean;
    v_name    text;
    v_enrol   integer;
    v_saved   integer := 0;
    v_added   integer := 0;
    v_blank   integer := 0;
    v_status  text;
    v_results text;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    v_section := COALESCE(TRIM(p_section), '');

    -- Every operation works on one exam; resolve its academic year once.
    IF COALESCE(p_exam_id, 0) > 0 THEN
        SELECT academic_year_id, status, results_status INTO v_year_id, v_status, v_results
        FROM academic.exams
        WHERE exam_id   = p_exam_id
          AND tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND NOT is_deleted;

        IF v_year_id IS NULL THEN
            RAISE EXCEPTION 'That exam was not found.';
        END IF;
    END IF;

    -- Operations from GetClassSetup down all need a class that is on the exam.
    IF p_operation IN ('GetClassSetup', 'GetSheet', 'SaveMarks', 'ReopenSheet') THEN
        IF COALESCE(p_academic_class_id, 0) <= 0 THEN
            RAISE EXCEPTION 'Pick a class first.';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM academic.exam_subjects
                       WHERE exam_id = p_exam_id
                         AND academic_class_id = p_academic_class_id) THEN
            RAISE EXCEPTION 'That class is not part of this exam.';
        END IF;
    END IF;

    IF p_operation = 'GetExamClasses' THEN

        -- The classes this exam covers — the Class dropdown.
        OPEN p_result FOR
        SELECT es.academic_class_id,
               c.class_name,
               COUNT(*)::int AS subject_count
        FROM academic.exam_subjects es
        JOIN academic.academic_classes c ON c.academic_class_id = es.academic_class_id
        WHERE es.exam_id   = p_exam_id
          AND es.tenant_id = p_tenant_id
          AND es.school_id = p_school_id
        GROUP BY es.academic_class_id, c.class_name, c.display_order
        ORDER BY c.display_order, c.class_name;

        OPEN p_result2 FOR SELECT 1 WHERE FALSE;

    ELSIF p_operation = 'GetClassSetup' THEN

        -- That class's datesheet — the Subject dropdown and its marks scale.
        OPEN p_result FOR
        SELECT es.subject_id, s.subject_name, es.exam_date, es.start_time, es.end_time,
               es.max_marks, es.pass_marks
        FROM academic.exam_subjects es
        JOIN academic.school_subjects s ON s.subject_id = es.subject_id
        WHERE es.exam_id           = p_exam_id
          AND es.academic_class_id = p_academic_class_id
          AND es.tenant_id         = p_tenant_id
          AND es.school_id         = p_school_id
        ORDER BY es.display_order, s.subject_name;

        -- Sections that actually have students enrolled in this class that year,
        -- narrowed to the exam's chosen sections when it targets specific ones.
        -- No exam_class_sections rows for this (exam, class) = the whole class.
        OPEN p_result2 FOR
        SELECT COALESCE(TRIM(e.section), '') AS section, COUNT(*)::int AS student_count
        FROM core.student_enrolment e
        WHERE e.tenant_id = p_tenant_id
          AND e.school_id = p_school_id
          AND e.academic_year_id  = v_year_id
          AND e.academic_class_id = p_academic_class_id
          AND COALESCE(e.status, '') <> 'Left'
          AND (NOT EXISTS (SELECT 1 FROM academic.exam_class_sections x
                           WHERE x.exam_id = p_exam_id
                             AND x.academic_class_id = p_academic_class_id)
               OR EXISTS (SELECT 1 FROM academic.exam_class_sections x
                          WHERE x.exam_id = p_exam_id
                            AND x.academic_class_id = p_academic_class_id
                            AND x.section = COALESCE(TRIM(e.section), '')))
        GROUP BY COALESCE(TRIM(e.section), '')
        ORDER BY 1;

    ELSIF p_operation = 'GetSheet' THEN

        SELECT es.max_marks, es.pass_marks INTO v_max, v_pass
        FROM academic.exam_subjects es
        WHERE es.exam_id = p_exam_id
          AND es.academic_class_id = p_academic_class_id
          AND es.subject_id = p_subject_id;

        IF v_max IS NULL THEN
            RAISE EXCEPTION 'That subject is not on this class''s datesheet.';
        END IF;

        OPEN p_result FOR
        SELECT
            r.out_student_id   AS student_id,
            r.out_roll_no      AS roll_no,
            r.out_student_name AS student_name,
            r.out_gender       AS gender,
            m.marks_obtained,
            COALESCE(m.is_absent, FALSE) AS is_absent,
            (m.exam_mark_id IS NOT NULL) AS has_mark
        FROM academic.fn_exam_sheet_roster(p_tenant_id, p_school_id, v_year_id, p_academic_class_id, v_section) r
        LEFT JOIN academic.exam_marks m
               ON m.exam_id    = p_exam_id
              AND m.subject_id = p_subject_id
              AND m.student_id = r.out_student_id;

        OPEN p_result2 FOR
        SELECT
            v_max  AS max_marks,
            v_pass AS pass_marks,
            (SELECT es.exam_date FROM academic.exam_subjects es
             WHERE es.exam_id = p_exam_id
               AND es.academic_class_id = p_academic_class_id
               AND es.subject_id = p_subject_id) AS exam_date,
            (SELECT es.start_time FROM academic.exam_subjects es
             WHERE es.exam_id = p_exam_id
               AND es.academic_class_id = p_academic_class_id
               AND es.subject_id = p_subject_id) AS start_time,
            (SELECT es.end_time FROM academic.exam_subjects es
             WHERE es.exam_id = p_exam_id
               AND es.academic_class_id = p_academic_class_id
               AND es.subject_id = p_subject_id) AS end_time,
            (SELECT s.subject_name FROM academic.school_subjects s
             WHERE s.subject_id = p_subject_id) AS subject_name,
            COALESCE(sh.is_finalized, FALSE) AS is_finalized,
            sh.finalized_at,
            (v_results = 'Published') AS results_published
        FROM (SELECT 1) x
        LEFT JOIN academic.exam_mark_sheets sh
               ON sh.exam_id           = p_exam_id
              AND sh.academic_class_id = p_academic_class_id
              AND sh.subject_id        = p_subject_id
              AND sh.section           = v_section;

    ELSIF p_operation = 'SaveMarks' THEN

        SELECT es.max_marks, es.pass_marks, NULLIF(es.exam_date::text, '')::date INTO v_max, v_pass, v_paper
        FROM academic.exam_subjects es
        WHERE es.exam_id = p_exam_id
          AND es.academic_class_id = p_academic_class_id
          AND es.subject_id = p_subject_id;

        IF v_max IS NULL THEN
            RAISE EXCEPTION 'That subject is not on this class''s datesheet.';
        END IF;

        SELECT COALESCE(is_finalized, FALSE) INTO v_final
        FROM academic.exam_mark_sheets
        WHERE exam_id           = p_exam_id
          AND academic_class_id = p_academic_class_id
          AND subject_id        = p_subject_id
          AND section           = v_section;

        -- Published results are a record parents have seen; they change only
        -- after someone unpublishes them (with a reason, logged).
        IF v_results = 'Published' THEN
            RAISE EXCEPTION 'The results of this exam are published, so its marks are locked. Unpublish the results first.';
        END IF;

        IF COALESCE(v_final, FALSE) THEN
            RAISE EXCEPTION 'These marks are finalized. Ask a school admin to reopen the sheet.';
        END IF;

        -- A draft datesheet is still being built; the Marks Entry page hides
        -- drafts, and the server holds the same line.
        IF v_status IS DISTINCT FROM 'Published' THEN
            RAISE EXCEPTION 'This exam is still a draft. Publish it before entering marks.';
        END IF;

        -- No marks before the paper has been written (QA BUG-076).
        IF v_paper > CURRENT_DATE THEN
            RAISE EXCEPTION 'This paper is on %. Marks can be entered from that day.', to_char(v_paper, 'DD Mon YYYY');
        END IF;

        -- An exam that targets specific sections of this class takes marks only
        -- for those sections (no exam_class_sections rows = the whole class).
        IF EXISTS (SELECT 1 FROM academic.exam_class_sections x
                   WHERE x.exam_id = p_exam_id AND x.academic_class_id = p_academic_class_id)
           AND NOT EXISTS (SELECT 1 FROM academic.exam_class_sections x
                           WHERE x.exam_id = p_exam_id AND x.academic_class_id = p_academic_class_id
                             AND LOWER(x.section) = LOWER(v_section)) THEN
            RAISE EXCEPTION 'This exam is not held for section % of this class.',
                CASE WHEN v_section = '' THEN '(none)' ELSE v_section END;
        END IF;

        v_items := COALESCE(NULLIF(p_items, ''), '[]')::jsonb;

        FOR v_item IN SELECT value FROM jsonb_array_elements(v_items)
        LOOP
            v_sid := NULLIF(v_item->>'studentId', '')::int;
            CONTINUE WHEN v_sid IS NULL;

            v_absent := COALESCE((v_item->>'absent')::boolean, FALSE);
            v_marks  := CASE WHEN v_absent THEN NULL
                             ELSE NULLIF(v_item->>'marks', '')::numeric END;

            -- Only students actually on this sheet's roster.
            SELECT r.out_student_name, r.out_enrolment_id INTO v_name, v_enrol
            FROM academic.fn_exam_sheet_roster(p_tenant_id, p_school_id, v_year_id, p_academic_class_id, v_section) r
            WHERE r.out_student_id = v_sid;

            IF v_name IS NULL THEN
                RAISE EXCEPTION 'A student on this sheet is not enrolled in this class and section.';
            END IF;

            IF v_marks IS NOT NULL AND (v_marks < 0 OR v_marks > v_max) THEN
                RAISE EXCEPTION 'Marks for % must be between 0 and %.', v_name, v_max;
            END IF;

            -- A student who moved section may already have this paper's mark on the
            -- OLD section's sheet. If that sheet is finalised, saving here would change a
            -- locked mark without anyone reopening it.
            SELECT m.section INTO v_old_sec
              FROM academic.exam_marks m
              JOIN academic.exam_mark_sheets sh
                ON sh.exam_id = m.exam_id AND sh.academic_class_id = m.academic_class_id
               AND sh.subject_id = m.subject_id AND sh.section = m.section AND sh.is_finalized
             WHERE m.exam_id = p_exam_id AND m.subject_id = p_subject_id AND m.student_id = v_sid
               AND (m.section IS DISTINCT FROM v_section OR m.academic_class_id <> p_academic_class_id)
             LIMIT 1;
            IF v_old_sec IS NOT NULL THEN
                RAISE EXCEPTION '%''s mark for this paper is on the finalised sheet of section %. Reopen that sheet first.',
                    v_name, CASE WHEN v_old_sec = '' THEN '(none)' ELSE v_old_sec END;
            END IF;

            INSERT INTO academic.exam_marks
                (tenant_id, school_id, exam_id, academic_class_id, subject_id, student_id,
                 enrolment_id, section, marks_obtained, is_absent, created_by, created_at)
            VALUES
                (p_tenant_id, p_school_id, p_exam_id, p_academic_class_id, p_subject_id, v_sid,
                 v_enrol, v_section, v_marks, v_absent, p_action_user_id, now())
            ON CONFLICT ON CONSTRAINT uq_exam_marks
            DO UPDATE SET marks_obtained    = EXCLUDED.marks_obtained,
                          is_absent         = EXCLUDED.is_absent,
                          enrolment_id      = EXCLUDED.enrolment_id,
                          academic_class_id = EXCLUDED.academic_class_id,
                          section           = EXCLUDED.section,
                          updated_by        = p_action_user_id,
                          updated_at        = now()
            -- An unchanged mark is not rewritten, so updated_by keeps meaning
            -- "who last changed it" and the history trigger stays quiet.
            WHERE academic.exam_marks.marks_obtained    IS DISTINCT FROM EXCLUDED.marks_obtained
               OR academic.exam_marks.is_absent         IS DISTINCT FROM EXCLUDED.is_absent
               OR academic.exam_marks.enrolment_id      IS DISTINCT FROM EXCLUDED.enrolment_id
               OR academic.exam_marks.academic_class_id IS DISTINCT FROM EXCLUDED.academic_class_id
               OR academic.exam_marks.section           IS DISTINCT FROM EXCLUDED.section;

            v_saved := v_saved + 1;
        END LOOP;

        IF p_finalize THEN
            -- Anyone still without a row is recorded Absent, which is exactly what
            -- the finalize dialog warns the teacher about.
            INSERT INTO academic.exam_marks
                (tenant_id, school_id, exam_id, academic_class_id, subject_id, student_id,
                 enrolment_id, section, marks_obtained, is_absent, created_by, created_at)
            SELECT p_tenant_id, p_school_id, p_exam_id, p_academic_class_id, p_subject_id,
                   r.out_student_id, r.out_enrolment_id, v_section, NULL, TRUE,
                   p_action_user_id, now()
            FROM academic.fn_exam_sheet_roster(p_tenant_id, p_school_id, v_year_id, p_academic_class_id, v_section) r
            WHERE NOT EXISTS (SELECT 1 FROM academic.exam_marks m
                              WHERE m.exam_id    = p_exam_id
                                AND m.subject_id = p_subject_id
                                AND m.student_id = r.out_student_id);

            GET DIAGNOSTICS v_added = ROW_COUNT;

            -- A blank that was saved as a draft (or a mark cleared later) is just
            -- as unmarked: it is recorded Absent too.
            UPDATE academic.exam_marks m
               SET is_absent  = TRUE,
                   updated_by = p_action_user_id,
                   updated_at = now()
             WHERE m.exam_id    = p_exam_id
               AND m.subject_id = p_subject_id
               AND m.marks_obtained IS NULL
               AND NOT m.is_absent
               AND m.student_id IN (SELECT r.out_student_id
                                    FROM academic.fn_exam_sheet_roster(p_tenant_id, p_school_id, v_year_id,
                                                                       p_academic_class_id, v_section) r);

            GET DIAGNOSTICS v_blank = ROW_COUNT;
            v_added := v_added + v_blank;

            INSERT INTO academic.exam_mark_sheets
                (tenant_id, school_id, exam_id, academic_class_id, subject_id, section,
                 is_finalized, finalized_by, finalized_at)
            VALUES
                (p_tenant_id, p_school_id, p_exam_id, p_academic_class_id, p_subject_id, v_section,
                 TRUE, p_action_user_id, now())
            ON CONFLICT ON CONSTRAINT uq_exam_mark_sheets
            DO UPDATE SET is_finalized = TRUE,
                          finalized_by = p_action_user_id,
                          finalized_at = now();
        END IF;

        OPEN p_result FOR
        SELECT TRUE AS success,
               v_saved AS saved,
               v_added AS marked_absent,
               p_finalize AS is_finalized,
               CASE WHEN p_finalize
                    THEN 'Marks finalized and locked.'
                    ELSE 'Marks saved as draft.' END AS message;

        OPEN p_result2 FOR SELECT 1 WHERE FALSE;

    ELSIF p_operation = 'GetMarkScope' THEN

        -- The sheets of this exam the calling user teaches (2026-10-12):
        -- every subject of a section they are class teacher of, plus each
        -- subject the timetable gives them in a section. A teacher with only
        -- exams.marks is limited to these; the caller skips this for school
        -- admins and exams.manage (the proc cannot see roles).
        -- Sections are per session, so joining on the exam's class id keeps
        -- this to the exam's own academic year.
        OPEN p_result FOR
        SELECT DISTINCT es.academic_class_id,
               sec.section_name AS section,
               es.subject_id
        FROM academic.exam_subjects es
        JOIN academic.academic_class_sections sec
             ON sec.academic_class_id = es.academic_class_id
            AND sec.tenant_id = p_tenant_id
            AND sec.school_id = p_school_id
            AND COALESCE(sec.is_deleted, FALSE) = FALSE
        JOIN core.staff st
             ON st.tenant_id = p_tenant_id
            AND st.school_id = p_school_id
            AND st.user_id   = p_action_user_id
            -- A teacher who has left must not keep entering marks.
            AND COALESCE(st.is_active, TRUE)   = TRUE
            AND COALESCE(st.is_deleted, FALSE) = FALSE
        WHERE es.exam_id   = p_exam_id
          AND es.tenant_id = p_tenant_id
          AND es.school_id = p_school_id
          AND (sec.class_teacher_staff_id = st.staff_id
               OR EXISTS (SELECT 1 FROM academic.timetable t
                          WHERE t.academic_class_section_id = sec.academic_class_section_id
                            AND t.subject_id = es.subject_id
                            AND t.staff_id   = st.staff_id
                            AND t.tenant_id  = p_tenant_id
                            AND t.school_id  = p_school_id));

        OPEN p_result2 FOR SELECT 1 WHERE FALSE;

    ELSIF p_operation = 'ReopenSheet' THEN

        -- Admin-only; the caller enforces that (the proc cannot see roles).
        IF COALESCE(p_subject_id, 0) <= 0 THEN
            RAISE EXCEPTION 'Pick a subject first.';
        END IF;
        IF v_results = 'Published' THEN
            RAISE EXCEPTION 'The results of this exam are published. Unpublish the results before reopening a sheet.';
        END IF;

        UPDATE academic.exam_mark_sheets
           SET is_finalized = FALSE,
               reopened_by  = p_action_user_id,
               reopened_at  = now()
         WHERE exam_id           = p_exam_id
           AND academic_class_id = p_academic_class_id
           AND subject_id        = p_subject_id
           AND section           = v_section
           AND tenant_id        = p_tenant_id
           AND school_id        = p_school_id
           AND is_finalized;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'That sheet is not finalized.';
        END IF;

        OPEN p_result FOR SELECT TRUE AS success, 'Sheet reopened for editing.' AS message;
        OPEN p_result2 FOR SELECT 1 WHERE FALSE;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;


-- ============================================================================
-- Fee Head — cascade delete
--
-- Deleting a fee head must remove it from EVERYWHERE it is used, not just hide
-- the head. This proc force-removes the head and everything tied to it:
--   • core.school_fee_structure_details   — drop the head from every class structure
--   • core.school_fee_structures           — recompute each affected class's rollups
--   • core.student_fee_plan                — drop the head from every student's plan
--   • core.student_ledger                  — drop ALL the head's dues (paid + unpaid)
--   • core.school_fee_heads                — soft-delete the head itself
--
-- Receipts (core.fee_payments + core.fee_payment_details) are LEFT INTACT — they
-- store their own snapshot of the head name/amount and remain printable from
-- payment history. Only the live ledger/config is purged.
--
-- Which is exactly why a head whose dues have been paid, waived or refunded
-- cannot be deleted at all: the receipt would survive and point at a due that
-- had been purged. That case is refused up front and the school is told to
-- deactivate instead (see core.fn_fee_head_delete_guard in fee_head_identity.sql).
--
-- The ledger has no fee_head_id, so its rows are matched by fee_head_name (which
-- is unique per school). Rollups mirror the Fee Structure screen's formula:
--   annual = one_time + monthly*12 + quarterly*4 + half_yearly*2 + yearly
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

CREATE OR REPLACE PROCEDURE core.sp_fee_head_delete_cascade(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_fee_head_id    integer,
    INOUT p_result         refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_name        varchar(80);
    v_structs     integer[];
    v_struct_rows integer := 0;
    v_plan_rows   integer := 0;
    v_ledger_rows integer := 0;
    v_paid_rows   integer := 0;
    v_old_dues   integer;
    v_emptied     integer := 0;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR COALESCE(p_fee_head_id, 0) <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;

    SELECT fee_head_name INTO v_name
    FROM core.school_fee_heads
    WHERE fee_head_id = p_fee_head_id AND tenant_id = p_tenant_id AND school_id = p_school_id
      AND COALESCE(is_deleted, FALSE) = FALSE;

    IF v_name IS NULL THEN
        OPEN p_result FOR SELECT FALSE AS success, 'Fee head not found.' AS message;
        RETURN;
    END IF;

    -- Money already collected against this head stops the delete. Step 4 below
    -- purges the ledger, and the receipts in core.fee_payment_details are kept
    -- on purpose -- so purging a PAID due leaves a receipt pointing at a due
    -- that no longer exists, and the money can never be reconciled against what
    -- it was taken for. Deactivating keeps the history and stops the charge,
    -- which is what the school actually wants here.
    v_paid_rows := core.fn_fee_head_delete_guard(p_tenant_id, p_school_id, v_name);
    IF v_paid_rows > 0 THEN
        -- Name the way out. Refusing without one just moves the problem to whoever
        -- reads the message: cancelling a receipt reverses amount_paid and
        -- concession on the ledger (fee_receipt_cancel.sql), so once every receipt
        -- against this head is cancelled the delete goes through. A refund does NOT
        -- reverse -- fee_refund.sql only ever adds to refund_amount -- so a head
        -- that has been refunded can be deactivated but never deleted, and saying
        -- so beats letting someone cancel receipts all afternoon for nothing.
        OPEN p_result FOR
        SELECT FALSE AS success,
               format('"%s" cannot be deleted: %s due(s) still have money against them. Either mark it inactive (it stays on past records and stops being charged), or cancel the receipts collected against it and delete it then. A due that has been refunded cannot be cleared this way — that one can only be made inactive.',
                      v_name, v_paid_rows) AS message;
        RETURN;
    END IF;

    -- Unpaid dues of an EARLIER session are arrears the school is still owed.
    -- Deleting the head would wipe them with no trace, so that head can only be
    -- made inactive.
    SELECT COUNT(*) INTO v_old_dues
      FROM core.student_ledger l
     WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id AND l.fee_head_name = v_name
       AND l.amount_due - l.amount_paid - COALESCE(l.concession, 0) > 0
       AND l.academic_year IS DISTINCT FROM (SELECT y.academic_year_name FROM academic.academic_years y
                                              WHERE y.tenant_id = p_tenant_id AND y.school_id = p_school_id
                                                AND COALESCE(y.is_current, FALSE) AND NOT COALESCE(y.is_deleted, FALSE)
                                              LIMIT 1);
    IF v_old_dues > 0 THEN
        OPEN p_result FOR
        SELECT FALSE AS success,
               format('"%s" cannot be deleted: %s unpaid due(s) from an earlier session use it. Mark it inactive instead, so those arrears stay on record.',
                      v_name, v_old_dues) AS message;
        RETURN;
    END IF;

    -- Which class structures reference this head (need the ids before deleting).
    SELECT array_agg(DISTINCT fee_structure_id) INTO v_structs
    FROM core.school_fee_structure_details
    WHERE fee_head_id = p_fee_head_id AND tenant_id = p_tenant_id AND school_id = p_school_id;

    -- 1. Remove the head from every class fee structure.
    DELETE FROM core.school_fee_structure_details
    WHERE fee_head_id = p_fee_head_id AND tenant_id = p_tenant_id AND school_id = p_school_id;
    GET DIAGNOSTICS v_struct_rows = ROW_COUNT;

    -- 2. Recompute rollups for the affected structures from what remains.
    IF v_structs IS NOT NULL THEN
        UPDATE core.school_fee_structures fs
        SET one_time_total    = COALESCE(t.one_time, 0),
            monthly_total     = COALESCE(t.monthly, 0),
            quarterly_total   = COALESCE(t.quarterly, 0),
            half_yearly_total = COALESCE(t.half_yearly, 0),
            yearly_total      = COALESCE(t.yearly, 0),
            annual_total      = COALESCE(t.annual, 0),
            updated_by        = p_action_user_id,
            updated_at        = NOW()
        FROM (
            SELECT d.fee_structure_id,
                   SUM(d.amount) FILTER (WHERE lower(d.frequency) = 'one time')    AS one_time,
                   SUM(d.amount) FILTER (WHERE lower(d.frequency) = 'monthly')     AS monthly,
                   SUM(d.amount) FILTER (WHERE lower(d.frequency) = 'quarterly')   AS quarterly,
                   SUM(d.amount) FILTER (WHERE lower(d.frequency) = 'half yearly') AS half_yearly,
                   SUM(d.amount) FILTER (WHERE lower(d.frequency) NOT IN ('one time','monthly','quarterly','half yearly')) AS yearly,
                   ( COALESCE(SUM(d.amount) FILTER (WHERE lower(d.frequency) = 'one time'), 0)
                   + COALESCE(SUM(d.amount) FILTER (WHERE lower(d.frequency) = 'monthly'), 0) * 12
                   + COALESCE(SUM(d.amount) FILTER (WHERE lower(d.frequency) = 'quarterly'), 0) * 4
                   + COALESCE(SUM(d.amount) FILTER (WHERE lower(d.frequency) = 'half yearly'), 0) * 2
                   + COALESCE(SUM(d.amount) FILTER (WHERE lower(d.frequency) NOT IN ('one time','monthly','quarterly','half yearly')), 0)
                   ) AS annual
            FROM core.school_fee_structure_details d
            WHERE d.fee_structure_id = ANY(v_structs)
              -- Only live lines. A head dropped from a structure earlier is kept
              -- as a soft-deleted line; counting it put its amount back into the
              -- totals the moment any other head was deleted.
              AND COALESCE(d.is_deleted, FALSE) = FALSE
            GROUP BY d.fee_structure_id
        ) t
        WHERE fs.fee_structure_id = t.fee_structure_id;

        -- A structure whose last fee head just went is not a structure. Zeroing the
        -- totals and leaving it alive is what this used to do, and it left the class
        -- listed as configured while billing nothing -- seventeen of them on the live
        -- database, all from deleting one head that every class shared. Retire it
        -- instead, so the page shows the class as not set up, which is the truth.
        UPDATE core.school_fee_structures fs
        SET one_time_total = 0, monthly_total = 0, quarterly_total = 0,
            half_yearly_total = 0, yearly_total = 0, annual_total = 0,
            -- This table tracks a delete with is_deleted + updated_by; it has no
            -- deleted_by/deleted_at pair, unlike most others.
            is_deleted = TRUE, is_active = FALSE,
            updated_by = p_action_user_id, updated_at = NOW()
        WHERE fs.fee_structure_id = ANY(v_structs)
          AND COALESCE(fs.is_deleted, FALSE) = FALSE
          AND NOT EXISTS (
              SELECT 1 FROM core.school_fee_structure_details d
              WHERE d.fee_structure_id = fs.fee_structure_id
                AND COALESCE(d.is_deleted, FALSE) = FALSE);
        GET DIAGNOSTICS v_emptied = ROW_COUNT;
    END IF;

    -- 3. Remove the head from every student's frozen plan.
    DELETE FROM core.student_fee_plan
    WHERE tenant_id = p_tenant_id AND school_id = p_school_id
      AND (fee_head_id = p_fee_head_id OR fee_head_name = v_name);
    GET DIAGNOSTICS v_plan_rows = ROW_COUNT;

    -- 4. Remove ALL the head's dues from the ledger (paid + unpaid). Receipts are
    --    independent snapshots and are not touched.
    DELETE FROM core.student_ledger
    WHERE tenant_id = p_tenant_id AND school_id = p_school_id
      AND fee_head_name = v_name;
    GET DIAGNOSTICS v_ledger_rows = ROW_COUNT;

    -- 5. Soft-delete the head itself.
    UPDATE core.school_fee_heads
    SET is_deleted = TRUE, is_active = FALSE, updated_by = p_action_user_id, updated_at = NOW()
    WHERE fee_head_id = p_fee_head_id AND tenant_id = p_tenant_id AND school_id = p_school_id;

    OPEN p_result FOR
    SELECT TRUE AS success,
           format('"%s" deleted — removed from %s structure row(s), %s plan row(s) and %s ledger due(s).%s',
                  v_name, v_struct_rows, v_plan_rows, v_ledger_rows,
                  CASE WHEN v_emptied > 0
                       THEN format(' %s class fee structure(s) had no other head and were retired.', v_emptied)
                       ELSE '' END) AS message,
           v_struct_rows AS structure_rows,
           v_plan_rows   AS plan_rows,
           v_ledger_rows AS ledger_rows;
END;
$procedure$;


-- ============================================================================
-- Fee Head: the name is the identity, so protect it.
--
-- core.student_ledger carries fee_head_name and NO fee_head_id (see
-- fee_head_cascade_delete.sql, which matches on the name for exactly that
-- reason). The name is therefore the join key for every due, every receipt line
-- and every report -- the same shape that class_name has, and the same three
-- problems:
--
--   1. Uniqueness was case-sensitive, so "Tuition Fee" and "tuition fee" were
--      two heads writing two sets of ledger rows that read identically on
--      screen and never added up together in a report.
--   2. Renaming a head left every row already written under the old name
--      behind, splitting one fee into two everywhere.
--   3. Deleting a head purged its dues INCLUDING the paid ones, leaving
--      receipts pointing at dues that no longer exist.
--
-- Safe to re-run. Step 1 refuses to create the index if case-duplicates exist
-- and names them, rather than failing halfway.
-- ============================================================================

-- ── 1. Uniqueness becomes case-insensitive ─────────────────────────────────
DO $ix$
DECLARE
    v_dups text;
BEGIN
    SELECT string_agg(format('%s (tenant %s, school %s, %s copies)',
                             lower(fee_head_name), tenant_id, school_id, n), '; ')
      INTO v_dups
    FROM (
        SELECT tenant_id, school_id, lower(fee_head_name) AS fee_head_name, count(*) AS n
          FROM core.school_fee_heads
         WHERE COALESCE(is_deleted, FALSE) = FALSE
         GROUP BY 1, 2, 3
        HAVING count(*) > 1) d;

    IF v_dups IS NOT NULL THEN
        -- Merging them is not a blind UPDATE: each one may already own ledger
        -- rows, so a human has to decide which name survives.
        RAISE WARNING 'Index NOT created, these names differ only by case: %', v_dups;
    ELSE
        DROP INDEX IF EXISTS core.uq_school_fee_heads_name;
        CREATE UNIQUE INDEX IF NOT EXISTS uq_school_fee_heads_name
            ON core.school_fee_heads (tenant_id, school_id, lower(fee_head_name))
            WHERE COALESCE(is_deleted, FALSE) = FALSE;
    END IF;
END
$ix$;


-- ── 2. Save: a rename carries the name with it ─────────────────────────────
-- p_display_order is gone, which is a new signature, so the old overload has to
-- go or calls fail with "procedure is not unique".
DROP PROCEDURE IF EXISTS core.sp_school_admin_fee_head_manage(
    character varying, integer, integer, integer, integer, character varying,
    character varying, numeric, character varying, character varying,
    character varying, boolean, integer, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_school_admin_fee_head_manage(
    IN    p_operation        character varying,
    IN    p_tenant_id        integer,
    IN    p_school_id        integer,
    IN    p_action_user_id   integer,
    IN    p_fee_head_id      integer   DEFAULT 0,
    IN    p_fee_head_name    character varying DEFAULT NULL::character varying,
    IN    p_frequency        character varying DEFAULT NULL::character varying,
    IN    p_default_amount   numeric   DEFAULT 0,
    IN    p_fee_type         character varying DEFAULT NULL::character varying,
    IN    p_fee_group        character varying DEFAULT 'Academic'::character varying,
    IN    p_collection_point character varying DEFAULT 'Recurring'::character varying,
    IN    p_is_refundable    boolean   DEFAULT false,
    INOUT p_result           refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_billed_ahead integer;
    v_name      varchar(80);
    v_old_name  varchar(80);
    v_moved     integer := 0;
    v_n         integer;
    v_active    boolean;
    v_freq      varchar(30);
    v_old_freq  varchar(30);
    v_clash     text;
    v_type      varchar(30);
    v_restruct  integer := 0;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    IF p_operation = 'GetFeeHead' THEN

        -- Inactive heads are returned too: this is the master list, and callers
        -- that must not charge an inactive head filter on is_active themselves
        -- (the fee-structure picker, the admission fee list). Dropping them here
        -- would break the by-id enrichment that gives a saved structure row its
        -- collection point.
        OPEN p_result FOR
        SELECT
            fee_head_id, tenant_id, school_id, fee_head_name, frequency,
            COALESCE(default_amount, 0) AS default_amount,
            fee_type, fee_group,
            COALESCE(collection_point, 'Recurring') AS collection_point,
            COALESCE(is_refundable, FALSE) AS is_refundable,
            COALESCE(is_active, TRUE) AS is_active
        FROM core.school_fee_heads
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND COALESCE(is_deleted, FALSE) = FALSE
        ORDER BY fee_head_name;

    ELSIF p_operation = 'GetFeeHeadById' THEN

        OPEN p_result FOR
        SELECT
            fee_head_id, tenant_id, school_id, fee_head_name, frequency,
            COALESCE(default_amount, 0) AS default_amount,
            fee_type, fee_group,
            COALESCE(collection_point, 'Recurring') AS collection_point,
            COALESCE(is_refundable, FALSE) AS is_refundable,
            COALESCE(is_active, TRUE) AS is_active
        FROM core.school_fee_heads
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND fee_head_id = p_fee_head_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

    ELSIF p_operation = 'SaveFeeHead' THEN

        v_name := trim(COALESCE(p_fee_head_name, ''));
        IF v_name = '' THEN
            RAISE EXCEPTION 'Fee head name is required.';
        END IF;

        -- The name is the join key, so a negative amount or an unknown cycle
        -- would be written straight into every student's ledger.
        IF COALESCE(p_default_amount, 0) < 0 THEN
            RAISE EXCEPTION 'Amount for "%" cannot be negative.', v_name;
        END IF;
        -- Validate AND store the canonical spelling. Every reader matches the
        -- cycle by exact text (the Fee Structure page groups on "Monthly" etc.),
        -- so " monthly " used to pass here and then vanish from that page.
        v_freq := CASE lower(trim(COALESCE(p_frequency, '')))
                      WHEN 'one time'    THEN 'One Time'
                      WHEN 'monthly'     THEN 'Monthly'
                      WHEN 'quarterly'   THEN 'Quarterly'
                      WHEN 'half yearly' THEN 'Half Yearly'
                      WHEN 'yearly'      THEN 'Yearly'
                  END;
        IF v_freq IS NULL THEN
            RAISE EXCEPTION 'Unknown billing cycle "%" for "%".', p_frequency, v_name;
        END IF;

        -- Mandatory / Optional drives the summary tiles and which heads the
        -- Fee Structure page ticks by default; anything else is neither.
        v_type := CASE lower(trim(COALESCE(p_fee_type, '')))
                      WHEN 'mandatory' THEN 'Mandatory'
                      WHEN 'optional'  THEN 'Optional'
                  END;
        IF v_type IS NULL THEN
            RAISE EXCEPTION 'Fee type for "%" must be Mandatory or Optional.', v_name;
        END IF;
        IF COALESCE(p_collection_point, 'Recurring') NOT IN
               ('Registration', 'Admission', 'Recurring') THEN
            RAISE EXCEPTION 'Unknown collection point "%" for "%".', p_collection_point, v_name;
        END IF;

        -- Only on a RENAME. Saving a NEW head under an existing name stays an
        -- upsert on purpose (settings_tests C4): it revives a head someone had
        -- deleted instead of complaining about a row the user cannot see. What
        -- must never happen is renaming head A onto head B's name -- that used
        -- to reach the unique index and come back as a raw 500.
        IF COALESCE(p_fee_head_id, 0) > 0 AND EXISTS (
            SELECT 1 FROM core.school_fee_heads
             WHERE tenant_id = p_tenant_id AND school_id = p_school_id
               AND COALESCE(is_deleted, FALSE) = FALSE
               AND lower(fee_head_name) = lower(v_name)
               AND fee_head_id <> p_fee_head_id
        ) THEN
            RAISE EXCEPTION 'A fee head named "%" already exists.', v_name;
        END IF;

        -- The create-form upsert above is only safe when the existing head is
        -- the same KIND of charge. The Admission Workflow fee cards send id 0
        -- plus a typed name, so typing "Admission Fee" on the deposit card used
        -- to turn the real Admission Fee into a refundable deposit (and "Tution
        -- Fee" on the registration card made tuition one-time). A same-name head
        -- at a different collection point, or refundable where the existing one
        -- is not (or the other way round), is a different charge: refuse.
        IF COALESCE(p_fee_head_id, 0) = 0 THEN
            SELECT CASE WHEN COALESCE(is_refundable, FALSE) THEN 'refundable ' ELSE '' END
                   || collection_point
              INTO v_clash
              FROM core.school_fee_heads
             WHERE tenant_id = p_tenant_id AND school_id = p_school_id
               AND COALESCE(is_deleted, FALSE) = FALSE
               AND lower(trim(fee_head_name)) = lower(v_name)
               AND (collection_point IS DISTINCT FROM COALESCE(p_collection_point, 'Recurring')
                    OR COALESCE(is_refundable, FALSE) <> COALESCE(p_is_refundable, FALSE))
             LIMIT 1;
            IF FOUND THEN
                RAISE EXCEPTION 'A fee head called "%" already exists as a % charge. Please use a different name.',
                                v_name, v_clash;
            END IF;
        END IF;

        IF COALESCE(p_fee_head_id, 0) > 0 THEN

            SELECT fee_head_name, frequency INTO v_old_name, v_old_freq
            FROM core.school_fee_heads
            WHERE tenant_id = p_tenant_id AND school_id = p_school_id
              AND fee_head_id = p_fee_head_id
              AND COALESCE(is_deleted, FALSE) = FALSE;

            IF v_old_name IS NULL THEN
                OPEN p_result FOR SELECT FALSE AS success, 'Fee head not found.' AS message;
                RETURN;
            END IF;

            UPDATE core.school_fee_heads
            SET fee_head_name    = v_name,
                frequency        = v_freq,
                default_amount   = COALESCE(p_default_amount, 0),
                fee_type         = v_type,
                fee_group        = COALESCE(p_fee_group, 'Academic'),
                collection_point = COALESCE(p_collection_point, 'Recurring'),
                is_refundable    = COALESCE(p_is_refundable, FALSE),
                updated_by       = p_action_user_id,
                updated_at       = NOW()
            WHERE tenant_id = p_tenant_id AND school_id = p_school_id
              AND fee_head_id = p_fee_head_id
              AND COALESCE(is_deleted, FALSE) = FALSE;

            -- Carry the rename into everything already written under the old
            -- name. Without this a typo fix ("Tution" -> "Tuition") leaves the
            -- old rows behind and every report shows one fee as two. Only the
            -- label moves; no amount is touched.
            IF v_old_name IS DISTINCT FROM v_name THEN
                UPDATE core.student_ledger SET fee_head_name = v_name
                 WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                   AND fee_head_name = v_old_name;
                GET DIAGNOSTICS v_n = ROW_COUNT; v_moved := v_moved + v_n;

                UPDATE core.student_fee_plan SET fee_head_name = v_name
                 WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                   AND fee_head_name = v_old_name;
                GET DIAGNOSTICS v_n = ROW_COUNT; v_moved := v_moved + v_n;

                UPDATE core.school_fee_structure_details SET fee_head_name = v_name
                 WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                   AND fee_head_name = v_old_name;
                GET DIAGNOSTICS v_n = ROW_COUNT; v_moved := v_moved + v_n;

                -- Receipt lines move too. A receipt is a snapshot of amounts,
                -- not of spelling, and leaving them behind is what splits a
                -- collection report down the middle.
                -- Only THIS school's receipts: the detail table has no tenant
                -- column, so scope it through its receipt header. Unscoped, a
                -- rename here rewrote every school's receipts with that name.
                UPDATE core.fee_payment_details d SET fee_head_name = v_name
                  FROM core.fee_payments p
                 WHERE p.payment_id = d.payment_id
                   AND p.tenant_id = p_tenant_id AND p.school_id = p_school_id
                   AND d.fee_head_name = v_old_name;
                GET DIAGNOSTICS v_n = ROW_COUNT; v_moved := v_moved + v_n;
            END IF;

            -- A new billing cycle has to reach the class structures that already
            -- carry this head. Admission bills from the structure line's cycle,
            -- so leaving it behind kept billing the old cycle while the page
            -- showed the new one. Ledgers already written stay as they are
            -- (they are frozen at admission); only future admissions change.
            IF v_old_freq IS DISTINCT FROM v_freq THEN
                UPDATE core.school_fee_structure_details SET frequency = v_freq,
                       updated_by = p_action_user_id, updated_at = NOW()
                 WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                   AND fee_head_id = p_fee_head_id;

                -- Re-derive the rollups of every structure that holds the head,
                -- from its live lines, the same way the save computes them.
                UPDATE core.school_fee_structures fs
                SET one_time_total    = t.one_time,
                    monthly_total     = t.monthly,
                    quarterly_total   = t.quarterly,
                    half_yearly_total = t.half_yearly,
                    yearly_total      = t.yearly,
                    annual_total      = t.one_time + t.monthly * 12 + t.quarterly * 4
                                      + t.half_yearly * 2 + t.yearly,
                    updated_by        = p_action_user_id,
                    updated_at        = NOW()
                FROM (
                    SELECT d.fee_structure_id,
                           COALESCE(SUM(d.amount) FILTER (WHERE lower(d.frequency) = 'one time'), 0)    AS one_time,
                           COALESCE(SUM(d.amount) FILTER (WHERE lower(d.frequency) = 'monthly'), 0)     AS monthly,
                           COALESCE(SUM(d.amount) FILTER (WHERE lower(d.frequency) = 'quarterly'), 0)   AS quarterly,
                           COALESCE(SUM(d.amount) FILTER (WHERE lower(d.frequency) = 'half yearly'), 0) AS half_yearly,
                           COALESCE(SUM(d.amount) FILTER (WHERE lower(d.frequency) NOT IN
                                    ('one time','monthly','quarterly','half yearly')), 0)                AS yearly
                      FROM core.school_fee_structure_details d
                     WHERE d.tenant_id = p_tenant_id AND d.school_id = p_school_id
                       AND COALESCE(d.is_deleted, FALSE) = FALSE
                       AND d.fee_structure_id IN (
                           SELECT fee_structure_id FROM core.school_fee_structure_details
                            WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                              AND fee_head_id = p_fee_head_id
                              AND COALESCE(is_deleted, FALSE) = FALSE)
                     GROUP BY d.fee_structure_id
                ) t
                WHERE fs.fee_structure_id = t.fee_structure_id
                  AND COALESCE(fs.is_deleted, FALSE) = FALSE;
                GET DIAGNOSTICS v_restruct = ROW_COUNT;
            END IF;

        ELSE
            INSERT INTO core.school_fee_heads
                (tenant_id, school_id, fee_head_name, frequency, default_amount,
                 fee_type, fee_group, collection_point, is_refundable,
                 is_active, is_deleted, created_by, created_at)
            VALUES
                (p_tenant_id, p_school_id, v_name, v_freq, COALESCE(p_default_amount, 0),
                 v_type, COALESCE(p_fee_group, 'Academic'),
                 COALESCE(p_collection_point, 'Recurring'), COALESCE(p_is_refundable, FALSE),
                 TRUE, FALSE, p_action_user_id, NOW())
            ON CONFLICT (tenant_id, school_id, lower(fee_head_name))
                WHERE COALESCE(is_deleted, FALSE) = FALSE
            DO UPDATE SET
                frequency        = EXCLUDED.frequency,
                default_amount   = EXCLUDED.default_amount,
                fee_type         = EXCLUDED.fee_type,
                fee_group        = EXCLUDED.fee_group,
                collection_point = EXCLUDED.collection_point,
                is_refundable    = EXCLUDED.is_refundable,
                is_active        = TRUE,
                is_deleted       = FALSE,
                updated_by       = p_action_user_id,
                updated_at       = NOW();
        END IF;

        OPEN p_result FOR
        SELECT TRUE AS success,
               CASE WHEN v_moved > 0
                    THEN format('"%s" saved — renamed from "%s" on %s existing row(s).',
                                v_name, v_old_name, v_moved)
                    ELSE format('"%s" saved.', v_name)
               END
               || CASE WHEN v_restruct > 0
                       THEN format(' Billing cycle changed to %s on %s class fee structure(s); students already admitted keep their existing dues.',
                                   v_freq, v_restruct)
                       ELSE '' END AS message;

    ELSIF p_operation = 'ToggleFeeHeadStatus' THEN

        UPDATE core.school_fee_heads
        SET is_active  = NOT COALESCE(is_active, TRUE),
            updated_by = p_action_user_id,
            updated_at = NOW()
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND fee_head_id = p_fee_head_id
          AND COALESCE(is_deleted, FALSE) = FALSE
        RETURNING fee_head_name, is_active INTO v_name, v_active;

        IF v_name IS NULL THEN
            OPEN p_result FOR SELECT FALSE AS success, 'Fee head not found.' AS message;
            RETURN;
        END IF;

        -- Say which way it went. "Status updated" told the user nothing, and
        -- this flag now actually stops the head being charged. Instalments ALREADY
        -- billed to students are not removed, and the message says so.
        SELECT COUNT(*) INTO v_billed_ahead
          FROM core.student_ledger l
         WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id AND l.fee_head_name = v_name
           AND l.due_date IS NOT NULL AND l.due_date::date > CURRENT_DATE
           AND l.amount_due - l.amount_paid - COALESCE(l.concession, 0) > 0;
        OPEN p_result FOR
        SELECT TRUE AS success,
               CASE WHEN v_active
                    THEN format('"%s" is active again and will be charged on new admissions.', v_name)
                    ELSE format('"%s" is now inactive — new admissions and class changes will not be charged it.', v_name)
                         || CASE WHEN v_billed_ahead > 0
                                 THEN format(' %s instalment(s) already billed to students for later months stay due; waive them at Collect Fees if they should not be paid.', v_billed_ahead)
                                 ELSE '' END
               END AS message;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;


-- ── 3. Delete: never purge a due that money has touched ────────────────────
-- The cascade itself is deliberate (see fee_head_cascade_delete.sql) -- a head
-- removed from the master must leave the structures and plans too. What it must
-- not do is delete a due that has been paid, waived or refunded: the receipt in
-- core.fee_payment_details survives and would point at nothing, so the money
-- collected can no longer be reconciled against what it was collected for.
-- Deactivating is the answer there, and the message says so.
CREATE OR REPLACE FUNCTION core.fn_fee_head_delete_guard(
    p_tenant_id integer, p_school_id integer, p_name varchar)
RETURNS integer
LANGUAGE sql STABLE AS $$
    SELECT COUNT(*)::integer
      FROM core.student_ledger
     WHERE tenant_id = p_tenant_id AND school_id = p_school_id
       AND fee_head_name = p_name
       AND (COALESCE(amount_paid, 0) > 0
         OR COALESCE(concession, 0) > 0
         OR COALESCE(refund_amount, 0) > 0);
$$;

COMMENT ON FUNCTION core.fn_fee_head_delete_guard(integer, integer, varchar) IS
    'How many of this fee head''s dues have money against them. Non-zero means the head cannot be deleted, only deactivated.';


-- ── 4. display_order goes ──────────────────────────────────────────────────
-- Stored, passed through every layer, and never once set: 22 heads on Railway,
-- one distinct value, nothing non-zero, no input anywhere on the page. The only
-- ORDER BY on it therefore sorted by name in practice, which is what the
-- procedures now say out loud. Kept "in case", it is the same dead weight as
-- registration_fee_amount sitting at 0.00 long after the amounts moved.
ALTER TABLE core.school_fee_heads DROP COLUMN IF EXISTS display_order;


-- ── 5. Billing cycles in their one canonical spelling ──────────────────────
-- The save used to validate lower(trim(cycle)) but store whatever was typed, so
-- " monthly " could reach the table. The Fee Structure page files heads by the
-- exact text and skipped such a head, which also left a hole in the posted
-- FeeHeads[i] indexes and dropped every head after it on save. The save now
-- stores the canonical form; this brings any older rows into line.
-- Safe to re-run: it only touches rows that are not already canonical.
UPDATE core.school_fee_heads
   SET frequency = CASE lower(trim(frequency))
                       WHEN 'one time'    THEN 'One Time'
                       WHEN 'monthly'     THEN 'Monthly'
                       WHEN 'quarterly'   THEN 'Quarterly'
                       WHEN 'half yearly' THEN 'Half Yearly'
                       WHEN 'yearly'      THEN 'Yearly'
                   END
 WHERE lower(trim(frequency)) IN ('one time','monthly','quarterly','half yearly','yearly')
   AND frequency NOT IN ('One Time','Monthly','Quarterly','Half Yearly','Yearly');

UPDATE core.school_fee_structure_details
   SET frequency = CASE lower(trim(frequency))
                       WHEN 'one time'    THEN 'One Time'
                       WHEN 'monthly'     THEN 'Monthly'
                       WHEN 'quarterly'   THEN 'Quarterly'
                       WHEN 'half yearly' THEN 'Half Yearly'
                       WHEN 'yearly'      THEN 'Yearly'
                   END
 WHERE lower(trim(frequency)) IN ('one time','monthly','quarterly','half yearly','yearly')
   AND frequency NOT IN ('One Time','Monthly','Quarterly','Half Yearly','Yearly');


-- ============================================================================
-- School Calendar — which days the school actually runs.
--
-- Two pieces:
--   academic.school_calendar_settings   weekly off days (default Sunday only)
--   academic.school_calendar            dated overrides: holiday | half_day | working
--
-- An explicit dated entry always beats the weekly-off rule, so a school can
-- declare "this Saturday IS working" or "second Saturday is off" without
-- touching the weekly pattern.
--
--   academic.sp_school_admin_calendar_manage
--     GetCalendar    (date range)  -> cursor1 entries, cursor2 weekly-off csv
--     GetDayStatus   (one date)    -> resolved status for that day
--     SaveEntry      (upsert one dated override)
--     SaveRange      (p_date..p_to_date: one entry per day; days that already
--                     have an entry are skipped and reported; a holiday or half
--                     day range also skips the weekly offs)
--     DeleteEntry
--     DeleteRange    (every entry between p_date and p_to_date)
--     SaveWeeklyOff
--
-- Consumed by the Smart Bell (suppresses bells on non-working days, ends the
-- day early on half days) and the School Calendar settings page.
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

CREATE TABLE IF NOT EXISTS academic.school_calendar_settings (
    tenant_id       integer  NOT NULL,
    school_id       integer  NOT NULL,
    weekly_off_days smallint[] NOT NULL DEFAULT '{0}',   -- 0 = Sunday … 6 = Saturday
    updated_by      integer,
    updated_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT pk_school_calendar_settings PRIMARY KEY (tenant_id, school_id)
);

CREATE TABLE IF NOT EXISTS academic.school_calendar (
    calendar_id   serial PRIMARY KEY,
    tenant_id     integer NOT NULL,
    school_id     integer NOT NULL,
    calendar_date date    NOT NULL,
    day_type      varchar(20) NOT NULL,     -- holiday | half_day | working
    title         varchar(100) NOT NULL,
    half_day_end  time,                     -- half_day only: bells stop after this
    created_by    integer,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    integer,
    updated_at    timestamptz,

    CONSTRAINT chk_school_calendar_type CHECK (day_type IN ('holiday', 'half_day', 'working')),
    CONSTRAINT uq_school_calendar_day   UNIQUE (tenant_id, school_id, calendar_date)
);

CREATE INDEX IF NOT EXISTS ix_school_calendar_date
    ON academic.school_calendar (tenant_id, school_id, calendar_date);


-- What kind of day a date is for one school: 'holiday' | 'weekly_off' |
-- 'half_day' | 'working'. A dated entry beats the weekly pattern in both
-- directions. GetDayStatus below answers the same question for the Smart Bell;
-- attendance and exam scheduling call this so all three agree.
CREATE OR REPLACE FUNCTION academic.fn_school_day_type(
    p_tenant_id integer, p_school_id integer, p_date date)
RETURNS text
LANGUAGE sql
STABLE
AS $function$
    SELECT COALESCE(
        (SELECT c.day_type FROM academic.school_calendar c
         WHERE c.tenant_id = p_tenant_id AND c.school_id = p_school_id
           AND c.calendar_date = to_char(p_date, 'YYYY-MM-DD')),
        CASE WHEN EXTRACT(DOW FROM p_date)::smallint = ANY (
                 COALESCE((SELECT s.weekly_off_days FROM academic.school_calendar_settings s
                           WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id),
                          '{0}'::smallint[]))
             THEN 'weekly_off' ELSE 'working' END);
$function$;


CREATE OR REPLACE PROCEDURE academic.sp_school_admin_calendar_manage(
    IN    p_operation      character varying,
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_calendar_id    integer   DEFAULT NULL,
    IN    p_date           date      DEFAULT NULL,
    IN    p_to_date        date      DEFAULT NULL,
    IN    p_day_type       character varying DEFAULT NULL,
    IN    p_title          character varying DEFAULT NULL,
    IN    p_half_day_end   time      DEFAULT NULL,
    IN    p_weekly_off     character varying DEFAULT NULL,   -- csv, e.g. '0,6'
    INOUT p_result         refcursor DEFAULT 'calendar_cursor'::refcursor,
    INOUT p_result2        refcursor DEFAULT 'calendar_cursor2'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_type       text;
    v_title      text;
    v_offs       smallint[];
    v_dow        smallint;
    v_entry      academic.school_calendar%ROWTYPE;
    v_day_type   text;
    v_day_title  text;
    v_is_working boolean;
    v_half_end   time;
    v_to         date;
    v_day        date;
    v_created    integer := 0;
    v_had_entry  integer := 0;
    v_off_days   integer := 0;
    v_open_days  integer := 0;
    v_had_list   text := '';
    v_first      time;
    v_last       time;
    v_n          integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    -- ---------------------------------------------------------------- read --
    IF p_operation = 'GetCalendar' THEN

        OPEN p_result FOR
        SELECT
            calendar_id,
            to_char(calendar_date::date, 'YYYY-MM-DD')     AS calendar_date,
            day_type,
            title,
            to_char(half_day_end, 'HH24:MI')         AS half_day_end
        FROM academic.school_calendar
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND calendar_date::date >= COALESCE(p_date,    date_trunc('year', CURRENT_DATE)::date)
          AND calendar_date::date <= COALESCE(p_to_date, (date_trunc('year', CURRENT_DATE) + interval '1 year - 1 day')::date)
        ORDER BY calendar_date;

        OPEN p_result2 FOR
        SELECT COALESCE(
            (SELECT array_to_string(weekly_off_days, ',')
             FROM academic.school_calendar_settings
             WHERE tenant_id = p_tenant_id AND school_id = p_school_id),
            '0') AS weekly_off_days;

    ELSIF p_operation = 'GetDayStatus' THEN

        -- Resolve one date the way the bell should see it.
        v_dow := EXTRACT(DOW FROM COALESCE(p_date, CURRENT_DATE))::smallint;   -- 0 = Sunday

        SELECT COALESCE(weekly_off_days, '{0}') INTO v_offs
        FROM academic.school_calendar_settings
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id;
        IF v_offs IS NULL THEN
            v_offs := '{0}';                       -- unconfigured school: Sunday off
        END IF;

        SELECT * INTO v_entry
        FROM academic.school_calendar
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND calendar_date::date = COALESCE(p_date, CURRENT_DATE);

        IF FOUND THEN
            -- A dated entry overrides the weekly pattern in both directions.
            v_day_type  := v_entry.day_type;
            v_day_title := v_entry.title;
            v_half_end  := v_entry.half_day_end;
            v_is_working := v_entry.day_type <> 'holiday';
            IF v_entry.day_type = 'working' THEN
                v_day_type := 'working';
            END IF;
        ELSIF v_dow = ANY (v_offs) THEN
            v_day_type   := 'weekly_off';
            v_day_title  := trim(to_char(COALESCE(p_date, CURRENT_DATE), 'Day'));
            v_is_working := FALSE;
        ELSE
            v_day_type   := 'working';
            v_day_title  := '';
            v_is_working := TRUE;
        END IF;

        OPEN p_result FOR
        SELECT
            to_char(COALESCE(p_date, CURRENT_DATE), 'YYYY-MM-DD') AS calendar_date,
            v_dow                          AS day_of_week,
            v_day_type                     AS day_type,
            COALESCE(v_day_title, '')      AS title,
            to_char(v_half_end, 'HH24:MI') AS half_day_end,
            v_is_working                   AS is_working;

        OPEN p_result2 FOR SELECT array_to_string(v_offs, ',') AS weekly_off_days;

    -- --------------------------------------------------------------- write --
    ELSIF p_operation IN ('SaveEntry', 'SaveRange') THEN

        -- SaveEntry writes one date (and replaces what was there). SaveRange
        -- writes every date from p_date to p_to_date as its own entry, and leaves
        -- a date that already has an entry alone, so a range never silently
        -- overwrites a half day or a working Saturday someone set by hand.
        IF p_date IS NULL THEN
            RAISE EXCEPTION 'Pick a date first.';
        END IF;

        v_to := CASE WHEN p_operation = 'SaveRange' THEN COALESCE(p_to_date, p_date) ELSE p_date END;
        IF v_to < p_date THEN
            RAISE EXCEPTION 'The range ends before it starts.';
        END IF;
        IF v_to - p_date > 366 THEN
            RAISE EXCEPTION 'A range can cover at most one year.';
        END IF;

        v_type  := lower(trim(COALESCE(p_day_type, 'holiday')));
        IF v_type NOT IN ('holiday', 'half_day', 'working') THEN
            RAISE EXCEPTION 'Unknown day type "%".', v_type;
        END IF;

        v_title := trim(COALESCE(p_title, ''));
        IF v_title = '' THEN
            v_title := CASE v_type
                         WHEN 'holiday'  THEN 'Holiday'
                         WHEN 'half_day' THEN 'Half Day'
                         ELSE 'Working Day'
                       END;
        END IF;

        IF v_type = 'half_day' AND p_half_day_end IS NULL THEN
            RAISE EXCEPTION 'A half day needs a closing time.';
        END IF;

        SELECT COALESCE(weekly_off_days, '{0}') INTO v_offs
        FROM academic.school_calendar_settings
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id;
        IF v_offs IS NULL THEN
            v_offs := '{0}';
        END IF;

        v_day := p_date;
        WHILE v_day <= v_to LOOP

            IF p_operation = 'SaveRange' AND EXISTS (
                   SELECT 1 FROM academic.school_calendar
                   WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                     AND calendar_date::date = v_day) THEN
                v_had_entry := v_had_entry + 1;
                IF v_had_entry <= 10 THEN
                    v_had_list := v_had_list || CASE WHEN v_had_list = '' THEN '' ELSE ', ' END
                                  || to_char(v_day, 'FMDD Mon');
                END IF;

            -- A closed day needs no holiday, and a half day on one would turn it
            -- into a working day. A working-day range is the way to open them.
            ELSIF p_operation = 'SaveRange' AND v_type <> 'working'
                  AND EXTRACT(DOW FROM v_day)::smallint = ANY (v_offs) THEN
                v_off_days := v_off_days + 1;

            -- A working-day override only means something on a weekly off; on a
            -- normal weekday it changes nothing, so refuse it (one date) or skip
            -- that day (a range).
            ELSIF v_type = 'working'
                  AND NOT (EXTRACT(DOW FROM v_day)::smallint = ANY (v_offs)) THEN
                IF p_operation = 'SaveEntry' THEN
                    RAISE EXCEPTION '% is already a working day. A working-day override is only for a weekly off.',
                        to_char(v_day, 'FMDay, FMDD Mon');
                END IF;
                v_open_days := v_open_days + 1;

            ELSE
                -- The closing time has to fall inside that day's bell schedule, or
                -- the bell either never rings (before the first period) or the
                -- half day changes nothing. A short Saturday has its own hours.
                IF v_type = 'half_day' THEN
                    SELECT MIN(start_time), MAX(end_time) INTO v_first, v_last
                    FROM academic.fn_day_periods(p_tenant_id, p_school_id, EXTRACT(DOW FROM v_day)::smallint);
                    IF v_first IS NOT NULL AND (p_half_day_end <= v_first OR p_half_day_end >= v_last) THEN
                        RAISE EXCEPTION 'A half day must close during the school day (between % and % on %).',
                            to_char(v_first, 'HH24:MI'), to_char(v_last, 'HH24:MI'), to_char(v_day, 'FMDay, FMDD Mon');
                    END IF;
                END IF;

                -- A day whose attendance was taken WAS a school day. Making it a holiday
                -- afterwards left those marks counted in the student % but not in the
                -- registers expected, and the day could no longer be corrected.
                IF v_type = 'holiday' AND EXISTS (
                       SELECT 1 FROM core.student_attendance a
                        WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
                          AND a.attendance_date::date = v_day) THEN
                    RAISE EXCEPTION 'Attendance was already taken on %, so it was a school day and cannot be made a holiday.',
                        to_char(v_day, 'FMDay, FMDD Mon YYYY');
                END IF;

                INSERT INTO academic.school_calendar
                    (tenant_id, school_id, calendar_date, day_type, title, half_day_end, created_by, created_at)
                VALUES
                    (p_tenant_id, p_school_id, v_day, v_type, v_title,
                     CASE WHEN v_type = 'half_day' THEN p_half_day_end ELSE NULL END,
                     p_action_user_id, now())
                ON CONFLICT (tenant_id, school_id, calendar_date) DO UPDATE
                    SET day_type     = EXCLUDED.day_type,
                        title        = EXCLUDED.title,
                        half_day_end = EXCLUDED.half_day_end,
                        updated_by   = p_action_user_id,
                        updated_at   = now();
                v_created := v_created + 1;
            END IF;

            v_day := v_day + 1;
        END LOOP;

        IF p_operation = 'SaveEntry' THEN
            OPEN p_result FOR SELECT TRUE AS success, 'Calendar updated.' AS message;
        ELSE
            IF v_created = 0 THEN
                RAISE EXCEPTION 'Nothing was added: every day from % to % already has an entry or %.',
                    to_char(p_date, 'FMDD Mon YYYY'), to_char(v_to, 'FMDD Mon YYYY'),
                    CASE WHEN v_type = 'working' THEN 'is already a working day' ELSE 'is a weekly off' END;
            END IF;

            OPEN p_result FOR
            SELECT TRUE AS success,
                   v_created   AS created,
                   v_had_entry AS skipped_existing,
                   v_off_days  AS skipped_weekly_off,
                   v_created || CASE WHEN v_created = 1 THEN ' day' ELSE ' days' END || ' marked.'
                   || CASE WHEN v_had_entry > 0
                           THEN ' Skipped ' || v_had_entry || ' that already had an entry (' || v_had_list
                                || CASE WHEN v_had_entry > 10 THEN ', ...' ELSE '' END || ').'
                           ELSE '' END
                   || CASE WHEN v_off_days > 0
                           THEN ' Skipped ' || v_off_days || ' weekly off' || CASE WHEN v_off_days = 1 THEN '' ELSE 's' END || '.'
                           ELSE '' END
                   || CASE WHEN v_open_days > 0
                           THEN ' Skipped ' || v_open_days || ' day' || CASE WHEN v_open_days = 1 THEN '' ELSE 's' END
                                || ' that ' || CASE WHEN v_open_days = 1 THEN 'is' ELSE 'are' END || ' already a working day.'
                           ELSE '' END AS message;
        END IF;
        OPEN p_result2 FOR SELECT 1 WHERE FALSE;

    ELSIF p_operation = 'DeleteRange' THEN

        IF p_date IS NULL OR p_to_date IS NULL THEN
            RAISE EXCEPTION 'Pick the first and last date of the range.';
        END IF;
        IF p_to_date < p_date THEN
            RAISE EXCEPTION 'The range ends before it starts.';
        END IF;

        DELETE FROM academic.school_calendar
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND calendar_date::date BETWEEN p_date AND p_to_date;
        GET DIAGNOSTICS v_n = ROW_COUNT;

        IF v_n = 0 THEN
            RAISE EXCEPTION 'There are no calendar entries from % to %.',
                to_char(p_date, 'FMDD Mon YYYY'), to_char(p_to_date, 'FMDD Mon YYYY');
        END IF;

        OPEN p_result FOR
        SELECT TRUE AS success, v_n AS removed,
               v_n || CASE WHEN v_n = 1 THEN ' entry' ELSE ' entries' END || ' removed.' AS message;
        OPEN p_result2 FOR SELECT 1 WHERE FALSE;

    ELSIF p_operation = 'DeleteEntry' THEN

        DELETE FROM academic.school_calendar
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND (   (p_calendar_id IS NOT NULL AND calendar_id   = p_calendar_id)
               OR (p_calendar_id IS NULL     AND calendar_date::date = p_date));

        IF NOT FOUND THEN
            RAISE EXCEPTION 'That calendar entry was not found.';
        END IF;

        OPEN p_result FOR SELECT TRUE AS success, 'Entry removed.' AS message;
        OPEN p_result2 FOR SELECT 1 WHERE FALSE;

    ELSIF p_operation = 'SaveWeeklyOff' THEN

        -- csv of 0..6; empty string is allowed (a school that never closes weekly).
        SELECT COALESCE(array_agg(d::smallint ORDER BY d::smallint), '{}')
          INTO v_offs
        FROM (
            SELECT DISTINCT trim(x) AS d
            FROM regexp_split_to_table(COALESCE(p_weekly_off, ''), ',') x
            WHERE trim(x) ~ '^[0-6]$'
        ) s;

        INSERT INTO academic.school_calendar_settings
            (tenant_id, school_id, weekly_off_days, updated_by, updated_at)
        VALUES
            (p_tenant_id, p_school_id, v_offs, p_action_user_id, now())
        ON CONFLICT (tenant_id, school_id) DO UPDATE
            SET weekly_off_days = EXCLUDED.weekly_off_days,
                updated_by      = p_action_user_id,
                updated_at      = now();

        OPEN p_result FOR SELECT TRUE AS success, 'Weekly offs saved.' AS message;
        OPEN p_result2 FOR SELECT 1 WHERE FALSE;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;


-- ============================================================================
-- sp_staff_manage.sql  —  CRUD for core.staff (HR/Staff module)
--
-- Operations (p_operation):
--   LIST       - all non-deleted staff for the school (UI filters client-side)
--   GET        - one staff row by p_staff_id
--   INSERT     - create a staff row; optionally also create a login user + role
--   UPDATE     - update a staff row; optionally create a login if not present
--   DELETE     - soft deactivate (status='Inactive', is_active=FALSE)
--   REACTIVATE - status='Active', is_active=TRUE
--
-- "Give login": when p_create_login = TRUE and email + password hash are
-- supplied, a core.users login is created (must_change_password=TRUE), a
-- profile + role (p_role_id) assigned, and core.staff.user_id linked. A bus
-- driver / peon left without a login is simply a staff row with user_id NULL.
--
-- Oct 2026 (platform_access_security_tests.sql) -- needs access_security_hardening.sql:
--   * DELETE also switches off the linked login; REACTIVATE switches it back on.
--     Nobody can deactivate their own login, and the last active school admin of a
--     school cannot be deactivated.
--   * Role ids must be roles of THIS tenant (there is no FK; a foreign id used to
--     become the primary role and lock the person out).
--   * Nobody can change their own roles. Only a school admin (or the platform)
--     can grant or remove SCHOOL_ADMIN, and the last school admin keeps it.
--   * Phone uniqueness uses core.fn_user_phone_taken (last 10 digits, like the index).
--   * Activation, role changes and admin password resets write admin_activity_logs.
--
-- Oct 2026 (hr_leave_payroll_tests.sql, docs/test-cases/hr_leave_payroll.md):
--   * core.staff.last_working_date: the day a leaver last worked. Payroll pays
--     the final month up to that day, so a leaver is no longer dropped from the
--     month they worked in. DELETE records it (p_last_working_date, default today).
--   * Choosing "Inactive" on the Edit form is the same as Deactivate: is_active
--     goes FALSE, status_changed_at and the last working day are stamped and the
--     login is switched off (same guards). Inactive -> Active/On Leave on the
--     form is the same as Reactivate. Before this only the status word changed,
--     so the person stayed in the teacher pools and kept signing in.
--   * UPDATE / DELETE / REACTIVATE check the staff row is in THIS school first.
--     An out-of-scope UPDATE with "create login" ticked used to create the login
--     before finding nothing to update, leaving an orphan account.
--   * Refused: employee code differing only by case, negative salary, a status
--     other than Active / On Leave / Inactive, a staff type outside the four
--     buckets, a new staff member created Inactive, a last working day in the
--     future or before the joining date, deactivating someone already inactive.
--   * p_last_working_date is the LAST parameter (after p_result) so existing
--     positional callers keep working.
--
-- NOTE: parameters are POSITIONAL (Npgsql CommandType.StoredProcedure). The C#
-- StaffService MUST build NpgsqlParameter[] in exactly this order.
-- ============================================================================

-- When a leaver last worked. Text 'YYYY-MM-DD' like every other date column on
-- core.staff (see dates_as_text.sql). NULL for anyone still working, and for
-- staff deactivated before this column existed (no honest value to fill in).
ALTER TABLE core.staff ADD COLUMN IF NOT EXISTS last_working_date varchar(10);

-- "zzhr-001" and "ZZHR-001" are the same badge. The proc checks this too; the
-- index makes it hold under concurrent saves.
CREATE UNIQUE INDEX IF NOT EXISTS uq_staff_employee_code_ci
    ON core.staff (tenant_id, school_id, UPPER(TRIM(employee_code)))
    WHERE employee_code IS NOT NULL AND is_deleted = FALSE;


-- ----------------------------------------------------------------------------
-- Switch a staff member's login off or on, with the guards that go with it.
-- One place for DELETE, REACTIVATE and an Edit-form status change.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE core.sp_staff_login_switch(
    p_tenant_id      integer,
    p_school_id      integer,
    p_action_user_id integer,
    p_staff_id       integer,
    p_user_id        integer,
    p_on             boolean)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_user_id IS NULL THEN
        RETURN;
    END IF;

    IF NOT p_on THEN
        IF p_user_id = p_action_user_id THEN
            RAISE EXCEPTION 'You cannot deactivate your own login.';
        END IF;
        IF core.fn_is_last_school_admin(p_school_id, p_user_id) THEN
            RAISE EXCEPTION 'This is the last active School Admin of the school. Make someone else a School Admin first.';
        END IF;

        -- Someone who has left must not keep signing in.
        UPDATE core.users
        SET    is_active = FALSE, updated_by = p_action_user_id, updated_at = now()
        WHERE  user_id = p_user_id AND tenant_id = p_tenant_id AND is_active = TRUE;

        IF FOUND THEN
            PERFORM core.fn_admin_audit(p_tenant_id, p_school_id, p_action_user_id, 'USER_DEACTIVATE',
                'Staff', 'core.users', p_user_id,
                format('Login deactivated with staff %s', p_staff_id));
        END IF;
        RETURN;
    END IF;

    -- Bring the login back, unless its email or phone now belongs to someone else.
    IF EXISTS (SELECT 1 FROM core.users WHERE user_id = p_user_id
               AND tenant_id = p_tenant_id AND is_active = FALSE AND is_deleted = FALSE) THEN
        IF core.fn_user_email_taken((SELECT email FROM core.users WHERE user_id = p_user_id), p_user_id) THEN
            RAISE EXCEPTION 'This person''s login email is now used by another user. Change it before re-activating.';
        END IF;
        IF EXISTS (SELECT 1 FROM core.user_profiles up WHERE up.user_id = p_user_id AND up.phone IS NOT NULL
                   AND core.fn_user_phone_taken(up.phone, p_user_id)) THEN
            RAISE EXCEPTION 'This person''s login phone is now used by another user. Change it before re-activating.';
        END IF;

        UPDATE core.users
        SET    is_active = TRUE, updated_by = p_action_user_id, updated_at = now()
        WHERE  user_id = p_user_id;

        PERFORM core.fn_admin_audit(p_tenant_id, p_school_id, p_action_user_id, 'USER_ACTIVATE',
            'Staff', 'core.users', p_user_id,
            format('Login re-activated with staff %s', p_staff_id));
    END IF;
END;
$procedure$;


-- ── a staff member leaves: their class charge and periods are freed ─────────
-- Left on them, the section showed a class teacher who had gone (only an admin
-- could take its attendance; the acting-teacher rule never fires for someone
-- inactive) and the timetable kept their periods, so no substitute was asked
-- for. In the current and later sessions the section gets no class teacher and
-- the periods no teacher, ready to be given to someone else.
CREATE OR REPLACE PROCEDURE core.sp_staff_release_duties(
    IN p_tenant_id      integer,
    IN p_school_id      integer,
    IN p_action_user_id integer,
    IN p_staff_id       integer)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    UPDATE academic.academic_class_sections sec
       SET class_teacher_staff_id = NULL, updated_by = p_action_user_id, updated_at = now()
      FROM academic.academic_years y
     WHERE sec.tenant_id = p_tenant_id AND sec.school_id = p_school_id
       AND sec.class_teacher_staff_id = p_staff_id
       AND y.academic_year_id = sec.academic_year_id
       AND NULLIF(y.end_date, '')::date >= CURRENT_DATE;

    UPDATE academic.timetable t
       SET staff_id = NULL, updated_by = p_action_user_id, updated_at = now()
      FROM academic.academic_years y
     WHERE t.tenant_id = p_tenant_id AND t.school_id = p_school_id
       AND t.staff_id = p_staff_id
       AND y.academic_year_id = t.academic_year_id
       AND NULLIF(y.end_date, '')::date >= CURRENT_DATE;
END;
$procedure$;


DROP PROCEDURE IF EXISTS core.sp_staff_manage(
    text, integer, integer, integer, integer,
    text, text, text, date, text, text, text, text, text,
    text, text, text, date, text, integer, text,
    numeric, text, text, text, text,
    boolean, text, integer[],
    text, text, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_staff_manage(
    p_operation        text,
    p_tenant_id        integer,
    p_school_id        integer,
    p_action_user_id   integer,
    p_staff_id         integer,
    -- personal
    p_employee_code    text,
    p_full_name        text,
    p_gender           text,
    p_dob              date,
    p_mobile           text,
    p_alt_mobile       text,
    p_email            text,
    p_blood_group      text,
    p_address          text,
    -- employment
    p_staff_type       text,
    p_department       text,
    p_designation      text,
    p_joining_date     date,
    p_qualification    text,
    p_experience_years integer,
    p_status           text,
    -- payroll / bank
    p_monthly_salary   numeric,
    p_bank_account_no  text,
    p_ifsc_code        text,
    p_pan              text,
    p_aadhaar          text,
    -- login linkage
    p_create_login     boolean,
    p_password_hash    text,
    p_role_ids         integer[],
    -- list filters
    p_search           text,
    p_status_filter    text,
    -- out
    INOUT p_result     refcursor DEFAULT 'staff_cursor',
    -- leaving (DELETE, or UPDATE to Inactive). Last so positional callers still work.
    p_last_working_date date DEFAULT NULL
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_staff_id    integer;
    v_user_id     integer;
    v_staff_type  text;
    v_old_roles   text;
    v_new_roles   text;
    v_admin_role  integer;
    v_had_admin   boolean;
    v_gets_admin  boolean;
    v_old_status  text;
    v_new_status  text;
    v_join        date;
    v_lwd         date;
    v_going_off   boolean := FALSE;
    v_coming_back boolean := FALSE;
BEGIN
    -- Multi-tenancy guard (tenant 1 = platform; real schools are tenant > 1).
    IF p_tenant_id IS NULL OR p_tenant_id <= 1 OR p_school_id IS NULL OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid tenant/school scope.';
    END IF;

    -- ---------------------------------------------------------------- LIST
    IF p_operation = 'LIST' THEN
        OPEN p_result FOR
        SELECT s.staff_id, s.public_id, s.employee_code, s.full_name, s.gender, s.dob,
               s.mobile, s.alt_mobile, s.email, s.blood_group, s.address,
               s.staff_type, s.department, s.designation, s.joining_date,
               s.qualification, s.experience_years, s.status,
               s.monthly_salary, s.bank_account_no, s.ifsc_code, s.pan, s.aadhaar,
               s.user_id, s.status_changed_at, s.last_working_date
        FROM   core.staff s
        WHERE  s.tenant_id = p_tenant_id
          AND  s.school_id = p_school_id
          AND  s.is_deleted = FALSE
          AND  (p_status_filter IS NULL OR p_status_filter = '' OR s.status = p_status_filter)
          AND  (p_search IS NULL OR p_search = ''
                OR s.full_name    ILIKE '%' || p_search || '%'
                OR s.employee_code ILIKE '%' || p_search || '%'
                OR s.designation  ILIKE '%' || p_search || '%')
        ORDER BY s.full_name;
        RETURN;
    END IF;

    -- ----------------------------------------------------------------- GET
    IF p_operation = 'GET' THEN
        OPEN p_result FOR
        SELECT s.staff_id, s.public_id, s.employee_code, s.full_name, s.gender, s.dob,
               s.mobile, s.alt_mobile, s.email, s.blood_group, s.address,
               s.staff_type, s.department, s.designation, s.joining_date,
               s.qualification, s.experience_years, s.status,
               s.monthly_salary, s.bank_account_no, s.ifsc_code, s.pan, s.aadhaar,
               s.user_id, s.status_changed_at, s.last_working_date
        FROM   core.staff s
        WHERE  s.tenant_id = p_tenant_id
          AND  s.school_id = p_school_id
          AND  s.staff_id  = p_staff_id
          AND  s.is_deleted = FALSE;
        RETURN;
    END IF;

    -- Every write below works on one staff row of THIS school. Find it first, so
    -- nothing (a login, a role) is created for a row that is not ours.
    IF p_operation IN ('UPDATE', 'DELETE', 'REACTIVATE') THEN
        SELECT user_id, status, NULLIF(joining_date, '')::date
          INTO v_user_id, v_old_status, v_join
        FROM core.staff
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND staff_id = p_staff_id AND is_deleted = FALSE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Staff member not found.';
        END IF;
    END IF;

    -- -------------------------------------------------------------- DELETE
    IF p_operation = 'DELETE' THEN
        IF v_old_status = 'Inactive' THEN
            RAISE EXCEPTION 'This staff member is already inactive.';
        END IF;

        v_lwd := COALESCE(p_last_working_date, CURRENT_DATE);
        IF v_lwd > CURRENT_DATE THEN
            RAISE EXCEPTION 'The last working day cannot be in the future. Deactivate on or after that day.';
        END IF;
        -- Someone hired for a future date who never joined: no working days at
        -- all, so no last working day (payroll then never pays them).
        IF p_last_working_date IS NULL AND v_join IS NOT NULL AND v_join > CURRENT_DATE THEN
            v_lwd := NULL;
        END IF;
        IF v_join IS NOT NULL AND v_lwd < v_join THEN
            RAISE EXCEPTION 'The last working day cannot be before the joining date (%).', to_char(v_join, 'DD Mon YYYY');
        END IF;

        UPDATE core.staff
        SET    status = 'Inactive', is_active = FALSE,
               status_changed_at = now(),
               last_working_date = to_char(v_lwd, 'YYYY-MM-DD'),
               updated_by = p_action_user_id, updated_at = now()
        WHERE  tenant_id = p_tenant_id AND school_id = p_school_id AND staff_id = p_staff_id;

        CALL core.sp_staff_login_switch(p_tenant_id, p_school_id, p_action_user_id, p_staff_id, v_user_id, FALSE);
        CALL core.sp_staff_release_duties(p_tenant_id, p_school_id, p_action_user_id, p_staff_id);

        OPEN p_result FOR SELECT p_staff_id AS staff_id;
        RETURN;
    END IF;

    -- ---------------------------------------------------------- REACTIVATE
    -- Meant for a mistaken deactivation. A re-hire after a real gap should also
    -- get a new joining date on the Edit form, or payroll would see the gap as
    -- employed time.
    IF p_operation = 'REACTIVATE' THEN
        UPDATE core.staff
        SET    status = 'Active', is_active = TRUE,
               status_changed_at = now(),
               last_working_date = NULL,
               updated_by = p_action_user_id, updated_at = now()
        WHERE  tenant_id = p_tenant_id AND school_id = p_school_id AND staff_id = p_staff_id;

        CALL core.sp_staff_login_switch(p_tenant_id, p_school_id, p_action_user_id, p_staff_id, v_user_id, TRUE);

        OPEN p_result FOR SELECT p_staff_id AS staff_id;
        RETURN;
    END IF;

    -- ============================ INSERT / UPDATE ========================
    IF p_operation IN ('INSERT', 'UPDATE') THEN

        IF p_full_name IS NULL OR TRIM(p_full_name) = '' THEN
            RAISE EXCEPTION 'Staff full name is required.';
        END IF;

        -- Payroll pays a salary only for the statuses it knows; any other word
        -- would silently drop the person from payroll.
        v_new_status := COALESCE(NULLIF(TRIM(p_status), ''), v_old_status, 'Active');
        IF v_new_status NOT IN ('Active', 'On Leave', 'Inactive') THEN
            RAISE EXCEPTION 'Status must be Active, On Leave or Inactive.';
        END IF;
        IF p_operation = 'INSERT' AND v_new_status = 'Inactive' THEN
            RAISE EXCEPTION 'A new staff member starts Active or On Leave.';
        END IF;

        IF p_monthly_salary IS NOT NULL AND p_monthly_salary < 0 THEN
            RAISE EXCEPTION 'Monthly salary cannot be negative.';
        END IF;

        -- Employee code unique per school (when supplied), ignoring case and spaces.
        IF p_employee_code IS NOT NULL AND TRIM(p_employee_code) <> ''
           AND EXISTS (
                SELECT 1 FROM core.staff
                WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                  AND is_deleted = FALSE
                  AND UPPER(TRIM(employee_code)) = UPPER(TRIM(p_employee_code))
                  AND (p_operation = 'INSERT' OR staff_id <> p_staff_id)
           ) THEN
            RAISE EXCEPTION 'Employee code already exists.';
        END IF;

        -- Mobile and email unique among this school's current staff (not the row
        -- being edited, not deleted or Inactive people, so a re-hire still works).
        -- Mobile compares the last 10 digits, the same rule as the login phone.
        IF p_mobile IS NOT NULL AND TRIM(p_mobile) <> ''
           AND EXISTS (
                SELECT 1 FROM core.staff
                WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                  AND is_deleted = FALSE AND status <> 'Inactive'
                  AND RIGHT(regexp_replace(mobile, '\D', '', 'g'), 10)
                      = RIGHT(regexp_replace(p_mobile, '\D', '', 'g'), 10)
                  AND (p_operation = 'INSERT' OR staff_id <> p_staff_id)
           ) THEN
            RAISE EXCEPTION 'A staff member with this mobile already exists.';
        END IF;

        IF p_email IS NOT NULL AND TRIM(p_email) <> ''
           AND EXISTS (
                SELECT 1 FROM core.staff
                WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                  AND is_deleted = FALSE AND status <> 'Inactive'
                  AND LOWER(TRIM(email)) = LOWER(TRIM(p_email))
                  AND (p_operation = 'INSERT' OR staff_id <> p_staff_id)
           ) THEN
            RAISE EXCEPTION 'A staff member with this email already exists.';
        END IF;

        -- Staff Type is DERIVED from the chosen Designation (single source of
        -- truth) so it can never contradict the title, even if the form is
        -- bypassed. Falls back to whatever the caller sent if the designation
        -- has no bucket set.
        IF p_designation IS NOT NULL AND TRIM(p_designation) <> '' THEN
            SELECT staff_type INTO v_staff_type
            FROM   config.designations
            WHERE  tenant_id = p_tenant_id AND is_deleted = FALSE
              AND  LOWER(TRIM(name)) = LOWER(TRIM(p_designation))
            LIMIT 1;
        END IF;
        v_staff_type := COALESCE(v_staff_type, NULLIF(TRIM(p_staff_type), ''));
        IF v_staff_type IS NOT NULL AND v_staff_type NOT IN ('Teaching', 'Non-Teaching', 'Transport', 'Support') THEN
            RAISE EXCEPTION 'Invalid staff type.';
        END IF;

        -- Status flips through the Edit form behave exactly like Deactivate /
        -- Reactivate (see the header).
        IF p_operation = 'UPDATE' THEN
            v_going_off   := v_new_status = 'Inactive' AND v_old_status <> 'Inactive';
            v_coming_back := v_old_status = 'Inactive' AND v_new_status <> 'Inactive';
        END IF;

        -- The last working day is set when someone goes Inactive, and can be
        -- corrected later while they stay Inactive.
        IF v_new_status = 'Inactive' AND (v_going_off OR p_last_working_date IS NOT NULL) THEN
            v_lwd := COALESCE(p_last_working_date, CURRENT_DATE);
            IF v_lwd > CURRENT_DATE THEN
                RAISE EXCEPTION 'The last working day cannot be in the future. Deactivate on or after that day.';
            END IF;
            IF p_last_working_date IS NULL AND COALESCE(p_joining_date, v_join) > CURRENT_DATE THEN
                v_lwd := NULL;   -- never joined (see DELETE)
            END IF;
            IF COALESCE(p_joining_date, v_join) IS NOT NULL AND v_lwd < COALESCE(p_joining_date, v_join) THEN
                RAISE EXCEPTION 'The last working day cannot be before the joining date.';
            END IF;
        END IF;

        -- Optionally create a login user (only when none is linked yet).
        IF COALESCE(p_create_login, FALSE) = TRUE
           AND v_user_id IS NULL
           AND p_email IS NOT NULL AND TRIM(p_email) <> ''
           AND p_password_hash IS NOT NULL AND TRIM(p_password_hash) <> '' THEN

            -- Shared guard (Database/user_email_unique.sql) so this can't drift from
            -- the uq_user_email_active index. The old inline check missed is_deleted.
            IF core.fn_user_email_taken(p_email) THEN
                RAISE EXCEPTION 'A login with this email already exists.';
            END IF;

            -- Same rule as uq_user_phone_active (last 10 digits), so '+91 98390 73643'
            -- gets this message instead of a raw constraint error.
            IF p_mobile IS NOT NULL AND TRIM(p_mobile) <> ''
               AND core.fn_user_phone_taken(p_mobile) THEN
                RAISE EXCEPTION 'A login with this phone already exists.';
            END IF;

            INSERT INTO core.users
                (tenant_id, school_id, email, password_hash, must_change_password, is_active, created_by, created_at)
            VALUES
                (p_tenant_id, p_school_id, LOWER(TRIM(p_email)), p_password_hash, TRUE, TRUE, p_action_user_id, NOW())
            RETURNING user_id INTO v_user_id;

            INSERT INTO core.user_profiles
                (tenant_id, user_id, school_id, full_name, phone, designation, is_active, created_by, created_at)
            VALUES
                (p_tenant_id, v_user_id, p_school_id, TRIM(p_full_name),
                 NULLIF(TRIM(p_mobile), ''), NULLIF(TRIM(p_designation), ''), TRUE, p_action_user_id, NOW());

        END IF;

        -- Reset the password of an EXISTING login when a new hash is supplied (admin
        -- "reset password" on the edit form). Force a self-reset on next sign-in.
        IF p_operation = 'UPDATE'
           AND COALESCE(p_create_login, FALSE) = FALSE
           AND v_user_id IS NOT NULL
           AND p_password_hash IS NOT NULL AND TRIM(p_password_hash) <> '' THEN
            UPDATE core.users
            SET    password_hash = p_password_hash,
                   must_change_password = TRUE,
                   password_changed_at = now(),   -- ends the person's open sessions
                   updated_by = p_action_user_id,
                   updated_at = now()
            WHERE  user_id = v_user_id AND tenant_id = p_tenant_id;

            PERFORM core.fn_admin_audit(p_tenant_id, p_school_id, p_action_user_id, 'PASSWORD_RESET_BY_ADMIN',
                'Staff', 'core.users', v_user_id, format('Password reset for staff %s', p_staff_id));
        END IF;

        -- Assign / sync the login's role(s). A user's effective permissions are the
        -- UNION of all their roles. Runs for a freshly-created OR an existing login,
        -- so the People edit form is the single place to manage a person's access.
        IF v_user_id IS NOT NULL AND p_role_ids IS NOT NULL THEN
            -- Every id must be a live role of THIS tenant (and never the platform role).
            IF EXISTS (SELECT 1 FROM unnest(p_role_ids) AS rid
                       WHERE NOT EXISTS (SELECT 1 FROM config.roles r
                                         WHERE r.role_id = rid AND r.tenant_id = p_tenant_id
                                           AND r.is_deleted = FALSE AND r.role_code <> 'SUPER_ADMIN')) THEN
                RAISE EXCEPTION 'Role not found.';
            END IF;

            SELECT string_agg(r.role_code, ', ' ORDER BY r.role_code) INTO v_old_roles
            FROM core.user_roles ur JOIN config.roles r ON r.role_id = ur.role_id
            WHERE ur.tenant_id = p_tenant_id AND ur.user_id = v_user_id
              AND ur.is_deleted = FALSE AND ur.is_active = TRUE;
            SELECT string_agg(r.role_code, ', ' ORDER BY r.role_code) INTO v_new_roles
            FROM config.roles r WHERE r.role_id = ANY (p_role_ids);

            IF v_old_roles IS DISTINCT FROM v_new_roles THEN
                IF v_user_id = p_action_user_id THEN
                    RAISE EXCEPTION 'You cannot change your own roles. Ask another School Admin.';
                END IF;

                SELECT role_id INTO v_admin_role FROM config.roles
                WHERE tenant_id = p_tenant_id AND role_code = 'SCHOOL_ADMIN' AND is_deleted = FALSE
                ORDER BY role_id LIMIT 1;
                v_had_admin  := COALESCE(v_old_roles, '') ~ '(^|, )SCHOOL_ADMIN(,|$)';
                v_gets_admin := v_admin_role = ANY (p_role_ids);

                IF v_had_admin IS DISTINCT FROM v_gets_admin
                   AND NOT core.fn_user_is_school_admin(p_tenant_id, p_action_user_id) THEN
                    RAISE EXCEPTION 'Only a School Admin can grant or remove the School Admin role.';
                END IF;
                IF v_had_admin AND NOT v_gets_admin
                   AND core.fn_is_last_school_admin(p_school_id, v_user_id) THEN
                    RAISE EXCEPTION 'This is the last active School Admin of the school. Make someone else a School Admin first.';
                END IF;

                PERFORM core.fn_admin_audit(p_tenant_id, p_school_id, p_action_user_id, 'USER_ROLES_CHANGE',
                    'Staff', 'core.user_roles', v_user_id,
                    format('Roles: [%s] -> [%s]', COALESCE(v_old_roles, ''), COALESCE(v_new_roles, '')));
            END IF;

            -- drop roles no longer selected
            UPDATE core.user_roles
            SET is_deleted = TRUE, is_active = FALSE, is_primary = FALSE,
                updated_by = p_action_user_id, updated_at = now()
            WHERE tenant_id = p_tenant_id AND user_id = v_user_id AND is_deleted = FALSE
              AND NOT (role_id = ANY (p_role_ids));

            -- revive previously-removed roles that are selected again
            UPDATE core.user_roles
            SET is_deleted = FALSE, is_active = TRUE, school_id = p_school_id,
                updated_by = p_action_user_id, updated_at = now()
            WHERE tenant_id = p_tenant_id AND user_id = v_user_id AND is_deleted = TRUE
              AND role_id = ANY (p_role_ids);

            -- insert brand-new selections
            INSERT INTO core.user_roles
                (tenant_id, user_id, role_id, school_id, is_primary, is_active, created_by, created_at)
            SELECT p_tenant_id, v_user_id, rid, p_school_id, FALSE, TRUE, p_action_user_id, now()
            FROM   unnest(p_role_ids) AS rid
            WHERE  NOT EXISTS (
                SELECT 1 FROM core.user_roles ur
                WHERE ur.tenant_id = p_tenant_id AND ur.user_id = v_user_id AND ur.role_id = rid);

            -- keep exactly one primary among the active roles (lowest role_id)
            UPDATE core.user_roles SET is_primary = FALSE
            WHERE tenant_id = p_tenant_id AND user_id = v_user_id AND is_deleted = FALSE AND is_primary = TRUE;
            UPDATE core.user_roles SET is_primary = TRUE
            WHERE user_role_id = (
                SELECT user_role_id FROM core.user_roles
                WHERE tenant_id = p_tenant_id AND user_id = v_user_id AND is_deleted = FALSE AND is_active = TRUE
                ORDER BY role_id LIMIT 1);
        END IF;

        IF p_operation = 'INSERT' THEN
            INSERT INTO core.staff
                (tenant_id, school_id, employee_code, full_name, gender, dob,
                 mobile, alt_mobile, email, blood_group, address,
                 staff_type, department, designation, joining_date, qualification,
                 experience_years, status, monthly_salary, bank_account_no, ifsc_code,
                 pan, aadhaar, user_id, created_by, updated_by)
            VALUES
                (p_tenant_id, p_school_id, NULLIF(TRIM(p_employee_code), ''), TRIM(p_full_name), p_gender, p_dob,
                 NULLIF(TRIM(p_mobile), ''), NULLIF(TRIM(p_alt_mobile), ''), NULLIF(TRIM(p_email), ''), p_blood_group, p_address,
                 v_staff_type, p_department, p_designation, p_joining_date, p_qualification,
                 p_experience_years, v_new_status, p_monthly_salary, p_bank_account_no, p_ifsc_code,
                 p_pan, p_aadhaar, v_user_id, p_action_user_id, p_action_user_id)
            RETURNING staff_id INTO v_staff_id;
        ELSE
            UPDATE core.staff
            SET employee_code   = NULLIF(TRIM(p_employee_code), ''),
                full_name       = TRIM(p_full_name),
                gender          = p_gender,
                dob             = p_dob,
                mobile          = NULLIF(TRIM(p_mobile), ''),
                alt_mobile      = NULLIF(TRIM(p_alt_mobile), ''),
                email           = NULLIF(TRIM(p_email), ''),
                blood_group     = p_blood_group,
                address         = p_address,
                staff_type      = v_staff_type,
                department      = p_department,
                designation     = p_designation,
                joining_date    = p_joining_date,
                qualification   = p_qualification,
                experience_years = p_experience_years,
                status          = v_new_status,
                -- is_active always follows the status, whichever screen set it.
                is_active       = (v_new_status <> 'Inactive'),
                status_changed_at = CASE WHEN v_going_off OR v_coming_back THEN now()
                                         ELSE status_changed_at END,
                last_working_date = CASE WHEN v_lwd IS NOT NULL THEN to_char(v_lwd, 'YYYY-MM-DD')
                                         WHEN v_coming_back THEN NULL
                                         ELSE last_working_date END,
                monthly_salary  = p_monthly_salary,
                bank_account_no = p_bank_account_no,
                ifsc_code       = p_ifsc_code,
                pan             = p_pan,
                aadhaar         = p_aadhaar,
                user_id         = COALESCE(v_user_id, user_id),
                updated_by      = p_action_user_id,
                updated_at      = now()
            WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND staff_id = p_staff_id
            RETURNING staff_id INTO v_staff_id;

            IF v_going_off THEN
                CALL core.sp_staff_login_switch(p_tenant_id, p_school_id, p_action_user_id, p_staff_id, v_user_id, FALSE);
                CALL core.sp_staff_release_duties(p_tenant_id, p_school_id, p_action_user_id, p_staff_id);
            ELSIF v_coming_back THEN
                CALL core.sp_staff_login_switch(p_tenant_id, p_school_id, p_action_user_id, p_staff_id, v_user_id, TRUE);
            END IF;
        END IF;

        OPEN p_result FOR SELECT v_staff_id AS staff_id;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation: %', p_operation;
END;
$procedure$;


-- ============================================================================
-- sp_staff_dropdowns — form source lists for the Add/Edit Staff screens:
--   cursor 0: departments      (department name)
--   cursor 1: designations     (name + default staff_type)
--   cursor 2: assignable roles (role_id + role_name) for the "give login" toggle
-- ============================================================================
DROP PROCEDURE IF EXISTS config.sp_staff_dropdowns(integer, integer, refcursor, refcursor, refcursor);

CREATE OR REPLACE PROCEDURE config.sp_staff_dropdowns(
    p_tenant_id integer,
    p_school_id integer,
    INOUT p_departments  refcursor DEFAULT 'departments_cursor',
    INOUT p_designations refcursor DEFAULT 'designations_cursor',
    INOUT p_roles        refcursor DEFAULT 'roles_cursor'
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    OPEN p_departments FOR
    SELECT name
    FROM   config.departments
    WHERE  tenant_id = p_tenant_id AND is_deleted = FALSE AND is_active = TRUE
    ORDER BY sort_order, name;

    OPEN p_designations FOR
    SELECT name, staff_type, default_department, default_role_id
    FROM   config.designations
    WHERE  tenant_id = p_tenant_id AND is_deleted = FALSE AND is_active = TRUE
    ORDER BY sort_order, name;

    -- School-scoped roles a new login can be given (exclude the platform SUPER_ADMIN).
    OPEN p_roles FOR
    SELECT role_id, role_name
    FROM   config.roles
    WHERE  tenant_id = p_tenant_id
      AND  is_deleted = FALSE AND is_active = TRUE
      AND  role_code <> 'SUPER_ADMIN'
    ORDER BY role_name;
END;
$procedure$;


-- ============================================================================
-- Academic Years + Classes & Sections: correctness fixes.
--
-- Found by tests/settings_years_classes_tests.sql. This script SUPERSEDES the
-- two procedure definitions below:
--   academic.sp_school_admin_academic_year_manage   (was fee_charge_from_per_year.sql)
--   academic.sp_school_admin_academic_setup_manage  (was academic_class_section_fields.sql)
-- Those scripts are not re-run for this change: fee_charge_from_per_year.sql
-- also rewrites the admission-workflow proc and drops a column, and
-- academic_class_section_fields.sql would put the old setup proc back.
--
-- Safe to re-run: every step is CREATE OR REPLACE / IF EXISTS / IF NOT EXISTS.
--
-- WHAT CHANGES
--   Sessions
--   * Name: max 20 characters, start and end dates required, end AFTER start
--     -- refused with a readable message instead of a raw constraint error.
--   * Two sessions of one school can no longer overlap.
--   * Set-current / edit / delete check that the session exists in THIS school
--     first. Before, an unknown id cleared every current flag and then set
--     nothing, leaving the school with no current session.
--   * The current session can not be un-ticked or deleted; another session has
--     to be made current first. A school always has exactly one.
--   * A session can not be renamed once anything stores its name (students,
--     enrolment, fee structures, attendance, transport, TC register, enquiries,
--     admission / registration counters). Those tables hold the NAME, not the
--     id, so a rename silently detached all of them. Refusing is safer than a
--     cascade across nine tables: counters would restart numbering and printed
--     receipts / TCs already carry the old name.
--   * A deleted session's name can be used again (the unique key now ignores
--     deleted rows, as the proc's duplicate check always did).
--   * The charge-fees-from lock and the student count also count the session's
--     enrolment history, so promoting students out does not unlock it.
--   Classes & Sections
--   * Save updates classes and sections IN PLACE (matched by their original
--     name, then by name) instead of delete-all + re-insert. Their ids stay,
--     so subjects, exam papers, the timetable and the class teacher stay
--     attached. Only what was really removed is soft-deleted.
--   * A renamed class keeps its id and carries its name into the session's
--     fee structures (the only other table that stores a class name without a
--     student behind it; renaming a class WITH students is still refused).
--   * A deleted session can not take a structure; capacity must be 1..5000;
--     the payload must be a JSON array. No temp table any more, so the proc
--     can run twice in one transaction.
-- ============================================================================


-- ── 1. Session names unique among LIVE rows only ────────────────────────────
ALTER TABLE academic.academic_years DROP CONSTRAINT IF EXISTS uq_academic_year;

CREATE UNIQUE INDEX IF NOT EXISTS ux_academic_years_name
    ON academic.academic_years (tenant_id, school_id, lower(academic_year_name))
    WHERE COALESCE(is_deleted, FALSE) = FALSE;


-- ── 2. Where a session's NAME is used ───────────────────────────────────────
-- Returns e.g. '3 student(s), 1 fee structure(s)', or NULL when nothing uses it.
CREATE OR REPLACE FUNCTION academic.fn_academic_year_name_usage(
    p_tenant_id integer, p_school_id integer, p_name text)
RETURNS text
LANGUAGE plpgsql STABLE
AS $function$
DECLARE
    v_parts text[] := '{}';
    v_n     integer;
BEGIN
    -- Students: their present position plus every session they were enrolled in.
    SELECT COUNT(*) INTO v_n FROM (
        SELECT student_id FROM core.students
         WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND academic_year = p_name
        UNION
        SELECT student_id FROM core.student_enrolment
         WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND academic_year = p_name) s;
    IF v_n > 0 THEN v_parts := v_parts || (v_n || ' student(s)'); END IF;

    SELECT COUNT(*) INTO v_n FROM core.school_fee_structures
     WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND academic_year = p_name;
    IF v_n > 0 THEN v_parts := v_parts || (v_n || ' fee structure(s)'); END IF;

    SELECT COUNT(*) INTO v_n FROM core.student_attendance
     WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND academic_year = p_name;
    IF v_n > 0 THEN v_parts := v_parts || (v_n || ' attendance record(s)'); END IF;

    SELECT COUNT(*) INTO v_n FROM core.student_transport
     WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND academic_year = p_name;
    IF v_n > 0 THEN v_parts := v_parts || (v_n || ' transport record(s)'); END IF;

    SELECT COUNT(*) INTO v_n FROM core.tc_register
     WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND academic_year = p_name;
    IF v_n > 0 THEN v_parts := v_parts || (v_n || ' TC(s)'); END IF;

    SELECT COUNT(*) INTO v_n FROM core.enquiries
     WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND session = p_name;
    IF v_n > 0 THEN v_parts := v_parts || (v_n || ' enquiry(ies)'); END IF;

    -- A counter means numbers were already issued under this name; a renamed
    -- session would start again from 1 and hand out duplicates.
    SELECT COUNT(*) INTO v_n FROM (
        SELECT 1 FROM core.admission_counters
         WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND academic_year = p_name
        UNION ALL
        SELECT 1 FROM core.registration_counters
         WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND session = p_name) c;
    IF v_n > 0 THEN v_parts := v_parts || 'issued admission/registration numbers'::text; END IF;

    RETURN NULLIF(array_to_string(v_parts, ', '), '');
END;
$function$;


-- ── 3. Academic year proc ───────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE academic.sp_school_admin_academic_year_manage(
    IN p_operation          character varying,
    IN p_tenant_id          integer,
    IN p_school_id          integer,
    IN p_action_user_id     integer,
    IN p_academic_year_id   integer           DEFAULT NULL::integer,
    IN p_academic_year_name character varying DEFAULT NULL::character varying,
    IN p_start_date         date              DEFAULT NULL::date,
    IN p_end_date           date              DEFAULT NULL::date,
    IN p_is_current         boolean           DEFAULT false,
    IN p_charge_fees_from   character varying DEFAULT NULL::character varying,
    INOUT p_result          refcursor         DEFAULT 'result_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_first_used    date;   -- earliest fee due / attendance day already in the session
    v_last_used     date;   -- latest one
    v_id            integer;
    v_name          text;
    v_year_name     text;
    v_was_current   boolean;
    v_class_count   integer;
    v_student_count integer;
    v_usage         text;
    v_clash         record;
    v_charge_from   varchar(20);
    v_old_charge    varchar(20);
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    IF p_operation = 'GetAcademicYears' THEN

        OPEN p_result FOR
        SELECT
            ay.academic_year_id,
            ay.academic_year_name,
            ay.start_date,
            ay.end_date,
            COALESCE(ay.is_current, FALSE) AS is_current,
            COALESCE(NULLIF(TRIM(ay.charge_fees_from), ''), 'AdmissionMonth') AS charge_fees_from,
            (SELECT COUNT(*) FROM academic.academic_classes ac
              WHERE ac.tenant_id = p_tenant_id
                AND ac.school_id = p_school_id
                AND ac.academic_year_id = ay.academic_year_id
                AND COALESCE(ac.is_deleted, FALSE) = FALSE) AS class_count,
            -- Present students plus the session's enrolment history, so a past
            -- session still shows (and is locked by) the students it billed.
            (SELECT COUNT(*) FROM (
                 SELECT st.student_id FROM core.students st
                  WHERE st.tenant_id = p_tenant_id AND st.school_id = p_school_id
                    AND st.academic_year = ay.academic_year_name
                    AND COALESCE(st.is_active, TRUE) = TRUE
                 UNION
                 SELECT en.student_id FROM core.student_enrolment en
                  WHERE en.tenant_id = p_tenant_id AND en.school_id = p_school_id
                    AND en.academic_year = ay.academic_year_name) s) AS student_count
        FROM academic.academic_years ay
        WHERE ay.tenant_id = p_tenant_id
          AND ay.school_id = p_school_id
          AND COALESCE(ay.is_deleted, FALSE) = FALSE
        ORDER BY ay.start_date DESC NULLS LAST, ay.academic_year_name DESC;

    ELSIF p_operation = 'SaveAcademicYear' THEN

        v_name := trim(COALESCE(p_academic_year_name, ''));
        IF v_name = '' THEN
            RAISE EXCEPTION 'Academic year name is required.';
        END IF;
        IF length(v_name) > 20 THEN
            RAISE EXCEPTION 'Academic year name can be at most 20 characters.';
        END IF;

        -- The columns are NOT NULL with CHECK (end > start); say so in words
        -- rather than let the raw constraint error reach the user.
        IF p_start_date IS NULL OR p_end_date IS NULL THEN
            RAISE EXCEPTION 'Start date and end date are both required.';
        END IF;
        IF p_end_date <= p_start_date THEN
            RAISE EXCEPTION 'End date must be after the start date.';
        END IF;

        -- An edit must point at a live session of THIS school. Checked before
        -- anything is written: the current-flag reset below would otherwise run
        -- for an id that then updates nothing.
        IF COALESCE(p_academic_year_id, 0) > 0 THEN
            SELECT academic_year_name,
                   COALESCE(NULLIF(TRIM(charge_fees_from), ''), 'AdmissionMonth'),
                   COALESCE(is_current, FALSE)
              INTO v_year_name, v_old_charge, v_was_current
            FROM academic.academic_years
            WHERE tenant_id = p_tenant_id
              AND school_id = p_school_id
              AND academic_year_id = p_academic_year_id
              AND COALESCE(is_deleted, FALSE) = FALSE;

            IF v_year_name IS NULL THEN
                RAISE EXCEPTION 'This academic year no longer exists. Refresh the page.';
            END IF;
        END IF;

        IF EXISTS (
            SELECT 1 FROM academic.academic_years
            WHERE tenant_id = p_tenant_id
              AND school_id = p_school_id
              AND COALESCE(is_deleted, FALSE) = FALSE
              AND lower(academic_year_name) = lower(v_name)
              AND academic_year_id <> COALESCE(p_academic_year_id, 0)
        ) THEN
            RAISE EXCEPTION 'An academic year named "%" already exists.', v_name;
        END IF;

        -- Two sessions covering the same day make "which session is this date
        -- in" ambiguous for fee months, attendance and admissions.
        SELECT academic_year_name, start_date, end_date INTO v_clash
        FROM academic.academic_years
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND COALESCE(is_deleted, FALSE) = FALSE
          AND academic_year_id <> COALESCE(p_academic_year_id, 0)
          AND start_date::date <= p_end_date
          AND end_date::date   >= p_start_date
        ORDER BY start_date
        LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'These dates overlap session "%" (% to %).',
                v_clash.academic_year_name, v_clash.start_date, v_clash.end_date;
        END IF;

        -- Anything but the one other value means the default.
        v_charge_from := CASE WHEN p_charge_fees_from = 'SessionStart'
                              THEN 'SessionStart' ELSE 'AdmissionMonth' END;

        IF COALESCE(p_academic_year_id, 0) > 0 THEN
            -- A school always has one current session: un-ticking it here would
            -- leave none. Making another session current is the way to move it.
            IF v_was_current AND NOT COALESCE(p_is_current, FALSE) THEN
                RAISE EXCEPTION 'This is the current session. Set another session as current instead of un-ticking it.';
            END IF;

            -- Students, fee structures, attendance... store the session NAME,
            -- not its id, so a rename would silently detach every one of them.
            -- A case-only change counts too: those columns compare exactly.
            IF v_name IS DISTINCT FROM v_year_name THEN
                v_usage := academic.fn_academic_year_name_usage(p_tenant_id, p_school_id, v_year_name);
                IF v_usage IS NOT NULL THEN
                    RAISE EXCEPTION 'Cannot rename % to %: it is already used by %. Those records keep the session name, so a rename would detach them.',
                        v_year_name, v_name, v_usage;
                END IF;
            END IF;

            -- New dates must still hold what already happened in this session: fees
            -- billed and attendance taken. Shrinking past them left months billed
            -- outside the session and broke every "within the session" check.
            SELECT MIN(d), MAX(d) INTO v_first_used, v_last_used FROM (
                SELECT NULLIF(l.due_date, '')::date AS d FROM core.student_ledger l
                 WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id AND l.academic_year = v_year_name
                   AND l.carried_from IS NULL   -- a due carried in keeps its old date
                UNION ALL
                SELECT a.attendance_date::date FROM core.student_attendance a
                 WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id AND a.academic_year = v_year_name) x;
            IF v_first_used IS NOT NULL AND (p_start_date > v_first_used OR p_end_date < v_last_used) THEN
                RAISE EXCEPTION 'Session % already has fees or attendance from % to %. The dates must cover that period.',
                    v_year_name, to_char(v_first_used, 'DD Mon YYYY'), to_char(v_last_used, 'DD Mon YYYY');
            END IF;

            -- The guard this move exists for. A student's fee ledger is generated
            -- once, at admission, from this setting -- and then frozen. Refuse
            -- while the value would actually differ; dates stay editable.
            IF v_old_charge IS DISTINCT FROM v_charge_from THEN
                SELECT COUNT(*) INTO v_student_count FROM (
                    SELECT student_id FROM core.students
                     WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                       AND academic_year = v_year_name AND COALESCE(is_active, TRUE) = TRUE
                    UNION
                    SELECT student_id FROM core.student_enrolment
                     WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                       AND academic_year = v_year_name) s;

                IF v_student_count > 0 THEN
                    RAISE EXCEPTION
                        'Cannot change when fees are charged from for %: % student(s) are already admitted in this session, and their fee plans were generated under the current setting.',
                        v_year_name, v_student_count;
                END IF;
            END IF;
        END IF;

        -- Only one current year per school.
        IF COALESCE(p_is_current, FALSE) THEN
            UPDATE academic.academic_years
            SET is_current = FALSE, updated_by = p_action_user_id, updated_at = NOW()
            WHERE tenant_id = p_tenant_id
              AND school_id = p_school_id
              AND COALESCE(is_deleted, FALSE) = FALSE
              AND COALESCE(is_current, FALSE)
              AND academic_year_id <> COALESCE(p_academic_year_id, 0);
        END IF;

        IF COALESCE(p_academic_year_id, 0) <= 0 THEN
            INSERT INTO academic.academic_years
                (tenant_id, school_id, academic_year_name, start_date, end_date, is_current,
                 charge_fees_from, created_by, created_at, is_deleted, is_active)
            VALUES
                (p_tenant_id, p_school_id, v_name, p_start_date, p_end_date, COALESCE(p_is_current, FALSE),
                 v_charge_from, p_action_user_id, NOW(), FALSE, TRUE)
            RETURNING academic_year_id INTO v_id;
        ELSE
            UPDATE academic.academic_years
            SET academic_year_name = v_name,
                start_date       = p_start_date,
                end_date         = p_end_date,
                is_current       = COALESCE(p_is_current, FALSE),
                charge_fees_from = v_charge_from,
                updated_by       = p_action_user_id,
                updated_at       = NOW()
            WHERE tenant_id = p_tenant_id
              AND school_id = p_school_id
              AND academic_year_id = p_academic_year_id
              AND COALESCE(is_deleted, FALSE) = FALSE
            RETURNING academic_year_id INTO v_id;
        END IF;

        OPEN p_result FOR
        SELECT TRUE AS success, 'Saved successfully.' AS message, v_id AS academic_year_id;

    ELSIF p_operation = 'SetCurrentAcademicYear' THEN

        IF p_academic_year_id IS NULL OR p_academic_year_id <= 0 THEN
            RAISE EXCEPTION 'Select an academic year.';
        END IF;

        -- Check first: clearing every flag and then matching nothing (a stale
        -- tab, another school's id) used to leave the school with no current year.
        IF NOT EXISTS (
            SELECT 1 FROM academic.academic_years
            WHERE tenant_id = p_tenant_id
              AND school_id = p_school_id
              AND academic_year_id = p_academic_year_id
              AND COALESCE(is_deleted, FALSE) = FALSE
        ) THEN
            RAISE EXCEPTION 'This academic year no longer exists. Refresh the page.';
        END IF;

        -- Every page opens on the current session and lists the students who are
        -- IN it. Switching before the session is set up, or before the students
        -- were promoted into it, left Collect Fees, attendance and homework showing
        -- nobody. So the order is: set it up, promote, then make it current.
        IF NOT EXISTS (
            SELECT 1 FROM academic.academic_classes
            WHERE tenant_id = p_tenant_id AND school_id = p_school_id
              AND academic_year_id = p_academic_year_id AND COALESCE(is_deleted, FALSE) = FALSE
        ) THEN
            RAISE EXCEPTION 'This session has no classes yet. Set up its classes and sections first (Classes & Sections).';
        END IF;

        SELECT COUNT(*), string_agg(DISTINCT s.academic_year, ', ')
          INTO v_student_count, v_name
          FROM core.students s
         WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id AND s.is_active
           AND s.academic_year IS DISTINCT FROM (SELECT y.academic_year_name FROM academic.academic_years y
                                                  WHERE y.academic_year_id = p_academic_year_id);
        IF v_student_count > 0 THEN
            RAISE EXCEPTION '% student(s) are still in %. Promote them into this session first (Students › Promotion), then make it current.',
                v_student_count, v_name;
        END IF;

        UPDATE academic.academic_years
        SET is_current = FALSE, updated_by = p_action_user_id, updated_at = NOW()
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND COALESCE(is_deleted, FALSE) = FALSE
          AND academic_year_id <> p_academic_year_id;

        UPDATE academic.academic_years
        SET is_current = TRUE, updated_by = p_action_user_id, updated_at = NOW()
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND academic_year_id = p_academic_year_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

        OPEN p_result FOR
        SELECT TRUE AS success, 'Current academic year updated.' AS message, p_academic_year_id AS academic_year_id;

    ELSIF p_operation = 'DeleteAcademicYear' THEN

        IF p_academic_year_id IS NULL OR p_academic_year_id <= 0 THEN
            RAISE EXCEPTION 'Select an academic year.';
        END IF;

        SELECT academic_year_name, COALESCE(is_current, FALSE) INTO v_year_name, v_was_current
        FROM academic.academic_years
        WHERE academic_year_id = p_academic_year_id
          AND tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

        IF v_year_name IS NULL THEN
            RAISE EXCEPTION 'This academic year no longer exists. Refresh the page.';
        END IF;

        IF v_was_current THEN
            RAISE EXCEPTION 'This is the current session. Set another session as current before deleting it.';
        END IF;

        SELECT COUNT(*) INTO v_class_count
        FROM academic.academic_classes
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND academic_year_id = p_academic_year_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

        SELECT COUNT(*) INTO v_student_count FROM (
            SELECT student_id FROM core.students
             WHERE tenant_id = p_tenant_id AND school_id = p_school_id
               AND academic_year = v_year_name AND COALESCE(is_active, TRUE) = TRUE
            UNION
            SELECT student_id FROM core.student_enrolment
             WHERE tenant_id = p_tenant_id AND school_id = p_school_id
               AND academic_year = v_year_name) s;

        IF v_class_count > 0 OR v_student_count > 0 THEN
            RAISE EXCEPTION 'Cannot delete this year: it has % class(es) and % student(s). Remove those first.',
                v_class_count, v_student_count;
        END IF;

        -- Fee structures, enquiries, counters... keep the name; deleting the
        -- session under them would orphan them just like a rename.
        v_usage := academic.fn_academic_year_name_usage(p_tenant_id, p_school_id, v_year_name);
        IF v_usage IS NOT NULL THEN
            RAISE EXCEPTION 'Cannot delete this year: it is used by %.', v_usage;
        END IF;

        UPDATE academic.academic_years
        SET is_deleted = TRUE, is_active = FALSE, is_current = FALSE,
            deleted_by = p_action_user_id, deleted_at = NOW(),
            updated_by = p_action_user_id, updated_at = NOW()
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND academic_year_id = p_academic_year_id;

        OPEN p_result FOR
        SELECT TRUE AS success, 'Academic year deleted.' AS message, p_academic_year_id AS academic_year_id;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;


-- ── 4. Academic setup (Classes & Sections) proc ─────────────────────────────
CREATE OR REPLACE PROCEDURE academic.sp_school_admin_academic_setup_manage(
    IN p_operation          character varying,
    IN p_tenant_id          integer,
    IN p_school_id          integer,
    IN p_action_user_id     integer,
    IN p_academic_year_id   integer           DEFAULT NULL::integer,
    IN p_academic_year_name character varying DEFAULT NULL::character varying,
    IN p_setup_json         text              DEFAULT NULL::text,
    INOUT p_result          refcursor         DEFAULT 'result_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_academic_year_id   integer;
    v_academic_year_name text;
    v_academic_class_id  integer;

    v_setup_json   jsonb;
    v_class_item   jsonb;
    v_section_item jsonb;
    v_sections     jsonb;
    v_i            integer;
    v_n            integer;
    v_k            integer;

    v_class_name   text;
    v_orig_name    text;
    v_old_name     text;
    v_section_name text;

    v_class_ids    integer[];   -- live class id matched to each payload item (by position)
    v_section_ids  integer[];   -- same, for the sections of one class
    v_keep_classes integer[] := '{}';
    v_keep_secs    integer[];
    v_sec_id       integer;

    v_class_order   integer;
    v_section_order integer;

    v_stream         text;
    v_coordinator    text;
    v_coord_staff_id integer;
    v_capacity       integer;
    v_room_no        text;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    IF p_operation = 'GetAcademicSetup' THEN

        OPEN p_result FOR
        SELECT
            ay.academic_year_id,
            p_tenant_id AS tenant_id,
            p_school_id AS school_id,
            ay.start_date,
            ay.end_date,
            ay.is_current,
            ac.academic_class_id,
            ac.class_name,
            ac.display_order AS class_display_order,
            ac.stream,
            ac.coordinator,
            ac.coordinator_staff_id,
            acs.academic_class_section_id,
            acs.section_name,
            acs.display_order AS section_display_order,
            acs.capacity,
            acs.room_no,
            acs.class_teacher_staff_id,
            cts.full_name AS class_teacher,
            -- Strength for THE SESSION BEING VIEWED, from the per-session
            -- enrolment rows (core.students only holds the present position).
            COALESCE((
                SELECT COUNT(*)
                FROM core.student_enrolment en
                WHERE en.tenant_id = p_tenant_id
                  AND en.school_id = p_school_id
                  AND en.academic_year = ay.academic_year_name
                  AND en.class_name = ac.class_name
                  AND en.section = acs.section_name
                  AND en.status <> 'Left'   -- left mid-session, not on the roll
            ), 0) AS strength
        FROM academic.academic_years ay
        LEFT JOIN academic.academic_classes ac
            ON ac.academic_year_id = ay.academic_year_id
           AND ac.tenant_id = p_tenant_id
           AND ac.school_id = p_school_id
           AND COALESCE(ac.is_deleted, FALSE) = FALSE
        LEFT JOIN academic.academic_class_sections acs
            ON acs.academic_class_id = ac.academic_class_id
           AND acs.academic_year_id = ay.academic_year_id
           AND acs.tenant_id = p_tenant_id
           AND acs.school_id = p_school_id
           AND COALESCE(acs.is_deleted, FALSE) = FALSE
        LEFT JOIN core.staff cts
            ON cts.staff_id = acs.class_teacher_staff_id
           AND cts.tenant_id = p_tenant_id
           AND cts.school_id = p_school_id
           AND COALESCE(cts.is_deleted, FALSE) = FALSE
        WHERE ay.academic_year_id = p_academic_year_id
          AND ay.tenant_id = p_tenant_id
          AND ay.school_id = p_school_id
          AND COALESCE(ay.is_deleted, FALSE) = FALSE
          AND COALESCE(ay.is_active, TRUE) = TRUE
        ORDER BY
            ac.display_order,
            ac.class_name,
            acs.display_order,
            acs.section_name;

    ELSIF p_operation = 'SaveAcademicSetup' THEN

        IF p_academic_year_id IS NULL OR p_academic_year_id <= 0 THEN
            RAISE EXCEPTION 'Please select academic year.';
        END IF;

        v_academic_year_id := p_academic_year_id;
        v_setup_json := COALESCE(NULLIF(p_setup_json, ''), '[]')::jsonb;

        IF jsonb_typeof(v_setup_json) <> 'array' THEN
            RAISE EXCEPTION 'The class list must be a JSON array.';
        END IF;

        -- A live session of THIS school only: another school's id must not
        -- take our classes, and a deleted session must not take any.
        SELECT academic_year_name INTO v_academic_year_name
        FROM academic.academic_years
        WHERE academic_year_id = v_academic_year_id
          AND tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

        IF v_academic_year_name IS NULL THEN
            RAISE EXCEPTION 'Please select academic year.';
        END IF;

        -- Capacity is checked by the controller too; this is the last word.
        SELECT trim(COALESCE(ci ->> 'className', ci ->> 'ClassName', '')),
               trim(COALESCE(si ->> 'sectionName', si ->> 'SectionName', ''))
          INTO v_class_name, v_section_name
        FROM jsonb_array_elements(v_setup_json) ci
        CROSS JOIN jsonb_array_elements(COALESCE(ci -> 'sections', ci -> 'Sections', '[]'::jsonb)) si
        WHERE jsonb_typeof(si) = 'object'
          AND NULLIF(si ->> 'capacity', '') IS NOT NULL
          AND (si ->> 'capacity')::int NOT BETWEEN 1 AND 5000
        LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'Capacity for % - % must be between 1 and 5000.', v_class_name, v_section_name;
        END IF;

        -- Guard: refuse to drop (or rename) a class/section that still has
        -- enrolled students. Students hold the class and section by NAME, so a
        -- section only survives if the payload still carries it by that name.
        IF EXISTS (
            SELECT 1
            FROM academic.academic_classes ac
            JOIN academic.academic_class_sections acs
              ON acs.academic_class_id = ac.academic_class_id
             AND COALESCE(acs.is_deleted, FALSE) = FALSE
            WHERE ac.tenant_id = p_tenant_id
              AND ac.school_id = p_school_id
              AND ac.academic_year_id = v_academic_year_id
              AND COALESCE(ac.is_deleted, FALSE) = FALSE
              AND EXISTS (
                  SELECT 1 FROM core.student_enrolment en
                  WHERE en.tenant_id = p_tenant_id
                    AND en.school_id = p_school_id
                    AND en.academic_year = v_academic_year_name
                    AND en.class_name = ac.class_name
                    AND en.section = acs.section_name
                    AND en.status <> 'Left'
              )
              AND NOT EXISTS (
                  SELECT 1
                  FROM jsonb_array_elements(v_setup_json) ci
                  CROSS JOIN jsonb_array_elements(
                      COALESCE(ci -> 'Sections', ci -> 'sections', '[]'::jsonb)) si
                  WHERE trim(COALESCE(ci ->> 'ClassName', ci ->> 'className', '')) = ac.class_name
                    AND trim(
                          CASE WHEN jsonb_typeof(si) = 'object'
                               THEN COALESCE(si ->> 'SectionName', si ->> 'sectionName', '')
                               ELSE trim(BOTH '"' FROM si::text)
                          END
                        ) = acs.section_name
              )
        ) THEN
            RAISE EXCEPTION 'Cannot remove a class or section that still has enrolled students. Move or promote those students first.';
        END IF;

        -- ── Match every payload class to a live class, keeping its id ──────
        -- WHY: subjects, exam papers and the timetable point at the class /
        -- section ID. The old delete-all + re-insert gave every class a new id
        -- on every save and left all of those pointing at deleted rows.
        -- Pass 1 matches by originalName (what the page loaded, so a rename is
        -- recognised); pass 2 matches the rest by name. An id is used once.
        v_n := jsonb_array_length(v_setup_json);
        v_class_ids := array_fill(NULL::integer, ARRAY[GREATEST(v_n, 1)]);

        FOR v_k IN 1..2 LOOP
            FOR v_i IN 1..v_n LOOP
                CONTINUE WHEN v_class_ids[v_i] IS NOT NULL;
                v_class_item := v_setup_json -> (v_i - 1);
                v_class_name := trim(COALESCE(v_class_item ->> 'ClassName', v_class_item ->> 'className', ''));
                CONTINUE WHEN v_class_name = '';
                v_orig_name := NULLIF(trim(COALESCE(v_class_item ->> 'originalName', v_class_item ->> 'OriginalName', '')), '');
                CONTINUE WHEN v_k = 1 AND v_orig_name IS NULL;

                SELECT academic_class_id INTO v_academic_class_id
                FROM academic.academic_classes
                WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                  AND academic_year_id = v_academic_year_id
                  AND COALESCE(is_deleted, FALSE) = FALSE
                  AND lower(class_name) = lower(CASE WHEN v_k = 1 THEN v_orig_name ELSE v_class_name END)
                  AND NOT (academic_class_id = ANY (v_keep_classes))
                LIMIT 1;

                IF v_academic_class_id IS NOT NULL THEN
                    v_class_ids[v_i] := v_academic_class_id;
                    v_keep_classes := v_keep_classes || v_academic_class_id;
                END IF;
            END LOOP;
        END LOOP;

        -- Only what was really removed goes: those classes and their sections.
        UPDATE academic.academic_class_sections
        SET is_deleted = TRUE, is_active = FALSE,
            deleted_by = p_action_user_id, deleted_at = NOW(),
            updated_by = p_action_user_id, updated_at = NOW()
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND academic_year_id = v_academic_year_id
          AND COALESCE(is_deleted, FALSE) = FALSE
          AND NOT (academic_class_id = ANY (v_keep_classes));

        UPDATE academic.academic_classes
        SET is_deleted = TRUE, is_active = FALSE,
            deleted_by = p_action_user_id, deleted_at = NOW(),
            updated_by = p_action_user_id, updated_at = NOW()
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND academic_year_id = v_academic_year_id
          AND COALESCE(is_deleted, FALSE) = FALSE
          AND NOT (academic_class_id = ANY (v_keep_classes));

        v_class_order := 0;

        FOR v_i IN 1..v_n LOOP
            v_class_item := v_setup_json -> (v_i - 1);
            v_class_name := trim(COALESCE(v_class_item ->> 'ClassName', v_class_item ->> 'className', ''));
            CONTINUE WHEN v_class_name = '';

            v_class_order := v_class_order + 1;
            v_stream      := NULLIF(trim(COALESCE(v_class_item ->> 'stream',      v_class_item ->> 'Stream',      '')), '');
            v_coordinator := NULLIF(trim(COALESCE(v_class_item ->> 'coordinator', v_class_item ->> 'Coordinator', '')), '');
            v_coord_staff_id := NULLIF(COALESCE(v_class_item ->> 'coordinatorStaffId', v_class_item ->> 'CoordinatorStaffId', ''), '')::int;

            -- Snapshot the coordinator's name from the linked staff row; a staff
            -- id that is not this school's is dropped.
            IF COALESCE(v_coord_staff_id, 0) > 0 THEN
                SELECT full_name INTO v_coordinator
                FROM   core.staff
                WHERE  staff_id = v_coord_staff_id
                  AND  tenant_id = p_tenant_id AND school_id = p_school_id
                  AND  COALESCE(is_deleted, FALSE) = FALSE;

                IF v_coordinator IS NULL THEN
                    v_coord_staff_id := NULL;
                END IF;
            END IF;

            v_academic_class_id := v_class_ids[v_i];

            IF v_academic_class_id IS NULL THEN
                INSERT INTO academic.academic_classes
                    (tenant_id, school_id, academic_year_id, class_name, display_order,
                     stream, coordinator, coordinator_staff_id, created_by, created_at, is_deleted, is_active)
                VALUES
                    (p_tenant_id, p_school_id, v_academic_year_id, v_class_name,
                     COALESCE(NULLIF(v_class_item ->> 'displayOrder', '')::int, v_class_order),
                     v_stream, v_coordinator, NULLIF(COALESCE(v_coord_staff_id, 0), 0),
                     p_action_user_id, NOW(), FALSE, TRUE)
                RETURNING academic_class_id INTO v_academic_class_id;
            ELSE
                SELECT class_name INTO v_old_name
                FROM academic.academic_classes WHERE academic_class_id = v_academic_class_id;

                -- A rename keeps the class id (so subjects, exams, timetable and
                -- class teachers stay) and carries the new name into this
                -- session's fee structures, the one other place a class name is
                -- stored without a student behind it. Renaming a class that has
                -- students was already refused by the guard above.
                IF v_old_name IS DISTINCT FROM v_class_name AND EXISTS (
                    SELECT 1 FROM core.school_fee_structures
                    WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                      AND academic_year = v_academic_year_name AND class_name = v_old_name
                ) THEN
                    IF length(v_class_name) > 30 THEN
                        RAISE EXCEPTION 'Cannot rename % to %: it has a fee structure, and a fee structure class name can be at most 30 characters.',
                            v_old_name, v_class_name;
                    END IF;
                    IF EXISTS (
                        SELECT 1 FROM core.school_fee_structures
                        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                          AND academic_year = v_academic_year_name AND class_name = v_class_name
                    ) THEN
                        RAISE EXCEPTION 'Cannot rename % to %: a fee structure for % already exists in this session.',
                            v_old_name, v_class_name, v_class_name;
                    END IF;

                    UPDATE core.school_fee_structures
                    SET class_name = v_class_name, updated_by = p_action_user_id, updated_at = NOW()
                    WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                      AND academic_year = v_academic_year_name AND class_name = v_old_name;
                END IF;

                UPDATE academic.academic_classes
                SET class_name           = v_class_name,
                    display_order        = COALESCE(NULLIF(v_class_item ->> 'displayOrder', '')::int, v_class_order),
                    stream               = v_stream,
                    coordinator          = v_coordinator,
                    coordinator_staff_id = NULLIF(COALESCE(v_coord_staff_id, 0), 0),
                    updated_by           = p_action_user_id,
                    updated_at           = NOW()
                WHERE academic_class_id = v_academic_class_id;
            END IF;

            -- ── Sections of this class: same two-pass match, by id ──────────
            v_sections := COALESCE(v_class_item -> 'Sections', v_class_item -> 'sections', '[]'::jsonb);
            v_section_ids := array_fill(NULL::integer, ARRAY[GREATEST(jsonb_array_length(v_sections), 1)]);
            v_keep_secs := '{}';

            FOR v_k IN 1..2 LOOP
                FOR v_section_order IN 1..jsonb_array_length(v_sections) LOOP
                    CONTINUE WHEN v_section_ids[v_section_order] IS NOT NULL;
                    v_section_item := v_sections -> (v_section_order - 1);
                    IF jsonb_typeof(v_section_item) = 'object' THEN
                        v_section_name := trim(COALESCE(v_section_item ->> 'sectionName', v_section_item ->> 'SectionName', ''));
                        v_orig_name    := NULLIF(trim(COALESCE(v_section_item ->> 'originalName', v_section_item ->> 'OriginalName', '')), '');
                    ELSE
                        v_section_name := trim(trim(BOTH '"' FROM v_section_item::text));
                        v_orig_name    := NULL;
                    END IF;
                    CONTINUE WHEN v_section_name = '';
                    CONTINUE WHEN v_k = 1 AND v_orig_name IS NULL;

                    SELECT academic_class_section_id INTO v_sec_id
                    FROM academic.academic_class_sections
                    WHERE academic_class_id = v_academic_class_id
                      AND COALESCE(is_deleted, FALSE) = FALSE
                      AND lower(section_name) = lower(CASE WHEN v_k = 1 THEN v_orig_name ELSE v_section_name END)
                      AND NOT (academic_class_section_id = ANY (v_keep_secs))
                    LIMIT 1;

                    IF v_sec_id IS NOT NULL THEN
                        v_section_ids[v_section_order] := v_sec_id;
                        v_keep_secs := v_keep_secs || v_sec_id;
                    END IF;
                END LOOP;
            END LOOP;

            UPDATE academic.academic_class_sections
            SET is_deleted = TRUE, is_active = FALSE,
                deleted_by = p_action_user_id, deleted_at = NOW(),
                updated_by = p_action_user_id, updated_at = NOW()
            WHERE academic_class_id = v_academic_class_id
              AND COALESCE(is_deleted, FALSE) = FALSE
              AND NOT (academic_class_section_id = ANY (v_keep_secs));

            v_k := 0;   -- position among the non-blank sections
            FOR v_section_order IN 1..jsonb_array_length(v_sections) LOOP
                v_section_item := v_sections -> (v_section_order - 1);
                IF jsonb_typeof(v_section_item) = 'object' THEN
                    v_section_name := trim(COALESCE(v_section_item ->> 'sectionName', v_section_item ->> 'SectionName', ''));
                    v_capacity     := NULLIF(v_section_item ->> 'capacity', '')::int;
                    v_room_no      := NULLIF(trim(COALESCE(v_section_item ->> 'roomNo', '')), '');
                ELSE
                    v_section_name := trim(trim(BOTH '"' FROM v_section_item::text));
                    v_capacity     := NULL;
                    v_room_no      := NULL;
                END IF;
                CONTINUE WHEN v_section_name = '';
                v_k := v_k + 1;

                IF v_section_ids[v_section_order] IS NULL THEN
                    INSERT INTO academic.academic_class_sections
                        (tenant_id, school_id, academic_year_id, academic_class_id, section_name,
                         display_order, capacity, room_no,
                         created_by, created_at, is_deleted, is_active)
                    VALUES
                        (p_tenant_id, p_school_id, v_academic_year_id, v_academic_class_id, v_section_name,
                         v_k, v_capacity, v_room_no,
                         p_action_user_id, NOW(), FALSE, TRUE);
                ELSE
                    -- In place: the class teacher (set on its own page) and the
                    -- timetable stay with the section.
                    UPDATE academic.academic_class_sections
                    SET section_name  = v_section_name,
                        display_order = v_k,
                        capacity      = v_capacity,
                        room_no       = v_room_no,
                        updated_by    = p_action_user_id,
                        updated_at    = NOW()
                    WHERE academic_class_section_id = v_section_ids[v_section_order];
                END IF;
            END LOOP;
        END LOOP;

        OPEN p_result FOR
        SELECT
            TRUE AS success,
            'Saved successfully.' AS message,
            v_academic_year_id AS academic_year_id;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;


