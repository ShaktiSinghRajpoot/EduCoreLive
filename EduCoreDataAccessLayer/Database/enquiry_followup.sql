-- Follow-up log for an enquiry: add a note and move the next follow-up date.
-- This procedure was live in the database but had no source file here, so the
-- repo could not rebuild it. Captured from the database and kept with the
-- other feature scripts.

CREATE OR REPLACE PROCEDURE core.sp_enquiry_followup_manage(IN p_operation text, IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_enquiry_id integer DEFAULT NULL::integer, IN p_followup_type text DEFAULT 'Call'::text, IN p_outcome text DEFAULT NULL::text, IN p_notes text DEFAULT NULL::text, IN p_next_followup_date date DEFAULT NULL::date, IN p_new_status text DEFAULT NULL::text, IN p_lost_reason text DEFAULT NULL::text, INOUT p_result refcursor DEFAULT 'followup_cursor'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_status_before VARCHAR(60);
BEGIN

    -- ── LogFollowup ───────────────────────────────────────────
    IF p_operation = 'LogFollowup' THEN

        SELECT status INTO v_status_before
        FROM core.enquiries
        WHERE enquiry_id = p_enquiry_id
          AND tenant_id  = p_tenant_id
          AND school_id  = p_school_id
          AND is_active  = TRUE;

        INSERT INTO core.enquiry_followups (
            enquiry_id, tenant_id, school_id,
            followup_type, outcome, notes,
            next_followup_date,
            status_before, status_after,
            created_by
        ) VALUES (
            p_enquiry_id, p_tenant_id, p_school_id,
            COALESCE(p_followup_type, 'Call'),
            p_outcome,
            p_notes,
            p_next_followup_date,
            v_status_before,
            COALESCE(p_new_status, v_status_before),
            p_action_user_id
        );

        UPDATE core.enquiries SET
            next_followup_date = COALESCE(p_next_followup_date::text, next_followup_date),
            status             = COALESCE(p_new_status,          status),
            lost_reason        = CASE
                                    WHEN p_new_status IN ('Not Interested', 'Dropped')
                                    THEN COALESCE(p_lost_reason, lost_reason)
                                    ELSE lost_reason
                                 END,
            updated_by         = p_action_user_id,
            updated_at         = NOW()
        WHERE enquiry_id = p_enquiry_id
          AND tenant_id  = p_tenant_id
          AND school_id  = p_school_id
          AND is_active  = TRUE;

        IF p_new_status IS NOT NULL AND p_new_status IS DISTINCT FROM v_status_before THEN
            INSERT INTO core.enquiry_status_history (
                enquiry_id, tenant_id, school_id,
                status_from, status_to,
                change_note, changed_by
            ) VALUES (
                p_enquiry_id, p_tenant_id, p_school_id,
                v_status_before, p_new_status,
                p_notes, p_action_user_id
            );
        END IF;

        OPEN p_result FOR SELECT 1 AS success;
        RETURN;

    -- ── GetFollowups ──────────────────────────────────────────
    ELSIF p_operation = 'GetFollowups' THEN
        OPEN p_result FOR
            SELECT
                followup_id, followup_date, followup_type,
                outcome, notes, next_followup_date,
                status_before, status_after,
                created_by, created_at
            FROM core.enquiry_followups
            WHERE enquiry_id = p_enquiry_id
              AND tenant_id  = p_tenant_id
              AND school_id  = p_school_id
            ORDER BY created_at DESC;
        RETURN;

    -- ── GetStatusHistory ──────────────────────────────────────
    ELSIF p_operation = 'GetStatusHistory' THEN
        OPEN p_result FOR
            SELECT
                history_id, status_from, status_to,
                change_note, changed_by, created_at
            FROM core.enquiry_status_history
            WHERE enquiry_id = p_enquiry_id
              AND tenant_id  = p_tenant_id
              AND school_id  = p_school_id
            ORDER BY created_at ASC;
        RETURN;

    END IF;

    -- Fallback: no operation matched
    OPEN p_result FOR SELECT 0 AS success WHERE FALSE;

END;
$procedure$
;

