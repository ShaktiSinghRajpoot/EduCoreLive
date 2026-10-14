-- Bundle 2026-10-14j: Rooms. Run with:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_14j.sql
-- Source: rooms.sql (one table, one proc; needs timetable.sql for academic.fn_room_key).

-- ============================================================================
-- Rooms (School Setup › Rooms).
--
-- The timetable already books rooms as free text (timetable.room_no, falling
-- back to the section's own room_no) and refuses two classes in one room in the
-- same period (academic.fn_room_key normalises "Room 101" / "room-101" / "101 "
-- to one key). This adds the list of the school's rooms and what each one is
-- used for:
--   List    the rooms, with periods a week booked in the current session
--   Usage   every booked period of one room (or of every room) for its weekly grid
--   Unknown rooms the timetable uses that are not in the list (typos show up here)
--   Save / Delete (soft)
-- The Timetable page offers the list as suggestions for its Room box.
-- Re-runnable.
-- ============================================================================

CREATE TABLE IF NOT EXISTS academic.rooms (
    room_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   integer      NOT NULL,
    school_id   integer      NOT NULL,
    room_name   varchar(50)  NOT NULL,
    room_type   varchar(20)  NOT NULL DEFAULT 'Classroom',
    capacity    integer,
    building    varchar(80),
    notes       varchar(200),
    is_deleted  boolean      NOT NULL DEFAULT FALSE,
    created_by  integer      NOT NULL,
    created_at  timestamptz  NOT NULL DEFAULT now(),
    updated_by  integer,
    updated_at  timestamptz
);
-- one live room per name key in a school
CREATE UNIQUE INDEX IF NOT EXISTS uq_rooms_key ON academic.rooms (tenant_id, school_id, academic.fn_room_key(room_name)) WHERE NOT is_deleted;


CREATE OR REPLACE PROCEDURE academic.sp_room_manage(
    IN    p_operation      varchar,          -- List | Usage | Unknown | Save | Delete
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_room_id        integer DEFAULT NULL,
    IN    p_room_name      varchar DEFAULT NULL,
    IN    p_room_type      varchar DEFAULT NULL,
    IN    p_capacity       integer DEFAULT NULL,
    IN    p_building       varchar DEFAULT NULL,
    IN    p_notes          varchar DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'rooms_cursor')
LANGUAGE plpgsql
AS $$
DECLARE
    v_year integer;
    v_id   integer;
    v_key  text := academic.fn_room_key(p_room_name);
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    SELECT ay.academic_year_id INTO v_year
      FROM academic.academic_years ay
     WHERE ay.tenant_id = p_tenant_id AND ay.school_id = p_school_id
       AND COALESCE(ay.is_current, FALSE) AND NOT COALESCE(ay.is_deleted, FALSE)
     LIMIT 1;

    -- every booked period of the session with the room it is in
    CREATE TEMP TABLE IF NOT EXISTS tmp_room_use (room_key text, room_text varchar, day_of_week int, period_seq int,
                                                  section_label varchar, subject_name varchar, teacher varchar, period_label varchar) ON COMMIT DROP;
    TRUNCATE tmp_room_use;
    IF p_operation IN ('List', 'Usage', 'Unknown') THEN
        INSERT INTO tmp_room_use
        SELECT academic.fn_room_key(COALESCE(NULLIF(trim(t.room_no), ''), sec.room_no)),
               COALESCE(NULLIF(trim(t.room_no), ''), sec.room_no),
               t.day_of_week, t.period_seq, c.class_name || ' – ' || sec.section_name, sj.subject_name, st.full_name,
               (SELECT ps.label FROM academic.period_structure ps
                 WHERE ps.tenant_id = t.tenant_id AND ps.school_id = t.school_id AND ps.seq = t.period_seq
                   AND (ps.day_of_week = t.day_of_week OR ps.day_of_week IS NULL)
                 ORDER BY ps.day_of_week NULLS LAST LIMIT 1)
          FROM academic.timetable t
          JOIN academic.academic_class_sections sec ON sec.academic_class_section_id = t.academic_class_section_id
          JOIN academic.academic_classes c ON c.academic_class_id = sec.academic_class_id
          LEFT JOIN academic.school_subjects sj ON sj.subject_id = t.subject_id
          LEFT JOIN core.staff st ON st.staff_id = t.staff_id
         WHERE t.tenant_id = p_tenant_id AND t.school_id = p_school_id AND t.academic_year_id = v_year
           AND academic.fn_room_key(COALESCE(NULLIF(trim(t.room_no), ''), sec.room_no)) IS NOT NULL;
    END IF;

    IF p_operation = 'List' THEN
        OPEN p_result FOR
        SELECT r.room_id, r.room_name, r.room_type, r.capacity, r.building, r.notes,
               (SELECT COUNT(*) FROM tmp_room_use u WHERE u.room_key = academic.fn_room_key(r.room_name))::int AS periods_week,
               (SELECT string_agg(DISTINCT sec.section_name, '') FROM academic.academic_class_sections sec
                 WHERE sec.tenant_id = p_tenant_id AND sec.school_id = p_school_id AND sec.academic_year_id = v_year
                   AND academic.fn_room_key(sec.room_no) = academic.fn_room_key(r.room_name)) AS home_of,
               (SELECT string_agg(DISTINCT c.class_name || ' – ' || sec.section_name, ', ')
                  FROM academic.academic_class_sections sec JOIN academic.academic_classes c ON c.academic_class_id = sec.academic_class_id
                 WHERE sec.tenant_id = p_tenant_id AND sec.school_id = p_school_id AND sec.academic_year_id = v_year
                   AND NOT COALESCE(sec.is_deleted, FALSE)
                   AND academic.fn_room_key(sec.room_no) = academic.fn_room_key(r.room_name)) AS home_sections
          FROM academic.rooms r
         WHERE r.tenant_id = p_tenant_id AND r.school_id = p_school_id AND NOT r.is_deleted
         ORDER BY r.room_type, r.room_name;
        RETURN;
    END IF;

    IF p_operation = 'Usage' THEN
        OPEN p_result FOR
        SELECT u.room_key, u.room_text, u.day_of_week, u.period_seq, u.period_label, u.section_label, u.subject_name, u.teacher
          FROM tmp_room_use u
         WHERE v_key IS NULL OR u.room_key = v_key
         ORDER BY u.room_key, u.day_of_week, u.period_seq;
        RETURN;
    END IF;

    IF p_operation = 'Unknown' THEN
        OPEN p_result FOR
        SELECT MIN(u.room_text) AS room_text, COUNT(*)::int AS periods_week
          FROM tmp_room_use u
         WHERE NOT EXISTS (SELECT 1 FROM academic.rooms r WHERE r.tenant_id = p_tenant_id AND r.school_id = p_school_id
                             AND NOT r.is_deleted AND academic.fn_room_key(r.room_name) = u.room_key)
         GROUP BY u.room_key
         ORDER BY 1;
        RETURN;
    END IF;

    IF p_operation = 'Save' THEN
        IF v_key IS NULL THEN RAISE EXCEPTION 'Give the room a name or number.'; END IF;
        IF COALESCE(p_room_type, 'Classroom') NOT IN ('Classroom', 'Lab', 'Library', 'Hall', 'Staff room', 'Office', 'Other') THEN
            RAISE EXCEPTION 'Choose a room type.';
        END IF;
        IF p_capacity IS NOT NULL AND p_capacity < 0 THEN RAISE EXCEPTION 'Capacity cannot be negative.'; END IF;
        IF EXISTS (SELECT 1 FROM academic.rooms r WHERE r.tenant_id = p_tenant_id AND r.school_id = p_school_id AND NOT r.is_deleted
                     AND academic.fn_room_key(r.room_name) = v_key AND r.room_id IS DISTINCT FROM p_room_id) THEN
            RAISE EXCEPTION 'A room called "%" already exists.', trim(p_room_name);
        END IF;

        IF p_room_id IS NULL THEN
            INSERT INTO academic.rooms (tenant_id, school_id, room_name, room_type, capacity, building, notes, created_by)
            VALUES (p_tenant_id, p_school_id, trim(p_room_name), COALESCE(p_room_type, 'Classroom'), p_capacity,
                    NULLIF(trim(p_building), ''), NULLIF(trim(p_notes), ''), p_action_user_id)
            RETURNING room_id INTO v_id;
        ELSE
            UPDATE academic.rooms
               SET room_name = trim(p_room_name), room_type = COALESCE(p_room_type, 'Classroom'), capacity = p_capacity,
                   building = NULLIF(trim(p_building), ''), notes = NULLIF(trim(p_notes), ''),
                   updated_by = p_action_user_id, updated_at = now()
             WHERE room_id = p_room_id AND tenant_id = p_tenant_id AND school_id = p_school_id AND NOT is_deleted
            RETURNING room_id INTO v_id;
            IF v_id IS NULL THEN RAISE EXCEPTION 'Room not found.'; END IF;
        END IF;
        OPEN p_result FOR SELECT v_id AS room_id, (CASE WHEN p_room_id IS NULL THEN 'Room added.' ELSE 'Room saved.' END)::varchar AS message;
        RETURN;
    END IF;

    IF p_operation = 'Delete' THEN
        UPDATE academic.rooms SET is_deleted = TRUE, updated_by = p_action_user_id, updated_at = now()
         WHERE room_id = p_room_id AND tenant_id = p_tenant_id AND school_id = p_school_id AND NOT is_deleted
        RETURNING room_id INTO v_id;
        IF v_id IS NULL THEN RAISE EXCEPTION 'Room not found.'; END IF;
        -- the timetable keeps its text; the room just leaves the list
        OPEN p_result FOR SELECT v_id AS room_id, 'Room removed from the list. Timetable bookings are kept.'::varchar AS message;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation.';
END;
$$;
