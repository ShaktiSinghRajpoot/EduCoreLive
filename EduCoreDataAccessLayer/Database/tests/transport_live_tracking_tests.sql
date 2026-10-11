-- ============================================================================
-- Transport: live bus tracking test suite (transport_live_tracking.sql).
--
-- The driver's phone posts GPS points for a trip; staff watch the live map and
-- trip history; parents open a share link with no login. The rules worth
-- testing are the ones that keep a position honest (only the bus's own driver,
-- only while the trip runs, only sane values) and the ones that keep it private
-- (one school, one route, nothing after a link is revoked).
--
-- Runs inside ONE transaction and ROLLS BACK.
--
--     psql ... -f transport_live_tracking_tests.sql
--
-- Fixture: tenant 24 / school 34 / admin user 39. Driver = staff 21 (user 43),
-- another member of staff = staff 23 (user 45). Cross-school = 23 / 33 / user 38.
-- now() is frozen for the whole transaction, so "time passing" is simulated by
-- moving a trip's timestamps back, and point times are given explicitly.
--
-- COVERS
--   A. My Bus: who is a driver
--   B. Start trip: only the assigned driver, one running trip per vehicle
--   C. Points: driver only, ranges, accuracy, future / old time, min interval
--   D. Live list: running trips of this school only
--   E. Stale trips: closed after 30 minutes; a new start closes a stale one
--   F. End trip
--   G. Parent share link: create / regenerate / revoke, public read
--   H. History and points
--   I. 30-day purge
--   J. Purge coverage and tenant isolation
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

-- ── Small wrappers over the procedures (each raises when the proc refuses) ──
CREATE OR REPLACE FUNCTION pg_temp.trip_start(p_t int, p_s int, p_u int, p_v int)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'ts'; r record;
BEGIN
    CALL core.sp_transport_trip_manage('StartTrip', p_t, p_s, p_u, p_v, NULL,
         NULL, NULL, NULL, NULL, NULL, NULL, c);
    FETCH c INTO r; CLOSE c;
    RETURN r.trip_id;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.trip_point(p_t int, p_s int, p_u int, p_trip int,
    p_lat numeric, p_lng numeric, p_acc numeric, p_at timestamptz,
    p_speed numeric DEFAULT NULL, p_heading numeric DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'tp'; r record;
BEGIN
    CALL core.sp_transport_trip_manage('AddPoint', p_t, p_s, p_u, NULL, p_trip,
         p_lat, p_lng, p_acc, p_speed, p_heading, p_at, c);
    FETCH c INTO r; CLOSE c;
    RETURN r.accepted;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.trip_end(p_t int, p_s int, p_u int, p_trip int)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'te'; r record;
BEGIN
    CALL core.sp_transport_trip_manage('EndTrip', p_t, p_s, p_u, NULL, p_trip,
         NULL, NULL, NULL, NULL, NULL, NULL, c);
    FETCH c INTO r; CLOSE c;
    RETURN r.message;
END $$;

-- Every row of a driver read, as jsonb.
CREATE OR REPLACE FUNCTION pg_temp.my_bus(p_t int, p_s int, p_u int)
RETURNS SETOF jsonb LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'mb'; r record;
BEGIN
    CALL core.sp_transport_trip_manage('MyBus', p_t, p_s, p_u, NULL, NULL,
         NULL, NULL, NULL, NULL, NULL, NULL, c);
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; RETURN NEXT to_jsonb(r); END LOOP;
    CLOSE c;
END $$;

-- Every row of a staff read, as jsonb.
CREATE OR REPLACE FUNCTION pg_temp.track(p_op text, p_t int, p_s int, p_u int,
    p_vehicle int DEFAULT NULL, p_trip int DEFAULT NULL, p_route int DEFAULT NULL,
    p_from text DEFAULT NULL, p_to text DEFAULT NULL, p_hash text DEFAULT NULL)
RETURNS SETOF jsonb LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'tk'; r record;
BEGIN
    CALL core.sp_transport_tracking_manage(p_op, p_t, p_s, p_u, p_vehicle, p_trip, p_route,
         p_from, p_to, p_hash, c);
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; RETURN NEXT to_jsonb(r); END LOOP;
    CLOSE c;
END $$;

-- Every row of the public (parent) read, as jsonb.
CREATE OR REPLACE FUNCTION pg_temp.pub(p_hash text)
RETURNS SETOF jsonb LANGUAGE plpgsql AS $$
DECLARE c refcursor := 'pb'; r record;
BEGIN
    CALL core.sp_transport_track_public(p_hash, c);
    LOOP FETCH c INTO r; EXIT WHEN NOT FOUND; RETURN NEXT to_jsonb(r); END LOOP;
    CLOSE c;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.h(p_token text)
RETURNS text LANGUAGE sql AS $$ SELECT encode(sha256(convert_to(p_token, 'UTF8')), 'hex') $$;


DO $suite$
DECLARE
    c_tenant   CONSTANT integer := 24;
    c_school   CONSTANT integer := 34;
    c_admin    CONSTANT integer := 39;
    c_drv_user CONSTANT integer := 43;   -- staff 21
    c_drv2_usr CONSTANT integer := 45;   -- staff 23
    c_tenant_b CONSTANT integer := 23;
    c_school_b CONSTANT integer := 33;
    c_user_b   CONSTANT integer := 38;

    v_drv   integer;
    v_drv2  integer;
    v_r1    integer;
    v_r2    integer;
    v_v1    integer;
    v_v2    integer;
    v_v3    integer;
    t1      integer;
    t3      integer;
    t4      integer;
    t5      integer;
    t6      integer;
    v_old   integer;
    v_tmp   integer;
    v_ok    boolean;
    v_n     integer;
    v_txt   text;
    v_j     jsonb;
    v_base  timestamptz := now() - interval '50 seconds';
    c       refcursor;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '========= TRANSPORT LIVE TRACKING TESTS =========';

    SELECT staff_id INTO v_drv  FROM core.staff WHERE user_id = c_drv_user AND tenant_id = c_tenant AND school_id = c_school;
    SELECT staff_id INTO v_drv2 FROM core.staff WHERE user_id = c_drv2_usr AND tenant_id = c_tenant AND school_id = c_school;
    IF v_drv IS NULL OR v_drv2 IS NULL THEN
        RAISE EXCEPTION 'Fixture missing: users % and % must be staff of school %.', c_drv_user, c_drv2_usr, c_school;
    END IF;
    -- Both must be working staff for the driver checks to mean anything.
    UPDATE core.staff SET status = 'Active', is_deleted = FALSE WHERE staff_id IN (v_drv, v_drv2);

    c := 'f1';
    CALL core.sp_transport_route_manage('SaveRoute', c_tenant, c_school, c_admin,
         NULL, 'ZZ GPS Route One', NULL,
         jsonb_build_array(jsonb_build_object('stopId', 0, 'stopName', 'ZZ GPS Stop', 'monthlyFare', 500, 'displayOrder', 1)), c);
    CLOSE c;
    c := 'f2';
    CALL core.sp_transport_route_manage('SaveRoute', c_tenant, c_school, c_admin,
         NULL, 'ZZ GPS Route Two', NULL,
         jsonb_build_array(jsonb_build_object('stopId', 0, 'stopName', 'ZZ GPS Stop 2', 'monthlyFare', 600, 'displayOrder', 1)), c);
    CLOSE c;
    SELECT route_id INTO v_r1 FROM core.transport_routes WHERE tenant_id = c_tenant AND school_id = c_school AND route_name = 'ZZ GPS Route One';
    SELECT route_id INTO v_r2 FROM core.transport_routes WHERE tenant_id = c_tenant AND school_id = c_school AND route_name = 'ZZ GPS Route Two';

    c := 'f3'; CALL core.sp_transport_vehicle_manage('SaveVehicle', c_tenant, c_school, c_admin, NULL, 'ZZ-GPS-01', 30, NULL, NULL, v_r1, v_drv,  c); CLOSE c;
    c := 'f4'; CALL core.sp_transport_vehicle_manage('SaveVehicle', c_tenant, c_school, c_admin, NULL, 'ZZ-GPS-02', 30, NULL, NULL, v_r2, NULL,   c); CLOSE c;
    c := 'f5'; CALL core.sp_transport_vehicle_manage('SaveVehicle', c_tenant, c_school, c_admin, NULL, 'ZZ-GPS-03', 30, NULL, NULL, v_r2, v_drv2, c); CLOSE c;
    SELECT vehicle_id INTO v_v1 FROM core.transport_vehicles WHERE tenant_id = c_tenant AND school_id = c_school AND vehicle_no = 'ZZ-GPS-01';
    SELECT vehicle_id INTO v_v2 FROM core.transport_vehicles WHERE tenant_id = c_tenant AND school_id = c_school AND vehicle_no = 'ZZ-GPS-02';
    SELECT vehicle_id INTO v_v3 FROM core.transport_vehicles WHERE tenant_id = c_tenant AND school_id = c_school AND vehicle_no = 'ZZ-GPS-03';
    IF v_r1 IS NULL OR v_r2 IS NULL OR v_v1 IS NULL OR v_v2 IS NULL OR v_v3 IS NULL THEN
        RAISE EXCEPTION 'Fixture setup failed (routes % %, vehicles % % %).', v_r1, v_r2, v_v1, v_v2, v_v3;
    END IF;
    RAISE NOTICE 'fixture: driver staff %  other staff %  routes % %  vehicles % % %', v_drv, v_drv2, v_r1, v_r2, v_v1, v_v2, v_v3;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- A. My Bus -------------------------------------------';

    SELECT COUNT(*) INTO v_n FROM pg_temp.my_bus(c_tenant, c_school, c_drv_user) j
     WHERE (j->>'vehicle_id')::int IN (v_v1, v_v2, v_v3);
    SELECT j->>'vehicle_no' INTO v_txt FROM pg_temp.my_bus(c_tenant, c_school, c_drv_user) j
     WHERE (j->>'vehicle_id')::int IN (v_v1, v_v2, v_v3) LIMIT 1;
    PERFORM pg_temp.chk('A1 the driver sees only the bus they drive', v_n = 1 AND v_txt = 'ZZ-GPS-01',
                        format('%s row(s), %s', v_n, v_txt));

    SELECT COUNT(*) INTO v_n FROM pg_temp.my_bus(c_tenant, c_school, c_drv2_usr) j
     WHERE (j->>'vehicle_id')::int = v_v3;
    PERFORM pg_temp.chk_eq('A2 another driver sees their own bus', v_n, 1);

    SELECT COUNT(*) INTO v_n FROM pg_temp.my_bus(c_tenant, c_school, c_admin);
    PERFORM pg_temp.chk_eq('A3 a user who is not staff drives no bus', v_n, 0);

    SELECT COUNT(*) INTO v_n FROM pg_temp.my_bus(c_tenant_b, c_school_b, c_drv_user);
    PERFORM pg_temp.chk_eq('A4 the driver in another school''s scope drives nothing', v_n, 0);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- B. Start trip ---------------------------------------';

    BEGIN
        PERFORM pg_temp.trip_start(c_tenant, c_school, c_drv2_usr, v_v1);
        PERFORM pg_temp.chk('B1 another member of staff cannot start the bus', FALSE, 'trip started');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('B1 another member of staff cannot start the bus', TRUE, SQLERRM);
    END;

    BEGIN
        PERFORM pg_temp.trip_start(c_tenant, c_school, c_admin, v_v1);
        PERFORM pg_temp.chk('B2 the school admin cannot start a trip for the driver', FALSE, 'trip started');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('B2 the school admin cannot start a trip for the driver', TRUE, SQLERRM);
    END;

    BEGIN
        PERFORM pg_temp.trip_start(c_tenant_b, c_school_b, c_user_b, v_v1);
        PERFORM pg_temp.chk('B3 another school cannot start our bus', FALSE, 'trip started');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('B3 another school cannot start our bus', TRUE, SQLERRM);
    END;

    BEGIN
        PERFORM pg_temp.trip_start(c_tenant_b, c_school_b, c_drv_user, v_v1);
        PERFORM pg_temp.chk('B4 the driver under another school''s scope is refused', FALSE, 'trip started');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('B4 the driver under another school''s scope is refused', TRUE, SQLERRM);
    END;

    BEGIN
        PERFORM pg_temp.trip_start(1, 0, c_drv_user, v_v1);
        PERFORM pg_temp.chk('B5 platform scope is refused', FALSE, 'trip started');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('B5 platform scope is refused', TRUE, SQLERRM);
    END;

    -- An inactive driver (left the school) cannot start.
    BEGIN
        UPDATE core.staff SET status = 'Inactive' WHERE staff_id = v_drv;
        BEGIN
            PERFORM pg_temp.trip_start(c_tenant, c_school, c_drv_user, v_v1);
            v_ok := TRUE;
        EXCEPTION WHEN OTHERS THEN
            v_ok := FALSE;
        END;
        RAISE EXCEPTION '__undo__';
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('B6 an inactive member of staff cannot start', SQLERRM = '__undo__' AND NOT v_ok, CASE WHEN SQLERRM = '__undo__' THEN '' ELSE SQLERRM END);
    END;

    -- A switched-off bus cannot start.
    BEGIN
        UPDATE core.transport_vehicles SET is_active = FALSE WHERE vehicle_id = v_v1;
        BEGIN
            PERFORM pg_temp.trip_start(c_tenant, c_school, c_drv_user, v_v1);
            v_ok := TRUE;
        EXCEPTION WHEN OTHERS THEN
            v_ok := FALSE;
        END;
        RAISE EXCEPTION '__undo__';
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('B7 a switched-off bus cannot start a trip', SQLERRM = '__undo__' AND NOT v_ok, CASE WHEN SQLERRM = '__undo__' THEN '' ELSE SQLERRM END);
    END;

    t1 := pg_temp.trip_start(c_tenant, c_school, c_drv_user, v_v1);
    SELECT COUNT(*) INTO v_n FROM core.transport_trips
     WHERE trip_id = t1 AND tenant_id = c_tenant AND school_id = c_school AND vehicle_id = v_v1
       AND ended_at IS NULL AND route_id = v_r1 AND vehicle_no = 'ZZ-GPS-01'
       AND route_name = 'ZZ GPS Route One' AND driver_staff_id = v_drv;
    PERFORM pg_temp.chk_eq('B8 the driver starts a trip (bus, route, driver kept)', v_n, 1);

    v_tmp := pg_temp.trip_start(c_tenant, c_school, c_drv_user, v_v1);
    SELECT COUNT(*) INTO v_n FROM core.transport_trips WHERE vehicle_id = v_v1 AND ended_at IS NULL;
    PERFORM pg_temp.chk('B9 starting again resumes the running trip (one per bus)',
                        v_tmp = t1 AND v_n = 1, format('second start -> %s, running=%s', v_tmp, v_n));

    BEGIN
        INSERT INTO core.transport_trips (tenant_id, school_id, vehicle_id) VALUES (c_tenant, c_school, v_v1);
        PERFORM pg_temp.chk('B10 the index refuses a second running trip', FALSE, 'inserted');
    EXCEPTION WHEN unique_violation THEN
        PERFORM pg_temp.chk('B10 the index refuses a second running trip', TRUE, SQLERRM);
    END;

    SELECT (j->>'trip_id')::int INTO v_tmp FROM pg_temp.my_bus(c_tenant, c_school, c_drv_user) j
     WHERE (j->>'vehicle_id')::int = v_v1;
    PERFORM pg_temp.chk_eq('B11 My Bus shows the running trip', v_tmp, t1);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- C. Points -------------------------------------------';

    v_ok := pg_temp.trip_point(c_tenant, c_school, c_drv_user, t1, 26.912434, 75.787270, 12, v_base, 8.5, 90);
    SELECT COUNT(*) INTO v_n FROM core.transport_trips
     WHERE trip_id = t1 AND point_count = 1 AND last_lat = 26.912434 AND last_lng = 75.787270
       AND last_received_at IS NOT NULL AND last_speed_mps = 8.5 AND last_heading_deg = 90;
    PERFORM pg_temp.chk('C1 a good point is saved and becomes the latest', v_ok AND v_n = 1, format('accepted=%s', v_ok));

    BEGIN
        PERFORM pg_temp.trip_point(c_tenant, c_school, c_drv2_usr, t1, 26.9, 75.8, 10, v_base + interval '20 seconds');
        PERFORM pg_temp.chk('C2 another member of staff cannot post to the trip', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C2 another member of staff cannot post to the trip', TRUE, SQLERRM);
    END;

    BEGIN
        PERFORM pg_temp.trip_point(c_tenant_b, c_school_b, c_user_b, t1, 26.9, 75.8, 10, v_base + interval '20 seconds');
        PERFORM pg_temp.chk('C3 another school cannot post to the trip', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C3 another school cannot post to the trip', TRUE, SQLERRM);
    END;

    BEGIN
        PERFORM pg_temp.trip_point(c_tenant, c_school, c_drv_user, t1, 91, 75.8, 10, v_base + interval '20 seconds');
        PERFORM pg_temp.chk('C4 latitude above 90 refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C4 latitude above 90 refused', TRUE, SQLERRM);
    END;

    BEGIN
        PERFORM pg_temp.trip_point(c_tenant, c_school, c_drv_user, t1, 26.9, -180.5, 10, v_base + interval '20 seconds');
        PERFORM pg_temp.chk('C5 longitude below -180 refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C5 longitude below -180 refused', TRUE, SQLERRM);
    END;

    BEGIN
        PERFORM pg_temp.trip_point(c_tenant, c_school, c_drv_user, t1, 0, 0, 10, v_base + interval '20 seconds');
        PERFORM pg_temp.chk('C6 the 0,0 "no fix" position refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C6 the 0,0 "no fix" position refused', TRUE, SQLERRM);
    END;

    BEGIN
        PERFORM pg_temp.trip_point(c_tenant, c_school, c_drv_user, t1, NULL, 75.8, 10, v_base + interval '20 seconds');
        PERFORM pg_temp.chk('C7 a missing latitude refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C7 a missing latitude refused', TRUE, SQLERRM);
    END;

    BEGIN
        PERFORM pg_temp.trip_point(c_tenant, c_school, c_drv_user, t1, 26.9, 75.8, 5000, v_base + interval '20 seconds');
        PERFORM pg_temp.chk('C8 accuracy worse than 2 km refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C8 accuracy worse than 2 km refused', TRUE, SQLERRM);
    END;

    BEGIN
        PERFORM pg_temp.trip_point(c_tenant, c_school, c_drv_user, t1, 26.9, 75.8, -1, v_base + interval '20 seconds');
        PERFORM pg_temp.chk('C9 negative accuracy refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C9 negative accuracy refused', TRUE, SQLERRM);
    END;

    BEGIN
        PERFORM pg_temp.trip_point(c_tenant, c_school, c_drv_user, t1, 26.9, 75.8, 10, now() + interval '10 minutes');
        PERFORM pg_temp.chk('C10 a position from the future refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C10 a position from the future refused', TRUE, SQLERRM);
    END;

    BEGIN
        PERFORM pg_temp.trip_point(c_tenant, c_school, c_drv_user, t1, 26.9, 75.8, 10, now() - interval '2 hours');
        PERFORM pg_temp.chk('C11 a position older than the trip refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C11 a position older than the trip refused', TRUE, SQLERRM);
    END;

    v_ok := pg_temp.trip_point(c_tenant, c_school, c_drv_user, t1, 26.9126, 75.7875, 10, v_base + interval '3 seconds');
    SELECT point_count INTO v_n FROM core.transport_trips WHERE trip_id = t1;
    PERFORM pg_temp.chk('C12 a point 3 s after the last one is dropped, not an error',
                        v_ok = FALSE AND v_n = 1, format('accepted=%s points=%s', v_ok, v_n));

    v_ok := pg_temp.trip_point(c_tenant, c_school, c_drv_user, t1, 26.9126, 75.7875, 10, v_base - interval '5 seconds');
    SELECT point_count INTO v_n FROM core.transport_trips WHERE trip_id = t1;
    PERFORM pg_temp.chk('C13 an out-of-order (older) point is dropped',
                        v_ok = FALSE AND v_n = 1, format('accepted=%s points=%s', v_ok, v_n));

    v_ok := pg_temp.trip_point(c_tenant, c_school, c_drv_user, t1, 26.913000, 75.788000, 15, v_base + interval '10 seconds', -5, 400);
    SELECT COUNT(*) INTO v_n FROM core.transport_trips
     WHERE trip_id = t1 AND point_count = 2 AND last_lat = 26.913 AND last_lng = 75.788
       AND last_speed_mps IS NULL AND last_heading_deg IS NULL;
    PERFORM pg_temp.chk('C14 10 s later accepted; bad speed/heading stored empty', v_ok AND v_n = 1, format('accepted=%s', v_ok));

    SELECT COUNT(*) INTO v_n FROM core.transport_trip_points
     WHERE trip_id = t1 AND tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk_eq('C15 only the two accepted points are stored', v_n, 2);

    -- The bus is given to another driver mid-trip: the old driver stops posting.
    BEGIN
        UPDATE core.transport_vehicles SET driver_staff_id = v_drv2 WHERE vehicle_id = v_v1;
        BEGIN
            PERFORM pg_temp.trip_point(c_tenant, c_school, c_drv_user, t1, 26.914, 75.789, 10, v_base + interval '30 seconds');
            v_ok := TRUE;
        EXCEPTION WHEN OTHERS THEN
            v_ok := FALSE;
        END;
        RAISE EXCEPTION '__undo__';
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C16 a driver taken off the bus can no longer post', SQLERRM = '__undo__' AND NOT v_ok, CASE WHEN SQLERRM = '__undo__' THEN '' ELSE SQLERRM END);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- D. Live list ----------------------------------------';

    SELECT j INTO v_j FROM pg_temp.track('LiveList', c_tenant, c_school, c_admin) j WHERE (j->>'trip_id')::int = t1;
    PERFORM pg_temp.chk('D1 the running trip is on the live list with its position',
                        v_j IS NOT NULL AND (v_j->>'lat')::numeric = 26.913 AND (v_j->>'vehicle_no') = 'ZZ-GPS-01'
                        AND (v_j->>'route_name') = 'ZZ GPS Route One' AND (v_j->>'age_seconds') IS NOT NULL
                        AND (v_j->>'driver_name') IS NOT NULL,
                        COALESCE(v_j::text, 'missing'));

    SELECT COUNT(*) INTO v_n FROM pg_temp.track('LiveList', c_tenant_b, c_school_b, c_user_b) j
     WHERE (j->>'trip_id')::int = t1;
    PERFORM pg_temp.chk_eq('D2 another school''s live list does not show it', v_n, 0);

    SELECT COUNT(*) INTO v_n FROM pg_temp.track('LiveList', c_tenant, c_school, c_admin) j
     WHERE (j->>'vehicle_id')::int IN (v_v2, v_v3);
    PERFORM pg_temp.chk_eq('D3 buses with no running trip are not listed', v_n, 0);

    BEGIN
        PERFORM pg_temp.track('LiveList', 1, 0, c_admin);
        PERFORM pg_temp.chk('D4 platform scope cannot read the live list', FALSE, 'read');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('D4 platform scope cannot read the live list', TRUE, SQLERRM);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- E. Stale trips --------------------------------------';

    -- Nothing received for 31 minutes.
    UPDATE core.transport_trips
       SET started_at = now() - interval '45 minutes', last_received_at = now() - interval '31 minutes'
     WHERE trip_id = t1;
    SELECT COUNT(*) INTO v_n FROM pg_temp.track('LiveList', c_tenant, c_school, c_admin) j WHERE (j->>'trip_id')::int = t1;
    SELECT COUNT(*) INTO v_tmp FROM core.transport_trips
     WHERE trip_id = t1 AND end_reason = 'Stale' AND ended_at = now() - interval '31 minutes';
    PERFORM pg_temp.chk('E1 a trip silent for 30+ min is closed on the next read',
                        v_n = 0 AND v_tmp = 1, format('listed=%s closed-as-stale=%s', v_n, v_tmp));

    BEGIN
        PERFORM pg_temp.trip_point(c_tenant, c_school, c_drv_user, t1, 26.914, 75.789, 10, now());
        PERFORM pg_temp.chk('E2 a stale (closed) trip takes no more points', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('E2 a stale (closed) trip takes no more points', TRUE, SQLERRM);
    END;

    t3 := pg_temp.trip_start(c_tenant, c_school, c_drv_user, v_v1);
    PERFORM pg_temp.chk('E3 the driver can start a new trip after a stale one', t3 IS NOT NULL AND t3 <> t1,
                        format('new trip %s', t3));

    -- A trip that never sent a point and is 31 min old is closed by the next start.
    UPDATE core.transport_trips SET started_at = now() - interval '31 minutes' WHERE trip_id = t3;
    t4 := pg_temp.trip_start(c_tenant, c_school, c_drv_user, v_v1);
    SELECT COUNT(*) INTO v_n FROM core.transport_trips
     WHERE trip_id = t3 AND end_reason = 'Stale' AND ended_at = started_at;
    PERFORM pg_temp.chk('E4 starting a trip closes a stale one on the same bus',
                        t4 <> t3 AND v_n = 1, format('t3=%s t4=%s stale-closed=%s', t3, t4, v_n));

    -- A fresh trip is NOT closed: 29 minutes of silence is still a running trip.
    UPDATE core.transport_trips SET started_at = now() - interval '29 minutes' WHERE trip_id = t4;
    SELECT COUNT(*) INTO v_n FROM pg_temp.track('LiveList', c_tenant, c_school, c_admin) j WHERE (j->>'trip_id')::int = t4;
    PERFORM pg_temp.chk_eq('E5 a trip silent for 29 minutes is still running', v_n, 1);
    UPDATE core.transport_trips SET started_at = now() WHERE trip_id = t4;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- F. End trip -----------------------------------------';

    PERFORM pg_temp.trip_point(c_tenant, c_school, c_drv_user, t4, 26.92, 75.79, 9, v_base);
    PERFORM pg_temp.trip_point(c_tenant, c_school, c_drv_user, t4, 26.921, 75.791, 9, v_base + interval '15 seconds');
    PERFORM pg_temp.trip_point(c_tenant, c_school, c_drv_user, t4, 26.922, 75.792, 9, v_base + interval '30 seconds');

    BEGIN
        PERFORM pg_temp.trip_end(c_tenant, c_school, c_drv2_usr, t4);
        PERFORM pg_temp.chk('F1 another member of staff cannot end the trip', FALSE, 'ended');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('F1 another member of staff cannot end the trip', TRUE, SQLERRM);
    END;

    BEGIN
        PERFORM pg_temp.trip_end(c_tenant_b, c_school_b, c_user_b, t4);
        PERFORM pg_temp.chk('F2 another school cannot end the trip', FALSE, 'ended');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('F2 another school cannot end the trip', TRUE, SQLERRM);
    END;

    v_txt := pg_temp.trip_end(c_tenant, c_school, c_drv_user, t4);
    SELECT COUNT(*) INTO v_n FROM core.transport_trips WHERE trip_id = t4 AND ended_at IS NOT NULL AND end_reason = 'Driver';
    PERFORM pg_temp.chk('F3 the driver ends the trip', v_n = 1, v_txt);

    v_txt := pg_temp.trip_end(c_tenant, c_school, c_drv_user, t4);
    PERFORM pg_temp.chk('F4 ending twice is harmless', v_txt ILIKE '%already%', v_txt);

    BEGIN
        PERFORM pg_temp.trip_point(c_tenant, c_school, c_drv_user, t4, 26.93, 75.80, 9, v_base + interval '45 seconds');
        PERFORM pg_temp.chk('F5 an ended trip takes no more points', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('F5 an ended trip takes no more points', TRUE, SQLERRM);
    END;

    SELECT COUNT(*) INTO v_n FROM pg_temp.track('LiveList', c_tenant, c_school, c_admin) j WHERE (j->>'trip_id')::int = t4;
    PERFORM pg_temp.chk_eq('F6 an ended trip leaves the live list', v_n, 0);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- G. Parent share link --------------------------------';

    PERFORM pg_temp.track('ShareCreate', c_tenant, c_school, c_admin, NULL, NULL, v_r1, NULL, NULL, pg_temp.h('zz-token-one'));
    SELECT COUNT(*) INTO v_n FROM pg_temp.track('ShareList', c_tenant, c_school, c_admin) j WHERE (j->>'route_id')::int = v_r1;
    PERFORM pg_temp.chk_eq('G1 a parent link is created for the route', v_n, 1);

    SELECT COUNT(*) INTO v_n FROM core.transport_route_shares
     WHERE route_id = v_r1 AND token_hash = pg_temp.h('zz-token-one') AND token_hash <> 'zz-token-one';
    PERFORM pg_temp.chk_eq('G2 only the hash of the token is stored', v_n, 1);

    SELECT COUNT(*), MAX(j->>'route_name'), COUNT(j->>'trip_id') INTO v_n, v_txt, v_tmp
      FROM pg_temp.pub(pg_temp.h('zz-token-one')) j;
    PERFORM pg_temp.chk('G3 no trip running: the link is valid but shows no bus',
                        v_n = 1 AND v_txt = 'ZZ GPS Route One' AND v_tmp = 0,
                        format('rows=%s route=%s trips=%s', v_n, v_txt, v_tmp));

    t5 := pg_temp.trip_start(c_tenant, c_school, c_drv_user, v_v1);
    PERFORM pg_temp.trip_point(c_tenant, c_school, c_drv_user, t5, 26.95, 75.81, 8, v_base);
    t6 := pg_temp.trip_start(c_tenant, c_school, c_drv2_usr, v_v3);     -- route two
    PERFORM pg_temp.trip_point(c_tenant, c_school, c_drv2_usr, t6, 26.80, 75.70, 8, v_base);

    SELECT COUNT(*) INTO v_n FROM pg_temp.pub(pg_temp.h('zz-token-one')) j;
    SELECT j INTO v_j FROM pg_temp.pub(pg_temp.h('zz-token-one')) j LIMIT 1;
    PERFORM pg_temp.chk('G4 during a trip the link shows that route''s bus only',
                        v_n = 1 AND v_j->>'vehicle_no' = 'ZZ-GPS-01' AND (v_j->>'lat')::numeric = 26.95,
                        COALESCE(v_j::text, 'none'));

    SELECT string_agg(k, ',' ORDER BY k) INTO v_txt FROM jsonb_object_keys(v_j) k;
    PERFORM pg_temp.chk('G5 the public row carries no driver, phone or student data',
                        v_txt = 'age_seconds,last_point_at,lat,lng,route_name,trip_id,vehicle_no', v_txt);

    PERFORM pg_temp.track('ShareCreate', c_tenant, c_school, c_admin, NULL, NULL, v_r1, NULL, NULL, pg_temp.h('zz-token-two'));
    SELECT COUNT(*) INTO v_n FROM pg_temp.pub(pg_temp.h('zz-token-one')) j;
    SELECT COUNT(*) INTO v_tmp FROM pg_temp.pub(pg_temp.h('zz-token-two')) j;
    PERFORM pg_temp.chk('G6 regenerating stops the old link at once; the new one works',
                        v_n = 0 AND v_tmp = 1, format('old=%s new=%s', v_n, v_tmp));

    SELECT COUNT(*) INTO v_n FROM core.transport_route_shares WHERE route_id = v_r1 AND revoked_at IS NULL;
    PERFORM pg_temp.chk_eq('G7 one live link per route', v_n, 1);

    BEGIN
        PERFORM pg_temp.track('ShareRevoke', c_tenant_b, c_school_b, c_user_b, NULL, NULL, v_r1);
        PERFORM pg_temp.chk('G8 another school cannot revoke our link', FALSE, 'revoked');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('G8 another school cannot revoke our link', TRUE, SQLERRM);
    END;

    BEGIN
        PERFORM pg_temp.track('ShareCreate', c_tenant_b, c_school_b, c_user_b, NULL, NULL, v_r1, NULL, NULL, pg_temp.h('zz-token-evil'));
        PERFORM pg_temp.chk('G9 another school cannot create a link to our route', FALSE, 'created');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('G9 another school cannot create a link to our route', TRUE, SQLERRM);
    END;

    BEGIN
        PERFORM pg_temp.track('ShareCreate', c_tenant, c_school, c_admin, NULL, NULL, v_r1, NULL, NULL, 'not-a-hash');
        PERFORM pg_temp.chk('G10 a malformed token hash is refused', FALSE, 'created');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('G10 a malformed token hash is refused', TRUE, SQLERRM);
    END;

    SELECT COUNT(*) INTO v_n FROM pg_temp.pub(pg_temp.h('zz-unknown-token'));
    SELECT COUNT(*) INTO v_tmp FROM pg_temp.pub('''; DROP TABLE core.transport_trips; --');
    PERFORM pg_temp.chk('G11 an unknown or garbage token returns nothing',
                        v_n = 0 AND v_tmp = 0, format('unknown=%s garbage=%s', v_n, v_tmp));

    -- Transport switched off for the school: the link shows nothing.
    BEGIN
        INSERT INTO core.school_admission_workflow_settings (tenant_id, school_id, created_by, enable_transport)
        VALUES (c_tenant, c_school, c_admin, FALSE)
        ON CONFLICT (tenant_id, school_id) DO UPDATE SET enable_transport = FALSE;
        SELECT COUNT(*) INTO v_n FROM pg_temp.pub(pg_temp.h('zz-token-two'));
        RAISE EXCEPTION '__undo__';
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('G12 module switched off: the link shows nothing', SQLERRM = '__undo__' AND v_n = 0, CASE WHEN SQLERRM = '__undo__' THEN format('rows=%s', v_n) ELSE SQLERRM END);
    END;

    PERFORM pg_temp.track('ShareRevoke', c_tenant, c_school, c_admin, NULL, NULL, v_r1);
    SELECT COUNT(*) INTO v_n FROM pg_temp.pub(pg_temp.h('zz-token-two'));
    SELECT COUNT(*) INTO v_tmp FROM pg_temp.track('ShareList', c_tenant, c_school, c_admin) j WHERE (j->>'route_id')::int = v_r1;
    PERFORM pg_temp.chk('G13 revoking stops the link at once', v_n = 0 AND v_tmp = 0, format('public rows=%s listed=%s', v_n, v_tmp));

    BEGIN
        PERFORM pg_temp.track('ShareRevoke', c_tenant, c_school, c_admin, NULL, NULL, v_r1);
        PERFORM pg_temp.chk('G14 revoking a route with no link says so', FALSE, 'no error');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('G14 revoking a route with no link says so', TRUE, SQLERRM);
    END;

    -- A deleted route's link stops too.
    BEGIN
        PERFORM pg_temp.track('ShareCreate', c_tenant, c_school, c_admin, NULL, NULL, v_r2, NULL, NULL, pg_temp.h('zz-token-three'));
        UPDATE core.transport_routes SET is_deleted = TRUE WHERE route_id = v_r2;
        SELECT COUNT(*) INTO v_n FROM pg_temp.pub(pg_temp.h('zz-token-three'));
        RAISE EXCEPTION '__undo__';
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('G15 a deleted route''s link shows nothing', SQLERRM = '__undo__' AND v_n = 0, CASE WHEN SQLERRM = '__undo__' THEN format('rows=%s', v_n) ELSE SQLERRM END);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- H. History ------------------------------------------';

    SELECT COUNT(*) INTO v_n FROM pg_temp.track('TripHistory', c_tenant, c_school, c_admin) j
     WHERE (j->>'trip_id')::int IN (t1, t3, t4, t5, t6);
    PERFORM pg_temp.chk_eq('H1 history lists every trip of the last 7 days', v_n, 5);

    SELECT j INTO v_j FROM pg_temp.track('TripHistory', c_tenant, c_school, c_admin) j WHERE (j->>'trip_id')::int = t4;
    PERFORM pg_temp.chk('H2 a trip keeps start, end, driver, bus, route and point count',
                        v_j->>'started_at' IS NOT NULL AND v_j->>'ended_at' IS NOT NULL
                        AND v_j->>'end_reason' = 'Driver' AND v_j->>'vehicle_no' = 'ZZ-GPS-01'
                        AND v_j->>'route_name' = 'ZZ GPS Route One' AND v_j->>'driver_name' IS NOT NULL
                        AND (v_j->>'point_count')::int = 3 AND (v_j->>'is_running')::boolean = FALSE,
                        COALESCE(v_j::text, 'missing'));

    SELECT COUNT(*), COUNT(*) FILTER (WHERE (j->>'vehicle_id')::int <> v_v3) INTO v_n, v_tmp
      FROM pg_temp.track('TripHistory', c_tenant, c_school, c_admin, v_v3) j;
    PERFORM pg_temp.chk('H3 the vehicle filter shows only that bus', v_n >= 1 AND v_tmp = 0,
                        format('rows=%s other buses=%s', v_n, v_tmp));

    SELECT COUNT(*) INTO v_n FROM pg_temp.track('TripHistory', c_tenant, c_school, c_admin, NULL, NULL, NULL,
                                               to_char(current_date - 10, 'YYYY-MM-DD'), to_char(current_date - 8, 'YYYY-MM-DD')) j
     WHERE (j->>'trip_id')::int IN (t1, t3, t4, t5, t6);
    PERFORM pg_temp.chk_eq('H4 the date filter excludes trips outside it', v_n, 0);

    SELECT COUNT(*) INTO v_n FROM pg_temp.track('TripPoints', c_tenant, c_school, c_admin, NULL, t4) j;
    SELECT string_agg(j->>'lat', ',' ORDER BY ord) INTO v_txt
      FROM pg_temp.track('TripPoints', c_tenant, c_school, c_admin, NULL, t4) WITH ORDINALITY AS x(j, ord);
    PERFORM pg_temp.chk('H5 the path comes back in time order',
                        v_n = 3 AND v_txt = '26.920000,26.921000,26.922000', format('%s: %s', v_n, v_txt));

    SELECT COUNT(*) INTO v_n FROM pg_temp.track('TripPoints', c_tenant_b, c_school_b, c_user_b, NULL, t4) j;
    PERFORM pg_temp.chk_eq('H6 another school cannot read the path', v_n, 0);

    SELECT COUNT(*) INTO v_n FROM pg_temp.track('TripHistory', c_tenant_b, c_school_b, c_user_b) j
     WHERE (j->>'trip_id')::int IN (t1, t3, t4, t5, t6);
    PERFORM pg_temp.chk_eq('H7 another school''s history shows none of ours', v_n, 0);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- I. 30-day purge -------------------------------------';

    INSERT INTO core.transport_trips (tenant_id, school_id, vehicle_id, vehicle_no, started_at, ended_at, end_reason)
    VALUES (c_tenant, c_school, v_v2, 'ZZ-GPS-02', now() - interval '31 days', now() - interval '31 days' + interval '1 hour', 'Driver')
    RETURNING trip_id INTO v_old;
    INSERT INTO core.transport_trip_points (tenant_id, school_id, trip_id, lat, lng, accuracy_m, recorded_at)
    VALUES (c_tenant, c_school, v_old, 26.9, 75.8, 10, now() - interval '31 days');
    -- An old point on a recent trip goes too; the recent points stay.
    INSERT INTO core.transport_trip_points (tenant_id, school_id, trip_id, lat, lng, accuracy_m, recorded_at)
    VALUES (c_tenant, c_school, t4, 26.9, 75.8, 10, now() - interval '31 days');

    v_tmp := pg_temp.trip_start(c_tenant, c_school, c_drv_user, v_v1);   -- t5 is running: resumes, purges
    SELECT COUNT(*) INTO v_n FROM core.transport_trips WHERE trip_id = v_old;
    PERFORM pg_temp.chk_eq('I1 a trip older than 30 days is deleted on the next start', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM core.transport_trip_points WHERE recorded_at < now() - interval '30 days';
    PERFORM pg_temp.chk_eq('I2 no point older than 30 days survives', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM core.transport_trip_points WHERE trip_id = t4;
    PERFORM pg_temp.chk_eq('I3 recent points are kept', v_n, 3);
    PERFORM pg_temp.chk_eq('I4 the start still resumed the running trip', v_tmp, t5);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- J. Purge coverage and isolation ---------------------';

    SELECT COUNT(*) INTO v_n
      FROM unnest(ARRAY['transport_trip_points', 'transport_trips', 'transport_route_shares']) tbl
     WHERE position(format('DELETE FROM core.%s ', tbl)
                    IN regexp_replace(pg_get_functiondef('core.sp_school_purge'::regproc), '\s+', ' ', 'g')) = 0;
    PERFORM pg_temp.chk_eq('J1 the school purge deletes all three tracking tables', v_n, 0);

    SELECT position('DELETE FROM core.transport_trip_points ' IN d) < position('DELETE FROM core.transport_trips ' IN d)
       AND position('DELETE FROM core.transport_trips ' IN d) < position('DELETE FROM core.transport_vehicles ' IN d)
       AND position('DELETE FROM core.transport_route_shares ' IN d) < position('DELETE FROM core.transport_routes ' IN d)
      INTO v_ok
      FROM (SELECT regexp_replace(pg_get_functiondef('core.sp_school_purge'::regproc), '\s+', ' ', 'g') AS d) x;
    PERFORM pg_temp.chk('J2 the purge deletes them before what they reference', v_ok, '');

    SELECT COUNT(*) INTO v_n FROM core.transport_trips t
     WHERE t.trip_id IN (t1, t3, t4, t5, t6) AND (t.tenant_id <> c_tenant OR t.school_id <> c_school);
    SELECT COUNT(*) INTO v_tmp FROM core.transport_trip_points p
      JOIN core.transport_trips t ON t.trip_id = p.trip_id
     WHERE p.tenant_id <> t.tenant_id OR p.school_id <> t.school_id;
    PERFORM pg_temp.chk('J3 trips and points carry their own school only',
                        v_n = 0 AND v_tmp = 0, format('trips=%s points=%s', v_n, v_tmp));
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
