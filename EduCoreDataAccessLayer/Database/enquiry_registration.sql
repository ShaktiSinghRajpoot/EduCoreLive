-- ============================================================================
-- Enquiry Registration
-- Registers an enquiry: issues a registration number, records the date and
-- (optional) fee, and moves the lead to "Registration Done".
-- Registration data lives on core.enquiries (registration_number/date). The fee is
-- taken by sp_registration_fee_record (registration_fee_partial.sql).
--
-- Target DB: PostgreSQL (educore)
-- Safe to re-run (idempotent).
-- ============================================================================

-- ── Per-session number counter (race-safe via upsert). Numbers carry the session year (REG-2027-0001, QA BUG-035) ──
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
    IN    p_registration_fee_paid boolean   DEFAULT FALSE,   -- IGNORED: kept for callers; paid follows the receipts
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
    v_year       text;
    v_tries      integer := 0;
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
      AND COALESCE(is_active, TRUE) = TRUE
    FOR UPDATE;   -- a double click must not register the same enquiry twice at once

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Enquiry not found.';
    END IF;

    IF v_admission IS NOT NULL THEN
        RAISE EXCEPTION 'This enquiry is already admitted.';
    END IF;

    -- Already registered and nothing new asked for (a retry or a double click):
    -- answer with the number it already has and write nothing, so the history
    -- does not grow a "Registration Done -> Registration Done" row.
    IF v_status = 'Registration Done' AND v_existing IS NOT NULL
       AND (NULLIF(trim(p_registration_number), '') IS NULL
            OR lower(trim(p_registration_number)) = lower(v_existing)) THEN
        OPEN p_result FOR
        SELECT TRUE AS success,
               'Already registered.' AS message,
               v_existing AS registration_number;
        RETURN;
    END IF;

    v_reg_date := COALESCE(p_registration_date, CURRENT_DATE);
    v_prefix   := COALESCE(NULLIF(trim(p_prefix), ''), 'REG-');

    -- One registration number at a time per school: the uniqueness check below
    -- and the write must not interleave with another desk doing the same.
    PERFORM pg_advisory_xact_lock(hashtextextended('enquiry_register:' || p_tenant_id || ':' || p_school_id, 0));

    -- Resolve the number: manual entry > already-issued number > auto-generated.
    v_reg_number := NULLIF(trim(p_registration_number), '');

    IF v_reg_number IS NULL THEN
        v_reg_number := v_existing;          -- never burn a new sequence on re-save
    END IF;

    IF v_reg_number IS NULL THEN
        IF COALESCE(p_auto_generate, TRUE) THEN
            -- QA BUG-035: the counter is per session, so the number carries the
            -- session's start year (same rule as ADM-/RCP- numbers). A number some
            -- one typed by hand may already hold the next value: skip past it.
            v_year := core.fn_receipt_year(p_tenant_id, p_school_id, v_session, v_reg_date);
            LOOP
                INSERT INTO core.registration_counters (tenant_id, school_id, session, last_seq)
                VALUES (p_tenant_id, p_school_id, COALESCE(v_session, 'NA'), 1)
                ON CONFLICT (tenant_id, school_id, session)
                DO UPDATE SET last_seq = core.registration_counters.last_seq + 1
                RETURNING last_seq INTO v_seq;

                v_reg_number := v_prefix || v_year || '-' || lpad(v_seq::text, 4, '0');

                EXIT WHEN NOT EXISTS (
                    SELECT 1 FROM core.enquiries
                     WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                       AND enquiry_id <> p_enquiry_id
                       AND lower(registration_number) = lower(v_reg_number));
                v_tries := v_tries + 1;
                IF v_tries > 1000 THEN
                    RAISE EXCEPTION 'Could not find a free registration number. Enter one by hand.';
                END IF;
            END LOOP;
        ELSE
            RAISE EXCEPTION 'Registration number is required.';
        END IF;
    END IF;

    -- A number belongs to one child in the whole school, across every session
    -- (it used to be checked within the session only, which is how two
    -- REG-0001 came about). Withdrawn and deleted enquiries keep theirs too.
    IF EXISTS (SELECT 1 FROM core.enquiries
               WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                 AND enquiry_id <> p_enquiry_id
                 AND lower(registration_number) = lower(v_reg_number)) THEN
        RAISE EXCEPTION 'Registration number % is already used by another student.', v_reg_number;
    END IF;

    UPDATE core.enquiries
    SET registration_number   = v_reg_number,
        registration_date     = v_reg_date,
        -- Never taken from the caller: the browser's "fee paid" tick used to land
        -- here and mark the fee paid with no receipt. Paid follows the money.
        registration_fee_paid = COALESCE(core.fn_registration_fee_is_paid(p_tenant_id, p_school_id, p_enquiry_id), FALSE),
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
         'Registered - ' || v_reg_number, p_action_user_id);

    OPEN p_result FOR
    SELECT TRUE AS success,
           'Registration completed.' AS message,
           v_reg_number AS registration_number;
END;
$procedure$;
