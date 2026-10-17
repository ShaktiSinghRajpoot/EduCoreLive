-- How Promotion and Year-End work together, in either order (17 Oct 2026).
-- QA Test School (tenant 32, school 45, admin 62), 2026-27 -> 2027-28.
--
-- The session is made to END TODAY inside the transaction and every 2026-27 fee
-- line is made due today, so this is "31 March" without waiting for it.
--   1. Promote first (with dues), then Year-End carries the old dues
--   2. Year-End first (child not promoted yet), then promote
--   3. Pass out with dues, then Year-End writes them off
--   4. Close the session, then promote someone after it
-- Everything is ROLLED BACK. Run from this folder:
--     psql ... -f promotion_year_end_flow_tests.sql
\set ON_ERROR_STOP 1
BEGIN;
\o NUL
\ir ../fee_year_end.sql
\o

CREATE TEMP TABLE _r(n serial, ok boolean, name text, detail text) ON COMMIT DROP;
CREATE FUNCTION pg_temp.chk(p_ok boolean, p_name text, p_detail text DEFAULT '') RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO _r(ok, name, detail) VALUES (p_ok, p_name, p_detail);
    RAISE NOTICE '[%] %  %', CASE WHEN p_ok THEN 'PASS' ELSE 'FAIL' END, p_name, p_detail;
END $$;

-- open dues of one child, by session ('' = all)
CREATE FUNCTION pg_temp.owed(p_student int, p_year text) RETURNS numeric LANGUAGE sql AS $$
    SELECT COALESCE(SUM(amount_due - amount_paid - concession), 0) FROM core.student_ledger
     WHERE student_id = p_student AND amount_due > amount_paid + concession
       AND (p_year = '' OR academic_year = p_year)
$$;

-- the class Year-End's list shows for a child, and how many lines
CREATE FUNCTION pg_temp.ye_list(p_student int, OUT cls text, OUT lines int, OUT carried int) LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'yl'; r record;
BEGIN
    lines := 0; carried := 0;
    CALL core.sp_fee_year_end_manage('List', 32, 45, 62, '2026-27', p_result => c);
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
        IF r.student_id = p_student THEN
            cls := r.class_name; lines := lines + 1;
            IF r.state = 'Carried' THEN carried := carried + 1; END IF;
        END IF;
    END LOOP; CLOSE c;
END $$;

-- what Fee Due Reminders says the child owes, and under which class
CREATE FUNCTION pg_temp.due_list(p_name text, OUT cls text, OUT amount numeric) LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'dl'; r record;
BEGIN
    CALL core.sp_fee_due_list(32, 45, 62, p_search => p_name, p_page_size => 50, p_result => c);
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND;
        IF r.student_name = p_name THEN cls := r.class_name; amount := r.total_outstanding; END IF;
    END LOOP; CLOSE c;
END $$;

CREATE FUNCTION pg_temp.promote(p_student int, p_outcome text, p_carry boolean) RETURNS void LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'pr';
BEGIN
    CALL core.sp_student_promote(32, 45, 62, '2026-27', '2027-28', NULL, p_carry,
         jsonb_build_array(jsonb_build_object('studentId', p_student, 'outcome', p_outcome)), c);
    CLOSE c;
END $$;

CREATE FUNCTION pg_temp.ye(p_op text, p_student int DEFAULT NULL, p_ledger int DEFAULT NULL, p_reason text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'ye'; r record;
BEGIN
    CALL core.sp_fee_year_end_manage(p_op, 32, 45, 62, '2026-27', p_ledger, p_student, p_reason, c);
    FETCH c INTO r; CLOSE c;
    RETURN r.message;
END $$;

DO $t$
DECLARE
    v_tanvi int; v_kiara int; v_sumit int; v_x int; v_xname text;
    v_before numeric; v_after numeric; v_n int; v_line int; v_txt text; r record;
BEGIN
    SELECT student_id INTO v_tanvi FROM core.students WHERE tenant_id = 32 AND student_name = 'Tanvi Agarwal';
    SELECT student_id INTO v_kiara FROM core.students WHERE tenant_id = 32 AND student_name = 'Kiara Pandey';
    SELECT student_id INTO v_sumit FROM core.students WHERE tenant_id = 32 AND student_name = 'Sumit Chaurasia';
    SELECT e.student_id, s.student_name INTO v_x, v_xname
      FROM core.student_enrolment e JOIN core.students s ON s.student_id = e.student_id
     WHERE e.tenant_id = 32 AND e.academic_year = '2026-27' AND e.class_name = 'Class 10'
       AND COALESCE(e.status, '') NOT IN ('Left', 'PassedOut') AND pg_temp.owed(e.student_id, '2026-27') > 0
     ORDER BY e.student_id LIMIT 1;
    IF v_tanvi IS NULL OR v_kiara IS NULL OR v_sumit IS NULL OR v_x IS NULL THEN RAISE EXCEPTION 'Fixture children missing'; END IF;

    -- "31 March": 2026-27 ends today and all its fees have fallen due
    UPDATE academic.academic_years SET end_date = to_char(CURRENT_DATE, 'YYYY-MM-DD')
     WHERE tenant_id = 32 AND school_id = 45 AND academic_year_name = '2026-27';
    UPDATE core.student_ledger SET due_date = to_char(CURRENT_DATE, 'YYYY-MM-DD')
     WHERE tenant_id = 32 AND school_id = 45 AND academic_year = '2026-27' AND due_date::date > CURRENT_DATE;

    RAISE NOTICE '';
    RAISE NOTICE '== 1. Promote first (with dues), then Year-End ==';
    v_before := pg_temp.owed(v_tanvi, '');
    PERFORM pg_temp.promote(v_tanvi, 'promote', TRUE);
    SELECT COUNT(*) INTO v_n FROM core.student_enrolment WHERE student_id = v_tanvi AND academic_year = '2027-28';
    PERFORM pg_temp.chk(v_n = 1, '1a promoted with dues (Class 3 -> 2027-28)');
    PERFORM pg_temp.chk(pg_temp.owed(v_tanvi, '2026-27') > 0, '1b old dues still in 2026-27 after promotion',
                        'Rs ' || pg_temp.owed(v_tanvi, '2026-27'));
    SELECT * INTO r FROM pg_temp.ye_list(v_tanvi);
    PERFORM pg_temp.chk(r.lines > 0, '1c Year-End list shows her 2026-27 dues', r.lines || ' lines');
    PERFORM pg_temp.chk(r.cls = 'Class 3', '1d ... under her 2026-27 class', 'shows ' || COALESCE(r.cls, 'NULL'));
    v_txt := pg_temp.ye('Carry', v_tanvi);
    PERFORM pg_temp.chk(pg_temp.owed(v_tanvi, '2026-27') = 0, '1e Carry: nothing left in 2026-27', v_txt);
    SELECT COUNT(*) INTO v_n FROM core.student_ledger WHERE student_id = v_tanvi AND carried_from = '2026-27' AND academic_year = '2027-28';
    PERFORM pg_temp.chk(v_n > 0, '1f carried lines sit in 2027-28 marked "from 2026-27"', v_n || ' lines');
    v_after := pg_temp.owed(v_tanvi, '');
    PERFORM pg_temp.chk(v_after = v_before + (SELECT COALESCE(SUM(amount_due), 0) FROM core.student_ledger
                                              WHERE student_id = v_tanvi AND academic_year = '2027-28' AND carried_from IS NULL),
                        '1g no money lost or doubled (old dues + 2027-28 fees)', v_before || ' -> ' || v_after);
    SELECT * INTO r FROM pg_temp.ye_list(v_tanvi);
    PERFORM pg_temp.chk(r.carried = r.lines AND r.lines > 0, '1h Year-End list now shows them as Carried', r.carried || '/' || r.lines);
    SELECT MIN(ledger_id) INTO v_line FROM core.student_ledger WHERE student_id = v_tanvi AND carried_from = '2026-27';
    v_txt := pg_temp.ye('Undo', NULL, v_line);
    PERFORM pg_temp.chk((SELECT academic_year FROM core.student_ledger WHERE ledger_id = v_line) = '2026-27', '1i Undo puts a line back in 2026-27', v_txt);
    v_txt := pg_temp.ye('Carry', NULL, v_line);

    RAISE NOTICE '';
    RAISE NOTICE '== 2. Year-End first (not promoted yet), then promote ==';
    v_before := pg_temp.owed(v_kiara, '');
    v_txt := pg_temp.ye('Carry', v_kiara);
    PERFORM pg_temp.chk(pg_temp.owed(v_kiara, '2027-28') = v_before AND pg_temp.owed(v_kiara, '2026-27') = 0,
                        '2a dues carried to 2027-28 although she is still in Class 3', v_txt);
    SELECT * INTO r FROM pg_temp.due_list('Kiara Pandey');
    PERFORM pg_temp.chk(r.amount = v_before, '2b Fee Due Reminders still asks for all of it', COALESCE(r.amount::text, 'not listed') || ' under ' || COALESCE(r.cls, '-'));
    BEGIN
        PERFORM pg_temp.promote(v_kiara, 'promote', FALSE);
        v_txt := 'it went through';
    EXCEPTION WHEN OTHERS THEN
        v_txt := SQLERRM;
    END;
    SELECT COUNT(*) INTO v_n FROM core.student_enrolment WHERE student_id = v_kiara AND academic_year = '2027-28';
    PERFORM pg_temp.chk(v_n = 0, '2c "hold back who owe": carried dues still count -> held back', v_txt);
    PERFORM pg_temp.promote(v_kiara, 'promote', TRUE);
    SELECT COUNT(*) INTO v_n FROM core.student_enrolment WHERE student_id = v_kiara AND academic_year = '2027-28';
    PERFORM pg_temp.chk(v_n = 1, '2d promote with dues: moves up');
    SELECT COUNT(*) INTO v_n FROM core.student_ledger WHERE student_id = v_kiara AND carried_from = '2026-27' AND amount_due > amount_paid + concession;
    PERFORM pg_temp.chk(v_n > 0, '2e carried dues untouched by the promotion', v_n || ' lines');

    RAISE NOTICE '';
    RAISE NOTICE '== 3. Pass out with dues, then Year-End ==';
    -- an unpaid refundable deposit (caution money) is closed on leaving: it would
    -- only be collected to be handed back. Every other due stays.
    SELECT pg_temp.owed(v_x, '2026-27') - COALESCE(SUM(l.amount_due - l.amount_paid - l.concession), 0) INTO v_before
      FROM core.student_ledger l JOIN core.school_fee_heads h ON h.fee_head_id = l.fee_head_id AND COALESCE(h.is_refundable, FALSE)
     WHERE l.student_id = v_x AND l.academic_year = '2026-27' AND l.amount_due > l.amount_paid + l.concession;
    PERFORM pg_temp.promote(v_x, 'passout', TRUE);
    PERFORM pg_temp.chk((SELECT NOT is_active FROM core.students WHERE student_id = v_x), '3a ' || v_xname || ' passed out');
    PERFORM pg_temp.chk(pg_temp.owed(v_x, '2026-27') = v_before, '3b fees already due stay open (only the deposit closes)',
                        'Rs ' || pg_temp.owed(v_x, '2026-27') || ', expected ' || v_before);
    SELECT * INTO r FROM pg_temp.ye_list(v_x);
    PERFORM pg_temp.chk(r.lines > 0, '3c Year-End lists the passed-out child', r.lines || ' lines, ' || COALESCE(r.cls, '-'));
    v_txt := pg_temp.ye('WriteOff', v_x, NULL, 'Passed out, family cannot pay (test)');
    PERFORM pg_temp.chk(pg_temp.owed(v_x, '') = 0, '3d Write off clears them', v_txt);
    SELECT * INTO r FROM pg_temp.due_list(v_xname);
    PERFORM pg_temp.chk(r.amount IS NULL, '3e no longer on Fee Due Reminders');

    RAISE NOTICE '';
    RAISE NOTICE '== 4. Close the session, then promote after it ==';
    BEGIN
        v_txt := pg_temp.ye('Close');
        PERFORM pg_temp.chk(FALSE, '4a Close refused while lines are undecided', 'it closed');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk(TRUE, '4a Close refused while lines are undecided', SQLERRM);
    END;
    v_txt := pg_temp.ye('CarryAll');
    PERFORM pg_temp.chk(TRUE, '4b Carry all', v_txt);
    v_txt := pg_temp.ye('Close');
    PERFORM pg_temp.chk((SELECT fees_closed_at IS NOT NULL FROM academic.academic_years WHERE tenant_id = 32 AND academic_year_name = '2026-27'),
                        '4c session closed', v_txt);
    PERFORM pg_temp.promote(v_sumit, 'promote', TRUE);
    SELECT COUNT(*) INTO v_n FROM core.student_enrolment WHERE student_id = v_sumit AND academic_year = '2027-28';
    PERFORM pg_temp.chk(v_n = 1, '4d promotion still works after the fees are closed');
    PERFORM pg_temp.chk(pg_temp.owed(v_sumit, '2026-27') = 0 AND pg_temp.owed(v_sumit, '2027-28') > 0,
                        '4e his old dues are in 2027-28 (carried), new fees billed', 'Rs ' || pg_temp.owed(v_sumit, '2027-28'));
    BEGIN
        v_txt := pg_temp.ye('Undo', NULL, (SELECT MIN(ledger_id) FROM core.student_ledger WHERE student_id = v_sumit AND carried_from = '2026-27'));
        PERFORM pg_temp.chk(FALSE, '4f a closed session cannot be changed', 'undo went through');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk(TRUE, '4f a closed session cannot be changed', SQLERRM);
    END;

    SELECT COUNT(*) FILTER (WHERE ok), COUNT(*) FILTER (WHERE NOT ok) INTO v_n, v_line FROM _r;
    RAISE NOTICE '';
    RAISE NOTICE '== % passed, % failed ==', v_n, v_line;
END $t$;

ROLLBACK;
