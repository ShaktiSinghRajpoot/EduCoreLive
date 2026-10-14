-- ============================================================================
-- Front office (Front Office page): visitor book, phone call log, complaints.
--
--   core.fo_visitors    who came, to meet whom, why, time in / time out
--   core.fo_calls       incoming / outgoing calls with an optional follow-up date
--   core.fo_complaints  a complaint from a parent / student / staff member, who it
--                       is assigned to, its status (Open -> In progress -> Resolved)
--                       and how it was resolved
-- One proc, picked by p_operation:
--   Visitors | VisitorSave | VisitorOut | Calls | CallSave | CallDone |
--   Complaints | ComplaintSave | ComplaintStatus | Summary
-- Lists filter by a date range (visitors / calls) or by status (complaints).
-- Nothing is deleted: a visitor gets an out time, a call is marked followed up,
-- a complaint is resolved (or closed) with a note.
-- Re-runnable.
-- ============================================================================

CREATE TABLE IF NOT EXISTS core.fo_visitors (
    visitor_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id    integer      NOT NULL,
    school_id    integer      NOT NULL,
    visit_date   date         NOT NULL DEFAULT CURRENT_DATE,
    visitor_name varchar(120) NOT NULL,
    mobile       varchar(20),
    purpose      varchar(40)  NOT NULL,
    to_meet      varchar(120),
    persons      integer      NOT NULL DEFAULT 1,
    id_proof     varchar(60),
    note         varchar(300),
    time_in      timestamptz  NOT NULL DEFAULT now(),
    time_out     timestamptz,
    created_by   integer      NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_fo_visitors_day ON core.fo_visitors (tenant_id, school_id, visit_date DESC);

CREATE TABLE IF NOT EXISTS core.fo_calls (
    call_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id      integer      NOT NULL,
    school_id      integer      NOT NULL,
    call_date      date         NOT NULL DEFAULT CURRENT_DATE,
    direction      varchar(10)  NOT NULL CHECK (direction IN ('Incoming', 'Outgoing')),
    caller_name    varchar(120) NOT NULL,
    mobile         varchar(20),
    purpose        varchar(40)  NOT NULL,
    note           varchar(400),
    follow_up_on   date,
    followed_up_at timestamptz,
    followed_up_by integer,
    created_by     integer      NOT NULL,
    created_at     timestamptz  NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_fo_calls_day ON core.fo_calls (tenant_id, school_id, call_date DESC);

CREATE TABLE IF NOT EXISTS core.fo_complaints (
    complaint_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       integer      NOT NULL,
    school_id       integer      NOT NULL,
    complaint_no    varchar(20)  NOT NULL,
    raised_on       date         NOT NULL DEFAULT CURRENT_DATE,
    from_type       varchar(20)  NOT NULL,
    from_name       varchar(120) NOT NULL,
    mobile          varchar(20),
    about_student   varchar(150),
    category        varchar(30)  NOT NULL,
    description     varchar(1000) NOT NULL,
    assigned_to     varchar(120),
    status          varchar(15)  NOT NULL DEFAULT 'Open' CHECK (status IN ('Open', 'In progress', 'Resolved', 'Closed')),
    resolution      varchar(1000),
    resolved_at     timestamptz,
    resolved_by     integer,
    created_by      integer      NOT NULL,
    created_at      timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT uq_fo_complaint_no UNIQUE (tenant_id, school_id, complaint_no)
);


CREATE OR REPLACE PROCEDURE core.sp_front_office_manage(
    IN    p_operation      varchar,
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_id             integer DEFAULT NULL,
    IN    p_from           date    DEFAULT NULL,
    IN    p_to             date    DEFAULT NULL,
    IN    p_name           varchar DEFAULT NULL,
    IN    p_mobile         varchar DEFAULT NULL,
    IN    p_purpose        varchar DEFAULT NULL,    -- visitor / call purpose; complaint category
    IN    p_to_meet        varchar DEFAULT NULL,    -- visitor: whom; complaint: assigned to
    IN    p_persons        integer DEFAULT NULL,
    IN    p_id_proof       varchar DEFAULT NULL,
    IN    p_note           varchar DEFAULT NULL,    -- visitor / call note; complaint description; status note
    IN    p_direction      varchar DEFAULT NULL,    -- call: Incoming / Outgoing; complaint: from type
    IN    p_follow_up      date    DEFAULT NULL,
    IN    p_student        varchar DEFAULT NULL,    -- complaint: about which student
    IN    p_status         varchar DEFAULT NULL,    -- complaint list filter / new status
    INOUT p_result         refcursor DEFAULT 'front_office_cursor')
LANGUAGE plpgsql
AS $$
DECLARE
    v_from date := COALESCE(p_from, CURRENT_DATE);
    v_to   date := COALESCE(p_to, CURRENT_DATE);
    v_id   integer;
    v_no   varchar;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    -- ── counts for the page header
    IF p_operation = 'Summary' THEN
        OPEN p_result FOR
        SELECT (SELECT COUNT(*) FROM core.fo_visitors WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND visit_date = CURRENT_DATE)::int AS visitors_today,
               (SELECT COUNT(*) FROM core.fo_visitors WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND visit_date = CURRENT_DATE AND time_out IS NULL)::int AS inside_now,
               (SELECT COUNT(*) FROM core.fo_calls WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND call_date = CURRENT_DATE)::int AS calls_today,
               (SELECT COUNT(*) FROM core.fo_calls WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                   AND follow_up_on IS NOT NULL AND follow_up_on <= CURRENT_DATE AND followed_up_at IS NULL)::int AS follow_ups_due,
               (SELECT COUNT(*) FROM core.fo_complaints WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND status IN ('Open', 'In progress'))::int AS complaints_open;
        RETURN;
    END IF;

    -- ── visitors
    IF p_operation = 'Visitors' THEN
        OPEN p_result FOR
        SELECT v.visitor_id, to_char(v.visit_date, 'YYYY-MM-DD') AS visit_date, v.visitor_name, v.mobile, v.purpose, v.to_meet,
               v.persons, v.id_proof, v.note,
               to_char(v.time_in AT TIME ZONE 'Asia/Kolkata', 'HH12:MI AM') AS time_in,
               to_char(v.time_out AT TIME ZONE 'Asia/Kolkata', 'HH12:MI AM') AS time_out,
               core.fn_user_display_name(v.created_by) AS entered_by
          FROM core.fo_visitors v
         WHERE v.tenant_id = p_tenant_id AND v.school_id = p_school_id AND v.visit_date BETWEEN v_from AND v_to
         ORDER BY v.visit_date DESC, v.time_in DESC
         LIMIT 500;
        RETURN;
    END IF;

    IF p_operation = 'VisitorSave' THEN
        IF NULLIF(trim(p_name), '') IS NULL THEN RAISE EXCEPTION 'Write the visitor''s name.'; END IF;
        IF NULLIF(trim(p_purpose), '') IS NULL THEN RAISE EXCEPTION 'Choose the purpose of the visit.'; END IF;
        INSERT INTO core.fo_visitors (tenant_id, school_id, visitor_name, mobile, purpose, to_meet, persons, id_proof, note, created_by)
        VALUES (p_tenant_id, p_school_id, trim(p_name), NULLIF(trim(p_mobile), ''), trim(p_purpose), NULLIF(trim(p_to_meet), ''),
                GREATEST(COALESCE(p_persons, 1), 1), NULLIF(trim(p_id_proof), ''), NULLIF(trim(p_note), ''), p_action_user_id)
        RETURNING visitor_id INTO v_id;
        OPEN p_result FOR SELECT v_id AS id, 'Visitor entered.'::varchar AS message;
        RETURN;
    END IF;

    IF p_operation = 'VisitorOut' THEN
        UPDATE core.fo_visitors SET time_out = now()
         WHERE visitor_id = p_id AND tenant_id = p_tenant_id AND school_id = p_school_id AND time_out IS NULL
        RETURNING visitor_id INTO v_id;
        IF v_id IS NULL THEN RAISE EXCEPTION 'This visitor is already marked out.'; END IF;
        OPEN p_result FOR SELECT v_id AS id, 'Marked out.'::varchar AS message;
        RETURN;
    END IF;

    -- ── calls
    IF p_operation = 'Calls' THEN
        OPEN p_result FOR
        SELECT c.call_id, to_char(c.call_date, 'YYYY-MM-DD') AS call_date, c.direction, c.caller_name, c.mobile, c.purpose, c.note,
               to_char(c.follow_up_on, 'YYYY-MM-DD') AS follow_up_on,
               to_char(c.followed_up_at AT TIME ZONE 'Asia/Kolkata', 'DD Mon, HH12:MI AM') AS followed_up_at,
               to_char(c.created_at AT TIME ZONE 'Asia/Kolkata', 'HH12:MI AM') AS call_time,
               core.fn_user_display_name(c.created_by) AS entered_by
          FROM core.fo_calls c
         WHERE c.tenant_id = p_tenant_id AND c.school_id = p_school_id
           AND (c.call_date BETWEEN v_from AND v_to
                -- a pending follow-up stays on the list until it is done
                OR (c.follow_up_on IS NOT NULL AND c.followed_up_at IS NULL AND c.follow_up_on <= v_to))
         ORDER BY c.call_date DESC, c.created_at DESC
         LIMIT 500;
        RETURN;
    END IF;

    IF p_operation = 'CallSave' THEN
        IF NULLIF(trim(p_name), '') IS NULL THEN RAISE EXCEPTION 'Write who called or was called.'; END IF;
        IF COALESCE(p_direction, '') NOT IN ('Incoming', 'Outgoing') THEN RAISE EXCEPTION 'Choose incoming or outgoing.'; END IF;
        IF NULLIF(trim(p_purpose), '') IS NULL THEN RAISE EXCEPTION 'Choose the purpose of the call.'; END IF;
        IF p_follow_up IS NOT NULL AND p_follow_up < CURRENT_DATE THEN RAISE EXCEPTION 'The follow-up date cannot be in the past.'; END IF;
        INSERT INTO core.fo_calls (tenant_id, school_id, direction, caller_name, mobile, purpose, note, follow_up_on, created_by)
        VALUES (p_tenant_id, p_school_id, p_direction, trim(p_name), NULLIF(trim(p_mobile), ''), trim(p_purpose),
                NULLIF(trim(p_note), ''), p_follow_up, p_action_user_id)
        RETURNING call_id INTO v_id;
        OPEN p_result FOR SELECT v_id AS id, 'Call logged.'::varchar AS message;
        RETURN;
    END IF;

    IF p_operation = 'CallDone' THEN
        UPDATE core.fo_calls SET followed_up_at = now(), followed_up_by = p_action_user_id,
               note = CASE WHEN NULLIF(trim(p_note), '') IS NULL THEN note
                           ELSE COALESCE(note || E'\n', '') || 'Follow-up: ' || trim(p_note) END
         WHERE call_id = p_id AND tenant_id = p_tenant_id AND school_id = p_school_id
           AND follow_up_on IS NOT NULL AND followed_up_at IS NULL
        RETURNING call_id INTO v_id;
        IF v_id IS NULL THEN RAISE EXCEPTION 'This call has no follow-up pending.'; END IF;
        OPEN p_result FOR SELECT v_id AS id, 'Follow-up done.'::varchar AS message;
        RETURN;
    END IF;

    -- ── complaints
    IF p_operation = 'Complaints' THEN
        OPEN p_result FOR
        SELECT x.complaint_id, x.complaint_no, to_char(x.raised_on, 'YYYY-MM-DD') AS raised_on, x.from_type, x.from_name, x.mobile,
               x.about_student, x.category, x.description, x.assigned_to, x.status, x.resolution,
               to_char(x.resolved_at AT TIME ZONE 'Asia/Kolkata', 'DD Mon YYYY') AS resolved_on,
               (CURRENT_DATE - x.raised_on)::int AS days_open,
               core.fn_user_display_name(x.created_by) AS entered_by
          FROM core.fo_complaints x
         WHERE x.tenant_id = p_tenant_id AND x.school_id = p_school_id
           AND (NULLIF(trim(p_status), '') IS NULL
                OR (p_status = 'Pending' AND x.status IN ('Open', 'In progress'))
                OR x.status = p_status)
         ORDER BY CASE x.status WHEN 'Open' THEN 0 WHEN 'In progress' THEN 1 ELSE 2 END, x.raised_on DESC, x.complaint_id DESC
         LIMIT 500;
        RETURN;
    END IF;

    IF p_operation = 'ComplaintSave' THEN
        IF NULLIF(trim(p_name), '') IS NULL THEN RAISE EXCEPTION 'Write who is complaining.'; END IF;
        IF COALESCE(p_direction, '') NOT IN ('Parent', 'Student', 'Staff', 'Other') THEN RAISE EXCEPTION 'Choose who the complaint is from.'; END IF;
        IF NULLIF(trim(p_purpose), '') IS NULL THEN RAISE EXCEPTION 'Choose a category.'; END IF;
        IF NULLIF(trim(p_note), '') IS NULL THEN RAISE EXCEPTION 'Write what the complaint is.'; END IF;
        v_no := 'CMP-' || to_char(CURRENT_DATE, 'YYYY') || '-' || lpad((
                  SELECT COUNT(*) + 1 FROM core.fo_complaints
                   WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                     AND complaint_no LIKE 'CMP-' || to_char(CURRENT_DATE, 'YYYY') || '-%')::text, 4, '0');
        INSERT INTO core.fo_complaints (tenant_id, school_id, complaint_no, from_type, from_name, mobile, about_student,
                                        category, description, assigned_to, created_by)
        VALUES (p_tenant_id, p_school_id, v_no, p_direction, trim(p_name), NULLIF(trim(p_mobile), ''), NULLIF(trim(p_student), ''),
                trim(p_purpose), trim(p_note), NULLIF(trim(p_to_meet), ''), p_action_user_id)
        RETURNING complaint_id INTO v_id;
        OPEN p_result FOR SELECT v_id AS id, ('Complaint ' || v_no || ' recorded.')::varchar AS message;
        RETURN;
    END IF;

    IF p_operation = 'ComplaintStatus' THEN
        IF COALESCE(p_status, '') NOT IN ('Open', 'In progress', 'Resolved', 'Closed') THEN RAISE EXCEPTION 'Choose a status.'; END IF;
        IF p_status IN ('Resolved', 'Closed') AND NULLIF(trim(p_note), '') IS NULL THEN
            RAISE EXCEPTION 'Write how it was resolved.';
        END IF;
        UPDATE core.fo_complaints
           SET status = p_status,
               assigned_to = COALESCE(NULLIF(trim(p_to_meet), ''), assigned_to),
               resolution = CASE WHEN NULLIF(trim(p_note), '') IS NULL THEN resolution ELSE trim(p_note) END,
               resolved_at = CASE WHEN p_status IN ('Resolved', 'Closed') THEN now() ELSE NULL END,
               resolved_by = CASE WHEN p_status IN ('Resolved', 'Closed') THEN p_action_user_id ELSE NULL END
         WHERE complaint_id = p_id AND tenant_id = p_tenant_id AND school_id = p_school_id
        RETURNING complaint_id INTO v_id;
        IF v_id IS NULL THEN RAISE EXCEPTION 'Complaint not found.'; END IF;
        OPEN p_result FOR SELECT v_id AS id, ('Marked ' || lower(p_status) || '.')::varchar AS message;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation.';
END;
$$;
