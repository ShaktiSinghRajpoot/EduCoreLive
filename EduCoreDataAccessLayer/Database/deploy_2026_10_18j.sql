-- Bundle 2026-10-18j: messaging -- sp_whatsapp_on for the app. Run with:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_18j.sql
-- Sources: messaging.sql

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


-- The school's switch for the app (any signed-in school user may ask).
CREATE OR REPLACE PROCEDURE core.sp_whatsapp_on(
    IN    p_tenant_id integer,
    IN    p_school_id integer,
    INOUT p_result    refcursor DEFAULT 'whatsapp_on_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    OPEN p_result FOR SELECT core.fn_whatsapp_on(p_tenant_id, p_school_id) AS whatsapp_on;
END;
$procedure$;
