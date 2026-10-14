-- Rooms (rooms.sql): checks on the QA Test School (tenant 32, school 45, admin
-- login 62; section 1-B has room_no 'Room 101'). Creates the table/proc inside
-- the transaction and ROLLS BACK. Run from this folder:
--     psql ... -f rooms_tests.sql
\set ON_ERROR_STOP 1
BEGIN;
\ir ../rooms.sql

DO $t$
DECLARE
    TN int := 32; SC int := 45; ADMIN int := 62;
    c refcursor; r record; v_id int; v_id2 int; v_n int; v_txt text;
    pass int := 0; fail int := 0;
BEGIN
    -- 1. add a room; it matches the section's "Room 101" through the room key
    CALL academic.sp_room_manage('Save', TN, SC, ADMIN, NULL, 'room-101', 'Classroom', 40, 'Main block', NULL, c);
    FETCH c INTO r; CLOSE c; v_id := r.room_id;
    CALL academic.sp_room_manage('List', TN, SC, ADMIN, NULL, NULL, NULL, NULL, NULL, NULL, c);
    v_txt := NULL;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.room_id = v_id THEN v_txt := r.periods_week || '/' || COALESCE(r.home_sections, '-'); END IF; END LOOP; CLOSE c;
    IF v_txt LIKE '%Class 1 – B%' AND split_part(v_txt, '/', 1)::int > 0 THEN pass := pass + 1; RAISE NOTICE 'PASS 1 room-101 = Room 101: %', v_txt;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 1 %', v_txt; END IF;

    -- 2. a second room with the same key is refused
    BEGIN
        CALL academic.sp_room_manage('Save', TN, SC, ADMIN, NULL, 'ROOM 101', 'Lab', NULL, NULL, NULL, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 2 duplicate accepted';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 2 %', SQLERRM; END;

    -- 3. usage of the room lists its periods with section and subject
    CALL academic.sp_room_manage('Usage', TN, SC, ADMIN, NULL, 'Room 101', NULL, NULL, NULL, NULL, c);
    v_n := 0; v_txt := NULL;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_n := v_n + 1; v_txt := COALESCE(v_txt, r.section_label || ' ' || COALESCE(r.subject_name, '')); END LOOP; CLOSE c;
    IF v_n > 0 THEN pass := pass + 1; RAISE NOTICE 'PASS 3 % booked period(s), e.g. %', v_n, v_txt;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 3 no usage'; END IF;

    -- 4. a room typed in the timetable but not in the list shows as unknown, then disappears once added
    UPDATE academic.timetable SET room_no = 'Lab-2' WHERE timetable_id = (SELECT MIN(timetable_id) FROM academic.timetable WHERE tenant_id = TN);
    CALL academic.sp_room_manage('Unknown', TN, SC, ADMIN, NULL, NULL, NULL, NULL, NULL, NULL, c);
    v_n := 0; LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.room_text = 'Lab-2' THEN v_n := 1; END IF; END LOOP; CLOSE c;
    CALL academic.sp_room_manage('Save', TN, SC, ADMIN, NULL, 'Lab 2', 'Lab', 30, NULL, NULL, c); FETCH c INTO r; CLOSE c; v_id2 := r.room_id;
    CALL academic.sp_room_manage('Unknown', TN, SC, ADMIN, NULL, NULL, NULL, NULL, NULL, NULL, c);
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.room_text = 'Lab-2' THEN v_n := v_n + 10; END IF; END LOOP; CLOSE c;
    IF v_n = 1 THEN pass := pass + 1; RAISE NOTICE 'PASS 4 unknown "Lab-2" listed, then matched by "Lab 2"';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 4 code %', v_n; END IF;

    -- 5. edit and delete; the timetable text is kept
    CALL academic.sp_room_manage('Save', TN, SC, ADMIN, v_id2, 'Lab 2', 'Lab', 32, 'Science block', NULL, c); CLOSE c;
    CALL academic.sp_room_manage('Delete', TN, SC, ADMIN, v_id2, NULL, NULL, NULL, NULL, NULL, c); CLOSE c;
    IF (SELECT is_deleted AND capacity = 32 FROM academic.rooms WHERE room_id = v_id2)
       AND EXISTS (SELECT 1 FROM academic.timetable WHERE room_no = 'Lab-2')
    THEN pass := pass + 1; RAISE NOTICE 'PASS 5 edited, removed, timetable text kept';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 5'; END IF;

    -- 6. another school cannot delete it
    BEGIN
        CALL academic.sp_room_manage('Delete', 30, 1, ADMIN, v_id, NULL, NULL, NULL, NULL, NULL, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 6 cross-school delete';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 6 %', SQLERRM; END;

    RAISE NOTICE '== % passed, % failed ==', pass, fail;
END;
$t$;

ROLLBACK;
