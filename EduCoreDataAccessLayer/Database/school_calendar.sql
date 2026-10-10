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
                RAISE EXCEPTION 'Nothing was added: every day from % to % already has an entry or is a weekly off.',
                    to_char(p_date, 'FMDD Mon YYYY'), to_char(v_to, 'FMDD Mon YYYY');
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
