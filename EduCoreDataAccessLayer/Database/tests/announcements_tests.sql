-- Announcements (announcements.sql): checks on the QA Test School (tenant 32,
-- school 45: admin login 62, teacher 63, accountant 64). Creates the tables/proc
-- inside the transaction and ROLLS BACK, so it leaves nothing behind.
-- Run from this folder:
--     psql ... -f announcements_tests.sql
\set ON_ERROR_STOP 1
BEGIN;
\ir ../announcements.sql

DO $t$
DECLARE
    T int := 32; S int := 45; ADMIN int := 62; TEACHER int := 63; ACC int := 64;
    c refcursor; r record; v_id int; v_old int; v_n int; v_txt text;
    pass int := 0; fail int := 0;
BEGIN
    -- 1. admin posts a notice; it is on the board, unread for the teacher, read for the admin
    CALL core.sp_announcement_manage('Save', T, S, ADMIN, NULL, 'PTM on Saturday', 'Parents meet class teachers 10am-1pm.',
                                     'PTM', 'Everyone', NULL, TRUE, NULL, c);
    FETCH c INTO r; CLOSE c; v_id := r.announcement_id;
    CALL core.sp_announcement_manage('Board', T, S, TEACHER, NULL, NULL, NULL, NULL, NULL, NULL, FALSE, NULL, c);
    v_txt := NULL;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.announcement_id = v_id THEN v_txt := r.is_read || '/' || r.seen_count || '/' || r.posted_by || '/' || r.is_pinned; END IF; END LOOP; CLOSE c;
    IF v_txt LIKE 'false/1/%/true' THEN pass := pass + 1; RAISE NOTICE 'PASS 1 posted, teacher sees it unread: %', v_txt;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 1 %', v_txt; END IF;

    -- 2. teacher opens the board -> read; Seen by lists QA Teacher
    CALL core.sp_announcement_manage('Read', T, S, TEACHER, NULL, NULL, NULL, NULL, NULL, NULL, FALSE, NULL, c); CLOSE c;
    CALL core.sp_announcement_manage('SeenBy', T, S, ADMIN, v_id, NULL, NULL, NULL, NULL, NULL, FALSE, NULL, c);
    v_txt := '';
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_txt := v_txt || r.name || ';'; END LOOP; CLOSE c;
    IF v_txt LIKE '%QA Teacher%' THEN pass := pass + 1; RAISE NOTICE 'PASS 2 seen by: %', v_txt;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 2 seen by: %', v_txt; END IF;

    -- 3. reading twice does not double count
    CALL core.sp_announcement_manage('Read', T, S, TEACHER, v_id, NULL, NULL, NULL, NULL, NULL, FALSE, NULL, c); CLOSE c;
    IF (SELECT COUNT(*) FROM core.announcement_reads WHERE announcement_id = v_id) = 2
    THEN pass := pass + 1; RAISE NOTICE 'PASS 3 seen count stays 2';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 3 double read'; END IF;

    -- 4. Classes audience needs at least one class
    BEGIN
        CALL core.sp_announcement_manage('Save', T, S, ADMIN, NULL, 'Picnic', 'Class trip', 'Event', 'Classes', '  ', FALSE, NULL, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 4 classes without a class accepted';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 4 %', SQLERRM; END;

    -- 5. empty title refused
    BEGIN
        CALL core.sp_announcement_manage('Save', T, S, ADMIN, NULL, ' ', 'x', 'General', 'Everyone', NULL, FALSE, NULL, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 5 empty title accepted';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 5 %', SQLERRM; END;

    -- 6. edit keeps the id; switching audience away from Classes clears the class list
    CALL core.sp_announcement_manage('Save', T, S, ADMIN, v_id, 'PTM moved to Sunday', 'Same time.', 'PTM', 'Classes', '5,6', FALSE, NULL, c); CLOSE c;
    CALL core.sp_announcement_manage('Save', T, S, ADMIN, v_id, 'PTM moved to Sunday', 'Same time.', 'PTM', 'Parents', '5,6', FALSE, NULL, c); CLOSE c;
    SELECT title || '/' || audience || '/' || COALESCE(class_names, 'none') INTO v_txt FROM core.announcements WHERE announcement_id = v_id;
    IF v_txt = 'PTM moved to Sunday/Parents/none' THEN pass := pass + 1; RAISE NOTICE 'PASS 6 edited: %', v_txt;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 6 %', v_txt; END IF;

    -- 7. a notice cannot be posted already expired; one that expires later leaves the board
    --    but stays in the manage list
    BEGIN
        CALL core.sp_announcement_manage('Save', T, S, ADMIN, NULL, 'Old holiday', 'Was yesterday', 'Holiday', 'Everyone', NULL, FALSE, CURRENT_DATE - 1, c);
        RAISE EXCEPTION 'expired notice accepted';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM = 'expired notice accepted' THEN RAISE; END IF;
    END;
    CALL core.sp_announcement_manage('Save', T, S, ADMIN, NULL, 'Old holiday', 'Was yesterday', 'Holiday', 'Everyone', NULL, FALSE, CURRENT_DATE, c);
    FETCH c INTO r; CLOSE c; v_old := r.announcement_id;
    UPDATE core.announcements SET show_until = CURRENT_DATE - 1 WHERE announcement_id = v_old;   -- time passes
    CALL core.sp_announcement_manage('Board', T, S, ACC, NULL, NULL, NULL, NULL, NULL, NULL, FALSE, NULL, c);
    v_n := 0; LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.announcement_id = v_old THEN v_n := v_n + 1; END IF; END LOOP; CLOSE c;
    CALL core.sp_announcement_manage('List', T, S, ADMIN, NULL, NULL, NULL, NULL, NULL, NULL, FALSE, NULL, c);
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.announcement_id = v_old THEN v_n := v_n + 10; END IF; END LOOP; CLOSE c;
    IF v_n = 10 THEN pass := pass + 1; RAISE NOTICE 'PASS 7 expired: off the board, in the list';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 7 code %', v_n; END IF;

    -- 8. another school cannot edit or delete it
    BEGIN
        CALL core.sp_announcement_manage('Delete', 30, 1, ADMIN, v_id, NULL, NULL, NULL, NULL, NULL, FALSE, NULL, c);
        fail := fail + 1; RAISE NOTICE 'FAIL 8 cross-school delete accepted';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 8 %', SQLERRM; END;

    -- 9. delete removes it from board and list
    CALL core.sp_announcement_manage('Delete', T, S, ADMIN, v_id, NULL, NULL, NULL, NULL, NULL, FALSE, NULL, c); CLOSE c;
    CALL core.sp_announcement_manage('List', T, S, ADMIN, NULL, NULL, NULL, NULL, NULL, NULL, FALSE, NULL, c);
    v_n := 0; LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.announcement_id = v_id THEN v_n := v_n + 1; END IF; END LOOP; CLOSE c;
    IF v_n = 0 THEN pass := pass + 1; RAISE NOTICE 'PASS 9 deleted';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 9 still listed'; END IF;

    RAISE NOTICE '== % passed, % failed ==', pass, fail;
END;
$t$;

ROLLBACK;
