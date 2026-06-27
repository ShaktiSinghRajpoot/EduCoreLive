-- Server-side school listing for the SuperAdmin Schools screen: tenant-scoped,
-- with optional filters and pagination. Window counts (total / active) are computed
-- over the full filtered set (before LIMIT) so the UI can show accurate totals.
CREATE OR REPLACE PROCEDURE core.sp_school_list(
    IN p_tenant_id       integer,
    IN p_action_user_id  integer,
    IN p_search          character varying DEFAULT NULL,
    IN p_city            character varying DEFAULT NULL,
    IN p_state           character varying DEFAULT NULL,
    IN p_status_id       integer DEFAULT NULL,
    IN p_board_id        integer DEFAULT NULL,
    IN p_school_type_id  integer DEFAULT NULL,
    IN p_from_date       date DEFAULT NULL,
    IN p_to_date         date DEFAULT NULL,
    IN p_page_no         integer DEFAULT 1,
    IN p_page_size       integer DEFAULT 10,
    INOUT p_result       refcursor DEFAULT 'school_list_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_offset integer;
BEGIN
    IF p_page_no IS NULL OR p_page_no < 1 THEN p_page_no := 1; END IF;
    IF p_page_size IS NULL OR p_page_size < 1 THEN p_page_size := 10; END IF;
    v_offset := (p_page_no - 1) * p_page_size;

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
    ORDER BY s.school_id DESC
    LIMIT p_page_size OFFSET v_offset;
END;
$procedure$;
