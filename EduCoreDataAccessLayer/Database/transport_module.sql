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
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    IF p_operation = 'GetRoutes' THEN
        OPEN p_result FOR
        SELECT r.route_id, r.route_name, r.description, r.is_active,
               COUNT(s.stop_id) FILTER (WHERE s.is_active)            AS stop_count,
               MIN(s.monthly_fare) FILTER (WHERE s.is_active)         AS min_fare,
               MAX(s.monthly_fare) FILTER (WHERE s.is_active)         AS max_fare
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

        IF COALESCE(p_route_id, 0) > 0 THEN
            UPDATE core.transport_routes
            SET route_name = p_route_name, description = p_description,
                updated_by = p_action_user_id, updated_at = NOW()
            WHERE route_id = p_route_id AND tenant_id = p_tenant_id AND school_id = p_school_id
            RETURNING route_id INTO v_route_id;
        ELSE
            INSERT INTO core.transport_routes (tenant_id, school_id, route_name, description, created_by)
            VALUES (p_tenant_id, p_school_id, p_route_name, p_description, p_action_user_id)
            RETURNING route_id INTO v_route_id;
        END IF;

        -- Sync stops: upsert provided ones, deactivate any existing not in the list.
        IF p_stops IS NOT NULL AND jsonb_typeof(p_stops) = 'array' THEN
            FOR v_stop IN SELECT * FROM jsonb_array_elements(p_stops)
            LOOP
                IF COALESCE(NULLIF(trim(v_stop->>'stopName'), ''), '') = '' THEN
                    CONTINUE;
                END IF;
                v_stop_id := NULLIF((v_stop->>'stopId'), '')::integer;
                IF COALESCE(v_stop_id, 0) > 0 THEN
                    UPDATE core.transport_stops
                    SET stop_name = v_stop->>'stopName',
                        monthly_fare = COALESCE((v_stop->>'monthlyFare')::numeric, 0),
                        display_order = COALESCE((v_stop->>'displayOrder')::integer, 0),
                        is_active = TRUE, updated_at = NOW()
                    WHERE stop_id = v_stop_id AND route_id = v_route_id;
                ELSE
                    INSERT INTO core.transport_stops
                        (route_id, tenant_id, school_id, stop_name, monthly_fare, display_order)
                    VALUES
                        (v_route_id, p_tenant_id, p_school_id, v_stop->>'stopName',
                         COALESCE((v_stop->>'monthlyFare')::numeric, 0),
                         COALESCE((v_stop->>'displayOrder')::integer, 0))
                    RETURNING stop_id INTO v_stop_id;
                END IF;
                v_keep := array_append(v_keep, v_stop_id);
            END LOOP;
        END IF;

        UPDATE core.transport_stops
        SET is_active = FALSE, updated_at = NOW()
        WHERE route_id = v_route_id AND NOT (stop_id = ANY(v_keep));

        OPEN p_result FOR SELECT TRUE AS success, 'Route saved.' AS message, v_route_id AS route_id;

    ELSIF p_operation = 'DeleteRoute' THEN
        UPDATE core.transport_routes
        SET is_deleted = TRUE, is_active = FALSE, updated_by = p_action_user_id, updated_at = NOW()
        WHERE route_id = p_route_id AND tenant_id = p_tenant_id AND school_id = p_school_id;
        OPEN p_result FOR SELECT TRUE AS success, 'Route deleted.' AS message;

    ELSIF p_operation = 'ToggleRouteStatus' THEN
        UPDATE core.transport_routes
        SET is_active = NOT is_active, updated_by = p_action_user_id, updated_at = NOW()
        WHERE route_id = p_route_id AND tenant_id = p_tenant_id AND school_id = p_school_id;
        OPEN p_result FOR SELECT TRUE AS success, 'Route status updated.' AS message;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;

-- ── Vehicles manage ─────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE core.sp_transport_vehicle_manage(
    IN    p_operation      varchar,
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_vehicle_id     integer  DEFAULT NULL,
    IN    p_vehicle_no     varchar  DEFAULT NULL,
    IN    p_capacity       integer  DEFAULT NULL,
    IN    p_driver_name    varchar  DEFAULT NULL,
    IN    p_driver_phone   varchar  DEFAULT NULL,
    IN    p_route_id       integer  DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    IF p_operation = 'GetVehicles' THEN
        OPEN p_result FOR
        SELECT v.vehicle_id, v.vehicle_no, v.capacity, v.driver_name, v.driver_phone,
               v.route_id, r.route_name, v.is_active
        FROM core.transport_vehicles v
        LEFT JOIN core.transport_routes r ON r.route_id = v.route_id
        WHERE v.tenant_id = p_tenant_id AND v.school_id = p_school_id
          AND COALESCE(v.is_deleted, FALSE) = FALSE
        ORDER BY v.vehicle_no;

    ELSIF p_operation = 'SaveVehicle' THEN
        IF COALESCE(NULLIF(trim(p_vehicle_no), ''), '') = '' THEN
            RAISE EXCEPTION 'Vehicle number is required.';
        END IF;
        IF COALESCE(p_vehicle_id, 0) > 0 THEN
            UPDATE core.transport_vehicles
            SET vehicle_no = p_vehicle_no, capacity = p_capacity,
                driver_name = p_driver_name, driver_phone = p_driver_phone,
                route_id = NULLIF(COALESCE(p_route_id, 0), 0),
                updated_by = p_action_user_id, updated_at = NOW()
            WHERE vehicle_id = p_vehicle_id AND tenant_id = p_tenant_id AND school_id = p_school_id;
        ELSE
            INSERT INTO core.transport_vehicles
                (tenant_id, school_id, vehicle_no, capacity, driver_name, driver_phone, route_id, created_by)
            VALUES
                (p_tenant_id, p_school_id, p_vehicle_no, p_capacity, p_driver_name, p_driver_phone,
                 NULLIF(COALESCE(p_route_id, 0), 0), p_action_user_id);
        END IF;
        OPEN p_result FOR SELECT TRUE AS success, 'Vehicle saved.' AS message;

    ELSIF p_operation = 'DeleteVehicle' THEN
        UPDATE core.transport_vehicles
        SET is_deleted = TRUE, is_active = FALSE, updated_by = p_action_user_id, updated_at = NOW()
        WHERE vehicle_id = p_vehicle_id AND tenant_id = p_tenant_id AND school_id = p_school_id;
        OPEN p_result FOR SELECT TRUE AS success, 'Vehicle deleted.' AS message;

    ELSIF p_operation = 'ToggleVehicleStatus' THEN
        UPDATE core.transport_vehicles
        SET is_active = NOT is_active, updated_by = p_action_user_id, updated_at = NOW()
        WHERE vehicle_id = p_vehicle_id AND tenant_id = p_tenant_id AND school_id = p_school_id;
        OPEN p_result FOR SELECT TRUE AS success, 'Vehicle status updated.' AS message;

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
    SELECT r.route_id, r.route_name, s.stop_id, s.stop_name, s.monthly_fare
    FROM core.transport_routes r
    JOIN core.transport_stops s ON s.route_id = r.route_id AND s.is_active = TRUE
    WHERE r.tenant_id = p_tenant_id AND r.school_id = p_school_id
      AND r.is_active = TRUE AND COALESCE(r.is_deleted, FALSE) = FALSE
    ORDER BY r.route_name, s.display_order, s.stop_id;
END;
$procedure$;

-- ── Student assignment (snapshots fare + generates monthly transport dues) ──
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
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR p_student_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;

    IF p_operation = 'GetForStudent' THEN
        OPEN p_result FOR
        SELECT a.assignment_id, a.route_id, a.stop_id, a.monthly_fare, a.start_date,
               r.route_name, s.stop_name
        FROM core.student_transport a
        LEFT JOIN core.transport_routes r ON r.route_id = a.route_id
        LEFT JOIN core.transport_stops  s ON s.stop_id  = a.stop_id
        WHERE a.student_id = p_student_id AND a.tenant_id = p_tenant_id AND a.school_id = p_school_id
          AND a.is_active = TRUE AND COALESCE(a.is_deleted, FALSE) = FALSE
        ORDER BY a.assignment_id DESC
        LIMIT 1;

    ELSIF p_operation = 'SaveAssignment' THEN
        SELECT monthly_fare, stop_name INTO v_fare, v_stop_name
        FROM core.transport_stops
        WHERE stop_id = p_stop_id AND route_id = p_route_id
          AND tenant_id = p_tenant_id AND school_id = p_school_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Selected stop not found.';
        END IF;

        v_start := COALESCE(p_start_date, CURRENT_DATE);

        -- Replace any current assignment + remove its FUTURE unpaid transport dues,
        -- so re-assigning (changed stop/fare) re-bills cleanly without touching
        -- months already paid.
        UPDATE core.student_transport
        SET is_active = FALSE, is_deleted = TRUE, updated_by = p_action_user_id, updated_at = NOW()
        WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
          AND is_active = TRUE;

        DELETE FROM core.student_ledger
        WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
          AND fee_head_name = 'Transport Fee'
          AND amount_paid = 0 AND concession = 0
          AND due_date >= DATE_TRUNC('month', v_start)::date;

        INSERT INTO core.student_transport
            (tenant_id, school_id, student_id, route_id, stop_id, monthly_fare,
             academic_year, start_date, created_by)
        VALUES
            (p_tenant_id, p_school_id, p_student_id, p_route_id, p_stop_id, v_fare,
             p_academic_year, v_start, p_action_user_id);

        -- Generate monthly 'Transport Fee' dues (skip a month if one already exists).
        v_month_start := DATE_TRUNC('month', v_start)::date;
        FOR v_i IN 0 .. GREATEST(COALESCE(p_months, 12), 1) - 1 LOOP
            IF NOT EXISTS (
                SELECT 1 FROM core.student_ledger
                WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
                  AND fee_head_name = 'Transport Fee'
                  AND due_date = (v_month_start + (v_i || ' month')::interval)::date
            ) THEN
                INSERT INTO core.student_ledger
                    (tenant_id, school_id, student_id, fee_head_name, frequency,
                     installment_label, due_date, amount_due, status)
                VALUES
                    (p_tenant_id, p_school_id, p_student_id, 'Transport Fee', 'Monthly',
                     TO_CHAR(v_month_start + (v_i || ' month')::interval, 'Mon YYYY'),
                     (v_month_start + (v_i || ' month')::interval)::date, v_fare, 'Pending');
                v_made := v_made + 1;
            END IF;
        END LOOP;

        OPEN p_result FOR
        SELECT TRUE AS success,
               'Transport assigned. ' || v_made || ' monthly due(s) generated.' AS message,
               v_fare AS monthly_fare, v_made AS months_generated;

    ELSIF p_operation = 'RemoveAssignment' THEN
        UPDATE core.student_transport
        SET is_active = FALSE, is_deleted = TRUE, updated_by = p_action_user_id, updated_at = NOW()
        WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
          AND is_active = TRUE;

        -- Drop future unpaid transport dues; keep paid history intact.
        DELETE FROM core.student_ledger
        WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
          AND fee_head_name = 'Transport Fee'
          AND amount_paid = 0 AND concession = 0
          AND due_date >= DATE_TRUNC('month', CURRENT_DATE)::date;

        OPEN p_result FOR SELECT TRUE AS success, 'Transport removed.' AS message;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;
