-- ============================================================================
-- Fee Due Reminders — server-side paged/filtered defaulters list.
--
-- One row per ACTIVE student who still owes money, with the outstanding total,
-- how many days the OLDEST unpaid installment is overdue, and an ageing bucket.
-- Separate from core.sp_fee_defaulters_get (the report proc, which returns the
-- full un-paged ageing breakdown) so the screen can page/filter/sort server-side.
--
-- total_count / sum_outstanding are window aggregates over the FULL filtered set
-- (before LIMIT) so the KPI tiles and pager stay correct on every page.
-- Sort column is whitelisted via CASE — never interpolated, so injection-safe.
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================
CREATE OR REPLACE PROCEDURE core.sp_fee_due_list(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_search         varchar   DEFAULT NULL,
    IN    p_class          varchar   DEFAULT NULL,
    IN    p_bucket         varchar   DEFAULT NULL,   -- NotDue | 0-30 | 31-60 | 60+
    IN    p_page_no        integer   DEFAULT 1,
    IN    p_page_size      integer   DEFAULT 10,
    IN    p_sort_column    varchar   DEFAULT NULL,   -- name | class | due | days
    IN    p_sort_dir       varchar   DEFAULT 'desc',
    INOUT p_result         refcursor DEFAULT 'fee_due_cursor'::refcursor
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
    v_asc := (lower(COALESCE(p_sort_dir, 'desc')) <> 'desc');

    OPEN p_result FOR
    WITH dues AS (
        SELECT sl.student_id,
               (sl.amount_due - sl.amount_paid - COALESCE(sl.concession, 0)) AS outstanding,
               sl.due_date
        FROM core.student_ledger sl
        WHERE sl.tenant_id = p_tenant_id
          AND sl.school_id = p_school_id
          AND sl.amount_due > sl.amount_paid + COALESCE(sl.concession, 0)
    ),
    agg AS (
        SELECT s.student_id, s.student_name, s.admission_no,
               s.class_name, s.section, s.roll_no, s.mobile,
               -- Parent email drives the Email reminder channel (father first, else mother).
               COALESCE(NULLIF(TRIM(s.father_email), ''), NULLIF(TRIM(s.mother_email), '')) AS parent_email,
               SUM(d.outstanding) AS total_outstanding,
               -- days the OLDEST overdue installment is past its due date (0 = nothing overdue yet)
               COALESCE(MAX(CASE WHEN d.due_date < CURRENT_DATE
                                 THEN (CURRENT_DATE - d.due_date) END), 0) AS overdue_days
        FROM dues d
        JOIN core.students s ON s.student_id = d.student_id
        WHERE s.tenant_id = p_tenant_id
          AND s.school_id = p_school_id
          AND COALESCE(s.is_active, TRUE) = TRUE
          AND (p_class IS NULL OR TRIM(p_class) = '' OR s.class_name = p_class)
          AND (p_search IS NULL OR TRIM(p_search) = ''
               OR s.student_name        ILIKE '%' || p_search || '%'
               OR s.admission_no        ILIKE '%' || p_search || '%'
               OR COALESCE(s.mobile,'') ILIKE '%' || p_search || '%')
        GROUP BY s.student_id, s.student_name, s.admission_no,
                 s.class_name, s.section, s.roll_no, s.mobile,
                 s.father_email, s.mother_email
        HAVING SUM(d.outstanding) > 0
    ),
    filtered AS (
        SELECT a.*,
               CASE WHEN a.overdue_days = 0  THEN 'NotDue'
                    WHEN a.overdue_days <= 30 THEN '0-30'
                    WHEN a.overdue_days <= 60 THEN '31-60'
                    ELSE '60+' END AS bucket
        FROM agg a
    )
    SELECT f.student_id, f.student_name, f.admission_no, f.class_name, f.section, f.roll_no,
           f.mobile, f.parent_email,
           f.total_outstanding, f.overdue_days, f.bucket,
           lr.sent_at                   AS last_reminder_at,
           COUNT(*)               OVER() AS total_count,
           SUM(f.total_outstanding) OVER() AS sum_outstanding
    FROM filtered f
    -- Most recent DELIVERED reminder for this student (drives the "Last" column).
    LEFT JOIN LATERAL (
        SELECT r.sent_at
        FROM core.fee_reminder_log r
        WHERE r.tenant_id = p_tenant_id AND r.school_id = p_school_id
          AND r.student_id = f.student_id
          AND COALESCE(r.channels_delivered, '') <> ''
        ORDER BY r.sent_at DESC
        LIMIT 1
    ) lr ON TRUE
    WHERE (p_bucket IS NULL OR TRIM(p_bucket) = '' OR f.bucket = p_bucket)
    ORDER BY
        CASE WHEN v_col = 'name'  AND v_asc     THEN student_name END ASC  NULLS LAST,
        CASE WHEN v_col = 'name'  AND NOT v_asc THEN student_name END DESC NULLS LAST,
        CASE WHEN v_col = 'class' AND v_asc     THEN class_name END ASC  NULLS LAST,
        CASE WHEN v_col = 'class' AND NOT v_asc THEN class_name END DESC NULLS LAST,
        CASE WHEN v_col = 'due'   AND v_asc     THEN total_outstanding END ASC,
        CASE WHEN v_col = 'due'   AND NOT v_asc THEN total_outstanding END DESC,
        CASE WHEN v_col = 'days'  AND v_asc     THEN overdue_days END ASC,
        CASE WHEN v_col = 'days'  AND NOT v_asc THEN overdue_days END DESC,
        total_outstanding DESC, student_name   -- stable default: biggest dues first
    LIMIT p_page_size OFFSET v_offset;
END;
$procedure$;
