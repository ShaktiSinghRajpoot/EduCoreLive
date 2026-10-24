-- =====================================================================
-- Website enquiries (24 Oct 2026).
--
-- The public website (smartschoolwala.com, Views/Site/Index.cshtml) has a "Book a free
-- demo" form. A school principal or owner fills it in without signing in; the row lands
-- here and the Super Admin sees it under Platform > Website Enquiries, where it is marked
-- Contacted / Demo done / Closed with a note.
--
-- Platform data: no tenant/school (the person is not a customer yet). Reading and
-- updating is for the platform tenant (1) only.
-- =====================================================================

CREATE TABLE IF NOT EXISTS core.website_enquiries (
    enquiry_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    contact_name  varchar(100)  NOT NULL,
    designation   varchar(60),
    school_name   varchar(150)  NOT NULL,
    city          varchar(80),
    phone         varchar(15)   NOT NULL,
    email         varchar(150),
    students      varchar(20),
    message       varchar(1000),
    status        varchar(20)   NOT NULL DEFAULT 'New',
    note          varchar(500),
    ip_address    varchar(45),
    created_at    timestamp     NOT NULL DEFAULT now(),
    updated_by    integer,
    updated_at    timestamp,
    CONSTRAINT chk_website_enquiries_status CHECK (status IN ('New', 'Contacted', 'Demo done', 'Closed'))
);
CREATE INDEX IF NOT EXISTS idx_website_enquiries_created ON core.website_enquiries (created_at DESC);


-- ── save one enquiry from the website (no sign-in) ────────────────────
CREATE OR REPLACE PROCEDURE core.sp_website_enquiry_save(
    IN    p_contact_name varchar,
    IN    p_designation  varchar,
    IN    p_school_name  varchar,
    IN    p_city         varchar,
    IN    p_phone        varchar,
    IN    p_email        varchar,
    IN    p_students     varchar,
    IN    p_message      varchar,
    IN    p_ip_address   varchar,
    INOUT p_result       refcursor DEFAULT 'enquiry_save_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_phone text := regexp_replace(COALESCE(p_phone, ''), '\D', '', 'g');
    v_id    integer;
BEGIN
    -- 91 / 0 in front of a 10-digit mobile is dropped
    IF length(v_phone) = 12 AND left(v_phone, 2) = '91' THEN v_phone := right(v_phone, 10); END IF;
    IF length(v_phone) = 11 AND left(v_phone, 1) = '0' THEN v_phone := right(v_phone, 10); END IF;

    IF NULLIF(trim(p_contact_name), '') IS NULL THEN RAISE EXCEPTION 'Please enter your name.'; END IF;
    IF NULLIF(trim(p_school_name), '') IS NULL THEN RAISE EXCEPTION 'Please enter the school name.'; END IF;
    IF v_phone !~ '^[6-9][0-9]{9}$' THEN RAISE EXCEPTION 'Please enter a 10-digit mobile number.'; END IF;
    IF NULLIF(trim(p_email), '') IS NOT NULL AND trim(p_email) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
        RAISE EXCEPTION 'Please check the e-mail address.';
    END IF;

    -- the same number again within a day: keep the first one, it is the same enquiry
    SELECT enquiry_id INTO v_id
      FROM core.website_enquiries
     WHERE phone = v_phone AND created_at > now() - interval '1 day'
     ORDER BY enquiry_id DESC LIMIT 1;

    IF v_id IS NULL THEN
        -- a flood from one address (a bot): refuse quietly after 10 in an hour
        IF (SELECT count(*) FROM core.website_enquiries
             WHERE ip_address = p_ip_address AND created_at > now() - interval '1 hour') >= 10 THEN
            RAISE EXCEPTION 'Too many enquiries from this network. Please call us instead.';
        END IF;

        INSERT INTO core.website_enquiries
            (contact_name, designation, school_name, city, phone, email, students, message, ip_address)
        VALUES
            (left(trim(p_contact_name), 100), left(NULLIF(trim(p_designation), ''), 60),
             left(trim(p_school_name), 150), left(NULLIF(trim(p_city), ''), 80), v_phone,
             left(NULLIF(trim(p_email), ''), 150), left(NULLIF(trim(p_students), ''), 20),
             left(NULLIF(trim(p_message), ''), 1000), left(p_ip_address, 45))
        RETURNING enquiry_id INTO v_id;
    END IF;

    OPEN p_result FOR SELECT v_id AS enquiry_id;
END;
$procedure$;


-- ── Super Admin: list, count of new ones, change status ─────────────
-- p_operation: 'LIST' (p_status_filter NULL = all), 'COUNT_NEW', 'STATUS'
CREATE OR REPLACE PROCEDURE core.sp_website_enquiry_manage(
    IN    p_operation      varchar,
    IN    p_tenant_id      integer,
    IN    p_action_user_id integer,
    IN    p_enquiry_id     integer,
    IN    p_status         varchar,
    IN    p_note           varchar,
    IN    p_status_filter  varchar,
    INOUT p_result         refcursor DEFAULT 'enquiry_manage_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id IS DISTINCT FROM 1 OR p_action_user_id IS NULL OR p_action_user_id <= 0 THEN
        RAISE EXCEPTION 'Only the platform can see website enquiries.';
    END IF;

    IF p_operation = 'LIST' THEN
        OPEN p_result FOR
        SELECT e.enquiry_id, e.contact_name, e.designation, e.school_name, e.city, e.phone, e.email,
               e.students, e.message, e.status, e.note,
               to_char(e.created_at, 'DD Mon YYYY, HH12:MI AM') AS created_at,
               to_char(e.updated_at, 'DD Mon YYYY, HH12:MI AM') AS updated_at
          FROM core.website_enquiries e
         WHERE p_status_filter IS NULL OR e.status = p_status_filter
         ORDER BY (e.status = 'New') DESC, e.enquiry_id DESC
         LIMIT 500;
        RETURN;
    END IF;

    IF p_operation = 'COUNT_NEW' THEN
        OPEN p_result FOR SELECT count(*)::int AS new_count FROM core.website_enquiries WHERE status = 'New';
        RETURN;
    END IF;

    IF p_operation = 'STATUS' THEN
        IF p_status NOT IN ('New', 'Contacted', 'Demo done', 'Closed') THEN
            RAISE EXCEPTION 'Unknown status.';
        END IF;
        UPDATE core.website_enquiries
           SET status = p_status, note = left(NULLIF(trim(p_note), ''), 500),
               updated_by = p_action_user_id, updated_at = now()
         WHERE enquiry_id = p_enquiry_id;
        IF NOT FOUND THEN RAISE EXCEPTION 'Enquiry not found.'; END IF;
        OPEN p_result FOR SELECT p_enquiry_id AS enquiry_id;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation: %', p_operation;
END;
$procedure$;
