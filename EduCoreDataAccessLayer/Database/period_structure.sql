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
    period_type  varchar(20) NOT NULL,         -- see chk_period_structure_type
    label        varchar(50) NOT NULL,         -- e.g. P1, Break, Lunch
    start_time   time NOT NULL,
    end_time     time NOT NULL,
    created_by   integer,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   integer,
    updated_at   timestamptz,

    CONSTRAINT chk_period_structure_type
        CHECK (period_type IN ('class', 'assembly', 'break', 'lunch', 'diary')),
    CONSTRAINT chk_period_structure_time CHECK (end_time > start_time)
);

CREATE INDEX IF NOT EXISTS ix_period_structure_school
    ON academic.period_structure (tenant_id, school_id, seq);

-- The CREATE TABLE above only shapes a fresh database. A database that already
-- has the table keeps the original three-value constraint, so widen it here.
-- Re-runnable: the constraint is dropped and re-added every time.
ALTER TABLE academic.period_structure
    DROP CONSTRAINT IF EXISTS chk_period_structure_type;

ALTER TABLE academic.period_structure
    ADD CONSTRAINT chk_period_structure_type
    CHECK (period_type IN ('class', 'assembly', 'break', 'lunch', 'diary'));


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

        IF jsonb_array_length(v_items) = 0 THEN
            RAISE EXCEPTION 'Add at least one period. An empty schedule stops the bell.';
        END IF;

        -- Walk them in clock order rather than the order they arrived in: the
        -- overlap test compares each period with the one before it, and that
        -- answer must not depend on how the caller happened to sort the array.
        v_prev_end := NULL;
        FOR v_item IN
            SELECT value FROM jsonb_array_elements(v_items)
            ORDER BY (value ->> 'start')::time
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
            -- The timetable and the bell both name a period by its label.
            IF EXISTS (
                SELECT 1 FROM jsonb_array_elements(v_items) o
                WHERE lower(trim(COALESCE(o ->> 'name', ''))) = lower(v_label)
                GROUP BY lower(trim(COALESCE(o ->> 'name', '')))
                HAVING count(*) > 1
            ) THEN
                RAISE EXCEPTION 'There are two periods called "%".', v_label;
            END IF;
            IF v_type NOT IN ('class', 'assembly', 'break', 'lunch', 'diary') THEN
                RAISE EXCEPTION 'Period "%" has an unknown type "%".', v_label, v_type;
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
            lower(trim(COALESCE(elem ->> 'type', 'class'))),
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
