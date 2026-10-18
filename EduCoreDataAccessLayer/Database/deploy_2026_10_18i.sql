-- Bundle 2026-10-18i: WhatsApp per school (Super Admin switch) and the message log; school purge covers them. Run with:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_18i.sql
-- Sources: messaging.sql, school_purge.sql

-- ===== messaging.sql =====
-- ============================================================================
-- WhatsApp messages to parents: who may send, and a record of every message.
--
-- The platform (SmartSchoolWala) has ONE WhatsApp Business account; its keys
-- live in the app's settings (Notifications:WhatsApp), never in the database.
-- The Super Admin switches WhatsApp on per school (core.school_messaging), since
-- every message costs money. Off by default.
--
-- Every message the app tries to send is written to core.message_log, sent or
-- not: Sent (the provider took it), Failed (with the provider's reason), Test
-- (the platform account is not connected yet: the message was built and shown,
-- nothing left the building), NoPhone (the child has no mobile number).
--
--   core.fn_whatsapp_on(tenant, school)
--   core.sp_school_messaging  Get | Save        (Super Admin only)
--   core.sp_message_log       Add | List | Summary
--
-- Re-runnable.
-- ============================================================================

CREATE TABLE IF NOT EXISTS core.school_messaging (
    tenant_id   integer NOT NULL,
    school_id   integer NOT NULL,
    whatsapp_on boolean NOT NULL DEFAULT FALSE,
    updated_by  integer,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pk_school_messaging PRIMARY KEY (tenant_id, school_id)
);

CREATE TABLE IF NOT EXISTS core.message_log (
    log_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id    integer NOT NULL,
    school_id    integer NOT NULL,
    channel      varchar(20) NOT NULL DEFAULT 'WhatsApp',
    alert_type   varchar(20) NOT NULL,          -- Absent | FeeDue | Notice
    student_id   integer,
    to_name      varchar(150),
    to_phone     varchar(20),
    message_text text,                          -- what the parent reads (template filled in)
    template     varchar(80),
    status       varchar(10) NOT NULL,          -- Sent | Failed | Test | NoPhone
    provider_ref varchar(120),                  -- the provider's message id
    error        varchar(300),
    created_by   integer NOT NULL DEFAULT 0,
    created_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT chk_message_log_scope  CHECK (tenant_id > 1 AND school_id > 0),
    CONSTRAINT chk_message_log_status CHECK (status IN ('Sent', 'Failed', 'Test', 'NoPhone'))
);
CREATE INDEX IF NOT EXISTS ix_message_log_school ON core.message_log (tenant_id, school_id, created_at DESC);


CREATE OR REPLACE FUNCTION core.fn_whatsapp_on(p_tenant_id integer, p_school_id integer)
RETURNS boolean LANGUAGE sql STABLE AS $fn$
    SELECT COALESCE((SELECT m.whatsapp_on FROM core.school_messaging m
                      WHERE m.tenant_id = p_tenant_id AND m.school_id = p_school_id), FALSE);
$fn$;


-- Super Admin: is WhatsApp on for a school (Get), switch it (Save).
CREATE OR REPLACE PROCEDURE core.sp_school_messaging(
    IN    p_operation      text,          -- Get | Save
    IN    p_action_user_id integer,
    IN    p_school_id      integer,
    IN    p_whatsapp_on    boolean DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'school_messaging_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_tenant integer;
BEGIN
    IF NOT core.fn_is_super_admin(p_action_user_id) THEN
        RAISE EXCEPTION 'Only the Super Admin can switch WhatsApp for a school.';
    END IF;
    SELECT tenant_id INTO v_tenant FROM core.schools WHERE school_id = p_school_id AND NOT COALESCE(is_deleted, FALSE);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'School not found.';
    END IF;

    IF p_operation = 'Save' THEN
        INSERT INTO core.school_messaging (tenant_id, school_id, whatsapp_on, updated_by)
        VALUES (v_tenant, p_school_id, COALESCE(p_whatsapp_on, FALSE), p_action_user_id)
        ON CONFLICT (tenant_id, school_id)
        DO UPDATE SET whatsapp_on = EXCLUDED.whatsapp_on, updated_by = EXCLUDED.updated_by, updated_at = now();
    ELSIF p_operation <> 'Get' THEN
        RAISE EXCEPTION 'Unknown operation %.', p_operation;
    END IF;

    OPEN p_result FOR
    SELECT core.fn_whatsapp_on(v_tenant, p_school_id) AS whatsapp_on,
           (SELECT COUNT(*) FROM core.message_log l
             WHERE l.tenant_id = v_tenant AND l.school_id = p_school_id AND l.status = 'Sent'
               AND l.created_at >= date_trunc('month', now()))::int AS sent_this_month;
END;
$procedure$;


CREATE OR REPLACE PROCEDURE core.sp_message_log(
    IN    p_operation      text,          -- Add | List | Summary
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_alert_type     varchar DEFAULT NULL,
    IN    p_student_id     integer DEFAULT NULL,
    IN    p_to_name        varchar DEFAULT NULL,
    IN    p_to_phone       varchar DEFAULT NULL,
    IN    p_message_text   text    DEFAULT NULL,
    IN    p_template       varchar DEFAULT NULL,
    IN    p_status         varchar DEFAULT NULL,
    IN    p_provider_ref   varchar DEFAULT NULL,
    IN    p_error          varchar DEFAULT NULL,
    IN    p_from           date    DEFAULT NULL,
    IN    p_to             date    DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'message_log_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_id bigint;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    IF p_operation = 'Add' THEN
        INSERT INTO core.message_log (tenant_id, school_id, alert_type, student_id, to_name, to_phone, message_text,
                                      template, status, provider_ref, error, created_by)
        VALUES (p_tenant_id, p_school_id, COALESCE(p_alert_type, 'Other'), p_student_id, left(p_to_name, 150),
                left(p_to_phone, 20), p_message_text, left(p_template, 80), p_status, left(p_provider_ref, 120),
                left(p_error, 300), p_action_user_id)
        RETURNING log_id INTO v_id;
        OPEN p_result FOR SELECT v_id AS log_id;
        RETURN;
    END IF;

    IF p_operation = 'List' THEN
        OPEN p_result FOR
        SELECT l.log_id, to_char(l.created_at, 'YYYY-MM-DD HH24:MI') AS sent_at, l.alert_type, l.to_name, l.to_phone,
               l.message_text, l.status, l.error, core.fn_user_display_name(l.created_by) AS sent_by
          FROM core.message_log l
         WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
           AND l.created_at::date BETWEEN COALESCE(p_from, CURRENT_DATE - 30) AND COALESCE(p_to, CURRENT_DATE)
           AND (NULLIF(p_alert_type, '') IS NULL OR l.alert_type = p_alert_type)
         ORDER BY l.log_id DESC
         LIMIT 1000;
        RETURN;
    END IF;

    IF p_operation = 'Summary' THEN
        OPEN p_result FOR
        SELECT COUNT(*) FILTER (WHERE status = 'Sent')    ::int AS sent,
               COUNT(*) FILTER (WHERE status = 'Failed')  ::int AS failed,
               COUNT(*) FILTER (WHERE status = 'Test')    ::int AS test,
               COUNT(*) FILTER (WHERE status = 'NoPhone') ::int AS no_phone
          FROM core.message_log
         WHERE tenant_id = p_tenant_id AND school_id = p_school_id
           AND created_at::date BETWEEN COALESCE(p_from, CURRENT_DATE - 30) AND COALESCE(p_to, CURRENT_DATE)
           AND (NULLIF(p_alert_type, '') IS NULL OR alert_type = p_alert_type);
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation %.', p_operation;
END;
$procedure$;

-- ===== school_purge.sql =====
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
--
-- Oct 2026 (platform_access_security_tests.sql):
--   * the delete list now covers the modules added after it was written -- exams,
--     inventory, staff leave/payroll, enrolment, promotion history, day-close log.
--     A school that had run exams could not be purged at all (FK on exam_subjects).
--     Also the attendance / exam-mark edit history (academics_edit_history.sql).
--   * 2026-10-10: the result publish log and the grade scale (exam_results_publish.sql).
--   * 2026-10-10: inventory locations, location stock, transfers and supplier
--     returns (inventory.sql, store locations revision).
--   * 2026-10-11: live bus tracking -- trip points, trips and parent share links
--     (transport_live_tracking.sql). The share link's token_hash is stripped from
--     the archive like every other token_hash.
--   * the archive no longer carries secrets: password_reset_tokens is skipped and
--     password_hash / token_hash are stripped from every row. The file sits on disk.
--   * purging a tenant's ONLY school keeps the tenant and its roles (decision D-7):
--     roles are tenant-level rows (school_id NULL), which this purge never touches.
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
          -- One-time reset codes are secrets with no archival value.
          AND NOT (c.table_schema = 'core' AND c.table_name = 'password_reset_tokens')
        ORDER BY 1, 2
    LOOP
        -- Secrets are stripped (password_hash, token_hash, user_sessions.refresh_token_hash):
        -- the archive is a file on disk.
        EXECUTE format('SELECT COALESCE(jsonb_agg(to_jsonb(x) - ''password_hash'' - ''token_hash'' - ''refresh_token_hash''), ''[]''::jsonb), count(*) FROM %I.%I x WHERE x.school_id = $1',
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
    -- exams reference classes and subjects; marks reference students
    DELETE FROM academic.exam_result_log           WHERE school_id = p_school_id;
    DELETE FROM academic.grade_scale               WHERE school_id = p_school_id;
    DELETE FROM academic.exam_marks_history        WHERE school_id = p_school_id;
    DELETE FROM academic.exam_marks                WHERE school_id = p_school_id;
    DELETE FROM academic.exam_mark_sheets          WHERE school_id = p_school_id;
    DELETE FROM academic.exam_class_sections       WHERE school_id = p_school_id;
    DELETE FROM academic.exam_subjects             WHERE school_id = p_school_id;
    DELETE FROM academic.exams                     WHERE school_id = p_school_id;

    DELETE FROM academic.timetable                 WHERE school_id = p_school_id;
    DELETE FROM academic.class_subjects            WHERE school_id = p_school_id;
    DELETE FROM academic.period_structure          WHERE school_id = p_school_id;
    DELETE FROM academic.school_calendar           WHERE school_id = p_school_id;
    DELETE FROM academic.school_calendar_settings  WHERE school_id = p_school_id;
    DELETE FROM academic.school_events             WHERE school_id = p_school_id;
    DELETE FROM academic.academic_class_sections   WHERE school_id = p_school_id;
    DELETE FROM academic.academic_classes          WHERE school_id = p_school_id;
    DELETE FROM academic.school_subjects           WHERE school_id = p_school_id;
    DELETE FROM academic.academic_years            WHERE school_id = p_school_id;

    -- student-linked data before students
    DELETE FROM core.student_attendance_history    WHERE school_id = p_school_id;
    DELETE FROM core.student_attendance            WHERE school_id = p_school_id;
    DELETE FROM core.student_transport             WHERE school_id = p_school_id;
    DELETE FROM core.student_advance               WHERE school_id = p_school_id;
    DELETE FROM core.student_fee_plan              WHERE school_id = p_school_id;
    -- books & uniform sold to students (inventory_student_sale.sql): before the students and items
    DELETE FROM core.inventory_student_sale_lines l USING core.inventory_student_sales sa
     WHERE l.sale_id = sa.sale_id AND sa.school_id = p_school_id;
    DELETE FROM core.inventory_student_sales       WHERE school_id = p_school_id;
    DELETE FROM core.inventory_class_kits          WHERE school_id = p_school_id;
    -- expenses and the cash book's opening balance (expense_cashbook.sql)
    DELETE FROM core.expenses                      WHERE school_id = p_school_id;
    DELETE FROM core.expense_categories            WHERE school_id = p_school_id;
    DELETE FROM core.cashbook_opening              WHERE school_id = p_school_id;
    -- WhatsApp switch and the message record (messaging.sql)
    DELETE FROM core.message_log                   WHERE school_id = p_school_id;
    DELETE FROM core.school_messaging              WHERE school_id = p_school_id;
    DELETE FROM core.student_ledger                WHERE school_id = p_school_id;
    DELETE FROM core.tc_register                   WHERE school_id = p_school_id;
    DELETE FROM core.tc_counters                   WHERE school_id = p_school_id;
    DELETE FROM core.student_enrolment             WHERE school_id = p_school_id;
    DELETE FROM core.student_promotion_history     WHERE school_id = p_school_id;
    DELETE FROM core.students                      WHERE school_id = p_school_id;

    -- enquiries (children cascade, deleted explicitly for clarity)
    DELETE FROM core.enquiry_followups             WHERE school_id = p_school_id;
    DELETE FROM core.enquiry_status_history        WHERE school_id = p_school_id;
    DELETE FROM core.enquiries                     WHERE school_id = p_school_id;

    -- money: fee_payment_details / _tenders cascade from fee_payments
    DELETE FROM core.fee_refunds                   WHERE school_id = p_school_id;
    DELETE FROM core.fee_reminder_log              WHERE school_id = p_school_id;
    DELETE FROM core.fee_day_close_log             WHERE school_id = p_school_id;
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

    -- transport: live tracking first (points -> trips -> vehicles/routes/staff,
    -- share links -> routes); vehicles reference routes and staff (SET NULL),
    -- stops cascade
    DELETE FROM core.transport_trip_points         WHERE school_id = p_school_id;
    DELETE FROM core.transport_trips               WHERE school_id = p_school_id;
    DELETE FROM core.transport_route_shares        WHERE school_id = p_school_id;
    DELETE FROM core.transport_stops               WHERE school_id = p_school_id;
    DELETE FROM core.transport_vehicles            WHERE school_id = p_school_id;
    DELETE FROM core.transport_routes              WHERE school_id = p_school_id;

    -- inventory: returns, transfers, location stock, purchase lines and the
    -- stock ledger reference items/purchases/locations, so they go first
    DELETE FROM core.inventory_purchase_returns    WHERE school_id = p_school_id;
    DELETE FROM core.inventory_transfers           WHERE school_id = p_school_id;
    DELETE FROM core.inventory_location_stock      WHERE school_id = p_school_id;
    DELETE FROM core.inventory_purchase_items      WHERE school_id = p_school_id;
    DELETE FROM core.inventory_stock_ledger        WHERE school_id = p_school_id;
    DELETE FROM core.inventory_purchases           WHERE school_id = p_school_id;
    DELETE FROM core.inventory_items               WHERE school_id = p_school_id;
    DELETE FROM core.inventory_locations           WHERE school_id = p_school_id;
    DELETE FROM core.inventory_suppliers           WHERE school_id = p_school_id;

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
    DELETE FROM core.staff_leave                   WHERE school_id = p_school_id;
    DELETE FROM core.staff_payroll_history         WHERE school_id = p_school_id;
    DELETE FROM core.staff_payroll_adjustment      WHERE school_id = p_school_id;
    DELETE FROM core.staff_payroll                 WHERE school_id = p_school_id;
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
