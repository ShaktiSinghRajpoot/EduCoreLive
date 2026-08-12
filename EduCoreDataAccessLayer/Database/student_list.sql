-- ============================================================================
-- core.sp_student_list
-- Server-side listing for the "All Students" page (Student/StudentList).
--
-- One proc = search + filters (class/gender/fee/year/status) + whitelisted
-- server-side sorting + pagination. Mirrors the sp_fee_head_list pattern.
--
-- The big core.sp_admission_manage 'GetStudents' branch is left untouched
-- (it still backs the AJAX GetStudentsData endpoint used by exports); this
-- dedicated proc adds sorting + summary tiles for the fat-model list page.
--
-- Returns one refcursor. Every row carries:
--   total_count / male_count / female_count / active_count  (window aggregates
--   over the WHOLE filtered set, so the summary tiles stay accurate across pages)
-- ============================================================================
CREATE OR REPLACE PROCEDURE core.sp_student_list(
    IN  p_tenant_id      integer,
    IN  p_school_id      integer,
    IN  p_action_user_id integer,
    IN  p_search         text    DEFAULT NULL,
    IN  p_filter_class   text    DEFAULT NULL,
    IN  p_filter_gender  text    DEFAULT NULL,
    IN  p_filter_fee     text    DEFAULT NULL,   -- Paid | Partial | Pending
    IN  p_filter_year    text    DEFAULT NULL,
    IN  p_filter_status  text    DEFAULT NULL,
    IN  p_page_no        integer DEFAULT 1,
    IN  p_page_size      integer DEFAULT 10,
    IN  p_sort_column    text    DEFAULT NULL,
    IN  p_sort_dir       text    DEFAULT 'asc',
    INOUT p_result       refcursor DEFAULT 'student_list_cursor'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_offset  integer;
    v_col     text;
    v_asc     boolean;
BEGIN
    -- Tenant/school scope guard (tenant 1 = platform, never real data).
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        OPEN p_result FOR SELECT WHERE FALSE;   -- empty result set
        RETURN;
    END IF;

    v_offset := (GREATEST(COALESCE(p_page_no, 1), 1) - 1) * COALESCE(p_page_size, 10);
    v_col    := LOWER(TRIM(COALESCE(p_sort_column, '')));
    v_asc    := LOWER(TRIM(COALESCE(p_sort_dir, 'asc'))) <> 'desc';

    OPEN p_result FOR
        WITH filtered AS (
            SELECT
                s.student_id, s.admission_no, s.roll_no, s.student_name,
                s.gender,
                -- When a session is asked for, report the class/section the
                -- student held IN THAT SESSION, not their present one.
                COALESCE(e.class_name,    s.class_name)    AS class_name,
                COALESCE(e.section,       s.section)       AS section,
                COALESCE(e.academic_year, s.academic_year) AS academic_year,
                s.admission_date, s.guardian_name, s.mobile,
                s.annual_total, s.status, s.approval_status, s.enquiry_id,
                s.photo_url,
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
            -- Per-session position (core.student_enrolment). students.academic_year
            -- only holds where a student is NOW, so filtering on it loses everyone
            -- who has since been promoted. Matches only when a session is asked
            -- for; otherwise e.* is NULL and the COALESCEs fall back to students.
            LEFT JOIN core.student_enrolment e
                   ON e.student_id    = s.student_id
                  AND e.academic_year = NULLIF(TRIM(COALESCE(p_filter_year, '')), '')
            WHERE s.tenant_id = p_tenant_id
              AND s.school_id = p_school_id
              AND s.is_active = TRUE
              AND (
                  p_search IS NULL OR TRIM(p_search) = ''
                  OR LOWER(s.student_name) LIKE '%' || LOWER(TRIM(p_search)) || '%'
                  OR LOWER(s.admission_no)  LIKE '%' || LOWER(TRIM(p_search)) || '%'
                  OR LOWER(COALESCE(s.guardian_name,'')) LIKE '%' || LOWER(TRIM(p_search)) || '%'
                  OR COALESCE(s.mobile,'') LIKE '%' || TRIM(p_search) || '%'
              )
              -- Enrolled in the requested session at all.
              AND (NULLIF(TRIM(COALESCE(p_filter_year, '')), '') IS NULL
                   OR e.enrolment_id IS NOT NULL)
              -- Class is matched against that session's position.
              AND (p_filter_class  IS NULL OR TRIM(p_filter_class)  = '' OR LOWER(COALESCE(e.class_name, s.class_name)) = LOWER(TRIM(p_filter_class)))
              AND (p_filter_gender IS NULL OR TRIM(p_filter_gender) = '' OR LOWER(COALESCE(s.gender,'')) = LOWER(TRIM(p_filter_gender)))
              AND (p_filter_status IS NULL OR TRIM(p_filter_status) = '' OR LOWER(s.status)              = LOWER(TRIM(p_filter_status)))
        ),
        scored AS (
            -- fee filter runs after fee_status is computed
            SELECT * FROM filtered f
            WHERE (p_filter_fee IS NULL OR TRIM(p_filter_fee) = '' OR LOWER(f.fee_status) = LOWER(TRIM(p_filter_fee)))
        )
        SELECT
            student_id, admission_no, roll_no, student_name, gender,
            class_name, section, academic_year, admission_date,
            guardian_name, mobile, annual_total, status, approval_status,
            enquiry_id, fee_status, fee_due, photo_url,
            COUNT(*)                                                    OVER() AS total_count,
            COUNT(*) FILTER (WHERE UPPER(COALESCE(gender,'')) = 'MALE')   OVER() AS male_count,
            COUNT(*) FILTER (WHERE UPPER(COALESCE(gender,'')) = 'FEMALE') OVER() AS female_count,
            COUNT(*) FILTER (WHERE UPPER(COALESCE(status,'')) = 'ACTIVE') OVER() AS active_count
        FROM scored
        ORDER BY
            -- Whitelisted, injection-safe sort (no dynamic SQL).
            CASE WHEN v_col = 'name'    AND v_asc      THEN student_name    END ASC,
            CASE WHEN v_col = 'name'    AND NOT v_asc  THEN student_name    END DESC,
            CASE WHEN v_col = 'class'   AND v_asc      THEN class_name      END ASC,
            CASE WHEN v_col = 'class'   AND NOT v_asc  THEN class_name      END DESC,
            CASE WHEN v_col = 'admdate' AND v_asc      THEN admission_date  END ASC,
            CASE WHEN v_col = 'admdate' AND NOT v_asc  THEN admission_date  END DESC,
            -- Default / tie-breaker: newest admission first.
            admission_date DESC, student_id DESC
        LIMIT  COALESCE(p_page_size, 10)
        OFFSET v_offset;
    RETURN;
END;
$procedure$;
