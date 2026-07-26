-- ============================================================================
-- Drop core.sp_school_list1 — dead code.
--
-- It was never called: no C# references it, no other proc calls it, and it had
-- no source file in Database/ (it existed only inside the database).
--
-- WHAT IT WAS: a copy of core.sp_school_list plus two extra parameters,
-- p_sort_column and p_sort_dir, implementing server-side sorting via a
-- CASE-per-column ORDER BY. Someone built sortable columns for the school list
-- and never wired the screen up to it. The live list (sp_school_list) still
-- orders by s.school_id DESC.
--
-- The full definition is archived at the bottom of this file so that work is not
-- lost. It is inside a block comment, so running this file only DROPS — it can
-- never accidentally recreate the procedure.
--
-- NOTE if it is ever revived: it sorts school_code as TEXT, which now reads
-- SCH1, SCH10, SCH11, SCH2 ... (see school_code_sequence.sql). Sort numerically:
--     ORDER BY NULLIF(regexp_replace(school_code,'\D','','g'),'')::int
-- Re-runnable.
-- ============================================================================

DROP PROCEDURE IF EXISTS core.sp_school_list1(
    integer, integer, character varying, character varying, character varying,
    integer, integer, integer, date, date, integer, integer,
    character varying, character varying, refcursor);

-- ============================================================================
-- ARCHIVED DEFINITION — reference only, deliberately commented out.
-- ============================================================================
/*
CREATE OR REPLACE PROCEDURE core.sp_school_list1(IN p_tenant_id integer, IN p_action_user_id integer, IN p_search character varying DEFAULT NULL::character varying, IN p_city character varying DEFAULT NULL::character varying, IN p_state character varying DEFAULT NULL::character varying, IN p_status_id integer DEFAULT NULL::integer, IN p_board_id integer DEFAULT NULL::integer, IN p_school_type_id integer DEFAULT NULL::integer, IN p_from_date date DEFAULT NULL::date, IN p_to_date date DEFAULT NULL::date, IN p_page_no integer DEFAULT 1, IN p_page_size integer DEFAULT 10, IN p_sort_column character varying DEFAULT NULL::character varying, IN p_sort_dir character varying DEFAULT 'asc'::character varying, INOUT p_result refcursor DEFAULT 'school_list_cursor'::refcursor)
 LANGUAGE plpgsql
AS $procedure$

DECLARE
    v_offset integer;
    v_col    text;
    v_asc    boolean;
BEGIN
    IF p_page_no IS NULL OR p_page_no < 1 THEN p_page_no := 1; END IF;
    IF p_page_size IS NULL OR p_page_size < 1 THEN p_page_size := 10; END IF;
    v_offset := (p_page_no - 1) * p_page_size;

    -- Whitelist the sort column (anything unknown falls back to the default
    -- school_id DESC order below). Direction is a plain asc/desc boolean.
    -- Column names are matched against a fixed set here, never interpolated,
    -- so this is safe from SQL injection.
    v_col := lower(COALESCE(NULLIF(TRIM(p_sort_column), ''), ''));
    v_asc := (lower(COALESCE(p_sort_dir, 'asc')) <> 'desc');

    OPEN p_result FOR
    SELECT
        s.school_id,
        s.school_code,
        s.school_name,
        s.display_name,
        t.tenant_name,
        st.name AS status_name,
        b.name  AS board_name,
        sty.name AS school_type_name,
        a.city,
        a.state,
        c.contact_name,
        c.phone,
        s.created_at,
        COUNT(*) OVER()                                          AS total_count,
        COUNT(*) FILTER (WHERE st.name = 'Active') OVER()        AS active_count
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
      AND (p_tenant_id = 1 OR s.tenant_id = p_tenant_id)
      AND (p_search IS NULL OR TRIM(p_search) = '' OR
              s.school_name  ILIKE '%' || p_search || '%' OR
              s.school_code  ILIKE '%' || p_search || '%' OR
              t.tenant_name  ILIKE '%' || p_search || '%' OR
              a.city         ILIKE '%' || p_search || '%' OR
              c.contact_name ILIKE '%' || p_search || '%')
      AND (p_city IS NULL OR TRIM(p_city) = '' OR a.city ILIKE '%' || p_city || '%')
      AND (p_state IS NULL OR TRIM(p_state) = '' OR a.state ILIKE '%' || p_state || '%')
      AND (p_status_id IS NULL OR s.status_id = p_status_id)
      AND (p_board_id IS NULL OR sp.board_id = p_board_id)
      AND (p_school_type_id IS NULL OR sp.school_type_id = p_school_type_id)
      AND (p_from_date IS NULL OR s.created_at::date >= p_from_date)
      AND (p_to_date   IS NULL OR s.created_at::date <= p_to_date)
    ORDER BY
        CASE WHEN v_col = 'school_name' AND v_asc     THEN s.school_name END ASC  NULLS LAST,
        CASE WHEN v_col = 'school_name' AND NOT v_asc THEN s.school_name END DESC NULLS LAST,
        CASE WHEN v_col = 'school_code' AND v_asc     THEN s.school_code END ASC  NULLS LAST,
        CASE WHEN v_col = 'school_code' AND NOT v_asc THEN s.school_code END DESC NULLS LAST,
        CASE WHEN v_col = 'tenant_name' AND v_asc     THEN t.tenant_name END ASC  NULLS LAST,
        CASE WHEN v_col = 'tenant_name' AND NOT v_asc THEN t.tenant_name END DESC NULLS LAST,
        CASE WHEN v_col = 'city'        AND v_asc     THEN a.city END ASC  NULLS LAST,
        CASE WHEN v_col = 'city'        AND NOT v_asc THEN a.city END DESC NULLS LAST,
        CASE WHEN v_col = 'status_name' AND v_asc     THEN st.name END ASC  NULLS LAST,
        CASE WHEN v_col = 'status_name' AND NOT v_asc THEN st.name END DESC NULLS LAST,
        CASE WHEN v_col = 'created_at'  AND v_asc     THEN s.created_at END ASC  NULLS LAST,
        CASE WHEN v_col = 'created_at'  AND NOT v_asc THEN s.created_at END DESC NULLS LAST,
        s.school_id DESC   -- stable tiebreaker + default when no/unknown sort
    LIMIT p_page_size OFFSET v_offset;
END;
$procedure$

*/
