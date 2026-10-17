-- ============================================================================
-- Transport Module — routes (+ per-stop fares), vehicles, student assignment
--
-- A student's monthly bus fee is the fare of the STOP they board at. Assigning a
-- student to a route+stop snapshots that fare and generates monthly 'Transport
-- Fee' dues in core.student_ledger, so the Fee Collection counter bills bus fee
-- automatically alongside tuition (same Monthly mechanism as student_master_fields.sql).
--
-- Tables : core.transport_routes, core.transport_stops, core.transport_vehicles,
--          core.student_transport
-- Procs  : sp_transport_route_manage, sp_transport_vehicle_manage,
--          sp_transport_assign_manage, sp_transport_routes_dropdown
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── Tables ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS core.transport_routes
(
    route_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   integer NOT NULL,
    school_id   integer NOT NULL,
    route_name  varchar(80)  NOT NULL,
    description varchar(200),
    is_active   boolean NOT NULL DEFAULT TRUE,
    is_deleted  boolean NOT NULL DEFAULT FALSE,
    created_by  integer,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  integer,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT chk_transport_routes_scope CHECK ((tenant_id > 1) AND (school_id > 0))
);

CREATE TABLE IF NOT EXISTS core.transport_stops
(
    stop_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    route_id      integer NOT NULL REFERENCES core.transport_routes(route_id) ON DELETE CASCADE,
    tenant_id     integer NOT NULL,
    school_id     integer NOT NULL,
    stop_name     varchar(80) NOT NULL,
    monthly_fare  numeric(12,2) NOT NULL DEFAULT 0,
    display_order integer NOT NULL DEFAULT 0,
    is_active     boolean NOT NULL DEFAULT TRUE,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_transport_stops_route ON core.transport_stops(route_id);

CREATE TABLE IF NOT EXISTS core.transport_vehicles
(
    vehicle_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id    integer NOT NULL,
    school_id    integer NOT NULL,
    vehicle_no   varchar(40) NOT NULL,
    capacity     integer,
    driver_name  varchar(100),
    driver_phone varchar(20),
    route_id     integer REFERENCES core.transport_routes(route_id) ON DELETE SET NULL,
    is_active    boolean NOT NULL DEFAULT TRUE,
    is_deleted   boolean NOT NULL DEFAULT FALSE,
    created_by   integer,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   integer,
    updated_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT chk_transport_vehicles_scope CHECK ((tenant_id > 1) AND (school_id > 0))
);

-- Driver is an EMPLOYEE (core.staff, designation "Driver"), not free text. The
-- name/phone columns above are kept as a snapshot of the linked staff at save
-- time (like other snapshots in this schema); driver_staff_id is the real link.
ALTER TABLE core.transport_vehicles
    ADD COLUMN IF NOT EXISTS driver_staff_id integer REFERENCES core.staff(staff_id) ON DELETE SET NULL;

-- One active assignment per student. stop_id/route_id are stored by value (no hard
-- FK) and the fare is snapshotted, so editing/removing a stop never corrupts a
-- student's billed history.
CREATE TABLE IF NOT EXISTS core.student_transport
(
    assignment_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     integer NOT NULL,
    school_id     integer NOT NULL,
    student_id    integer NOT NULL,
    route_id      integer NOT NULL,
    stop_id       integer NOT NULL,
    monthly_fare  numeric(12,2) NOT NULL DEFAULT 0,
    academic_year varchar(12),
    start_date    date NOT NULL DEFAULT CURRENT_DATE,
    is_active     boolean NOT NULL DEFAULT TRUE,
    is_deleted    boolean NOT NULL DEFAULT FALSE,
    created_by    integer,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    integer,
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT chk_student_transport_scope CHECK ((tenant_id > 1) AND (school_id > 0))
);
CREATE INDEX IF NOT EXISTS idx_student_transport_student ON core.student_transport(student_id);

-- ── Riders and seats per route ──────────────────────────────────────────────
-- Riders = students on the roll with an active assignment on the route.
-- Seats  = total capacity of the route's active vehicles. NULL when no active
-- vehicle on the route has a capacity set: the route then has no known limit
-- and assignment is not capped (a school that never registers buses still works).
-- p_on: count only riders whose bus has started by that date (a child booked
-- from April does not take a seat in October). NULL = every booked rider, used
-- where a future rider matters too (removing a vehicle, deleting a route).
-- The old 2-argument version is dropped: next to this one every short call
-- would be ambiguous.
DROP FUNCTION IF EXISTS core.fn_transport_route_riders(integer, integer);
CREATE OR REPLACE FUNCTION core.fn_transport_route_riders(p_route_id integer, p_except_student integer DEFAULT NULL,
                                                         p_on date DEFAULT NULL)
RETURNS integer LANGUAGE sql STABLE AS $fn$
    SELECT COUNT(DISTINCT a.student_id)::integer
    FROM core.student_transport a
    JOIN core.students st ON st.student_id = a.student_id AND st.is_active
    WHERE a.route_id = p_route_id
      AND a.is_active AND NOT COALESCE(a.is_deleted, FALSE)
      AND a.student_id IS DISTINCT FROM p_except_student
      AND (p_on IS NULL OR NULLIF(a.start_date::text, '')::date <= p_on);
$fn$;

CREATE OR REPLACE FUNCTION core.fn_transport_route_seats(p_route_id integer, p_except_vehicle integer DEFAULT NULL)
RETURNS integer LANGUAGE sql STABLE AS $fn$
    SELECT NULLIF(SUM(COALESCE(v.capacity, 0)), 0)::integer
    FROM core.transport_vehicles v
    WHERE v.route_id = p_route_id
      AND v.is_active AND NOT COALESCE(v.is_deleted, FALSE)
      AND v.vehicle_id IS DISTINCT FROM p_except_vehicle;
$fn$;

-- ── Routes (+ stops) manage ─────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE core.sp_transport_route_manage(
    IN    p_operation      varchar,
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_route_id       integer  DEFAULT NULL,
    IN    p_route_name     varchar  DEFAULT NULL,
    IN    p_description    varchar  DEFAULT NULL,
    IN    p_stops          jsonb    DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_route_id integer;
    v_stop     jsonb;
    v_stop_id  integer;
    v_keep     integer[] := ARRAY[]::integer[];
    v_busy     text;
    v_riders   integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    IF p_operation = 'GetRoutes' THEN
        OPEN p_result FOR
        SELECT r.route_id, r.route_name, r.description, r.is_active,
               COUNT(s.stop_id) FILTER (WHERE s.is_active)            AS stop_count,
               MIN(s.monthly_fare) FILTER (WHERE s.is_active)         AS min_fare,
               MAX(s.monthly_fare) FILTER (WHERE s.is_active)         AS max_fare,
               core.fn_transport_route_riders(r.route_id, NULL, CURRENT_DATE) AS riders,   -- riding today
               core.fn_transport_route_seats(r.route_id)              AS seats
        FROM core.transport_routes r
        LEFT JOIN core.transport_stops s ON s.route_id = r.route_id
        WHERE r.tenant_id = p_tenant_id AND r.school_id = p_school_id
          AND COALESCE(r.is_deleted, FALSE) = FALSE
        GROUP BY r.route_id, r.route_name, r.description, r.is_active
        ORDER BY r.route_name;

    ELSIF p_operation = 'GetStops' THEN
        OPEN p_result FOR
        SELECT stop_id, route_id, stop_name, monthly_fare, display_order
        FROM core.transport_stops
        WHERE route_id = p_route_id AND tenant_id = p_tenant_id AND school_id = p_school_id
          AND is_active = TRUE
        ORDER BY display_order, stop_id;

    ELSIF p_operation = 'SaveRoute' THEN
        IF COALESCE(NULLIF(trim(p_route_name), ''), '') = '' THEN
            RAISE EXCEPTION 'Route name is required.';
        END IF;

        -- One route per name (case and spaces ignored), or the Assign dropdown
        -- offers two "North Zone"s and nobody knows which one a child is on.
        IF EXISTS (SELECT 1 FROM core.transport_routes
                    WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                      AND NOT COALESCE(is_deleted, FALSE)
                      AND lower(regexp_replace(trim(route_name), '\s+', ' ', 'g'))
                          = lower(regexp_replace(trim(p_route_name), '\s+', ' ', 'g'))
                      AND route_id IS DISTINCT FROM NULLIF(p_route_id, 0)) THEN
            RAISE EXCEPTION 'A route called "%" already exists.', trim(p_route_name);
        END IF;

        -- A fare is money the parent pays; it cannot be negative.
        IF p_stops IS NOT NULL AND jsonb_typeof(p_stops) = 'array' AND EXISTS (
               SELECT 1 FROM jsonb_array_elements(p_stops) e
                WHERE COALESCE(NULLIF(trim(e->>'stopName'), ''), '') <> ''
                  AND COALESCE((e->>'monthlyFare')::numeric, 0) < 0) THEN
            RAISE EXCEPTION 'A stop fare cannot be negative.';
        END IF;

        IF COALESCE(p_route_id, 0) > 0 THEN
            UPDATE core.transport_routes
            SET route_name = trim(p_route_name), description = NULLIF(trim(p_description), ''),
                updated_by = p_action_user_id, updated_at = NOW()
            WHERE route_id = p_route_id AND tenant_id = p_tenant_id AND school_id = p_school_id
              AND NOT COALESCE(is_deleted, FALSE)
            RETURNING route_id INTO v_route_id;
            -- Another school's id, or a deleted route: say so, do not pretend.
            IF v_route_id IS NULL THEN
                RAISE EXCEPTION 'Route not found.';
            END IF;
        ELSE
            INSERT INTO core.transport_routes (tenant_id, school_id, route_name, description, created_by)
            VALUES (p_tenant_id, p_school_id, trim(p_route_name), NULLIF(trim(p_description), ''), p_action_user_id)
            RETURNING route_id INTO v_route_id;
        END IF;

        -- Sync stops: upsert provided ones, switch off any existing not in the list.
        -- A fare change applies to NEW assignments only: a child already on the
        -- stop keeps the fare snapshotted when they were assigned.
        IF p_stops IS NOT NULL AND jsonb_typeof(p_stops) = 'array' THEN
            FOR v_stop IN SELECT * FROM jsonb_array_elements(p_stops)
            LOOP
                IF COALESCE(NULLIF(trim(v_stop->>'stopName'), ''), '') = '' THEN
                    CONTINUE;
                END IF;
                v_stop_id := NULLIF((v_stop->>'stopId'), '')::integer;
                IF COALESCE(v_stop_id, 0) > 0 THEN
                    UPDATE core.transport_stops
                    SET stop_name = trim(v_stop->>'stopName'),
                        monthly_fare = COALESCE((v_stop->>'monthlyFare')::numeric, 0),
                        display_order = COALESCE((v_stop->>'displayOrder')::integer, 0),
                        is_active = TRUE, updated_at = NOW()
                    WHERE stop_id = v_stop_id AND route_id = v_route_id;
                    IF NOT FOUND THEN
                        v_stop_id := NULL;   -- not a stop of this route: ignore it
                    END IF;
                ELSE
                    INSERT INTO core.transport_stops
                        (route_id, tenant_id, school_id, stop_name, monthly_fare, display_order)
                    VALUES
                        (v_route_id, p_tenant_id, p_school_id, trim(v_stop->>'stopName'),
                         COALESCE((v_stop->>'monthlyFare')::numeric, 0),
                         COALESCE((v_stop->>'displayOrder')::integer, 0))
                    RETURNING stop_id INTO v_stop_id;
                END IF;
                IF v_stop_id IS NOT NULL THEN
                    v_keep := array_append(v_keep, v_stop_id);
                END IF;
            END LOOP;
        END IF;

        -- A stop that children board at cannot be taken off the route: they
        -- would stay assigned (and billed) at a stop that no longer exists.
        SELECT string_agg(DISTINCT s.stop_name, ', ') INTO v_busy
        FROM core.transport_stops s
        JOIN core.student_transport a ON a.stop_id = s.stop_id
             AND a.is_active AND NOT COALESCE(a.is_deleted, FALSE)
        JOIN core.students st ON st.student_id = a.student_id AND st.is_active
        WHERE s.route_id = v_route_id AND s.is_active
          AND NOT (s.stop_id = ANY(v_keep));
        IF v_busy IS NOT NULL THEN
            RAISE EXCEPTION 'Stop(s) % still have students assigned. Move them to another stop first.', v_busy;
        END IF;

        -- Removed stops are switched off, never deleted: past assignments and
        -- their history still point at them.
        UPDATE core.transport_stops
        SET is_active = FALSE, updated_at = NOW()
        WHERE route_id = v_route_id AND is_active AND NOT (stop_id = ANY(v_keep));

        OPEN p_result FOR SELECT TRUE AS success, 'Route saved.' AS message, v_route_id AS route_id;

    ELSIF p_operation = 'DeleteRoute' THEN
        PERFORM 1 FROM core.transport_routes
         WHERE route_id = p_route_id AND tenant_id = p_tenant_id AND school_id = p_school_id
           AND NOT COALESCE(is_deleted, FALSE);
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Route not found.';
        END IF;

        -- Children still riding it: refuse. A deleted route would keep billing
        -- them on a route nobody can see.
        v_riders := core.fn_transport_route_riders(p_route_id);
        IF v_riders > 0 THEN
            RAISE EXCEPTION '% student(s) are still assigned to this route. Move or remove them first.', v_riders;
        END IF;

        -- Soft delete: the row stays so past assignments keep their route name.
        UPDATE core.transport_routes
        SET is_deleted = TRUE, is_active = FALSE, updated_by = p_action_user_id, updated_at = NOW()
        WHERE route_id = p_route_id AND tenant_id = p_tenant_id AND school_id = p_school_id;

        -- A bus left pointing at a deleted route would still show it on Vehicles.
        UPDATE core.transport_vehicles
        SET route_id = NULL, updated_by = p_action_user_id, updated_at = NOW()
        WHERE route_id = p_route_id AND tenant_id = p_tenant_id AND school_id = p_school_id;

        OPEN p_result FOR SELECT TRUE AS success, 'Route deleted.' AS message;

    ELSIF p_operation = 'ToggleRouteStatus' THEN
        -- Switching a route off only stops NEW assignments; children already on
        -- it stay until they are moved.
        UPDATE core.transport_routes
        SET is_active = NOT is_active, updated_by = p_action_user_id, updated_at = NOW()
        WHERE route_id = p_route_id AND tenant_id = p_tenant_id AND school_id = p_school_id
          AND NOT COALESCE(is_deleted, FALSE);
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Route not found.';
        END IF;
        OPEN p_result FOR SELECT TRUE AS success, 'Route status updated.' AS message;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;

-- ── Vehicles manage ─────────────────────────────────────────────────────────
-- Old signature (free-text driver only) is dropped so the driver_staff_id param
-- can be added without creating an ambiguous overload.
DROP PROCEDURE IF EXISTS core.sp_transport_vehicle_manage(
    varchar, integer, integer, integer, integer, varchar, integer,
    varchar, varchar, integer, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_transport_vehicle_manage(
    IN    p_operation       varchar,
    IN    p_tenant_id       integer,
    IN    p_school_id       integer,
    IN    p_action_user_id  integer,
    IN    p_vehicle_id      integer  DEFAULT NULL,
    IN    p_vehicle_no      varchar  DEFAULT NULL,
    IN    p_capacity        integer  DEFAULT NULL,
    IN    p_driver_name     varchar  DEFAULT NULL,
    IN    p_driver_phone    varchar  DEFAULT NULL,
    IN    p_route_id        integer  DEFAULT NULL,
    IN    p_driver_staff_id integer  DEFAULT NULL,
    INOUT p_result          refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_dname  varchar(100);
    v_dphone varchar(20);
    v_route  integer;
    v_active boolean;
    v_riders integer;
    v_old_route  integer;   -- route the vehicle was on before this save
    v_old_seats  integer;   -- seats of that route before the save
    v_new_seats  integer;   -- seats of the chosen route before the save
    v_seats      integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    IF p_operation = 'GetVehicles' THEN
        OPEN p_result FOR
        SELECT v.vehicle_id, v.vehicle_no, v.capacity, v.driver_name, v.driver_phone,
               v.route_id, r.route_name, v.is_active, v.driver_staff_id
        FROM core.transport_vehicles v
        -- Only this school's live routes: a route id from anywhere else must
        -- never surface another school's route name here.
        LEFT JOIN core.transport_routes r ON r.route_id = v.route_id
             AND r.tenant_id = v.tenant_id AND r.school_id = v.school_id
             AND NOT COALESCE(r.is_deleted, FALSE)
        WHERE v.tenant_id = p_tenant_id AND v.school_id = p_school_id
          AND COALESCE(v.is_deleted, FALSE) = FALSE
        ORDER BY v.vehicle_no;

    ELSIF p_operation = 'GetDrivers' THEN
        -- Transport-type staff (drivers/conductors) for the vehicle dropdown.
        OPEN p_result FOR
        SELECT staff_id, full_name, mobile, designation
        FROM   core.staff
        WHERE  tenant_id = p_tenant_id AND school_id = p_school_id
          AND  COALESCE(is_deleted, FALSE) = FALSE
          AND  COALESCE(status, 'Active') <> 'Inactive'
          AND  (staff_type = 'Transport' OR designation ILIKE '%driver%' OR designation ILIKE '%conductor%')
        ORDER BY full_name;

    ELSIF p_operation = 'SaveVehicle' THEN
        IF COALESCE(NULLIF(trim(p_vehicle_no), ''), '') = '' THEN
            RAISE EXCEPTION 'Vehicle number is required.';
        END IF;

        -- A registration number is one vehicle. Compared without case, spaces
        -- or dashes so "RJ14-AB-1234" and "rj14 ab 1234" are the same bus.
        IF EXISTS (SELECT 1 FROM core.transport_vehicles
                    WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                      AND NOT COALESCE(is_deleted, FALSE)
                      AND upper(regexp_replace(vehicle_no, '[\s-]', '', 'g'))
                          = upper(regexp_replace(p_vehicle_no, '[\s-]', '', 'g'))
                      AND vehicle_id IS DISTINCT FROM NULLIF(p_vehicle_id, 0)) THEN
            RAISE EXCEPTION 'Vehicle % is already registered.', trim(p_vehicle_no);
        END IF;

        IF p_capacity IS NOT NULL AND p_capacity < 1 THEN
            RAISE EXCEPTION 'Capacity must be at least 1 seat (or left blank).';
        END IF;

        -- The route must be one of this school's live routes.
        IF COALESCE(p_route_id, 0) > 0 AND NOT EXISTS (
               SELECT 1 FROM core.transport_routes
                WHERE route_id = p_route_id AND tenant_id = p_tenant_id AND school_id = p_school_id
                  AND NOT COALESCE(is_deleted, FALSE)) THEN
            RAISE EXCEPTION 'Route not found.';
        END IF;

        IF COALESCE(p_driver_staff_id, 0) > 0 AND NOT EXISTS (
               SELECT 1 FROM core.staff
                WHERE staff_id = p_driver_staff_id AND tenant_id = p_tenant_id AND school_id = p_school_id
                  AND COALESCE(is_deleted, FALSE) = FALSE) THEN
            RAISE EXCEPTION 'Driver not found.';
        END IF;
        -- A driver who has left cannot be put on a bus (sp_staff_release_duties
        -- takes them off their bus when they leave).
        IF COALESCE(p_driver_staff_id, 0) > 0 AND EXISTS (
               SELECT 1 FROM core.staff
                WHERE staff_id = p_driver_staff_id AND COALESCE(status, 'Active') = 'Inactive') THEN
            RAISE EXCEPTION 'This driver is marked as left. Pick an active driver.';
        END IF;

        -- Seats before the save, to check below that children are not left
        -- without a seat when capacity is lowered or the bus moves route.
        SELECT route_id INTO v_old_route FROM core.transport_vehicles
         WHERE vehicle_id = NULLIF(COALESCE(p_vehicle_id, 0), 0)
           AND tenant_id = p_tenant_id AND school_id = p_school_id;
        v_old_seats := core.fn_transport_route_seats(v_old_route);
        v_new_seats := core.fn_transport_route_seats(NULLIF(COALESCE(p_route_id, 0), 0));

        -- Snapshot driver name/phone from the linked staff row (single source);
        -- fall back to any free-text passed in when no staff is linked.
        IF COALESCE(p_driver_staff_id, 0) > 0 THEN
            SELECT full_name, mobile INTO v_dname, v_dphone
            FROM   core.staff
            WHERE  staff_id = p_driver_staff_id
              AND  tenant_id = p_tenant_id AND school_id = p_school_id
              AND  COALESCE(is_deleted, FALSE) = FALSE;
        END IF;
        v_dname  := COALESCE(v_dname,  p_driver_name);
        v_dphone := COALESCE(v_dphone, p_driver_phone);

        IF COALESCE(p_vehicle_id, 0) > 0 THEN
            UPDATE core.transport_vehicles
            SET vehicle_no = trim(p_vehicle_no), capacity = p_capacity,
                driver_name = v_dname, driver_phone = v_dphone,
                driver_staff_id = NULLIF(COALESCE(p_driver_staff_id, 0), 0),
                route_id = NULLIF(COALESCE(p_route_id, 0), 0),
                updated_by = p_action_user_id, updated_at = NOW()
            WHERE vehicle_id = p_vehicle_id AND tenant_id = p_tenant_id AND school_id = p_school_id
              AND NOT COALESCE(is_deleted, FALSE);
            IF NOT FOUND THEN
                RAISE EXCEPTION 'Vehicle not found.';
            END IF;
        ELSE
            INSERT INTO core.transport_vehicles
                (tenant_id, school_id, vehicle_no, capacity, driver_name, driver_phone,
                 driver_staff_id, route_id, created_by)
            VALUES
                (p_tenant_id, p_school_id, trim(p_vehicle_no), p_capacity, v_dname, v_dphone,
                 NULLIF(COALESCE(p_driver_staff_id, 0), 0), NULLIF(COALESCE(p_route_id, 0), 0), p_action_user_id);
        END IF;

        -- Fewer seats than children riding: refused (the save is rolled back).
        -- Only when this save took seats away, so an old full route can still be edited.
        IF v_old_route IS NOT NULL THEN
            v_seats  := core.fn_transport_route_seats(v_old_route);
            v_riders := core.fn_transport_route_riders(v_old_route);
            IF v_seats IS NOT NULL AND v_seats < COALESCE(v_old_seats, 2147483647) AND v_riders > v_seats THEN
                RAISE EXCEPTION 'The route would have % seat(s) for % student(s). Move some students or add a vehicle first.', v_seats, v_riders;
            END IF;
        END IF;
        IF COALESCE(p_route_id, 0) > 0 AND p_route_id IS DISTINCT FROM v_old_route THEN
            v_seats  := core.fn_transport_route_seats(p_route_id);
            v_riders := core.fn_transport_route_riders(p_route_id);
            IF v_seats IS NOT NULL AND v_seats < COALESCE(v_new_seats, 2147483647) AND v_riders > v_seats THEN
                RAISE EXCEPTION 'The route would have % seat(s) for % student(s). Move some students or add a vehicle first.', v_seats, v_riders;
            END IF;
        END IF;
        OPEN p_result FOR SELECT TRUE AS success, 'Vehicle saved.' AS message;

    ELSIF p_operation IN ('DeleteVehicle', 'ToggleVehicleStatus') THEN
        SELECT route_id, is_active INTO v_route, v_active
        FROM core.transport_vehicles
        WHERE vehicle_id = p_vehicle_id AND tenant_id = p_tenant_id AND school_id = p_school_id
          AND NOT COALESCE(is_deleted, FALSE);
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Vehicle not found.';
        END IF;

        -- Taking a bus off the road (switching it off, or deleting it) is
        -- refused when it is the last active bus of a route children ride:
        -- they would be assigned to a route with no bus. Switching ON is free.
        IF v_active AND v_route IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM core.transport_vehicles
                            WHERE route_id = v_route AND vehicle_id <> p_vehicle_id
                              AND is_active AND NOT COALESCE(is_deleted, FALSE)) THEN
            v_riders := core.fn_transport_route_riders(v_route);
            IF v_riders > 0 THEN
                RAISE EXCEPTION 'This is the only active vehicle on its route and % student(s) ride it. Add or move another vehicle to the route first.', v_riders;
            END IF;
        END IF;

        IF p_operation = 'DeleteVehicle' THEN
            UPDATE core.transport_vehicles
            SET is_deleted = TRUE, is_active = FALSE, updated_by = p_action_user_id, updated_at = NOW()
            WHERE vehicle_id = p_vehicle_id;
            OPEN p_result FOR SELECT TRUE AS success, 'Vehicle deleted.' AS message;
        ELSE
            UPDATE core.transport_vehicles
            SET is_active = NOT is_active, updated_by = p_action_user_id, updated_at = NOW()
            WHERE vehicle_id = p_vehicle_id;
            OPEN p_result FOR SELECT TRUE AS success, 'Vehicle status updated.' AS message;
        END IF;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;

-- ── Routes + stops for cascading dropdowns ──────────────────────────────────
CREATE OR REPLACE PROCEDURE core.sp_transport_routes_dropdown(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    INOUT p_result         refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    OPEN p_result FOR
    SELECT r.route_id, r.route_name, s.stop_id, s.stop_name, s.monthly_fare,
           core.fn_transport_route_riders(r.route_id, NULL, CURRENT_DATE) AS riders,
           core.fn_transport_route_seats(r.route_id)  AS seats
    FROM core.transport_routes r
    JOIN core.transport_stops s ON s.route_id = r.route_id AND s.is_active = TRUE
    WHERE r.tenant_id = p_tenant_id AND r.school_id = p_school_id
      AND r.is_active = TRUE AND COALESCE(r.is_deleted, FALSE) = FALSE
    ORDER BY r.route_name, s.display_order, s.stop_id;
END;
$procedure$;

-- ── Student assignment (snapshots fare + generates monthly transport dues) ──
-- Depends on student_money_lifecycle.sql (fn_ledger_close and the close columns).
CREATE OR REPLACE PROCEDURE core.sp_transport_assign_manage(
    IN    p_operation      varchar,
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_student_id     integer,
    IN    p_route_id       integer  DEFAULT NULL,
    IN    p_stop_id        integer  DEFAULT NULL,
    IN    p_academic_year  varchar  DEFAULT NULL,
    IN    p_start_date     date     DEFAULT NULL,
    IN    p_months         integer  DEFAULT 12,
    INOUT p_result         refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_fare        numeric(12,2);
    v_stop_name   varchar(80);
    v_route_name  varchar(80);
    v_start       date;
    v_month_start date;
    v_i           integer;
    v_made        integer := 0;
    v_student_year varchar;
    v_year        varchar;
    v_sess_end    date;
    v_months      integer;
    v_max         integer;
    v_due         date;
    v_already     numeric(12,2);
    v_closed      numeric(12,2);
    v_reason      varchar(200);
    v_open        boolean;
    v_same_route  boolean;
    v_same_stop   boolean;
    v_seats       integer;
    v_riders      integer;
    r             record;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR p_student_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;

    IF p_operation = 'GetForStudent' THEN
        OPEN p_result FOR
        SELECT a.assignment_id, a.route_id, a.stop_id, a.monthly_fare, a.start_date,
               rt.route_name, s.stop_name
        FROM core.student_transport a
        -- "rt", not "r": r is a record variable of this proc, and PL/pgSQL read
        -- r.route_name as that (unassigned) variable -- every call failed.
        LEFT JOIN core.transport_routes rt ON rt.route_id = a.route_id
        LEFT JOIN core.transport_stops  s ON s.stop_id  = a.stop_id
        WHERE a.student_id = p_student_id AND a.tenant_id = p_tenant_id AND a.school_id = p_school_id
          AND a.is_active = TRUE AND COALESCE(a.is_deleted, FALSE) = FALSE
        ORDER BY a.assignment_id DESC
        LIMIT 1;

    ELSIF p_operation = 'SaveAssignment' THEN
        -- The student must be ours and still on the roll. Without this a stop
        -- of this school could be billed to ANY student id, including another
        -- school's, with the ledger rows written under this school's tenant.
        SELECT academic_year INTO v_student_year
        FROM core.students
        WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
          AND is_active = TRUE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Student not found, or no longer on the roll.';
        END IF;

        SELECT s.monthly_fare, s.stop_name, rt.route_name,
               (s.is_active AND rt.is_active AND NOT COALESCE(rt.is_deleted, FALSE))
          INTO v_fare, v_stop_name, v_route_name, v_open
        FROM core.transport_stops s
        JOIN core.transport_routes rt ON rt.route_id = s.route_id
        WHERE s.stop_id = p_stop_id AND s.route_id = p_route_id
          AND s.tenant_id = p_tenant_id AND s.school_id = p_school_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Selected stop not found.';
        END IF;

        -- Is the child already on this route / stop? Promotion re-bills a kept
        -- route for the new session through this same call, and that must keep
        -- working even if the route has since been closed or filled up.
        v_same_route := EXISTS (SELECT 1 FROM core.student_transport
                                 WHERE student_id = p_student_id AND route_id = p_route_id
                                   AND is_active AND NOT COALESCE(is_deleted, FALSE));
        v_same_stop  := EXISTS (SELECT 1 FROM core.student_transport
                                 WHERE student_id = p_student_id AND stop_id = p_stop_id
                                   AND is_active AND NOT COALESCE(is_deleted, FALSE));

        -- A switched-off route, a deleted route or a removed stop takes no new
        -- riders.
        IF NOT v_open AND NOT v_same_stop THEN
            RAISE EXCEPTION 'Route % / stop % is not in service. Pick an active route and stop.',
                v_route_name, v_stop_name;
        END IF;

        -- Seats: the route's active buses decide how many children it takes.
        -- Unlimited when no active bus on the route has a capacity set.
        IF NOT v_same_route THEN
            v_seats  := core.fn_transport_route_seats(p_route_id);
            -- riders already on the bus by the day this one starts
            v_riders := core.fn_transport_route_riders(p_route_id, p_student_id, COALESCE(p_start_date, CURRENT_DATE));
            IF v_seats IS NOT NULL AND v_riders >= v_seats THEN
                RAISE EXCEPTION 'Route % is full: % of % seats taken. Add a vehicle or pick another route.',
                    v_route_name, v_riders, v_seats;
            END IF;
        END IF;

        v_start := COALESCE(p_start_date, CURRENT_DATE);
        v_year  := COALESCE(NULLIF(TRIM(p_academic_year), ''), v_student_year);

        -- A start before the child joined would bill months they were not here.
        IF v_start < (SELECT NULLIF(admission_date, '')::date FROM core.students WHERE student_id = p_student_id) THEN
            RAISE EXCEPTION 'The bus start date is before the student''s admission date.';
        END IF;

        -- Bill to the end of the SESSION the assignment is for, read from its
        -- real end date. The controllers used to send a month count worked out
        -- from the session NAME on an April-March assumption, and this proc
        -- trusted it, so a 12-month count from October ran into the next session.
        SELECT NULLIF(end_date, '')::date, GREATEST(v_start, NULLIF(start_date, '')::date)
          INTO v_sess_end, v_start
        FROM academic.academic_years
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND academic_year_name = v_year AND COALESCE(is_deleted, FALSE) = FALSE
        LIMIT 1;
        -- (a start before the session begins is moved to the session's first day:
        --  an advance admission in February does not bill March of the old session)
        v_start := COALESCE(v_start, COALESCE(p_start_date, CURRENT_DATE));

        v_months := GREATEST(COALESCE(NULLIF(p_months, 0), 12), 1);
        IF v_sess_end IS NOT NULL THEN
            v_max := ((EXTRACT(YEAR FROM v_sess_end) * 12 + EXTRACT(MONTH FROM v_sess_end))
                    - (EXTRACT(YEAR FROM v_start)    * 12 + EXTRACT(MONTH FROM v_start)))::integer + 1;
            IF v_max <= 0 THEN
                RAISE EXCEPTION 'The start date is after session % ends.', v_year;
            END IF;
            v_months := LEAST(v_months, v_max);
        END IF;

        -- Replace the current assignment. Its unpaid dues from the start month
        -- on are CLOSED, not deleted: the row stays (a cancelled receipt may
        -- still point at it) with the reason, who and when, and only the part
        -- nobody paid is taken off. See student_money_lifecycle.sql.
        v_reason := 'Route changed on ' || to_char(v_start, 'YYYY-MM-DD');
        FOR r IN
            SELECT ledger_id FROM core.student_ledger
            WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
              AND fee_head_name = 'Transport Fee'
              AND due_date::date >= DATE_TRUNC('month', v_start)::date
              AND amount_due - amount_paid - concession > 0
        LOOP
            PERFORM core.fn_ledger_close(r.ledger_id, v_reason, 'Transport', p_action_user_id);
        END LOOP;

        UPDATE core.student_transport
        SET is_active = FALSE, is_deleted = TRUE,
            end_reason = 'Replaced by ' || COALESCE(v_route_name, '') || ' / ' || COALESCE(v_stop_name, '') ||
                         ' on ' || to_char(v_start, 'YYYY-MM-DD'),
            ended_by = p_action_user_id, ended_at = NOW(),
            updated_by = p_action_user_id, updated_at = NOW()
        WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
          AND is_active = TRUE;

        INSERT INTO core.student_transport
            (tenant_id, school_id, student_id, route_id, stop_id, monthly_fare,
             academic_year, start_date, created_by)
        VALUES
            (p_tenant_id, p_school_id, p_student_id, p_route_id, p_stop_id, v_fare,
             v_year, v_start, p_action_user_id);

        -- One 'Transport Fee' due per month. A month that already holds settled
        -- money (paid, or paid then closed) is only topped up to the new fare,
        -- so a part-paid month is never charged twice.
        v_month_start := DATE_TRUNC('month', v_start)::date;
        FOR v_i IN 0 .. v_months - 1 LOOP
            v_due := (v_month_start + make_interval(months => v_i))::date;

            SELECT COALESCE(SUM(amount_due), 0) INTO v_already
            FROM core.student_ledger
            WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
              AND fee_head_name = 'Transport Fee'
              AND due_date::date = v_due;

            IF v_already < v_fare THEN
                INSERT INTO core.student_ledger
                    (tenant_id, school_id, student_id, fee_head_name, frequency,
                     installment_label, due_date, amount_due, status, academic_year)
                VALUES
                    (p_tenant_id, p_school_id, p_student_id, 'Transport Fee', 'Monthly',
                     TO_CHAR(v_due, 'Mon YYYY'), v_due, v_fare - v_already, 'Pending', v_year);
                v_made := v_made + 1;
            END IF;
        END LOOP;

        OPEN p_result FOR
        SELECT TRUE AS success,
               'Transport assigned. ' || v_made || ' monthly due(s) generated.' AS message,
               v_fare AS monthly_fare, v_made AS months_generated;

    ELSIF p_operation = 'RemoveAssignment' THEN
        -- Unpaid bus dues from this month on are CLOSED with a reason (never
        -- deleted), including the unpaid part of a month that was paid in
        -- part. Money already taken stays on the row and can be refunded.
        v_reason := 'Transport removed on ' || to_char(CURRENT_DATE, 'YYYY-MM-DD');
        v_closed := 0;
        FOR r IN
            SELECT ledger_id FROM core.student_ledger
            WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
              AND fee_head_name = 'Transport Fee'
              AND due_date::date >= DATE_TRUNC('month', CURRENT_DATE)::date
              AND amount_due - amount_paid - concession > 0
        LOOP
            v_closed := v_closed + core.fn_ledger_close(r.ledger_id, v_reason, 'Transport', p_action_user_id);
        END LOOP;

        UPDATE core.student_transport
        SET is_active = FALSE, is_deleted = TRUE,
            end_reason = v_reason, ended_by = p_action_user_id, ended_at = NOW(),
            updated_by = p_action_user_id, updated_at = NOW()
        WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
          AND is_active = TRUE;

        OPEN p_result FOR SELECT TRUE AS success,
               'Transport removed.' ||
               CASE WHEN v_closed > 0
                    THEN ' ' || to_char(v_closed, 'FM99999990.00') || ' of unpaid bus fees closed.'
                    ELSE '' END AS message;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;
