-- ============================================================================
-- SCHOOL ARCHIVE + PURGE — permanently delete a school and all of its data.
--
-- WHY TWO PROCEDURES, NOT ONE
-- core.sp_school_archive is READ-ONLY and returns the school's entire data set as
-- JSON. core.sp_school_purge deletes. The caller runs archive first, writes the
-- file to disk, and only calls purge once that file exists. One combined proc
-- would mean a failed file write leaves the data already gone.
--
-- GUARDS ON PURGE (all enforced here, not just in the UI)
--   1. platform caller only (p_tenant_id = 1)
--   2. the school must already be CLOSED — closing is a separate, reversible act,
--      so purging always takes two deliberate steps
--   3. p_confirm_name must match the school name exactly
-- Any of these failing raises, and the whole thing rolls back.
--
-- COMPLETENESS IS SELF-CHECKED
-- The delete list below is explicit and ordered for foreign keys. After deleting,
-- the proc re-scans EVERY table in core/academic that has a school_id column and
-- raises if any row survived. So if someone adds a school-scoped table later and
-- forgets this proc, the purge FAILS LOUDLY and rolls back rather than silently
-- leaving orphans. That check is the actual guarantee — the list is just the plan.
--
-- core.fee_payment_details and core.fee_payment_tenders have no school_id but
-- cascade from core.fee_payments, so they need no explicit delete.
-- ============================================================================

-- ── ARCHIVE (read-only) ────────────────────────────────────────────────────
-- Built dynamically on purpose: it picks up any school-scoped table automatically,
-- so the archive can never fall behind the schema the way a hand-written list would.
CREATE OR REPLACE PROCEDURE core.sp_school_archive(
    IN p_tenant_id integer,
    IN p_school_id integer,
    INOUT p_result refcursor DEFAULT 'archive_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    r        record;
    v_json   jsonb;
    v_out    jsonb := '{}'::jsonb;
    v_rows   bigint;
    v_total  bigint := 0;
BEGIN
    IF p_tenant_id <> 1 THEN
        RAISE EXCEPTION 'Only the platform super admin can archive a school.';
    END IF;

    FOR r IN
        SELECT c.table_schema AS sch, c.table_name AS tbl
        FROM information_schema.columns c
        JOIN information_schema.tables t
          ON t.table_schema = c.table_schema AND t.table_name = c.table_name
         AND t.table_type = 'BASE TABLE'
        -- config is included: config.roles, config.role_permissions and
        -- config.lookup_value all carry a school_id for per-school overrides.
        -- Leaving it out was a real hole — purging a school stranded its role rows.
        WHERE c.column_name = 'school_id'
          AND c.table_schema IN ('core', 'academic', 'config')
        ORDER BY 1, 2
    LOOP
        EXECUTE format('SELECT COALESCE(jsonb_agg(to_jsonb(x)), ''[]''::jsonb), count(*) FROM %I.%I x WHERE x.school_id = $1',
                       r.sch, r.tbl)
        INTO v_json, v_rows
        USING p_school_id;

        IF v_rows > 0 THEN
            v_out := v_out || jsonb_build_object(r.sch || '.' || r.tbl, v_json);
            v_total := v_total + v_rows;
        END IF;
    END LOOP;

    OPEN p_result FOR
    SELECT
        p_school_id                                   AS school_id,
        (SELECT school_code FROM core.schools WHERE school_id = p_school_id) AS school_code,
        (SELECT school_name FROM core.schools WHERE school_id = p_school_id) AS school_name,
        v_total                                       AS total_rows,
        jsonb_pretty(
            jsonb_build_object(
                'archived_at', to_char(NOW(), 'YYYY-MM-DD"T"HH24:MI:SS'),
                'school_id',   p_school_id,
                'data',        v_out
            )
        )                                             AS archive_json;
END;
$procedure$;

-- ── PURGE (destructive) ────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE core.sp_school_purge(
    IN p_tenant_id integer,
    IN p_school_id integer,
    IN p_action_user_id integer,
    IN p_confirm_name character varying,
    INOUT p_result refcursor DEFAULT 'purge_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_school_tenant integer;
    v_name          character varying;
    v_code          character varying;
    v_status        character varying;
    r               record;
    v_left          bigint;
BEGIN
    IF p_tenant_id <> 1 THEN
        RAISE EXCEPTION 'Only the platform super admin can purge a school.';
    END IF;

    SELECT s.tenant_id, s.school_name, s.school_code, COALESCE(st.status_code, 'UNKNOWN')
      INTO v_school_tenant, v_name, v_code, v_status
    FROM core.schools s
    LEFT JOIN config.school_statuses st ON st.school_status_id = s.status_id
    WHERE s.school_id = p_school_id;

    IF v_name IS NULL THEN
        RAISE EXCEPTION 'School not found.';
    END IF;

    -- Two deliberate steps: close first (reversible), purge second (not).
    IF v_status <> 'CLOSED' THEN
        RAISE EXCEPTION 'Only a Closed school can be purged. Set the status to Closed first.';
    END IF;

    IF p_confirm_name IS NULL OR TRIM(p_confirm_name) <> TRIM(v_name) THEN
        RAISE EXCEPTION 'Confirmation name does not match the school name.';
    END IF;

    -- Audit BEFORE the delete: admin_activity_logs is itself school-scoped, so a row
    -- written here would be wiped below. Logged against the platform tenant instead,
    -- with no school_id, so the record outlives the school.
    INSERT INTO core.admin_activity_logs
        (tenant_id, user_id, school_id, action, module_name, table_name, record_id, description, created_by, created_at)
    VALUES
        (1, p_action_user_id, NULL, 'SCHOOL_PURGE', 'SuperAdmin/Schools', 'core.schools', p_school_id,
         format('Permanently purged school %s (%s), tenant %s', v_code, v_name, v_school_tenant),
         p_action_user_id, NOW());

    -- ── Deletes, ordered so no foreign key is violated ─────────────────────
    -- academic: timetable and class_subjects reference sections/classes/subjects
    DELETE FROM academic.timetable                 WHERE school_id = p_school_id;
    DELETE FROM academic.class_subjects            WHERE school_id = p_school_id;
    DELETE FROM academic.period_structure          WHERE school_id = p_school_id;
    DELETE FROM academic.school_calendar           WHERE school_id = p_school_id;
    DELETE FROM academic.school_calendar_settings  WHERE school_id = p_school_id;
    DELETE FROM academic.academic_class_sections   WHERE school_id = p_school_id;
    DELETE FROM academic.academic_classes          WHERE school_id = p_school_id;
    DELETE FROM academic.school_subjects           WHERE school_id = p_school_id;
    DELETE FROM academic.academic_years            WHERE school_id = p_school_id;

    -- student-linked data before students
    DELETE FROM core.student_attendance            WHERE school_id = p_school_id;
    DELETE FROM core.student_transport             WHERE school_id = p_school_id;
    DELETE FROM core.student_advance               WHERE school_id = p_school_id;
    DELETE FROM core.student_fee_plan              WHERE school_id = p_school_id;
    DELETE FROM core.student_ledger                WHERE school_id = p_school_id;
    DELETE FROM core.tc_register                   WHERE school_id = p_school_id;
    DELETE FROM core.tc_counters                   WHERE school_id = p_school_id;
    DELETE FROM core.students                      WHERE school_id = p_school_id;

    -- enquiries (children cascade, deleted explicitly for clarity)
    DELETE FROM core.enquiry_followups             WHERE school_id = p_school_id;
    DELETE FROM core.enquiry_status_history        WHERE school_id = p_school_id;
    DELETE FROM core.enquiries                     WHERE school_id = p_school_id;

    -- money: fee_payment_details / _tenders cascade from fee_payments
    DELETE FROM core.fee_refunds                   WHERE school_id = p_school_id;
    DELETE FROM core.fee_reminder_log              WHERE school_id = p_school_id;
    DELETE FROM core.fee_day_close                 WHERE school_id = p_school_id;
    DELETE FROM core.fee_payments                  WHERE school_id = p_school_id;
    DELETE FROM core.school_fee_structure_details  WHERE school_id = p_school_id;
    DELETE FROM core.school_fee_structures         WHERE school_id = p_school_id;
    DELETE FROM core.school_fee_heads              WHERE school_id = p_school_id;

    -- counters / audit trails
    DELETE FROM core.admission_audit               WHERE school_id = p_school_id;
    DELETE FROM core.admission_counters            WHERE school_id = p_school_id;
    DELETE FROM core.registration_counters         WHERE school_id = p_school_id;
    DELETE FROM core.receipt_counters              WHERE school_id = p_school_id;

    -- transport: vehicles reference routes and staff (SET NULL), stops cascade
    DELETE FROM core.transport_stops               WHERE school_id = p_school_id;
    DELETE FROM core.transport_vehicles            WHERE school_id = p_school_id;
    DELETE FROM core.transport_routes              WHERE school_id = p_school_id;

    -- school configuration
    DELETE FROM core.school_documents              WHERE school_id = p_school_id;
    DELETE FROM core.school_working_hours          WHERE school_id = p_school_id;
    DELETE FROM core.school_admission_workflow_settings WHERE school_id = p_school_id;
    DELETE FROM core.school_settings               WHERE school_id = p_school_id;
    DELETE FROM core.school_contacts               WHERE school_id = p_school_id;
    DELETE FROM core.school_addresses              WHERE school_id = p_school_id;
    DELETE FROM core.school_profiles               WHERE school_id = p_school_id;

    -- people: staff references users, so staff first
    DELETE FROM core.admin_activity_logs           WHERE school_id = p_school_id;
    DELETE FROM core.login_attempts                WHERE school_id = p_school_id;
    DELETE FROM core.password_reset_tokens         WHERE school_id = p_school_id;
    DELETE FROM core.user_sessions                 WHERE school_id = p_school_id;
    DELETE FROM core.user_roles                    WHERE school_id = p_school_id;
    DELETE FROM core.user_profiles                 WHERE school_id = p_school_id;
    DELETE FROM core.staff                         WHERE school_id = p_school_id;
    DELETE FROM core.users                         WHERE school_id = p_school_id;

    -- config: per-school overrides. Only rows carrying THIS school's id go — the
    -- tenant-level rows (school_id NULL) and platform defaults (school_id 0) are
    -- shared and must survive. config.roles in particular holds a school's own
    -- role rows, which login joins on.
    DELETE FROM config.role_permissions            WHERE school_id = p_school_id;
    DELETE FROM config.roles                       WHERE school_id = p_school_id;
    DELETE FROM config.lookup_value                WHERE school_id = p_school_id;

    -- and finally the school itself
    DELETE FROM core.schools                       WHERE school_id = p_school_id;

    -- ── Completeness check ─────────────────────────────────────────────────
    -- Re-scan every school-scoped table. Anything left means the list above is out
    -- of date, so fail and roll the whole purge back rather than leave orphans.
    FOR r IN
        SELECT c.table_schema AS sch, c.table_name AS tbl
        FROM information_schema.columns c
        JOIN information_schema.tables t
          ON t.table_schema = c.table_schema AND t.table_name = c.table_name
         AND t.table_type = 'BASE TABLE'
        -- config is included: config.roles, config.role_permissions and
        -- config.lookup_value all carry a school_id for per-school overrides.
        -- Leaving it out was a real hole — purging a school stranded its role rows.
        WHERE c.column_name = 'school_id'
          AND c.table_schema IN ('core', 'academic', 'config')
    LOOP
        EXECUTE format('SELECT count(*) FROM %I.%I WHERE school_id = $1', r.sch, r.tbl)
        INTO v_left USING p_school_id;

        IF v_left > 0 THEN
            RAISE EXCEPTION
                'Purge incomplete: % row(s) remain in %.%. Add it to core.sp_school_purge.',
                v_left, r.sch, r.tbl;
        END IF;
    END LOOP;

    OPEN p_result FOR
    SELECT p_school_id AS school_id, v_code AS school_code, v_name AS school_name;
END;
$procedure$;
