-- ============================================================================
-- Seal & signature (School Setup › Seal & Signature).
--
-- The head of school's signature image, the school seal image and the name /
-- designation printed under them. Printed documents (certificates, report cards,
-- circulars, TC, admit cards) show them when set, so a document looks official
-- without a rubber stamp on every copy.
--
-- Kept in core.school_profiles beside logo_url, but read and written by this
-- small proc so the long basic-profile proc is not touched. Get is called by
-- SchoolSettingsService.GetBasicProfileAsync, so every print page that loads the
-- school profile gets these too.
-- Re-runnable.
-- ============================================================================

ALTER TABLE core.school_profiles ADD COLUMN IF NOT EXISTS signature_url         varchar(300);
ALTER TABLE core.school_profiles ADD COLUMN IF NOT EXISTS seal_url              varchar(300);
ALTER TABLE core.school_profiles ADD COLUMN IF NOT EXISTS signatory_name        varchar(120);
ALTER TABLE core.school_profiles ADD COLUMN IF NOT EXISTS signatory_designation varchar(80);

CREATE OR REPLACE PROCEDURE core.sp_school_signature_manage(
    IN    p_operation      varchar,          -- Get | SaveImage | SaveName | Remove
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_kind           varchar DEFAULT NULL,   -- signature | seal (SaveImage / Remove)
    IN    p_url            varchar DEFAULT NULL,   -- SaveImage
    IN    p_name           varchar DEFAULT NULL,   -- SaveName
    IN    p_designation    varchar DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'signature_cursor')
LANGUAGE plpgsql
AS $$
DECLARE
    v_old varchar;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM core.school_profiles WHERE tenant_id = p_tenant_id AND school_id = p_school_id) THEN
        IF p_operation = 'Get' THEN
            OPEN p_result FOR SELECT NULL::varchar AS signature_url, NULL::varchar AS seal_url,
                                     NULL::varchar AS signatory_name, NULL::varchar AS signatory_designation;
            RETURN;
        END IF;
        RAISE EXCEPTION 'Save the school''s basic profile first.';
    END IF;

    IF p_operation = 'Get' THEN
        OPEN p_result FOR
        SELECT signature_url, seal_url, signatory_name, signatory_designation
          FROM core.school_profiles WHERE tenant_id = p_tenant_id AND school_id = p_school_id
         LIMIT 1;
        RETURN;
    END IF;

    IF p_operation IN ('SaveImage', 'Remove') AND COALESCE(p_kind, '') NOT IN ('signature', 'seal') THEN
        RAISE EXCEPTION 'Choose signature or seal.';
    END IF;

    -- the old file's URL comes back so the app can delete it
    SELECT CASE WHEN p_kind = 'seal' THEN seal_url ELSE signature_url END INTO v_old
      FROM core.school_profiles WHERE tenant_id = p_tenant_id AND school_id = p_school_id LIMIT 1;

    IF p_operation = 'SaveImage' THEN
        IF NULLIF(trim(p_url), '') IS NULL THEN RAISE EXCEPTION 'No image.'; END IF;
        UPDATE core.school_profiles
           SET signature_url = CASE WHEN p_kind = 'signature' THEN trim(p_url) ELSE signature_url END,
               seal_url      = CASE WHEN p_kind = 'seal'      THEN trim(p_url) ELSE seal_url END,
               updated_by = p_action_user_id, updated_at = now()
         WHERE tenant_id = p_tenant_id AND school_id = p_school_id;
        OPEN p_result FOR SELECT (initcap(p_kind) || ' saved.')::varchar AS message, v_old AS old_url;
        RETURN;
    END IF;

    IF p_operation = 'Remove' THEN
        UPDATE core.school_profiles
           SET signature_url = CASE WHEN p_kind = 'signature' THEN NULL ELSE signature_url END,
               seal_url      = CASE WHEN p_kind = 'seal'      THEN NULL ELSE seal_url END,
               updated_by = p_action_user_id, updated_at = now()
         WHERE tenant_id = p_tenant_id AND school_id = p_school_id;
        OPEN p_result FOR SELECT (initcap(p_kind) || ' removed.')::varchar AS message, v_old AS old_url;
        RETURN;
    END IF;

    IF p_operation = 'SaveName' THEN
        UPDATE core.school_profiles
           SET signatory_name = NULLIF(trim(p_name), ''),
               signatory_designation = COALESCE(NULLIF(trim(p_designation), ''), 'Principal'),
               updated_by = p_action_user_id, updated_at = now()
         WHERE tenant_id = p_tenant_id AND school_id = p_school_id;
        OPEN p_result FOR SELECT 'Saved.'::varchar AS message, NULL::varchar AS old_url;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation.';
END;
$$;
