-- ============================================================================
-- Announcements / Notice Board.
--
-- A school posts a notice (title, message, category, who it is for). Every
-- school user sees the live notices on the Notice Board and in the navbar
-- bell; opening the board marks them read, so the poster sees "Seen by".
-- Parents have no login, so a notice reaches them as a printed circular or a
-- WhatsApp share from the page (the audience is printed on the circular).
--
--   audience: Everyone | Staff | Parents | Classes (then class_names lists them)
--   show_until: after this date the notice leaves the board (kept for the poster)
--
-- Posting needs the new permission notices.manage (School Admin bypasses).
-- Re-runnable.
-- ============================================================================

CREATE TABLE IF NOT EXISTS core.announcements (
    announcement_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id        integer      NOT NULL,
    school_id        integer      NOT NULL,
    title            varchar(200) NOT NULL,
    body             text         NOT NULL,
    category         varchar(20)  NOT NULL DEFAULT 'General',
    audience         varchar(20)  NOT NULL DEFAULT 'Everyone',
    class_names      varchar(500),
    is_pinned        boolean      NOT NULL DEFAULT FALSE,
    show_until       date,
    is_deleted       boolean      NOT NULL DEFAULT FALSE,
    created_by       integer      NOT NULL,
    created_at       timestamptz  NOT NULL DEFAULT now(),
    updated_by       integer,
    updated_at       timestamptz
);
CREATE INDEX IF NOT EXISTS ix_announcements_school ON core.announcements (tenant_id, school_id, created_at DESC);

CREATE TABLE IF NOT EXISTS core.announcement_reads (
    announcement_id  integer     NOT NULL REFERENCES core.announcements (announcement_id),
    user_id          integer     NOT NULL,
    read_at          timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (announcement_id, user_id)
);

INSERT INTO config.permissions (permission_key, module_group, display_name, sort_order)
VALUES ('notices.manage', 'Administration', 'Announcements — Post and manage notices', 143)
ON CONFLICT (permission_key) DO NOTHING;


CREATE OR REPLACE PROCEDURE core.sp_announcement_manage(
    IN    p_operation      varchar,    -- Board | List | Save | Delete | Read | SeenBy
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_id             integer DEFAULT NULL,
    IN    p_title          varchar DEFAULT NULL,
    IN    p_body           text    DEFAULT NULL,
    IN    p_category       varchar DEFAULT NULL,
    IN    p_audience       varchar DEFAULT NULL,
    IN    p_class_names    varchar DEFAULT NULL,
    IN    p_is_pinned      boolean DEFAULT FALSE,
    IN    p_show_until     date    DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'announcement_cursor')
LANGUAGE plpgsql
AS $$
DECLARE
    v_id       integer;
    v_audience varchar := COALESCE(NULLIF(trim(p_audience), ''), 'Everyone');
    v_classes  varchar := NULLIF(trim(p_class_names), '');
    v_staff    integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    -- How many people can read a notice: the school's active logins.
    SELECT COUNT(*) INTO v_staff FROM core.users
     WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND is_active AND NOT is_deleted;

    -- ── Board: live notices for the signed-in user, pinned first
    IF p_operation = 'Board' THEN
        OPEN p_result FOR
        SELECT a.announcement_id, a.title, a.body, a.category, a.audience, a.class_names,
               a.is_pinned, to_char(a.show_until, 'YYYY-MM-DD') AS show_until, a.created_at,
               COALESCE(st.full_name, split_part(u.email, '@', 1)) AS posted_by,
               (r.user_id IS NOT NULL) AS is_read,
               (SELECT COUNT(*) FROM core.announcement_reads x WHERE x.announcement_id = a.announcement_id) AS seen_count,
               v_staff AS staff_count
          FROM core.announcements a
          LEFT JOIN core.users u  ON u.user_id = a.created_by
          LEFT JOIN LATERAL (SELECT s.full_name FROM core.staff s
                              WHERE s.user_id = a.created_by AND s.tenant_id = a.tenant_id LIMIT 1) st ON TRUE
          LEFT JOIN core.announcement_reads r ON r.announcement_id = a.announcement_id AND r.user_id = p_action_user_id
         WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id AND NOT a.is_deleted
           AND (a.show_until IS NULL OR a.show_until >= CURRENT_DATE)
         ORDER BY a.is_pinned DESC, a.created_at DESC
         LIMIT 100;
        RETURN;
    END IF;

    -- ── List: every notice incl. expired ones (manage view)
    IF p_operation = 'List' THEN
        OPEN p_result FOR
        SELECT a.announcement_id, a.title, a.body, a.category, a.audience, a.class_names,
               a.is_pinned, to_char(a.show_until, 'YYYY-MM-DD') AS show_until, a.created_at,
               COALESCE(st.full_name, split_part(u.email, '@', 1)) AS posted_by,
               (r.user_id IS NOT NULL) AS is_read,
               (SELECT COUNT(*) FROM core.announcement_reads x WHERE x.announcement_id = a.announcement_id) AS seen_count,
               v_staff AS staff_count
          FROM core.announcements a
          LEFT JOIN core.users u  ON u.user_id = a.created_by
          LEFT JOIN LATERAL (SELECT s.full_name FROM core.staff s
                              WHERE s.user_id = a.created_by AND s.tenant_id = a.tenant_id LIMIT 1) st ON TRUE
          LEFT JOIN core.announcement_reads r ON r.announcement_id = a.announcement_id AND r.user_id = p_action_user_id
         WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id AND NOT a.is_deleted
         ORDER BY a.is_pinned DESC, a.created_at DESC
         LIMIT 300;
        RETURN;
    END IF;

    -- ── SeenBy: who opened one notice
    IF p_operation = 'SeenBy' THEN
        OPEN p_result FOR
        SELECT COALESCE(st.full_name, split_part(u.email, '@', 1)) AS name, r.read_at
          FROM core.announcement_reads r
          JOIN core.announcements a ON a.announcement_id = r.announcement_id
                                   AND a.tenant_id = p_tenant_id AND a.school_id = p_school_id
          JOIN core.users u ON u.user_id = r.user_id
          LEFT JOIN LATERAL (SELECT s.full_name FROM core.staff s
                              WHERE s.user_id = r.user_id AND s.tenant_id = p_tenant_id LIMIT 1) st ON TRUE
         WHERE r.announcement_id = p_id
         ORDER BY r.read_at DESC;
        RETURN;
    END IF;

    -- ── Read: mark one notice (p_id) or every live notice as read by this user
    IF p_operation = 'Read' THEN
        INSERT INTO core.announcement_reads (announcement_id, user_id)
        SELECT a.announcement_id, p_action_user_id
          FROM core.announcements a
         WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id AND NOT a.is_deleted
           AND (p_id IS NULL OR a.announcement_id = p_id)
        ON CONFLICT DO NOTHING;
        OPEN p_result FOR SELECT 'Marked as read.'::varchar AS message;
        RETURN;
    END IF;

    -- ── Save: new (p_id null) or edit
    IF p_operation = 'Save' THEN
        IF NULLIF(trim(p_title), '') IS NULL OR NULLIF(trim(p_body), '') IS NULL THEN
            RAISE EXCEPTION 'Title and message are required.';
        END IF;
        IF v_audience NOT IN ('Everyone', 'Staff', 'Parents', 'Classes') THEN
            RAISE EXCEPTION 'Choose who the notice is for.';
        END IF;
        IF v_audience = 'Classes' AND v_classes IS NULL THEN
            RAISE EXCEPTION 'Pick at least one class.';
        END IF;
        IF v_audience <> 'Classes' THEN
            v_classes := NULL;
        END IF;

        IF p_id IS NULL THEN
            INSERT INTO core.announcements (tenant_id, school_id, title, body, category, audience, class_names,
                                            is_pinned, show_until, created_by)
            VALUES (p_tenant_id, p_school_id, trim(p_title), trim(p_body), COALESCE(NULLIF(trim(p_category), ''), 'General'),
                    v_audience, v_classes, COALESCE(p_is_pinned, FALSE), p_show_until, p_action_user_id)
            RETURNING announcement_id INTO v_id;
            -- the poster has obviously read it
            INSERT INTO core.announcement_reads (announcement_id, user_id) VALUES (v_id, p_action_user_id);
        ELSE
            UPDATE core.announcements
               SET title = trim(p_title), body = trim(p_body),
                   category = COALESCE(NULLIF(trim(p_category), ''), 'General'),
                   audience = v_audience, class_names = v_classes,
                   is_pinned = COALESCE(p_is_pinned, FALSE), show_until = p_show_until,
                   updated_by = p_action_user_id, updated_at = now()
             WHERE announcement_id = p_id AND tenant_id = p_tenant_id AND school_id = p_school_id AND NOT is_deleted
            RETURNING announcement_id INTO v_id;
            IF v_id IS NULL THEN
                RAISE EXCEPTION 'Notice not found.';
            END IF;
        END IF;
        OPEN p_result FOR SELECT v_id AS announcement_id,
               (CASE WHEN p_id IS NULL THEN 'Notice posted.' ELSE 'Notice updated.' END)::varchar AS message;
        RETURN;
    END IF;

    -- ── Delete (soft)
    IF p_operation = 'Delete' THEN
        UPDATE core.announcements SET is_deleted = TRUE, updated_by = p_action_user_id, updated_at = now()
         WHERE announcement_id = p_id AND tenant_id = p_tenant_id AND school_id = p_school_id AND NOT is_deleted
        RETURNING announcement_id INTO v_id;
        IF v_id IS NULL THEN
            RAISE EXCEPTION 'Notice not found.';
        END IF;
        OPEN p_result FOR SELECT 'Notice deleted.'::varchar AS message;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation.';
END;
$$;
