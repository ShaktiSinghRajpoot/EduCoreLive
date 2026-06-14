-- ============================================================================
-- Enquiry Registration
-- Registers an enquiry: issues a registration number, records the date and
-- (optional) fee, and moves the lead to "Registration Done".
-- Registration data lives on core.enquiries (registration_number/date/fee_paid).
--
-- Target DB: PostgreSQL (educore)
-- Safe to re-run (idempotent).
-- ============================================================================

-- ── Per-session number counter (race-safe via upsert) ───────────────────────
CREATE TABLE IF NOT EXISTS core.registration_counters
(
    tenant_id  integer     NOT NULL,
    school_id  integer     NOT NULL,
    session    varchar(20) NOT NULL,
    last_seq   integer     NOT NULL DEFAULT 0,
    CONSTRAINT pk_registration_counters PRIMARY KEY (tenant_id, school_id, session)
);

-- ── Registration procedure ──────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE core.sp_enquiry_register(
    IN    p_tenant_id             integer,
    IN    p_school_id             integer,
    IN    p_action_user_id        integer,
    IN    p_enquiry_id            integer,
    IN    p_registration_number   varchar   DEFAULT NULL,   -- manual number (optional)
    IN    p_registration_date     date      DEFAULT NULL,   -- defaults to today
    IN    p_registration_fee_paid boolean   DEFAULT FALSE,
    IN    p_auto_generate         boolean   DEFAULT TRUE,
    IN    p_prefix                varchar   DEFAULT 'REG-',
    INOUT p_result                refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_status     varchar;
    v_admission  integer;
    v_session    varchar;
    v_existing   varchar;
    v_reg_number varchar;
    v_seq        integer;
    v_prefix     varchar;
    v_reg_date   date;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR p_enquiry_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;

    SELECT status, admission_id, session, registration_number
      INTO v_status, v_admission, v_session, v_existing
    FROM core.enquiries
    WHERE enquiry_id = p_enquiry_id
      AND tenant_id  = p_tenant_id
      AND school_id  = p_school_id
      AND COALESCE(is_active, TRUE) = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Enquiry not found.';
    END IF;

    IF v_admission IS NOT NULL THEN
        RAISE EXCEPTION 'This enquiry is already admitted.';
    END IF;

    v_reg_date := COALESCE(p_registration_date, CURRENT_DATE);
    v_prefix   := COALESCE(NULLIF(trim(p_prefix), ''), 'REG-');

    -- Resolve the number: manual entry > already-issued number > auto-generated.
    v_reg_number := NULLIF(trim(p_registration_number), '');

    IF v_reg_number IS NULL THEN
        v_reg_number := v_existing;          -- never burn a new sequence on re-save
    END IF;

    IF v_reg_number IS NULL THEN
        IF COALESCE(p_auto_generate, TRUE) THEN
            INSERT INTO core.registration_counters (tenant_id, school_id, session, last_seq)
            VALUES (p_tenant_id, p_school_id, COALESCE(v_session, 'NA'), 1)
            ON CONFLICT (tenant_id, school_id, session)
            DO UPDATE SET last_seq = core.registration_counters.last_seq + 1
            RETURNING last_seq INTO v_seq;

            v_reg_number := v_prefix || lpad(v_seq::text, 4, '0');
        ELSE
            RAISE EXCEPTION 'Registration number is required.';
        END IF;
    END IF;

    UPDATE core.enquiries
    SET registration_number   = v_reg_number,
        registration_date     = v_reg_date,
        registration_fee_paid = COALESCE(p_registration_fee_paid, FALSE),
        status                = 'Registration Done',
        updated_by            = p_action_user_id,
        updated_at            = NOW()
    WHERE enquiry_id = p_enquiry_id
      AND tenant_id  = p_tenant_id
      AND school_id  = p_school_id;

    INSERT INTO core.enquiry_status_history
        (enquiry_id, tenant_id, school_id, status_from, status_to, change_note, changed_by)
    VALUES
        (p_enquiry_id, p_tenant_id, p_school_id, v_status, 'Registration Done',
         'Registered · ' || v_reg_number, p_action_user_id);

    OPEN p_result FOR
    SELECT TRUE AS success,
           'Registration completed.' AS message,
           v_reg_number AS registration_number;
END;
$procedure$;
