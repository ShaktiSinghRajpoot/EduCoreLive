-- ============================================================================
-- Chasing fees the way a school office does it (19 Oct 2026), around the
-- Month-wise Dues page (fee_month_dues.sql):
--
--   * FOLLOW-UP NOTES. "Father will pay on the 25th": a note per child with an
--     optional promise date; done when it is dealt with. Never deleted.
--   * DON'T CHASE. A child on a scholarship / RTE seat / written promise is marked
--     with a reason (and an optional "until" date); the page leaves them out of
--     reminders, letters and the hold list. Clearing keeps the row (is_active).
--   * SETTINGS per school: the late fee (amount per overdue month, after a grace
--     of N days) and the hold rule (hold after N months pending).
--   * LATE FEE. One "Late Fee" line per overdue month per child, added only when
--     the office presses Apply after a preview; a month that already has one (even
--     waived / closed) never gets a second. Late fee lines are not themselves
--     "months pending".
--
--   core.sp_fee_followup       Add | List | Done
--   core.sp_fee_no_chase       Set | Clear
--   core.sp_fee_dues_settings  Get | Save
--   core.sp_fee_late_fee       Preview | Apply
-- ============================================================================

CREATE TABLE IF NOT EXISTS core.fee_followups (
    followup_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id    integer NOT NULL,
    school_id    integer NOT NULL,
    student_id   integer NOT NULL,
    note         varchar(300) NOT NULL,
    promise_date date,
    is_done      boolean NOT NULL DEFAULT FALSE,
    done_by      integer,
    done_at      timestamptz,
    created_by   integer NOT NULL DEFAULT 0,
    created_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT chk_fee_followup_scope CHECK (tenant_id > 1 AND school_id > 0)
);
CREATE INDEX IF NOT EXISTS ix_fee_followups_student ON core.fee_followups (tenant_id, school_id, student_id);

CREATE TABLE IF NOT EXISTS core.fee_no_chase (
    tenant_id  integer NOT NULL,
    school_id  integer NOT NULL,
    student_id integer NOT NULL,
    reason     varchar(200) NOT NULL,
    until_date date,
    is_active  boolean NOT NULL DEFAULT TRUE,
    set_by     integer NOT NULL DEFAULT 0,
    set_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pk_fee_no_chase PRIMARY KEY (tenant_id, school_id, student_id)
);

CREATE TABLE IF NOT EXISTS core.fee_dues_settings (
    tenant_id           integer NOT NULL,
    school_id           integer NOT NULL,
    late_fee_amount     numeric(10,2) NOT NULL DEFAULT 0,   -- 0 = no late fee
    late_fee_grace_days integer NOT NULL DEFAULT 10,
    hold_after_months   integer NOT NULL DEFAULT 3,         -- 0 = no hold rule
    updated_by          integer,
    updated_at          timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pk_fee_dues_settings PRIMARY KEY (tenant_id, school_id),
    CONSTRAINT chk_fee_dues_settings CHECK (late_fee_amount >= 0 AND late_fee_grace_days >= 0 AND hold_after_months >= 0)
);


CREATE OR REPLACE PROCEDURE core.sp_fee_followup(
    IN    p_operation      varchar,
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_student_id     integer DEFAULT NULL,
    IN    p_note           varchar DEFAULT NULL,
    IN    p_promise_date   varchar DEFAULT NULL,   -- yyyy-MM-dd, optional
    IN    p_followup_id    integer DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'fee_followup_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_id integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    IF p_operation = 'Add' THEN
        IF NOT EXISTS (SELECT 1 FROM core.students WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id) THEN
            RAISE EXCEPTION 'Student not found.';
        END IF;
        IF NULLIF(trim(p_note), '') IS NULL THEN
            RAISE EXCEPTION 'Write what the parent said.';
        END IF;
        INSERT INTO core.fee_followups (tenant_id, school_id, student_id, note, promise_date, created_by)
        VALUES (p_tenant_id, p_school_id, p_student_id, left(trim(p_note), 300), NULLIF(trim(p_promise_date), '')::date, p_action_user_id)
        RETURNING followup_id INTO v_id;
        OPEN p_result FOR SELECT TRUE AS success, v_id AS followup_id, 'Note saved.' AS message;
        RETURN;
    END IF;

    IF p_operation = 'List' THEN
        OPEN p_result FOR
        SELECT f.followup_id, f.note, COALESCE(f.promise_date::text, '') AS promise_date, f.is_done,
               to_char(f.created_at AT TIME ZONE 'Asia/Kolkata', 'YYYY-MM-DD') AS created_on,
               core.fn_user_display_name(f.created_by) AS created_by_name
          FROM core.fee_followups f
         WHERE f.tenant_id = p_tenant_id AND f.school_id = p_school_id AND f.student_id = p_student_id
         ORDER BY f.followup_id DESC;
        RETURN;
    END IF;

    IF p_operation = 'Done' THEN
        UPDATE core.fee_followups SET is_done = TRUE, done_by = p_action_user_id, done_at = now()
         WHERE followup_id = p_followup_id AND tenant_id = p_tenant_id AND school_id = p_school_id AND NOT is_done;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Note not found, or already done.';
        END IF;
        OPEN p_result FOR SELECT TRUE AS success, 'Marked done.' AS message;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation.';
END;
$procedure$;


CREATE OR REPLACE PROCEDURE core.sp_fee_no_chase(
    IN    p_operation      varchar,
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_student_id     integer,
    IN    p_reason         varchar DEFAULT NULL,
    IN    p_until          varchar DEFAULT NULL,   -- yyyy-MM-dd, optional
    INOUT p_result         refcursor DEFAULT 'fee_no_chase_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM core.students WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id) THEN
        RAISE EXCEPTION 'Student not found.';
    END IF;

    IF p_operation = 'Set' THEN
        IF NULLIF(trim(p_reason), '') IS NULL THEN
            RAISE EXCEPTION 'Give the reason (scholarship, RTE seat, promise ...).';
        END IF;
        INSERT INTO core.fee_no_chase (tenant_id, school_id, student_id, reason, until_date, is_active, set_by, set_at)
        VALUES (p_tenant_id, p_school_id, p_student_id, left(trim(p_reason), 200), NULLIF(trim(p_until), '')::date, TRUE, p_action_user_id, now())
        ON CONFLICT (tenant_id, school_id, student_id)
        DO UPDATE SET reason = EXCLUDED.reason, until_date = EXCLUDED.until_date, is_active = TRUE,
                      set_by = EXCLUDED.set_by, set_at = now();
        OPEN p_result FOR SELECT TRUE AS success, 'Not chased: reminders, letters and the hold list leave this child out.' AS message;
        RETURN;
    END IF;

    IF p_operation = 'Clear' THEN
        UPDATE core.fee_no_chase SET is_active = FALSE, set_by = p_action_user_id, set_at = now()
         WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND student_id = p_student_id AND is_active;
        OPEN p_result FOR SELECT TRUE AS success, 'The child is chased again.' AS message;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation.';
END;
$procedure$;


CREATE OR REPLACE PROCEDURE core.sp_fee_dues_settings(
    IN    p_operation      varchar,
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_late_fee       numeric DEFAULT NULL,
    IN    p_grace_days     integer DEFAULT NULL,
    IN    p_hold_months    integer DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'fee_dues_settings_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    IF p_operation = 'Save' THEN
        IF COALESCE(p_late_fee, 0) < 0 OR p_late_fee <> round(p_late_fee, 2) THEN
            RAISE EXCEPTION 'The late fee is a rupee amount (0 = none).';
        END IF;
        IF COALESCE(p_grace_days, 0) < 0 OR COALESCE(p_grace_days, 0) > 90 THEN
            RAISE EXCEPTION 'Grace days are between 0 and 90.';
        END IF;
        IF COALESCE(p_hold_months, 0) < 0 OR COALESCE(p_hold_months, 0) > 12 THEN
            RAISE EXCEPTION 'Hold after 0 (off) to 12 months.';
        END IF;
        INSERT INTO core.fee_dues_settings (tenant_id, school_id, late_fee_amount, late_fee_grace_days, hold_after_months, updated_by, updated_at)
        VALUES (p_tenant_id, p_school_id, COALESCE(p_late_fee, 0), COALESCE(p_grace_days, 10), COALESCE(p_hold_months, 3), p_action_user_id, now())
        ON CONFLICT (tenant_id, school_id)
        DO UPDATE SET late_fee_amount = EXCLUDED.late_fee_amount, late_fee_grace_days = EXCLUDED.late_fee_grace_days,
                      hold_after_months = EXCLUDED.hold_after_months, updated_by = EXCLUDED.updated_by, updated_at = now();
    END IF;

    OPEN p_result FOR
    SELECT COALESCE(s.late_fee_amount, 0) AS late_fee_amount, COALESCE(s.late_fee_grace_days, 10) AS grace_days,
           COALESCE(s.hold_after_months, 3) AS hold_months
      FROM (SELECT 1) x
      LEFT JOIN core.fee_dues_settings s ON s.tenant_id = p_tenant_id AND s.school_id = p_school_id;
END;
$procedure$;


-- Late fees: Preview lists what Apply would add; Apply adds it. p_student_ids
-- (a JSON array) limits it to those children; empty = everyone in the session.
CREATE OR REPLACE PROCEDURE core.sp_fee_late_fee(
    IN    p_operation      varchar,
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_academic_year  varchar,
    IN    p_student_ids    jsonb DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'fee_late_fee_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_amount numeric;
    v_grace  integer;
    v_start  date;
    v_n      integer;
    v_total  numeric;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;
    IF NULLIF(trim(p_academic_year), '') IS NULL THEN
        RAISE EXCEPTION 'Choose the session.';
    END IF;
    SELECT late_fee_amount, late_fee_grace_days INTO v_amount, v_grace
      FROM core.fee_dues_settings WHERE tenant_id = p_tenant_id AND school_id = p_school_id;
    IF COALESCE(v_amount, 0) <= 0 THEN
        RAISE EXCEPTION 'Set the late fee first (Settings on this page).';
    END IF;
    SELECT NULLIF(y.start_date, '')::date INTO v_start
      FROM academic.academic_years y
     WHERE y.tenant_id = p_tenant_id AND y.school_id = p_school_id AND y.academic_year_name = p_academic_year LIMIT 1;
    v_start := COALESCE(v_start, date_trunc('month', CURRENT_DATE)::date);

    -- months a child still owes, past the grace days, with no late fee line yet
    DROP TABLE IF EXISTS _late;
    CREATE TEMP TABLE _late ON COMMIT DROP AS
    SELECT l.student_id, s.student_name, COALESCE(e.class_name, s.class_name) AS class_name, COALESCE(e.section, s.section) AS section,
           date_trunc('month', COALESCE(NULLIF(l.due_date, '')::date, v_start))::date AS month
      FROM core.student_ledger l
      JOIN core.students s ON s.student_id = l.student_id
      LEFT JOIN core.student_enrolment e ON e.student_id = l.student_id AND e.academic_year = p_academic_year
     WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id AND l.academic_year = p_academic_year
       AND l.fee_head_name <> 'Late Fee'
       AND l.amount_due - l.amount_paid - l.concession > 0
       AND COALESCE(NULLIF(l.due_date, '')::date, v_start) + v_grace < CURRENT_DATE
       AND COALESCE(s.is_active, TRUE) AND COALESCE(e.status, '') NOT IN ('Left', 'PassedOut')
       AND (p_student_ids IS NULL OR jsonb_array_length(p_student_ids) = 0
            OR l.student_id IN (SELECT (x)::int FROM jsonb_array_elements_text(p_student_ids) x))
       AND NOT EXISTS (SELECT 1 FROM core.fee_no_chase nc
                        WHERE nc.tenant_id = p_tenant_id AND nc.school_id = p_school_id AND nc.student_id = l.student_id
                          AND nc.is_active AND (nc.until_date IS NULL OR nc.until_date >= CURRENT_DATE))
     GROUP BY l.student_id, s.student_name, COALESCE(e.class_name, s.class_name), COALESCE(e.section, s.section),
              date_trunc('month', COALESCE(NULLIF(l.due_date, '')::date, v_start));
    DELETE FROM _late lt
     WHERE EXISTS (SELECT 1 FROM core.student_ledger x
                    WHERE x.tenant_id = p_tenant_id AND x.school_id = p_school_id AND x.student_id = lt.student_id
                      AND x.academic_year = p_academic_year AND x.fee_head_name = 'Late Fee'
                      AND x.installment_label = to_char(lt.month, 'Mon YYYY'));

    IF p_operation = 'Preview' THEN
        OPEN p_result FOR
        SELECT student_id, student_name, class_name, COALESCE(section, '') AS section,
               to_char(month, 'YYYY-MM') AS month, v_amount AS amount
          FROM _late ORDER BY class_name, section, student_name, month;
        RETURN;
    END IF;

    IF p_operation = 'Apply' THEN
        INSERT INTO core.student_ledger
            (tenant_id, school_id, student_id, fee_head_name, frequency, installment_label, due_date, amount_due, status, academic_year)
        SELECT p_tenant_id, p_school_id, student_id, 'Late Fee', 'One Time', to_char(month, 'Mon YYYY'),
               to_char(CURRENT_DATE, 'YYYY-MM-DD'), v_amount, 'Pending', p_academic_year
          FROM _late;
        GET DIAGNOSTICS v_n = ROW_COUNT;
        v_total := v_n * v_amount;
        OPEN p_result FOR
        SELECT TRUE AS success, v_n AS added,
               CASE WHEN v_n = 0 THEN 'No late fee to add: nobody is past the grace days without one.'
                    ELSE v_n || ' late fee line(s) added, Rs ' || to_char(v_total, 'FM99,99,99,990.00') || ' in all.' END AS message;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation.';
END;
$procedure$;
