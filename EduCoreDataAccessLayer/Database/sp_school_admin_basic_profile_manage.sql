-- ============================================================================
-- core.sp_school_admin_basic_profile_manage
--
-- Dumped from the live DB so this proc finally has a source file (the only
-- previous mention of it anywhere was a comment). Edit here, re-apply with psql -f.
--
-- Changes made on top of the original:
--   1. board_name now includes the board's STATE. A State Board school was
--      showing just "State Board" on Basic Profile while the school list already
--      said "State Board (Uttar Pradesh)" — the two screens disagreed.
--   2. GET returns country_id / state_id / district_id so the shared
--      Country->State->District picker can pre-select, matching the SuperAdmin
--      wizard instead of using free-text boxes.
--   3. SAVE accepts and stores those same ids (new p_country_id / p_state_id /
--      p_district_id parameters, added at the END, just before p_result).
--   4. (2026-10-10) Official / alternate phone may be a landline: see
--      core.fn_school_phone_clean below. Stored as digits only.
--   5. (2026-10-10) 'RemoveLogo' operation: clears logo_url and returns the old
--      URL so the controller can delete the file (only when it sits in this
--      school's upload folder).
-- ============================================================================

-- ── fn_school_phone_clean ───────────────────────────────────────────────────
-- A school's official number is often a landline. Accepted, after removing
-- spaces and hyphens:
--   * a 10-digit Indian mobile        9876543210
--   * a landline with its STD code    0141-2345678, 011 23456789, 01412345678
--     (starts with 0, 10 to 12 digits in all)
-- Returns the number as DIGITS ONLY (0141-2345678 -> 01412345678), NULL for a
-- blank value, and raises for anything else. The same rule is in
-- EC.rule.phone (site.js) and PhoneRules (C#).
CREATE OR REPLACE FUNCTION core.fn_school_phone_clean(p_value varchar, p_label varchar)
RETURNS varchar
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
    v varchar := regexp_replace(COALESCE(p_value, ''), '[\s-]', '', 'g');
BEGIN
    IF v = '' THEN
        RETURN NULL;
    END IF;
    IF v ~ '^[6-9][0-9]{9}$' OR v ~ '^0[0-9]{9,11}$' THEN
        RETURN v;
    END IF;
    RAISE EXCEPTION '% must be a 10-digit mobile number or a landline with STD code (e.g. 0141-2345678).', p_label
        USING ERRCODE = 'check_violation';
END;
$$;

CREATE OR REPLACE PROCEDURE core.sp_school_admin_basic_profile_manage(IN p_operation character varying, IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_display_name character varying DEFAULT NULL::character varying, IN p_registration_number character varying DEFAULT NULL::character varying, IN p_affiliation_number character varying DEFAULT NULL::character varying, IN p_board_id integer DEFAULT NULL::integer, IN p_school_type_id integer DEFAULT NULL::integer, IN p_ownership_type_id integer DEFAULT NULL::integer, IN p_medium_id integer DEFAULT NULL::integer, IN p_established_year integer DEFAULT NULL::integer, IN p_website character varying DEFAULT NULL::character varying, IN p_logo_url character varying DEFAULT NULL::character varying, IN p_header_image_url character varying DEFAULT NULL::character varying, IN p_address_type_id integer DEFAULT NULL::integer, IN p_address_line1 character varying DEFAULT NULL::character varying, IN p_address_line2 character varying DEFAULT NULL::character varying, IN p_city character varying DEFAULT NULL::character varying, IN p_district character varying DEFAULT NULL::character varying, IN p_state character varying DEFAULT NULL::character varying, IN p_pincode character varying DEFAULT NULL::character varying, IN p_contact_type_id integer DEFAULT NULL::integer, IN p_contact_name character varying DEFAULT NULL::character varying, IN p_designation character varying DEFAULT NULL::character varying, IN p_contact_email character varying DEFAULT NULL::character varying, IN p_phone character varying DEFAULT NULL::character varying, IN p_alternate_phone character varying DEFAULT NULL::character varying, IN p_academic_year_id integer DEFAULT NULL::integer, IN p_date_format_id integer DEFAULT NULL::integer, IN p_time_format_id integer DEFAULT NULL::integer, IN p_enable_sms boolean DEFAULT false, IN p_enable_email boolean DEFAULT true, IN p_enable_whatsapp boolean DEFAULT false, IN p_country_id integer DEFAULT NULL::integer, IN p_state_id integer DEFAULT NULL::integer, IN p_district_id integer DEFAULT NULL::integer, INOUT p_result refcursor DEFAULT 'basic_profile_cursor'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    -- Set only for boards flagged requires_state; the address state is then forced
    -- to these values on save (see the UpdateBasicProfile branch).
    v_locked_state_id   integer;
    v_locked_state_name character varying;
    v_old_logo          character varying;
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
            -- The page's status pill read "Status -" for every school: this join was
            -- left commented out (with a wrong table and column name).
            sm.name AS status_name,

            sp.registration_number,
            sp.affiliation_number,

            sp.board_id,
            sp.board_state_id,
            -- "State Board (Uttar Pradesh)", not a bare "State Board". Boards flagged
            -- config.boards.requires_state carry a board_state_id; without this join
            -- the school list and this page described the same school differently.
            CASE WHEN bs.name IS NOT NULL THEN b.name || ' (' || bs.name || ')' ELSE b.name END
                AS board_name,
            -- Drives the read-only lock on the address State. A State Board is granted by
            -- one state's education department, so a UP Board school cannot sit in Bihar —
            -- for these boards the address state is not the school's to choose. CBSE/ICSE/IB
            -- are national, so they stay free.
            COALESCE(b.requires_state, FALSE) AS board_requires_state,

            sp.school_type_id,
            st.name AS school_type_name,

            -- School / Computer-IT institute / Coaching centre, and what this page calls
            -- the board and type fields for it (institution_categories.sql).
            COALESCE(ic.name, 'School')         AS category_name,
            COALESCE(ic.board_label, 'Board')   AS board_label,
            COALESCE(ic.type_label, 'School Type') AS type_label,

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
            -- Needed so the shared Country -> State -> District picker can pre-select,
            -- instead of this page falling back to free-text boxes that drift from
            -- what the SuperAdmin wizard stored.
            sa.country_id,
            sa.state_id,
            sa.district_id,

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

        LEFT JOIN config.school_statuses sm
            ON sm.school_status_id = s.status_id

        LEFT JOIN config.boards b
            ON b.board_id = sp.board_id

        LEFT JOIN config.states bs
            ON bs.state_id = sp.board_state_id

        LEFT JOIN config.institution_categories ic
            ON ic.category_id = sp.institution_category_id

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

        -- Mobile or landline, stored as digits (fn_school_phone_clean).
        p_phone           := core.fn_school_phone_clean(p_phone, 'Official phone');
        p_alternate_phone := core.fn_school_phone_clean(p_alternate_phone, 'Alternate phone');

        -- A State Board is granted by one state's education department, so a UP Board
        -- school cannot be located in Bihar. For boards flagged requires_state the
        -- address state is NOT the school's to choose — it follows the board.
        --
        -- Forced here, on the server, and not just disabled in the UI: a disabled input
        -- simply doesn't post, and a hand-crafted POST would otherwise slip a different
        -- state through. The board state is the single source of truth.
        --
        -- Only applies to requires_state boards; CBSE / ICSE / IB / NIOS are national
        -- and their schools may sit in any state, so those fall through untouched.
        SELECT sp.board_state_id, st.name
          INTO v_locked_state_id, v_locked_state_name
        FROM core.school_profiles sp
        JOIN config.boards b     ON b.board_id = sp.board_id AND b.requires_state = TRUE
        JOIN config.states st    ON st.state_id = sp.board_state_id
        WHERE sp.tenant_id = p_tenant_id
          AND sp.school_id = p_school_id
          AND sp.is_deleted = FALSE;

        IF v_locked_state_id IS NOT NULL THEN
            p_state_id := v_locked_state_id;
            p_state    := v_locked_state_name;

            -- A district from the old state would now contradict the forced state, so
            -- drop it rather than store an impossible pair. The school re-picks it.
            IF p_district_id IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM config.districts d
                               WHERE d.district_id = p_district_id
                                 AND d.state_id = v_locked_state_id) THEN
                p_district_id := NULL;
                p_district    := NULL;
            END IF;
        END IF;

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
            country_id,
            state_id,
            district_id,
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
            p_country_id,
            p_state_id,
            p_district_id,
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
            -- COALESCE so a caller that doesn't send the ids (an older screen, or a
            -- partial save) cannot blank out geography the wizard already set.
            country_id = COALESCE(EXCLUDED.country_id, core.school_addresses.country_id),
            state_id = COALESCE(EXCLUDED.state_id, core.school_addresses.state_id),
            -- The district id must never outlive its text or its state: no district
            -- text means no district, and a new state drops the old state's district.
            -- (A plain COALESCE kept Gurugram after the state moved to Delhi.)
            district_id = CASE
                WHEN NULLIF(trim(EXCLUDED.district), '') IS NULL THEN NULL
                WHEN EXCLUDED.district_id IS NOT NULL THEN EXCLUDED.district_id
                WHEN COALESCE(EXCLUDED.state_id, core.school_addresses.state_id)
                     IS DISTINCT FROM core.school_addresses.state_id THEN NULL
                ELSE core.school_addresses.district_id
            END,
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

    ELSIF p_operation = 'RemoveLogo' THEN

        -- The save above keeps the old logo when none is sent (COALESCE), so
        -- taking a logo off needs its own operation. Only this school's row.
        SELECT sp.logo_url INTO v_old_logo
        FROM core.school_profiles sp
        WHERE sp.tenant_id = p_tenant_id AND sp.school_id = p_school_id;

        UPDATE core.school_profiles
        SET logo_url = NULL,
            updated_by = p_action_user_id,
            updated_at = NOW()
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND logo_url IS NOT NULL;

        OPEN p_result FOR
        SELECT
            TRUE AS success,
            p_school_id AS school_id,
            v_old_logo AS removed_logo_url,
            CASE WHEN NULLIF(trim(v_old_logo), '') IS NULL THEN 'There was no logo to remove.'
                 ELSE 'Logo removed.' END AS message;

    ELSE
        RAISE EXCEPTION 'Invalid operation %. Allowed operations are GetBasicProfile, UpdateBasicProfile, RemoveLogo', p_operation;
    END IF;
END;
$procedure$

;
