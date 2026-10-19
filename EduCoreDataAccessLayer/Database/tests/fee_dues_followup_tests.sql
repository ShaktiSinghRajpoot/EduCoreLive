-- Fee chasing (19 Oct 2026): follow-up notes, don't chase, settings, hold, late fee.
-- QA Test School (tenant 32, school 45, admin 62). Everything is ROLLED BACK.
-- Run from this folder:   psql ... -f fee_dues_followup_tests.sql
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
    c refcursor; m refcursor; k refcursor; s refcursor; r record;
    v_kid integer; v_kid2 integer; v_fid integer; v_n integer; v_n2 integer; v_bad integer;
BEGIN
    -- two active children with dues in the session
    SELECT e.student_id INTO v_kid FROM core.student_enrolment e
      JOIN core.student_ledger l ON l.student_id = e.student_id AND l.academic_year = '2026-27' AND l.amount_due > l.amount_paid + l.concession
     WHERE e.tenant_id = 32 AND e.school_id = 45 AND e.academic_year = '2026-27' AND e.class_name = 'Class 9' LIMIT 1;
    SELECT e.student_id INTO v_kid2 FROM core.student_enrolment e
      JOIN core.student_ledger l ON l.student_id = e.student_id AND l.academic_year = '2026-27' AND l.amount_due > l.amount_paid + l.concession
     WHERE e.tenant_id = 32 AND e.school_id = 45 AND e.academic_year = '2026-27' AND e.class_name = 'Class 10' LIMIT 1;

    -- ── follow-up notes ──
    c := 'f1'; CALL core.sp_fee_followup('Add', 32, 45, 62, v_kid, 'ZZ Father will pay on the 25th', to_char(CURRENT_DATE + 6, 'YYYY-MM-DD'), NULL, c);
    FETCH c INTO r; v_fid := r.followup_id; CLOSE c;
    PERFORM pg_temp.chk(v_fid IS NOT NULL, 'F1 a follow-up note is saved');
    BEGIN
        c := 'f2'; CALL core.sp_fee_followup('Add', 32, 45, 62, v_kid, '  ', NULL, NULL, c);
        PERFORM pg_temp.chk(FALSE, 'F2 an empty note is refused', 'saved');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk(TRUE, 'F2 an empty note is refused', SQLERRM); END;

    -- ── settings + the dues list shows the note, the hold, don't chase ──
    c := 's1'; CALL core.sp_fee_dues_settings('Save', 32, 45, 62, 50, 0, 1, c); FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk(r.late_fee_amount = 50 AND r.grace_days = 0 AND r.hold_months = 1, 'S1 settings are saved and read back');
    BEGIN
        c := 's2'; CALL core.sp_fee_dues_settings('Save', 32, 45, 62, -5, 0, 1, c);
        PERFORM pg_temp.chk(FALSE, 'S2 a negative late fee is refused', 'saved');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk(TRUE, 'S2 a negative late fee is refused', SQLERRM); END;

    c := 'n1'; CALL core.sp_fee_no_chase('Set', 32, 45, 62, v_kid2, 'RTE seat', NULL, c); CLOSE c;

    m := 'm1'; k := 'k1'; s := 's9';
    CALL core.sp_fee_month_dues(32, 45, 62, '2026-27', NULL, NULL, NULL, NULL, m, k, s);
    CLOSE m; CLOSE k;
    LOOP FETCH s INTO r; EXIT WHEN NOT FOUND;
        IF r.student_id = v_kid THEN
            PERFORM pg_temp.chk(r.followup_note LIKE 'ZZ Father%' AND r.promise_date <> '', 'D1 the list shows the open note and promise date');
            PERFORM pg_temp.chk(r.on_hold, 'D2 a child past the hold rule (1 month) is on hold');
        END IF;
        IF r.student_id = v_kid2 THEN
            PERFORM pg_temp.chk(r.no_chase = 'RTE seat' AND NOT r.on_hold, 'D3 a not-chased child shows the reason and is never on hold');
        END IF;
    END LOOP; CLOSE s;

    c := 'f3'; CALL core.sp_fee_followup('Done', 32, 45, 62, NULL, NULL, NULL, v_fid, c); CLOSE c;
    PERFORM pg_temp.chk((SELECT is_done FROM core.fee_followups WHERE followup_id = v_fid), 'F3 a note is marked done (and kept)');

    -- ── late fee ──
    c := 'l1'; CALL core.sp_fee_late_fee('Preview', 32, 45, 62, '2026-27', jsonb_build_array(v_kid, v_kid2), c); v_n := 0; v_bad := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; v_n := v_n + 1; IF r.student_id = v_kid2 THEN v_bad := v_bad + 1; END IF; END LOOP; CLOSE c;
    PERFORM pg_temp.chk(v_n >= 1 AND v_bad = 0, 'L1 the preview lists overdue months, leaving out a not-chased child', v_n || ' line(s)');
    c := 'l2'; CALL core.sp_fee_late_fee('Apply', 32, 45, 62, '2026-27', jsonb_build_array(v_kid, v_kid2), c); FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk(r.added = v_n, 'L2 apply adds what the preview showed', r.message);
    PERFORM pg_temp.chk((SELECT COUNT(*) FROM core.student_ledger WHERE student_id = v_kid AND fee_head_name = 'Late Fee'
                                                              AND academic_year = '2026-27' AND amount_due = 50) = v_n,
                        'L3 the late fee lines are on the fee account at the set amount');
    c := 'l3'; CALL core.sp_fee_late_fee('Apply', 32, 45, 62, '2026-27', jsonb_build_array(v_kid), c); FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk(r.added = 0, 'L4 applying again adds nothing (one late fee per month)', r.message);

    m := 'm2'; k := 'k2'; s := 's8';
    CALL core.sp_fee_month_dues(32, 45, 62, '2026-27', NULL, NULL, NULL, NULL, m, k, s);
    CLOSE m; CLOSE k; v_n2 := NULL;
    LOOP FETCH s INTO r; EXIT WHEN NOT FOUND; IF r.student_id = v_kid THEN v_n2 := r.months_count; PERFORM pg_temp.chk(r.late_fee = 50 * v_n, 'L5 the list shows the late fee owed', r.late_fee::text); END IF; END LOOP; CLOSE s;
    PERFORM pg_temp.chk(v_n2 = v_n, 'L6 late fee lines are not counted as extra months pending', COALESCE(v_n2::text, 'missing'));

    -- ── don't chase cleared ──
    c := 'n2'; CALL core.sp_fee_no_chase('Clear', 32, 45, 62, v_kid2, NULL, NULL, c); CLOSE c;
    PERFORM pg_temp.chk(NOT (SELECT is_active FROM core.fee_no_chase WHERE tenant_id = 32 AND school_id = 45 AND student_id = v_kid2),
                        'N1 clearing keeps the row, switched off');

    SELECT COUNT(*) FILTER (WHERE ok), COUNT(*) FILTER (WHERE NOT ok) INTO v_n, v_bad FROM _r;
    RAISE NOTICE '== % passed, % failed ==', v_n, v_bad;
END $t$;

ROLLBACK;
