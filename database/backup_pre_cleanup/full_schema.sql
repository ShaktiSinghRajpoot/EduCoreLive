--
-- PostgreSQL database dump
--

\restrict wg3fNbNA2wAcKo3L1gAz3o5PijadWM9Zi0AqhEq9bkcdJa4mxo34lHvMqacBUvr

-- Dumped from database version 16.13
-- Dumped by pg_dump version 16.13

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: academic; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA academic;


--
-- Name: audit; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA audit;


--
-- Name: auth; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA auth;


--
-- Name: config; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA config;


--
-- Name: core; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA core;


--
-- Name: erp; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA erp;


--
-- Name: lms; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA lms;


--
-- Name: notification; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA notification;


--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: sp_school_admin_academic_setup_manage(character varying, integer, integer, integer, integer, character varying, text, refcursor); Type: PROCEDURE; Schema: academic; Owner: -
--

CREATE PROCEDURE academic.sp_school_admin_academic_setup_manage(IN p_operation character varying, IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_academic_year_id integer DEFAULT NULL::integer, IN p_academic_year_name character varying DEFAULT NULL::character varying, IN p_setup_json text DEFAULT NULL::text, INOUT p_result refcursor DEFAULT 'result_cursor'::refcursor)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_academic_year_id integer;
    v_academic_class_id integer;

    v_setup_json jsonb;
    v_class_item jsonb;
    v_section_item jsonb;

    v_class_name text;
    v_section_name text;

    v_class_order integer;
    v_section_order integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    IF p_operation = 'GetAcademicSetup' THEN

        OPEN p_result FOR
        SELECT
            ay.academic_year_id,
            p_tenant_id AS tenant_id,
            p_school_id AS school_id,
            ay.academic_year_id,
            ay.start_date,
            ay.end_date,
            ay.is_current,
            ac.academic_class_id,
            ac.class_name,
            ac.display_order AS class_display_order,
            acs.academic_class_section_id,
            acs.section_name,
            acs.display_order AS section_display_order
        FROM academic.academic_years ay
        LEFT JOIN academic.academic_classes ac
            ON ac.academic_year_id = ay.academic_year_id
           AND ac.tenant_id = p_tenant_id
           AND ac.school_id = p_school_id
           AND COALESCE(ac.is_deleted, FALSE) = FALSE
        LEFT JOIN academic.academic_class_sections acs
            ON acs.academic_class_id = ac.academic_class_id
           AND acs.academic_year_id = ay.academic_year_id
           AND acs.tenant_id = p_tenant_id
           AND acs.school_id = p_school_id
           AND COALESCE(acs.is_deleted, FALSE) = FALSE
        WHERE ay.academic_year_id = p_academic_year_id
          AND COALESCE(ay.is_deleted, FALSE) = FALSE
          AND COALESCE(ay.is_active, TRUE) = TRUE
        ORDER BY
            ac.display_order,
            ac.class_name,
            acs.display_order,
            acs.section_name;
    ELSIF p_operation = 'SaveAcademicSetup' THEN

        IF p_academic_year_id IS NULL OR p_academic_year_id <= 0 THEN
            RAISE EXCEPTION 'Please select academic year.';
        END IF;

        v_academic_year_id := p_academic_year_id;
        v_setup_json := COALESCE(NULLIF(p_setup_json, ''), '[]')::jsonb;

        UPDATE academic.academic_class_sections
        SET is_deleted = TRUE,
            is_active = FALSE,
            deleted_by = p_action_user_id,
            deleted_at = NOW(),
            updated_by = p_action_user_id,
            updated_at = NOW()
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND academic_year_id = v_academic_year_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

        UPDATE academic.academic_classes
        SET is_deleted = TRUE,
            is_active = FALSE,
            deleted_by = p_action_user_id,
            deleted_at = NOW(),
            updated_by = p_action_user_id,
            updated_at = NOW()
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND academic_year_id = v_academic_year_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

        v_class_order := 0;

        FOR v_class_item IN
            SELECT value
            FROM jsonb_array_elements(v_setup_json)
        LOOP
            v_class_name := trim(COALESCE(v_class_item ->> 'ClassName', v_class_item ->> 'className', ''));

            IF v_class_name <> '' THEN
                v_class_order := v_class_order + 1;

                INSERT INTO academic.academic_classes
                (
                    tenant_id,
                    school_id,
                    academic_year_id,
                    class_name,
                    display_order,
                    created_by,
                    created_at,
                    is_deleted,
                    is_active
                )
                VALUES
                (
                    p_tenant_id,
                    p_school_id,
                    v_academic_year_id,
                    v_class_name,
                    v_class_order,
                    p_action_user_id,
                    NOW(),
                    FALSE,
                    TRUE
                )
                RETURNING academic_class_id INTO v_academic_class_id;

                v_section_order := 0;

                FOR v_section_item IN
                    SELECT value
                    FROM jsonb_array_elements(
                        COALESCE(v_class_item -> 'Sections', v_class_item -> 'sections', '[]'::jsonb)
                    )
                LOOP
                    v_section_name := trim(BOTH '"' FROM v_section_item::text);
                    v_section_name := trim(v_section_name);

                    IF v_section_name <> '' THEN
                        v_section_order := v_section_order + 1;

                        INSERT INTO academic.academic_class_sections
                        (
                            tenant_id,
                            school_id,
                            academic_year_id,
                            academic_class_id,
                            section_name,
                            display_order,
                            created_by,
                            created_at,
                            is_deleted,
                            is_active
                        )
                        VALUES
                        (
                            p_tenant_id,
                            p_school_id,
                            v_academic_year_id,
                            v_academic_class_id,
                            v_section_name,
                            v_section_order,
                            p_action_user_id,
                            NOW(),
                            FALSE,
                            TRUE
                        );
                    END IF;
                END LOOP;
            END IF;
        END LOOP;

        OPEN p_result FOR
        SELECT
            TRUE AS success,
            'Saved successfully.' AS message,
            v_academic_year_id AS academic_year_id;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$$;


--
-- Name: sp_dropdown_common(character varying, character varying, character varying, refcursor); Type: PROCEDURE; Schema: config; Owner: -
--

CREATE PROCEDURE config.sp_dropdown_common(IN p_activity character varying, IN p_param1 character varying DEFAULT NULL::character varying, IN p_param2 character varying DEFAULT NULL::character varying, INOUT p_result refcursor DEFAULT 'result_cursor'::refcursor)
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF p_activity = 'AcademicYear' THEN

        OPEN p_result FOR
        SELECT
            academic_year_name AS "Name",
            academic_year_id::text AS "Code"
        FROM academic.academic_years
        WHERE COALESCE(is_deleted, FALSE) = FALSE
          AND COALESCE(is_active, TRUE) = TRUE
        ORDER BY academic_year_id DESC;
		
      elseIF p_activity = 'Class' THEN
        OPEN p_result FOR
        SELECT
            class_name AS "Name",
            academic_class_id::text AS "Code"
        FROM academic.academic_classes
        WHERE COALESCE(is_deleted, FALSE) = FALSE
          AND COALESCE(is_active, TRUE) = TRUE
        ORDER BY academic_class_id DESC;

    ELSE

        OPEN p_result FOR
        SELECT
            ''::text AS "Name",
            ''::text AS "Code"
        WHERE FALSE;

    END IF;
END;
$$;


--
-- Name: sp_role_permission_management(character varying, integer, integer, integer, integer[], integer, refcursor); Type: PROCEDURE; Schema: config; Owner: -
--

CREATE PROCEDURE config.sp_role_permission_management(IN p_operation_type character varying, IN p_tenant_id integer, IN p_school_id integer, IN p_role_id integer DEFAULT NULL::integer, IN p_permission_ids integer[] DEFAULT NULL::integer[], IN p_action_by integer DEFAULT NULL::integer, INOUT p_result refcursor DEFAULT NULL::refcursor)
    LANGUAGE plpgsql
    AS $$
BEGIN

    IF p_operation_type = 'GET_ALL_PERMISSIONS' THEN

        OPEN p_result FOR
        SELECT
            permission_id,
            permission_key,
            permission_name,
            module_name,
            description
        FROM config.permissions
        WHERE is_deleted = false
          AND is_active = true
          AND (tenant_id IS NULL OR tenant_id = p_tenant_id)
        ORDER BY module_name, permission_name;

    ELSIF p_operation_type = 'GET_ROLE_PERMISSIONS' THEN

        OPEN p_result FOR
        SELECT
            p.permission_id,
            p.permission_key,
            p.permission_name,
            p.module_name,
            CASE
                WHEN rp.role_permission_id IS NULL THEN false
                ELSE true
            END AS is_selected
        FROM config.permissions p
        LEFT JOIN config.role_permissions rp
            ON rp.permission_id = p.permission_id
           AND rp.tenant_id = p_tenant_id
           AND rp.school_id = p_school_id
           AND rp.role_id = p_role_id
           AND rp.is_deleted = false
           AND rp.is_allowed = true
        WHERE p.is_deleted = false
          AND p.is_active = true
          AND (p.tenant_id IS NULL OR p.tenant_id = p_tenant_id)
        ORDER BY p.module_name, p.permission_name;

    ELSIF p_operation_type = 'SAVE_ROLE_PERMISSIONS' THEN

        -- soft delete old permissions
        UPDATE config.role_permissions
        SET
            is_deleted = true,
            deleted_by = p_action_by,
            deleted_at = CURRENT_TIMESTAMP
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND role_id = p_role_id
          AND is_deleted = false;

        -- insert selected permissions
        INSERT INTO config.role_permissions
        (
            tenant_id,
            school_id,
            role_id,
            permission_id,
            is_allowed,
            created_by
        )
        SELECT
            p_tenant_id,
            p_school_id,
            p_role_id,
            permission_id,
            true,
            p_action_by
        FROM unnest(p_permission_ids) AS permission_id;

        OPEN p_result FOR
        SELECT true AS success, 'Permissions saved successfully.' AS message;

    END IF;

END;
$$;


--
-- Name: sp_school_dropdowns(refcursor, refcursor, refcursor, refcursor, refcursor, refcursor, refcursor, refcursor, refcursor, refcursor, refcursor); Type: PROCEDURE; Schema: config; Owner: -
--

CREATE PROCEDURE config.sp_school_dropdowns(INOUT p_tenants refcursor, INOUT p_statuses refcursor, INOUT p_boards refcursor, INOUT p_school_types refcursor, INOUT p_ownership_types refcursor, INOUT p_mediums refcursor, INOUT p_address_types refcursor, INOUT p_contact_types refcursor, INOUT p_academic_years refcursor, INOUT p_date_formats refcursor, INOUT p_time_formats refcursor)
    LANGUAGE plpgsql
    AS $$
BEGIN
   OPEN p_tenants FOR
   SELECT tenant_id AS id, tenant_name AS name
   FROM core.tenants
   WHERE is_active = TRUE;


    OPEN p_statuses FOR
        SELECT school_status_id AS id, name
        FROM config.school_statuses
        WHERE is_deleted = FALSE
        ORDER BY name;

    OPEN p_boards FOR
        SELECT board_id AS id, name
        FROM config.boards
        WHERE is_deleted = FALSE
        ORDER BY name;

    OPEN p_school_types FOR
        SELECT school_type_id AS id, name
        FROM config.school_types
        WHERE is_deleted = FALSE
        ORDER BY name;

    OPEN p_ownership_types FOR
        SELECT ownership_type_id AS id, name
        FROM config.ownership_types
        WHERE is_deleted = FALSE
        ORDER BY name;

    OPEN p_mediums FOR
        SELECT medium_id AS id, name
        FROM config.mediums
        WHERE is_deleted = FALSE
        ORDER BY name;

    OPEN p_address_types FOR
        SELECT address_type_id AS id, name
        FROM config.address_types
        WHERE is_deleted = FALSE
        ORDER BY name;

    OPEN p_contact_types FOR
        SELECT contact_type_id AS id, name
        FROM config.contact_types
        WHERE is_deleted = FALSE
        ORDER BY name;

    OPEN p_academic_years FOR
        SELECT academic_year_id AS id, name
        FROM config.academic_years
        WHERE is_deleted = FALSE
        ORDER BY name DESC;

    OPEN p_date_formats FOR
        SELECT date_format_id AS id, format_value AS name
        FROM config.date_formats
        WHERE is_deleted = FALSE
        ORDER BY format_value;

    OPEN p_time_formats FOR
        SELECT time_format_id AS id, format_value AS name
        FROM config.time_formats
        WHERE is_deleted = FALSE
        ORDER BY format_value;

END;
$$;


--
-- Name: sp_admission_manage(text, integer, integer, integer, integer, text, text, text, text, date, text, text, text, date, text, text, text, text, text, numeric, numeric, numeric, numeric, text, numeric, numeric, text, numeric, jsonb, integer, integer, integer, text, text, text, text, text, text, refcursor); Type: PROCEDURE; Schema: core; Owner: -
--

CREATE PROCEDURE core.sp_admission_manage(IN p_operation text, IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_student_id integer DEFAULT NULL::integer, IN p_admission_no text DEFAULT NULL::text, IN p_roll_no text DEFAULT NULL::text, IN p_student_name text DEFAULT NULL::text, IN p_gender text DEFAULT NULL::text, IN p_dob date DEFAULT NULL::date, IN p_class_name text DEFAULT NULL::text, IN p_section text DEFAULT NULL::text, IN p_academic_year text DEFAULT NULL::text, IN p_admission_date date DEFAULT NULL::date, IN p_guardian_name text DEFAULT NULL::text, IN p_mother_name text DEFAULT NULL::text, IN p_mobile text DEFAULT NULL::text, IN p_alt_mobile text DEFAULT NULL::text, IN p_address text DEFAULT NULL::text, IN p_pay_today_total numeric DEFAULT 0, IN p_monthly_total numeric DEFAULT 0, IN p_yearly_total numeric DEFAULT 0, IN p_annual_total numeric DEFAULT 0, IN p_concession_type text DEFAULT NULL::text, IN p_concession_value numeric DEFAULT 0, IN p_concession_amount numeric DEFAULT 0, IN p_concession_reason text DEFAULT NULL::text, IN p_concession_cap numeric DEFAULT 100000, IN p_fee_plan_json jsonb DEFAULT NULL::jsonb, IN p_enquiry_id integer DEFAULT NULL::integer, IN p_page_number integer DEFAULT 1, IN p_page_size integer DEFAULT 10, IN p_search text DEFAULT NULL::text, IN p_filter_class text DEFAULT NULL::text, IN p_filter_section text DEFAULT NULL::text, IN p_filter_gender text DEFAULT NULL::text, IN p_filter_year text DEFAULT NULL::text, IN p_filter_status text DEFAULT NULL::text, INOUT p_result refcursor DEFAULT 'admission_cursor'::refcursor)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_student_id    INTEGER;
    v_admission_no  TEXT;
    v_seq           INTEGER;
    v_year          VARCHAR(20);
    v_adm_date      DATE;
    v_approval      VARCHAR(20);
    v_dup           INTEGER;
    v_item          JSONB;
    v_month_start   DATE;
    v_i             INTEGER;
BEGIN

    -- ── SaveAdmission ────────────────────────────────────────
    IF p_operation = 'SaveAdmission' THEN

        IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
            OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                'Invalid tenant/school context.' AS message, NULL::TEXT AS admission_no;
            RETURN;
        END IF;

        v_year     := COALESCE(p_academic_year, '');
        v_adm_date := COALESCE(p_admission_date, CURRENT_DATE);

        -- Duplicate guard: same name + dob + mobile already admitted
        SELECT COUNT(*) INTO v_dup
        FROM core.students
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND is_active = TRUE
          AND LOWER(student_name) = LOWER(COALESCE(p_student_name, ''))
          AND COALESCE(dob, DATE '1900-01-01') = COALESCE(p_dob, DATE '1900-01-01')
          AND COALESCE(mobile, '') = COALESCE(p_mobile, '');
        IF v_dup > 0 THEN
            OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                'A student with the same name, DOB and mobile already exists.' AS message,
                NULL::TEXT AS admission_no;
            RETURN;
        END IF;

        -- Admission number: use supplied value or auto-generate per school+year
        IF p_admission_no IS NULL OR TRIM(p_admission_no) = '' THEN
            INSERT INTO core.admission_counters (tenant_id, school_id, academic_year, last_seq)
            VALUES (p_tenant_id, p_school_id, v_year, 1)
            ON CONFLICT (tenant_id, school_id, academic_year)
            DO UPDATE SET last_seq = core.admission_counters.last_seq + 1
            RETURNING last_seq INTO v_seq;

            v_admission_no := 'ADM-' ||
                COALESCE(NULLIF(LEFT(v_year, 4), ''), TO_CHAR(v_adm_date, 'YYYY')) ||
                '-' || LPAD(v_seq::TEXT, 4, '0');
        ELSE
            v_admission_no := TRIM(p_admission_no);
            -- Reject collision with an existing admission number
            IF EXISTS (SELECT 1 FROM core.students
                       WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                         AND admission_no = v_admission_no) THEN
                OPEN p_result FOR SELECT 0 AS student_id, 0 AS success,
                    'Admission number already in use.' AS message,
                    v_admission_no AS admission_no;
                RETURN;
            END IF;
        END IF;

        -- Concession approval gate
        v_approval := CASE WHEN COALESCE(p_concession_amount, 0) > COALESCE(p_concession_cap, 100000)
                           THEN 'Pending Approval' ELSE 'Approved' END;

        INSERT INTO core.students (
            tenant_id, school_id,
            admission_no, roll_no, student_name, gender, dob,
            class_name, section, academic_year, admission_date,
            guardian_name, mother_name, mobile, alt_mobile, address,
            pay_today_total, monthly_total, yearly_total, annual_total,
            concession_type, concession_value, concession_amount, concession_reason,
            enquiry_id, status, approval_status,
            created_by, updated_by
        ) VALUES (
            p_tenant_id, p_school_id,
            v_admission_no, p_roll_no, p_student_name, p_gender, p_dob,
            p_class_name, p_section, v_year, v_adm_date,
            p_guardian_name, p_mother_name, p_mobile, p_alt_mobile, p_address,
            COALESCE(p_pay_today_total, 0), COALESCE(p_monthly_total, 0),
            COALESCE(p_yearly_total, 0), COALESCE(p_annual_total, 0),
            p_concession_type, COALESCE(p_concession_value, 0),
            COALESCE(p_concession_amount, 0), p_concession_reason,
            p_enquiry_id, 'Active', v_approval,
            p_action_user_id, p_action_user_id
        )
        RETURNING student_id INTO v_student_id;

        -- Freeze the fee plan + generate ledger rows
        IF p_fee_plan_json IS NOT NULL THEN
            FOR v_item IN SELECT * FROM jsonb_array_elements(p_fee_plan_json)
            LOOP
                INSERT INTO core.student_fee_plan (
                    tenant_id, school_id, student_id,
                    fee_head_id, fee_head_name, frequency, amount, is_optional
                ) VALUES (
                    p_tenant_id, p_school_id, v_student_id,
                    NULLIF((v_item->>'feeHeadId'), '')::INTEGER,
                    COALESCE(v_item->>'feeHeadName', 'Fee'),
                    COALESCE(v_item->>'frequency', 'Yearly'),
                    COALESCE((v_item->>'amount')::NUMERIC, 0),
                    COALESCE((v_item->>'isOptional')::BOOLEAN, FALSE)
                );

                -- Ledger generation
                IF COALESCE(v_item->>'frequency', 'Yearly') = 'Monthly' THEN
                    -- 12 monthly installments from admission month
                    v_month_start := DATE_TRUNC('month', v_adm_date)::DATE;
                    FOR v_i IN 0..11 LOOP
                        INSERT INTO core.student_ledger (
                            tenant_id, school_id, student_id,
                            fee_head_name, frequency, installment_label,
                            due_date, amount_due, status
                        ) VALUES (
                            p_tenant_id, p_school_id, v_student_id,
                            COALESCE(v_item->>'feeHeadName', 'Fee'), 'Monthly',
                            TO_CHAR(v_month_start + (v_i || ' month')::INTERVAL, 'Mon YYYY'),
                            (v_month_start + (v_i || ' month')::INTERVAL)::DATE,
                            COALESCE((v_item->>'amount')::NUMERIC, 0), 'Pending'
                        );
                    END LOOP;
                ELSE
                    INSERT INTO core.student_ledger (
                        tenant_id, school_id, student_id,
                        fee_head_name, frequency, installment_label,
                        due_date, amount_due, status
                    ) VALUES (
                        p_tenant_id, p_school_id, v_student_id,
                        COALESCE(v_item->>'feeHeadName', 'Fee'),
                        COALESCE(v_item->>'frequency', 'Yearly'),
                        CASE WHEN COALESCE(v_item->>'frequency','Yearly') = 'One Time'
                             THEN 'Admission' ELSE 'Annual' END,
                        v_adm_date,
                        COALESCE((v_item->>'amount')::NUMERIC, 0), 'Pending'
                    );
                END IF;
            END LOOP;
        END IF;

        -- Audit
        INSERT INTO core.admission_audit (tenant_id, school_id, student_id, action, detail, action_by)
        VALUES (p_tenant_id, p_school_id, v_student_id, 'AdmissionCreated',
                'Admission ' || v_admission_no || ' created for ' || COALESCE(p_student_name,''),
                p_action_user_id);

        IF COALESCE(p_concession_amount, 0) > 0 THEN
            INSERT INTO core.admission_audit (tenant_id, school_id, student_id, action, detail, action_by)
            VALUES (p_tenant_id, p_school_id, v_student_id, 'ConcessionApplied',
                    'Concession ' || p_concession_amount::TEXT || ' (' ||
                    COALESCE(p_concession_reason, 'no reason') || ') status=' || v_approval,
                    p_action_user_id);
        END IF;

        -- Close the loop: link + confirm enquiry
        IF p_enquiry_id IS NOT NULL AND p_enquiry_id > 0 THEN
            UPDATE core.enquiries
            SET admission_id = v_student_id,
                status       = 'Admission Confirmed',
                updated_by   = p_action_user_id,
                updated_at   = NOW()
            WHERE enquiry_id = p_enquiry_id
              AND tenant_id  = p_tenant_id
              AND school_id  = p_school_id
              AND is_active  = TRUE;

            INSERT INTO core.enquiry_status_history (
                enquiry_id, tenant_id, school_id,
                status_from, status_to, change_note, changed_by
            )
            SELECT p_enquiry_id, p_tenant_id, p_school_id,
                   NULL, 'Admission Confirmed',
                   'Converted to admission ' || v_admission_no, p_action_user_id
            WHERE EXISTS (SELECT 1 FROM core.enquiries
                          WHERE enquiry_id = p_enquiry_id
                            AND tenant_id = p_tenant_id AND school_id = p_school_id);

            INSERT INTO core.admission_audit (tenant_id, school_id, student_id, action, detail, action_by)
            VALUES (p_tenant_id, p_school_id, v_student_id, 'ConvertedFromEnquiry',
                    'Linked from enquiry #' || p_enquiry_id::TEXT, p_action_user_id);
        END IF;

        OPEN p_result FOR
            SELECT v_student_id AS student_id, 1 AS success,
                   'Admission saved.' AS message, v_admission_no AS admission_no;
        RETURN;

    -- ── GetStudents (filtered + paginated) ───────────────────
    ELSIF p_operation = 'GetStudents' THEN
        OPEN p_result FOR
            WITH filtered AS (
                SELECT
                    s.student_id, s.admission_no, s.roll_no, s.student_name,
                    s.gender, s.dob, s.class_name, s.section, s.academic_year,
                    s.admission_date, s.guardian_name, s.mobile,
                    s.annual_total, s.status, s.approval_status, s.enquiry_id,
                    COALESCE((
                        SELECT CASE
                            WHEN SUM(l.amount_due) = 0 THEN 'Paid'
                            WHEN SUM(l.amount_paid) = 0 THEN 'Pending'
                            WHEN SUM(l.amount_paid) >= SUM(l.amount_due) THEN 'Paid'
                            ELSE 'Partial' END
                        FROM core.student_ledger l
                        WHERE l.student_id = s.student_id
                    ), 'Pending') AS fee_status,
                    COALESCE((
                        SELECT SUM(l.amount_due - l.amount_paid)
                        FROM core.student_ledger l
                        WHERE l.student_id = s.student_id
                    ), 0) AS fee_due
                FROM core.students s
                WHERE s.tenant_id = p_tenant_id
                  AND s.school_id = p_school_id
                  AND s.is_active = TRUE
                  AND (
                      p_search IS NULL OR TRIM(p_search) = ''
                      OR LOWER(s.student_name) LIKE '%' || LOWER(TRIM(p_search)) || '%'
                      OR LOWER(s.admission_no) LIKE '%' || LOWER(TRIM(p_search)) || '%'
                      OR LOWER(COALESCE(s.guardian_name,'')) LIKE '%' || LOWER(TRIM(p_search)) || '%'
                      OR COALESCE(s.mobile,'') LIKE '%' || TRIM(p_search) || '%'
                  )
                  AND (p_filter_class   IS NULL OR TRIM(p_filter_class)   = '' OR LOWER(s.class_name) = LOWER(TRIM(p_filter_class)))
                  AND (p_filter_section IS NULL OR TRIM(p_filter_section) = '' OR LOWER(COALESCE(s.section,'')) = LOWER(TRIM(p_filter_section)))
                  AND (p_filter_gender  IS NULL OR TRIM(p_filter_gender)  = '' OR LOWER(COALESCE(s.gender,''))  = LOWER(TRIM(p_filter_gender)))
                  AND (p_filter_year    IS NULL OR TRIM(p_filter_year)    = '' OR s.academic_year = TRIM(p_filter_year))
                  AND (p_filter_status  IS NULL OR TRIM(p_filter_status)  = '' OR LOWER(s.status) = LOWER(TRIM(p_filter_status)))
            )
            SELECT *, COUNT(*) OVER() AS total_count
            FROM filtered
            ORDER BY admission_date DESC, student_id DESC
            LIMIT  COALESCE(p_page_size,   10)
            OFFSET (COALESCE(p_page_number, 1) - 1) * COALESCE(p_page_size, 10);
        RETURN;

    -- ── GetStudentById ───────────────────────────────────────
    ELSIF p_operation = 'GetStudentById' THEN
        OPEN p_result FOR
            SELECT s.*
            FROM core.students s
            WHERE s.student_id = p_student_id
              AND s.tenant_id  = p_tenant_id
              AND s.school_id  = p_school_id
              AND s.is_active  = TRUE;
        RETURN;

    -- ── DeleteStudent (soft) ─────────────────────────────────
    ELSIF p_operation = 'DeleteStudent' THEN
        UPDATE core.students
        SET is_active = FALSE, updated_by = p_action_user_id, updated_at = NOW()
        WHERE student_id = p_student_id
          AND tenant_id  = p_tenant_id
          AND school_id  = p_school_id;
        OPEN p_result FOR SELECT 1 AS success;
        RETURN;

    END IF;

    -- Fallback
    OPEN p_result FOR SELECT 0 AS student_id WHERE FALSE;

END;
$$;


--
-- Name: sp_enquiry_crm_manage(text, integer, integer, integer, integer, text, text, date, text, text, text, text, text, text, text, text, text, text, text, text, text, text, text, text, text, integer, text, text, date, text, numeric, text, date, boolean, text, text, text, boolean, text, integer, integer, text, text, text, text, text, text, integer, boolean, boolean, refcursor); Type: PROCEDURE; Schema: core; Owner: -
--

CREATE PROCEDURE core.sp_enquiry_crm_manage(IN p_operation text, IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_enquiry_id integer DEFAULT NULL::integer, IN p_student_name text DEFAULT NULL::text, IN p_gender text DEFAULT NULL::text, IN p_dob date DEFAULT NULL::date, IN p_class_name text DEFAULT NULL::text, IN p_session text DEFAULT NULL::text, IN p_interested_stream text DEFAULT NULL::text, IN p_parent_name text DEFAULT NULL::text, IN p_father_name text DEFAULT NULL::text, IN p_father_mobile text DEFAULT NULL::text, IN p_mother_name text DEFAULT NULL::text, IN p_mother_mobile text DEFAULT NULL::text, IN p_mobile text DEFAULT NULL::text, IN p_alt_mobile text DEFAULT NULL::text, IN p_city text DEFAULT NULL::text, IN p_area_locality text DEFAULT NULL::text, IN p_lead_source text DEFAULT NULL::text, IN p_referrer_name text DEFAULT NULL::text, IN p_referrer_mobile text DEFAULT NULL::text, IN p_priority text DEFAULT NULL::text, IN p_status text DEFAULT NULL::text, IN p_assigned_to_id integer DEFAULT NULL::integer, IN p_lost_reason text DEFAULT NULL::text, IN p_lost_to_school text DEFAULT NULL::text, IN p_next_followup_date date DEFAULT NULL::date, IN p_notes text DEFAULT NULL::text, IN p_estimated_fee numeric DEFAULT NULL::numeric, IN p_registration_number text DEFAULT NULL::text, IN p_registration_date date DEFAULT NULL::date, IN p_registration_fee_paid boolean DEFAULT false, IN p_parent_email text DEFAULT NULL::text, IN p_current_class text DEFAULT NULL::text, IN p_current_school text DEFAULT NULL::text, IN p_transport_required boolean DEFAULT false, IN p_whatsapp_number text DEFAULT NULL::text, IN p_page_number integer DEFAULT 1, IN p_page_size integer DEFAULT 10, IN p_search text DEFAULT NULL::text, IN p_filter_session text DEFAULT NULL::text, IN p_filter_priority text DEFAULT NULL::text, IN p_filter_class text DEFAULT NULL::text, IN p_filter_source text DEFAULT NULL::text, IN p_filter_pipeline text DEFAULT NULL::text, IN p_filter_assigned_to integer DEFAULT NULL::integer, IN p_filter_overdue boolean DEFAULT false, IN p_filter_today boolean DEFAULT false, INOUT p_result refcursor DEFAULT 'enquiry_cursor'::refcursor)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_enquiry_id     INTEGER;
    v_status_before  VARCHAR(60);
    v_today          DATE := CURRENT_DATE;
BEGIN

    -- ── GetEnquiries (filtered + paginated) ──────────────────
    IF p_operation = 'GetEnquiries' THEN
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
                CASE WHEN is_overdue THEN 0 ELSE 1 END ASC,
                next_followup_date ASC NULLS LAST,
                created_at DESC
            LIMIT  COALESCE(p_page_size,   10)
            OFFSET (COALESCE(p_page_number, 1) - 1) * COALESCE(p_page_size, 10);
        RETURN;

    -- ── GetKpiStats ───────────────────────────────────────────
    ELSIF p_operation = 'GetKpiStats' THEN
        OPEN p_result FOR
            SELECT
                COUNT(*)                                                                                       AS total_leads,
                COUNT(*) FILTER (WHERE next_followup_date = v_today)                                           AS due_today,
                COUNT(*) FILTER (WHERE next_followup_date < v_today
                                   AND status NOT IN ('Admission Confirmed','Not Interested','Dropped'))        AS overdue_count,
                COUNT(*) FILTER (WHERE status = 'Campus Visit Scheduled')                                      AS campus_visits,
                COUNT(*) FILTER (WHERE status = 'Admission Confirmed')                                         AS admitted,
                COUNT(*) FILTER (WHERE status = 'New')                                                         AS cnt_new,
                COUNT(*) FILTER (WHERE status = 'Follow-up Pending')                                           AS cnt_followup,
                COUNT(*) FILTER (WHERE status = 'Interested')                                                  AS cnt_interested,
                COUNT(*) FILTER (WHERE status = 'Campus Visit Scheduled')                                      AS cnt_campusvisit,
                COUNT(*) FILTER (WHERE status = 'Registration Done')                                           AS cnt_registered,
                COUNT(*) FILTER (WHERE status IN ('Not Interested','Dropped'))                                 AS cnt_not_interested,
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
$$;


--
-- Name: sp_enquiry_followup_manage(text, integer, integer, integer, integer, text, text, text, date, text, text, refcursor); Type: PROCEDURE; Schema: core; Owner: -
--

CREATE PROCEDURE core.sp_enquiry_followup_manage(IN p_operation text, IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_enquiry_id integer DEFAULT NULL::integer, IN p_followup_type text DEFAULT 'Call'::text, IN p_outcome text DEFAULT NULL::text, IN p_notes text DEFAULT NULL::text, IN p_next_followup_date date DEFAULT NULL::date, IN p_new_status text DEFAULT NULL::text, IN p_lost_reason text DEFAULT NULL::text, INOUT p_result refcursor DEFAULT 'followup_cursor'::refcursor)
    LANGUAGE plpgsql
    AS $$
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
            next_followup_date = COALESCE(p_next_followup_date, next_followup_date),
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
$$;


--
-- Name: sp_get_user_permissions(integer, integer, integer, refcursor); Type: PROCEDURE; Schema: core; Owner: -
--

CREATE PROCEDURE core.sp_get_user_permissions(IN p_tenant_id integer, IN p_school_id integer, IN p_user_id integer, INOUT p_result refcursor)
    LANGUAGE plpgsql
    AS $$
BEGIN

    OPEN p_result FOR

    WITH user_role AS
    (
        SELECT ur.role_id
        FROM core.user_roles ur
        WHERE ur.tenant_id = p_tenant_id
          AND ur.school_id = p_school_id
          AND ur.user_id = p_user_id
          AND ur.is_deleted = false
          AND ur.is_active = true
          AND ur.is_primary = true
        LIMIT 1
    ),

    role_permissions AS
    (
        SELECT rp.permission_id
        FROM config.role_permissions rp
        INNER JOIN user_role ur
            ON ur.role_id = rp.role_id
        WHERE rp.tenant_id = p_tenant_id
          AND (rp.school_id IS NULL OR rp.school_id = p_school_id)
          AND rp.is_deleted = false
          AND rp.is_allowed = true
    ),

    user_allowed_permissions AS
    (
        SELECT up.permission_id
        FROM config.user_permissions up
        WHERE up.tenant_id = p_tenant_id
          AND up.school_id = p_school_id
          AND up.user_id = p_user_id
          AND up.is_deleted = false
          AND up.is_allowed = true
    ),

    user_denied_permissions AS
    (
        SELECT up.permission_id
        FROM config.user_permissions up
        WHERE up.tenant_id = p_tenant_id
          AND up.school_id = p_school_id
          AND up.user_id = p_user_id
          AND up.is_deleted = false
          AND up.is_allowed = false
    ),

    final_permissions AS
    (
        SELECT permission_id
        FROM role_permissions

        UNION

        SELECT permission_id
        FROM user_allowed_permissions

        EXCEPT

        SELECT permission_id
        FROM user_denied_permissions
    )

    SELECT
        p.permission_id,
        p.permission_key AS permission_code,
        p.permission_key,
        p.permission_name,
        p.module_name
    FROM final_permissions fp
    INNER JOIN config.permissions p
        ON p.permission_id = fp.permission_id
    WHERE p.tenant_id = p_tenant_id
      AND p.is_deleted = false
      AND p.is_active = true
    ORDER BY p.module_name, p.permission_name;

END;
$$;


--
-- Name: sp_login_management(character varying, character varying, integer, boolean, character varying, character varying, text, refcursor); Type: PROCEDURE; Schema: core; Owner: -
--

CREATE PROCEDURE core.sp_login_management(IN p_operation_type character varying, IN p_email character varying DEFAULT NULL::character varying, IN p_user_id integer DEFAULT NULL::integer, IN p_is_success boolean DEFAULT NULL::boolean, IN p_failure_reason character varying DEFAULT NULL::character varying, IN p_ip_address character varying DEFAULT NULL::character varying, IN p_user_agent text DEFAULT NULL::text, INOUT p_result refcursor DEFAULT NULL::refcursor)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_user_id INTEGER;
    v_tenant_id INTEGER;
    v_school_id INTEGER;
BEGIN

    IF p_operation_type = 'GET_LOGIN_USER' THEN

        OPEN p_result FOR
        SELECT
            u.user_id,
            u.tenant_id,
            ur.school_id,
            u.email,
            u.password_hash,
            u.is_email_verified,
            u.is_active,
            u.is_deleted,
            u.last_login_at,

            up.full_name,
            up.phone,

            r.role_id,
            r.role_name,
            r.role_code
        FROM core.users u
        LEFT JOIN core.user_profiles up
            ON up.user_id = u.user_id
           AND up.tenant_id = u.tenant_id
           AND up.is_deleted = FALSE

        INNER JOIN core.user_roles ur
            ON ur.user_id = u.user_id
           AND ur.tenant_id = u.tenant_id
           AND ur.is_deleted = FALSE
           AND ur.is_active = TRUE
           AND ur.is_primary = TRUE

        INNER JOIN config.roles r
            ON r.role_id = ur.role_id
           AND r.tenant_id = u.tenant_id
           AND r.is_deleted = FALSE
           AND r.is_active = TRUE

        WHERE LOWER(u.email) = LOWER(p_email)
          AND u.is_deleted = FALSE
          AND u.is_active = TRUE
        ORDER BY
            CASE r.role_code
                WHEN 'SUPER_ADMIN' THEN 1
                WHEN 'SCHOOL_ADMIN' THEN 2
                WHEN 'TEACHER' THEN 3
                WHEN 'ACCOUNTANT' THEN 4
                WHEN 'RECEPTIONIST' THEN 5
                ELSE 99
            END
        LIMIT 1;

      ELSIF p_operation_type = 'GET_USER_ROLES' THEN

        OPEN p_result FOR
        SELECT
            u.user_id,
        u.tenant_id,
        ur.school_id,
        u.email,
        u.password_hash,
        u.is_email_verified,
        u.is_active,
        u.is_deleted,
        u.last_login_at,

        up.full_name,
        up.phone,

        r.role_id,
        r.role_name,
        r.role_code,

        ur.is_primary
        FROM core.users u
        LEFT JOIN core.user_profiles up
            ON up.user_id = u.user_id
           AND up.tenant_id = u.tenant_id
           AND up.is_deleted = FALSE

        INNER JOIN core.user_roles ur
            ON ur.user_id = u.user_id
           AND ur.tenant_id = u.tenant_id
           AND ur.is_deleted = FALSE
           AND ur.is_active = TRUE

        INNER JOIN config.roles r
            ON r.role_id = ur.role_id
           AND r.tenant_id = u.tenant_id
           AND r.is_deleted = FALSE
           AND r.is_active = TRUE

        WHERE u.user_id = p_user_id
          AND u.is_deleted = FALSE
          AND u.is_active = TRUE

        ORDER BY
            ur.is_primary DESC,
        CASE r.role_code
                WHEN 'SUPER_ADMIN' THEN 1
                WHEN 'TENANT_ADMIN' THEN 2
                WHEN 'SCHOOL_ADMIN' THEN 3
                WHEN 'TEACHER' THEN 4
                WHEN 'ACCOUNTANT' THEN 5
                WHEN 'RECEPTIONIST' THEN 6
                ELSE 99
            END;

    ELSIF p_operation_type = 'GET_USER_BY_ID' THEN

        OPEN p_result FOR
        SELECT
            u.user_id,
            u.tenant_id,
            ur.school_id,
            u.email,
            u.password_hash,
            u.is_email_verified,
            u.is_active,
            u.is_deleted,
            u.last_login_at,

            up.full_name,
            up.phone,

            r.role_id,
            r.role_name,
            r.role_code
        FROM core.users u
        LEFT JOIN core.user_profiles up
            ON up.user_id = u.user_id
           AND up.tenant_id = u.tenant_id
           AND up.is_deleted = FALSE

        INNER JOIN core.user_roles ur
            ON ur.user_id = u.user_id
           AND ur.tenant_id = u.tenant_id
           AND ur.is_deleted = FALSE
           AND ur.is_active = TRUE
           AND ur.is_primary = TRUE

        INNER JOIN config.roles r
            ON r.role_id = ur.role_id
           AND r.tenant_id = u.tenant_id
           AND r.is_deleted = FALSE
           AND r.is_active = TRUE

        WHERE u.user_id = p_user_id
          AND u.is_deleted = FALSE
          AND u.is_active = TRUE
        ORDER BY
            CASE r.role_code
                WHEN 'SUPER_ADMIN' THEN 1
                WHEN 'SCHOOL_ADMIN' THEN 2
                WHEN 'TEACHER' THEN 3
                WHEN 'ACCOUNTANT' THEN 4
                WHEN 'RECEPTIONIST' THEN 5
                ELSE 99
            END
        LIMIT 1;

    ELSIF p_operation_type = 'SAVE_LOGIN_ATTEMPT' THEN

        SELECT
            u.user_id,
            u.tenant_id,
            ur.school_id
        INTO
            v_user_id,
            v_tenant_id,
            v_school_id
        FROM core.users u
        LEFT JOIN core.user_roles ur
            ON ur.user_id = u.user_id
           AND ur.tenant_id = u.tenant_id
           AND ur.is_deleted = FALSE
           AND ur.is_primary = TRUE
        WHERE LOWER(u.email) = LOWER(p_email)
          AND u.is_deleted = FALSE
        LIMIT 1;

        INSERT INTO core.login_attempts
        (
            tenant_id,
            user_id,
            school_id,
            email,
            ip_address,
            user_agent,
            is_success,
            failure_reason,
            created_by,
            created_at,
            is_deleted
        )
        VALUES
        (
            v_tenant_id,
            v_user_id,
            v_school_id,
            p_email,
            p_ip_address,
            p_user_agent,
            COALESCE(p_is_success, FALSE),
            p_failure_reason,
            v_user_id,
            CURRENT_TIMESTAMP,
            FALSE
        );

    ELSIF p_operation_type = 'SAVE_USER_SESSION' THEN

        SELECT
            u.user_id,
            u.tenant_id,
            ur.school_id
        INTO
            v_user_id,
            v_tenant_id,
            v_school_id
        FROM core.users u
        LEFT JOIN core.user_roles ur
            ON ur.user_id = u.user_id
           AND ur.tenant_id = u.tenant_id
           AND ur.is_deleted = FALSE
           AND ur.is_primary = TRUE
        WHERE u.user_id = p_user_id
          AND u.is_deleted = FALSE
        LIMIT 1;

        INSERT INTO core.user_sessions
        (
            tenant_id,
            user_id,
            school_id,
            ip_address,
            user_agent,
            login_at,
            expires_at,
            is_active,
            created_by,
            created_at,
            is_deleted
        )
        VALUES
        (
            v_tenant_id,
            p_user_id,
            v_school_id,
            p_ip_address,
            p_user_agent,
            CURRENT_TIMESTAMP,
            CURRENT_TIMESTAMP + INTERVAL '8 hours',
            TRUE,
            p_user_id,
            CURRENT_TIMESTAMP,
            FALSE
        );

        UPDATE core.users
        SET last_login_at = CURRENT_TIMESTAMP,
            updated_by = p_user_id,
            updated_at = CURRENT_TIMESTAMP
        WHERE user_id = p_user_id;

    ELSE
        RAISE EXCEPTION 'Invalid operation type: %', p_operation_type;
    END IF;

END;
$$;


--
-- Name: sp_school_admin_basic_profile_manage(character varying, integer, integer, integer, character varying, character varying, character varying, integer, integer, integer, integer, integer, character varying, character varying, character varying, integer, character varying, character varying, character varying, character varying, character varying, character varying, integer, character varying, character varying, character varying, character varying, character varying, integer, integer, integer, boolean, boolean, boolean, refcursor); Type: PROCEDURE; Schema: core; Owner: -
--

CREATE PROCEDURE core.sp_school_admin_basic_profile_manage(IN p_operation character varying, IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_display_name character varying DEFAULT NULL::character varying, IN p_registration_number character varying DEFAULT NULL::character varying, IN p_affiliation_number character varying DEFAULT NULL::character varying, IN p_board_id integer DEFAULT NULL::integer, IN p_school_type_id integer DEFAULT NULL::integer, IN p_ownership_type_id integer DEFAULT NULL::integer, IN p_medium_id integer DEFAULT NULL::integer, IN p_established_year integer DEFAULT NULL::integer, IN p_website character varying DEFAULT NULL::character varying, IN p_logo_url character varying DEFAULT NULL::character varying, IN p_header_image_url character varying DEFAULT NULL::character varying, IN p_address_type_id integer DEFAULT NULL::integer, IN p_address_line1 character varying DEFAULT NULL::character varying, IN p_address_line2 character varying DEFAULT NULL::character varying, IN p_city character varying DEFAULT NULL::character varying, IN p_district character varying DEFAULT NULL::character varying, IN p_state character varying DEFAULT NULL::character varying, IN p_pincode character varying DEFAULT NULL::character varying, IN p_contact_type_id integer DEFAULT NULL::integer, IN p_contact_name character varying DEFAULT NULL::character varying, IN p_designation character varying DEFAULT NULL::character varying, IN p_contact_email character varying DEFAULT NULL::character varying, IN p_phone character varying DEFAULT NULL::character varying, IN p_alternate_phone character varying DEFAULT NULL::character varying, IN p_academic_year_id integer DEFAULT NULL::integer, IN p_date_format_id integer DEFAULT NULL::integer, IN p_time_format_id integer DEFAULT NULL::integer, IN p_enable_sms boolean DEFAULT false, IN p_enable_email boolean DEFAULT true, IN p_enable_whatsapp boolean DEFAULT false, INOUT p_result refcursor DEFAULT 'basic_profile_cursor'::refcursor)
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    IF p_operation = 'GetBasicProfile' THEN

        OPEN p_result FOR
        SELECT
            s.tenant_id,
            t.tenant_name,

            s.school_id,
            s.school_code,
            s.school_name,
            s.display_name,
            s.status_id,
           -- sm.name AS status_name,

            sp.registration_number,
            sp.affiliation_number,

            sp.board_id,
            b.name AS board_name,

            sp.school_type_id,
            st.name AS school_type_name,

            sp.ownership_type_id,
            sp.medium_id,
            sp.established_year,
            sp.website,
            sp.logo_url,
            sp.header_image_url,

            COALESCE(sa.address_type_id, 1) AS address_type_id,
            sa.address_line1,
            sa.address_line2,
            sa.city,
            sa.district,
            sa.state,
            sa.pincode,

            COALESCE(sc.contact_type_id, 1) AS contact_type_id,
            sc.contact_name,
            sc.designation,
            sc.email,
            sc.phone,
            sc.alternate_phone,

            ss.academic_year_id,
            ss.date_format_id,
            ss.time_format_id,
            COALESCE(ss.enable_sms, FALSE) AS enable_sms,
            COALESCE(ss.enable_email, TRUE) AS enable_email,
            COALESCE(ss.enable_whatsapp, FALSE) AS enable_whatsapp

        FROM core.schools s

        LEFT JOIN core.tenants t
            ON t.tenant_id = s.tenant_id

        LEFT JOIN core.school_profiles sp
            ON sp.tenant_id = s.tenant_id
           AND sp.school_id = s.school_id

         -- LEFT JOIN config.config.school_statuses sm
         --     ON sm.status_id = s.status_id

        LEFT JOIN config.boards b
            ON b.board_id = sp.board_id

        LEFT JOIN config.school_types st
            ON st.school_type_id = sp.school_type_id

        LEFT JOIN core.school_addresses sa
            ON sa.tenant_id = s.tenant_id
           AND sa.school_id = s.school_id
           AND sa.address_type_id = 1

        LEFT JOIN core.school_contacts sc
            ON sc.tenant_id = s.tenant_id
           AND sc.school_id = s.school_id
           AND sc.contact_type_id = 1

        LEFT JOIN core.school_settings ss
            ON ss.tenant_id = s.tenant_id
           AND ss.school_id = s.school_id

        WHERE s.tenant_id = p_tenant_id
          AND s.school_id = p_school_id
          AND COALESCE(s.is_deleted, FALSE) = FALSE;

    ELSIF p_operation = 'UpdateBasicProfile' THEN

        UPDATE core.schools
        SET
            display_name = p_display_name,
            updated_by = p_action_user_id,
            updated_at = NOW()
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

        INSERT INTO core.school_profiles (
            tenant_id,
            school_id,
            registration_number,
            affiliation_number,
            established_year,
            website,
            logo_url,
            header_image_url,
            created_by,
            created_at,
            updated_by,
            updated_at
        )
        VALUES (
            p_tenant_id,
            p_school_id,
            p_registration_number,
            p_affiliation_number,
            p_established_year,
            p_website,
            p_logo_url,
            p_header_image_url,
            p_action_user_id,
            NOW(),
            p_action_user_id,
            NOW()
        )
        ON CONFLICT (tenant_id, school_id)
        DO UPDATE SET
            registration_number = EXCLUDED.registration_number,
            affiliation_number = EXCLUDED.affiliation_number,
            established_year = EXCLUDED.established_year,
            website = EXCLUDED.website,
            logo_url = COALESCE(EXCLUDED.logo_url, core.school_profiles.logo_url),
            header_image_url = COALESCE(EXCLUDED.header_image_url, core.school_profiles.header_image_url),
            updated_by = p_action_user_id,
            updated_at = NOW();

        INSERT INTO core.school_addresses (
            tenant_id,
            school_id,
            address_type_id,
            address_line1,
            address_line2,
            city,
            district,
            state,
            pincode,
            created_by,
            created_at,
            updated_by,
            updated_at
        )
        VALUES (
            p_tenant_id,
            p_school_id,
            COALESCE(p_address_type_id, 1),
            p_address_line1,
            p_address_line2,
            p_city,
            p_district,
            p_state,
            p_pincode,
            p_action_user_id,
            NOW(),
            p_action_user_id,
            NOW()
        )
        ON CONFLICT (tenant_id, school_id, address_type_id)
        DO UPDATE SET
            address_line1 = EXCLUDED.address_line1,
            address_line2 = EXCLUDED.address_line2,
            city = EXCLUDED.city,
            district = EXCLUDED.district,
            state = EXCLUDED.state,
            pincode = EXCLUDED.pincode,
            updated_by = p_action_user_id,
            updated_at = NOW();

        INSERT INTO core.school_contacts (
            tenant_id,
            school_id,
            contact_type_id,
            contact_name,
            designation,
            email,
            phone,
            alternate_phone,
            created_by,
            created_at,
            updated_by,
            updated_at
        )
        VALUES (
            p_tenant_id,
            p_school_id,
            COALESCE(p_contact_type_id, 1),
            p_contact_name,
            p_designation,
            p_contact_email,
            p_phone,
            p_alternate_phone,
            p_action_user_id,
            NOW(),
            p_action_user_id,
            NOW()
        )
        ON CONFLICT (tenant_id, school_id, contact_type_id)
        DO UPDATE SET
            contact_name = EXCLUDED.contact_name,
            designation = EXCLUDED.designation,
            email = EXCLUDED.email,
            phone = EXCLUDED.phone,
            alternate_phone = EXCLUDED.alternate_phone,
            updated_by = p_action_user_id,
            updated_at = NOW();

        OPEN p_result FOR
        SELECT
            TRUE AS success,
            p_school_id AS school_id,
            'Basic profile updated successfully.' AS message;

    ELSE
        RAISE EXCEPTION 'Invalid operation %. Allowed operations are GetBasicProfile, UpdateBasicProfile', p_operation;
    END IF;
END;
$$;


--
-- Name: sp_school_admin_dashboard(integer, integer, refcursor, refcursor, refcursor); Type: PROCEDURE; Schema: core; Owner: -
--

CREATE PROCEDURE core.sp_school_admin_dashboard(IN p_tenant_id integer, IN p_school_id integer, INOUT p_summary refcursor, INOUT p_recent_users refcursor, INOUT p_activity_logs refcursor)
    LANGUAGE plpgsql
    AS $$
BEGIN
    OPEN p_summary FOR
    SELECT
        COUNT(DISTINCT u.user_id) FILTER (
            WHERE u.is_deleted = false AND u.is_active = true
        ) AS active_users,

        COUNT(DISTINCT u.user_id) FILTER (
            WHERE u.is_deleted = false AND u.is_active = false
        ) AS inactive_users,

        COUNT(DISTINCT r.role_id) FILTER (
            WHERE r.is_deleted = false AND r.is_active = true
        ) AS active_roles
    FROM core.users u
    LEFT JOIN core.user_roles ur
        ON ur.tenant_id = u.tenant_id
       AND ur.school_id = u.school_id
       AND ur.user_id = u.user_id
       AND ur.is_deleted = false
    LEFT JOIN config.roles r
        ON r.tenant_id = u.tenant_id
       AND r.role_id = ur.role_id
       AND r.is_deleted = false
    WHERE u.tenant_id = p_tenant_id
      AND u.school_id = p_school_id;

    OPEN p_recent_users FOR
    SELECT
        u.user_id,
        u.email,
        u.is_active,
        u.created_at,
        up.full_name,
        up.phone,
        r.role_name
    FROM core.users u
    LEFT JOIN core.user_profiles up
        ON up.tenant_id = u.tenant_id
       AND up.school_id = u.school_id
       AND up.user_id = u.user_id
       AND up.is_deleted = false
    LEFT JOIN core.user_roles ur
        ON ur.tenant_id = u.tenant_id
       AND ur.school_id = u.school_id
       AND ur.user_id = u.user_id
       AND ur.is_deleted = false
    LEFT JOIN config.roles r
        ON r.role_id = ur.role_id
       AND r.is_deleted = false
    WHERE u.tenant_id = p_tenant_id
      AND u.school_id = p_school_id
      AND u.is_deleted = false
    ORDER BY u.created_at DESC
    LIMIT 10;

    OPEN p_activity_logs FOR
    SELECT
        admin_activity_log_id,
        action,
        module_name,
        description,
        created_at
    FROM core.admin_activity_logs
    WHERE tenant_id = p_tenant_id
      AND school_id = p_school_id
      AND is_deleted = false
    ORDER BY created_at DESC
    LIMIT 10;
END;
$$;


--
-- Name: sp_school_admin_fee_head_manage(character varying, integer, integer, integer, integer, character varying, character varying, numeric, character varying, character varying, integer, refcursor); Type: PROCEDURE; Schema: core; Owner: -
--

CREATE PROCEDURE core.sp_school_admin_fee_head_manage(IN p_operation character varying, IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_fee_head_id integer DEFAULT 0, IN p_fee_head_name character varying DEFAULT NULL::character varying, IN p_frequency character varying DEFAULT NULL::character varying, IN p_default_amount numeric DEFAULT 0, IN p_fee_type character varying DEFAULT NULL::character varying, IN p_fee_group character varying DEFAULT 'Academic'::character varying, IN p_display_order integer DEFAULT 0, INOUT p_result refcursor DEFAULT 'result_cursor'::refcursor)
    LANGUAGE plpgsql
    AS $$
BEGIN

    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    IF p_operation = 'GetFeeHead' THEN

        OPEN p_result FOR
        SELECT
            fee_head_id,
            tenant_id,
            school_id,
            fee_head_name,
            frequency,
            COALESCE(default_amount, 0) AS default_amount,
            fee_type,
            fee_group,
            COALESCE(display_order, 0) AS display_order,
            COALESCE(is_active, TRUE) AS is_active
        FROM core.school_fee_heads
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND COALESCE(is_deleted, FALSE) = FALSE
        ORDER BY display_order, fee_head_name;

    ELSIF p_operation = 'GetFeeHeadById' THEN

        OPEN p_result FOR
        SELECT
            fee_head_id,
            tenant_id,
            school_id,
            fee_head_name,
            frequency,
            COALESCE(default_amount, 0) AS default_amount,
            fee_type,
            fee_group,
            COALESCE(display_order, 0) AS display_order,
            COALESCE(is_active, TRUE) AS is_active
        FROM core.school_fee_heads
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND fee_head_id = p_fee_head_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

    ELSIF p_operation = 'SaveFeeHead' THEN

        IF p_fee_head_id > 0 THEN

            UPDATE core.school_fee_heads
            SET
                fee_head_name = p_fee_head_name,
                frequency = p_frequency,
                default_amount = COALESCE(p_default_amount, 0),
                fee_type = p_fee_type,
                fee_group = COALESCE(p_fee_group, 'Academic'),
                display_order = COALESCE(p_display_order, 0),
                updated_by = p_action_user_id,
                updated_at = NOW()
            WHERE tenant_id = p_tenant_id
              AND school_id = p_school_id
              AND fee_head_id = p_fee_head_id
              AND COALESCE(is_deleted, FALSE) = FALSE;

        ELSE

            INSERT INTO core.school_fee_heads
            (
                tenant_id,
                school_id,
                fee_head_name,
                frequency,
                default_amount,
                fee_type,
                fee_group,
                display_order,
                is_active,
                is_deleted,
                created_by,
                created_at
            )
            VALUES
            (
                p_tenant_id,
                p_school_id,
                p_fee_head_name,
                p_frequency,
                COALESCE(p_default_amount, 0),
                p_fee_type,
                COALESCE(p_fee_group, 'Academic'),
                COALESCE(p_display_order, 0),
                TRUE,
                FALSE,
                p_action_user_id,
                NOW()
            )
            ON CONFLICT (tenant_id, school_id, fee_head_name)
            DO UPDATE SET
                frequency = EXCLUDED.frequency,
                default_amount = EXCLUDED.default_amount,
                fee_type = EXCLUDED.fee_type,
                fee_group = EXCLUDED.fee_group,
                display_order = EXCLUDED.display_order,
                is_active = TRUE,
                is_deleted = FALSE,
                updated_by = p_action_user_id,
                updated_at = NOW();

        END IF;

        OPEN p_result FOR
        SELECT
            TRUE AS success,
            'Fee head saved successfully.' AS message;

    ELSIF p_operation = 'DeleteFeeHead' THEN

        UPDATE core.school_fee_heads
        SET
            is_deleted = TRUE,
            is_active = FALSE,
            updated_by = p_action_user_id,
            updated_at = NOW()
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND fee_head_id = p_fee_head_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

        OPEN p_result FOR
        SELECT
            TRUE AS success,
            'Fee head deleted successfully.' AS message;

    ELSIF p_operation = 'ToggleFeeHeadStatus' THEN

        UPDATE core.school_fee_heads
        SET
            is_active = NOT COALESCE(is_active, TRUE),
            updated_by = p_action_user_id,
            updated_at = NOW()
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND fee_head_id = p_fee_head_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

        OPEN p_result FOR
        SELECT
            TRUE AS success,
            'Fee head status updated successfully.' AS message;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;

END;
$$;


--
-- Name: sp_school_admin_fee_structure_manage(character varying, integer, integer, integer, integer, character varying, character varying, integer, character varying, character varying, numeric, numeric, numeric, numeric, numeric, refcursor); Type: PROCEDURE; Schema: core; Owner: -
--

CREATE PROCEDURE core.sp_school_admin_fee_structure_manage(IN p_operation character varying, IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_fee_structure_id integer DEFAULT 0, IN p_class_name character varying DEFAULT NULL::character varying, IN p_academic_year character varying DEFAULT NULL::character varying, IN p_fee_head_id integer DEFAULT 0, IN p_fee_head_name character varying DEFAULT NULL::character varying, IN p_frequency character varying DEFAULT NULL::character varying, IN p_amount numeric DEFAULT 0, IN p_one_time_total numeric DEFAULT 0, IN p_monthly_total numeric DEFAULT 0, IN p_yearly_total numeric DEFAULT 0, IN p_annual_total numeric DEFAULT 0, INOUT p_result refcursor DEFAULT 'result_cursor'::refcursor)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_fee_structure_id INTEGER;
BEGIN

    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    IF p_operation = 'GetFeeStructure' THEN

        OPEN p_result FOR
        SELECT
            fs.fee_structure_id,
            fs.tenant_id,
            fs.school_id,
            fs.class_name,
            fs.academic_year,
            COALESCE(fs.one_time_total, 0) AS one_time_total,
            COALESCE(fs.monthly_total, 0) AS monthly_total,
            COALESCE(fs.yearly_total, 0) AS yearly_total,
            COALESCE(fs.annual_total, 0) AS annual_total,
            COALESCE(fs.is_active, TRUE) AS is_active,
            COALESCE(string_agg(fsd.fee_head_name, ', ' ORDER BY fsd.fee_head_name), '') AS fee_head_names,
            fs.created_by,
            fs.updated_by,
            COALESCE(fs.updated_at, fs.created_at) AS updated_at
        FROM core.school_fee_structures fs
        LEFT JOIN core.school_fee_structure_details fsd
            ON fsd.fee_structure_id = fs.fee_structure_id
           AND fsd.tenant_id = p_tenant_id
           AND fsd.school_id = p_school_id
           AND COALESCE(fsd.is_deleted, FALSE) = FALSE
           AND COALESCE(fsd.is_selected, TRUE) = TRUE
        WHERE fs.tenant_id = p_tenant_id
          AND fs.school_id = p_school_id
          AND COALESCE(fs.is_deleted, FALSE) = FALSE
        GROUP BY
            fs.fee_structure_id,
            fs.tenant_id,
            fs.school_id,
            fs.class_name,
            fs.academic_year,
            fs.one_time_total,
            fs.monthly_total,
            fs.yearly_total,
            fs.annual_total,
            fs.is_active,
            fs.created_by,
            fs.updated_by,
            fs.created_at,
            fs.updated_at
        ORDER BY fs.academic_year DESC, fs.class_name;

    ELSIF p_operation = 'GetFeeStructureByClass' THEN

        OPEN p_result FOR
        SELECT
            fs.fee_structure_id,
            fs.tenant_id,
            fs.school_id,
            fs.class_name,
            fs.academic_year,
            COALESCE(fs.one_time_total, 0) AS one_time_total,
            COALESCE(fs.monthly_total, 0) AS monthly_total,
            COALESCE(fs.yearly_total, 0) AS yearly_total,
            COALESCE(fs.annual_total, 0) AS annual_total,
            COALESCE(fs.is_active, TRUE) AS is_active
        FROM core.school_fee_structures fs
        WHERE fs.tenant_id = p_tenant_id
          AND fs.school_id = p_school_id
          AND fs.class_name = p_class_name
          AND fs.academic_year = p_academic_year
          AND COALESCE(fs.is_deleted, FALSE) = FALSE;

    ELSIF p_operation = 'GetFeeStructureDetails' THEN

        OPEN p_result FOR
        SELECT
            fsd.fee_structure_detail_id,
            fsd.tenant_id,
            fsd.school_id,
            fsd.fee_structure_id,
            fsd.fee_head_id,
            fsd.fee_head_name,
            fsd.frequency,
            COALESCE(fsd.amount, 0) AS amount,
            COALESCE(fsd.is_selected, TRUE) AS is_selected
        FROM core.school_fee_structure_details fsd
        INNER JOIN core.school_fee_structures fs
            ON fs.fee_structure_id = fsd.fee_structure_id
           AND fs.tenant_id = p_tenant_id
           AND fs.school_id = p_school_id
           AND COALESCE(fs.is_deleted, FALSE) = FALSE
        WHERE fsd.tenant_id = p_tenant_id
          AND fsd.school_id = p_school_id
          AND fs.class_name = p_class_name
          AND fs.academic_year = p_academic_year
          AND COALESCE(fsd.is_deleted, FALSE) = FALSE
        ORDER BY fsd.frequency, fsd.fee_head_name;

    ELSIF p_operation = 'SaveFeeStructure' THEN

        INSERT INTO core.school_fee_structures
        (
            tenant_id,
            school_id,
            class_name,
            academic_year,
            one_time_total,
            monthly_total,
            yearly_total,
            annual_total,
            is_active,
            is_deleted,
            created_by,
            created_at
        )
        VALUES
        (
            p_tenant_id,
            p_school_id,
            p_class_name,
            p_academic_year,
            COALESCE(p_one_time_total, 0),
            COALESCE(p_monthly_total, 0),
            COALESCE(p_yearly_total, 0),
            COALESCE(p_annual_total, 0),
            TRUE,
            FALSE,
            p_action_user_id,
            NOW()
        )
        ON CONFLICT (tenant_id, school_id, class_name, academic_year)
        DO UPDATE SET
            one_time_total = EXCLUDED.one_time_total,
            monthly_total = EXCLUDED.monthly_total,
            yearly_total = EXCLUDED.yearly_total,
            annual_total = EXCLUDED.annual_total,
            is_active = TRUE,
            is_deleted = FALSE,
            updated_by = p_action_user_id,
            updated_at = NOW()
        RETURNING fee_structure_id INTO v_fee_structure_id;

        UPDATE core.school_fee_structure_details
        SET
            is_deleted = TRUE,
            is_selected = FALSE,
            updated_by = p_action_user_id,
            updated_at = NOW()
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND fee_structure_id = v_fee_structure_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

        OPEN p_result FOR
        SELECT
            TRUE AS success,
            'Fee structure saved successfully.' AS message,
            v_fee_structure_id AS fee_structure_id;

    ELSIF p_operation = 'SaveFeeStructureDetail' THEN

        SELECT fee_structure_id
        INTO v_fee_structure_id
        FROM core.school_fee_structures
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND class_name = p_class_name
          AND academic_year = p_academic_year
          AND COALESCE(is_deleted, FALSE) = FALSE
        LIMIT 1;

        IF COALESCE(v_fee_structure_id, 0) = 0 THEN
            RAISE EXCEPTION 'Fee structure not found for class % and academic year %', p_class_name, p_academic_year;
        END IF;

        INSERT INTO core.school_fee_structure_details
        (
            tenant_id,
            school_id,
            fee_structure_id,
            fee_head_id,
            fee_head_name,
            frequency,
            amount,
            is_selected,
            is_deleted,
            created_by,
            created_at
        )
        VALUES
        (
            p_tenant_id,
            p_school_id,
            v_fee_structure_id,
            p_fee_head_id,
            p_fee_head_name,
            p_frequency,
            COALESCE(p_amount, 0),
            TRUE,
            FALSE,
            p_action_user_id,
            NOW()
        )
        ON CONFLICT (tenant_id, school_id, fee_structure_id, fee_head_id)
        DO UPDATE SET
            fee_head_name = EXCLUDED.fee_head_name,
            frequency = EXCLUDED.frequency,
            amount = EXCLUDED.amount,
            is_selected = TRUE,
            is_deleted = FALSE,
            updated_by = p_action_user_id,
            updated_at = NOW();

        OPEN p_result FOR
        SELECT
            TRUE AS success,
            'Fee structure detail saved successfully.' AS message,
            v_fee_structure_id AS fee_structure_id;

    ELSIF p_operation = 'DeleteFeeStructure' THEN

        UPDATE core.school_fee_structures
        SET
            is_deleted = TRUE,
            is_active = FALSE,
            updated_by = p_action_user_id,
            updated_at = NOW()
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND fee_structure_id = p_fee_structure_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

        UPDATE core.school_fee_structure_details
        SET
            is_deleted = TRUE,
            is_selected = FALSE,
            updated_by = p_action_user_id,
            updated_at = NOW()
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND fee_structure_id = p_fee_structure_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

        OPEN p_result FOR
        SELECT
            TRUE AS success,
            'Fee structure deleted successfully.' AS message;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;

END;
$$;


--
-- Name: sp_school_manage(character varying, integer, integer, character varying, integer, character varying, character varying, character varying, character varying, integer, character varying, character varying, integer, character varying, character varying, integer, integer, integer, integer, integer, character varying, integer, character varying, character varying, character varying, character varying, character varying, character varying, integer, character varying, character varying, character varying, character varying, character varying, integer, integer, integer, boolean, boolean, boolean, boolean, character varying, character varying, character varying, character varying, refcursor); Type: PROCEDURE; Schema: core; Owner: -
--

CREATE PROCEDURE core.sp_school_manage(IN p_operation character varying, IN p_tenant_id integer, IN p_action_user_id integer, IN p_tenant_mode character varying DEFAULT NULL::character varying, IN p_selected_tenant_id integer DEFAULT NULL::integer, IN p_tenant_name character varying DEFAULT NULL::character varying, IN p_tenant_code character varying DEFAULT NULL::character varying, IN p_tenant_email character varying DEFAULT NULL::character varying, IN p_tenant_phone character varying DEFAULT NULL::character varying, IN p_school_id integer DEFAULT NULL::integer, IN p_school_name character varying DEFAULT NULL::character varying, IN p_display_name character varying DEFAULT NULL::character varying, IN p_status_id integer DEFAULT NULL::integer, IN p_registration_number character varying DEFAULT NULL::character varying, IN p_affiliation_number character varying DEFAULT NULL::character varying, IN p_board_id integer DEFAULT NULL::integer, IN p_school_type_id integer DEFAULT NULL::integer, IN p_ownership_type_id integer DEFAULT NULL::integer, IN p_medium_id integer DEFAULT NULL::integer, IN p_established_year integer DEFAULT NULL::integer, IN p_website character varying DEFAULT NULL::character varying, IN p_address_type_id integer DEFAULT NULL::integer, IN p_address_line1 character varying DEFAULT NULL::character varying, IN p_address_line2 character varying DEFAULT NULL::character varying, IN p_city character varying DEFAULT NULL::character varying, IN p_district character varying DEFAULT NULL::character varying, IN p_state character varying DEFAULT NULL::character varying, IN p_pincode character varying DEFAULT NULL::character varying, IN p_contact_type_id integer DEFAULT NULL::integer, IN p_contact_name character varying DEFAULT NULL::character varying, IN p_designation character varying DEFAULT NULL::character varying, IN p_contact_email character varying DEFAULT NULL::character varying, IN p_phone character varying DEFAULT NULL::character varying, IN p_alternate_phone character varying DEFAULT NULL::character varying, IN p_academic_year_id integer DEFAULT NULL::integer, IN p_date_format_id integer DEFAULT NULL::integer, IN p_time_format_id integer DEFAULT NULL::integer, IN p_enable_sms boolean DEFAULT false, IN p_enable_email boolean DEFAULT false, IN p_enable_whatsapp boolean DEFAULT false, IN p_create_school_admin boolean DEFAULT false, IN p_admin_full_name character varying DEFAULT NULL::character varying, IN p_admin_email character varying DEFAULT NULL::character varying, IN p_admin_phone character varying DEFAULT NULL::character varying, IN p_password_hash character varying DEFAULT NULL::character varying, INOUT p_result refcursor DEFAULT 'school_cursor'::refcursor)
    LANGUAGE plpgsql
    AS $_$
DECLARE
    v_school_id integer;
    v_tenant_id integer;
    v_school_code character varying;
    v_user_id integer;
BEGIN
    IF p_operation IS NULL OR TRIM(p_operation) = '' THEN
        RAISE EXCEPTION 'Operation is required.';
    END IF;

    p_operation := UPPER(TRIM(p_operation));

    /*
        LIST
    */
    IF p_operation = 'L' THEN
        OPEN p_result FOR
        SELECT
            s.school_id,
            s.school_code,
            s.school_name,
            s.display_name,
            t.tenant_name,
            st.name AS status_name,
            b.name AS board_name,
            sty.name AS school_type_name,
            a.city,
            a.state,
            c.contact_name,
            c.phone,
            s.created_at
        FROM core.schools s
        INNER JOIN core.tenants t
            ON t.tenant_id = s.tenant_id
           AND t.is_deleted = FALSE
        LEFT JOIN core.school_profiles sp
            ON sp.tenant_id = s.tenant_id
           AND sp.school_id = s.school_id
           AND sp.is_deleted = FALSE
           AND sp.is_active = TRUE
        LEFT JOIN config.school_statuses st
            ON st.school_status_id = s.status_id
           AND st.is_deleted = FALSE
        LEFT JOIN config.boards b
            ON b.board_id = sp.board_id
           AND b.is_deleted = FALSE
        LEFT JOIN config.school_types sty
            ON sty.school_type_id = sp.school_type_id
           AND sty.is_deleted = FALSE
        LEFT JOIN core.school_addresses a
            ON a.tenant_id = s.tenant_id
           AND a.school_id = s.school_id
           AND a.is_primary = TRUE
           AND a.is_active = TRUE
           AND a.is_deleted = FALSE
        LEFT JOIN core.school_contacts c
            ON c.tenant_id = s.tenant_id
           AND c.school_id = s.school_id
           AND c.is_primary = TRUE
           AND c.is_active = TRUE
           AND c.is_deleted = FALSE
        WHERE s.is_active = TRUE
          AND s.is_deleted = FALSE
          AND (
                p_tenant_id = 1
                OR s.tenant_id = p_tenant_id
              )
        ORDER BY s.school_id DESC;

        RETURN;
    END IF;

    /*
        GET BY ID
    */
    IF p_operation = 'G' THEN
        IF p_school_id IS NULL OR p_school_id <= 0 THEN
            RAISE EXCEPTION 'School id is required.';
        END IF;

        OPEN p_result FOR
        SELECT
            s.tenant_id,
            t.tenant_name,
            t.tenant_code,
            s.school_id,
            s.school_code,
            s.school_name,
            s.display_name,
            s.status_id,

            sp.registration_number,
            sp.affiliation_number,
            sp.board_id,
            sp.school_type_id,
            sp.ownership_type_id,
            sp.medium_id,
            sp.established_year,
            sp.website,
            sp.logo_url,
            sp.header_image_url,
            sp.description,

            a.address_type_id,
            a.address_line1,
            a.address_line2,
            a.city,
            a.district,
            a.state,
            a.pincode,

            c.contact_type_id,
            c.contact_name,
            c.designation,
            c.email,
            c.phone,
            c.alternate_phone,

            ss.academic_year_id,
            ss.date_format_id,
            ss.time_format_id,
            COALESCE(ss.enable_sms, FALSE) AS enable_sms,
            COALESCE(ss.enable_email, FALSE) AS enable_email,
            COALESCE(ss.enable_whatsapp, FALSE) AS enable_whatsapp
        FROM core.schools s
        LEFT JOIN core.tenants t
            ON t.tenant_id = s.tenant_id
           AND t.is_deleted = FALSE
        LEFT JOIN core.school_profiles sp
            ON sp.tenant_id = s.tenant_id
           AND sp.school_id = s.school_id
           AND sp.is_deleted = FALSE
        LEFT JOIN core.school_addresses a
            ON a.tenant_id = s.tenant_id
           AND a.school_id = s.school_id
           AND a.is_primary = TRUE
           AND a.is_active = TRUE
           AND a.is_deleted = FALSE
        LEFT JOIN core.school_contacts c
            ON c.tenant_id = s.tenant_id
           AND c.school_id = s.school_id
           AND c.is_primary = TRUE
           AND c.is_active = TRUE
           AND c.is_deleted = FALSE
        LEFT JOIN core.school_settings ss
            ON ss.tenant_id = s.tenant_id
           AND ss.school_id = s.school_id
           AND ss.is_deleted = FALSE
        WHERE s.school_id = p_school_id
          AND (p_tenant_id = 0 OR s.tenant_id = p_tenant_id)
          AND s.is_active = TRUE
          AND s.is_deleted = FALSE;

        RETURN;
    END IF;

    /*
        DELETE / SOFT DELETE
    */
    IF p_operation = 'D' THEN
        IF p_school_id IS NULL OR p_school_id <= 0 THEN
            RAISE EXCEPTION 'School id is required.';
        END IF;

        UPDATE core.schools
        SET
            is_active = FALSE,
            is_deleted = TRUE,
            deleted_by = p_action_user_id,
            deleted_at = NOW(),
            updated_by = p_action_user_id,
            updated_at = NOW()
        WHERE school_id = p_school_id
          AND (p_tenant_id = 0 OR tenant_id = p_tenant_id)
          AND is_deleted = FALSE;

        OPEN p_result FOR
        SELECT p_school_id AS school_id;

        RETURN;
    END IF;

    /*
        INSERT / UPDATE VALIDATION
    */
    IF p_operation NOT IN ('I', 'U') THEN
        RAISE EXCEPTION 'Invalid operation: %', p_operation;
    END IF;

    IF p_school_name IS NULL OR TRIM(p_school_name) = '' THEN
        RAISE EXCEPTION 'School name is required.';
    END IF;

    IF p_status_id IS NULL OR p_status_id <= 0 THEN
        RAISE EXCEPTION 'Status is required.';
    END IF;

    IF p_address_line1 IS NULL OR TRIM(p_address_line1) = '' THEN
        RAISE EXCEPTION 'Address line 1 is required.';
    END IF;

    IF p_city IS NULL OR TRIM(p_city) = '' THEN
        RAISE EXCEPTION 'City is required.';
    END IF;

    IF p_state IS NULL OR TRIM(p_state) = '' THEN
        RAISE EXCEPTION 'State is required.';
    END IF;

    IF p_pincode IS NULL OR TRIM(p_pincode) = '' THEN
        RAISE EXCEPTION 'Pincode is required.';
    END IF;

    IF TRIM(p_pincode) !~ '^[0-9]{6}$' THEN
        RAISE EXCEPTION 'Pincode must be 6 digits.';
    END IF;

    IF p_contact_name IS NULL OR TRIM(p_contact_name) = '' THEN
        RAISE EXCEPTION 'Contact name is required.';
    END IF;

    IF p_phone IS NULL OR TRIM(p_phone) = '' THEN
        RAISE EXCEPTION 'Phone is required.';
    END IF;

    /*
        TENANT RESOLUTION
    */
    IF p_operation = 'I' THEN
        IF p_tenant_mode = 'existing' THEN
            IF p_selected_tenant_id IS NULL OR p_selected_tenant_id <= 0 THEN
                RAISE EXCEPTION 'Please select tenant.';
            END IF;

            IF NOT EXISTS (
                SELECT 1
                FROM core.tenants
                WHERE tenant_id = p_selected_tenant_id
                  AND is_active = TRUE
                  AND is_deleted = FALSE
            ) THEN
                RAISE EXCEPTION 'Selected tenant does not exist.';
            END IF;

            v_tenant_id := p_selected_tenant_id;

        ELSIF p_tenant_mode = 'new' THEN
            IF p_tenant_name IS NULL OR TRIM(p_tenant_name) = '' THEN
                RAISE EXCEPTION 'Tenant name is required.';
            END IF;

            IF p_tenant_code IS NULL OR TRIM(p_tenant_code) = '' THEN
                RAISE EXCEPTION 'Tenant code is required.';
            END IF;

            IF EXISTS (
                SELECT 1
                FROM core.tenants
                WHERE LOWER(TRIM(tenant_code)) = LOWER(TRIM(p_tenant_code))
                  AND is_deleted = FALSE
            ) THEN
                RAISE EXCEPTION 'Tenant code already exists.';
            END IF;

            IF p_tenant_email IS NOT NULL
               AND TRIM(p_tenant_email) <> ''
               AND EXISTS (
                    SELECT 1
                    FROM core.tenants
                    WHERE LOWER(TRIM(contact_email)) = LOWER(TRIM(p_tenant_email))
                      AND is_deleted = FALSE
               ) THEN
                RAISE EXCEPTION 'Tenant email already exists.';
            END IF;

            INSERT INTO core.tenants
            (
                tenant_name,
                tenant_code,
                contact_email,
                contact_phone,
                is_active,
                created_by,
                created_at
            )
            VALUES
            (
                TRIM(p_tenant_name),
                LOWER(TRIM(p_tenant_code)),
                NULLIF(TRIM(p_tenant_email), ''),
                NULLIF(TRIM(p_tenant_phone), ''),
                TRUE,
                p_action_user_id,
                NOW()
            )
            RETURNING tenant_id INTO v_tenant_id;

        ELSE
            RAISE EXCEPTION 'Tenant option is required.';
        END IF;
    ELSE
        v_tenant_id := p_tenant_id;
    END IF;

    IF v_tenant_id IS NULL OR v_tenant_id <= 0 THEN
        RAISE EXCEPTION 'Tenant id is required.';
    END IF;

    /*
        SCHOOL DUPLICATE VALIDATION
    */
    IF EXISTS (
        SELECT 1
        FROM core.schools
        WHERE tenant_id = v_tenant_id
          AND LOWER(TRIM(school_name)) = LOWER(TRIM(p_school_name))
          AND is_deleted = FALSE
          AND (p_operation = 'I' OR school_id <> p_school_id)
    ) THEN
        RAISE EXCEPTION 'School name already exists for this tenant.';
    END IF;

    IF p_registration_number IS NOT NULL
       AND TRIM(p_registration_number) <> ''
       AND EXISTS (
            SELECT 1
            FROM core.school_profiles sp
            WHERE sp.tenant_id = v_tenant_id
              AND LOWER(TRIM(sp.registration_number)) = LOWER(TRIM(p_registration_number))
              AND sp.is_deleted = FALSE
              AND (p_operation = 'I' OR sp.school_id <> p_school_id)
       ) THEN
        RAISE EXCEPTION 'Registration number already exists for this tenant.';
    END IF;

    IF p_affiliation_number IS NOT NULL
       AND TRIM(p_affiliation_number) <> ''
       AND EXISTS (
            SELECT 1
            FROM core.school_profiles sp
            WHERE sp.tenant_id = v_tenant_id
              AND LOWER(TRIM(sp.affiliation_number)) = LOWER(TRIM(p_affiliation_number))
              AND sp.is_deleted = FALSE
              AND (p_operation = 'I' OR sp.school_id <> p_school_id)
       ) THEN
        RAISE EXCEPTION 'Affiliation number already exists for this tenant.';
    END IF;

    /*
        ADMIN VALIDATION
    */
    IF COALESCE(p_create_school_admin, FALSE) = TRUE THEN
        IF p_admin_full_name IS NULL OR TRIM(p_admin_full_name) = '' THEN
            RAISE EXCEPTION 'Admin full name is required.';
        END IF;

        IF p_admin_email IS NULL OR TRIM(p_admin_email) = '' THEN
            RAISE EXCEPTION 'Admin email is required.';
        END IF;

        IF p_operation = 'I'
           AND EXISTS (
                SELECT 1
                FROM core.users
                WHERE LOWER(TRIM(email)) = LOWER(TRIM(p_admin_email))
                  AND is_active = TRUE
           ) THEN
            RAISE EXCEPTION 'Admin email already exists.';
        END IF;
    END IF;

    /*
        INSERT / UPDATE SCHOOL MASTER
        Only basic school fields should be stored in core.schools.
    */
    IF p_operation = 'I' THEN
        v_school_code := 'SCH' || TO_CHAR(NOW(), 'YYYYMMDDHH24MISS');

        INSERT INTO core.schools
        (
            tenant_id,
            school_code,
            school_name,
            display_name,
            status_id,
            is_active,
            created_by,
            created_at
        )
        VALUES
        (
            v_tenant_id,
            v_school_code,
            TRIM(p_school_name),
            NULLIF(TRIM(p_display_name), ''),
            p_status_id,
            TRUE,
            p_action_user_id,
            NOW()
        )
        RETURNING school_id INTO v_school_id;

    ELSE
        IF p_school_id IS NULL OR p_school_id <= 0 THEN
            RAISE EXCEPTION 'School id is required.';
        END IF;

        IF NOT EXISTS (
            SELECT 1
            FROM core.schools
            WHERE school_id = p_school_id
              AND tenant_id = v_tenant_id
              AND is_active = TRUE
              AND is_deleted = FALSE
        ) THEN
            RAISE EXCEPTION 'School not found.';
        END IF;

        v_school_id := p_school_id;

        UPDATE core.schools
        SET
            school_name = TRIM(p_school_name),
            display_name = NULLIF(TRIM(p_display_name), ''),
            status_id = p_status_id,
            updated_by = p_action_user_id,
            updated_at = NOW()
        WHERE school_id = v_school_id
          AND tenant_id = v_tenant_id;
    END IF;

    /*
        SCHOOL PROFILE UPSERT
    */
    INSERT INTO core.school_profiles
    (
        tenant_id,
        school_id,
        registration_number,
        affiliation_number,
        board_id,
        school_type_id,
        ownership_type_id,
        medium_id,
        established_year,
        website,
        is_active,
        created_by,
        created_at
    )
    VALUES
    (
        v_tenant_id,
        v_school_id,
        NULLIF(TRIM(p_registration_number), ''),
        NULLIF(TRIM(p_affiliation_number), ''),
        p_board_id,
        p_school_type_id,
        p_ownership_type_id,
        p_medium_id,
        p_established_year,
        NULLIF(TRIM(p_website), ''),
        TRUE,
        p_action_user_id,
        NOW()
    )
    ON CONFLICT (tenant_id, school_id)
    DO UPDATE SET
        registration_number = EXCLUDED.registration_number,
        affiliation_number = EXCLUDED.affiliation_number,
        board_id = EXCLUDED.board_id,
        school_type_id = EXCLUDED.school_type_id,
        ownership_type_id = EXCLUDED.ownership_type_id,
        medium_id = EXCLUDED.medium_id,
        established_year = EXCLUDED.established_year,
        website = EXCLUDED.website,
        is_active = TRUE,
        is_deleted = FALSE,
        updated_by = p_action_user_id,
        updated_at = NOW();

    /*
        ADDRESS UPSERT
    */
    INSERT INTO core.school_addresses
    (
        tenant_id,
        school_id,
        address_type_id,
        address_line1,
        address_line2,
        city,
        district,
        state,
        pincode,
        is_primary,
        is_active,
        created_by,
        created_at
    )
    VALUES
    (
        v_tenant_id,
        v_school_id,
        COALESCE(p_address_type_id, 1),
        TRIM(p_address_line1),
        NULLIF(TRIM(p_address_line2), ''),
        TRIM(p_city),
        NULLIF(TRIM(p_district), ''),
        TRIM(p_state),
        TRIM(p_pincode),
        TRUE,
        TRUE,
        p_action_user_id,
        NOW()
    )
    ON CONFLICT (tenant_id, school_id, address_type_id)
    DO UPDATE SET
        address_line1 = EXCLUDED.address_line1,
        address_line2 = EXCLUDED.address_line2,
        city = EXCLUDED.city,
        district = EXCLUDED.district,
        state = EXCLUDED.state,
        pincode = EXCLUDED.pincode,
        is_primary = TRUE,
        is_active = TRUE,
        is_deleted = FALSE,
        updated_by = p_action_user_id,
        updated_at = NOW();

    /*
        CONTACT UPSERT
    */
    INSERT INTO core.school_contacts
    (
        tenant_id,
        school_id,
        contact_type_id,
        contact_name,
        designation,
        email,
        phone,
        alternate_phone,
        is_primary,
        is_active,
        created_by,
        created_at
    )
    VALUES
    (
        v_tenant_id,
        v_school_id,
        COALESCE(p_contact_type_id, 1),
        TRIM(p_contact_name),
        NULLIF(TRIM(p_designation), ''),
        NULLIF(TRIM(p_contact_email), ''),
        TRIM(p_phone),
        NULLIF(TRIM(p_alternate_phone), ''),
        TRUE,
        TRUE,
        p_action_user_id,
        NOW()
    )
    ON CONFLICT (tenant_id, school_id, contact_type_id)
    DO UPDATE SET
        contact_name = EXCLUDED.contact_name,
        designation = EXCLUDED.designation,
        email = EXCLUDED.email,
        phone = EXCLUDED.phone,
        alternate_phone = EXCLUDED.alternate_phone,
        is_primary = TRUE,
        is_active = TRUE,
        is_deleted = FALSE,
        updated_by = p_action_user_id,
        updated_at = NOW();

    /*
        SETTINGS UPSERT
    */
    INSERT INTO core.school_settings
    (
        tenant_id,
        school_id,
        academic_year_id,
        date_format_id,
        time_format_id,
        enable_sms,
        enable_email,
        enable_whatsapp,
        is_active,
        created_by,
        created_at
    )
    VALUES
    (
        v_tenant_id,
        v_school_id,
        p_academic_year_id,
        p_date_format_id,
        p_time_format_id,
        COALESCE(p_enable_sms, FALSE),
        COALESCE(p_enable_email, FALSE),
        COALESCE(p_enable_whatsapp, FALSE),
        TRUE,
        p_action_user_id,
        NOW()
    )
    ON CONFLICT (tenant_id, school_id)
    DO UPDATE SET
        academic_year_id = EXCLUDED.academic_year_id,
        date_format_id = EXCLUDED.date_format_id,
        time_format_id = EXCLUDED.time_format_id,
        enable_sms = EXCLUDED.enable_sms,
        enable_email = EXCLUDED.enable_email,
        enable_whatsapp = EXCLUDED.enable_whatsapp,
        is_active = TRUE,
        is_deleted = FALSE,
        updated_by = p_action_user_id,
        updated_at = NOW();

    /*
        CREATE SCHOOL ADMIN
    */
    IF p_operation = 'I' AND COALESCE(p_create_school_admin, FALSE) = TRUE THEN
        INSERT INTO core.users
        (
            tenant_id,
            school_id,
            email,
            password_hash,
            --role_id,
            is_active,
            created_by,
            created_at
        )
        VALUES
        (
            v_tenant_id,
            v_school_id,
            LOWER(TRIM(p_admin_email)),
            p_password_hash,
           -- 3,
            TRUE,
            p_action_user_id,
            NOW()
        )
        RETURNING user_id INTO v_user_id;

        INSERT INTO core.user_profiles
        (
            tenant_id,
            user_id,
            school_id,
            full_name,
            phone,
            designation,
            is_active,
            created_by,
            created_at
        )
        VALUES
        (
            v_tenant_id,
            v_user_id,
            v_school_id,
            TRIM(p_admin_full_name),
            NULLIF(TRIM(p_admin_phone), ''),
            'School Admin',
            TRUE,
            p_action_user_id,
            NOW()
        );

        INSERT INTO core.user_roles
        (
            tenant_id,
            user_id,
            role_id,
            school_id,
            is_active,
            created_by,
            created_at
        )
        VALUES
        (
            v_tenant_id,
            v_user_id,
            3,
            v_school_id,
            TRUE,
            p_action_user_id,
            NOW()
        )
        ON CONFLICT (tenant_id, user_id, role_id) DO NOTHING;
    END IF;

    /*
        FINAL RESULT
    */
    OPEN p_result FOR
    SELECT
        v_school_id AS school_id,
        v_tenant_id AS tenant_id;
END;
$_$;


--
-- Name: sp_school_user_management(character varying, integer, integer, integer, character varying, text, character varying, character varying, character varying, integer, boolean, integer, refcursor); Type: PROCEDURE; Schema: core; Owner: -
--

CREATE PROCEDURE core.sp_school_user_management(IN p_operation_type character varying, IN p_tenant_id integer, IN p_school_id integer, IN p_user_id integer DEFAULT NULL::integer, IN p_email character varying DEFAULT NULL::character varying, IN p_password_hash text DEFAULT NULL::text, IN p_full_name character varying DEFAULT NULL::character varying, IN p_phone character varying DEFAULT NULL::character varying, IN p_designation character varying DEFAULT NULL::character varying, IN p_role_id integer DEFAULT NULL::integer, IN p_is_active boolean DEFAULT NULL::boolean, IN p_action_by integer DEFAULT NULL::integer, INOUT p_result refcursor DEFAULT NULL::refcursor)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_new_user_id integer;
BEGIN

    IF p_operation_type = 'LIST' THEN

        OPEN p_result FOR
        SELECT
            u.user_id,
            u.email,
            u.is_active,
            u.created_at,
            up.full_name,
            up.phone,
            up.designation,
            r.role_id,
            r.role_name
        FROM core.users u
        LEFT JOIN core.user_profiles up
            ON up.tenant_id = u.tenant_id
           AND up.school_id = u.school_id
           AND up.user_id = u.user_id
           AND up.is_deleted = false
        LEFT JOIN core.user_roles ur
            ON ur.tenant_id = u.tenant_id
           AND ur.school_id = u.school_id
           AND ur.user_id = u.user_id
           AND ur.is_deleted = false
        LEFT JOIN config.roles r
            ON r.role_id = ur.role_id
           AND r.is_deleted = false
        WHERE u.tenant_id = p_tenant_id
          AND u.school_id = p_school_id
          AND u.is_deleted = false
        ORDER BY u.created_at DESC;

    ELSIF p_operation_type = 'GET_BY_ID' THEN

        OPEN p_result FOR
        SELECT
            u.user_id,
            u.email,
            u.is_active,
            up.full_name,
            up.phone,
            up.alternate_phone,
            up.designation,
            up.profile_photo_url,
            r.role_id,
            r.role_name
        FROM core.users u
        LEFT JOIN core.user_profiles up
            ON up.tenant_id = u.tenant_id
           AND up.school_id = u.school_id
           AND up.user_id = u.user_id
           AND up.is_deleted = false
        LEFT JOIN core.user_roles ur
            ON ur.tenant_id = u.tenant_id
           AND ur.school_id = u.school_id
           AND ur.user_id = u.user_id
           AND ur.is_deleted = false
        LEFT JOIN config.roles r
            ON r.role_id = ur.role_id
           AND r.is_deleted = false
        WHERE u.tenant_id = p_tenant_id
          AND u.school_id = p_school_id
          AND u.user_id = p_user_id
          AND u.is_deleted = false;

    ELSIF p_operation_type = 'CREATE' THEN

        IF EXISTS (
            SELECT 1
            FROM core.users
            WHERE tenant_id = p_tenant_id
              AND school_id = p_school_id
              AND LOWER(email) = LOWER(p_email)
              AND is_deleted = false
        ) THEN
            OPEN p_result FOR SELECT false AS success, 'Email already exists.' AS message;
            RETURN;
        END IF;

        INSERT INTO core.users
        (
            tenant_id, school_id, email, password_hash,
            is_email_verified, is_active,
            created_by
        )
        VALUES
        (
            p_tenant_id, p_school_id, LOWER(p_email), p_password_hash,
             false, true,
            p_action_by
        )
        RETURNING user_id INTO v_new_user_id;

        INSERT INTO core.user_profiles
        (
            tenant_id, school_id, user_id,
            full_name, phone, designation,
            created_by
        )
        VALUES
        (
            p_tenant_id, p_school_id, v_new_user_id,
            p_full_name, p_phone, p_designation,
            p_action_by
        );

        INSERT INTO core.user_roles
        (
            tenant_id, school_id, user_id, role_id,
            created_by
        )
        VALUES
        (
            p_tenant_id, p_school_id, v_new_user_id, p_role_id,
            p_action_by
        );

        INSERT INTO core.admin_activity_logs
        (
            tenant_id, school_id, user_id,
            action, module_name, table_name, record_id,
            description, created_by
        )
        VALUES
        (
            p_tenant_id, p_school_id, p_action_by,
            'CREATE_USER', 'School User Management', 'core.users', v_new_user_id,
            'School user created: ' || p_email,
            p_action_by
        );

        OPEN p_result FOR
        SELECT true AS success, 'User created successfully.' AS message, v_new_user_id AS user_id;

    ELSIF p_operation_type = 'UPDATE' THEN

        UPDATE core.users
        SET
            email = LOWER(p_email),
            updated_by = p_action_by,
            updated_at = CURRENT_TIMESTAMP
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND user_id = p_user_id
          AND is_deleted = false;

        UPDATE core.user_profiles
        SET
            full_name = p_full_name,
            phone = p_phone,
            designation = p_designation,
            updated_by = p_action_by,
            updated_at = CURRENT_TIMESTAMP
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND user_id = p_user_id
          AND is_deleted = false;

        UPDATE core.user_roles
        SET
            role_id = p_role_id,
            updated_by = p_action_by,
            updated_at = CURRENT_TIMESTAMP
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND user_id = p_user_id
          AND is_deleted = false;

        OPEN p_result FOR
        SELECT true AS success, 'User updated successfully.' AS message;

    ELSIF p_operation_type = 'SOFT_DELETE' THEN

        UPDATE core.users
        SET
            is_deleted = true,
            is_active = false,
            deleted_by = p_action_by,
            deleted_at = CURRENT_TIMESTAMP
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND user_id = p_user_id
          AND is_deleted = false;

        UPDATE core.user_roles
        SET
            is_deleted = true,
            is_active = false,
            deleted_by = p_action_by,
            deleted_at = CURRENT_TIMESTAMP
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND user_id = p_user_id
          AND is_deleted = false;

        OPEN p_result FOR
        SELECT true AS success, 'User deleted successfully.' AS message;

    ELSIF p_operation_type = 'CHANGE_STATUS' THEN

        UPDATE core.users
        SET
            is_active = p_is_active,
            updated_by = p_action_by,
            updated_at = CURRENT_TIMESTAMP
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND user_id = p_user_id
          AND is_deleted = false;

        OPEN p_result FOR
        SELECT true AS success, 'User status updated successfully.' AS message;

    END IF;

END;
$$;


--
-- Name: generate_school_code(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.generate_school_code() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.school_code IS NULL THEN
        NEW.school_code := 'SCH' || LPAD(NEW.id::TEXT, 4, '0');
    END IF;
    RETURN NEW;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: academic_class_sections; Type: TABLE; Schema: academic; Owner: -
--

CREATE TABLE academic.academic_class_sections (
    academic_class_section_id integer NOT NULL,
    tenant_id integer NOT NULL,
    school_id integer NOT NULL,
    academic_year_id integer NOT NULL,
    academic_class_id integer NOT NULL,
    section_name character varying(20) NOT NULL,
    display_order integer DEFAULT 0 NOT NULL,
    created_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_by integer,
    updated_at timestamp without time zone,
    deleted_by integer,
    deleted_at timestamp without time zone,
    is_deleted boolean DEFAULT false NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    CONSTRAINT chk_academic_class_sections_scope CHECK (((tenant_id > 1) AND (school_id > 0)))
);


--
-- Name: academic_class_sections_academic_class_section_id_seq; Type: SEQUENCE; Schema: academic; Owner: -
--

ALTER TABLE academic.academic_class_sections ALTER COLUMN academic_class_section_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME academic.academic_class_sections_academic_class_section_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: academic_classes; Type: TABLE; Schema: academic; Owner: -
--

CREATE TABLE academic.academic_classes (
    academic_class_id integer NOT NULL,
    tenant_id integer NOT NULL,
    school_id integer NOT NULL,
    academic_year_id integer NOT NULL,
    class_name character varying(50) NOT NULL,
    display_order integer DEFAULT 0 NOT NULL,
    created_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_by integer,
    updated_at timestamp without time zone,
    deleted_by integer,
    deleted_at timestamp without time zone,
    is_deleted boolean DEFAULT false NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    CONSTRAINT chk_academic_classes_scope CHECK (((tenant_id > 1) AND (school_id > 0)))
);


--
-- Name: academic_classes_academic_class_id_seq; Type: SEQUENCE; Schema: academic; Owner: -
--

ALTER TABLE academic.academic_classes ALTER COLUMN academic_class_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME academic.academic_classes_academic_class_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: academic_years; Type: TABLE; Schema: academic; Owner: -
--

CREATE TABLE academic.academic_years (
    academic_year_id integer NOT NULL,
    tenant_id integer NOT NULL,
    school_id integer NOT NULL,
    academic_year_name character varying(20) NOT NULL,
    start_date date NOT NULL,
    end_date date NOT NULL,
    is_current boolean DEFAULT false NOT NULL,
    created_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_by integer,
    updated_at timestamp without time zone,
    deleted_by integer,
    deleted_at timestamp without time zone,
    is_deleted boolean DEFAULT false NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    CONSTRAINT chk_academic_year_dates CHECK ((end_date > start_date)),
    CONSTRAINT chk_academic_year_scope CHECK (((tenant_id > 1) AND (school_id > 0)))
);


--
-- Name: academic_years_academic_year_id_seq; Type: SEQUENCE; Schema: academic; Owner: -
--

ALTER TABLE academic.academic_years ALTER COLUMN academic_year_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME academic.academic_years_academic_year_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: academic_years; Type: TABLE; Schema: config; Owner: -
--

CREATE TABLE config.academic_years (
    academic_year_id integer NOT NULL,
    tenant_id integer NOT NULL,
    name character varying(20) NOT NULL,
    created_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_by integer,
    updated_at timestamp without time zone,
    deleted_by integer,
    deleted_at timestamp without time zone,
    is_deleted boolean DEFAULT false NOT NULL
);


--
-- Name: academic_years_academic_year_id_seq; Type: SEQUENCE; Schema: config; Owner: -
--

ALTER TABLE config.academic_years ALTER COLUMN academic_year_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME config.academic_years_academic_year_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: address_types; Type: TABLE; Schema: config; Owner: -
--

CREATE TABLE config.address_types (
    address_type_id integer NOT NULL,
    tenant_id integer NOT NULL,
    name character varying(50) NOT NULL,
    created_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_by integer,
    updated_at timestamp without time zone,
    deleted_by integer,
    deleted_at timestamp without time zone,
    is_deleted boolean DEFAULT false NOT NULL
);


--
-- Name: address_types_address_type_id_seq; Type: SEQUENCE; Schema: config; Owner: -
--

ALTER TABLE config.address_types ALTER COLUMN address_type_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME config.address_types_address_type_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: boards; Type: TABLE; Schema: config; Owner: -
--

CREATE TABLE config.boards (
    board_id integer NOT NULL,
    tenant_id integer NOT NULL,
    name character varying(100) NOT NULL,
    created_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_by integer,
    updated_at timestamp without time zone,
    deleted_by integer,
    deleted_at timestamp without time zone,
    is_deleted boolean DEFAULT false NOT NULL
);


--
-- Name: boards_board_id_seq; Type: SEQUENCE; Schema: config; Owner: -
--

ALTER TABLE config.boards ALTER COLUMN board_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME config.boards_board_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: contact_types; Type: TABLE; Schema: config; Owner: -
--

CREATE TABLE config.contact_types (
    contact_type_id integer NOT NULL,
    tenant_id integer NOT NULL,
    name character varying(50) NOT NULL,
    created_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_by integer,
    updated_at timestamp without time zone,
    deleted_by integer,
    deleted_at timestamp without time zone,
    is_deleted boolean DEFAULT false NOT NULL
);


--
-- Name: contact_types_contact_type_id_seq; Type: SEQUENCE; Schema: config; Owner: -
--

ALTER TABLE config.contact_types ALTER COLUMN contact_type_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME config.contact_types_contact_type_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: date_formats; Type: TABLE; Schema: config; Owner: -
--

CREATE TABLE config.date_formats (
    date_format_id integer NOT NULL,
    tenant_id integer NOT NULL,
    format_value character varying(20) NOT NULL,
    created_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_by integer,
    updated_at timestamp without time zone,
    deleted_by integer,
    deleted_at timestamp without time zone,
    is_deleted boolean DEFAULT false NOT NULL
);


--
-- Name: date_formats_date_format_id_seq; Type: SEQUENCE; Schema: config; Owner: -
--

ALTER TABLE config.date_formats ALTER COLUMN date_format_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME config.date_formats_date_format_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: document_types; Type: TABLE; Schema: config; Owner: -
--

CREATE TABLE config.document_types (
    document_type_id integer NOT NULL,
    tenant_id integer NOT NULL,
    name character varying(100) NOT NULL,
    created_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_by integer,
    updated_at timestamp without time zone,
    deleted_by integer,
    deleted_at timestamp without time zone,
    is_deleted boolean DEFAULT false NOT NULL
);


--
-- Name: document_types_document_type_id_seq; Type: SEQUENCE; Schema: config; Owner: -
--

ALTER TABLE config.document_types ALTER COLUMN document_type_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME config.document_types_document_type_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: mediums; Type: TABLE; Schema: config; Owner: -
--

CREATE TABLE config.mediums (
    medium_id integer NOT NULL,
    tenant_id integer NOT NULL,
    name character varying(50) NOT NULL,
    created_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_by integer,
    updated_at timestamp without time zone,
    deleted_by integer,
    deleted_at timestamp without time zone,
    is_deleted boolean DEFAULT false NOT NULL
);


--
-- Name: mediums_medium_id_seq; Type: SEQUENCE; Schema: config; Owner: -
--

ALTER TABLE config.mediums ALTER COLUMN medium_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME config.mediums_medium_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: ownership_types; Type: TABLE; Schema: config; Owner: -
--

CREATE TABLE config.ownership_types (
    ownership_type_id integer NOT NULL,
    tenant_id integer NOT NULL,
    name character varying(100) NOT NULL,
    created_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_by integer,
    updated_at timestamp without time zone,
    deleted_by integer,
    deleted_at timestamp without time zone,
    is_deleted boolean DEFAULT false NOT NULL
);


--
-- Name: ownership_types_ownership_type_id_seq; Type: SEQUENCE; Schema: config; Owner: -
--

ALTER TABLE config.ownership_types ALTER COLUMN ownership_type_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME config.ownership_types_ownership_type_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: role_permissions; Type: TABLE; Schema: config; Owner: -
--

CREATE TABLE config.role_permissions (
    role_permission_id integer NOT NULL,
    tenant_id integer,
    school_id integer,
    role_id integer NOT NULL,
    permission_id integer NOT NULL,
    is_allowed boolean DEFAULT true NOT NULL,
    created_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_by integer,
    updated_at timestamp without time zone,
    deleted_by integer,
    deleted_at timestamp without time zone,
    is_deleted boolean DEFAULT false NOT NULL
);


--
-- Name: role_permissions_role_permission_id_seq; Type: SEQUENCE; Schema: config; Owner: -
--

ALTER TABLE config.role_permissions ALTER COLUMN role_permission_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME config.role_permissions_role_permission_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: roles; Type: TABLE; Schema: config; Owner: -
--

CREATE TABLE config.roles (
    role_id integer NOT NULL,
    tenant_id integer,
    role_name character varying(50) NOT NULL,
    description text,
    is_active boolean DEFAULT true NOT NULL,
    created_by integer,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_by integer,
    updated_at timestamp without time zone,
    deleted_by integer,
    deleted_at timestamp without time zone,
    is_deleted boolean DEFAULT false NOT NULL,
    school_id integer,
    role_code character varying(100) NOT NULL
);


--
-- Name: roles_role_id_seq; Type: SEQUENCE; Schema: config; Owner: -
--

ALTER TABLE config.roles ALTER COLUMN role_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME config.roles_role_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: school_statuses; Type: TABLE; Schema: config; Owner: -
--

CREATE TABLE config.school_statuses (
    school_status_id integer NOT NULL,
    tenant_id integer,
    name character varying(50) NOT NULL,
    created_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_by integer,
    updated_at timestamp without time zone,
    deleted_by integer,
    deleted_at timestamp without time zone,
    is_deleted boolean DEFAULT false NOT NULL
);


--
-- Name: school_statuses_school_status_id_seq; Type: SEQUENCE; Schema: config; Owner: -
--

ALTER TABLE config.school_statuses ALTER COLUMN school_status_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME config.school_statuses_school_status_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: school_types; Type: TABLE; Schema: config; Owner: -
--

CREATE TABLE config.school_types (
    school_type_id integer NOT NULL,
    tenant_id integer NOT NULL,
    name character varying(100) NOT NULL,
    created_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_by integer,
    updated_at timestamp without time zone,
    deleted_by integer,
    deleted_at timestamp without time zone,
    is_deleted boolean DEFAULT false NOT NULL
);


--
-- Name: school_types_school_type_id_seq; Type: SEQUENCE; Schema: config; Owner: -
--

ALTER TABLE config.school_types ALTER COLUMN school_type_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME config.school_types_school_type_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: time_formats; Type: TABLE; Schema: config; Owner: -
--

CREATE TABLE config.time_formats (
    time_format_id integer NOT NULL,
    tenant_id integer NOT NULL,
    format_value character varying(20) NOT NULL,
    created_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_by integer,
    updated_at timestamp without time zone,
    deleted_by integer,
    deleted_at timestamp without time zone,
    is_deleted boolean DEFAULT false NOT NULL
);


--
-- Name: time_formats_time_format_id_seq; Type: SEQUENCE; Schema: config; Owner: -
--

ALTER TABLE config.time_formats ALTER COLUMN time_format_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME config.time_formats_time_format_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: admin_activity_logs; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.admin_activity_logs (
    admin_activity_log_id integer NOT NULL,
    tenant_id integer NOT NULL,
    user_id integer,
    school_id integer,
    action character varying(100) NOT NULL,
    module_name character varying(100),
    table_name character varying(100),
    record_id integer,
    description text,
    ip_address character varying(100),
    user_agent text,
    created_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_by integer,
    updated_at timestamp without time zone,
    deleted_by integer,
    deleted_at timestamp without time zone,
    is_deleted boolean DEFAULT false NOT NULL
);


--
-- Name: admin_activity_logs_admin_activity_log_id_seq; Type: SEQUENCE; Schema: core; Owner: -
--

ALTER TABLE core.admin_activity_logs ALTER COLUMN admin_activity_log_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME core.admin_activity_logs_admin_activity_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: admission_audit; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.admission_audit (
    audit_id integer NOT NULL,
    tenant_id integer NOT NULL,
    school_id integer NOT NULL,
    student_id integer,
    action character varying(50) NOT NULL,
    detail text,
    action_by integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: admission_audit_audit_id_seq; Type: SEQUENCE; Schema: core; Owner: -
--

CREATE SEQUENCE core.admission_audit_audit_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: admission_audit_audit_id_seq; Type: SEQUENCE OWNED BY; Schema: core; Owner: -
--

ALTER SEQUENCE core.admission_audit_audit_id_seq OWNED BY core.admission_audit.audit_id;


--
-- Name: admission_counters; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.admission_counters (
    tenant_id integer NOT NULL,
    school_id integer NOT NULL,
    academic_year character varying(20) NOT NULL,
    last_seq integer DEFAULT 0 NOT NULL
);


--
-- Name: enquiries; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.enquiries (
    enquiry_id integer NOT NULL,
    tenant_id integer NOT NULL,
    school_id integer NOT NULL,
    student_name character varying(150) NOT NULL,
    gender character varying(10),
    dob date,
    class_name character varying(50) NOT NULL,
    session character varying(20) NOT NULL,
    interested_stream character varying(50),
    parent_name character varying(150),
    father_name character varying(150),
    father_mobile character varying(15),
    mother_name character varying(150),
    mother_mobile character varying(15),
    mobile character varying(15) NOT NULL,
    alt_mobile character varying(15),
    city character varying(100),
    area_locality character varying(100),
    lead_source character varying(50) DEFAULT 'Walk-in'::character varying NOT NULL,
    referrer_name character varying(150),
    referrer_mobile character varying(15),
    priority character varying(10) DEFAULT 'Warm'::character varying NOT NULL,
    status character varying(60) DEFAULT 'New'::character varying NOT NULL,
    assigned_to_id integer,
    lost_reason character varying(150),
    lost_to_school character varying(150),
    enquiry_date date DEFAULT CURRENT_DATE NOT NULL,
    next_followup_date date,
    notes text,
    estimated_fee numeric(12,2),
    registration_number character varying(50),
    registration_date date,
    registration_fee_paid boolean DEFAULT false NOT NULL,
    admission_id integer,
    is_active boolean DEFAULT true NOT NULL,
    created_by integer DEFAULT 0 NOT NULL,
    updated_by integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    parent_email character varying(150),
    current_class character varying(20),
    current_school character varying(200),
    transport_required boolean DEFAULT false NOT NULL,
    whatsapp_number character varying(15)
);


--
-- Name: enquiries_enquiry_id_seq; Type: SEQUENCE; Schema: core; Owner: -
--

CREATE SEQUENCE core.enquiries_enquiry_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: enquiries_enquiry_id_seq; Type: SEQUENCE OWNED BY; Schema: core; Owner: -
--

ALTER SEQUENCE core.enquiries_enquiry_id_seq OWNED BY core.enquiries.enquiry_id;


--
-- Name: enquiry_followups; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.enquiry_followups (
    followup_id integer NOT NULL,
    enquiry_id integer NOT NULL,
    tenant_id integer NOT NULL,
    school_id integer NOT NULL,
    followup_date timestamp with time zone DEFAULT now() NOT NULL,
    followup_type character varying(20) DEFAULT 'Call'::character varying NOT NULL,
    outcome character varying(50),
    notes text,
    next_followup_date date,
    status_before character varying(60),
    status_after character varying(60),
    created_by integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: enquiry_followups_followup_id_seq; Type: SEQUENCE; Schema: core; Owner: -
--

CREATE SEQUENCE core.enquiry_followups_followup_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: enquiry_followups_followup_id_seq; Type: SEQUENCE OWNED BY; Schema: core; Owner: -
--

ALTER SEQUENCE core.enquiry_followups_followup_id_seq OWNED BY core.enquiry_followups.followup_id;


--
-- Name: enquiry_status_history; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.enquiry_status_history (
    history_id integer NOT NULL,
    enquiry_id integer NOT NULL,
    tenant_id integer NOT NULL,
    school_id integer NOT NULL,
    status_from character varying(60),
    status_to character varying(60) NOT NULL,
    change_note text,
    changed_by integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: enquiry_status_history_history_id_seq; Type: SEQUENCE; Schema: core; Owner: -
--

CREATE SEQUENCE core.enquiry_status_history_history_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: enquiry_status_history_history_id_seq; Type: SEQUENCE OWNED BY; Schema: core; Owner: -
--

ALTER SEQUENCE core.enquiry_status_history_history_id_seq OWNED BY core.enquiry_status_history.history_id;


--
-- Name: login_attempts; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.login_attempts (
    login_attempt_id integer NOT NULL,
    tenant_id integer,
    user_id integer,
    school_id integer,
    email character varying(150) NOT NULL,
    ip_address character varying(100),
    user_agent text,
    is_success boolean NOT NULL,
    failure_reason character varying(200),
    created_by integer,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_by integer,
    updated_at timestamp without time zone,
    deleted_by integer,
    deleted_at timestamp without time zone,
    is_deleted boolean DEFAULT false NOT NULL
);


--
-- Name: login_attempts_login_attempt_id_seq; Type: SEQUENCE; Schema: core; Owner: -
--

ALTER TABLE core.login_attempts ALTER COLUMN login_attempt_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME core.login_attempts_login_attempt_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: password_reset_tokens; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.password_reset_tokens (
    password_reset_token_id integer NOT NULL,
    tenant_id integer NOT NULL,
    user_id integer NOT NULL,
    school_id integer,
    token_hash text NOT NULL,
    expires_at timestamp without time zone NOT NULL,
    used_at timestamp without time zone,
    created_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_by integer,
    updated_at timestamp without time zone,
    deleted_by integer,
    deleted_at timestamp without time zone,
    is_deleted boolean DEFAULT false NOT NULL
);


--
-- Name: password_reset_tokens_password_reset_token_id_seq; Type: SEQUENCE; Schema: core; Owner: -
--

ALTER TABLE core.password_reset_tokens ALTER COLUMN password_reset_token_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME core.password_reset_tokens_password_reset_token_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: school_addresses; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.school_addresses (
    school_address_id integer NOT NULL,
    tenant_id integer NOT NULL,
    school_id integer NOT NULL,
    address_type_id integer NOT NULL,
    address_line1 character varying(250) NOT NULL,
    address_line2 character varying(250),
    city character varying(100) NOT NULL,
    district character varying(100),
    state character varying(100) NOT NULL,
    pincode character varying(20) NOT NULL,
    latitude numeric(10,7),
    longitude numeric(10,7),
    is_primary boolean DEFAULT true NOT NULL,
    created_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_by integer,
    updated_at timestamp without time zone,
    deleted_by integer,
    deleted_at timestamp without time zone,
    is_deleted boolean DEFAULT false NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    CONSTRAINT chk_pincode CHECK (((pincode)::text ~ '^[0-9]{6}$'::text)),
    CONSTRAINT chk_school_addresses_scope CHECK (((tenant_id > 1) AND (school_id > 0)))
);


--
-- Name: school_addresses_school_address_id_seq; Type: SEQUENCE; Schema: core; Owner: -
--

ALTER TABLE core.school_addresses ALTER COLUMN school_address_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME core.school_addresses_school_address_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: school_contacts; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.school_contacts (
    school_contact_id integer NOT NULL,
    tenant_id integer NOT NULL,
    school_id integer NOT NULL,
    contact_type_id integer NOT NULL,
    contact_name character varying(150) NOT NULL,
    designation character varying(100),
    email character varying(150),
    phone character varying(30) NOT NULL,
    alternate_phone character varying(30),
    is_primary boolean DEFAULT true NOT NULL,
    created_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_by integer,
    updated_at timestamp without time zone,
    deleted_by integer,
    deleted_at timestamp without time zone,
    is_deleted boolean DEFAULT false NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    CONSTRAINT chk_school_contacts_scope CHECK (((tenant_id > 1) AND (school_id > 0)))
);


--
-- Name: school_contacts_school_contact_id_seq; Type: SEQUENCE; Schema: core; Owner: -
--

ALTER TABLE core.school_contacts ALTER COLUMN school_contact_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME core.school_contacts_school_contact_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: school_documents; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.school_documents (
    school_document_id integer NOT NULL,
    tenant_id integer NOT NULL,
    school_id integer NOT NULL,
    document_type_id integer NOT NULL,
    document_name character varying(200),
    file_name character varying(250) NOT NULL,
    file_path text NOT NULL,
    file_size bigint,
    file_extension character varying(20),
    file_mime_type character varying(100),
    uploaded_by integer,
    uploaded_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    is_verified boolean DEFAULT false NOT NULL,
    verified_by integer,
    verified_at timestamp without time zone,
    created_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_by integer,
    updated_at timestamp without time zone,
    deleted_by integer,
    deleted_at timestamp without time zone,
    is_deleted boolean DEFAULT false NOT NULL,
    CONSTRAINT chk_school_documents_scope CHECK (((tenant_id > 1) AND (school_id > 0)))
);


--
-- Name: school_documents_school_document_id_seq; Type: SEQUENCE; Schema: core; Owner: -
--

ALTER TABLE core.school_documents ALTER COLUMN school_document_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME core.school_documents_school_document_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: school_fee_heads; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.school_fee_heads (
    fee_head_id integer NOT NULL,
    tenant_id integer NOT NULL,
    school_id integer NOT NULL,
    fee_head_name character varying(80) NOT NULL,
    frequency character varying(30) NOT NULL,
    default_amount numeric(12,2) DEFAULT 0,
    fee_type character varying(30) NOT NULL,
    fee_group character varying(50) DEFAULT 'Academic'::character varying,
    display_order integer DEFAULT 0,
    is_active boolean DEFAULT true,
    is_deleted boolean DEFAULT false,
    created_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT now(),
    updated_by integer,
    updated_at timestamp without time zone
);


--
-- Name: school_fee_heads_fee_head_id_seq; Type: SEQUENCE; Schema: core; Owner: -
--

CREATE SEQUENCE core.school_fee_heads_fee_head_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: school_fee_heads_fee_head_id_seq; Type: SEQUENCE OWNED BY; Schema: core; Owner: -
--

ALTER SEQUENCE core.school_fee_heads_fee_head_id_seq OWNED BY core.school_fee_heads.fee_head_id;


--
-- Name: school_fee_structure_details; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.school_fee_structure_details (
    fee_structure_detail_id integer NOT NULL,
    tenant_id integer NOT NULL,
    school_id integer NOT NULL,
    fee_structure_id integer NOT NULL,
    fee_head_id integer NOT NULL,
    fee_head_name character varying(80) NOT NULL,
    frequency character varying(30) NOT NULL,
    amount numeric(12,2) DEFAULT 0,
    is_selected boolean DEFAULT true,
    is_deleted boolean DEFAULT false,
    created_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT now(),
    updated_by integer,
    updated_at timestamp without time zone
);


--
-- Name: school_fee_structure_details_fee_structure_detail_id_seq; Type: SEQUENCE; Schema: core; Owner: -
--

CREATE SEQUENCE core.school_fee_structure_details_fee_structure_detail_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: school_fee_structure_details_fee_structure_detail_id_seq; Type: SEQUENCE OWNED BY; Schema: core; Owner: -
--

ALTER SEQUENCE core.school_fee_structure_details_fee_structure_detail_id_seq OWNED BY core.school_fee_structure_details.fee_structure_detail_id;


--
-- Name: school_fee_structures; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.school_fee_structures (
    fee_structure_id integer NOT NULL,
    tenant_id integer NOT NULL,
    school_id integer NOT NULL,
    class_name character varying(30) NOT NULL,
    academic_year character varying(20) NOT NULL,
    one_time_total numeric(12,2) DEFAULT 0,
    monthly_total numeric(12,2) DEFAULT 0,
    yearly_total numeric(12,2) DEFAULT 0,
    annual_total numeric(12,2) DEFAULT 0,
    is_active boolean DEFAULT true,
    is_deleted boolean DEFAULT false,
    created_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT now(),
    updated_by integer,
    updated_at timestamp without time zone
);


--
-- Name: school_fee_structures_fee_structure_id_seq; Type: SEQUENCE; Schema: core; Owner: -
--

CREATE SEQUENCE core.school_fee_structures_fee_structure_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: school_fee_structures_fee_structure_id_seq; Type: SEQUENCE OWNED BY; Schema: core; Owner: -
--

ALTER SEQUENCE core.school_fee_structures_fee_structure_id_seq OWNED BY core.school_fee_structures.fee_structure_id;


--
-- Name: school_profiles; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.school_profiles (
    school_profile_id integer NOT NULL,
    tenant_id integer NOT NULL,
    school_id integer NOT NULL,
    registration_number character varying(100),
    affiliation_number character varying(100),
    board_id integer,
    school_type_id integer,
    ownership_type_id integer,
    medium_id integer,
    established_year integer,
    website character varying(200),
    logo_url text,
    description text,
    created_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_by integer,
    updated_at timestamp without time zone,
    deleted_by integer,
    deleted_at timestamp without time zone,
    is_deleted boolean DEFAULT false NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    header_image_url character varying(500),
    CONSTRAINT chk_established_year CHECK (((established_year IS NULL) OR ((established_year >= 1800) AND (established_year <= 2100)))),
    CONSTRAINT chk_school_profiles_scope CHECK (((tenant_id > 1) AND (school_id > 0)))
);


--
-- Name: school_profiles_school_profile_id_seq; Type: SEQUENCE; Schema: core; Owner: -
--

ALTER TABLE core.school_profiles ALTER COLUMN school_profile_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME core.school_profiles_school_profile_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: school_settings; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.school_settings (
    school_setting_id integer NOT NULL,
    tenant_id integer NOT NULL,
    school_id integer NOT NULL,
    academic_year_id integer,
    date_format_id integer,
    time_format_id integer,
    timezone character varying(100) DEFAULT 'Asia/Kolkata'::character varying NOT NULL,
    currency character varying(10) DEFAULT 'INR'::character varying NOT NULL,
    default_language character varying(50) DEFAULT 'English'::character varying NOT NULL,
    enable_sms boolean DEFAULT false NOT NULL,
    enable_email boolean DEFAULT true NOT NULL,
    enable_whatsapp boolean DEFAULT false NOT NULL,
    created_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_by integer,
    updated_at timestamp without time zone,
    deleted_by integer,
    deleted_at timestamp without time zone,
    is_deleted boolean DEFAULT false NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    CONSTRAINT chk_school_settings_scope CHECK (((tenant_id > 1) AND (school_id > 0)))
);


--
-- Name: school_settings_school_setting_id_seq; Type: SEQUENCE; Schema: core; Owner: -
--

ALTER TABLE core.school_settings ALTER COLUMN school_setting_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME core.school_settings_school_setting_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: school_working_hours; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.school_working_hours (
    school_working_hour_id integer NOT NULL,
    tenant_id integer NOT NULL,
    school_id integer NOT NULL,
    reporting_time time without time zone NOT NULL,
    departure_time time without time zone NOT NULL,
    late_grace_minutes integer DEFAULT 0 NOT NULL,
    created_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_by integer,
    updated_at timestamp without time zone,
    deleted_by integer,
    deleted_at timestamp without time zone,
    is_deleted boolean DEFAULT false NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    CONSTRAINT chk_late_grace_minutes CHECK ((late_grace_minutes >= 0)),
    CONSTRAINT chk_school_working_hours_scope CHECK (((tenant_id > 1) AND (school_id > 0))),
    CONSTRAINT chk_working_hours_time CHECK ((departure_time > reporting_time))
);


--
-- Name: school_working_hours_school_working_hour_id_seq; Type: SEQUENCE; Schema: core; Owner: -
--

ALTER TABLE core.school_working_hours ALTER COLUMN school_working_hour_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME core.school_working_hours_school_working_hour_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: schools; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.schools (
    school_id integer NOT NULL,
    tenant_id integer NOT NULL,
    school_code character varying(50),
    school_name character varying(200) NOT NULL,
    display_name character varying(200),
    status_id integer NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_by integer NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_by integer,
    updated_at timestamp without time zone,
    deleted_by integer,
    deleted_at timestamp without time zone,
    is_deleted boolean DEFAULT false NOT NULL
);


--
-- Name: schools_school_id_seq; Type: SEQUENCE; Schema: core; Owner: -
--

ALTER TABLE core.schools ALTER COLUMN school_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME core.schools_school_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: student_fee_plan; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.student_fee_plan (
    fee_plan_id integer NOT NULL,
    tenant_id integer NOT NULL,
    school_id integer NOT NULL,
    student_id integer NOT NULL,
    fee_head_id integer,
    fee_head_name character varying(100) NOT NULL,
    frequency character varying(20) NOT NULL,
    amount numeric(12,2) DEFAULT 0 NOT NULL,
    is_optional boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: student_fee_plan_fee_plan_id_seq; Type: SEQUENCE; Schema: core; Owner: -
--

CREATE SEQUENCE core.student_fee_plan_fee_plan_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: student_fee_plan_fee_plan_id_seq; Type: SEQUENCE OWNED BY; Schema: core; Owner: -
--

ALTER SEQUENCE core.student_fee_plan_fee_plan_id_seq OWNED BY core.student_fee_plan.fee_plan_id;


--
-- Name: student_ledger; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.student_ledger (
    ledger_id integer NOT NULL,
    tenant_id integer NOT NULL,
    school_id integer NOT NULL,
    student_id integer NOT NULL,
    fee_head_name character varying(100) NOT NULL,
    frequency character varying(20) NOT NULL,
    installment_label character varying(40),
    due_date date,
    amount_due numeric(12,2) DEFAULT 0 NOT NULL,
    amount_paid numeric(12,2) DEFAULT 0 NOT NULL,
    status character varying(20) DEFAULT 'Pending'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: student_ledger_ledger_id_seq; Type: SEQUENCE; Schema: core; Owner: -
--

CREATE SEQUENCE core.student_ledger_ledger_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: student_ledger_ledger_id_seq; Type: SEQUENCE OWNED BY; Schema: core; Owner: -
--

ALTER SEQUENCE core.student_ledger_ledger_id_seq OWNED BY core.student_ledger.ledger_id;


--
-- Name: students; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.students (
    student_id integer NOT NULL,
    tenant_id integer NOT NULL,
    school_id integer NOT NULL,
    admission_no character varying(50) NOT NULL,
    roll_no character varying(50),
    student_name character varying(150) NOT NULL,
    gender character varying(10),
    dob date,
    class_name character varying(50) NOT NULL,
    section character varying(20),
    academic_year character varying(20) NOT NULL,
    admission_date date DEFAULT CURRENT_DATE NOT NULL,
    guardian_name character varying(150),
    mother_name character varying(150),
    mobile character varying(15),
    alt_mobile character varying(15),
    address text,
    pay_today_total numeric(12,2) DEFAULT 0 NOT NULL,
    monthly_total numeric(12,2) DEFAULT 0 NOT NULL,
    yearly_total numeric(12,2) DEFAULT 0 NOT NULL,
    annual_total numeric(12,2) DEFAULT 0 NOT NULL,
    concession_type character varying(20),
    concession_value numeric(12,2) DEFAULT 0 NOT NULL,
    concession_amount numeric(12,2) DEFAULT 0 NOT NULL,
    concession_reason character varying(250),
    enquiry_id integer,
    status character varying(30) DEFAULT 'Active'::character varying NOT NULL,
    approval_status character varying(20) DEFAULT 'Approved'::character varying NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_by integer DEFAULT 0 NOT NULL,
    updated_by integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: students_student_id_seq; Type: SEQUENCE; Schema: core; Owner: -
--

CREATE SEQUENCE core.students_student_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: students_student_id_seq; Type: SEQUENCE OWNED BY; Schema: core; Owner: -
--

ALTER SEQUENCE core.students_student_id_seq OWNED BY core.students.student_id;


--
-- Name: tenants; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.tenants (
    tenant_id integer NOT NULL,
    tenant_name character varying(150) NOT NULL,
    tenant_code character varying(50),
    contact_email character varying(150),
    contact_phone character varying(20),
    is_active boolean DEFAULT true NOT NULL,
    created_by integer,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_by integer,
    updated_at timestamp without time zone,
    deleted_by integer,
    deleted_at timestamp without time zone,
    is_deleted boolean DEFAULT false NOT NULL
);


--
-- Name: tenants_tenant_id_seq; Type: SEQUENCE; Schema: core; Owner: -
--

ALTER TABLE core.tenants ALTER COLUMN tenant_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME core.tenants_tenant_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: user_profiles; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.user_profiles (
    user_profile_id integer NOT NULL,
    tenant_id integer,
    user_id integer NOT NULL,
    school_id integer,
    full_name character varying(150) NOT NULL,
    phone character varying(30),
    alternate_phone character varying(30),
    profile_photo_url text,
    designation character varying(100),
    created_by integer,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_by integer,
    updated_at timestamp without time zone,
    deleted_by integer,
    deleted_at timestamp without time zone,
    is_deleted boolean DEFAULT false NOT NULL,
    is_active boolean DEFAULT true NOT NULL
);


--
-- Name: user_profiles_user_profile_id_seq; Type: SEQUENCE; Schema: core; Owner: -
--

ALTER TABLE core.user_profiles ALTER COLUMN user_profile_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME core.user_profiles_user_profile_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: user_roles; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.user_roles (
    user_role_id integer NOT NULL,
    tenant_id integer,
    user_id integer NOT NULL,
    role_id integer NOT NULL,
    school_id integer,
    created_by integer,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_by integer,
    updated_at timestamp without time zone,
    deleted_by integer,
    deleted_at timestamp without time zone,
    is_deleted boolean DEFAULT false NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    is_primary boolean DEFAULT true NOT NULL
);


--
-- Name: user_roles_user_role_id_seq; Type: SEQUENCE; Schema: core; Owner: -
--

ALTER TABLE core.user_roles ALTER COLUMN user_role_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME core.user_roles_user_role_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: user_sessions; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.user_sessions (
    user_session_id integer NOT NULL,
    tenant_id integer,
    user_id integer NOT NULL,
    school_id integer,
    refresh_token_hash text,
    ip_address character varying(100),
    user_agent text,
    login_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    logout_at timestamp without time zone,
    expires_at timestamp without time zone,
    is_active boolean DEFAULT true NOT NULL,
    created_by integer,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_by integer,
    updated_at timestamp without time zone,
    deleted_by integer,
    deleted_at timestamp without time zone,
    is_deleted boolean DEFAULT false NOT NULL
);


--
-- Name: user_sessions_user_session_id_seq; Type: SEQUENCE; Schema: core; Owner: -
--

ALTER TABLE core.user_sessions ALTER COLUMN user_session_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME core.user_sessions_user_session_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: users; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.users (
    user_id integer NOT NULL,
    tenant_id integer,
    school_id integer,
    email character varying(150) NOT NULL,
    password_hash text NOT NULL,
    is_email_verified boolean DEFAULT false NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    last_login_at timestamp without time zone,
    created_by integer,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_by integer,
    updated_at timestamp without time zone,
    deleted_by integer,
    deleted_at timestamp without time zone,
    is_deleted boolean DEFAULT false NOT NULL
);


--
-- Name: users_user_id_seq; Type: SEQUENCE; Schema: core; Owner: -
--

ALTER TABLE core.users ALTER COLUMN user_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME core.users_user_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: admission_audit audit_id; Type: DEFAULT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.admission_audit ALTER COLUMN audit_id SET DEFAULT nextval('core.admission_audit_audit_id_seq'::regclass);


--
-- Name: enquiries enquiry_id; Type: DEFAULT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.enquiries ALTER COLUMN enquiry_id SET DEFAULT nextval('core.enquiries_enquiry_id_seq'::regclass);


--
-- Name: enquiry_followups followup_id; Type: DEFAULT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.enquiry_followups ALTER COLUMN followup_id SET DEFAULT nextval('core.enquiry_followups_followup_id_seq'::regclass);


--
-- Name: enquiry_status_history history_id; Type: DEFAULT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.enquiry_status_history ALTER COLUMN history_id SET DEFAULT nextval('core.enquiry_status_history_history_id_seq'::regclass);


--
-- Name: school_fee_heads fee_head_id; Type: DEFAULT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.school_fee_heads ALTER COLUMN fee_head_id SET DEFAULT nextval('core.school_fee_heads_fee_head_id_seq'::regclass);


--
-- Name: school_fee_structure_details fee_structure_detail_id; Type: DEFAULT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.school_fee_structure_details ALTER COLUMN fee_structure_detail_id SET DEFAULT nextval('core.school_fee_structure_details_fee_structure_detail_id_seq'::regclass);


--
-- Name: school_fee_structures fee_structure_id; Type: DEFAULT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.school_fee_structures ALTER COLUMN fee_structure_id SET DEFAULT nextval('core.school_fee_structures_fee_structure_id_seq'::regclass);


--
-- Name: student_fee_plan fee_plan_id; Type: DEFAULT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.student_fee_plan ALTER COLUMN fee_plan_id SET DEFAULT nextval('core.student_fee_plan_fee_plan_id_seq'::regclass);


--
-- Name: student_ledger ledger_id; Type: DEFAULT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.student_ledger ALTER COLUMN ledger_id SET DEFAULT nextval('core.student_ledger_ledger_id_seq'::regclass);


--
-- Name: students student_id; Type: DEFAULT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.students ALTER COLUMN student_id SET DEFAULT nextval('core.students_student_id_seq'::regclass);


--
-- Name: academic_class_sections academic_class_sections_pkey; Type: CONSTRAINT; Schema: academic; Owner: -
--

ALTER TABLE ONLY academic.academic_class_sections
    ADD CONSTRAINT academic_class_sections_pkey PRIMARY KEY (academic_class_section_id);


--
-- Name: academic_classes academic_classes_pkey; Type: CONSTRAINT; Schema: academic; Owner: -
--

ALTER TABLE ONLY academic.academic_classes
    ADD CONSTRAINT academic_classes_pkey PRIMARY KEY (academic_class_id);


--
-- Name: academic_years academic_years_pkey; Type: CONSTRAINT; Schema: academic; Owner: -
--

ALTER TABLE ONLY academic.academic_years
    ADD CONSTRAINT academic_years_pkey PRIMARY KEY (academic_year_id);


--
-- Name: academic_years uq_academic_year; Type: CONSTRAINT; Schema: academic; Owner: -
--

ALTER TABLE ONLY academic.academic_years
    ADD CONSTRAINT uq_academic_year UNIQUE (tenant_id, school_id, academic_year_name);


--
-- Name: academic_years academic_years_pkey; Type: CONSTRAINT; Schema: config; Owner: -
--

ALTER TABLE ONLY config.academic_years
    ADD CONSTRAINT academic_years_pkey PRIMARY KEY (academic_year_id);


--
-- Name: address_types address_types_pkey; Type: CONSTRAINT; Schema: config; Owner: -
--

ALTER TABLE ONLY config.address_types
    ADD CONSTRAINT address_types_pkey PRIMARY KEY (address_type_id);


--
-- Name: boards boards_pkey; Type: CONSTRAINT; Schema: config; Owner: -
--

ALTER TABLE ONLY config.boards
    ADD CONSTRAINT boards_pkey PRIMARY KEY (board_id);


--
-- Name: contact_types contact_types_pkey; Type: CONSTRAINT; Schema: config; Owner: -
--

ALTER TABLE ONLY config.contact_types
    ADD CONSTRAINT contact_types_pkey PRIMARY KEY (contact_type_id);


--
-- Name: date_formats date_formats_pkey; Type: CONSTRAINT; Schema: config; Owner: -
--

ALTER TABLE ONLY config.date_formats
    ADD CONSTRAINT date_formats_pkey PRIMARY KEY (date_format_id);


--
-- Name: document_types document_types_pkey; Type: CONSTRAINT; Schema: config; Owner: -
--

ALTER TABLE ONLY config.document_types
    ADD CONSTRAINT document_types_pkey PRIMARY KEY (document_type_id);


--
-- Name: mediums mediums_pkey; Type: CONSTRAINT; Schema: config; Owner: -
--

ALTER TABLE ONLY config.mediums
    ADD CONSTRAINT mediums_pkey PRIMARY KEY (medium_id);


--
-- Name: ownership_types ownership_types_pkey; Type: CONSTRAINT; Schema: config; Owner: -
--

ALTER TABLE ONLY config.ownership_types
    ADD CONSTRAINT ownership_types_pkey PRIMARY KEY (ownership_type_id);


--
-- Name: role_permissions role_permissions_pkey; Type: CONSTRAINT; Schema: config; Owner: -
--

ALTER TABLE ONLY config.role_permissions
    ADD CONSTRAINT role_permissions_pkey PRIMARY KEY (role_permission_id);


--
-- Name: roles roles_pkey; Type: CONSTRAINT; Schema: config; Owner: -
--

ALTER TABLE ONLY config.roles
    ADD CONSTRAINT roles_pkey PRIMARY KEY (role_id);


--
-- Name: school_statuses school_statuses_pkey; Type: CONSTRAINT; Schema: config; Owner: -
--

ALTER TABLE ONLY config.school_statuses
    ADD CONSTRAINT school_statuses_pkey PRIMARY KEY (school_status_id);


--
-- Name: school_types school_types_pkey; Type: CONSTRAINT; Schema: config; Owner: -
--

ALTER TABLE ONLY config.school_types
    ADD CONSTRAINT school_types_pkey PRIMARY KEY (school_type_id);


--
-- Name: time_formats time_formats_pkey; Type: CONSTRAINT; Schema: config; Owner: -
--

ALTER TABLE ONLY config.time_formats
    ADD CONSTRAINT time_formats_pkey PRIMARY KEY (time_format_id);


--
-- Name: academic_years uq_academic_year_name; Type: CONSTRAINT; Schema: config; Owner: -
--

ALTER TABLE ONLY config.academic_years
    ADD CONSTRAINT uq_academic_year_name UNIQUE (tenant_id, name);


--
-- Name: address_types uq_address_type_name; Type: CONSTRAINT; Schema: config; Owner: -
--

ALTER TABLE ONLY config.address_types
    ADD CONSTRAINT uq_address_type_name UNIQUE (tenant_id, name);


--
-- Name: boards uq_board_name; Type: CONSTRAINT; Schema: config; Owner: -
--

ALTER TABLE ONLY config.boards
    ADD CONSTRAINT uq_board_name UNIQUE (tenant_id, name);


--
-- Name: contact_types uq_contact_type_name; Type: CONSTRAINT; Schema: config; Owner: -
--

ALTER TABLE ONLY config.contact_types
    ADD CONSTRAINT uq_contact_type_name UNIQUE (tenant_id, name);


--
-- Name: date_formats uq_date_format_value; Type: CONSTRAINT; Schema: config; Owner: -
--

ALTER TABLE ONLY config.date_formats
    ADD CONSTRAINT uq_date_format_value UNIQUE (tenant_id, format_value);


--
-- Name: document_types uq_document_type_name; Type: CONSTRAINT; Schema: config; Owner: -
--

ALTER TABLE ONLY config.document_types
    ADD CONSTRAINT uq_document_type_name UNIQUE (tenant_id, name);


--
-- Name: mediums uq_medium_name; Type: CONSTRAINT; Schema: config; Owner: -
--

ALTER TABLE ONLY config.mediums
    ADD CONSTRAINT uq_medium_name UNIQUE (tenant_id, name);


--
-- Name: ownership_types uq_ownership_type_name; Type: CONSTRAINT; Schema: config; Owner: -
--

ALTER TABLE ONLY config.ownership_types
    ADD CONSTRAINT uq_ownership_type_name UNIQUE (tenant_id, name);


--
-- Name: school_statuses uq_school_status_name; Type: CONSTRAINT; Schema: config; Owner: -
--

ALTER TABLE ONLY config.school_statuses
    ADD CONSTRAINT uq_school_status_name UNIQUE (tenant_id, name);


--
-- Name: school_types uq_school_type_name; Type: CONSTRAINT; Schema: config; Owner: -
--

ALTER TABLE ONLY config.school_types
    ADD CONSTRAINT uq_school_type_name UNIQUE (tenant_id, name);


--
-- Name: time_formats uq_time_format_value; Type: CONSTRAINT; Schema: config; Owner: -
--

ALTER TABLE ONLY config.time_formats
    ADD CONSTRAINT uq_time_format_value UNIQUE (tenant_id, format_value);


--
-- Name: admin_activity_logs admin_activity_logs_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.admin_activity_logs
    ADD CONSTRAINT admin_activity_logs_pkey PRIMARY KEY (admin_activity_log_id);


--
-- Name: admission_audit admission_audit_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.admission_audit
    ADD CONSTRAINT admission_audit_pkey PRIMARY KEY (audit_id);


--
-- Name: enquiries enquiries_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.enquiries
    ADD CONSTRAINT enquiries_pkey PRIMARY KEY (enquiry_id);


--
-- Name: enquiry_followups enquiry_followups_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.enquiry_followups
    ADD CONSTRAINT enquiry_followups_pkey PRIMARY KEY (followup_id);


--
-- Name: enquiry_status_history enquiry_status_history_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.enquiry_status_history
    ADD CONSTRAINT enquiry_status_history_pkey PRIMARY KEY (history_id);


--
-- Name: login_attempts login_attempts_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.login_attempts
    ADD CONSTRAINT login_attempts_pkey PRIMARY KEY (login_attempt_id);


--
-- Name: password_reset_tokens password_reset_tokens_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.password_reset_tokens
    ADD CONSTRAINT password_reset_tokens_pkey PRIMARY KEY (password_reset_token_id);


--
-- Name: admission_counters pk_admission_counters; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.admission_counters
    ADD CONSTRAINT pk_admission_counters PRIMARY KEY (tenant_id, school_id, academic_year);


--
-- Name: school_addresses school_addresses_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.school_addresses
    ADD CONSTRAINT school_addresses_pkey PRIMARY KEY (school_address_id);


--
-- Name: school_contacts school_contacts_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.school_contacts
    ADD CONSTRAINT school_contacts_pkey PRIMARY KEY (school_contact_id);


--
-- Name: school_documents school_documents_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.school_documents
    ADD CONSTRAINT school_documents_pkey PRIMARY KEY (school_document_id);


--
-- Name: school_fee_heads school_fee_heads_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.school_fee_heads
    ADD CONSTRAINT school_fee_heads_pkey PRIMARY KEY (fee_head_id);


--
-- Name: school_fee_structure_details school_fee_structure_details_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.school_fee_structure_details
    ADD CONSTRAINT school_fee_structure_details_pkey PRIMARY KEY (fee_structure_detail_id);


--
-- Name: school_fee_structures school_fee_structures_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.school_fee_structures
    ADD CONSTRAINT school_fee_structures_pkey PRIMARY KEY (fee_structure_id);


--
-- Name: school_profiles school_profiles_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.school_profiles
    ADD CONSTRAINT school_profiles_pkey PRIMARY KEY (school_profile_id);


--
-- Name: school_settings school_settings_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.school_settings
    ADD CONSTRAINT school_settings_pkey PRIMARY KEY (school_setting_id);


--
-- Name: school_working_hours school_working_hours_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.school_working_hours
    ADD CONSTRAINT school_working_hours_pkey PRIMARY KEY (school_working_hour_id);


--
-- Name: schools schools_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.schools
    ADD CONSTRAINT schools_pkey PRIMARY KEY (school_id);


--
-- Name: student_fee_plan student_fee_plan_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.student_fee_plan
    ADD CONSTRAINT student_fee_plan_pkey PRIMARY KEY (fee_plan_id);


--
-- Name: student_ledger student_ledger_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.student_ledger
    ADD CONSTRAINT student_ledger_pkey PRIMARY KEY (ledger_id);


--
-- Name: students students_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.students
    ADD CONSTRAINT students_pkey PRIMARY KEY (student_id);


--
-- Name: tenants tenants_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.tenants
    ADD CONSTRAINT tenants_pkey PRIMARY KEY (tenant_id);


--
-- Name: tenants tenants_tenant_code_key; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.tenants
    ADD CONSTRAINT tenants_tenant_code_key UNIQUE (tenant_code);


--
-- Name: school_addresses uq_school_address; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.school_addresses
    ADD CONSTRAINT uq_school_address UNIQUE (tenant_id, school_id, address_type_id);


--
-- Name: schools uq_school_code; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.schools
    ADD CONSTRAINT uq_school_code UNIQUE (tenant_id, school_code);


--
-- Name: school_contacts uq_school_contact; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.school_contacts
    ADD CONSTRAINT uq_school_contact UNIQUE (tenant_id, school_id, contact_type_id);


--
-- Name: school_fee_heads uq_school_fee_heads_name; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.school_fee_heads
    ADD CONSTRAINT uq_school_fee_heads_name UNIQUE (tenant_id, school_id, fee_head_name);


--
-- Name: school_fee_structure_details uq_school_fee_structure_details_head; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.school_fee_structure_details
    ADD CONSTRAINT uq_school_fee_structure_details_head UNIQUE (tenant_id, school_id, fee_structure_id, fee_head_id);


--
-- Name: school_fee_structures uq_school_fee_structures_class_year; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.school_fee_structures
    ADD CONSTRAINT uq_school_fee_structures_class_year UNIQUE (tenant_id, school_id, class_name, academic_year);


--
-- Name: school_profiles uq_school_profile_school; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.school_profiles
    ADD CONSTRAINT uq_school_profile_school UNIQUE (tenant_id, school_id);


--
-- Name: school_settings uq_school_settings; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.school_settings
    ADD CONSTRAINT uq_school_settings UNIQUE (tenant_id, school_id);


--
-- Name: school_working_hours uq_school_working_hours; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.school_working_hours
    ADD CONSTRAINT uq_school_working_hours UNIQUE (tenant_id, school_id);


--
-- Name: students uq_student_admission_no; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.students
    ADD CONSTRAINT uq_student_admission_no UNIQUE (tenant_id, school_id, admission_no);


--
-- Name: users uq_user_email; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.users
    ADD CONSTRAINT uq_user_email UNIQUE (tenant_id, email);


--
-- Name: user_profiles uq_user_profile_user; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.user_profiles
    ADD CONSTRAINT uq_user_profile_user UNIQUE (tenant_id, user_id);


--
-- Name: user_roles uq_user_roles_tenant_user_role; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.user_roles
    ADD CONSTRAINT uq_user_roles_tenant_user_role UNIQUE (tenant_id, user_id, role_id);


--
-- Name: user_profiles user_profiles_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.user_profiles
    ADD CONSTRAINT user_profiles_pkey PRIMARY KEY (user_profile_id);


--
-- Name: user_roles user_roles_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.user_roles
    ADD CONSTRAINT user_roles_pkey PRIMARY KEY (user_role_id);


--
-- Name: user_sessions user_sessions_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.user_sessions
    ADD CONSTRAINT user_sessions_pkey PRIMARY KEY (user_session_id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (user_id);


--
-- Name: idx_academic_years_tenant; Type: INDEX; Schema: config; Owner: -
--

CREATE INDEX idx_academic_years_tenant ON config.academic_years USING btree (tenant_id);


--
-- Name: idx_address_types_tenant; Type: INDEX; Schema: config; Owner: -
--

CREATE INDEX idx_address_types_tenant ON config.address_types USING btree (tenant_id);


--
-- Name: idx_boards_tenant; Type: INDEX; Schema: config; Owner: -
--

CREATE INDEX idx_boards_tenant ON config.boards USING btree (tenant_id);


--
-- Name: idx_contact_types_tenant; Type: INDEX; Schema: config; Owner: -
--

CREATE INDEX idx_contact_types_tenant ON config.contact_types USING btree (tenant_id);


--
-- Name: idx_date_formats_tenant; Type: INDEX; Schema: config; Owner: -
--

CREATE INDEX idx_date_formats_tenant ON config.date_formats USING btree (tenant_id);


--
-- Name: idx_document_types_tenant; Type: INDEX; Schema: config; Owner: -
--

CREATE INDEX idx_document_types_tenant ON config.document_types USING btree (tenant_id);


--
-- Name: idx_mediums_tenant; Type: INDEX; Schema: config; Owner: -
--

CREATE INDEX idx_mediums_tenant ON config.mediums USING btree (tenant_id);


--
-- Name: idx_ownership_types_tenant; Type: INDEX; Schema: config; Owner: -
--

CREATE INDEX idx_ownership_types_tenant ON config.ownership_types USING btree (tenant_id);


--
-- Name: idx_role_permissions_permission; Type: INDEX; Schema: config; Owner: -
--

CREATE INDEX idx_role_permissions_permission ON config.role_permissions USING btree (tenant_id, permission_id, is_deleted);


--
-- Name: idx_role_permissions_role; Type: INDEX; Schema: config; Owner: -
--

CREATE INDEX idx_role_permissions_role ON config.role_permissions USING btree (tenant_id, school_id, role_id, is_deleted);


--
-- Name: idx_roles_tenant; Type: INDEX; Schema: config; Owner: -
--

CREATE INDEX idx_roles_tenant ON config.roles USING btree (tenant_id);


--
-- Name: idx_school_statuses_tenant; Type: INDEX; Schema: config; Owner: -
--

CREATE INDEX idx_school_statuses_tenant ON config.school_statuses USING btree (tenant_id);


--
-- Name: idx_school_types_tenant; Type: INDEX; Schema: config; Owner: -
--

CREATE INDEX idx_school_types_tenant ON config.school_types USING btree (tenant_id);


--
-- Name: idx_time_formats_tenant; Type: INDEX; Schema: config; Owner: -
--

CREATE INDEX idx_time_formats_tenant ON config.time_formats USING btree (tenant_id);


--
-- Name: ux_roles_school_code; Type: INDEX; Schema: config; Owner: -
--

CREATE UNIQUE INDEX ux_roles_school_code ON config.roles USING btree (tenant_id, school_id, role_code) WHERE (is_deleted = false);


--
-- Name: idx_admin_activity_logs_created; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_admin_activity_logs_created ON core.admin_activity_logs USING btree (tenant_id, created_at);


--
-- Name: idx_admin_activity_logs_school; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_admin_activity_logs_school ON core.admin_activity_logs USING btree (tenant_id, school_id);


--
-- Name: idx_admin_activity_logs_user; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_admin_activity_logs_user ON core.admin_activity_logs USING btree (tenant_id, user_id);


--
-- Name: idx_admission_audit_student; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_admission_audit_student ON core.admission_audit USING btree (student_id);


--
-- Name: idx_enquiries_assigned; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_enquiries_assigned ON core.enquiries USING btree (assigned_to_id);


--
-- Name: idx_enquiries_enquiry_date; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_enquiries_enquiry_date ON core.enquiries USING btree (enquiry_date);


--
-- Name: idx_enquiries_followup; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_enquiries_followup ON core.enquiries USING btree (next_followup_date);


--
-- Name: idx_enquiries_school; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_enquiries_school ON core.enquiries USING btree (tenant_id, school_id);


--
-- Name: idx_enquiries_status; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_enquiries_status ON core.enquiries USING btree (status);


--
-- Name: idx_eq_followups_enquiry; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_eq_followups_enquiry ON core.enquiry_followups USING btree (enquiry_id);


--
-- Name: idx_eq_status_history_enquiry; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_eq_status_history_enquiry ON core.enquiry_status_history USING btree (enquiry_id);


--
-- Name: idx_login_attempts_created; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_login_attempts_created ON core.login_attempts USING btree (tenant_id, created_at);


--
-- Name: idx_login_attempts_email; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_login_attempts_email ON core.login_attempts USING btree (tenant_id, email);


--
-- Name: idx_password_reset_tokens_user; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_password_reset_tokens_user ON core.password_reset_tokens USING btree (tenant_id, user_id);


--
-- Name: idx_school_addresses_city_state; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_school_addresses_city_state ON core.school_addresses USING btree (tenant_id, city, state);


--
-- Name: idx_school_addresses_deleted; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_school_addresses_deleted ON core.school_addresses USING btree (tenant_id, is_deleted);


--
-- Name: idx_school_addresses_school; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_school_addresses_school ON core.school_addresses USING btree (tenant_id, school_id);


--
-- Name: idx_school_contacts_deleted; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_school_contacts_deleted ON core.school_contacts USING btree (tenant_id, is_deleted);


--
-- Name: idx_school_contacts_phone; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_school_contacts_phone ON core.school_contacts USING btree (tenant_id, phone);


--
-- Name: idx_school_contacts_school; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_school_contacts_school ON core.school_contacts USING btree (tenant_id, school_id);


--
-- Name: idx_school_documents_deleted; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_school_documents_deleted ON core.school_documents USING btree (tenant_id, is_deleted);


--
-- Name: idx_school_documents_school; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_school_documents_school ON core.school_documents USING btree (tenant_id, school_id);


--
-- Name: idx_school_documents_type; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_school_documents_type ON core.school_documents USING btree (tenant_id, document_type_id);


--
-- Name: idx_school_profiles_board; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_school_profiles_board ON core.school_profiles USING btree (tenant_id, board_id);


--
-- Name: idx_school_profiles_school; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_school_profiles_school ON core.school_profiles USING btree (tenant_id, school_id);


--
-- Name: idx_school_settings_school; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_school_settings_school ON core.school_settings USING btree (tenant_id, school_id);


--
-- Name: idx_schools_deleted; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_schools_deleted ON core.schools USING btree (tenant_id, is_deleted);


--
-- Name: idx_schools_name; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_schools_name ON core.schools USING btree (tenant_id, school_name);


--
-- Name: idx_schools_status; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_schools_status ON core.schools USING btree (tenant_id, status_id);


--
-- Name: idx_schools_tenant; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_schools_tenant ON core.schools USING btree (tenant_id);


--
-- Name: idx_student_fee_plan_student; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_student_fee_plan_student ON core.student_fee_plan USING btree (student_id);


--
-- Name: idx_student_ledger_due; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_student_ledger_due ON core.student_ledger USING btree (due_date);


--
-- Name: idx_student_ledger_student; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_student_ledger_student ON core.student_ledger USING btree (student_id);


--
-- Name: idx_students_class; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_students_class ON core.students USING btree (class_name, section);


--
-- Name: idx_students_enquiry; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_students_enquiry ON core.students USING btree (enquiry_id);


--
-- Name: idx_students_school; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_students_school ON core.students USING btree (tenant_id, school_id);


--
-- Name: idx_students_year; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_students_year ON core.students USING btree (academic_year);


--
-- Name: idx_user_profiles_user; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_user_profiles_user ON core.user_profiles USING btree (tenant_id, user_id);


--
-- Name: idx_user_roles_role; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_user_roles_role ON core.user_roles USING btree (tenant_id, role_id);


--
-- Name: idx_user_roles_user; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_user_roles_user ON core.user_roles USING btree (tenant_id, user_id);


--
-- Name: idx_user_sessions_active; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_user_sessions_active ON core.user_sessions USING btree (tenant_id, is_active);


--
-- Name: idx_user_sessions_user; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_user_sessions_user ON core.user_sessions USING btree (tenant_id, user_id);


--
-- Name: idx_users_deleted; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_users_deleted ON core.users USING btree (tenant_id, is_deleted);


--
-- Name: idx_users_email; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_users_email ON core.users USING btree (tenant_id, email);


--
-- Name: idx_users_school; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_users_school ON core.users USING btree (tenant_id, school_id);


--
-- Name: idx_users_tenant; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_users_tenant ON core.users USING btree (tenant_id);


--
-- Name: ux_user_one_primary_role; Type: INDEX; Schema: core; Owner: -
--

CREATE UNIQUE INDEX ux_user_one_primary_role ON core.user_roles USING btree (tenant_id, school_id, user_id) WHERE ((is_deleted = false) AND (is_primary = true));


--
-- Name: academic_class_sections fk_academic_class_sections_class; Type: FK CONSTRAINT; Schema: academic; Owner: -
--

ALTER TABLE ONLY academic.academic_class_sections
    ADD CONSTRAINT fk_academic_class_sections_class FOREIGN KEY (academic_class_id) REFERENCES academic.academic_classes(academic_class_id);


--
-- Name: academic_class_sections fk_academic_class_sections_year; Type: FK CONSTRAINT; Schema: academic; Owner: -
--

ALTER TABLE ONLY academic.academic_class_sections
    ADD CONSTRAINT fk_academic_class_sections_year FOREIGN KEY (academic_year_id) REFERENCES academic.academic_years(academic_year_id);


--
-- Name: academic_classes fk_academic_classes_year; Type: FK CONSTRAINT; Schema: academic; Owner: -
--

ALTER TABLE ONLY academic.academic_classes
    ADD CONSTRAINT fk_academic_classes_year FOREIGN KEY (academic_year_id) REFERENCES academic.academic_years(academic_year_id);


--
-- Name: enquiry_followups enquiry_followups_enquiry_id_fkey; Type: FK CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.enquiry_followups
    ADD CONSTRAINT enquiry_followups_enquiry_id_fkey FOREIGN KEY (enquiry_id) REFERENCES core.enquiries(enquiry_id) ON DELETE CASCADE;


--
-- Name: enquiry_status_history enquiry_status_history_enquiry_id_fkey; Type: FK CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.enquiry_status_history
    ADD CONSTRAINT enquiry_status_history_enquiry_id_fkey FOREIGN KEY (enquiry_id) REFERENCES core.enquiries(enquiry_id) ON DELETE CASCADE;


--
-- Name: school_fee_structure_details fk_school_fee_structure_details_structure; Type: FK CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.school_fee_structure_details
    ADD CONSTRAINT fk_school_fee_structure_details_structure FOREIGN KEY (fee_structure_id) REFERENCES core.school_fee_structures(fee_structure_id);


--
-- Name: student_fee_plan student_fee_plan_student_id_fkey; Type: FK CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.student_fee_plan
    ADD CONSTRAINT student_fee_plan_student_id_fkey FOREIGN KEY (student_id) REFERENCES core.students(student_id) ON DELETE CASCADE;


--
-- Name: student_ledger student_ledger_student_id_fkey; Type: FK CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.student_ledger
    ADD CONSTRAINT student_ledger_student_id_fkey FOREIGN KEY (student_id) REFERENCES core.students(student_id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

\unrestrict wg3fNbNA2wAcKo3L1gAz3o5PijadWM9Zi0AqhEq9bkcdJa4mxo34lHvMqacBUvr

