-- ============================================================================
-- Transfer Certificate (TC) — issue, register and reprint.
--
-- A TC is a LEGAL document. Once issued it must reprint identically forever, so
-- its content is FROZEN into core.tc_register at issue time — never recomputed
-- from the (mutable) student row afterwards. A reprint is stamped DUPLICATE.
--
-- Sits on top of the student-exit flow (student_exit.sql): a TC can only be
-- issued for a student who has already left (is_active = FALSE). Dues MUST be
-- clear — that is the real gate (exit only *reported* dues; the TC blocks on them).
--
--   core.tc_counters    per-school / per-year gap-free number series
--   core.tc_register    the frozen certificate (one issued TC per row)
--   core.sp_tc_manage   Issue | Print | Get | List | Void
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── default TC print format (next to receipt_format) ────────────────────────
-- Two templates, not two paper sizes:
--   Basic  the everyday private-school TC (the common set of particulars).
--   Board  adds the fields CBSE / ICSE / State boards require (exam & result,
--          subjects, attendance, fees-paid-upto, activities, date of application…).
ALTER TABLE core.school_settings
    ADD COLUMN IF NOT EXISTS tc_format varchar(20) NOT NULL DEFAULT 'Basic';

ALTER TABLE core.school_settings DROP CONSTRAINT IF EXISTS chk_school_settings_tc_format;
-- Migrate any earlier value before re-adding the (stricter) constraint.
UPDATE core.school_settings SET tc_format = 'Basic'
    WHERE tc_format NOT IN ('Basic', 'Board') OR tc_format IS NULL;
ALTER TABLE core.school_settings ALTER COLUMN tc_format SET DEFAULT 'Basic';
ALTER TABLE core.school_settings
    ADD CONSTRAINT chk_school_settings_tc_format
    CHECK (tc_format IN ('Basic', 'Board'));


-- ── read/write the default TC format (mirrors sp_school_receipt_format_manage) ──
CREATE OR REPLACE PROCEDURE core.sp_school_tc_format_manage(
    IN    p_operation      varchar,          -- 'Get' | 'Save'
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_tc_format      varchar   DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'tc_format_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_format varchar(20);
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    IF p_operation = 'Save' THEN
        v_format := CASE WHEN p_tc_format IN ('Basic', 'Board')
                         THEN p_tc_format ELSE 'Basic' END;

        INSERT INTO core.school_settings (tenant_id, school_id, tc_format, created_by, created_at, is_deleted, is_active)
        VALUES (p_tenant_id, p_school_id, v_format, p_action_user_id, NOW(), FALSE, TRUE)
        ON CONFLICT (tenant_id, school_id) DO UPDATE
            SET tc_format  = EXCLUDED.tc_format,
                updated_by = p_action_user_id,
                updated_at = NOW();

        OPEN p_result FOR SELECT TRUE AS success, v_format AS tc_format;

    ELSE   -- Get
        OPEN p_result FOR
        SELECT COALESCE(NULLIF(TRIM(s.tc_format), ''), 'Basic') AS tc_format
        FROM core.school_settings s
        WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id
          AND COALESCE(s.is_deleted, FALSE) = FALSE
        LIMIT 1;
    END IF;
END;
$procedure$;


-- ── number series: TC-<year>-<seq>, gap-free per school (mirrors receipt_counters)
CREATE TABLE IF NOT EXISTS core.tc_counters (
    tenant_id integer NOT NULL,
    school_id integer NOT NULL,
    fin_year  varchar(4) NOT NULL,
    last_seq  integer NOT NULL DEFAULT 0,
    PRIMARY KEY (tenant_id, school_id, fin_year)
);


-- ── the frozen certificate ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS core.tc_register (
    tc_id        serial PRIMARY KEY,
    tenant_id    integer NOT NULL,
    school_id    integer NOT NULL,
    student_id   integer NOT NULL,
    tc_no        varchar(40) NOT NULL,
    format       varchar(20) NOT NULL DEFAULT 'Basic',
    issue_date   date NOT NULL DEFAULT CURRENT_DATE,

    -- Frozen snapshot of the student as they were on the day the TC was issued.
    admission_no   varchar(50),
    student_name   varchar(150),
    gender         varchar(20),
    dob            date,
    father_name    varchar(150),
    mother_name    varchar(150),
    class_name     varchar(50),
    section        varchar(20),
    academic_year  varchar(20),
    admission_date date,
    date_of_leaving date,
    religion       varchar(50),
    category       varchar(50),
    nationality    varchar(50),
    address        text,
    udise_no       varchar(30),        -- snapshot of the student's UDISE / PEN id

    -- Entered on the issue form (also part of the legal record).
    reason_for_leaving varchar(300),
    conduct            varchar(50),    -- Good | Satisfactory | Excellent ...
    result             varchar(100),   -- e.g. "Promoted to Class VI" / "Passed"
    remarks            varchar(500),
    outstanding_at_issue numeric(12,2) NOT NULL DEFAULT 0,

    -- Board-format extras (CBSE/ICSE/State). Optional; only the Board template
    -- prints them, but they are frozen like everything else once entered.
    exam_result      varchar(150),     -- last exam taken + result, e.g. "Annual 2025-26, Passed"
    failed_status    varchar(30),      -- No | Once | Twice (whether failed before)
    subjects_studied varchar(300),
    fees_paid_upto   varchar(50),      -- month up to which fees are paid
    working_days     integer,          -- total working days in the session
    days_present     integer,          -- days the student was present
    activities       varchar(300),     -- games / NCC / Scouts-Guides / co-curricular
    application_date date,             -- date the parent applied for the certificate

    -- Reprint tracking: the first print is the original, every later one DUPLICATE.
    print_count  integer NOT NULL DEFAULT 0,

    is_void      boolean NOT NULL DEFAULT FALSE,
    void_reason  varchar(300),
    voided_by    integer,
    voided_at    timestamptz,

    issued_by    integer,
    issued_at    timestamptz NOT NULL DEFAULT now()
);

-- One live TC number per school; a voided one frees nothing (numbers never reused).
CREATE UNIQUE INDEX IF NOT EXISTS ux_tc_register_no
    ON core.tc_register (tenant_id, school_id, tc_no);

-- A student can hold only ONE live (non-void) TC. Re-issuing needs the old one voided.
CREATE UNIQUE INDEX IF NOT EXISTS ux_tc_register_student_live
    ON core.tc_register (tenant_id, school_id, student_id)
    WHERE is_void = FALSE;

-- Board-format columns for a tc_register that already exists (idempotent).
ALTER TABLE core.tc_register
    ADD COLUMN IF NOT EXISTS udise_no         varchar(30),
    ADD COLUMN IF NOT EXISTS exam_result      varchar(150),
    ADD COLUMN IF NOT EXISTS failed_status    varchar(30),
    ADD COLUMN IF NOT EXISTS subjects_studied varchar(300),
    ADD COLUMN IF NOT EXISTS fees_paid_upto   varchar(50),
    ADD COLUMN IF NOT EXISTS working_days     integer,
    ADD COLUMN IF NOT EXISTS days_present     integer,
    ADD COLUMN IF NOT EXISTS activities       varchar(300),
    ADD COLUMN IF NOT EXISTS application_date date;


-- ── issue / print / read / list / void ──────────────────────────────────────
-- Drop the earlier (pre-Board) 15-arg signature so only one overload survives —
-- CREATE OR REPLACE keeps a differing arg list as a separate overload otherwise.
DROP PROCEDURE IF EXISTS core.sp_tc_manage(
    varchar, integer, integer, integer, integer, integer,
    varchar, varchar, varchar, varchar, varchar,
    text, integer, integer, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_tc_manage(
    IN    p_operation      varchar,     -- 'Issue' | 'Print' | 'Get' | 'List' | 'Void'
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_tc_id          integer DEFAULT NULL,
    IN    p_student_id     integer DEFAULT NULL,
    IN    p_format         varchar DEFAULT NULL,   -- Issue: chosen format (Basic | Board)
    IN    p_conduct        varchar DEFAULT NULL,
    IN    p_result         varchar DEFAULT NULL,
    IN    p_reason         varchar DEFAULT NULL,
    IN    p_remarks        varchar DEFAULT NULL,
    -- Board-format extras (all optional; ignored by the Basic template)
    IN    p_exam_result    varchar DEFAULT NULL,
    IN    p_failed_status  varchar DEFAULT NULL,
    IN    p_subjects       varchar DEFAULT NULL,
    IN    p_fees_paid_upto varchar DEFAULT NULL,
    IN    p_working_days   integer DEFAULT NULL,
    IN    p_days_present   integer DEFAULT NULL,
    IN    p_activities     varchar DEFAULT NULL,
    IN    p_application_date date  DEFAULT NULL,
    IN    p_search         text    DEFAULT NULL,    -- List
    IN    p_page_no        integer DEFAULT 1,
    IN    p_page_size      integer DEFAULT 10,
    INOUT p_result_cur     refcursor DEFAULT 'tc_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    s        core.students%ROWTYPE;
    v_dues   numeric(12,2);
    v_year   varchar(4);
    v_seq    integer;
    v_tc_no  varchar(40);
    v_new_id integer;
    v_fmt    varchar(20);
    v_offset integer;
    v_was_printed boolean;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    -- ───────────────────────────── Issue ─────────────────────────────
    IF p_operation = 'Issue' THEN
        SELECT * INTO s
        FROM core.students
        WHERE student_id = p_student_id
          AND tenant_id  = p_tenant_id
          AND school_id  = p_school_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Student not found.';
        END IF;

        -- A TC is only for a student who has actually left, and only for the
        -- reasons that warrant one (a plain withdrawal does not get a TC).
        IF s.is_active THEN
            RAISE EXCEPTION 'Mark % as left before issuing a Transfer Certificate.', s.student_name;
        END IF;
        IF s.status NOT IN ('Transfer', 'Passout', 'Struck Off') THEN
            RAISE EXCEPTION 'A Transfer Certificate is not issued for status "%".', s.status;
        END IF;

        -- The gate: dues must be clear. Unlike exit (which only reported them),
        -- the TC is withheld until the account is settled.
        SELECT COALESCE(SUM(l.amount_due - l.amount_paid - COALESCE(l.concession, 0)), 0)
        INTO v_dues
        FROM core.student_ledger l
        WHERE l.student_id = p_student_id;

        IF v_dues > 0 THEN
            -- RAISE has no printf specifiers; format the amount ourselves.
            RAISE EXCEPTION 'Clear the pending dues of % before issuing the certificate.',
                to_char(v_dues, 'FM99,99,99,990.00');
        END IF;

        -- One live TC per student. If a valid one already exists, re-open it
        -- rather than minting a second number (reprint is the correct path).
        IF EXISTS (SELECT 1 FROM core.tc_register
                   WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                     AND student_id = p_student_id AND is_void = FALSE) THEN
            RAISE EXCEPTION 'A Transfer Certificate has already been issued for %. Use reprint.', s.student_name;
        END IF;

        v_fmt  := CASE WHEN p_format IN ('Basic', 'Board') THEN p_format ELSE 'Basic' END;
        v_year := to_char(CURRENT_DATE, 'YYYY');

        -- Gap-free number, atomic per (school, year).
        INSERT INTO core.tc_counters (tenant_id, school_id, fin_year, last_seq)
        VALUES (p_tenant_id, p_school_id, v_year, 1)
        ON CONFLICT (tenant_id, school_id, fin_year)
        DO UPDATE SET last_seq = core.tc_counters.last_seq + 1
        RETURNING last_seq INTO v_seq;

        v_tc_no := 'TC-' || v_year || '-' || lpad(v_seq::text, 4, '0');

        INSERT INTO core.tc_register (
            tenant_id, school_id, student_id, tc_no, format, issue_date,
            admission_no, student_name, gender, dob, father_name, mother_name,
            class_name, section, academic_year, admission_date, date_of_leaving,
            religion, category, nationality, address, udise_no,
            reason_for_leaving, conduct, result, remarks, outstanding_at_issue,
            exam_result, failed_status, subjects_studied, fees_paid_upto,
            working_days, days_present, activities, application_date,
            issued_by, issued_at)
        VALUES (
            p_tenant_id, p_school_id, p_student_id, v_tc_no, v_fmt, CURRENT_DATE,
            s.admission_no, s.student_name, s.gender, s.dob, s.guardian_name, s.mother_name,
            s.class_name, s.section, s.academic_year, s.admission_date, s.date_of_leaving,
            s.religion, s.category, s.nationality, s.address, s.udise_student_id,
            NULLIF(TRIM(COALESCE(p_reason, s.leaving_reason)), ''),
            NULLIF(TRIM(p_conduct), ''), NULLIF(TRIM(p_result), ''),
            NULLIF(TRIM(p_remarks), ''), 0,
            NULLIF(TRIM(p_exam_result), ''), NULLIF(TRIM(p_failed_status), ''),
            NULLIF(TRIM(p_subjects), ''), NULLIF(TRIM(p_fees_paid_upto), ''),
            p_working_days, p_days_present, NULLIF(TRIM(p_activities), ''), p_application_date,
            p_action_user_id, now())
        RETURNING tc_id INTO v_new_id;

        OPEN p_result_cur FOR
        SELECT TRUE AS success,
               'Transfer Certificate ' || v_tc_no || ' issued for ' || s.student_name || '.' AS message,
               v_new_id AS tc_id, v_tc_no AS tc_no;
        RETURN;
    END IF;

    -- ─────────────────────────── Print / Get ──────────────────────────
    -- Print serves the frozen row and marks it printed: the first serve is the
    -- original, every later serve comes back with was_duplicate = TRUE so the
    -- page can stamp DUPLICATE. Get is the same read WITHOUT marking (for lists).
    IF p_operation IN ('Print', 'Get') THEN
        IF p_operation = 'Print' THEN
            SELECT (print_count > 0) INTO v_was_printed
            FROM core.tc_register
            WHERE tc_id = p_tc_id AND tenant_id = p_tenant_id AND school_id = p_school_id;

            IF NOT FOUND THEN
                RAISE EXCEPTION 'Certificate not found.';
            END IF;

            UPDATE core.tc_register
            SET print_count = print_count + 1
            WHERE tc_id = p_tc_id AND tenant_id = p_tenant_id AND school_id = p_school_id;
        END IF;

        OPEN p_result_cur FOR
        SELECT r.*,
               CASE WHEN p_operation = 'Print' THEN v_was_printed
                    ELSE (r.print_count > 0) END AS was_duplicate
        FROM core.tc_register r
        WHERE r.tc_id = p_tc_id
          AND r.tenant_id = p_tenant_id AND r.school_id = p_school_id;
        RETURN;
    END IF;

    -- ───────────────────────────── List ──────────────────────────────
    IF p_operation = 'List' THEN
        v_offset := (GREATEST(COALESCE(p_page_no, 1), 1) - 1) * COALESCE(p_page_size, 10);

        OPEN p_result_cur FOR
        WITH filtered AS (
            SELECT r.tc_id, r.public_id, r.tc_no, r.format, r.issue_date, r.student_id,
                   r.admission_no, r.student_name, r.class_name, r.section,
                   r.academic_year, r.date_of_leaving, r.is_void, r.print_count
            FROM core.tc_register r
            WHERE r.tenant_id = p_tenant_id AND r.school_id = p_school_id
              AND (p_search IS NULL OR TRIM(p_search) = ''
                   OR LOWER(r.student_name) LIKE '%' || LOWER(TRIM(p_search)) || '%'
                   OR LOWER(r.tc_no)        LIKE '%' || LOWER(TRIM(p_search)) || '%'
                   OR LOWER(COALESCE(r.admission_no, '')) LIKE '%' || LOWER(TRIM(p_search)) || '%')
        )
        SELECT tc_id, public_id, tc_no, format, issue_date, student_id, admission_no,
               student_name, class_name, section, academic_year, date_of_leaving,
               is_void, print_count,
               COUNT(*) OVER() AS total_count
        FROM filtered
        ORDER BY tc_id DESC
        LIMIT COALESCE(p_page_size, 10) OFFSET v_offset;
        RETURN;
    END IF;

    -- ───────────────────────────── Void ──────────────────────────────
    -- A mistaken TC is voided, not deleted — the number is retired for audit and
    -- the student becomes eligible for a fresh issue.
    IF p_operation = 'Void' THEN
        UPDATE core.tc_register
        SET is_void = TRUE, void_reason = NULLIF(TRIM(p_reason), ''),
            voided_by = p_action_user_id, voided_at = now()
        WHERE tc_id = p_tc_id AND tenant_id = p_tenant_id AND school_id = p_school_id
          AND is_void = FALSE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Certificate not found or already void.';
        END IF;

        OPEN p_result_cur FOR SELECT TRUE AS success, 'Certificate voided.' AS message;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation %.', p_operation;
END;
$procedure$;
