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
--     DeleteEntry
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
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    -- ---------------------------------------------------------------- read --
    IF p_operation = 'GetCalendar' THEN

        OPEN p_result FOR
        SELECT
            calendar_id,
            to_char(calendar_date, 'YYYY-MM-DD')     AS calendar_date,
            day_type,
            title,
            to_char(half_day_end, 'HH24:MI')         AS half_day_end
        FROM academic.school_calendar
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND calendar_date >= COALESCE(p_date,    date_trunc('year', CURRENT_DATE)::date)
          AND calendar_date <= COALESCE(p_to_date, (date_trunc('year', CURRENT_DATE) + interval '1 year - 1 day')::date)
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
          AND calendar_date = COALESCE(p_date, CURRENT_DATE);

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
    ELSIF p_operation = 'SaveEntry' THEN

        IF p_date IS NULL THEN
            RAISE EXCEPTION 'Pick a date first.';
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

        INSERT INTO academic.school_calendar
            (tenant_id, school_id, calendar_date, day_type, title, half_day_end, created_by, created_at)
        VALUES
            (p_tenant_id, p_school_id, p_date, v_type, v_title,
             CASE WHEN v_type = 'half_day' THEN p_half_day_end ELSE NULL END,
             p_action_user_id, now())
        ON CONFLICT (tenant_id, school_id, calendar_date) DO UPDATE
            SET day_type     = EXCLUDED.day_type,
                title        = EXCLUDED.title,
                half_day_end = EXCLUDED.half_day_end,
                updated_by   = p_action_user_id,
                updated_at   = now();

        OPEN p_result FOR SELECT TRUE AS success, 'Calendar updated.' AS message;
        OPEN p_result2 FOR SELECT 1 WHERE FALSE;

    ELSIF p_operation = 'DeleteEntry' THEN

        DELETE FROM academic.school_calendar
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND (   (p_calendar_id IS NOT NULL AND calendar_id   = p_calendar_id)
               OR (p_calendar_id IS NULL     AND calendar_date = p_date));

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
