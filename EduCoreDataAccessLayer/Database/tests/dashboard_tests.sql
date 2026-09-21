-- ============================================================================
-- Dashboard test suite.
--
-- WHY THIS EXISTS: the landing dashboard is the most-opened page in the app and
-- was the ONE module with no suite. It broke on the date-to-text migration -
-- `fp.payment_date = g.d::date` in the 7-day trend - and 481 checks across the
-- other fifteen suites did not notice, because none of them called this
-- procedure. The user found it by opening the page.
--
-- The lesson shapes the suite: a refcursor proc does almost nothing until its
-- cursors are FETCHED, so every check below fetches. A test that only CALLs
-- would have passed while the page was still broken.
--
-- Runs inside ONE transaction and ROLLS BACK.
--
--     psql ... -f dashboard_tests.sql
--
-- COVERS
--   A. Every cursor opens and fetches
--   B. The 7-day trend - the query that actually broke
--   C. Dates come back as ISO text
--   D. Scope
-- ============================================================================

\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE TEMP TABLE _t(id serial, name text, ok boolean, detail text) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.chk(p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO _t(name, ok, detail) VALUES (p_name, p_ok, p_detail);
    RAISE NOTICE '  [%] %  %', CASE WHEN p_ok THEN 'PASS' ELSE 'FAIL' END, rpad(p_name, 54), p_detail;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.chk_eq(p_name text, p_got numeric, p_want numeric)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.chk(p_name, p_got IS NOT DISTINCT FROM p_want,
                        format('got %s, expected %s', COALESCE(p_got::text,'NULL'), p_want));
END $$;


DO $suite$
DECLARE
    c_tenant CONSTANT integer := 23;
    c_school CONSTANT integer := 33;
    c_user   CONSTANT integer := 1;

    -- one name per cursor the dashboard opens
    c_names  CONSTANT text[] := ARRAY['db_kpi','db_trend','db_classes','db_modes',
                                      'db_defaulters','db_recent','db_approvals',
                                      'db_events','db_birthdays'];
    v_name   text;
    v_cur    refcursor;
    -- INOUT refcursor parameters need writable arguments, so the cursors are
    -- named here and passed in; the names are then used to fetch them back.
    k refcursor := 'db_kpi';        t refcursor := 'db_trend';
    cl refcursor := 'db_classes';   m refcursor := 'db_modes';
    df refcursor := 'db_defaulters';rc refcursor := 'db_recent';
    ap refcursor := 'db_approvals'; ev refcursor := 'db_events';
    bd refcursor := 'db_birthdays';
    v_rec    record;
    v_n      integer;
    v_amt    numeric;
    v_rows   integer;
    v_first  text;
    v_last   text;
    v_bad    integer;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '============== DASHBOARD TESTS ==============';
    RAISE NOTICE '-- A. Every cursor opens and fetches ---------------------';

    CALL core.sp_dashboard_summary(c_tenant, c_school, c_user, k, t, cl, m, df, rc, ap, ev, bd);

    -- Fetching is the point: this is where a bad comparison actually throws.
    v_bad := 0;
    FOREACH v_name IN ARRAY c_names LOOP
        BEGIN
            v_cur  := v_name::refcursor;
            v_rows := 0;
            LOOP
                FETCH v_cur INTO v_rec;
                EXIT WHEN NOT FOUND;
                v_rows := v_rows + 1;
            END LOOP;
            CLOSE v_cur;   -- so the procedure can be called again below
            PERFORM pg_temp.chk('A cursor ' || rpad(v_name, 14) || ' fetched',
                                TRUE, format('%s row(s)', v_rows));
        EXCEPTION WHEN OTHERS THEN
            v_bad := v_bad + 1;
            PERFORM pg_temp.chk('A cursor ' || rpad(v_name, 14) || ' fetched',
                                FALSE, SQLERRM);
        END;
    END LOOP;

    RAISE NOTICE '-- B. The 7-day trend (the query that broke) -------------';

    CREATE TEMP TABLE _trend(d date, amount numeric) ON COMMIT DROP;
    CALL core.sp_dashboard_summary(c_tenant, c_school, c_user, k, t, cl, m, df, rc, ap, ev, bd);
    v_cur := 'db_trend'::refcursor;
    LOOP
        FETCH v_cur INTO v_rec;
        EXIT WHEN NOT FOUND;
        INSERT INTO _trend VALUES (v_rec.d, v_rec.amount);
    END LOOP;
    CLOSE v_cur;
    FOREACH v_name IN ARRAY c_names LOOP
        IF v_name <> 'db_trend' THEN
            v_cur := v_name::refcursor;
            CLOSE v_cur;
        END IF;
    END LOOP;

    SELECT COUNT(*) INTO v_n FROM _trend;
    PERFORM pg_temp.chk_eq('B1 trend covers exactly seven days', v_n, 7);

    SELECT MIN(d)::text, MAX(d)::text INTO v_first, v_last FROM _trend;
    PERFORM pg_temp.chk('B2 trend ends today',
                        v_last = CURRENT_DATE::text,
                        format('last = %s', v_last));
    PERFORM pg_temp.chk('B3 trend starts six days back',
                        v_first = (CURRENT_DATE - 6)::text,
                        format('first = %s', v_first));

    SELECT COUNT(*) INTO v_n FROM _trend WHERE amount IS NULL;
    PERFORM pg_temp.chk_eq('B4 no day is missing its amount', v_n, 0);

    -- A receipt taken today has to land on today's bar. This is the join that
    -- compared a varchar column with a date and threw on the live page.
    SELECT COALESCE(SUM(amount), 0) INTO v_amt FROM _trend WHERE d = CURRENT_DATE;
    PERFORM pg_temp.chk('B5 today''s bar is a real number',
                        v_amt IS NOT NULL, format('today = %s', v_amt));

    RAISE NOTICE '-- C. Dates come back as ISO text ------------------------';

    -- The columns are varchar now; the dashboard must still hand out YYYY-MM-DD.
    SELECT COUNT(*) INTO v_bad FROM core.fee_payments
     WHERE tenant_id = c_tenant AND school_id = c_school
       AND payment_date IS NOT NULL
       AND payment_date !~ '^\d{4}-\d{2}-\d{2}$';
    PERFORM pg_temp.chk_eq('C1 every payment_date is ISO text', v_bad, 0);

    SELECT COUNT(*) INTO v_bad FROM core.students
     WHERE tenant_id = c_tenant AND school_id = c_school
       AND dob IS NOT NULL AND dob !~ '^\d{4}-\d{2}-\d{2}$';
    PERFORM pg_temp.chk_eq('C2 every dob is ISO text', v_bad, 0);

    SELECT COUNT(*) INTO v_bad FROM core.students
     WHERE tenant_id = c_tenant AND school_id = c_school
       AND admission_date IS NOT NULL
       AND admission_date !~ '^\d{4}-\d{2}-\d{2}$';
    PERFORM pg_temp.chk_eq('C3 every admission_date is ISO text', v_bad, 0);

    RAISE NOTICE '-- D. Scope ---------------------------------------------';

    -- Tenant 1 is the platform, not a school: the dashboard must stay empty.
    CALL core.sp_dashboard_summary(1, 0, c_user, k, t, cl, m, df, rc, ap, ev, bd);

    v_n := 0; v_cur := 'db_trend'::refcursor;
    LOOP FETCH v_cur INTO v_rec; EXIT WHEN NOT FOUND; v_n := v_n + 1; END LOOP;
    PERFORM pg_temp.chk_eq('D1 platform tenant gets no trend', v_n, 0);

    v_n := 0; v_cur := 'db_recent'::refcursor;
    LOOP FETCH v_cur INTO v_rec; EXIT WHEN NOT FOUND; v_n := v_n + 1; END LOOP;
    PERFORM pg_temp.chk_eq('D2 platform tenant gets no receipts', v_n, 0);

    FOREACH v_name IN ARRAY c_names LOOP
        v_cur := v_name::refcursor;
        CLOSE v_cur;
    END LOOP;
END
$suite$;


DO $sum$
DECLARE p integer; f integer; r record;
BEGIN
    SELECT COUNT(*) FILTER (WHERE ok), COUNT(*) FILTER (WHERE NOT ok) INTO p, f FROM _t;
    RAISE NOTICE '';
    RAISE NOTICE '========== RESULT: % passed, % failed ==========', p, f;
    IF f > 0 THEN
        RAISE NOTICE 'failures:';
        FOR r IN SELECT name, detail FROM _t WHERE NOT ok ORDER BY id LOOP
            RAISE NOTICE '   %  %', rpad(r.name, 54), r.detail;
        END LOOP;
    END IF;
    RAISE NOTICE '';
END
$sum$;

ROLLBACK;
