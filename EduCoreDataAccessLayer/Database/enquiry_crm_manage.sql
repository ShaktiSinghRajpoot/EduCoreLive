-- ============================================================
-- Enquiry CRM — list ordering + server-side sorting
--
-- GetEnquiries used to order as a follow-up work queue (overdue first,
-- then next follow-up date). The CRM list is now a plain register that
-- defaults to newest-first and supports clickable column sorting, so it
-- takes p_sort_column / p_sort_dir like core.sp_student_list does.
--
-- Sorting uses the same whitelisted CASE form as sp_student_list: the
-- column key is matched against a fixed list, never interpolated into
-- SQL, so no dynamic SQL and nothing injectable. Accepted keys are
-- name, class, status, source, nextfu, age; anything else (including
-- NULL) falls through to the default created_at DESC, enquiry_id DESC.
--
-- NOTE: this DROPs and re-CREATEs the procedure rather than using
-- CREATE OR REPLACE, because adding parameters changes the signature and
-- REPLACE cannot do that. DDL is transactional in Postgres, so wrapping
-- the run in BEGIN/COMMIT makes the swap atomic.
-- ============================================================

DROP PROCEDURE IF EXISTS core.sp_enquiry_crm_manage;

CREATE PROCEDURE core.sp_enquiry_crm_manage(IN p_operation text, IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_enquiry_id integer DEFAULT NULL::integer, IN p_student_name text DEFAULT NULL::text, IN p_gender text DEFAULT NULL::text, IN p_dob date DEFAULT NULL::date, IN p_class_name text DEFAULT NULL::text, IN p_session text DEFAULT NULL::text, IN p_interested_stream text DEFAULT NULL::text, IN p_parent_name text DEFAULT NULL::text, IN p_father_name text DEFAULT NULL::text, IN p_father_mobile text DEFAULT NULL::text, IN p_mother_name text DEFAULT NULL::text, IN p_mother_mobile text DEFAULT NULL::text, IN p_mobile text DEFAULT NULL::text, IN p_alt_mobile text DEFAULT NULL::text, IN p_city text DEFAULT NULL::text, IN p_area_locality text DEFAULT NULL::text, IN p_lead_source text DEFAULT NULL::text, IN p_referrer_name text DEFAULT NULL::text, IN p_referrer_mobile text DEFAULT NULL::text, IN p_priority text DEFAULT NULL::text, IN p_status text DEFAULT NULL::text, IN p_assigned_to_id integer DEFAULT NULL::integer, IN p_lost_reason text DEFAULT NULL::text, IN p_lost_to_school text DEFAULT NULL::text, IN p_next_followup_date date DEFAULT NULL::date, IN p_notes text DEFAULT NULL::text, IN p_estimated_fee numeric DEFAULT NULL::numeric, IN p_registration_number text DEFAULT NULL::text, IN p_registration_date date DEFAULT NULL::date, IN p_registration_fee_paid boolean DEFAULT false, IN p_parent_email text DEFAULT NULL::text, IN p_current_class text DEFAULT NULL::text, IN p_current_school text DEFAULT NULL::text, IN p_transport_required boolean DEFAULT false, IN p_whatsapp_number text DEFAULT NULL::text, IN p_page_number integer DEFAULT 1, IN p_page_size integer DEFAULT 10, IN p_search text DEFAULT NULL::text, IN p_filter_session text DEFAULT NULL::text, IN p_filter_priority text DEFAULT NULL::text, IN p_filter_class text DEFAULT NULL::text, IN p_filter_source text DEFAULT NULL::text, IN p_filter_pipeline text DEFAULT NULL::text, IN p_filter_assigned_to integer DEFAULT NULL::integer, IN p_filter_overdue boolean DEFAULT false, IN p_filter_today boolean DEFAULT false, IN p_sort_column text DEFAULT NULL::text, IN p_sort_dir text DEFAULT 'asc'::text, INOUT p_result refcursor DEFAULT 'enquiry_cursor'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_sort_col       TEXT;
    v_sort_asc       BOOLEAN;
    v_enquiry_id     INTEGER;
    v_status_before  VARCHAR(60);
    v_today          DATE := CURRENT_DATE;
BEGIN

    -- ── GetEnquiries (filtered + paginated) ──────────────────
    IF p_operation = 'GetEnquiries' THEN
        v_sort_col := LOWER(TRIM(COALESCE(p_sort_column, '')));
        v_sort_asc := LOWER(TRIM(COALESCE(p_sort_dir, 'asc'))) <> 'desc';

        OPEN p_result FOR
            WITH filtered AS (
                SELECT
                    e.enquiry_id,
                    e.student_name,
                    e.gender,
                    e.dob,
                    e.class_name,
                    e.session,
                    e.interested_stream,
                    COALESCE(e.father_name, e.parent_name) AS parent_name,
                    e.father_name,
                    e.father_mobile,
                    e.mother_name,
                    e.mother_mobile,
                    e.mobile,
                    e.alt_mobile,
                    e.city,
                    e.area_locality,
                    e.lead_source,
                    e.referrer_name,
                    e.priority,
                    e.status,
                    e.assigned_to_id,
                    e.lost_reason,
                    e.enquiry_date,
                    e.next_followup_date,
                    e.notes,
                    e.estimated_fee,
                    e.registration_number,
                    e.registration_fee_paid,
                    e.admission_id,
                    e.parent_email,
                    e.current_class,
                    e.current_school,
                    e.transport_required,
                    e.whatsapp_number,
                    e.created_at,
                    e.updated_at,
                    (v_today - e.enquiry_date)              AS days_since_enquiry,
                    (SELECT COUNT(*)::INTEGER
                       FROM core.enquiry_followups f
                      WHERE f.enquiry_id = e.enquiry_id)   AS followup_count,
                    CASE
                        WHEN e.next_followup_date < v_today
                             AND e.status NOT IN ('Admission Confirmed','Not Interested','Dropped')
                        THEN TRUE ELSE FALSE
                    END AS is_overdue,
                    CASE
                        WHEN e.next_followup_date = v_today THEN TRUE ELSE FALSE
                    END AS is_today
                FROM core.enquiries e
                WHERE e.tenant_id = p_tenant_id
                  AND e.school_id = p_school_id
                  AND e.is_active = TRUE
                  AND (
                      p_search IS NULL OR TRIM(p_search) = ''
                      OR LOWER(e.student_name) LIKE '%' || LOWER(TRIM(p_search)) || '%'
                      OR LOWER(COALESCE(e.father_name, e.parent_name, ''))
                                               LIKE '%' || LOWER(TRIM(p_search)) || '%'
                      OR e.mobile              LIKE '%' || TRIM(p_search) || '%'
                      OR COALESCE(e.father_mobile,'') LIKE '%' || TRIM(p_search) || '%'
                  )
                  AND (p_filter_session    IS NULL OR TRIM(p_filter_session)  = '' OR LOWER(e.session)     = LOWER(TRIM(p_filter_session)))
                  AND (p_filter_priority   IS NULL OR TRIM(p_filter_priority) = '' OR LOWER(e.priority)    = LOWER(TRIM(p_filter_priority)))
                  AND (p_filter_class      IS NULL OR TRIM(p_filter_class)    = '' OR LOWER(e.class_name)  = LOWER(TRIM(p_filter_class)))
                  AND (p_filter_source     IS NULL OR TRIM(p_filter_source)   = '' OR LOWER(e.lead_source) = LOWER(TRIM(p_filter_source)))
                  AND (p_filter_assigned_to IS NULL OR e.assigned_to_id = p_filter_assigned_to)
                  AND (
                      p_filter_pipeline IS NULL OR TRIM(p_filter_pipeline) = '' OR p_filter_pipeline = 'all'
                      OR (p_filter_pipeline = 'new'           AND e.status = 'New')
                      OR (p_filter_pipeline = 'followup'      AND e.status = 'Follow-up Pending')
                      OR (p_filter_pipeline = 'interested'    AND e.status = 'Interested')
                      OR (p_filter_pipeline = 'campusvisit'   AND e.status = 'Campus Visit Scheduled')
                      OR (p_filter_pipeline = 'registered'    AND e.status = 'Registration Done')
                      OR (p_filter_pipeline = 'admitted'      AND e.status = 'Admission Confirmed')
                      OR (p_filter_pipeline = 'notinterested' AND e.status IN ('Not Interested','Dropped'))
                  )
                  AND (
                      NOT COALESCE(p_filter_overdue, FALSE) OR
                      (e.next_followup_date < v_today AND e.status NOT IN ('Admission Confirmed','Not Interested','Dropped'))
                  )
                  AND (NOT COALESCE(p_filter_today, FALSE) OR e.next_followup_date = v_today)
            )
            SELECT *, COUNT(*) OVER() AS total_count
            FROM filtered
            ORDER BY
                -- Whitelisted, injection-safe sort (no dynamic SQL).
                CASE WHEN v_sort_col = 'name'    AND v_sort_asc     THEN student_name       END ASC,
                CASE WHEN v_sort_col = 'name'    AND NOT v_sort_asc THEN student_name       END DESC,
                CASE WHEN v_sort_col = 'class'   AND v_sort_asc     THEN class_name         END ASC,
                CASE WHEN v_sort_col = 'class'   AND NOT v_sort_asc THEN class_name         END DESC,
                CASE WHEN v_sort_col = 'status'  AND v_sort_asc     THEN status             END ASC,
                CASE WHEN v_sort_col = 'status'  AND NOT v_sort_asc THEN status             END DESC,
                CASE WHEN v_sort_col = 'source'  AND v_sort_asc     THEN lead_source        END ASC,
                CASE WHEN v_sort_col = 'source'  AND NOT v_sort_asc THEN lead_source        END DESC,
                CASE WHEN v_sort_col = 'nextfu'  AND v_sort_asc     THEN next_followup_date END ASC,
                CASE WHEN v_sort_col = 'nextfu'  AND NOT v_sort_asc THEN next_followup_date END DESC,
                CASE WHEN v_sort_col = 'age'     AND v_sort_asc     THEN created_at         END ASC,
                CASE WHEN v_sort_col = 'age'     AND NOT v_sort_asc THEN created_at         END DESC,
                -- Default / tie-breaker: newest enquiry first. enquiry_id keeps the
                -- order stable across pages when two rows share a created_at.
                created_at DESC, enquiry_id DESC
            LIMIT  COALESCE(p_page_size,   10)
            OFFSET (COALESCE(p_page_number, 1) - 1) * COALESCE(p_page_size, 10);
        RETURN;

    -- ── GetKpiStats ───────────────────────────────────────────
    ELSIF p_operation = 'GetKpiStats' THEN
        OPEN p_result FOR
            SELECT
                COUNT(*) AS total_leads,
                COUNT(*) FILTER (WHERE next_followup_date = v_today) AS due_today,
                COUNT(*) FILTER (WHERE next_followup_date < v_today
                                   AND status NOT IN ('Admission Confirmed','Not Interested','Dropped')) AS overdue_count,
                COUNT(*) FILTER (WHERE status = 'Campus Visit Scheduled') AS campus_visits,
                COUNT(*) FILTER (WHERE status = 'Admission Confirmed') AS admitted,
                COUNT(*) FILTER (WHERE status = 'New') AS cnt_new,
                COUNT(*) FILTER (WHERE status = 'Follow-up Pending') AS cnt_followup,
                COUNT(*) FILTER (WHERE status = 'Interested') AS cnt_interested,
                COUNT(*) FILTER (WHERE status = 'Campus Visit Scheduled')AS cnt_campusvisit,
                COUNT(*) FILTER (WHERE status = 'Registration Done') AS cnt_registered,
                COUNT(*) FILTER (WHERE status IN ('Not Interested','Dropped')) AS cnt_not_interested,
                CASE WHEN COUNT(*) = 0 THEN 0::NUMERIC
                     ELSE ROUND(COUNT(*) FILTER (WHERE status = 'Admission Confirmed') * 100.0 / COUNT(*), 1)
                END AS conversion_rate
            FROM core.enquiries
            WHERE tenant_id = p_tenant_id
              AND school_id = p_school_id
              AND is_active = TRUE;
        RETURN;

    -- ── GetEnquiryById ────────────────────────────────────────
    ELSIF p_operation = 'GetEnquiryById' THEN
        OPEN p_result FOR
            SELECT
                e.*,
                COALESCE(e.father_name, e.parent_name) AS derived_parent_name,
                (v_today - e.enquiry_date)              AS days_since_enquiry,
                (SELECT COUNT(*)::INTEGER FROM core.enquiry_followups f
                  WHERE f.enquiry_id = e.enquiry_id)   AS followup_count,
                FALSE AS is_overdue,
                FALSE AS is_today,
                0     AS total_count
            FROM core.enquiries e
            WHERE e.enquiry_id = p_enquiry_id
              AND e.tenant_id  = p_tenant_id
              AND e.school_id  = p_school_id
              AND e.is_active  = TRUE;
        RETURN;

    -- ── SaveEnquiry ───────────────────────────────────────────
    ELSIF p_operation = 'SaveEnquiry' THEN
        IF p_enquiry_id IS NULL OR p_enquiry_id = 0 THEN
            INSERT INTO core.enquiries (
                tenant_id, school_id,
                student_name, gender, dob,
                class_name, session, interested_stream,
                parent_name, father_name, father_mobile,
                mother_name, mother_mobile,
                mobile, alt_mobile,
                city, area_locality,
                lead_source, referrer_name, referrer_mobile,
                priority, status, assigned_to_id,
                enquiry_date, next_followup_date, notes,
                parent_email, current_class, current_school,
                transport_required, whatsapp_number,
                created_by, updated_by
            ) VALUES (
                p_tenant_id, p_school_id,
                p_student_name, p_gender, p_dob,
                p_class_name, p_session, p_interested_stream,
                COALESCE(p_father_name, p_parent_name),
                p_father_name, p_father_mobile,
                p_mother_name, p_mother_mobile,
                p_mobile, p_alt_mobile,
                p_city, p_area_locality,
                COALESCE(p_lead_source, 'Walk-in'),
                p_referrer_name, p_referrer_mobile,
                COALESCE(p_priority, 'Warm'),
                COALESCE(p_status, 'New'),
                p_assigned_to_id,
                v_today, p_next_followup_date, p_notes,
                p_parent_email, p_current_class, p_current_school,
                COALESCE(p_transport_required, FALSE), p_whatsapp_number,
                p_action_user_id, p_action_user_id
            )
            RETURNING enquiry_id INTO v_enquiry_id;

            INSERT INTO core.enquiry_status_history (
                enquiry_id, tenant_id, school_id,
                status_from, status_to, change_note, changed_by
            ) VALUES (
                v_enquiry_id, p_tenant_id, p_school_id,
                NULL, COALESCE(p_status, 'New'), 'Enquiry created', p_action_user_id
            );
        ELSE
            SELECT status INTO v_status_before
            FROM core.enquiries
            WHERE enquiry_id = p_enquiry_id
              AND tenant_id  = p_tenant_id
              AND school_id  = p_school_id
              AND is_active  = TRUE;

            UPDATE core.enquiries SET
                student_name          = COALESCE(p_student_name,        student_name),
                gender                = COALESCE(p_gender,              gender),
                dob                   = COALESCE(p_dob,                 dob),
                class_name            = COALESCE(p_class_name,          class_name),
                session               = COALESCE(p_session,             session),
                interested_stream     = p_interested_stream,
                parent_name           = COALESCE(p_father_name, p_parent_name, parent_name),
                father_name           = COALESCE(p_father_name,         father_name),
                father_mobile         = COALESCE(p_father_mobile,       father_mobile),
                mother_name           = p_mother_name,
                mother_mobile         = p_mother_mobile,
                mobile                = COALESCE(p_mobile,              mobile),
                alt_mobile            = p_alt_mobile,
                city                  = p_city,
                area_locality         = p_area_locality,
                lead_source           = COALESCE(p_lead_source,         lead_source),
                referrer_name         = p_referrer_name,
                referrer_mobile       = p_referrer_mobile,
                priority              = COALESCE(p_priority,            priority),
                status                = COALESCE(p_status,              status),
                assigned_to_id        = p_assigned_to_id,
                lost_reason           = CASE WHEN p_status IN ('Not Interested','Dropped')
                                             THEN COALESCE(p_lost_reason, lost_reason)
                                             ELSE lost_reason END,
                next_followup_date    = p_next_followup_date,
                notes                 = p_notes,
                estimated_fee         = p_estimated_fee,
                registration_number   = COALESCE(p_registration_number, registration_number),
                registration_date     = COALESCE(p_registration_date,   registration_date),
                registration_fee_paid = COALESCE(p_registration_fee_paid, registration_fee_paid),
                parent_email          = p_parent_email,
                current_class         = p_current_class,
                current_school        = p_current_school,
                transport_required    = COALESCE(p_transport_required,  transport_required),
                whatsapp_number       = p_whatsapp_number,
                updated_by            = p_action_user_id,
                updated_at            = NOW()
            WHERE enquiry_id = p_enquiry_id
              AND tenant_id  = p_tenant_id
              AND school_id  = p_school_id
              AND is_active  = TRUE
            RETURNING enquiry_id INTO v_enquiry_id;

            IF p_status IS NOT NULL AND p_status IS DISTINCT FROM v_status_before THEN
                INSERT INTO core.enquiry_status_history (
                    enquiry_id, tenant_id, school_id,
                    status_from, status_to, change_note, changed_by
                ) VALUES (
                    v_enquiry_id, p_tenant_id, p_school_id,
                    v_status_before, p_status, p_notes, p_action_user_id
                );
            END IF;
        END IF;

        OPEN p_result FOR SELECT COALESCE(v_enquiry_id, 0) AS enquiry_id;
        RETURN;

    -- ── UpdateStatus ──────────────────────────────────────────
    ELSIF p_operation = 'UpdateStatus' THEN
        SELECT status INTO v_status_before
        FROM core.enquiries
        WHERE enquiry_id = p_enquiry_id
          AND tenant_id  = p_tenant_id
          AND school_id  = p_school_id
          AND is_active  = TRUE;

        IF v_status_before = 'Admission Confirmed' THEN
            OPEN p_result FOR
                SELECT 0 AS success, 'Status cannot be changed after Admission Confirmed.' AS message;
            RETURN;
        END IF;

        UPDATE core.enquiries SET
            status      = p_status,
            lost_reason = CASE WHEN p_status IN ('Not Interested','Dropped')
                               THEN COALESCE(p_lost_reason, lost_reason)
                               ELSE lost_reason END,
            updated_by  = p_action_user_id,
            updated_at  = NOW()
        WHERE enquiry_id = p_enquiry_id
          AND tenant_id  = p_tenant_id
          AND school_id  = p_school_id
          AND is_active  = TRUE;

        IF p_status IS DISTINCT FROM v_status_before THEN
            INSERT INTO core.enquiry_status_history (
                enquiry_id, tenant_id, school_id,
                status_from, status_to, change_note, changed_by
            ) VALUES (
                p_enquiry_id, p_tenant_id, p_school_id,
                v_status_before, p_status, p_notes, p_action_user_id
            );
        END IF;

        OPEN p_result FOR SELECT 1 AS success, 'Status updated.' AS message;
        RETURN;

    -- ── DeleteEnquiry ─────────────────────────────────────────
    ELSIF p_operation = 'DeleteEnquiry' THEN
        UPDATE core.enquiries SET
            is_active  = FALSE,
            updated_by = p_action_user_id,
            updated_at = NOW()
        WHERE enquiry_id = p_enquiry_id
          AND tenant_id  = p_tenant_id
          AND school_id  = p_school_id;

        OPEN p_result FOR SELECT 1 AS success;
        RETURN;

    END IF;

    -- Fallback: no operation matched
    OPEN p_result FOR SELECT 0 AS enquiry_id WHERE FALSE;

END;
$procedure$

;
