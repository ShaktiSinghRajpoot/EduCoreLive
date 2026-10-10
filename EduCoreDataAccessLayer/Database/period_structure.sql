-- ============================================================================
-- Period Structure — the school's daily bell schedule.
-- Ordered list of periods; each is a teaching class, an assembly, a break,
-- lunch or diary time. The Timetable grid and the Smart Bell are built from it.
--
-- A school has ONE DEFAULT schedule (day_of_week IS NULL) used on every day,
-- plus an optional CUSTOM schedule for any weekday (day_of_week 0..6, e.g. a
-- short Saturday). A day with no rows of its own uses the default.
--
--   academic.period_structure                          rows, one per period
--   academic.fn_day_periods(tenant, school, day)       the schedule a weekday runs on
--   academic.sp_school_admin_period_structure_manage   GetPeriodStructure | GetAllSchedules
--                                                      | SavePeriodStructure | UseDefault
--
-- Save is replace-all for one schedule (the default, or one day's custom one)
-- and validates chronological, non-overlapping times server-side (the UI
-- validates too, but the proc is the gate).
--
-- Migration: day_of_week was added as a NULLable column, and NULL means "the
-- default schedule". So every schedule saved before this change simply becomes
-- the default, with no data copy, and re-running this script changes nothing.
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

-- Per-weekday schedules. NULL = the default schedule (all existing rows).
ALTER TABLE academic.period_structure
    ADD COLUMN IF NOT EXISTS day_of_week smallint;

ALTER TABLE academic.period_structure
    DROP CONSTRAINT IF EXISTS chk_period_structure_dow;

ALTER TABLE academic.period_structure
    ADD CONSTRAINT chk_period_structure_dow
    CHECK (day_of_week IS NULL OR day_of_week BETWEEN 0 AND 6);

CREATE INDEX IF NOT EXISTS ix_period_structure_day
    ON academic.period_structure (tenant_id, school_id, day_of_week, seq);


-- The schedule one weekday runs on: its own custom rows when it has any,
-- otherwise the default rows. p_day NULL returns the default schedule.
-- Timetable lessons on a day point at a period of THIS schedule by its seq.
CREATE OR REPLACE FUNCTION academic.fn_day_periods(
    p_tenant_id integer, p_school_id integer, p_day smallint)
RETURNS TABLE (period_id integer, seq integer, period_type varchar, label varchar,
               start_time time, end_time time, day_of_week smallint)
LANGUAGE sql
STABLE
AS $function$
    SELECT ps.period_id, ps.seq, ps.period_type, ps.label, ps.start_time, ps.end_time, ps.day_of_week
    FROM academic.period_structure ps
    WHERE ps.tenant_id = p_tenant_id AND ps.school_id = p_school_id
      AND ps.day_of_week = p_day
    UNION ALL
    SELECT ps.period_id, ps.seq, ps.period_type, ps.label, ps.start_time, ps.end_time, ps.day_of_week
    FROM academic.period_structure ps
    WHERE ps.tenant_id = p_tenant_id AND ps.school_id = p_school_id
      AND ps.day_of_week IS NULL
      AND NOT EXISTS (SELECT 1 FROM academic.period_structure c
                      WHERE c.tenant_id = p_tenant_id AND c.school_id = p_school_id
                        AND c.day_of_week = p_day);
$function$;


-- The old 6-argument version (one schedule per school) is replaced by the
-- 7-argument one below. p_day_of_week comes LAST, after the cursor, so every
-- existing positional call (..., p_items, cursor) still resolves.
DROP PROCEDURE IF EXISTS academic.sp_school_admin_period_structure_manage(
    character varying, integer, integer, integer, text, refcursor);

CREATE OR REPLACE PROCEDURE academic.sp_school_admin_period_structure_manage(
    IN    p_operation      character varying,
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_items          text      DEFAULT NULL::text,
    INOUT p_result         refcursor DEFAULT 'result_cursor'::refcursor,
    IN    p_day_of_week    smallint  DEFAULT NULL::smallint)   -- NULL = the default schedule
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
    v_booked   text;
    v_booked_d smallint;
    v_offs     smallint[];
    v_days     smallint[];
    v_dayname  text;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    IF p_day_of_week IS NOT NULL AND (p_day_of_week < 0 OR p_day_of_week > 6) THEN
        RAISE EXCEPTION 'That is not a day of the week.';
    END IF;
    v_dayname := to_char(DATE '2024-01-07' + COALESCE(p_day_of_week, 0), 'FMDay');   -- 2024-01-07 was a Sunday

    IF p_operation = 'GetPeriodStructure' THEN

        -- No day: the default schedule. A day: the schedule that day runs on
        -- (its own, or the default). day_of_week NULL on a row = a default row.
        OPEN p_result FOR
        SELECT
            d.period_id,
            d.seq,
            d.period_type,
            d.label,
            to_char(d.start_time, 'HH24:MI') AS start_time,
            to_char(d.end_time,   'HH24:MI') AS end_time,
            d.day_of_week
        FROM academic.fn_day_periods(p_tenant_id, p_school_id, p_day_of_week) d
        ORDER BY d.seq, d.start_time;

    ELSIF p_operation = 'GetAllSchedules' THEN

        -- Every schedule the school has: the default first, then each custom day.
        OPEN p_result FOR
        SELECT
            period_id,
            seq,
            period_type,
            label,
            to_char(start_time, 'HH24:MI') AS start_time,
            to_char(end_time,   'HH24:MI') AS end_time,
            day_of_week
        FROM academic.period_structure
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
        ORDER BY day_of_week NULLS FIRST, seq, start_time;

    ELSIF p_operation IN ('SavePeriodStructure', 'UseDefault') THEN

        IF p_operation = 'UseDefault' AND p_day_of_week IS NULL THEN
            RAISE EXCEPTION 'Pick the day that should go back to the default schedule.';
        END IF;

        IF p_operation = 'SavePeriodStructure' THEN

            -- A weekly off has no lessons and no bell, so it gets no schedule.
            IF p_day_of_week IS NOT NULL THEN
                SELECT weekly_off_days INTO v_offs
                FROM academic.school_calendar_settings
                WHERE tenant_id = p_tenant_id AND school_id = p_school_id;
                IF p_day_of_week = ANY (COALESCE(v_offs, '{0}')) THEN
                    RAISE EXCEPTION '% is a weekly off, so it has no bell schedule.', v_dayname;
                END IF;
            END IF;

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
        END IF;

        -- Which weekdays change schedule with this save: one custom day, or (for
        -- the default) every day that does not have a schedule of its own.
        IF p_day_of_week IS NOT NULL THEN
            v_days := ARRAY[p_day_of_week];
        ELSE
            SELECT COALESCE(array_agg(d::smallint), '{}') INTO v_days
            FROM generate_series(0, 6) d
            WHERE NOT EXISTS (SELECT 1 FROM academic.period_structure c
                              WHERE c.tenant_id = p_tenant_id AND c.school_id = p_school_id
                                AND c.day_of_week = d);
        END IF;

        -- Remember the schedule each of those days ran on until now, so their
        -- timetable lessons can follow their period by label afterwards.
        CREATE TEMP TABLE IF NOT EXISTS _old_day_periods
            (day smallint, seq integer, label text, label_txt text) ON COMMIT DROP;
        DELETE FROM _old_day_periods;
        INSERT INTO _old_day_periods
        SELECT d, p.seq, lower(p.label), p.label
        FROM unnest(v_days) d
        CROSS JOIN LATERAL academic.fn_day_periods(p_tenant_id, p_school_id, d) p;

        -- Replace-all of this one schedule. UseDefault just drops the day's own
        -- rows, so that day falls back to the default.
        DELETE FROM academic.period_structure
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND day_of_week IS NOT DISTINCT FROM p_day_of_week;

        IF p_operation = 'SavePeriodStructure' THEN
            INSERT INTO academic.period_structure
                (tenant_id, school_id, day_of_week, seq, period_type, label, start_time, end_time, created_by, created_at)
            SELECT
                p_tenant_id,
                p_school_id,
                p_day_of_week,
                row_number() OVER (ORDER BY (elem ->> 'start')::time),
                lower(trim(COALESCE(elem ->> 'type', 'class'))),
                trim(COALESCE(elem ->> 'name', '')),
                (elem ->> 'start')::time,
                (elem ->> 'end')::time,
                p_action_user_id,
                now()
            FROM jsonb_array_elements(v_items) elem;
        END IF;

        -- Timetable lessons point at a period by (day, seq), and the change above
        -- can renumber or drop periods. So a period that has lessons on an
        -- affected day must still exist on that day, by label, as a teaching
        -- period. Otherwise its lessons would be left on nothing, or slide onto
        -- whatever period took its number. RAISE undoes the whole save.
        SELECT o.label_txt, o.day INTO v_booked, v_booked_d
        FROM academic.timetable t
        JOIN _old_day_periods o ON o.day = t.day_of_week AND o.seq = t.period_seq
        WHERE t.tenant_id = p_tenant_id
          AND t.school_id = p_school_id
          AND NOT EXISTS (SELECT 1 FROM academic.fn_day_periods(p_tenant_id, p_school_id, o.day) n
                          WHERE lower(n.label) = o.label AND n.period_type = 'class')
        ORDER BY CASE WHEN o.day = 0 THEN 7 ELSE o.day END, o.seq
        LIMIT 1;

        IF v_booked IS NOT NULL THEN
            RAISE EXCEPTION 'Period "%" has lessons in the timetable on %. Keep it as a class period, or clear those lessons in Timetable first.',
                v_booked, to_char(DATE '2024-01-07' + v_booked_d, 'FMDay');
        END IF;

        -- Move each lesson to its period's new number on that day. Done in two
        -- steps (via a negative number) so the unique slot index never sees two
        -- lessons on one number half way through.
        UPDATE academic.timetable t
        SET period_seq = -n.seq
        FROM _old_day_periods o
        CROSS JOIN LATERAL academic.fn_day_periods(p_tenant_id, p_school_id, o.day) n
        WHERE lower(n.label) = o.label
          AND t.tenant_id = p_tenant_id
          AND t.school_id = p_school_id
          AND t.day_of_week = o.day
          AND t.period_seq = o.seq;

        UPDATE academic.timetable
        SET period_seq = -period_seq
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND period_seq < 0;

        OPEN p_result FOR
        SELECT TRUE AS success,
               CASE WHEN p_operation = 'UseDefault'
                    THEN v_dayname || ' now uses the default schedule.'
                    ELSE 'Schedule saved.'
               END AS message;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;
