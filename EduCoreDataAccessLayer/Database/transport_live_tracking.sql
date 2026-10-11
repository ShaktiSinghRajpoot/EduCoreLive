-- ============================================================================
-- Transport: live bus tracking
--
-- WHERE THE POSITION COMES FROM
-- The driver's own phone. A driver is a staff row (core.staff) with a login
-- (staff.user_id) who is the assigned driver of a vehicle
-- (core.transport_vehicles.driver_staff_id). The "My Bus" page in the browser
-- starts a trip and posts the phone's GPS position about every 15 seconds.
-- No other permission is needed: being the vehicle's driver IS the permission,
-- and every write below checks it again.
--
-- TABLES
--   core.transport_trips        one row per trip. The latest point is copied onto
--                               the trip row (last_lat, last_lng, ...) so the live
--                               map reads one row per running bus, never a
--                               "latest point per trip" scan over the points.
--   core.transport_trip_points  every accepted GPS point of a trip.
--   core.transport_route_shares parent share links, one live link per route. Only
--                               the sha256 of the token is stored (hex); the raw
--                               token is shown once and can be regenerated.
--
-- RULES
--   * One running trip per vehicle (unique partial index). Starting again while
--     a fresh trip runs resumes it; a stale trip is closed first.
--   * A trip with no point for 30 minutes is STALE and is closed (end_reason
--     'Stale') by fn_transport_close_stale_trips, which every read and write
--     below calls first. Staleness is measured on the SERVER's receive time,
--     so a phone with a wrong clock cannot keep a trip alive or kill it.
--   * Points: lat/lng in range and not (0,0), accuracy 0..2000 m, no timestamp
--     more than 2 minutes in the future or before the trip started, and a point
--     less than 5 s after the previous one is DROPPED (not an error).
--   * 30-DAY HISTORY: StartTrip deletes points older than 30 days and ended trips
--     that started more than 30 days ago, for every school. It is one indexed
--     DELETE, cheap enough to run at the start of each trip, so no scheduler
--     or cron job is needed. Nothing older than 30 days is ever read.
--
-- PROCS
--   core.fn_transport_close_stale_trips(tenant, school)
--   core.sp_transport_trip_manage      driver: MyBus, IsDriver, StartTrip, EndTrip, AddPoint
--   core.sp_transport_tracking_manage  staff : LiveList, TripHistory, TripPoints,
--                                              ShareList, ShareCreate, ShareRevoke
--   core.sp_transport_track_public     parent page: token hash -> that route's bus
--
-- Timestamps are timestamptz; text sent to the app is formatted in the session
-- time zone, which is the school's (school_timezone.sql sets Asia/Kolkata).
--
-- Target DB: PostgreSQL (educore). Safe to re-run. No inner BEGIN/COMMIT.
-- school_purge.sql deletes these three tables; apply it after this script.
-- ============================================================================

-- ── Tables ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS core.transport_trips
(
    trip_id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id        integer NOT NULL,
    school_id        integer NOT NULL,
    vehicle_id       integer NOT NULL REFERENCES core.transport_vehicles(vehicle_id) ON DELETE CASCADE,
    route_id         integer REFERENCES core.transport_routes(route_id) ON DELETE SET NULL,
    driver_staff_id  integer REFERENCES core.staff(staff_id) ON DELETE SET NULL,
    -- Snapshots, so history still reads right after a bus or route is renamed.
    vehicle_no       varchar(40),
    route_name       varchar(80),
    driver_name      varchar(150),
    started_by       integer,
    started_at       timestamptz NOT NULL DEFAULT now(),
    ended_at         timestamptz,
    end_reason       varchar(20),             -- Driver | Stale
    -- The latest accepted point (recorded_at = phone time, received_at = server time).
    last_lat         numeric(9,6),
    last_lng         numeric(9,6),
    last_accuracy_m  numeric(8,1),
    last_speed_mps   numeric(6,2),
    last_heading_deg numeric(5,1),
    last_recorded_at timestamptz,
    last_received_at timestamptz,
    point_count      integer NOT NULL DEFAULT 0,
    CONSTRAINT chk_transport_trips_scope CHECK ((tenant_id > 1) AND (school_id > 0))
);

-- One running trip per vehicle.
CREATE UNIQUE INDEX IF NOT EXISTS ux_transport_trips_running
    ON core.transport_trips(vehicle_id) WHERE ended_at IS NULL;
-- Live map: the running trips of one school.
CREATE INDEX IF NOT EXISTS ix_transport_trips_school_running
    ON core.transport_trips(tenant_id, school_id) WHERE ended_at IS NULL;
-- History list, newest first, and the 30-day purge of old trips.
CREATE INDEX IF NOT EXISTS ix_transport_trips_school_started
    ON core.transport_trips(tenant_id, school_id, started_at DESC);
CREATE INDEX IF NOT EXISTS ix_transport_trips_started
    ON core.transport_trips(started_at);

CREATE TABLE IF NOT EXISTS core.transport_trip_points
(
    point_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id    integer NOT NULL,
    school_id    integer NOT NULL,
    trip_id      integer NOT NULL REFERENCES core.transport_trips(trip_id) ON DELETE CASCADE,
    lat          numeric(9,6) NOT NULL,
    lng          numeric(9,6) NOT NULL,
    accuracy_m   numeric(8,1),
    speed_mps    numeric(6,2),
    heading_deg  numeric(5,1),
    recorded_at  timestamptz NOT NULL,
    received_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT chk_transport_trip_points_scope CHECK ((tenant_id > 1) AND (school_id > 0))
);
-- A trip's path in order (history playback).
CREATE INDEX IF NOT EXISTS ix_transport_trip_points_trip
    ON core.transport_trip_points(trip_id, recorded_at);
-- The 30-day purge.
CREATE INDEX IF NOT EXISTS ix_transport_trip_points_recorded
    ON core.transport_trip_points(recorded_at);

CREATE TABLE IF NOT EXISTS core.transport_route_shares
(
    share_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   integer NOT NULL,
    school_id   integer NOT NULL,
    route_id    integer NOT NULL REFERENCES core.transport_routes(route_id) ON DELETE CASCADE,
    token_hash  char(64) NOT NULL,            -- lowercase hex sha256 of the raw token
    created_by  integer,
    created_at  timestamptz NOT NULL DEFAULT now(),
    revoked_by  integer,
    revoked_at  timestamptz,
    CONSTRAINT chk_transport_route_shares_scope CHECK ((tenant_id > 1) AND (school_id > 0))
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_transport_route_shares_token
    ON core.transport_route_shares(token_hash);
-- One live link per route.
CREATE UNIQUE INDEX IF NOT EXISTS ux_transport_route_shares_live
    ON core.transport_route_shares(route_id) WHERE revoked_at IS NULL;


-- ── Stale trips ─────────────────────────────────────────────────────────────
-- A running trip with nothing received for 30 minutes is over: the phone was
-- switched off, the page was closed, or the driver forgot End Trip. It ends at
-- its last point (or its start, when it never sent one).
CREATE OR REPLACE FUNCTION core.fn_transport_close_stale_trips(p_tenant_id integer, p_school_id integer)
RETURNS integer
LANGUAGE plpgsql
AS $function$
DECLARE
    v_n integer;
BEGIN
    UPDATE core.transport_trips
       SET ended_at   = COALESCE(last_received_at, started_at),
           end_reason = 'Stale'
     WHERE tenant_id = p_tenant_id AND school_id = p_school_id
       AND ended_at IS NULL
       AND COALESCE(last_received_at, started_at) < now() - interval '30 minutes';
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END;
$function$;


-- ── Driver ──────────────────────────────────────────────────────────────────
DROP PROCEDURE IF EXISTS core.sp_transport_trip_manage(varchar, integer, integer, integer, integer, integer,
    numeric, numeric, numeric, numeric, numeric, timestamptz, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_transport_trip_manage(
    IN p_operation      varchar,
    IN p_tenant_id      integer,
    IN p_school_id      integer,
    IN p_action_user_id integer,
    IN p_vehicle_id     integer     DEFAULT NULL,
    IN p_trip_id        integer     DEFAULT NULL,
    IN p_lat            numeric     DEFAULT NULL,
    IN p_lng            numeric     DEFAULT NULL,
    IN p_accuracy       numeric     DEFAULT NULL,
    IN p_speed          numeric     DEFAULT NULL,
    IN p_heading        numeric     DEFAULT NULL,
    IN p_recorded_at    timestamptz DEFAULT NULL,
    INOUT p_result      refcursor   DEFAULT 'result_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_staff_id  integer;
    v_staff_nm  varchar(150);
    v_trip      core.transport_trips%ROWTYPE;
    v_vehicle   core.transport_vehicles%ROWTYPE;
    v_route_nm  varchar(80);
    v_at        timestamptz;
    v_speed     numeric;
    v_heading   numeric;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    -- Who is calling, as a member of staff of THIS school.
    SELECT staff_id, full_name INTO v_staff_id, v_staff_nm
      FROM core.staff
     WHERE user_id = p_action_user_id AND tenant_id = p_tenant_id AND school_id = p_school_id
       AND NOT COALESCE(is_deleted, FALSE)
       AND COALESCE(status, 'Active') <> 'Inactive'
     LIMIT 1;

    PERFORM core.fn_transport_close_stale_trips(p_tenant_id, p_school_id);

    IF p_operation IN ('MyBus', 'IsDriver') THEN
        -- The vehicles this user drives (none when they are not staff here).
        OPEN p_result FOR
        SELECT v.vehicle_id, v.vehicle_no, r.route_id, r.route_name,
               t.trip_id,
               to_char(t.started_at, 'YYYY-MM-DD HH24:MI:SS')       AS started_at,
               to_char(t.last_received_at, 'YYYY-MM-DD HH24:MI:SS') AS last_point_at,
               COALESCE(t.point_count, 0)                           AS point_count
          FROM core.transport_vehicles v
          LEFT JOIN core.transport_routes r
                 ON r.route_id = v.route_id AND r.tenant_id = v.tenant_id AND r.school_id = v.school_id
                AND NOT COALESCE(r.is_deleted, FALSE)
          LEFT JOIN core.transport_trips t ON t.vehicle_id = v.vehicle_id AND t.ended_at IS NULL
         WHERE v.tenant_id = p_tenant_id AND v.school_id = p_school_id
           AND v.driver_staff_id = v_staff_id
           AND v.is_active AND NOT COALESCE(v.is_deleted, FALSE)
         ORDER BY v.vehicle_no;
        RETURN;
    END IF;

    IF p_operation = 'StartTrip' THEN
        SELECT * INTO v_vehicle FROM core.transport_vehicles
         WHERE vehicle_id = p_vehicle_id AND tenant_id = p_tenant_id AND school_id = p_school_id
           AND is_active AND NOT COALESCE(is_deleted, FALSE);
        IF NOT FOUND OR v_staff_id IS NULL OR v_vehicle.driver_staff_id IS DISTINCT FROM v_staff_id THEN
            RAISE EXCEPTION 'You are not the driver of this bus.';
        END IF;

        -- 30-day retention, for every school (see the header). Indexed and cheap.
        DELETE FROM core.transport_trip_points WHERE recorded_at < now() - interval '30 days';
        DELETE FROM core.transport_trips
         WHERE ended_at IS NOT NULL AND started_at < now() - interval '30 days';

        -- A fresh trip already running on this bus (the page was reloaded): resume it.
        SELECT * INTO v_trip FROM core.transport_trips
         WHERE vehicle_id = v_vehicle.vehicle_id AND ended_at IS NULL;
        IF FOUND THEN
            OPEN p_result FOR
            SELECT TRUE AS success, 'Trip already running. Resumed.'::text AS message,
                   v_trip.trip_id AS trip_id, TRUE AS resumed;
            RETURN;
        END IF;

        SELECT route_name INTO v_route_nm FROM core.transport_routes
         WHERE route_id = v_vehicle.route_id AND tenant_id = p_tenant_id AND school_id = p_school_id
           AND NOT COALESCE(is_deleted, FALSE);

        INSERT INTO core.transport_trips
            (tenant_id, school_id, vehicle_id, route_id, driver_staff_id,
             vehicle_no, route_name, driver_name, started_by)
        VALUES
            (p_tenant_id, p_school_id, v_vehicle.vehicle_id,
             CASE WHEN v_route_nm IS NULL THEN NULL ELSE v_vehicle.route_id END,
             v_staff_id, v_vehicle.vehicle_no, v_route_nm, v_staff_nm, p_action_user_id)
        RETURNING * INTO v_trip;

        OPEN p_result FOR
        SELECT TRUE AS success, 'Trip started.'::text AS message, v_trip.trip_id AS trip_id, FALSE AS resumed;
        RETURN;
    END IF;

    IF p_operation NOT IN ('EndTrip', 'AddPoint') THEN
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;

    -- EndTrip / AddPoint: the trip must be this school's, and the caller must be
    -- the CURRENT driver of its bus.
    SELECT * INTO v_trip FROM core.transport_trips
     WHERE trip_id = p_trip_id AND tenant_id = p_tenant_id AND school_id = p_school_id;
    IF NOT FOUND OR v_staff_id IS NULL OR NOT EXISTS (
           SELECT 1 FROM core.transport_vehicles
            WHERE vehicle_id = v_trip.vehicle_id AND driver_staff_id = v_staff_id
              AND NOT COALESCE(is_deleted, FALSE)) THEN
        RAISE EXCEPTION 'You are not the driver of this bus.';
    END IF;

    IF p_operation = 'EndTrip' THEN
        IF v_trip.ended_at IS NOT NULL THEN
            OPEN p_result FOR SELECT TRUE AS success, 'This trip had already ended.'::text AS message;
            RETURN;
        END IF;
        UPDATE core.transport_trips SET ended_at = now(), end_reason = 'Driver'
         WHERE trip_id = v_trip.trip_id;
        OPEN p_result FOR SELECT TRUE AS success, 'Trip ended.'::text AS message;
        RETURN;
    END IF;

    -- AddPoint
    IF v_trip.ended_at IS NOT NULL THEN
        RAISE EXCEPTION 'This trip has ended. Start a new trip.';
    END IF;
    IF p_lat IS NULL OR p_lng IS NULL OR p_lat < -90 OR p_lat > 90 OR p_lng < -180 OR p_lng > 180 THEN
        RAISE EXCEPTION 'Invalid position.';
    END IF;
    IF p_lat = 0 AND p_lng = 0 THEN
        RAISE EXCEPTION 'Invalid position.';
    END IF;
    IF p_accuracy IS NULL OR p_accuracy < 0 OR p_accuracy > 2000 THEN
        RAISE EXCEPTION 'GPS accuracy is too poor to use (more than 2 km).';
    END IF;

    v_at := COALESCE(p_recorded_at, now());
    IF v_at > now() + interval '2 minutes' THEN
        RAISE EXCEPTION 'The position time is in the future. Check the phone''s clock.';
    END IF;
    IF v_at < v_trip.started_at - interval '1 minute' THEN
        RAISE EXCEPTION 'The position is older than the trip.';
    END IF;

    -- Too soon after the previous point (or out of order): dropped, not an error.
    IF v_trip.last_recorded_at IS NOT NULL AND v_at < v_trip.last_recorded_at + interval '5 seconds' THEN
        OPEN p_result FOR SELECT TRUE AS success, FALSE AS accepted, 'Too soon after the last point; skipped.'::text AS message;
        RETURN;
    END IF;

    -- Speed and heading are only extras: a nonsense value is dropped, not refused.
    v_speed   := CASE WHEN p_speed   BETWEEN 0 AND 100 THEN round(p_speed, 2)   END;   -- m/s
    v_heading := CASE WHEN p_heading BETWEEN 0 AND 360 THEN round(p_heading, 1) END;

    INSERT INTO core.transport_trip_points
        (tenant_id, school_id, trip_id, lat, lng, accuracy_m, speed_mps, heading_deg, recorded_at)
    VALUES
        (p_tenant_id, p_school_id, v_trip.trip_id, round(p_lat, 6), round(p_lng, 6),
         round(p_accuracy, 1), v_speed, v_heading, v_at);

    UPDATE core.transport_trips
       SET last_lat = round(p_lat, 6), last_lng = round(p_lng, 6),
           last_accuracy_m = round(p_accuracy, 1), last_speed_mps = v_speed, last_heading_deg = v_heading,
           last_recorded_at = v_at, last_received_at = now(),
           point_count = point_count + 1
     WHERE trip_id = v_trip.trip_id;

    OPEN p_result FOR SELECT TRUE AS success, TRUE AS accepted, 'Point saved.'::text AS message;
END;
$procedure$;


-- ── Staff: live map, history, share links ───────────────────────────────────
DROP PROCEDURE IF EXISTS core.sp_transport_tracking_manage(varchar, integer, integer, integer, integer, integer,
    integer, varchar, varchar, varchar, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_transport_tracking_manage(
    IN p_operation      varchar,
    IN p_tenant_id      integer,
    IN p_school_id      integer,
    IN p_action_user_id integer,
    IN p_vehicle_id     integer   DEFAULT NULL,
    IN p_trip_id        integer   DEFAULT NULL,
    IN p_route_id       integer   DEFAULT NULL,
    IN p_from_date      varchar   DEFAULT NULL,   -- ISO yyyy-MM-dd, school date
    IN p_to_date        varchar   DEFAULT NULL,
    IN p_token_hash     varchar   DEFAULT NULL,   -- ShareCreate: hex sha256 of the new token
    INOUT p_result      refcursor DEFAULT 'result_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_from date;
    v_to   date;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    PERFORM core.fn_transport_close_stale_trips(p_tenant_id, p_school_id);

    IF p_operation = 'LiveList' THEN
        OPEN p_result FOR
        SELECT t.trip_id, t.vehicle_id,
               COALESCE(v.vehicle_no, t.vehicle_no)                 AS vehicle_no,
               t.route_name, t.driver_name,
               to_char(t.started_at, 'YYYY-MM-DD HH24:MI:SS')       AS started_at,
               to_char(t.last_received_at, 'YYYY-MM-DD HH24:MI:SS') AS last_point_at,
               CASE WHEN t.last_received_at IS NULL THEN NULL
                    ELSE GREATEST(0, EXTRACT(EPOCH FROM now() - t.last_received_at))::int END AS age_seconds,
               t.last_lat AS lat, t.last_lng AS lng, t.last_accuracy_m AS accuracy_m,
               t.last_speed_mps AS speed_mps, t.last_heading_deg AS heading_deg, t.point_count
          FROM core.transport_trips t
          LEFT JOIN core.transport_vehicles v ON v.vehicle_id = t.vehicle_id
         WHERE t.tenant_id = p_tenant_id AND t.school_id = p_school_id AND t.ended_at IS NULL
         ORDER BY 3;

    ELSIF p_operation = 'TripHistory' THEN
        -- Dates are the school's calendar days; default = the last 7 days.
        v_to   := COALESCE(NULLIF(trim(p_to_date), '')::date, current_date);
        v_from := COALESCE(NULLIF(trim(p_from_date), '')::date, v_to - 6);
        OPEN p_result FOR
        SELECT t.trip_id, t.vehicle_id, t.vehicle_no, t.route_name, t.driver_name,
               to_char(t.started_at, 'YYYY-MM-DD HH24:MI:SS') AS started_at,
               to_char(t.ended_at,   'YYYY-MM-DD HH24:MI:SS') AS ended_at,
               t.end_reason, t.point_count,
               (t.ended_at IS NULL) AS is_running,
               GREATEST(0, EXTRACT(EPOCH FROM COALESCE(t.ended_at, now()) - t.started_at) / 60)::int AS duration_min
          FROM core.transport_trips t
         WHERE t.tenant_id = p_tenant_id AND t.school_id = p_school_id
           AND (COALESCE(p_vehicle_id, 0) = 0 OR t.vehicle_id = p_vehicle_id)
           AND t.started_at >= v_from::timestamptz
           AND t.started_at <  (v_to + 1)::timestamptz
         ORDER BY t.started_at DESC
         LIMIT 500;

    ELSIF p_operation = 'TripPoints' THEN
        -- Only a trip of this school; another school's trip id returns no rows.
        OPEN p_result FOR
        SELECT p.lat, p.lng, p.accuracy_m, p.speed_mps,
               to_char(p.recorded_at, 'YYYY-MM-DD HH24:MI:SS') AS recorded_at
          FROM core.transport_trip_points p
          JOIN core.transport_trips t ON t.trip_id = p.trip_id
         WHERE p.trip_id = p_trip_id
           AND t.tenant_id = p_tenant_id AND t.school_id = p_school_id
           AND p.tenant_id = p_tenant_id AND p.school_id = p_school_id
         ORDER BY p.recorded_at
         LIMIT 10000;

    ELSIF p_operation = 'ShareList' THEN
        OPEN p_result FOR
        SELECT s.route_id, to_char(s.created_at, 'YYYY-MM-DD HH24:MI:SS') AS created_at
          FROM core.transport_route_shares s
         WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id AND s.revoked_at IS NULL;

    ELSIF p_operation = 'ShareCreate' THEN
        -- Create, or regenerate: the old link stops working at once.
        IF NOT EXISTS (SELECT 1 FROM core.transport_routes
                        WHERE route_id = p_route_id AND tenant_id = p_tenant_id AND school_id = p_school_id
                          AND NOT COALESCE(is_deleted, FALSE)) THEN
            RAISE EXCEPTION 'Route not found.';
        END IF;
        IF p_token_hash IS NULL OR p_token_hash !~ '^[0-9a-f]{64}$' THEN
            RAISE EXCEPTION 'Invalid link token.';
        END IF;

        UPDATE core.transport_route_shares
           SET revoked_at = now(), revoked_by = p_action_user_id
         WHERE route_id = p_route_id AND tenant_id = p_tenant_id AND school_id = p_school_id
           AND revoked_at IS NULL;

        INSERT INTO core.transport_route_shares (tenant_id, school_id, route_id, token_hash, created_by)
        VALUES (p_tenant_id, p_school_id, p_route_id, p_token_hash, p_action_user_id);

        OPEN p_result FOR SELECT TRUE AS success, 'Parent link created.'::text AS message;

    ELSIF p_operation = 'ShareRevoke' THEN
        UPDATE core.transport_route_shares
           SET revoked_at = now(), revoked_by = p_action_user_id
         WHERE route_id = p_route_id AND tenant_id = p_tenant_id AND school_id = p_school_id
           AND revoked_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'This route has no parent link.';
        END IF;
        OPEN p_result FOR SELECT TRUE AS success, 'Parent link turned off.'::text AS message;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;


-- ── Parent page (no login) ──────────────────────────────────────────────────
-- The token's hash is the ONLY input; the school comes from the share row, never
-- from the caller. Rows:
--   none                     -> unknown or revoked link, route deleted, or the
--                               school switched Transport off
--   one row, trip_id NULL    -> valid link, no bus on a trip right now
--   one row per running bus  -> vehicle no. and last position
-- Nothing personal is returned: no driver, no phone, no students.
DROP PROCEDURE IF EXISTS core.sp_transport_track_public(varchar, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_transport_track_public(
    IN p_token_hash varchar,
    INOUT p_result  refcursor DEFAULT 'result_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_tenant integer;
    v_school integer;
    v_route  integer;
    v_name   varchar(80);
BEGIN
    SELECT s.tenant_id, s.school_id, s.route_id, r.route_name
      INTO v_tenant, v_school, v_route, v_name
      FROM core.transport_route_shares s
      JOIN core.transport_routes r ON r.route_id = s.route_id
           AND r.tenant_id = s.tenant_id AND r.school_id = s.school_id
           AND NOT COALESCE(r.is_deleted, FALSE)
     WHERE p_token_hash ~ '^[0-9a-f]{64}$'
       AND s.token_hash = p_token_hash
       AND s.revoked_at IS NULL
       AND COALESCE((SELECT w.enable_transport FROM core.school_admission_workflow_settings w
                      WHERE w.tenant_id = s.tenant_id AND w.school_id = s.school_id
                        AND NOT COALESCE(w.is_deleted, FALSE)
                      LIMIT 1), TRUE);

    IF v_route IS NULL THEN
        OPEN p_result FOR
        SELECT NULL::varchar AS route_name, NULL::integer AS trip_id, NULL::varchar AS vehicle_no,
               NULL::numeric AS lat, NULL::numeric AS lng, NULL::int AS age_seconds,
               NULL::text AS last_point_at
         WHERE FALSE;
        RETURN;
    END IF;

    PERFORM core.fn_transport_close_stale_trips(v_tenant, v_school);

    OPEN p_result FOR
    SELECT v_name AS route_name, t.trip_id, t.vehicle_no, t.last_lat AS lat, t.last_lng AS lng,
           CASE WHEN t.last_received_at IS NULL THEN NULL
                ELSE GREATEST(0, EXTRACT(EPOCH FROM now() - t.last_received_at))::int END AS age_seconds,
           to_char(t.last_received_at, 'HH24:MI') AS last_point_at
      FROM (SELECT 1) one
      LEFT JOIN core.transport_trips t
             ON t.tenant_id = v_tenant AND t.school_id = v_school
            AND t.route_id = v_route AND t.ended_at IS NULL
     ORDER BY t.vehicle_no;
END;
$procedure$;
