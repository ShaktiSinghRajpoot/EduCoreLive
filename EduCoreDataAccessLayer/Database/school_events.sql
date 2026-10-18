-- ============================================================================
-- School events on the School Calendar (PTM, annual function, sports day,
-- trip, staff meeting ...).
--
-- The calendar already says WHICH DAYS the school runs (school_calendar.sql:
-- holiday / half day / working). An event does not change that -- a PTM on a
-- Saturday is still whatever that Saturday is -- so events live in their own
-- table and may span several days or share a day with another event.
--
--   academic.sp_school_events_manage
--     List    (p_start_date..p_end_date) -> events AND exams overlapping the range,
--             one shape: kind = 'Event' | 'Exam'. Exams come from the Exam
--             Schedule (academic.exams) and only while the Exams module is on.
--     Save    (p_event_id NULL = new)    -> success, message, event_id
--     Delete  (soft)                     -> success, message
--
-- Re-runnable.
-- ============================================================================

CREATE TABLE IF NOT EXISTS academic.school_events (
    event_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   integer NOT NULL,
    school_id   integer NOT NULL,
    title       varchar(120) NOT NULL,
    event_type  varchar(20)  NOT NULL DEFAULT 'Event',   -- PTM | Event | Sports | Trip | Meeting | Other
    start_date  date NOT NULL,
    end_date    date NOT NULL,
    start_time  time,
    end_time    time,
    for_whom    varchar(120),                              -- free text ("Class 1-5 parents"); NULL = everyone
    notes       text,
    is_deleted  boolean NOT NULL DEFAULT FALSE,
    created_by  integer,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  integer,
    updated_at  timestamptz,

    CONSTRAINT chk_school_events_scope CHECK (tenant_id > 1 AND school_id > 0),
    CONSTRAINT chk_school_events_dates CHECK (end_date >= start_date),
    CONSTRAINT chk_school_events_type  CHECK (event_type IN ('PTM','Event','Sports','Trip','Meeting','Other'))
);

CREATE INDEX IF NOT EXISTS ix_school_events_date
    ON academic.school_events (tenant_id, school_id, start_date) WHERE NOT is_deleted;


CREATE OR REPLACE PROCEDURE academic.sp_school_events_manage(
    IN    p_operation      varchar,
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_event_id       integer DEFAULT NULL,
    IN    p_title          varchar DEFAULT NULL,
    IN    p_event_type     varchar DEFAULT NULL,
    IN    p_start_date     date    DEFAULT NULL,
    IN    p_end_date       date    DEFAULT NULL,
    IN    p_start_time     time    DEFAULT NULL,
    IN    p_end_time       time    DEFAULT NULL,
    IN    p_for_whom       varchar DEFAULT NULL,
    IN    p_notes          text    DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'school_events_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_title varchar := NULLIF(trim(p_title), '');
    v_type  varchar := COALESCE(NULLIF(trim(p_event_type), ''), 'Event');
    v_id    integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    -- ── List: everything on the calendar between two dates
    IF p_operation = 'List' THEN
        OPEN p_result FOR
        SELECT 'Event' AS kind, ev.event_id AS id, ev.title, ev.event_type,
               ev.start_date::text AS start_date, ev.end_date::text AS end_date,
               to_char(ev.start_time, 'HH24:MI') AS start_time, to_char(ev.end_time, 'HH24:MI') AS end_time,
               ev.for_whom, ev.notes, NULL::varchar AS status
          FROM academic.school_events ev
         WHERE ev.tenant_id = p_tenant_id AND ev.school_id = p_school_id AND NOT ev.is_deleted
           AND ev.start_date <= p_end_date AND ev.end_date >= p_start_date
        UNION ALL
        -- the exam period from the Exam Schedule, with the classes that sit it
        SELECT 'Exam', x.exam_id, x.exam_name, 'Exam',
               NULLIF(x.start_date::text, '')::date::text, NULLIF(x.end_date::text, '')::date::text, NULL, NULL,
               (SELECT string_agg(DISTINCT c.class_name, ', ')
                  FROM academic.exam_subjects es
                  JOIN academic.academic_classes c ON c.academic_class_id = es.academic_class_id
                 WHERE es.exam_id = x.exam_id),
               NULL, x.status
          FROM academic.exams x
         WHERE x.tenant_id = p_tenant_id AND x.school_id = p_school_id AND NOT x.is_deleted
           -- exam dates are stored as text (dates_as_text migration)
           AND NULLIF(x.start_date::text, '')::date <= p_end_date AND NULLIF(x.end_date::text, '')::date >= p_start_date
           AND core.fn_module_on(p_tenant_id, p_school_id, 'exams')
         ORDER BY 5, 3;
        RETURN;
    END IF;

    -- ── Save: add or change one event
    IF p_operation = 'Save' THEN
        IF v_title IS NULL THEN
            RAISE EXCEPTION 'Give the event a name.';
        END IF;
        IF v_type NOT IN ('PTM','Event','Sports','Trip','Meeting','Other') THEN
            RAISE EXCEPTION 'Unknown event type.';
        END IF;
        IF p_start_date IS NULL THEN
            RAISE EXCEPTION 'Pick the date of the event.';
        END IF;
        IF COALESCE(p_end_date, p_start_date) < p_start_date THEN
            RAISE EXCEPTION 'The event ends before it starts.';
        END IF;
        IF p_start_time IS NOT NULL AND p_end_time IS NOT NULL AND p_end_time <= p_start_time THEN
            RAISE EXCEPTION 'The end time must be after the start time.';
        END IF;

        IF p_event_id IS NULL THEN
            INSERT INTO academic.school_events
                (tenant_id, school_id, title, event_type, start_date, end_date, start_time, end_time,
                 for_whom, notes, created_by)
            VALUES (p_tenant_id, p_school_id, left(v_title, 120), v_type, p_start_date, COALESCE(p_end_date, p_start_date),
                    p_start_time, p_end_time, left(NULLIF(trim(p_for_whom), ''), 120), NULLIF(trim(p_notes), ''),
                    p_action_user_id)
            RETURNING event_id INTO v_id;
        ELSE
            UPDATE academic.school_events
               SET title = left(v_title, 120), event_type = v_type,
                   start_date = p_start_date, end_date = COALESCE(p_end_date, p_start_date),
                   start_time = p_start_time, end_time = p_end_time,
                   for_whom = left(NULLIF(trim(p_for_whom), ''), 120), notes = NULLIF(trim(p_notes), ''),
                   updated_by = p_action_user_id, updated_at = now()
             WHERE event_id = p_event_id AND tenant_id = p_tenant_id AND school_id = p_school_id AND NOT is_deleted
            RETURNING event_id INTO v_id;
            IF v_id IS NULL THEN
                RAISE EXCEPTION 'Event not found.';
            END IF;
        END IF;

        OPEN p_result FOR SELECT TRUE AS success, 'Event saved.' AS message, v_id AS event_id;
        RETURN;
    END IF;

    -- ── Delete (soft: kept for the record)
    IF p_operation = 'Delete' THEN
        UPDATE academic.school_events
           SET is_deleted = TRUE, updated_by = p_action_user_id, updated_at = now()
         WHERE event_id = p_event_id AND tenant_id = p_tenant_id AND school_id = p_school_id AND NOT is_deleted
        RETURNING event_id INTO v_id;
        IF v_id IS NULL THEN
            RAISE EXCEPTION 'Event not found.';
        END IF;
        OPEN p_result FOR SELECT TRUE AS success, 'Event removed.' AS message, v_id AS event_id;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation.';
END;
$procedure$;
