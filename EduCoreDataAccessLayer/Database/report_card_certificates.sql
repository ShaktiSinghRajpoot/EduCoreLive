-- ============================================================================
-- Report cards + Bonafide / Character certificates.
--
-- 1. core.sp_report_card_extras: what a report card needs beyond the exam
--    result (academic.sp_school_admin_exam_results_manage 'GetClassResult'):
--    mother's name and the session's attendance, for a list of students.
--    Attendance counts days exactly like the Student Dashboard
--    (core.fn_attendance_student_days; Present + Late = present).
--
-- 2. core.certificates: Bonafide and Character certificates, numbered
--    BC-YYYY-0001 / CC-YYYY-0001 per school and calendar year, frozen at issue
--    time like the TC (the student row is copied in). A certificate is never
--    deleted; Void keeps the number with a reason.
--      Bonafide  - only for a student studying here now (active).
--      Character - for a current or a former student.
-- Re-runnable.
-- ============================================================================

CREATE OR REPLACE PROCEDURE core.sp_report_card_extras(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_student_ids    integer[],
    IN    p_academic_year  varchar,
    INOUT p_result         refcursor DEFAULT 'report_card_cursor')
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    OPEN p_result FOR
    SELECT s.student_id, s.mother_name, s.guardian_name, s.dob,
           d.school_days, p.present,
           CASE WHEN d.school_days = 0 THEN NULL
                ELSE ROUND(p.present * 100.0 / d.school_days, 1) END AS percent
      FROM core.students s
      CROSS JOIN LATERAL (SELECT COUNT(*)::int AS school_days
                            FROM core.fn_attendance_student_days(p_tenant_id, p_school_id, s.student_id, p_academic_year)) d
      CROSS JOIN LATERAL (SELECT COUNT(*)::int AS present
                            FROM core.student_attendance a
                           WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
                             AND a.student_id = s.student_id AND a.academic_year = p_academic_year
                             AND a.status IN ('Present', 'Late')) p
     WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id
       AND s.student_id = ANY (p_student_ids);
END;
$$;


CREATE TABLE IF NOT EXISTS core.certificate_counters (
    tenant_id  integer     NOT NULL,
    school_id  integer     NOT NULL,
    cert_type  varchar(20) NOT NULL,
    year_no    integer     NOT NULL,
    last_seq   integer     NOT NULL DEFAULT 0,
    PRIMARY KEY (tenant_id, school_id, cert_type, year_no)
);

CREATE TABLE IF NOT EXISTS core.certificates (
    cert_id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       integer      NOT NULL,
    school_id       integer      NOT NULL,
    cert_no         varchar(30)  NOT NULL,
    cert_type       varchar(20)  NOT NULL CHECK (cert_type IN ('Bonafide', 'Character')),
    student_id      integer      NOT NULL,
    -- the student as they were on the day of issue
    student_name    varchar(150) NOT NULL,
    gender          varchar(20),
    father_name     varchar(150),
    mother_name     varchar(150),
    dob             varchar(10),
    admission_no    varchar(50),
    admission_date  varchar(10),
    class_name      varchar(100),
    section         varchar(20),
    academic_year   varchar(20),
    is_current      boolean      NOT NULL,     -- studying here on the day of issue
    date_of_leaving varchar(10),
    -- what the school wrote
    purpose         varchar(200),
    conduct         varchar(30),
    remarks         varchar(300),
    issue_date      date         NOT NULL DEFAULT CURRENT_DATE,
    issued_by       integer      NOT NULL,
    issued_at       timestamptz  NOT NULL DEFAULT now(),
    is_void         boolean      NOT NULL DEFAULT FALSE,
    void_reason     varchar(300),
    voided_by       integer,
    voided_at       timestamptz,
    CONSTRAINT uq_certificate_no UNIQUE (tenant_id, school_id, cert_no)
);


CREATE OR REPLACE PROCEDURE core.sp_certificate_manage(
    IN    p_operation      varchar,          -- Search | Issue | Get | List | Void
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_cert_id        integer DEFAULT NULL,
    IN    p_student_id     integer DEFAULT NULL,
    IN    p_cert_type      varchar DEFAULT NULL,
    IN    p_purpose        varchar DEFAULT NULL,
    IN    p_conduct        varchar DEFAULT NULL,
    IN    p_remarks        varchar DEFAULT NULL,   -- Issue: remarks; Void: the reason
    IN    p_search         varchar DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'certificate_cursor')
LANGUAGE plpgsql
AS $$
DECLARE
    s       record;
    v_type  varchar := NULLIF(trim(p_cert_type), '');
    v_q     varchar := '%' || lower(trim(COALESCE(p_search, ''))) || '%';
    v_year  integer := EXTRACT(YEAR FROM CURRENT_DATE)::int;
    v_seq   integer;
    v_no    varchar;
    v_id    integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    -- ── Search: current AND former students (a character certificate is often for someone who left)
    IF p_operation = 'Search' THEN
        IF length(trim(COALESCE(p_search, ''))) < 2 THEN
            OPEN p_result FOR SELECT NULL::int AS student_id WHERE FALSE;
            RETURN;
        END IF;
        OPEN p_result FOR
        SELECT st.student_id, st.student_name, st.admission_no, st.class_name, st.section, st.academic_year,
               st.guardian_name, st.mobile, COALESCE(st.is_active, TRUE) AS is_current, st.status
          FROM core.students st
         WHERE st.tenant_id = p_tenant_id AND st.school_id = p_school_id
           AND (lower(st.student_name) LIKE v_q OR lower(COALESCE(st.admission_no, '')) LIKE v_q
                OR lower(COALESCE(st.guardian_name, '')) LIKE v_q OR COALESCE(st.mobile, '') LIKE v_q)
         ORDER BY COALESCE(st.is_active, TRUE) DESC, st.student_name
         LIMIT 20;
        RETURN;
    END IF;

    -- ── Issue
    IF p_operation = 'Issue' THEN
        IF v_type NOT IN ('Bonafide', 'Character') OR v_type IS NULL THEN
            RAISE EXCEPTION 'Choose the certificate type.';
        END IF;
        SELECT * INTO s FROM core.students
         WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id;
        IF NOT FOUND THEN RAISE EXCEPTION 'Student not found.'; END IF;
        IF v_type = 'Bonafide' AND NOT COALESCE(s.is_active, TRUE) THEN
            RAISE EXCEPTION 'A bonafide certificate is only for a student studying here now. Issue a character certificate instead.';
        END IF;
        IF v_type = 'Bonafide' AND NULLIF(trim(p_purpose), '') IS NULL THEN
            RAISE EXCEPTION 'Write what the certificate is needed for.';
        END IF;

        INSERT INTO core.certificate_counters (tenant_id, school_id, cert_type, year_no, last_seq)
        VALUES (p_tenant_id, p_school_id, v_type, v_year, 1)
        ON CONFLICT (tenant_id, school_id, cert_type, year_no)
        DO UPDATE SET last_seq = core.certificate_counters.last_seq + 1
        RETURNING last_seq INTO v_seq;
        v_no := CASE v_type WHEN 'Bonafide' THEN 'BC-' ELSE 'CC-' END || v_year || '-' || lpad(v_seq::text, 4, '0');

        INSERT INTO core.certificates (tenant_id, school_id, cert_no, cert_type, student_id, student_name, gender,
                                       father_name, mother_name, dob, admission_no, admission_date, class_name, section,
                                       academic_year, is_current, date_of_leaving, purpose, conduct, remarks, issued_by)
        VALUES (p_tenant_id, p_school_id, v_no, v_type, s.student_id, s.student_name, s.gender,
                s.guardian_name, s.mother_name, s.dob, s.admission_no, s.admission_date, s.class_name, s.section,
                s.academic_year, COALESCE(s.is_active, TRUE), s.date_of_leaving,
                NULLIF(trim(p_purpose), ''), COALESCE(NULLIF(trim(p_conduct), ''), 'Good'),
                NULLIF(trim(p_remarks), ''), p_action_user_id)
        RETURNING cert_id INTO v_id;

        OPEN p_result FOR SELECT v_id AS cert_id, v_no AS cert_no,
               (v_type || ' certificate ' || v_no || ' issued.')::varchar AS message;
        RETURN;
    END IF;

    -- ── Get / List
    IF p_operation IN ('Get', 'List') THEN
        OPEN p_result FOR
        SELECT c.cert_id, c.cert_no, c.cert_type, c.student_id, c.student_name, c.gender, c.father_name, c.mother_name,
               c.dob, c.admission_no, c.admission_date, c.class_name, c.section, c.academic_year, c.is_current,
               c.date_of_leaving, c.purpose, c.conduct, c.remarks, to_char(c.issue_date, 'YYYY-MM-DD') AS issue_date,
               c.is_void, c.void_reason
          FROM core.certificates c
         WHERE c.tenant_id = p_tenant_id AND c.school_id = p_school_id
           AND (p_operation = 'List' OR c.cert_id = p_cert_id)
           AND (p_operation = 'Get' OR v_type IS NULL OR c.cert_type = v_type)
           AND (p_operation = 'Get' OR length(trim(COALESCE(p_search, ''))) = 0
                OR lower(c.student_name) LIKE v_q OR lower(c.cert_no) LIKE v_q OR lower(COALESCE(c.admission_no, '')) LIKE v_q)
         ORDER BY c.cert_id DESC
         LIMIT 200;
        RETURN;
    END IF;

    -- ── Void
    IF p_operation = 'Void' THEN
        IF NULLIF(trim(p_remarks), '') IS NULL THEN RAISE EXCEPTION 'Give a reason.'; END IF;
        UPDATE core.certificates
           SET is_void = TRUE, void_reason = trim(p_remarks), voided_by = p_action_user_id, voided_at = now()
         WHERE cert_id = p_cert_id AND tenant_id = p_tenant_id AND school_id = p_school_id AND NOT is_void
        RETURNING cert_id INTO v_id;
        IF v_id IS NULL THEN RAISE EXCEPTION 'Certificate not found or already void.'; END IF;
        OPEN p_result FOR SELECT 'Certificate voided.'::varchar AS message;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation.';
END;
$$;
