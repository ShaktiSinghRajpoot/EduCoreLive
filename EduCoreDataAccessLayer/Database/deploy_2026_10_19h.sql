-- Bundle 2026-10-19h: School > Import Data -- previous dues from the old software. Run with:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_19h.sql
-- Sources: data_import.sql

-- ============================================================================
-- Bringing a new school's records in (School > Import Data, 19 Oct 2026).
--
-- Students and staff are imported through the screens' own procedures
-- (core.sp_admission_manage, core.sp_staff_manage), one row at a time, so an
-- imported child is billed exactly like one admitted at the counter.
--
-- What has no procedure of its own is the money a family still owed in the
-- school's OLD software. core.sp_import_opening_due puts it on the child as one
-- due line, "Previous Dues", carried from the session it belongs to -- the same
-- shape Year-End leaves when it carries a balance forward, so the fee counter,
-- Month-wise Dues, reminders and receipts all show it as old dues.
--
-- One call = one child. Refused (with a message, nothing written) when the
-- admission number is not an active child of this school, the amount is not
-- above zero, or the same child already has an imported opening due -- a file
-- uploaded twice must not bill a family twice.
-- ============================================================================

CREATE OR REPLACE PROCEDURE core.sp_import_opening_due(
    IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer,
    IN p_admission_no character varying, IN p_amount numeric, IN p_note character varying DEFAULT NULL,
    IN p_from_session character varying DEFAULT NULL,
    INOUT p_result refcursor DEFAULT 'opening_due_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_student  integer;
    v_name     text;
    v_year     text;
    v_start    date;
    v_from     text;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    SELECT student_id, student_name INTO v_student, v_name
      FROM core.students
     WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND is_active
       AND upper(trim(admission_no)) = upper(trim(p_admission_no));
    IF v_student IS NULL THEN
        OPEN p_result FOR SELECT FALSE AS success, format('No active student with admission no %s.', trim(p_admission_no)) AS message;
        RETURN;
    END IF;
    IF COALESCE(p_amount, 0) <= 0 THEN
        OPEN p_result FOR SELECT FALSE AS success, 'The amount must be more than 0.' AS message;
        RETURN;
    END IF;
    IF EXISTS (SELECT 1 FROM core.student_ledger
                WHERE student_id = v_student AND fee_head_name = 'Previous Dues'
                  AND COALESCE(status, '') <> 'Closed') THEN
        OPEN p_result FOR SELECT FALSE AS success, format('%s already has previous dues on record.', v_name) AS message;
        RETURN;
    END IF;

    SELECT academic_year_name, start_date INTO v_year, v_start
      FROM academic.academic_years
     WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND is_current AND NOT COALESCE(is_deleted, FALSE)
     LIMIT 1;
    IF v_year IS NULL THEN
        RAISE EXCEPTION 'Set a current session first (School > Sessions).';
    END IF;
    -- the session the money belongs to: as given, else the one before the current
    v_from := COALESCE(NULLIF(trim(p_from_session), ''),
                       (extract(year FROM v_start)::int - 1) || '-' || right((extract(year FROM v_start)::int)::text, 2));

    INSERT INTO core.student_ledger (tenant_id, school_id, student_id, fee_head_name, frequency, installment_label,
                                     due_date, amount_due, status, academic_year, carried_from, carried_by, carried_at)
    VALUES (p_tenant_id, p_school_id, v_student, 'Previous Dues', 'One Time',
            COALESCE(NULLIF(trim(p_note), ''), 'Balance from old records'),
            v_start::text, round(p_amount, 2), 'Pending', v_year, v_from, p_action_user_id, now());

    OPEN p_result FOR SELECT TRUE AS success, format('%s: Rs %s added as previous dues.', v_name, round(p_amount, 2)) AS message;
END;
$procedure$;
