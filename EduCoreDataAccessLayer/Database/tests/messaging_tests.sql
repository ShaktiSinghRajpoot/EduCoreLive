-- WhatsApp per school and the message log (18 Oct 2026). QA Test School (tenant 32, school 45,
-- admin 62); the Super Admin is user 8. Everything is ROLLED BACK. Run from this folder:
--     psql ... -f messaging_tests.sql
\set ON_ERROR_STOP 1
BEGIN;

CREATE TEMP TABLE _r(n serial, ok boolean, name text, detail text) ON COMMIT DROP;
CREATE FUNCTION pg_temp.chk(p_ok boolean, p_name text, p_detail text DEFAULT '') RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO _r(ok, name, detail) VALUES (COALESCE(p_ok, FALSE), p_name, p_detail);
    RAISE NOTICE '[%] %  %', CASE WHEN COALESCE(p_ok, FALSE) THEN 'PASS' ELSE 'FAIL' END, p_name, p_detail;
END $$;

DO $t$
DECLARE c refcursor; r record; v_n int; v_m int;
BEGIN
    DELETE FROM core.school_messaging WHERE tenant_id = 32 AND school_id = 45;
    PERFORM pg_temp.chk(NOT core.fn_whatsapp_on(32, 45), 'M1 WhatsApp is off for a school until the Super Admin switches it on');

    BEGIN
        c := 'a'; CALL core.sp_school_messaging('Save', 62, 45, TRUE, c);
        PERFORM pg_temp.chk(FALSE, 'M2 a school admin cannot switch WhatsApp on', 'it was switched on');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk(TRUE, 'M2 a school admin cannot switch WhatsApp on', SQLERRM); END;

    c := 'b'; CALL core.sp_school_messaging('Save', 8, 45, TRUE, c); FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk(r.whatsapp_on AND core.fn_whatsapp_on(32, 45), 'M3 the Super Admin switches it on');
    c := 'w'; CALL core.sp_whatsapp_on(32, 45, c); FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk(r.whatsapp_on, 'M4 the app sees it on (sp_whatsapp_on)');
    PERFORM pg_temp.chk(NOT core.fn_whatsapp_on(30, 41), 'M5 another school stays off');

    c := 'l1'; CALL core.sp_message_log('Add', 32, 45, 62, 'Absent', 703, 'Test Parent', '919839101237',
                                        'Dear Parent, ZZ was absent ...', 'absent_alert', 'Test', p_result => c); CLOSE c;
    c := 'l2'; CALL core.sp_message_log('Add', 32, 45, 62, 'Notice', NULL, 'No Number', NULL, 'ZZ notice', 'school_notice', 'NoPhone', p_result => c); CLOSE c;
    c := 'l3'; CALL core.sp_message_log('List', 32, 45, 62, p_result => c); v_n := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.message_text LIKE '%ZZ%' THEN v_n := v_n + 1; END IF; END LOOP; CLOSE c;
    PERFORM pg_temp.chk(v_n = 2, 'M6 both messages are in the log', v_n || ' rows');
    c := 'l4'; CALL core.sp_message_log('Summary', 32, 45, 62, 'Absent', p_result => c); FETCH c INTO r; CLOSE c;
    PERFORM pg_temp.chk(r.test >= 1 AND r.no_phone = 0, 'M7 summary by type counts the absent alert as Test', 'test ' || r.test);
    BEGIN
        c := 'l5'; CALL core.sp_message_log('Add', 32, 45, 62, 'Absent', NULL, 'x', 'x', 'x', 'x', 'Maybe', p_result => c);
        PERFORM pg_temp.chk(FALSE, 'M8 only known statuses are stored', 'stored');
    EXCEPTION WHEN OTHERS THEN PERFORM pg_temp.chk(TRUE, 'M8 only known statuses are stored', SQLERRM); END;
    c := 'l6'; CALL core.sp_message_log('List', 30, 41, 1, p_result => c); v_n := 0;
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; IF r.message_text LIKE '%ZZ%' THEN v_n := v_n + 1; END IF; END LOOP; CLOSE c;
    PERFORM pg_temp.chk(v_n = 0, 'M9 another school does not see these messages');

    SELECT COUNT(*) FILTER (WHERE ok), COUNT(*) FILTER (WHERE NOT ok) INTO v_n, v_m FROM _r;
    RAISE NOTICE '== % passed, % failed ==', v_n, v_m;
END $t$;

ROLLBACK;
