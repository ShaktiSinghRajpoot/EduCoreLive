-- ============================================================================
-- Registration Register
-- Lists registered enquiries with their registration number + details, and
-- supports cancel / mark-fee-collected actions. Registration data lives on
-- core.enquiries. Convert-to-admission reuses the existing admission flow.
--
-- Target DB: PostgreSQL (educore)
-- Safe to re-run (idempotent).
-- ============================================================================

CREATE OR REPLACE PROCEDURE core.sp_registration_manage(
    IN    p_operation      varchar,
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_enquiry_id     integer   DEFAULT NULL,
    IN    p_search         varchar   DEFAULT NULL,
    IN    p_session        varchar   DEFAULT NULL,
    IN    p_class          varchar   DEFAULT NULL,
    IN    p_fee_status     varchar   DEFAULT NULL,   -- 'paid' | 'unpaid' | NULL
    IN    p_reason         varchar   DEFAULT NULL,
    IN    p_page           integer   DEFAULT 1,
    IN    p_page_size      integer   DEFAULT 10,
    INOUT p_result         refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_offset    integer;
    v_size      integer;
    v_status    varchar;
    v_admission integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    -- ── Paged list of registered students ───────────────────────────────────
    IF p_operation = 'List' THEN
        v_size   := COALESCE(NULLIF(p_page_size, 0), 10);
        v_offset := GREATEST(COALESCE(p_page, 1) - 1, 0) * v_size;

        OPEN p_result FOR
        SELECT
            e.enquiry_id,
            e.registration_number,
            e.registration_date,
            e.registration_fee_paid,
            e.student_name,
            e.class_name,
            e.session,
            COALESCE(NULLIF(trim(e.father_name), ''), e.parent_name) AS parent_name,
            e.mobile,
            e.status,
            e.admission_id,
            COUNT(*) OVER() AS total_count
        FROM core.enquiries e
        WHERE e.tenant_id = p_tenant_id
          AND e.school_id = p_school_id
          AND e.is_active = TRUE
          AND e.registration_number IS NOT NULL
          AND (p_search IS NULL OR p_search = '' OR
               e.student_name        ILIKE '%' || p_search || '%' OR
               e.registration_number ILIKE '%' || p_search || '%' OR
               e.mobile              ILIKE '%' || p_search || '%')
          AND (p_session IS NULL OR p_session = '' OR e.session = p_session)
          AND (p_class   IS NULL OR p_class   = '' OR e.class_name = p_class)
          AND (p_fee_status IS NULL OR p_fee_status = '' OR
               (p_fee_status = 'paid'   AND e.registration_fee_paid = TRUE) OR
               (p_fee_status = 'unpaid' AND COALESCE(e.registration_fee_paid, FALSE) = FALSE))
        ORDER BY e.registration_date DESC NULLS LAST, e.enquiry_id DESC
        OFFSET v_offset LIMIT v_size;

    -- ── KPI counts ──────────────────────────────────────────────────────────
    ELSIF p_operation = 'Stats' THEN
        OPEN p_result FOR
        SELECT
            COUNT(*)                                                        AS total_registered,
            COUNT(*) FILTER (WHERE registration_fee_paid = TRUE)            AS fee_collected,
            COUNT(*) FILTER (WHERE COALESCE(registration_fee_paid, FALSE) = FALSE) AS fee_pending,
            COUNT(*) FILTER (WHERE admission_id IS NOT NULL)                AS converted
        FROM core.enquiries
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND is_active = TRUE
          AND registration_number IS NOT NULL;

    -- ── Cancel a registration (parent withdrew → Not Interested) ────────────
    -- The registration NUMBER, DATE and FEE are intentionally RETAINED: the
    -- registration fee is non-refundable and the registration genuinely happened,
    -- so the record stays for audit/accounting. We only record the withdrawal.
    ELSIF p_operation = 'Cancel' THEN
        SELECT status, admission_id INTO v_status, v_admission
        FROM core.enquiries
        WHERE enquiry_id = p_enquiry_id AND tenant_id = p_tenant_id AND school_id = p_school_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Registration not found.';
        END IF;
        IF v_admission IS NOT NULL THEN
            RAISE EXCEPTION 'Cannot cancel — this student is already admitted.';
        END IF;

        UPDATE core.enquiries
        SET status      = 'Not Interested',
            lost_reason = COALESCE(NULLIF(trim(p_reason), ''), 'Registration cancelled'),
            updated_by  = p_action_user_id,
            updated_at  = NOW()
        WHERE enquiry_id = p_enquiry_id AND tenant_id = p_tenant_id AND school_id = p_school_id;

        INSERT INTO core.enquiry_status_history
            (enquiry_id, tenant_id, school_id, status_from, status_to, change_note, changed_by)
        VALUES
            (p_enquiry_id, p_tenant_id, p_school_id, v_status, 'Not Interested',
             'Registration cancelled' || COALESCE(' · ' || NULLIF(trim(p_reason), ''), '')
             || ' (fee retained, non-refundable)', p_action_user_id);

        OPEN p_result FOR SELECT TRUE AS success, 'Registration cancelled. Lead marked Not Interested.' AS message;

    -- ── Mark the registration fee as collected ──────────────────────────────
    ELSIF p_operation = 'MarkFeePaid' THEN
        UPDATE core.enquiries
        SET registration_fee_paid = TRUE,
            updated_by            = p_action_user_id,
            updated_at            = NOW()
        WHERE enquiry_id = p_enquiry_id AND tenant_id = p_tenant_id AND school_id = p_school_id
          AND registration_number IS NOT NULL;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Registration not found.';
        END IF;

        OPEN p_result FOR SELECT TRUE AS success, 'Registration fee marked as collected.' AS message;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;
