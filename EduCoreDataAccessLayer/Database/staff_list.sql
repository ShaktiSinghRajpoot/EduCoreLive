-- ============================================================================
-- core.sp_staff_list
-- Server-side listing for the "All Staff" page (Staff/StaffList).
--
-- One proc = search + filters (department / staff-type / status) + whitelisted
-- server-side sorting + pagination. Mirrors sp_fee_head_list / sp_student_list.
--
-- The big core.sp_staff_manage 'LIST' branch is left untouched (it still backs
-- the Inactive page + any client-side callers); this dedicated proc adds
-- sorting + paging for the fat-model list page. Returns one refcursor; every
-- row carries total_count (window aggregate over the whole filtered set).
-- ============================================================================
CREATE OR REPLACE PROCEDURE core.sp_staff_list(
    IN  p_tenant_id       integer,
    IN  p_school_id       integer,
    IN  p_action_user_id  integer,
    IN  p_search          text    DEFAULT NULL,
    IN  p_filter_dept     text    DEFAULT NULL,
    IN  p_filter_type     text    DEFAULT NULL,
    IN  p_filter_status   text    DEFAULT NULL,
    IN  p_page_no         integer DEFAULT 1,
    IN  p_page_size       integer DEFAULT 10,
    IN  p_sort_column     text    DEFAULT NULL,
    IN  p_sort_dir        text    DEFAULT 'asc',
    INOUT p_result        refcursor DEFAULT 'staff_list_cursor'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_offset integer;
    v_col    text;
    v_asc    boolean;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        OPEN p_result FOR SELECT WHERE FALSE;
        RETURN;
    END IF;

    v_offset := (GREATEST(COALESCE(p_page_no, 1), 1) - 1) * COALESCE(p_page_size, 10);
    v_col    := LOWER(TRIM(COALESCE(p_sort_column, '')));
    v_asc    := LOWER(TRIM(COALESCE(p_sort_dir, 'asc'))) <> 'desc';

    OPEN p_result FOR
        WITH filtered AS (
            SELECT s.staff_id, s.public_id, s.employee_code, s.full_name, s.gender,
                   s.mobile, s.email, s.staff_type, s.department, s.designation,
                   s.joining_date, s.status, s.user_id
            FROM   core.staff s
            WHERE  s.tenant_id  = p_tenant_id
              AND  s.school_id  = p_school_id
              AND  s.is_deleted = FALSE
              AND  (p_filter_dept   IS NULL OR TRIM(p_filter_dept)   = '' OR LOWER(COALESCE(s.department,''))  = LOWER(TRIM(p_filter_dept)))
              AND  (p_filter_type   IS NULL OR TRIM(p_filter_type)   = '' OR LOWER(COALESCE(s.staff_type,'')) = LOWER(TRIM(p_filter_type)))
              AND  (p_filter_status IS NULL OR TRIM(p_filter_status) = '' OR LOWER(COALESCE(s.status,''))     = LOWER(TRIM(p_filter_status)))
              AND  (p_search IS NULL OR TRIM(p_search) = ''
                    OR s.full_name     ILIKE '%' || TRIM(p_search) || '%'
                    OR s.employee_code ILIKE '%' || TRIM(p_search) || '%'
                    OR s.designation   ILIKE '%' || TRIM(p_search) || '%'
                    OR COALESCE(s.mobile,'') ILIKE '%' || TRIM(p_search) || '%')
        )
        SELECT staff_id, public_id, employee_code, full_name, gender, mobile, email,
               staff_type, department, designation, joining_date, status, user_id,
               COUNT(*) OVER() AS total_count
        FROM filtered
        ORDER BY
            CASE WHEN v_col = 'name'        AND v_asc     THEN full_name    END ASC,
            CASE WHEN v_col = 'name'        AND NOT v_asc THEN full_name    END DESC,
            CASE WHEN v_col = 'designation' AND v_asc     THEN designation  END ASC,
            CASE WHEN v_col = 'designation' AND NOT v_asc THEN designation  END DESC,
            CASE WHEN v_col = 'department'  AND v_asc     THEN department   END ASC,
            CASE WHEN v_col = 'department'  AND NOT v_asc THEN department   END DESC,
            CASE WHEN v_col = 'joindate'    AND v_asc     THEN joining_date END ASC,
            CASE WHEN v_col = 'joindate'    AND NOT v_asc THEN joining_date END DESC,
            full_name ASC   -- default / tie-breaker
        LIMIT  COALESCE(p_page_size, 10)
        OFFSET v_offset;
    RETURN;
END;
$procedure$;
