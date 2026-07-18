-- Server-side paged + sorted + searched listing for the Fee Head master screen.
-- Separate from sp_school_admin_fee_head_manage's cached "GetFeeHead" (which returns
-- the FULL list for other screens) so pagination never pollutes that cache.
-- total_count is a window count over the full filtered set (before LIMIT).
-- Sort column is whitelisted via CASE — never interpolated, so injection-safe.
CREATE OR REPLACE PROCEDURE core.sp_fee_head_list(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_search         varchar   DEFAULT NULL,
    IN    p_frequency      varchar   DEFAULT NULL,
    IN    p_page_no        integer   DEFAULT 1,
    IN    p_page_size      integer   DEFAULT 10,
    IN    p_sort_column    varchar   DEFAULT NULL,
    IN    p_sort_dir       varchar   DEFAULT 'asc',
    INOUT p_result         refcursor DEFAULT 'fee_head_list_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_offset integer;
    v_col    text;
    v_asc    boolean;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    IF p_page_no   IS NULL OR p_page_no   < 1 THEN p_page_no   := 1;  END IF;
    IF p_page_size IS NULL OR p_page_size < 1 THEN p_page_size := 10; END IF;
    v_offset := (p_page_no - 1) * p_page_size;

    v_col := lower(COALESCE(NULLIF(TRIM(p_sort_column), ''), ''));
    v_asc := (lower(COALESCE(p_sort_dir, 'asc')) <> 'desc');

    OPEN p_result FOR
    SELECT
        fee_head_id,
        tenant_id,
        school_id,
        fee_head_name,
        frequency,
        COALESCE(default_amount, 0)             AS default_amount,
        fee_type,
        fee_group,
        COALESCE(collection_point, 'Recurring') AS collection_point,
        COALESCE(is_refundable, FALSE)          AS is_refundable,
        COALESCE(display_order, 0)              AS display_order,
        COALESCE(is_active, TRUE)               AS is_active,
        COUNT(*) OVER()                                        AS total_count,
        -- Summary tiles must reflect the FULL filtered set, not just this page,
        -- so they are window counts (same OVER() frame as total_count) — never
        -- computed from the paged Items list in the view.
        COUNT(*) FILTER (WHERE fee_type = 'Mandatory') OVER() AS mandatory_count,
        COUNT(*) FILTER (WHERE fee_type = 'Optional')  OVER() AS optional_count
    FROM core.school_fee_heads
    WHERE tenant_id = p_tenant_id
      AND school_id = p_school_id
      AND COALESCE(is_deleted, FALSE) = FALSE
      AND (p_search    IS NULL OR TRIM(p_search) = ''    OR fee_head_name ILIKE '%' || p_search || '%')
      AND (p_frequency IS NULL OR TRIM(p_frequency) = '' OR lower(frequency) = lower(p_frequency))
    ORDER BY
        CASE WHEN v_col = 'name'   AND v_asc     THEN fee_head_name END ASC  NULLS LAST,
        CASE WHEN v_col = 'name'   AND NOT v_asc THEN fee_head_name END DESC NULLS LAST,
        CASE WHEN v_col = 'amount' AND v_asc     THEN COALESCE(default_amount, 0) END ASC,
        CASE WHEN v_col = 'amount' AND NOT v_asc THEN COALESCE(default_amount, 0) END DESC,
        CASE WHEN v_col = 'cycle'  AND v_asc     THEN frequency END ASC  NULLS LAST,
        CASE WHEN v_col = 'cycle'  AND NOT v_asc THEN frequency END DESC NULLS LAST,
        display_order, fee_head_name   -- stable default when no/unknown sort
    LIMIT p_page_size OFFSET v_offset;
END;
$procedure$;
