-- Bundle 2026-10-14p: QA round 3, batch 2c (joining month due on the joining day, BUG-100). Run with:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_14p.sql
-- Sources (re-runnable): student_money_lifecycle.sql

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
-- student billed for six.
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
                                                      f.frequency, COALESCE(p_from, CURRENT_DATE)))::integer AS instalments
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
