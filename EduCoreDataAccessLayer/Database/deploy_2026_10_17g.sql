-- Bundle 2026-10-17g: Year-End carry only from the session's last month; class-teacher card counts the session's enrolment. Run with:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_17g.sql
-- Sources: fee_year_end.sql, class_teacher_of.sql

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
    v_last   date;               -- first day of the session's last month: carrying opens then
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

    SELECT y.fees_closed_at, date_trunc('month', NULLIF(y.end_date, '')::date)::date INTO v_closed, v_last
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
    -- Carrying moves dues into next session's books; it is the year-end step. Done in
    -- October it put that month's fees under 2027-28, out of every 2026-27 report.
    -- Write-off stays open all year (waiving a due is an everyday decision).
    IF p_operation IN ('Carry', 'CarryAll') AND v_last IS NOT NULL AND CURRENT_DATE < v_last THEN
        RAISE EXCEPTION 'Dues can be carried to the next session from % (the last month of %). Until then collect them, or write them off.',
            to_char(v_last, 'DD Mon YYYY'), p_academic_year;
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
-- Which sections is someone the class teacher of (current session)?
--
-- Shown to the teacher in the profile menu and on the dashboard ("Your class:
-- Class 3-A, 32 students, attendance not marked yet"), and to the office on the
-- staff profile. Read-only.
--
--   p_staff_id NULL -> the staff record of the signed-in user (p_action_user_id)
--   p_staff_id set  -> that staff member (staff profile page)
--
-- Re-runnable.
-- ============================================================================
CREATE OR REPLACE PROCEDURE core.sp_class_teacher_of(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_staff_id       integer DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'class_teacher_of_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_staff integer := p_staff_id;
    v_year  integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    IF v_staff IS NULL THEN
        SELECT staff_id INTO v_staff
          FROM core.staff
         WHERE user_id = p_action_user_id AND tenant_id = p_tenant_id AND school_id = p_school_id
           AND NOT COALESCE(is_deleted, FALSE) AND COALESCE(status, 'Active') <> 'Inactive'
         LIMIT 1;
    END IF;

    SELECT academic_year_id INTO v_year
      FROM academic.academic_years
     WHERE tenant_id = p_tenant_id AND school_id = p_school_id
       AND is_current AND NOT COALESCE(is_deleted, FALSE)
     LIMIT 1;

    OPEN p_result FOR
    SELECT sec.academic_class_section_id AS section_id,
           c.class_name,
           sec.section_name,
           y.academic_year_name,
           -- the section's roll for its session (core.student_enrolment): a child
           -- promoted early still belongs to it until the session ends
           (SELECT COUNT(*) FROM core.student_enrolment e
             WHERE e.tenant_id = p_tenant_id AND e.school_id = p_school_id
               AND e.academic_year = y.academic_year_name AND COALESCE(e.status, '') NOT IN ('Left', 'PassedOut')
               AND e.class_name = c.class_name AND COALESCE(e.section, '') = COALESCE(sec.section_name, ''))::int AS students,
           EXISTS (SELECT 1 FROM core.student_attendance a
                    WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
                      AND a.academic_year = y.academic_year_name
                      AND a.class_name = c.class_name AND COALESCE(a.section, '') = COALESCE(sec.section_name, '')
                      AND a.attendance_date::date = CURRENT_DATE) AS marked_today
      FROM academic.academic_class_sections sec
      JOIN academic.academic_classes c ON c.academic_class_id = sec.academic_class_id
      JOIN academic.academic_years y   ON y.academic_year_id  = sec.academic_year_id
     WHERE sec.tenant_id = p_tenant_id AND sec.school_id = p_school_id
       AND v_staff IS NOT NULL AND sec.class_teacher_staff_id = v_staff
       AND sec.academic_year_id = v_year
       AND NOT COALESCE(sec.is_deleted, FALSE) AND NOT COALESCE(c.is_deleted, FALSE)
     ORDER BY c.display_order, c.class_name, sec.display_order, sec.section_name;
END;
$procedure$;

