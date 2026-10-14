-- Bundle 2026-10-15c: ID cards of an older session use that session's class (enrolment); a TC right after promotion is written for the session finished. Run with:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_15c.sql
-- Sources (re-runnable): id_card.sql, transfer_certificate.sql

-- ============================================================================
-- Student ID Card — print (single + class-wise bulk).
--
-- Unlike the TC, an ID card is NOT a frozen legal document: it is generated
-- on demand from the student's CURRENT data, so there is no register table.
-- This script only stores the school's chosen card format and provides the
-- read that feeds the print grid.
--
-- The card carries a photo box that stays blank until a student-photo upload
-- exists (schools commonly paste the photo physically for now).
--
--   core.school_settings.id_card_format         Portrait | Landscape
--   core.sp_school_id_card_format_manage         Get | Save the format
--   core.sp_id_card_students                      one class's active students
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── default ID-card format (next to receipt_format / tc_format) ──────────────
ALTER TABLE core.school_settings
    ADD COLUMN IF NOT EXISTS id_card_format varchar(20) NOT NULL DEFAULT 'Portrait';

ALTER TABLE core.school_settings DROP CONSTRAINT IF EXISTS chk_school_settings_id_card_format;
ALTER TABLE core.school_settings
    ADD CONSTRAINT chk_school_settings_id_card_format
    CHECK (id_card_format IN ('Portrait', 'Landscape'));


-- ── read/write the format (mirrors the receipt / tc format procs) ────────────
CREATE OR REPLACE PROCEDURE core.sp_school_id_card_format_manage(
    IN    p_operation      varchar,          -- 'Get' | 'Save'
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_format         varchar   DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'id_card_format_cursor'::refcursor
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
        v_format := CASE WHEN p_format IN ('Portrait', 'Landscape')
                         THEN p_format ELSE 'Portrait' END;

        INSERT INTO core.school_settings (tenant_id, school_id, id_card_format, created_by, created_at, is_deleted, is_active)
        VALUES (p_tenant_id, p_school_id, v_format, p_action_user_id, NOW(), FALSE, TRUE)
        ON CONFLICT (tenant_id, school_id) DO UPDATE
            SET id_card_format = EXCLUDED.id_card_format,
                updated_by     = p_action_user_id,
                updated_at     = NOW();

        OPEN p_result FOR SELECT TRUE AS success, v_format AS id_card_format;

    ELSE   -- Get
        OPEN p_result FOR
        SELECT COALESCE(NULLIF(TRIM(s.id_card_format), ''), 'Portrait') AS id_card_format
        FROM core.school_settings s
        WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id
          AND COALESCE(s.is_deleted, FALSE) = FALSE
        LIMIT 1;
    END IF;
END;
$procedure$;


-- ── the students on one class's ID-card sheet ────────────────────────────────
-- Class + academic year pick the batch; section is optional (blank = all
-- sections of that class). Only active students are carried onto cards.
-- p_student_id, when given, returns just that one student (single-card print).
DROP PROCEDURE IF EXISTS core.sp_id_card_students(
    integer, integer, integer, varchar, varchar, varchar, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_id_card_students(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_class          varchar DEFAULT NULL,
    IN    p_section        varchar DEFAULT NULL,
    IN    p_academic_year  varchar DEFAULT NULL,
    IN    p_student_id     integer DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'id_card_students_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        OPEN p_result FOR SELECT WHERE FALSE;
        RETURN;
    END IF;

    -- A chosen session reads the student's class / section / roll FOR THAT session
    -- (core.student_enrolment), so promoted students still print on an older
    -- session's cards, with that session's class. No session = where they are now.
    OPEN p_result FOR
    SELECT x.student_id, x.admission_no, x.roll_no, x.student_name,
           x.class_name, x.section, x.academic_year,
           x.dob, x.blood_group, x.gender,
           x.guardian_name, x.mobile, x.address, x.photo_url
    FROM (
        SELECT s.student_id, s.admission_no, s.student_name,
               COALESCE(e.roll_no, s.roll_no)             AS roll_no,
               COALESCE(e.class_name, s.class_name)       AS class_name,
               COALESCE(e.section, s.section)             AS section,
               COALESCE(e.academic_year, s.academic_year) AS academic_year,
               s.dob, s.blood_group, s.gender,
               s.guardian_name, s.mobile, s.address, s.photo_url
          FROM core.students s
          LEFT JOIN core.student_enrolment e
                 ON e.student_id = s.student_id
                AND NULLIF(TRIM(p_academic_year), '') IS NOT NULL
                AND e.academic_year = TRIM(p_academic_year)
         WHERE s.tenant_id = p_tenant_id
           AND s.school_id = p_school_id
           AND s.is_active = TRUE
           AND (p_student_id IS NULL OR s.student_id = p_student_id)
    ) x
    WHERE (p_class IS NULL OR TRIM(p_class) = '' OR LOWER(x.class_name) = LOWER(TRIM(p_class)))
      AND (p_section IS NULL OR TRIM(p_section) = '' OR LOWER(COALESCE(x.section, '')) = LOWER(TRIM(p_section)))
      AND (p_academic_year IS NULL OR TRIM(p_academic_year) = '' OR x.academic_year = TRIM(p_academic_year))
    ORDER BY
        -- Roll numbers are text; sort them numerically when they are numbers,
        -- then fall back to name so the sheet reads in register order.
        CASE WHEN x.roll_no ~ '^[0-9]+$' THEN lpad(x.roll_no, 6, '0') ELSE NULL END NULLS LAST,
        x.student_name;
END;
$procedure$;


-- ── the sections that actually have students in a class ──────────────────────
-- Feeds the ID-card chooser's Section dropdown, so it only lists sections that
-- have active students to print (no config setup needed).
CREATE OR REPLACE PROCEDURE core.sp_id_card_sections(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_class          varchar DEFAULT NULL,
    IN    p_academic_year  varchar DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'id_card_sections_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        OPEN p_result FOR SELECT WHERE FALSE;
        RETURN;
    END IF;

    -- Same rule as the cards: a chosen session uses that session's class / section.
    OPEN p_result FOR
    SELECT DISTINCT TRIM(x.section) AS section
    FROM (
        SELECT COALESCE(e.class_name, s.class_name)       AS class_name,
               COALESCE(e.section, s.section)             AS section,
               COALESCE(e.academic_year, s.academic_year) AS academic_year
          FROM core.students s
          LEFT JOIN core.student_enrolment e
                 ON e.student_id = s.student_id
                AND NULLIF(TRIM(p_academic_year), '') IS NOT NULL
                AND e.academic_year = TRIM(p_academic_year)
         WHERE s.tenant_id = p_tenant_id
           AND s.school_id = p_school_id
           AND s.is_active = TRUE
    ) x
    WHERE COALESCE(TRIM(x.section), '') <> ''
      AND (p_class IS NULL OR TRIM(p_class) = '' OR LOWER(x.class_name) = LOWER(TRIM(p_class)))
      AND (p_academic_year IS NULL OR TRIM(p_academic_year) = '' OR x.academic_year = TRIM(p_academic_year))
    ORDER BY 1;
END;
$procedure$;


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
    v_public uuid;
    v_fmt    varchar(20);
    v_offset integer;
    v_was_printed boolean;
    v_wallet numeric(12,2);
    v_work   integer;
    v_pres   integer;
    v_upto   varchar(50);
    v_days   integer;
    e        record;
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

        -- Money the school still holds for the family blocks the TC too. An
        -- advance balance (overpayment / prepaid) has to be refunded first,
        -- with a voucher, or it would simply stay with the school after the
        -- child has gone.
        SELECT COALESCE(balance, 0) INTO v_wallet
        FROM core.student_advance
        WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id;

        IF COALESCE(v_wallet, 0) > 0 THEN
            RAISE EXCEPTION 'Refund the advance balance of % to the family before issuing the certificate.',
                to_char(v_wallet, 'FM99,99,99,990.00');
        END IF;

        -- One live TC per student. If a valid one already exists, re-open it
        -- rather than minting a second number (reprint is the correct path).
        IF EXISTS (SELECT 1 FROM core.tc_register
                   WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                     AND student_id = p_student_id AND is_void = FALSE) THEN
            RAISE EXCEPTION 'A Transfer Certificate has already been issued for %. Use reprint.', s.student_name;
        END IF;

        -- The Board particulars are printed on a legal document, so they have
        -- to make sense: no negative days, never more days present than
        -- working days, and nobody applies for a TC after it was issued.
        IF COALESCE(p_working_days, 0) < 0 OR COALESCE(p_days_present, 0) < 0 THEN
            RAISE EXCEPTION 'Working days and days present cannot be negative.';
        END IF;
        IF p_working_days IS NOT NULL AND p_days_present IS NOT NULL
           AND p_days_present > p_working_days THEN
            RAISE EXCEPTION 'Days present (%) cannot be more than working days (%).',
                p_days_present, p_working_days;
        END IF;
        IF p_application_date IS NOT NULL AND p_application_date > CURRENT_DATE THEN
            RAISE EXCEPTION 'The date of application cannot be after the date of issue.';
        END IF;

        -- Left just after promotion: the student has hardly studied in the new class.
        -- Fewer than 30 register days in the new session -> the TC is written for the
        -- session they finished (class last studied, its attendance, its fees), the
        -- way a school writes it ("last studied Class 8, qualified for Class 9").
        SELECT COUNT(DISTINCT a.attendance_date) INTO v_days
          FROM core.student_attendance a
         WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
           AND a.academic_year = s.academic_year AND a.class_name = s.class_name
           AND COALESCE(a.section, '') = COALESCE(s.section, '');
        IF v_days < 30 THEN
            SELECT en.academic_year, en.class_name, en.section INTO e
              FROM core.student_enrolment en
             WHERE en.student_id = p_student_id AND en.academic_year <> s.academic_year
             ORDER BY en.academic_year DESC
             LIMIT 1;
            IF e.academic_year IS NOT NULL THEN
                s.academic_year := e.academic_year;
                s.class_name    := e.class_name;
                s.section       := e.section;
            END IF;
        END IF;

        -- Left blank on the form, these come from the school's own records
        -- (QA BUG-085): working days = days the register of the student's section
        -- was taken this session, days present = their Present / Late days, and
        -- fees paid up to = the last fee line paid before the first unpaid one.
        v_work := p_working_days;
        IF v_work IS NULL THEN
            SELECT NULLIF(COUNT(DISTINCT a.attendance_date), 0)::int INTO v_work
              FROM core.student_attendance a
             WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
               AND a.academic_year = s.academic_year AND a.class_name = s.class_name
               AND COALESCE(a.section, '') = COALESCE(s.section, '');
        END IF;
        v_pres := p_days_present;
        IF v_pres IS NULL AND v_work IS NOT NULL THEN
            SELECT COUNT(*)::int INTO v_pres
              FROM core.student_attendance a
             WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
               AND a.student_id = p_student_id AND a.academic_year = s.academic_year
               AND a.status IN ('Present', 'Late');
        END IF;
        v_upto := NULLIF(TRIM(p_fees_paid_upto), '');
        IF v_upto IS NULL THEN
            SELECT l.installment_label INTO v_upto
              FROM core.student_ledger l
             WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
               AND l.student_id = p_student_id AND l.academic_year = s.academic_year
               AND l.amount_paid + COALESCE(l.concession, 0) >= l.amount_due
               AND l.due_date < COALESCE(
                     (SELECT MIN(u.due_date) FROM core.student_ledger u
                       WHERE u.tenant_id = p_tenant_id AND u.school_id = p_school_id
                         AND u.student_id = p_student_id AND u.academic_year = s.academic_year
                         AND u.amount_paid + COALESCE(u.concession, 0) + COALESCE(u.closed_amount, 0) < u.amount_due),
                     '9999-12-31')
             ORDER BY l.due_date DESC, l.ledger_id DESC
             LIMIT 1;
        END IF;

        v_fmt  := CASE WHEN p_format IN ('Basic', 'Board') THEN p_format ELSE 'Basic' END;
        -- The series restarts on 1 January (calendar year), not at the session
        -- start. Kept on purpose: the school confirmed it (2026-10-10).
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
            NULLIF(TRIM(p_subjects), ''), v_upto,
            v_work, v_pres, NULLIF(TRIM(p_activities), ''), p_application_date,
            p_action_user_id, now())
        RETURNING tc_id, public_id INTO v_new_id, v_public;

        OPEN p_result_cur FOR
        SELECT TRUE AS success,
               'Transfer Certificate ' || v_tc_no || ' issued for ' || s.student_name || '.' AS message,
               v_new_id AS tc_id, v_tc_no AS tc_no,
               -- The page opens Tc/Print by this uuid (the int id is not routable).
               v_public AS public_id;
        RETURN;
    END IF;

    -- ─────────────────────────── Print / Get ──────────────────────────
    -- Print marks the certificate printed: the first Print is the original,
    -- every later one comes back with was_duplicate = TRUE so the page can
    -- stamp DUPLICATE. The page calls it only from an explicit POST when the
    -- user presses Print (TcController.MarkPrinted) -- opening or refreshing the
    -- page uses Get, which never marks anything.
    -- A VOIDED certificate is never printed: it would come out looking valid.
    IF p_operation IN ('Print', 'Get') THEN
        IF p_operation = 'Print' THEN
            SELECT (print_count > 0) INTO v_was_printed
            FROM core.tc_register
            WHERE tc_id = p_tc_id AND tenant_id = p_tenant_id AND school_id = p_school_id;

            IF NOT FOUND THEN
                RAISE EXCEPTION 'Certificate not found.';
            END IF;

            IF EXISTS (SELECT 1 FROM core.tc_register
                        WHERE tc_id = p_tc_id AND is_void) THEN
                RAISE EXCEPTION 'This certificate was voided and cannot be printed.';
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
                   r.academic_year, r.date_of_leaving, r.is_void, r.print_count,
                   -- Why, who and when a number was retired, for the Register.
                   r.void_reason, r.voided_at, u.email AS voided_by_name
            FROM core.tc_register r
            LEFT JOIN core.users u ON u.user_id = r.voided_by
            WHERE r.tenant_id = p_tenant_id AND r.school_id = p_school_id
              -- strpos, not LIKE: a typed % or _ is a character, not a wildcard.
              AND (p_search IS NULL OR TRIM(p_search) = ''
                   OR strpos(LOWER(r.student_name), LOWER(TRIM(p_search))) > 0
                   OR strpos(LOWER(r.tc_no), LOWER(TRIM(p_search))) > 0
                   OR strpos(LOWER(COALESCE(r.admission_no, '')), LOWER(TRIM(p_search))) > 0)
        )
        SELECT tc_id, public_id, tc_no, format, issue_date, student_id, admission_no,
               student_name, class_name, section, academic_year, date_of_leaving,
               is_void, print_count, void_reason, voided_at, voided_by_name,
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
        -- A retired certificate number must say why it was retired.
        IF COALESCE(TRIM(p_reason), '') = '' THEN
            RAISE EXCEPTION 'A reason is required to void a certificate.';
        END IF;

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


