-- ============================================================================
-- Timetable — the weekly grid: which subject/teacher/room fills each class
-- section's period slot on each working day.
--
--   academic.timetable                             one row per filled slot
--   academic.sp_school_admin_timetable_manage      GetSetup | GetGrid | SaveCell
--                                                  | ClearCell | CopyDay | GetTeacherGrid
--
-- Sources everything from what the school already configured:
--   * period slots  -> academic.period_structure (only 'class' periods are bookable)
--   * day columns   -> academic.school_calendar_settings (weekly offs are dropped)
--   * sections      -> academic.academic_class_sections
--   * subjects      -> academic.class_subjects for that section's class
--   * teachers      -> core.staff
--
-- A slot is keyed by the period's SEQ, not its period_id: saving the Period
-- Structure is replace-all (it deletes and re-inserts rows), so ids churn on
-- every save while seq stays put. Inserting a period mid-day still shifts the
-- slots below it — that is the known trade-off of the replace-all save.
--
-- Teacher double-booking is rejected HERE, not just in the page's JS.
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

CREATE TABLE IF NOT EXISTS academic.timetable (
    timetable_id              serial PRIMARY KEY,
    tenant_id                 integer  NOT NULL,
    school_id                 integer  NOT NULL,
    academic_year_id          integer  NOT NULL,
    academic_class_section_id integer  NOT NULL,
    day_of_week               smallint NOT NULL,      -- 0 = Sunday … 6 = Saturday
    period_seq                smallint NOT NULL,      -- academic.period_structure.seq
    subject_id                integer  NOT NULL,
    staff_id                  integer,                -- NULL = subject set, teacher not yet assigned
    room_no                   varchar(50),
    created_by                integer,
    created_at                timestamptz NOT NULL DEFAULT now(),
    updated_by                integer,
    updated_at                timestamptz,

    CONSTRAINT chk_timetable_scope CHECK (tenant_id > 1 AND school_id > 0),
    CONSTRAINT chk_timetable_dow   CHECK (day_of_week BETWEEN 0 AND 6),
    CONSTRAINT fk_timetable_section FOREIGN KEY (academic_class_section_id)
        REFERENCES academic.academic_class_sections (academic_class_section_id),
    CONSTRAINT fk_timetable_subject FOREIGN KEY (subject_id)
        REFERENCES academic.school_subjects (subject_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_timetable_slot
    ON academic.timetable (tenant_id, school_id, academic_year_id, academic_class_section_id, day_of_week, period_seq);

-- The clash lookup: "who else is this teacher booked with at this slot?"
CREATE INDEX IF NOT EXISTS ix_timetable_teacher_slot
    ON academic.timetable (tenant_id, school_id, academic_year_id, day_of_week, period_seq, staff_id);


CREATE OR REPLACE PROCEDURE academic.sp_school_admin_timetable_manage(
    IN    p_operation        character varying,
    IN    p_tenant_id        integer,
    IN    p_school_id        integer,
    IN    p_action_user_id   integer,
    IN    p_academic_year_id integer   DEFAULT NULL,
    IN    p_section_id       integer   DEFAULT NULL,
    IN    p_day              smallint  DEFAULT NULL,
    IN    p_period_seq       smallint  DEFAULT NULL,
    IN    p_subject_id       integer   DEFAULT NULL,
    IN    p_staff_id         integer   DEFAULT NULL,
    IN    p_room_no          character varying DEFAULT NULL,
    INOUT p_result           refcursor DEFAULT 'timetable_cursor'::refcursor,
    INOUT p_result2          refcursor DEFAULT 'timetable_cursor2'::refcursor,
    INOUT p_result3          refcursor DEFAULT 'timetable_cursor3'::refcursor,
    INOUT p_result4          refcursor DEFAULT 'timetable_cursor4'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_year      integer;
    v_class     integer;
    v_offs      smallint[];
    v_clash     text;
    v_teacher   text;
    v_copied    integer := 0;
    v_skipped   integer := 0;
    v_day       smallint;
    v_row       record;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    v_year := COALESCE(p_academic_year_id,
        (SELECT academic_year_id
         FROM academic.academic_years
         WHERE tenant_id = p_tenant_id AND school_id = p_school_id
           AND is_current AND NOT is_deleted
         ORDER BY academic_year_id DESC
         LIMIT 1));

    -- ---------------------------------------------------------------- read --
    IF p_operation = 'GetSetup' THEN

        -- 1: the bookable day, straight from the bell schedule.
        OPEN p_result FOR
        SELECT
            seq::int AS period_seq,
            label,
            period_type,
            to_char(start_time, 'HH24:MI') AS start_time,
            to_char(end_time,   'HH24:MI') AS end_time
        FROM academic.period_structure
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
        ORDER BY seq, start_time;

        -- 2: class sections to switch between.
        OPEN p_result2 FOR
        SELECT
            s.academic_class_section_id AS section_id,
            c.class_name,
            s.section_name,
            c.class_name || ' – ' || s.section_name AS label,
            COALESCE(s.room_no, '') AS room_no
        FROM academic.academic_class_sections s
        JOIN academic.academic_classes c ON c.academic_class_id = s.academic_class_id
        WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id
          AND s.academic_year_id = v_year
          AND NOT s.is_deleted AND s.is_active
          AND NOT c.is_deleted AND c.is_active
        ORDER BY c.display_order, c.class_name, s.display_order, s.section_name;

        -- 3: teaching staff.
        OPEN p_result3 FOR
        SELECT staff_id, full_name
        FROM core.staff
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND NOT is_deleted AND is_active
        ORDER BY full_name;

        -- 4: day columns = the week minus the school's weekly offs.
        SELECT COALESCE(weekly_off_days, '{0}') INTO v_offs
        FROM academic.school_calendar_settings
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id;
        IF v_offs IS NULL THEN
            v_offs := '{0}';
        END IF;

        OPEN p_result4 FOR
        SELECT d::smallint AS day_of_week,
               to_char(DATE '2024-01-07' + d, 'Dy') AS day_label   -- 2024-01-07 was a Sunday
        FROM generate_series(0, 6) d
        WHERE NOT (d = ANY (v_offs))
        ORDER BY CASE WHEN d = 0 THEN 7 ELSE d END;                -- Mon first, Sun last

    ELSIF p_operation = 'GetGrid' THEN

        -- 1: this section's filled slots.
        OPEN p_result FOR
        SELECT
            t.day_of_week,
            t.period_seq,
            t.subject_id,
            s.subject_name,
            t.staff_id,
            COALESCE(st.full_name, '') AS staff_name,
            COALESCE(t.room_no, '')    AS room_no
        FROM academic.timetable t
        JOIN academic.school_subjects s ON s.subject_id = t.subject_id
        LEFT JOIN core.staff st ON st.staff_id = t.staff_id
        WHERE t.tenant_id = p_tenant_id AND t.school_id = p_school_id
          AND t.academic_year_id = v_year
          AND t.academic_class_section_id = p_section_id
        ORDER BY t.day_of_week, t.period_seq;

        -- 2: every OTHER section's teacher bookings — the page flags clashes with these.
        OPEN p_result2 FOR
        SELECT
            t.day_of_week,
            t.period_seq,
            t.staff_id,
            c.class_name || ' – ' || sec.section_name AS section_label
        FROM academic.timetable t
        JOIN academic.academic_class_sections sec ON sec.academic_class_section_id = t.academic_class_section_id
        JOIN academic.academic_classes c          ON c.academic_class_id = sec.academic_class_id
        WHERE t.tenant_id = p_tenant_id AND t.school_id = p_school_id
          AND t.academic_year_id = v_year
          AND t.academic_class_section_id <> p_section_id
          AND t.staff_id IS NOT NULL;

        -- 3: subjects this section's class actually studies (the modal's dropdown).
        SELECT sec.academic_class_id INTO v_class
        FROM academic.academic_class_sections sec
        WHERE sec.academic_class_section_id = p_section_id
          AND sec.tenant_id = p_tenant_id AND sec.school_id = p_school_id;

        OPEN p_result3 FOR
        SELECT s.subject_id, s.subject_name
        FROM academic.class_subjects cs
        JOIN academic.school_subjects s ON s.subject_id = cs.subject_id
        WHERE cs.tenant_id = p_tenant_id AND cs.school_id = p_school_id
          AND cs.academic_year_id  = v_year
          AND cs.academic_class_id = v_class
        ORDER BY cs.display_order, s.subject_name;

        OPEN p_result4 FOR SELECT 1 WHERE FALSE;

    ELSIF p_operation = 'GetTeacherGrid' THEN

        -- Read-only teacher view: where this teacher is, slot by slot.
        OPEN p_result FOR
        SELECT
            t.day_of_week,
            t.period_seq,
            t.subject_id,
            s.subject_name,
            c.class_name || ' – ' || sec.section_name AS section_label,
            COALESCE(t.room_no, '') AS room_no
        FROM academic.timetable t
        JOIN academic.school_subjects s           ON s.subject_id = t.subject_id
        JOIN academic.academic_class_sections sec ON sec.academic_class_section_id = t.academic_class_section_id
        JOIN academic.academic_classes c          ON c.academic_class_id = sec.academic_class_id
        WHERE t.tenant_id = p_tenant_id AND t.school_id = p_school_id
          AND t.academic_year_id = v_year
          AND t.staff_id = p_staff_id
        ORDER BY t.day_of_week, t.period_seq;

        OPEN p_result2 FOR SELECT 1 WHERE FALSE;
        OPEN p_result3 FOR SELECT 1 WHERE FALSE;
        OPEN p_result4 FOR SELECT 1 WHERE FALSE;

    -- --------------------------------------------------------------- write --
    ELSIF p_operation = 'SaveCell' THEN

        IF p_section_id IS NULL OR p_day IS NULL OR p_period_seq IS NULL THEN
            RAISE EXCEPTION 'Missing slot.';
        END IF;
        IF p_subject_id IS NULL THEN
            RAISE EXCEPTION 'Pick a subject.';
        END IF;

        IF NOT EXISTS (SELECT 1 FROM academic.academic_class_sections
                       WHERE academic_class_section_id = p_section_id
                         AND tenant_id = p_tenant_id AND school_id = p_school_id
                         AND NOT is_deleted) THEN
            RAISE EXCEPTION 'That section does not belong to this school.';
        END IF;

        -- Only teaching periods are bookable — never a break or lunch.
        IF NOT EXISTS (SELECT 1 FROM academic.period_structure
                       WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                         AND seq = p_period_seq AND period_type = 'class') THEN
            RAISE EXCEPTION 'That slot is not a teaching period.';
        END IF;

        -- A teacher cannot be in two rooms at once. This is the gate; the page's
        -- warning is only a courtesy.
        IF p_staff_id IS NOT NULL THEN
            SELECT c.class_name || ' – ' || sec.section_name, COALESCE(st.full_name, 'That teacher')
              INTO v_clash, v_teacher
            FROM academic.timetable t
            JOIN academic.academic_class_sections sec ON sec.academic_class_section_id = t.academic_class_section_id
            JOIN academic.academic_classes c          ON c.academic_class_id = sec.academic_class_id
            LEFT JOIN core.staff st                   ON st.staff_id = t.staff_id
            WHERE t.tenant_id = p_tenant_id AND t.school_id = p_school_id
              AND t.academic_year_id = v_year
              AND t.day_of_week = p_day
              AND t.period_seq  = p_period_seq
              AND t.staff_id    = p_staff_id
              AND t.academic_class_section_id <> p_section_id
            LIMIT 1;

            IF v_clash IS NOT NULL THEN
                RAISE EXCEPTION '% is already teaching % in this slot.', v_teacher, v_clash;
            END IF;
        END IF;

        INSERT INTO academic.timetable
            (tenant_id, school_id, academic_year_id, academic_class_section_id,
             day_of_week, period_seq, subject_id, staff_id, room_no, created_by, created_at)
        VALUES
            (p_tenant_id, p_school_id, v_year, p_section_id,
             p_day, p_period_seq, p_subject_id, p_staff_id, NULLIF(trim(COALESCE(p_room_no, '')), ''),
             p_action_user_id, now())
        ON CONFLICT (tenant_id, school_id, academic_year_id, academic_class_section_id, day_of_week, period_seq)
        DO UPDATE SET subject_id = EXCLUDED.subject_id,
                      staff_id   = EXCLUDED.staff_id,
                      room_no    = EXCLUDED.room_no,
                      updated_by = p_action_user_id,
                      updated_at = now();

        OPEN p_result FOR SELECT TRUE AS success, 'Period updated.' AS message;
        OPEN p_result2 FOR SELECT 1 WHERE FALSE;
        OPEN p_result3 FOR SELECT 1 WHERE FALSE;
        OPEN p_result4 FOR SELECT 1 WHERE FALSE;

    ELSIF p_operation = 'ClearCell' THEN

        DELETE FROM academic.timetable
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND academic_year_id = v_year
          AND academic_class_section_id = p_section_id
          AND day_of_week = p_day
          AND period_seq  = p_period_seq;

        OPEN p_result FOR SELECT TRUE AS success, 'Period cleared.' AS message;
        OPEN p_result2 FOR SELECT 1 WHERE FALSE;
        OPEN p_result3 FOR SELECT 1 WHERE FALSE;
        OPEN p_result4 FOR SELECT 1 WHERE FALSE;

    ELSIF p_operation = 'CopyDay' THEN

        -- Copy one day across the rest of the working week. A slot that would
        -- double-book a teacher elsewhere is skipped, not forced.
        SELECT COALESCE(weekly_off_days, '{0}') INTO v_offs
        FROM academic.school_calendar_settings
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id;
        IF v_offs IS NULL THEN
            v_offs := '{0}';
        END IF;

        FOR v_day IN SELECT d::smallint FROM generate_series(0, 6) d
                     WHERE NOT (d = ANY (v_offs)) AND d <> p_day
        LOOP
            -- Clear the target day first: copy means "make it look like the source".
            DELETE FROM academic.timetable
            WHERE tenant_id = p_tenant_id AND school_id = p_school_id
              AND academic_year_id = v_year
              AND academic_class_section_id = p_section_id
              AND day_of_week = v_day;

            FOR v_row IN
                SELECT period_seq, subject_id, staff_id, room_no
                FROM academic.timetable
                WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                  AND academic_year_id = v_year
                  AND academic_class_section_id = p_section_id
                  AND day_of_week = p_day
            LOOP
                IF v_row.staff_id IS NOT NULL AND EXISTS (
                    SELECT 1 FROM academic.timetable t
                    WHERE t.tenant_id = p_tenant_id AND t.school_id = p_school_id
                      AND t.academic_year_id = v_year
                      AND t.day_of_week = v_day
                      AND t.period_seq  = v_row.period_seq
                      AND t.staff_id    = v_row.staff_id
                      AND t.academic_class_section_id <> p_section_id
                ) THEN
                    v_skipped := v_skipped + 1;
                    CONTINUE;
                END IF;

                INSERT INTO academic.timetable
                    (tenant_id, school_id, academic_year_id, academic_class_section_id,
                     day_of_week, period_seq, subject_id, staff_id, room_no, created_by, created_at)
                VALUES
                    (p_tenant_id, p_school_id, v_year, p_section_id,
                     v_day, v_row.period_seq, v_row.subject_id, v_row.staff_id, v_row.room_no,
                     p_action_user_id, now());

                v_copied := v_copied + 1;
            END LOOP;
        END LOOP;

        OPEN p_result FOR
        SELECT TRUE AS success,
               v_copied  AS copied,
               v_skipped AS skipped,
               CASE WHEN v_skipped > 0
                    THEN v_copied || ' periods copied · ' || v_skipped || ' skipped (teacher already booked).'
                    ELSE v_copied || ' periods copied across the week.'
               END AS message;

        OPEN p_result2 FOR SELECT 1 WHERE FALSE;
        OPEN p_result3 FOR SELECT 1 WHERE FALSE;
        OPEN p_result4 FOR SELECT 1 WHERE FALSE;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;
