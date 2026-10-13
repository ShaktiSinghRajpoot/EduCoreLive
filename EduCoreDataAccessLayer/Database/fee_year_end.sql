-- ============================================================================
-- Year-End Fee Closure (Fee › Year-End).
--
-- Before a session is closed, the school goes through every fee line still
-- unpaid in that session and decides, line by line or a whole student at once:
--   Carry     -> the due stays payable next session. The ledger is not
--                year-scoped, so the line already shows at the fee counter;
--                Carry only records that someone reviewed it (carried_at/by).
--   Write off -> the unpaid part is CLOSED with core.fn_ledger_close (source
--                'YearEnd', reason required), exactly as Exit closes dues, so
--                every report that reads amount_due - amount_paid - concession
--                shows 0 for it without being changed.
--   Undo      -> a write-off is put back with core.fn_ledger_reopen; a carry
--                mark is simply cleared.
--
-- Needs student_money_lifecycle.sql (fn_ledger_close / fn_ledger_reopen).
-- Re-runnable.
-- ============================================================================

ALTER TABLE core.student_ledger
    ADD COLUMN IF NOT EXISTS carried_by integer,
    ADD COLUMN IF NOT EXISTS carried_at timestamptz;


CREATE OR REPLACE PROCEDURE core.sp_fee_year_end_manage(
    IN    p_operation      varchar,    -- List | Carry | WriteOff | Undo | CarryAll
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
    v_count  integer := 0;
    v_amount numeric(12,2) := 0;
    r        record;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;
    IF v_year IS NULL THEN
        RAISE EXCEPTION 'Choose a session.';
    END IF;

    -- ── List: every open line of the session, plus the lines already written off
    IF p_operation = 'List' THEN
        OPEN p_result FOR
        SELECT l.ledger_id, l.student_id, s.student_name, s.admission_no, s.class_name, s.section,
               s.guardian_name, s.mobile,
               l.fee_head_name, l.installment_label, l.due_date,
               CASE WHEN l.close_source = 'YearEnd' THEN l.closed_amount
                    ELSE l.amount_due - l.amount_paid - l.concession END   AS amount,
               CASE WHEN l.close_source = 'YearEnd' THEN 'WrittenOff'
                    WHEN l.carried_at IS NOT NULL   THEN 'Carried'
                    ELSE 'Open' END                                         AS state,
               CASE WHEN l.close_source = 'YearEnd' THEN l.close_reason END AS reason,
               COALESCE(CASE WHEN l.close_source = 'YearEnd' THEN l.closed_at END, l.carried_at) AS decided_at
          FROM core.student_ledger l
          JOIN core.students s ON s.student_id = l.student_id
                              AND s.tenant_id = p_tenant_id AND s.school_id = p_school_id
         WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
           AND lower(COALESCE(NULLIF(trim(l.academic_year), ''), s.academic_year)) = v_year
           AND (l.amount_due > l.amount_paid + l.concession
                OR (l.close_source = 'YearEnd' AND l.closed_amount > 0))
         ORDER BY s.class_name, s.section, s.student_name, l.student_id, l.due_date NULLS LAST, l.ledger_id;
        RETURN;
    END IF;

    IF p_operation NOT IN ('Carry', 'WriteOff', 'Undo', 'CarryAll') THEN
        RAISE EXCEPTION 'Unknown operation.';
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

    -- The lines this call acts on, always inside this school and session.
    FOR r IN
        SELECT l.ledger_id, l.carried_at, l.close_source, l.closed_amount,
               l.amount_due - l.amount_paid - l.concession AS open_amount
          FROM core.student_ledger l
          JOIN core.students s ON s.student_id = l.student_id
         WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
           AND lower(COALESCE(NULLIF(trim(l.academic_year), ''), s.academic_year)) = v_year
           AND (p_ledger_id  IS NULL OR l.ledger_id  = p_ledger_id)
           AND (p_student_id IS NULL OR l.student_id = p_student_id)
         ORDER BY l.ledger_id
           FOR UPDATE OF l
    LOOP
        IF p_operation = 'Undo' THEN
            IF r.close_source = 'YearEnd' AND r.closed_amount > 0 THEN
                v_amount := v_amount + core.fn_ledger_reopen(r.ledger_id);
                v_count  := v_count + 1;
            ELSIF r.carried_at IS NOT NULL THEN
                UPDATE core.student_ledger SET carried_at = NULL, carried_by = NULL, updated_at = now()
                 WHERE ledger_id = r.ledger_id;
                v_amount := v_amount + r.open_amount;
                v_count  := v_count + 1;
            END IF;

        ELSIF r.open_amount > 0 THEN
            IF p_operation = 'WriteOff' THEN
                v_amount := v_amount + core.fn_ledger_close(r.ledger_id, v_reason, 'YearEnd', p_action_user_id);
                UPDATE core.student_ledger SET carried_at = NULL, carried_by = NULL WHERE ledger_id = r.ledger_id;
                v_count  := v_count + 1;
            ELSIF r.carried_at IS NULL THEN   -- Carry / CarryAll: only lines not yet decided
                UPDATE core.student_ledger SET carried_at = now(), carried_by = p_action_user_id, updated_at = now()
                 WHERE ledger_id = r.ledger_id;
                v_amount := v_amount + r.open_amount;
                v_count  := v_count + 1;
            END IF;
        END IF;
    END LOOP;

    IF v_count = 0 THEN
        RAISE EXCEPTION 'Nothing to change: the line is already settled or decided.';
    END IF;

    OPEN p_result FOR
    SELECT v_count AS lines, v_amount AS amount,
           CASE p_operation
                WHEN 'WriteOff' THEN 'Written off'
                WHEN 'Undo'     THEN 'Undone'
                ELSE 'Carried forward' END
           || ': ' || v_count || ' line(s), Rs ' || to_char(v_amount, 'FM99,99,99,990.00') AS message;
END;
$$;
