-- ============================================================================
-- Period Structure — the school's daily bell schedule (one schedule per school).
-- Ordered list of periods; each is a teaching class, a break, or lunch. The
-- Timetable grid is built from this later.
--
--   academic.period_structure                          rows, one per period
--   academic.sp_school_admin_period_structure_manage   Get | Save (replace-all)
--
-- Save is replace-all for the school and validates chronological, non-overlapping
-- times server-side (the UI validates too, but the proc is the gate).
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

CREATE TABLE IF NOT EXISTS academic.period_structure (
    period_id    serial PRIMARY KEY,
    tenant_id    integer NOT NULL,
    school_id    integer NOT NULL,
    seq          integer NOT NULL,             -- display / chronological order
    period_type  varchar(20) NOT NULL,         -- class | break | lunch
    label        varchar(50) NOT NULL,         -- e.g. P1, Break, Lunch
    start_time   time NOT NULL,
    end_time     time NOT NULL,
    created_by   integer,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   integer,
    updated_at   timestamptz,

    CONSTRAINT chk_period_structure_type CHECK (period_type IN ('class', 'break', 'lunch')),
    CONSTRAINT chk_period_structure_time CHECK (end_time > start_time)
);

CREATE INDEX IF NOT EXISTS ix_period_structure_school
    ON academic.period_structure (tenant_id, school_id, seq);


CREATE OR REPLACE PROCEDURE academic.sp_school_admin_period_structure_manage(
    IN    p_operation      character varying,
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_items          text      DEFAULT NULL::text,
    INOUT p_result         refcursor DEFAULT 'result_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_items    jsonb;
    v_item     jsonb;
    v_type     text;
    v_label    text;
    v_start    time;
    v_end      time;
    v_prev_end time;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    IF p_operation = 'GetPeriodStructure' THEN

        OPEN p_result FOR
        SELECT
            period_id,
            seq,
            period_type,
            label,
            to_char(start_time, 'HH24:MI') AS start_time,
            to_char(end_time,   'HH24:MI') AS end_time
        FROM academic.period_structure
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
        ORDER BY seq, start_time;

    ELSIF p_operation = 'SavePeriodStructure' THEN

        v_items := COALESCE(NULLIF(p_items, ''), '[]')::jsonb;

        -- Validate in the order given (the UI keeps them chronological): each
        -- period must end after it starts and not overlap the one before it.
        v_prev_end := NULL;
        FOR v_item IN SELECT value FROM jsonb_array_elements(v_items)
        LOOP
            v_label := trim(COALESCE(v_item ->> 'name', ''));
            v_type  := lower(trim(COALESCE(v_item ->> 'type', 'class')));
            v_start := (v_item ->> 'start')::time;
            v_end   := (v_item ->> 'end')::time;

            IF v_label = '' THEN
                RAISE EXCEPTION 'Every period needs a label.';
            END IF;
            IF v_start IS NULL OR v_end IS NULL THEN
                RAISE EXCEPTION 'Period "%" is missing a start or end time.', v_label;
            END IF;
            IF v_end <= v_start THEN
                RAISE EXCEPTION 'Period "%" ends before it starts.', v_label;
            END IF;
            IF v_prev_end IS NOT NULL AND v_start < v_prev_end THEN
                RAISE EXCEPTION 'Period "%" overlaps the previous period.', v_label;
            END IF;

            v_prev_end := v_end;
        END LOOP;

        -- Replace-all: this page owns the whole schedule for the school.
        DELETE FROM academic.period_structure
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id;

        INSERT INTO academic.period_structure
            (tenant_id, school_id, seq, period_type, label, start_time, end_time, created_by, created_at)
        SELECT
            p_tenant_id,
            p_school_id,
            row_number() OVER (ORDER BY (elem ->> 'start')::time),
            CASE WHEN lower(trim(COALESCE(elem ->> 'type', 'class'))) IN ('class', 'break', 'lunch')
                 THEN lower(trim(COALESCE(elem ->> 'type', 'class')))
                 ELSE 'class' END,
            trim(COALESCE(elem ->> 'name', '')),
            (elem ->> 'start')::time,
            (elem ->> 'end')::time,
            p_action_user_id,
            now()
        FROM jsonb_array_elements(v_items) elem;

        OPEN p_result FOR
        SELECT TRUE AS success, 'Schedule saved.' AS message;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;
