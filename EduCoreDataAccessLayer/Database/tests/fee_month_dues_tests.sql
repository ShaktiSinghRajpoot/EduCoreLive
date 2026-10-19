-- Month-wise dues + "may have left" (19 Oct 2026). QA Test School (tenant 32, school 45,
-- admin 62). Everything is ROLLED BACK.   psql ... -f fee_month_dues_tests.sql
\set ON_ERROR_STOP 1
BEGIN;

CREATE TEMP TABLE _r(n serial, ok boolean, name text, detail text) ON COMMIT DROP;
CREATE FUNCTION pg_temp.chk(p_ok boolean, p_name text, p_detail text DEFAULT '') RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO _r(ok, name, detail) VALUES (COALESCE(p_ok, FALSE), p_name, p_detail);
    RAISE NOTICE '[%] %  %', CASE WHEN COALESCE(p_ok, FALSE) THEN 'PASS' ELSE 'FAIL' END, p_name, p_detail;
END $$;

DO $t$
DECLARE
    m refcursor; c refcursor; s refcursor; r record;
    v_cls varchar; v_sec varchar; v_gone integer; v_here integer; d integer;
    v_sum_m numeric := 0; v_sum_s numeric := 0; v_sum_c numeric := 0; v_flag_gone boolean; v_flag_here boolean; v_n integer;
BEGIN
    -- two active children of one class-section with dues
    SELECT e.class_name, e.section INTO v_cls, v_sec FROM core.student_enrolment e
     WHERE e.tenant_id = 32 AND e.school_id = 45 AND e.academic_year = '2026-27' AND e.class_name = 'Class 12 Science (PCM)' LIMIT 1;
    SELECT MIN(e.student_id), MAX(e.student_id) INTO v_gone, v_here FROM core.student_enrolment e
     WHERE e.tenant_id = 32 AND e.school_id = 45 AND e.academic_year = '2026-27' AND e.class_name = v_cls AND e.section = v_sec;

    -- the register taken on 6 of the last 21 days: v_gone absent every day, v_here present
    DELETE FROM core.student_attendance WHERE student_id IN (v_gone, v_here);
    FOR d IN 1..6 LOOP
        INSERT INTO core.student_attendance (tenant_id, school_id, student_id, attendance_date, status, academic_year, class_name, section, marked_by)
        VALUES (32, 45, v_gone, to_char(CURRENT_DATE - d, 'YYYY-MM-DD'), 'Absent',  '2026-27', v_cls, v_sec, 62),
               (32, 45, v_here, to_char(CURRENT_DATE - d, 'YYYY-MM-DD'), 'Present', '2026-27', v_cls, v_sec, 62);
    END LOOP;

    m := 'm'; c := 'c'; s := 's';
    CALL core.sp_fee_month_dues(32, 45, 62, '2026-27', NULL, NULL, NULL, NULL, m, c, s);
    LOOP FETCH m INTO r; EXIT WHEN NOT FOUND; v_sum_m := v_sum_m + r.pending; END LOOP; CLOSE m;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_sum_c := v_sum_c + r.pending; END LOOP; CLOSE c;
    LOOP FETCH s INTO r; EXIT WHEN NOT FOUND;
        v_sum_s := v_sum_s + r.pending;
        IF r.student_id = v_gone THEN v_flag_gone := r.may_have_left; END IF;
        IF r.student_id = v_here THEN v_flag_here := r.may_have_left; END IF;
    END LOOP; CLOSE s;

    PERFORM pg_temp.chk(v_sum_m = v_sum_s AND v_sum_s = v_sum_c AND v_sum_s > 0, 'D1 months, classes and children add up to the same pending',
                        v_sum_m || ' / ' || v_sum_c || ' / ' || v_sum_s);
    PERFORM pg_temp.chk(v_flag_gone, 'D2 a child absent every day the register was taken is flagged "may have left"');
    PERFORM pg_temp.chk(NOT COALESCE(v_flag_here, FALSE), 'D3 a child present is not flagged');

    -- dues up to a month before every fee fell due: nothing
    m := 'm2'; c := 'c2'; s := 's2';
    CALL core.sp_fee_month_dues(32, 45, 62, '2026-27', NULL, '2026-03', NULL, NULL, m, c, s);
    v_n := 0; LOOP FETCH m INTO r; EXIT WHEN NOT FOUND; v_n := v_n + 1; END LOOP; CLOSE m;
    CLOSE c; CLOSE s;
    PERFORM pg_temp.chk(v_n = 0, 'D4 "due up to" leaves out fees falling due later', v_n || ' month(s)');

    -- from November to December: only those two months
    m := 'm4'; c := 'c4'; s := 's4';
    CALL core.sp_fee_month_dues(32, 45, 62, '2026-27', '2026-11', '2026-12', NULL, NULL, m, c, s);
    v_n := 0; LOOP FETCH m INTO r; EXIT WHEN NOT FOUND; IF r.month NOT IN ('2026-11', '2026-12') THEN v_n := v_n + 1; END IF; END LOOP; CLOSE m; CLOSE c; CLOSE s;
    PERFORM pg_temp.chk(v_n = 0, 'D7 "from" and "to" keep only the months between them', v_n || ' month(s) outside');

    -- one class only
    m := 'm3'; c := 'c3'; s := 's3';
    CALL core.sp_fee_month_dues(32, 45, 62, '2026-27', NULL, NULL, v_cls, v_sec, m, c, s);
    CLOSE m; v_n := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.class_name <> v_cls THEN v_n := v_n + 1; END IF; END LOOP; CLOSE c;
    CLOSE s;
    PERFORM pg_temp.chk(v_n = 0, 'D5 the class filter shows that class only');

    -- the attendance brief
    m := 'a'; c := 'b';
    CALL core.sp_student_attendance_brief(32, 45, 62, v_gone, '2026-27', m, c);
    FETCH m INTO r; CLOSE m; CLOSE c;
    PERFORM pg_temp.chk(r.absent_streak = 6 AND r.present = 0 AND r.marked = 6, 'D6 the brief shows 6 days absent, none present', r.absent_streak || ' / ' || r.present || ' / ' || r.marked);

    SELECT COUNT(*) FILTER (WHERE ok), COUNT(*) FILTER (WHERE NOT ok) INTO v_n, d FROM _r;
    RAISE NOTICE '== % passed, % failed ==', v_n, d;
END $t$;

ROLLBACK;
