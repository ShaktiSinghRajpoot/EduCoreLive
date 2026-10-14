-- Bundle 2026-10-15a: session change -- copy fee structure, Year-End status / close / reopen, promotion roll numbers. Run with:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_15a.sql
-- Sources (re-runnable): fee_structure_copy.sql, fee_year_end.sql, student_promotion.sql

-- ============================================================================
-- Copy the fee structure into a new session (School Setup › Fee Structure)
--
-- A new session starts with no fee structure, so promotion billed nobody until
-- every class was typed in again by hand. This copies each class's structure
-- from an earlier session, optionally raised by a percentage (rounded to whole
-- rupees). Classes that already have a structure in the target session are
-- left as they are, so it is safe to run twice.
--
-- The totals are worked out the same way SaveFeeStructure does it
-- (fee_structure_manage.sql): by each fee head's cycle.
--
--   core.sp_fee_structure_copy(tenant, school, user, from_year, to_year, increase_percent)
--   one row: copied (classes), skipped (already had one), message
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

CREATE OR REPLACE PROCEDURE core.sp_fee_structure_copy(
    IN    p_tenant_id        integer,
    IN    p_school_id        integer,
    IN    p_action_user_id   integer,
    IN    p_from_year        varchar,
    IN    p_to_year          varchar,
    IN    p_increase_percent numeric DEFAULT 0,
    INOUT p_result           refcursor DEFAULT 'fee_copy_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    src        record;
    v_new_id   integer;
    v_factor   numeric := 1 + COALESCE(p_increase_percent, 0) / 100;
    v_copied   integer := 0;
    v_skipped  integer := 0;
    v_one      numeric; v_mon numeric; v_qtr numeric; v_half numeric; v_year numeric;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;
    IF COALESCE(trim(p_from_year), '') = '' OR COALESCE(trim(p_to_year), '') = '' THEN
        RAISE EXCEPTION 'Choose the session to copy from and the session to copy into.';
    END IF;
    IF p_from_year = p_to_year THEN
        RAISE EXCEPTION 'Choose two different sessions.';
    END IF;
    IF COALESCE(p_increase_percent, 0) < 0 OR COALESCE(p_increase_percent, 0) > 100 THEN
        RAISE EXCEPTION 'The increase must be between 0 and 100 percent.';
    END IF;

    FOR src IN
        SELECT s.fee_structure_id, s.class_name
          FROM core.school_fee_structures s
         WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id
           AND s.academic_year = p_from_year AND NOT COALESCE(s.is_deleted, FALSE)
         ORDER BY s.class_name
    LOOP
        -- a class already set up in the new session keeps its own structure
        IF EXISTS (SELECT 1 FROM core.school_fee_structures t
                    WHERE t.tenant_id = p_tenant_id AND t.school_id = p_school_id
                      AND t.class_name = src.class_name AND t.academic_year = p_to_year
                      AND NOT COALESCE(t.is_deleted, FALSE)) THEN
            v_skipped := v_skipped + 1;
            CONTINUE;
        END IF;

        -- totals by the fee head's cycle, from the new (raised, whole-rupee) amounts
        SELECT COALESCE(SUM(x.amount) FILTER (WHERE x.cycle = 'one time'), 0),
               COALESCE(SUM(x.amount) FILTER (WHERE x.cycle = 'monthly'), 0),
               COALESCE(SUM(x.amount) FILTER (WHERE x.cycle = 'quarterly'), 0),
               COALESCE(SUM(x.amount) FILTER (WHERE x.cycle = 'half yearly'), 0),
               COALESCE(SUM(x.amount) FILTER (WHERE x.cycle NOT IN ('one time', 'monthly', 'quarterly', 'half yearly')), 0)
          INTO v_one, v_mon, v_qtr, v_half, v_year
          FROM (SELECT lower(trim(h.frequency)) AS cycle, ROUND(d.amount * v_factor) AS amount
                  FROM core.school_fee_structure_details d
                  JOIN core.school_fee_heads h ON h.fee_head_id = d.fee_head_id
                 WHERE d.fee_structure_id = src.fee_structure_id
                   AND NOT COALESCE(d.is_deleted, FALSE) AND COALESCE(d.is_selected, TRUE)
                   AND NOT COALESCE(h.is_deleted, FALSE)) x;

        -- a deleted row of the same class + session is reused (the key is unique)
        INSERT INTO core.school_fee_structures
            (tenant_id, school_id, class_name, academic_year,
             one_time_total, monthly_total, quarterly_total, half_yearly_total,
             yearly_total, annual_total, is_active, is_deleted, created_by, created_at)
        VALUES
            (p_tenant_id, p_school_id, src.class_name, p_to_year,
             v_one, v_mon, v_qtr, v_half, v_year,
             v_one + v_mon * 12 + v_qtr * 4 + v_half * 2 + v_year,
             TRUE, FALSE, p_action_user_id, now())
        ON CONFLICT (tenant_id, school_id, class_name, academic_year) DO UPDATE
           SET one_time_total = EXCLUDED.one_time_total, monthly_total = EXCLUDED.monthly_total,
               quarterly_total = EXCLUDED.quarterly_total, half_yearly_total = EXCLUDED.half_yearly_total,
               yearly_total = EXCLUDED.yearly_total, annual_total = EXCLUDED.annual_total,
               is_active = TRUE, is_deleted = FALSE, updated_by = p_action_user_id, updated_at = now()
        RETURNING fee_structure_id INTO v_new_id;

        -- clear what a deleted row may still hold, then copy the heads
        DELETE FROM core.school_fee_structure_details WHERE fee_structure_id = v_new_id;
        INSERT INTO core.school_fee_structure_details
            (tenant_id, school_id, fee_structure_id, fee_head_id, fee_head_name,
             frequency, amount, is_selected, is_deleted, created_by, created_at)
        SELECT p_tenant_id, p_school_id, v_new_id, d.fee_head_id, h.fee_head_name,
               h.frequency, ROUND(d.amount * v_factor), TRUE, FALSE, p_action_user_id, now()
          FROM core.school_fee_structure_details d
          JOIN core.school_fee_heads h ON h.fee_head_id = d.fee_head_id
         WHERE d.fee_structure_id = src.fee_structure_id
           AND NOT COALESCE(d.is_deleted, FALSE) AND COALESCE(d.is_selected, TRUE)
           AND NOT COALESCE(h.is_deleted, FALSE);

        v_copied := v_copied + 1;
    END LOOP;

    IF v_copied = 0 AND v_skipped = 0 THEN
        RAISE EXCEPTION 'Session % has no fee structure to copy.', p_from_year;
    END IF;

    OPEN p_result FOR
    SELECT v_copied AS copied, v_skipped AS skipped,
           v_copied || ' class(es) copied into ' || p_to_year
           || CASE WHEN COALESCE(p_increase_percent, 0) > 0 THEN ' with a ' || trim_scale(p_increase_percent) || '% increase' ELSE '' END
           || CASE WHEN v_skipped > 0 THEN '; ' || v_skipped || ' already had a structure and were left as they are' ELSE '' END
           || '.' AS message;
END;
$procedure$;


-- ============================================================================
-- Year-End Fee Closure (Fee › Year-End).
--
-- Before a session is closed, the school goes through every fee line still
-- unpaid in that session and decides, line by line or a whole student at once:
--   Carry     -> the due MOVES into the next session: its academic_year becomes
--                the next session and carried_from keeps where it came from.
--                So it leaves this session's defaulters and appears in the
--                next one's. The next session must exist (School Setup › Sessions).
--   Write off -> the unpaid part is CLOSED with core.fn_ledger_close (source
--                'YearEnd', reason required), exactly as Exit closes dues, so
--                every report that reads amount_due - amount_paid - concession
--                shows 0 for it without being changed. The app allows it only to
--                fees.writeoff (school admin / principal), not to a cashier.
--   Undo      -> a write-off is put back with core.fn_ledger_reopen; a carried
--                line goes back to the session it came from.
-- Only lines that are already DUE (due date today or earlier) can be carried or
-- written off: next month's fee is not a year-end matter (QA BUG-091).
--   Status -> next session, whether the session is closed, lines still to decide.
--   Close  -> once every line is carried or written off, the session's fees are
--             closed: nothing on this page can change until it is re-opened.
--   Reopen -> undoes Close (fees.writeoff, like a write-off).
--
-- Needs student_money_lifecycle.sql (fn_ledger_close / fn_ledger_reopen).
-- Re-runnable.
-- ============================================================================

ALTER TABLE core.student_ledger
    ADD COLUMN IF NOT EXISTS carried_by   integer,
    ADD COLUMN IF NOT EXISTS carried_at   timestamptz,
    ADD COLUMN IF NOT EXISTS carried_from varchar(20);

-- The first version only marked a line "carried" without moving it. Those marks
-- meant nothing to any report, so they are cleared: the lines are open again.
UPDATE core.student_ledger SET carried_at = NULL, carried_by = NULL
 WHERE carried_at IS NOT NULL AND carried_from IS NULL;

-- When the session's fees were closed on the Year-End page (NULL = open).
ALTER TABLE academic.academic_years
    ADD COLUMN IF NOT EXISTS fees_closed_at timestamptz,
    ADD COLUMN IF NOT EXISTS fees_closed_by integer;

-- Writing dues off is a decision for the head of school, not the fee counter.
INSERT INTO config.permissions (permission_key, module_group, display_name, sort_order)
VALUES ('fees.writeoff', 'Finance', 'Fees & Collection — Write off dues (year-end)', 78)
ON CONFLICT (permission_key) DO NOTHING;


CREATE OR REPLACE PROCEDURE core.sp_fee_year_end_manage(
    IN    p_operation      varchar,    -- List | Status | Carry | WriteOff | Undo | CarryAll | Close | Reopen
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_academic_year  varchar,
    IN    p_ledger_id      integer DEFAULT NULL,   -- one line ...
    IN    p_student_id     integer DEFAULT NULL,   -- ... or every open line of one student
    IN    p_reason         varchar DEFAULT NULL,   -- required for WriteOff
    INOUT p_result         refcursor DEFAULT 'year_end_cursor')
LANGUAGE plpgsql
AS $$
DECLARE
    v_year   varchar := lower(NULLIF(trim(p_academic_year), ''));
    v_reason varchar := NULLIF(trim(p_reason), '');
    v_next   varchar;            -- the session after v_year, where carried dues go
    v_count  integer := 0;
    v_amount numeric(12,2) := 0;
    v_closed timestamptz;        -- when this session's fees were closed (NULL = open)
    v_open   integer := 0;       -- lines still to decide
    v_notdue integer := 0;       -- ... of which not due yet
    r        record;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;
    IF v_year IS NULL THEN
        RAISE EXCEPTION 'Choose a session.';
    END IF;

    SELECT n.academic_year_name INTO v_next
      FROM academic.academic_years n
      JOIN academic.academic_years cur ON cur.tenant_id = n.tenant_id AND cur.school_id = n.school_id
                                      AND lower(cur.academic_year_name) = v_year AND NOT COALESCE(cur.is_deleted, FALSE)
     WHERE n.tenant_id = p_tenant_id AND n.school_id = p_school_id AND NOT COALESCE(n.is_deleted, FALSE)
       AND n.start_date > cur.start_date
     ORDER BY n.start_date
     LIMIT 1;

    SELECT y.fees_closed_at INTO v_closed
      FROM academic.academic_years y
     WHERE y.tenant_id = p_tenant_id AND y.school_id = p_school_id
       AND lower(y.academic_year_name) = v_year AND NOT COALESCE(y.is_deleted, FALSE)
     LIMIT 1;

    -- Lines of this session still unpaid and not yet carried or written off.
    SELECT COUNT(*), COUNT(*) FILTER (WHERE NULLIF(l.due_date, '')::date > CURRENT_DATE)
      INTO v_open, v_notdue
      FROM core.student_ledger l
      JOIN core.students s ON s.student_id = l.student_id
     WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
       AND lower(COALESCE(NULLIF(trim(l.academic_year), ''), s.academic_year)) = v_year
       AND l.amount_due > l.amount_paid + l.concession
       AND COALESCE(l.close_source, '') <> 'YearEnd';

    -- ── Status: what the page needs to know about the session as a whole
    IF p_operation = 'Status' THEN
        OPEN p_result FOR
        SELECT v_next AS next_session, v_closed AS closed_at,
               (SELECT core.fn_user_display_name(y.fees_closed_by) FROM academic.academic_years y
                 WHERE y.tenant_id = p_tenant_id AND y.school_id = p_school_id
                   AND lower(y.academic_year_name) = v_year LIMIT 1) AS closed_by,
               v_open AS open_lines, v_notdue AS not_due_lines;
        RETURN;
    END IF;

    -- ── Close / Reopen the session's fees
    IF p_operation = 'Close' THEN
        IF v_closed IS NOT NULL THEN
            RAISE EXCEPTION 'This session is already closed.';
        END IF;
        IF v_open > 0 THEN
            RAISE EXCEPTION '% fee line(s) are still to decide% Carry or write off every line first.',
                v_open, CASE WHEN v_notdue > 0 THEN ' (' || v_notdue || ' not due yet).' ELSE '.' END;
        END IF;
        UPDATE academic.academic_years
           SET fees_closed_at = now(), fees_closed_by = p_action_user_id
         WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND lower(academic_year_name) = v_year;
        OPEN p_result FOR SELECT 'Session ' || p_academic_year || ' is closed.' AS message;
        RETURN;
    END IF;
    IF p_operation = 'Reopen' THEN
        IF v_closed IS NULL THEN
            RAISE EXCEPTION 'This session is not closed.';
        END IF;
        UPDATE academic.academic_years
           SET fees_closed_at = NULL, fees_closed_by = NULL
         WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND lower(academic_year_name) = v_year;
        OPEN p_result FOR SELECT 'Session ' || p_academic_year || ' is open again.' AS message;
        RETURN;
    END IF;

    -- ── List: the session's open lines, its write-offs, and what it carried forward
    IF p_operation = 'List' THEN
        OPEN p_result FOR
        SELECT l.ledger_id, l.student_id, s.student_name, s.admission_no, s.class_name, s.section,
               s.guardian_name, s.mobile,
               l.fee_head_name, l.installment_label, l.due_date,
               CASE WHEN l.close_source = 'YearEnd' THEN l.closed_amount
                    ELSE l.amount_due - l.amount_paid - l.concession END   AS amount,
               CASE WHEN l.close_source = 'YearEnd'          THEN 'WrittenOff'
                    WHEN lower(l.carried_from) = v_year      THEN 'Carried'
                    ELSE 'Open' END                                         AS state,
               (NULLIF(l.due_date, '')::date > CURRENT_DATE)               AS not_due,
               CASE WHEN l.close_source = 'YearEnd' THEN l.close_reason
                    WHEN lower(l.carried_from) = v_year THEN 'Moved to ' || l.academic_year END AS reason,
               COALESCE(CASE WHEN l.close_source = 'YearEnd' THEN l.closed_at END, l.carried_at) AS decided_at,
               v_next AS next_session
          FROM core.student_ledger l
          JOIN core.students s ON s.student_id = l.student_id
                              AND s.tenant_id = p_tenant_id AND s.school_id = p_school_id
         WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
           AND (   (lower(COALESCE(NULLIF(trim(l.academic_year), ''), s.academic_year)) = v_year
                    AND (l.amount_due > l.amount_paid + l.concession
                         OR (l.close_source = 'YearEnd' AND l.closed_amount > 0)))
                OR (lower(l.carried_from) = v_year AND l.amount_due > l.amount_paid + l.concession))
         ORDER BY s.class_name, s.section, s.student_name, l.student_id, l.due_date NULLS LAST, l.ledger_id;
        RETURN;
    END IF;

    IF p_operation NOT IN ('Carry', 'WriteOff', 'Undo', 'CarryAll') THEN
        RAISE EXCEPTION 'Unknown operation.';
    END IF;
    IF v_closed IS NOT NULL THEN
        RAISE EXCEPTION 'Session % is closed. Re-open it to change anything.', p_academic_year;
    END IF;
    IF p_operation = 'WriteOff' AND v_reason IS NULL THEN
        RAISE EXCEPTION 'Give a reason for the write-off.';
    END IF;
    IF p_operation IN ('Carry', 'WriteOff') AND p_ledger_id IS NULL AND p_student_id IS NULL THEN
        RAISE EXCEPTION 'Choose a fee line or a student.';
    END IF;
    IF p_operation = 'Undo' AND p_ledger_id IS NULL THEN
        RAISE EXCEPTION 'Choose a fee line.';
    END IF;
    IF p_operation IN ('Carry', 'CarryAll') AND v_next IS NULL THEN
        RAISE EXCEPTION 'Create the next session first (School Setup › Sessions): carried dues move into it.';
    END IF;

    -- The lines this call acts on, always inside this school: the session's own
    -- lines, and for Undo also the lines it carried into the next session.
    FOR r IN
        SELECT l.ledger_id, l.carried_from, l.close_source, l.closed_amount,
               l.amount_due - l.amount_paid - l.concession AS open_amount,
               COALESCE(NULLIF(l.due_date, '')::date, CURRENT_DATE) <= CURRENT_DATE AS is_due,
               lower(COALESCE(NULLIF(trim(l.academic_year), ''), s.academic_year)) = v_year AS in_session
          FROM core.student_ledger l
          JOIN core.students s ON s.student_id = l.student_id
         WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
           AND (lower(COALESCE(NULLIF(trim(l.academic_year), ''), s.academic_year)) = v_year
                OR (p_operation = 'Undo' AND lower(l.carried_from) = v_year))
           AND (p_ledger_id  IS NULL OR l.ledger_id  = p_ledger_id)
           AND (p_student_id IS NULL OR l.student_id = p_student_id)
         ORDER BY l.ledger_id
           FOR UPDATE OF l
    LOOP
        IF p_operation = 'Undo' THEN
            IF r.close_source = 'YearEnd' AND r.closed_amount > 0 THEN
                v_amount := v_amount + core.fn_ledger_reopen(r.ledger_id);
                v_count  := v_count + 1;
            ELSIF lower(r.carried_from) = v_year THEN
                UPDATE core.student_ledger
                   SET academic_year = carried_from, carried_from = NULL, carried_at = NULL, carried_by = NULL, updated_at = now()
                 WHERE ledger_id = r.ledger_id;
                v_amount := v_amount + r.open_amount;
                v_count  := v_count + 1;
            END IF;

        ELSIF r.open_amount > 0 AND r.in_session THEN
            IF NOT r.is_due THEN
                -- one line asked for by name gets a reason; a student / CarryAll just skips it
                IF p_ledger_id IS NOT NULL THEN
                    RAISE EXCEPTION 'This fee is not due yet. Only dues of past and current months can be carried or written off.';
                END IF;
                CONTINUE;
            END IF;
            IF p_operation = 'WriteOff' THEN
                v_amount := v_amount + core.fn_ledger_close(r.ledger_id, v_reason, 'YearEnd', p_action_user_id);
                v_count  := v_count + 1;
            ELSE   -- Carry / CarryAll: move into the next session
                UPDATE core.student_ledger
                   SET carried_from = COALESCE(NULLIF(trim(academic_year), ''), (SELECT s2.academic_year FROM core.students s2 WHERE s2.student_id = student_ledger.student_id)),
                       academic_year = v_next, carried_at = now(), carried_by = p_action_user_id, updated_at = now()
                 WHERE ledger_id = r.ledger_id;
                v_amount := v_amount + r.open_amount;
                v_count  := v_count + 1;
            END IF;
        END IF;
    END LOOP;

    IF v_count = 0 THEN
        RAISE EXCEPTION 'Nothing to change: the line is already settled, decided or not due yet.';
    END IF;

    OPEN p_result FOR
    SELECT v_count AS lines, v_amount AS amount,
           CASE p_operation
                WHEN 'WriteOff' THEN 'Written off'
                WHEN 'Undo'     THEN 'Undone'
                ELSE 'Carried to ' || v_next END
           || ': ' || v_count || ' line(s), Rs ' || to_char(v_amount, 'FM99,99,99,990.00') AS message;
END;
$$;


-- ============================================================================
-- Bulk student promotion — moving a class into the next academic session.
--
-- core.students holds ONE row per student: class_name, section and
-- academic_year live on that row, and there is no per-year enrolment table.
-- The unique (tenant_id, school_id, admission_no) constraint also forbids a
-- second row for the same student in a new year. So promotion is an in-place
-- UPDATE of the student row, exactly like the exit flow: the student_id never
-- changes, so the fee ledger, receipts and TC register keep pointing at it.
--
-- History is kept separately in core.student_promotion_history, because the
-- student row itself remembers nothing about the class it came from.
--
--   core.student_promotion_history  one row per student per promotion run
--   core.sp_class_ladder            classes in real teaching order
--   core.sp_student_promote         the promotion itself
--
-- outcome values:
--   Promote   moved up to the next class in the ladder, new session
--   Retain    stays in the same class, new session
--   PassOut   completed the final class -> inactive, TC-eligible
--
-- PREREQUISITE: the target session must already have its classes and sections
-- (see academic_session_rollover.sql). Classes are per-session rows, so a new
-- session is empty until the structure is copied forward, and promoting into an
-- empty session would write students onto classes that do not exist.
--
-- MONEY: Promote / Retain bill the target class's recurring fee structure for
-- the new session (once per student per session) and re-bill a kept bus route;
-- PassOut closes later dues like an exit. Depends on student_money_lifecycle.sql,
-- transport_module.sql and student_exit.sql -- apply those first.
-- ============================================================================

-- ── history ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS core.student_promotion_history (
    promotion_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     integer      NOT NULL,
    school_id     integer      NOT NULL,
    student_id    integer      NOT NULL REFERENCES core.students(student_id) ON DELETE CASCADE,
    from_year     varchar(20)  NOT NULL,
    from_class    varchar(50)  NOT NULL,
    from_section  varchar(20),
    to_year       varchar(20)  NOT NULL,
    to_class      varchar(50),
    to_section    varchar(20),
    outcome       varchar(20)  NOT NULL,
    dues_carried  numeric(12,2) NOT NULL DEFAULT 0,
    promoted_by   integer      NOT NULL DEFAULT 0,
    promoted_at   timestamptz  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_student_promotion_history_student
    ON core.student_promotion_history (student_id);
CREATE INDEX IF NOT EXISTS idx_student_promotion_history_year
    ON core.student_promotion_history (tenant_id, school_id, to_year);

COMMENT ON TABLE core.student_promotion_history IS
    'Audit trail of promotions. The student row is updated in place, so this is the only record of which class a student came from.';
COMMENT ON COLUMN core.student_promotion_history.dues_carried IS
    'Outstanding balance at the moment of promotion. The ledger is not year-scoped, so the dues simply follow the student; this is the snapshot.';


-- ── the class ladder ───────────────────────────────────────────────────────
-- config.sp_dropdown_common returns classes newest-id-first, which is NOT
-- teaching order — using it to work out "the next class" walks DOWN the
-- school. display_order is the column meant for this, so promotion (and the
-- page's "next class" preview) reads the ladder from here instead.
--
-- Classes are per-session rows, so the ladder MUST be scoped to one session.
-- Unscoped it returns every session's classes concatenated, which reads as
-- "1st, 1st, 2nd, 2nd, ..." the moment a second session has structure.
-- p_academic_year_name is optional; NULL means the current session.
DROP PROCEDURE IF EXISTS core.sp_class_ladder(integer, integer, integer, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_class_ladder(
    IN  p_tenant_id         integer,
    IN  p_school_id         integer,
    IN  p_action_user_id    integer,
    IN  p_academic_year_name character varying DEFAULT NULL,
    INOUT p_result          refcursor DEFAULT 'class_ladder_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_year varchar := NULLIF(TRIM(COALESCE(p_academic_year_name, '')), '');
    v_year_id integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        OPEN p_result FOR SELECT WHERE FALSE;
        RETURN;
    END IF;

    SELECT academic_year_id INTO v_year_id
    FROM   academic.academic_years
    WHERE  tenant_id = p_tenant_id
      AND  school_id = p_school_id
      AND  COALESCE(is_deleted, FALSE) = FALSE
      AND  (   (v_year IS NOT NULL AND academic_year_name = v_year)
            OR (v_year IS NULL     AND COALESCE(is_current, FALSE) = TRUE))
    LIMIT 1;

    IF v_year_id IS NULL THEN
        OPEN p_result FOR SELECT WHERE FALSE;
        RETURN;
    END IF;

    -- display_order comes back too: the Promotion page needs it to work out the
    -- next class exactly the way this proc's caller does (order from the SOURCE
    -- session, then the first higher class in the TARGET). Names alone are not
    -- enough once the two sessions hold different classes. Additive column —
    -- existing consumers read by name, so they are unaffected.
    OPEN p_result FOR
    SELECT class_name, display_order
    FROM academic.academic_classes
    WHERE tenant_id = p_tenant_id
      AND school_id = p_school_id
      AND academic_year_id = v_year_id
      AND COALESCE(is_deleted, FALSE) = FALSE
      AND COALESCE(is_active,  TRUE)  = TRUE
    ORDER BY display_order, academic_class_id;
    RETURN;
END;
$procedure$;


-- ── promote ────────────────────────────────────────────────────────────────
-- p_students is [{"studentId":1,"outcome":"promote"}, ...]. The target class
-- is NOT taken from the browser: it is derived here from the ladder above, so
-- a stale page cannot write the wrong class.
--
-- A student who cannot be promoted is skipped and reported, not fatal — one
-- student on a stale page should not roll back the whole class.
CREATE OR REPLACE PROCEDURE core.sp_student_promote(
    IN  p_tenant_id      integer,
    IN  p_school_id      integer,
    IN  p_action_user_id integer,
    IN  p_source_year    varchar,
    IN  p_target_year    varchar,
    IN  p_target_section varchar DEFAULT NULL,   -- NULL / 'keep' = keep the student's section
    IN  p_carry_dues     boolean DEFAULT TRUE,
    IN  p_students       jsonb   DEFAULT '[]'::jsonb,
    INOUT p_result       refcursor DEFAULT 'student_promote_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    r             record;
    v_src         varchar := TRIM(COALESCE(p_source_year, ''));
    v_tgt         varchar := TRIM(COALESCE(p_target_year, ''));
    v_sec         varchar := NULLIF(TRIM(COALESCE(p_target_section, '')), '');
    v_src_year_id integer;
    v_tgt_year_id integer;
    v_tgt_classes integer := 0;
    v_cur_order   integer;
    v_pick_order  integer;   -- display_order of an explicitly chosen target class
    v_outcome     varchar;
    v_next        varchar;
    v_to_class    varchar;
    v_to_section  varchar;
    v_dues        numeric(12,2);
    v_promoted    integer := 0;
    v_retained    integer := 0;
    v_passed      integer := 0;
    v_skipped     text[]  := '{}';
    v_tgt_start   date;
    v_plan        jsonb;
    v_billed      integer := 0;
    v_roll        varchar;   -- the roll number in the new class (see below)
    v_unbilled    text[]  := '{}';
    v_route       integer;
    v_stop        integer;
    v_bus         refcursor;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    IF v_src = '' OR v_tgt = '' THEN
        RAISE EXCEPTION 'Choose both the current and the new academic session.';
    END IF;

    IF LOWER(v_src) = LOWER(v_tgt) THEN
        RAISE EXCEPTION 'The new session must be different from the current session.';
    END IF;

    SELECT academic_year_id, start_date::date INTO v_tgt_year_id, v_tgt_start
    FROM   academic.academic_years
    WHERE  tenant_id = p_tenant_id
      AND  school_id = p_school_id
      AND  academic_year_name = v_tgt
      AND  COALESCE(is_deleted, FALSE) = FALSE
      AND  COALESCE(is_active,  TRUE)  = TRUE;

    IF v_tgt_year_id IS NULL THEN
        RAISE EXCEPTION 'Academic session % is not set up for this school.', v_tgt;
    END IF;

    -- The session EXISTING is not enough. Classes and sections are per-session
    -- rows, so a freshly created session is empty, and promoting into it writes
    -- students into a class that does not exist anywhere in the setup — they
    -- then vanish from every class-filtered page. Stop before that happens.
    SELECT COUNT(*) INTO v_tgt_classes
    FROM   academic.academic_classes
    WHERE  tenant_id = p_tenant_id
      AND  school_id = p_school_id
      AND  academic_year_id = v_tgt_year_id
      AND  COALESCE(is_deleted, FALSE) = FALSE
      AND  COALESCE(is_active,  TRUE)  = TRUE;

    IF v_tgt_classes = 0 THEN
        RAISE EXCEPTION 'Session % has no classes or sections yet. Open Settings > Classes & Sections, pick %, and copy the structure from the previous session before promoting.', v_tgt, v_tgt;
    END IF;

    -- Optional: used only to read the student's current position on the ladder.
    SELECT academic_year_id INTO v_src_year_id
    FROM   academic.academic_years
    WHERE  tenant_id = p_tenant_id
      AND  school_id = p_school_id
      AND  academic_year_name = v_src
      AND  COALESCE(is_deleted, FALSE) = FALSE;

    IF p_students IS NULL OR jsonb_array_length(p_students) = 0 THEN
        RAISE EXCEPTION 'No students were selected.';
    END IF;

    -- 'keep' is the page's own token for "leave the section alone".
    IF v_sec IS NOT NULL AND LOWER(v_sec) = 'keep' THEN
        v_sec := NULL;
    END IF;

    FOR r IN
        -- Column names are quoted so they match the camelCase JSON keys exactly —
        -- unquoted identifiers fold to lowercase and would never match "studentId".
        SELECT x."studentId"                             AS student_id,
               LOWER(TRIM(COALESCE(x.outcome, '')))       AS outcome,
               NULLIF(TRIM(COALESCE(x."toClass", '')), '') AS to_class
        FROM jsonb_to_recordset(p_students) AS x("studentId" integer, outcome text, "toClass" text)
    LOOP
        DECLARE
            s core.students%ROWTYPE;
        BEGIN
            SELECT * INTO s
            FROM core.students
            WHERE student_id = r.student_id
              AND tenant_id  = p_tenant_id
              AND school_id  = p_school_id
            FOR UPDATE;

            IF NOT FOUND THEN
                v_skipped := v_skipped || ('#' || COALESCE(r.student_id::text, '?') || ' (not found)');
                CONTINUE;
            END IF;

            IF NOT s.is_active THEN
                v_skipped := v_skipped || (s.student_name || ' (already left)');
                CONTINUE;
            END IF;

            -- Guards a double submit: after a successful run the student sits
            -- on the target year, so a repeat finds nothing to move.
            IF TRIM(COALESCE(s.academic_year, '')) <> v_src THEN
                v_skipped := v_skipped || (s.student_name || ' (not in ' || v_src || ')');
                CONTINUE;
            END IF;

            v_outcome := CASE r.outcome
                            WHEN 'promote' THEN 'Promote'
                            WHEN 'retain'  THEN 'Retain'
                            WHEN 'passout' THEN 'PassOut'
                            ELSE NULL
                         END;
            IF v_outcome IS NULL THEN
                v_skipped := v_skipped || (s.student_name || ' (unknown outcome)');
                CONTINUE;
            END IF;

            SELECT COALESCE(SUM(l.amount_due - l.amount_paid - COALESCE(l.concession, 0)), 0)
            INTO v_dues
            FROM core.student_ledger l
            WHERE l.student_id = s.student_id;
            v_dues := GREATEST(v_dues, 0);

            -- The ledger is not year-scoped, so dues follow the student no
            -- matter what. Unticking the box therefore means "do not take the
            -- dues into the new session" -> those students must settle first.
            IF NOT p_carry_dues AND v_dues > 0 AND v_outcome <> 'PassOut' THEN
                v_skipped := v_skipped || (s.student_name || ' (pending dues)');
                CONTINUE;
            END IF;

            -- 1. Work out where the student is going.
            IF v_outcome = 'Promote' THEN
                -- The student's rung on the ladder, read from the session they
                -- are leaving; fall back to the new session in case the old one
                -- was edited after they were admitted.
                SELECT display_order INTO v_cur_order
                FROM   academic.academic_classes
                WHERE  tenant_id = p_tenant_id
                  AND  school_id = p_school_id
                  AND  academic_year_id = COALESCE(v_src_year_id, v_tgt_year_id)
                  AND  class_name = s.class_name
                  AND  COALESCE(is_deleted, FALSE) = FALSE
                ORDER BY display_order, academic_class_id
                LIMIT 1;

                IF v_cur_order IS NULL THEN
                    SELECT display_order INTO v_cur_order
                    FROM   academic.academic_classes
                    WHERE  tenant_id = p_tenant_id
                      AND  school_id = p_school_id
                      AND  academic_year_id = v_tgt_year_id
                      AND  class_name = s.class_name
                      AND  COALESCE(is_deleted, FALSE) = FALSE
                    ORDER BY display_order, academic_class_id
                    LIMIT 1;
                END IF;

                IF v_cur_order IS NULL THEN
                    v_skipped := v_skipped || (s.student_name || ' (class ' || s.class_name || ' is not in the session setup)');
                    CONTINUE;
                END IF;

                IF r.to_class IS NOT NULL THEN
                    -- The office asked for a specific class (a double promotion,
                    -- 1st -> 3rd). Still has to be a real class in the TARGET
                    -- session, and still has to be ABOVE where they are now: this
                    -- operation only ever moves students up. Moving someone down
                    -- is a correction, and belongs on the student's own page where
                    -- it is one deliberate act rather than a bulk one.
                    SELECT display_order INTO v_pick_order
                    FROM   academic.academic_classes
                    WHERE  tenant_id = p_tenant_id
                      AND  school_id = p_school_id
                      AND  academic_year_id = v_tgt_year_id
                      AND  class_name = r.to_class
                      AND  COALESCE(is_deleted, FALSE) = FALSE
                      AND  COALESCE(is_active,  TRUE)  = TRUE
                    ORDER BY display_order, academic_class_id
                    LIMIT 1;

                    IF v_pick_order IS NULL THEN
                        v_skipped := v_skipped ||
                            (s.student_name || ' (chosen class ' || r.to_class || ' is not set up in ' || v_tgt || ')');
                        CONTINUE;
                    END IF;

                    IF v_pick_order <= v_cur_order THEN
                        v_skipped := v_skipped ||
                            (s.student_name || ' (' || r.to_class || ' is not above ' || s.class_name || ')');
                        CONTINUE;
                    END IF;

                    v_next := r.to_class;
                ELSE
                    -- Default: the next rung up. Read from the TARGET session, so a
                    -- student can only ever be moved into a class that exists there.
                    SELECT class_name INTO v_next
                    FROM   academic.academic_classes
                    WHERE  tenant_id = p_tenant_id
                      AND  school_id = p_school_id
                      AND  academic_year_id = v_tgt_year_id
                      AND  COALESCE(is_deleted, FALSE) = FALSE
                      AND  COALESCE(is_active,  TRUE)  = TRUE
                      AND  display_order > v_cur_order
                    ORDER BY display_order, academic_class_id
                    LIMIT 1;
                END IF;

                IF v_next IS NULL THEN
                    v_skipped := v_skipped || (s.student_name || ' (already in the final class — mark Pass Out)');
                    CONTINUE;
                END IF;

                v_to_class := v_next;

            ELSIF v_outcome = 'Retain' THEN
                v_to_class := s.class_name;

            ELSE
                v_to_class := NULL;   -- PassOut leaves the school; no class needed
            END IF;

            -- 2. A student may only land on a class + section that really exists
            --    in the target session. Carrying the old section forward blindly
            --    is how students used to end up in a section their new class has
            --    never had (1st-C -> 2nd-C, where 2nd only ever had A and B).
            IF v_outcome <> 'PassOut' THEN
                v_to_section := COALESCE(v_sec, s.section);

                IF NOT EXISTS (
                    SELECT 1
                    FROM   academic.academic_classes ac
                    WHERE  ac.tenant_id = p_tenant_id
                      AND  ac.school_id = p_school_id
                      AND  ac.academic_year_id = v_tgt_year_id
                      AND  ac.class_name = v_to_class
                      AND  COALESCE(ac.is_deleted, FALSE) = FALSE
                      AND  COALESCE(ac.is_active,  TRUE)  = TRUE
                ) THEN
                    v_skipped := v_skipped || (s.student_name || ' (' || v_to_class || ' is not set up in ' || v_tgt || ')');
                    CONTINUE;
                END IF;

                IF v_to_section IS NULL OR NOT EXISTS (
                    SELECT 1
                    FROM   academic.academic_class_sections acs
                    JOIN   academic.academic_classes ac
                           ON ac.academic_class_id = acs.academic_class_id
                    WHERE  ac.tenant_id = p_tenant_id
                      AND  ac.school_id = p_school_id
                      AND  ac.academic_year_id = v_tgt_year_id
                      AND  ac.class_name   = v_to_class
                      AND  acs.section_name = v_to_section
                      AND  COALESCE(ac.is_deleted,  FALSE) = FALSE
                      AND  COALESCE(acs.is_deleted, FALSE) = FALSE
                      AND  COALESCE(acs.is_active,  TRUE)  = TRUE
                ) THEN
                    v_skipped := v_skipped ||
                        (s.student_name || ' (section ' || COALESCE(v_to_section, '—') ||
                         ' does not exist in ' || v_to_class || ' for ' || v_tgt || ')');
                    CONTINUE;
                END IF;
            ELSE
                v_to_section := NULL;
            END IF;

            -- 3. Commit the move.
            --
            --    Two records are kept in step here: core.students carries the
            --    student's PRESENT position (overwritten), and
            --    core.student_enrolment gains a row per session so the position
            --    they are leaving is not lost. See student_enrolment.sql.
            -- Roll number in the new class: keep it, unless the student has none or
            -- someone already in that class-section uses it -- then the next free
            -- number (highest + 1). Renumbering a whole class is Students › Data Checks.
            v_roll := NULLIF(TRIM(COALESCE(s.roll_no, '')), '');
            IF v_outcome IN ('Promote', 'Retain') AND (v_roll IS NULL OR EXISTS (
                   SELECT 1 FROM core.students o
                    WHERE o.tenant_id = p_tenant_id AND o.school_id = p_school_id AND o.is_active
                      AND o.student_id <> s.student_id AND o.academic_year = v_tgt
                      AND o.class_name = v_to_class AND COALESCE(o.section, '') = COALESCE(v_to_section, '')
                      AND lower(TRIM(o.roll_no)) = lower(v_roll))) THEN
                -- counts those already moved in AND classmates of this run still to come,
                -- so a missing roll goes after everyone else's instead of taking roll 1
                SELECT (COALESCE(MAX(TRIM(x.roll_no)::int), 0) + 1)::text INTO v_roll
                  FROM (SELECT o.roll_no FROM core.students o
                         WHERE o.tenant_id = p_tenant_id AND o.school_id = p_school_id AND o.is_active
                           AND o.student_id <> s.student_id AND o.academic_year = v_tgt
                           AND o.class_name = v_to_class AND COALESCE(o.section, '') = COALESCE(v_to_section, '')
                        UNION ALL
                        SELECT o.roll_no FROM core.students o
                         WHERE o.student_id IN (SELECT (j->>'studentId')::int FROM jsonb_array_elements(p_students) j)
                           AND o.student_id <> s.student_id AND o.academic_year = s.academic_year
                           AND o.class_name = s.class_name AND COALESCE(o.section, '') = COALESCE(s.section, '')) x
                 WHERE TRIM(x.roll_no) ~ '^[0-9]{1,6}$';
            END IF;

            IF v_outcome = 'Promote' THEN
                UPDATE core.students
                SET class_name    = v_to_class,
                    roll_no       = v_roll,
                    section       = v_to_section,
                    academic_year = v_tgt,
                    updated_by    = p_action_user_id,
                    updated_at    = now()
                WHERE student_id = s.student_id;

                PERFORM core.fn_student_enrolment_close(
                    s.student_id, s.academic_year, 'Promoted', p_action_user_id);
                PERFORM core.fn_student_enrolment_open(
                    p_tenant_id, p_school_id, s.student_id,
                    v_tgt, v_to_class, v_to_section, v_roll, p_action_user_id);

                v_promoted := v_promoted + 1;

            ELSIF v_outcome = 'Retain' THEN
                UPDATE core.students
                SET section       = v_to_section,
                    roll_no       = v_roll,
                    academic_year = v_tgt,
                    updated_by    = p_action_user_id,
                    updated_at    = now()
                WHERE student_id = s.student_id;

                PERFORM core.fn_student_enrolment_close(
                    s.student_id, s.academic_year, 'Retained', p_action_user_id);
                PERFORM core.fn_student_enrolment_open(
                    p_tenant_id, p_school_id, s.student_id,
                    v_tgt, v_to_class, v_to_section, v_roll, p_action_user_id);

                v_retained := v_retained + 1;

            ELSE  -- PassOut: same shape as sp_student_exit, so they show up in
                  -- the Inactive list and stay eligible for a TC.
                UPDATE core.students
                SET status           = 'Passout',
                    is_active        = FALSE,
                    date_of_leaving  = CURRENT_DATE,
                    exit_recorded_by = p_action_user_id,
                    exit_recorded_at = now(),
                    updated_by       = p_action_user_id,
                    updated_at       = now()
                WHERE student_id = s.student_id;

                -- No new session opens; the last one just ends.
                PERFORM core.fn_student_enrolment_close(
                    s.student_id, s.academic_year, 'PassedOut', p_action_user_id);

                -- Same money rule as a manual exit: anything due after today
                -- is closed with a reason and the bus ends.
                PERFORM core.fn_student_leave_money(
                    p_tenant_id, p_school_id, s.student_id, CURRENT_DATE, p_action_user_id);

                v_passed := v_passed + 1;
            END IF;

            -- 4. Bill the new session (Promote and Retain).
            --
            --    The class's recurring fee structure for the TARGET session is
            --    billed exactly the way admission bills a plan
            --    (core.fn_student_bill_plan), from the session start. The
            --    admission fee and deposit are not charged again. Billing is
            --    once per student per session, so a repeated run never adds a
            --    second plan. Before this, promotion created no dues at all
            --    for the new year. Old unpaid dues are untouched: they carry.
            IF v_outcome IN ('Promote', 'Retain') THEN
                v_plan := core.fn_class_fee_plan(p_tenant_id, p_school_id, v_to_class, v_tgt);
                IF v_plan IS NULL THEN
                    v_unbilled := v_unbilled || (s.student_name || ' (' || v_to_class || ')');
                ELSIF core.fn_student_bill_plan(p_tenant_id, p_school_id, p_action_user_id,
                          s.student_id, v_tgt, COALESCE(v_tgt_start, CURRENT_DATE), v_plan) > 0 THEN
                    v_billed := v_billed + 1;
                END IF;

                -- A student who keeps a bus route is billed for it in the new
                -- session too, at the stop's current fare.
                v_route := NULL;
                SELECT route_id, stop_id INTO v_route, v_stop
                FROM core.student_transport
                WHERE student_id = s.student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
                  AND is_active = TRUE AND COALESCE(is_deleted, FALSE) = FALSE
                ORDER BY assignment_id DESC
                LIMIT 1;

                IF v_route IS NOT NULL THEN
                    v_bus := 'promote_bus_' || s.student_id;
                    CALL core.sp_transport_assign_manage('SaveAssignment', p_tenant_id, p_school_id,
                         p_action_user_id, s.student_id, v_route, v_stop, v_tgt,
                         COALESCE(v_tgt_start, CURRENT_DATE), 12, v_bus);
                    CLOSE v_bus;
                END IF;
            END IF;

            INSERT INTO core.student_promotion_history (
                tenant_id, school_id, student_id,
                from_year, from_class, from_section,
                to_year, to_class, to_section,
                outcome, dues_carried, promoted_by)
            VALUES (
                p_tenant_id, p_school_id, s.student_id,
                s.academic_year, s.class_name, s.section,
                CASE WHEN v_outcome = 'PassOut' THEN s.academic_year ELSE v_tgt END,
                v_to_class, v_to_section,
                v_outcome, v_dues, p_action_user_id);
        END;
    END LOOP;

    IF v_promoted + v_retained + v_passed = 0 THEN
        RAISE EXCEPTION 'Nothing was promoted. %',
            COALESCE(NULLIF(array_to_string(v_skipped, '; '), ''), 'No matching students in ' || v_src || '.');
    END IF;

    OPEN p_result FOR
    SELECT TRUE                                   AS success,
           v_promoted                             AS promoted,
           v_retained                             AS retained,
           v_passed                               AS passed_out,
           COALESCE(array_length(v_skipped, 1), 0) AS skipped,
           array_to_string(v_skipped, '; ')       AS skipped_detail,
           v_promoted || ' promoted, ' || v_retained || ' retained, ' ||
           v_passed   || ' passed out. ' ||
           v_billed   || ' billed for ' || v_tgt || '.' ||
           CASE WHEN array_length(v_unbilled, 1) > 0
                THEN ' Not billed — no fee structure for ' || v_tgt || ': ' ||
                     array_to_string(v_unbilled, ', ') || '.'
                ELSE '' END                       AS message,
           v_billed                               AS billed;
    RETURN;
END;
$procedure$;


