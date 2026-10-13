-- Staff attendance + substitutions (staff_attendance.sql): checks on the QA Test
-- School (tenant 32, school 45; admin login 62; QA Teacher = staff 92 / login 63;
-- Meena Kumari = staff 119). Creates the tables/procs inside the transaction and
-- ROLLS BACK, so it leaves nothing behind. Run from this folder:
--     psql ... -f staff_attendance_tests.sql
\set ON_ERROR_STOP 1
BEGIN;
\ir ../staff_attendance.sql

DO $t$
DECLARE
    TN int := 32; SC int := 45; ADMIN int := 62; TEACHER_LOGIN int := 63; QA_T int := 92; MEENA int := 119;
    D date;                       -- the most recent weekday Meena teaches on
    c refcursor; c2 refcursor; r record;
    v_n int; v_total int; v_txt text; v_sec int; v_seq smallint; v_free int; v_busy int;
    pass int := 0; fail int := 0;
BEGIN
    SELECT gs::date INTO D FROM generate_series(CURRENT_DATE - 6, CURRENT_DATE, interval '1 day') gs
     WHERE EXISTS (SELECT 1 FROM academic.timetable t WHERE t.tenant_id = TN AND t.staff_id = MEENA
                     AND t.day_of_week = EXTRACT(ISODOW FROM gs))
     ORDER BY gs DESC LIMIT 1;
    RAISE NOTICE 'test date %', D;

    -- 1. Day lists every active staff member, unmarked
    CALL core.sp_staff_attendance_manage('Day', TN, SC, ADMIN, D, NULL, NULL, NULL, NULL, c, c2);
    v_n := 0; v_total := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_total := v_total + 1; IF r.status IS NOT NULL THEN v_n := v_n + 1; END IF; END LOOP;
    CLOSE c; CLOSE c2;
    IF v_total > 20 AND v_n = 0 THEN pass := pass + 1; RAISE NOTICE 'PASS 1 day lists % staff, none marked', v_total;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 1 total % marked %', v_total, v_n; END IF;

    -- 2. Save: Meena absent, QA Teacher present, one left blank (not saved)
    CALL core.sp_staff_attendance_manage('Save', TN, SC, ADMIN, D, NULL, ARRAY[MEENA, QA_T, 120], ARRAY['Absent', 'Present', ''], ARRAY['Fever', NULL, NULL], c, c2);
    FETCH c INTO r; CLOSE c; CLOSE c2;
    IF r.message = 'Saved attendance for 2 staff.' AND (SELECT status FROM core.staff_attendance WHERE staff_id = MEENA AND att_date = D) = 'Absent'
    THEN pass := pass + 1; RAISE NOTICE 'PASS 2 %', r.message;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 2 %', r.message; END IF;

    -- 3. Saving again updates, not duplicates
    CALL core.sp_staff_attendance_manage('Save', TN, SC, ADMIN, D, NULL, ARRAY[QA_T], ARRAY['Late'], ARRAY['Bus late'], c, c2); CLOSE c; CLOSE c2;
    IF (SELECT COUNT(*) || status FROM core.staff_attendance WHERE staff_id = QA_T AND att_date = D GROUP BY status) = '1Late'
    THEN pass := pass + 1; RAISE NOTICE 'PASS 3 re-save updates the same row';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 3'; END IF;

    -- 4. Future date and unknown status are refused
    BEGIN
        CALL core.sp_staff_attendance_manage('Save', TN, SC, ADMIN, CURRENT_DATE + 1, NULL, ARRAY[QA_T], ARRAY['Present'], ARRAY[NULL::varchar], c, c2);
        fail := fail + 1; RAISE NOTICE 'FAIL 4 future accepted';
    EXCEPTION WHEN raise_exception THEN
        BEGIN
            CALL core.sp_staff_attendance_manage('Save', TN, SC, ADMIN, D, NULL, ARRAY[QA_T], ARRAY['Holiday'], ARRAY[NULL::varchar], c, c2);
            fail := fail + 1; RAISE NOTICE 'FAIL 4 bad status accepted';
        EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 4 future date and bad status refused'; END;
    END;

    -- 5. Month register: marks of the month + approved leave on unmarked days (QA Teacher, Sick, 2026-10-09)
    CALL core.sp_staff_attendance_manage('Month', TN, SC, ADMIN, NULL, '2026-10', NULL, NULL, NULL, c, c2);
    CLOSE c; v_txt := '';
    LOOP FETCH c2 INTO r; EXIT WHEN NOT FOUND;
        IF r.staff_id = QA_T AND r.day = 9 THEN v_txt := v_txt || 'd9=' || r.status || ';'; END IF;
        IF r.staff_id = MEENA AND r.day = EXTRACT(DAY FROM D) THEN v_txt := v_txt || 'meena=' || r.status || ';'; END IF;
    END LOOP; CLOSE c2;
    IF v_txt LIKE '%d9=Leave%' AND v_txt LIKE '%meena=Absent%' THEN pass := pass + 1; RAISE NOTICE 'PASS 5 month: %', v_txt;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 5 month: %', v_txt; END IF;

    -- 6. Substitution Day: Meena's periods need cover, reason Absent
    CALL academic.sp_substitution_manage('Day', TN, SC, ADMIN, D, NULL, NULL, NULL, c, c2);
    v_n := 0; v_sec := NULL;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
        IF r.staff_id = MEENA AND r.away_reason = 'Absent' THEN
            v_n := v_n + 1;
            -- first of her periods where QA Teacher is free
            IF v_sec IS NULL AND NOT EXISTS (SELECT 1 FROM academic.timetable t WHERE t.tenant_id = TN AND t.staff_id = QA_T
                                                AND t.day_of_week = EXTRACT(ISODOW FROM D) AND t.period_seq = r.period_seq) THEN
                v_sec := r.section_id; v_seq := r.period_seq;
            END IF;
        END IF;
    END LOOP; CLOSE c;
    v_busy := 0; LOOP FETCH c2 INTO r; EXIT WHEN NOT FOUND; v_busy := v_busy + 1; END LOOP; CLOSE c2;
    IF v_n > 0 AND v_sec IS NOT NULL AND v_busy > 10 THEN pass := pass + 1; RAISE NOTICE 'PASS 6 % periods of Meena to cover, % teachers listed', v_n, v_busy;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 6 periods % sec % teachers %', v_n, v_sec, v_busy; END IF;

    -- 7. Assign QA Teacher (free that period) -> saved; shows on the board and in QA Teacher's "Mine"
    --    (Mine lists from today on, so only checked when D is today)
    CALL academic.sp_substitution_manage('Assign', TN, SC, ADMIN, D, v_sec, v_seq, QA_T, c, c2); CLOSE c; CLOSE c2;
    IF EXISTS (SELECT 1 FROM academic.timetable_substitutions WHERE sub_date = D AND academic_class_section_id = v_sec
                AND period_seq = v_seq AND substitute_staff_id = QA_T AND original_staff_id = MEENA)
    THEN pass := pass + 1; RAISE NOTICE 'PASS 7 QA Teacher covers section % period %', v_sec, v_seq;
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 7 not saved'; END IF;
    IF D = CURRENT_DATE THEN
        CALL academic.sp_substitution_manage('Mine', TN, SC, TEACHER_LOGIN, NULL, NULL, NULL, NULL, c, c2);
        v_n := 0; LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_n := v_n + 1; END LOOP; CLOSE c; CLOSE c2;
        RAISE NOTICE '   Mine for QA Teacher: % row(s)', v_n;
    END IF;

    -- 8. An absent teacher cannot cover
    BEGIN
        SELECT staff_id INTO v_free FROM core.staff WHERE tenant_id = TN AND staff_type = 'Teaching' AND staff_id NOT IN (MEENA, QA_T) AND is_active
          ORDER BY staff_id LIMIT 1;
        CALL core.sp_staff_attendance_manage('Save', TN, SC, ADMIN, D, NULL, ARRAY[v_free], ARRAY['Absent'], ARRAY[NULL::varchar], c, c2); CLOSE c; CLOSE c2;
        CALL academic.sp_substitution_manage('Assign', TN, SC, ADMIN, D, v_sec, v_seq, v_free, c, c2);
        fail := fail + 1; RAISE NOTICE 'FAIL 8 absent substitute accepted';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 8 %', SQLERRM; END;

    -- 9. A teacher already teaching that period cannot cover
    BEGIN
        SELECT t.staff_id INTO v_busy FROM academic.timetable t
         WHERE t.tenant_id = TN AND t.day_of_week = EXTRACT(ISODOW FROM D) AND t.period_seq = v_seq
           AND t.staff_id NOT IN (MEENA, QA_T) LIMIT 1;
        CALL academic.sp_substitution_manage('Assign', TN, SC, ADMIN, D, v_sec, v_seq, v_busy, c, c2);
        fail := fail + 1; RAISE NOTICE 'FAIL 9 busy substitute accepted';
    EXCEPTION WHEN raise_exception THEN pass := pass + 1; RAISE NOTICE 'PASS 9 %', SQLERRM; END;

    -- 10. Remove
    CALL academic.sp_substitution_manage('Remove', TN, SC, ADMIN, D, v_sec, v_seq, NULL, c, c2); CLOSE c; CLOSE c2;
    IF NOT EXISTS (SELECT 1 FROM academic.timetable_substitutions WHERE sub_date = D AND academic_class_section_id = v_sec AND period_seq = v_seq)
    THEN pass := pass + 1; RAISE NOTICE 'PASS 10 removed';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 10 still there'; END IF;

    -- 11. Another school sees none of it
    CALL core.sp_staff_attendance_manage('Month', 30, 1, ADMIN, NULL, '2026-10', NULL, NULL, NULL, c, c2);
    CLOSE c; v_n := 0; LOOP FETCH c2 INTO r; EXIT WHEN NOT FOUND; IF r.staff_id IN (MEENA, QA_T) THEN v_n := v_n + 1; END IF; END LOOP; CLOSE c2;
    IF v_n = 0 THEN pass := pass + 1; RAISE NOTICE 'PASS 11 other school sees nothing';
    ELSE fail := fail + 1; RAISE NOTICE 'FAIL 11 leak'; END IF;

    RAISE NOTICE '== % passed, % failed ==', pass, fail;
END;
$t$;

ROLLBACK;
