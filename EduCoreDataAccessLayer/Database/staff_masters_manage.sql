-- ============================================================================
-- staff_masters_manage.sql
--
-- CRUD for the two Staff reference masters a school edits itself:
--   config.departments   (name + order)
--   config.designations  (name + staff_type bucket + default_department)
--
-- These feed the Add/Edit Staff dropdowns (config.sp_staff_dropdowns) and the
-- designation -> staff_type / default_department auto-fill. Seeded in
-- staff_hr_module.sql; this file lets a school add / edit / reorder / retire
-- entries without a developer.
--
-- Both tables are TENANT-scoped (no school_id); school_id is accepted only for
-- the standard scope guard. Deletes are soft (is_deleted = TRUE) and blocked
-- when the entry is still assigned to a live staff member.
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- Suggested login role for a designation (RBAC config.roles). When a staff
-- member with this designation is given a login, this role is pre-ticked on the
-- form (editable). NULL = no suggestion.
ALTER TABLE config.designations ADD COLUMN IF NOT EXISTS default_role_id integer;

-- ── List both masters (one round-trip, two cursors) ─────────────────────────
CREATE OR REPLACE PROCEDURE config.sp_staff_masters_list(
    IN    p_tenant_id    integer,
    IN    p_school_id    integer,
    INOUT p_departments  refcursor DEFAULT 'departments_cursor',
    INOUT p_designations refcursor DEFAULT 'designations_cursor'
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    OPEN p_departments FOR
    SELECT department_id, name, sort_order, is_active
    FROM   config.departments
    WHERE  tenant_id = p_tenant_id AND COALESCE(is_deleted, FALSE) = FALSE
    ORDER BY sort_order, name;

    OPEN p_designations FOR
    SELECT designation_id, name, staff_type, default_department, default_role_id, sort_order, is_active
    FROM   config.designations
    WHERE  tenant_id = p_tenant_id AND COALESCE(is_deleted, FALSE) = FALSE
    ORDER BY sort_order, name;
END;
$procedure$;

-- ── Save / Delete / Toggle a department or designation ──────────────────────
-- Operations: SaveDepartment | SaveDesignation | DeleteDepartment |
--             DeleteDesignation | ToggleDepartment | ToggleDesignation
-- Old signature dropped so the default_role_id param can be added cleanly.
DROP PROCEDURE IF EXISTS config.sp_staff_masters_manage(
    text, integer, integer, integer, integer, text, text, text, integer, refcursor);

CREATE OR REPLACE PROCEDURE config.sp_staff_masters_manage(
    IN    p_operation          text,
    IN    p_tenant_id          integer,
    IN    p_school_id          integer,
    IN    p_action_user_id     integer,
    IN    p_id                 integer DEFAULT NULL,
    IN    p_name               text    DEFAULT NULL,
    IN    p_staff_type         text    DEFAULT NULL,
    IN    p_default_department  text    DEFAULT NULL,
    IN    p_sort_order         integer DEFAULT 0,
    IN    p_default_role_id    integer DEFAULT NULL,
    INOUT p_result             refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_name        text := NULLIF(TRIM(p_name), '');
    v_staff_type  text;
    v_target_name text;
    v_id          integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    -- ─────────────────────────────── DEPARTMENTS ───────────────────────────
    IF p_operation = 'SaveDepartment' THEN
        IF v_name IS NULL THEN
            RAISE EXCEPTION 'Department name is required.';
        END IF;
        -- Unique per tenant (case-insensitive), ignoring the row being edited.
        IF EXISTS (SELECT 1 FROM config.departments
                   WHERE tenant_id = p_tenant_id AND COALESCE(is_deleted, FALSE) = FALSE
                     AND LOWER(name) = LOWER(v_name)
                     AND (COALESCE(p_id, 0) = 0 OR department_id <> p_id)) THEN
            RAISE EXCEPTION 'A department named "%" already exists.', v_name;
        END IF;

        IF COALESCE(p_id, 0) > 0 THEN
            UPDATE config.departments
            SET name = v_name, sort_order = COALESCE(p_sort_order, sort_order),
                updated_by = p_action_user_id, updated_at = NOW()
            WHERE department_id = p_id AND tenant_id = p_tenant_id
            RETURNING department_id INTO v_id;
        ELSE
            INSERT INTO config.departments (tenant_id, name, sort_order, created_by)
            VALUES (p_tenant_id, v_name, COALESCE(p_sort_order, 0), p_action_user_id)
            RETURNING department_id INTO v_id;
        END IF;
        OPEN p_result FOR SELECT TRUE AS success, 'Department saved.' AS message, v_id AS id;
        RETURN;

    ELSIF p_operation = 'DeleteDepartment' THEN
        SELECT name INTO v_target_name FROM config.departments
        WHERE department_id = p_id AND tenant_id = p_tenant_id;

        IF EXISTS (SELECT 1 FROM core.staff
                   WHERE tenant_id = p_tenant_id AND COALESCE(is_deleted, FALSE) = FALSE
                     AND LOWER(TRIM(department)) = LOWER(TRIM(v_target_name))) THEN
            RAISE EXCEPTION 'This department is assigned to staff and cannot be deleted. Reassign them first.';
        END IF;

        UPDATE config.departments
        SET is_deleted = TRUE, is_active = FALSE, updated_by = p_action_user_id, updated_at = NOW()
        WHERE department_id = p_id AND tenant_id = p_tenant_id;
        OPEN p_result FOR SELECT TRUE AS success, 'Department deleted.' AS message;
        RETURN;

    ELSIF p_operation = 'ToggleDepartment' THEN
        UPDATE config.departments
        SET is_active = NOT is_active, updated_by = p_action_user_id, updated_at = NOW()
        WHERE department_id = p_id AND tenant_id = p_tenant_id;
        OPEN p_result FOR SELECT TRUE AS success, 'Department status updated.' AS message;
        RETURN;

    -- ─────────────────────────────── DESIGNATIONS ──────────────────────────
    ELSIF p_operation = 'SaveDesignation' THEN
        IF v_name IS NULL THEN
            RAISE EXCEPTION 'Designation name is required.';
        END IF;
        v_staff_type := COALESCE(NULLIF(TRIM(p_staff_type), ''), 'Non-Teaching');
        IF v_staff_type NOT IN ('Teaching', 'Non-Teaching', 'Transport', 'Support') THEN
            RAISE EXCEPTION 'Invalid staff type.';
        END IF;
        IF EXISTS (SELECT 1 FROM config.designations
                   WHERE tenant_id = p_tenant_id AND COALESCE(is_deleted, FALSE) = FALSE
                     AND LOWER(name) = LOWER(v_name)
                     AND (COALESCE(p_id, 0) = 0 OR designation_id <> p_id)) THEN
            RAISE EXCEPTION 'A designation named "%" already exists.', v_name;
        END IF;

        IF COALESCE(p_id, 0) > 0 THEN
            UPDATE config.designations
            SET name = v_name, staff_type = v_staff_type,
                default_department = NULLIF(TRIM(p_default_department), ''),
                default_role_id = NULLIF(COALESCE(p_default_role_id, 0), 0),
                sort_order = COALESCE(p_sort_order, sort_order),
                updated_by = p_action_user_id, updated_at = NOW()
            WHERE designation_id = p_id AND tenant_id = p_tenant_id
            RETURNING designation_id INTO v_id;
        ELSE
            INSERT INTO config.designations
                (tenant_id, name, staff_type, default_department, default_role_id, sort_order, created_by)
            VALUES
                (p_tenant_id, v_name, v_staff_type, NULLIF(TRIM(p_default_department), ''),
                 NULLIF(COALESCE(p_default_role_id, 0), 0), COALESCE(p_sort_order, 0), p_action_user_id)
            RETURNING designation_id INTO v_id;
        END IF;
        OPEN p_result FOR SELECT TRUE AS success, 'Designation saved.' AS message, v_id AS id;
        RETURN;

    ELSIF p_operation = 'DeleteDesignation' THEN
        SELECT name INTO v_target_name FROM config.designations
        WHERE designation_id = p_id AND tenant_id = p_tenant_id;

        IF EXISTS (SELECT 1 FROM core.staff
                   WHERE tenant_id = p_tenant_id AND COALESCE(is_deleted, FALSE) = FALSE
                     AND LOWER(TRIM(designation)) = LOWER(TRIM(v_target_name))) THEN
            RAISE EXCEPTION 'This designation is assigned to staff and cannot be deleted. Reassign them first.';
        END IF;

        UPDATE config.designations
        SET is_deleted = TRUE, is_active = FALSE, updated_by = p_action_user_id, updated_at = NOW()
        WHERE designation_id = p_id AND tenant_id = p_tenant_id;
        OPEN p_result FOR SELECT TRUE AS success, 'Designation deleted.' AS message;
        RETURN;

    ELSIF p_operation = 'ToggleDesignation' THEN
        UPDATE config.designations
        SET is_active = NOT is_active, updated_by = p_action_user_id, updated_at = NOW()
        WHERE designation_id = p_id AND tenant_id = p_tenant_id;
        OPEN p_result FOR SELECT TRUE AS success, 'Designation status updated.' AS message;
        RETURN;

    END IF;

    RAISE EXCEPTION 'Unknown operation: %', p_operation;
END;
$procedure$;
