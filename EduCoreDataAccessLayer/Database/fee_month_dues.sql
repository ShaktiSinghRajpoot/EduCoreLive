-- ============================================================================
-- Month-wise fee dues (19 Oct 2026): what is still unpaid, month by month, for
-- the office that chases fees.
--
-- A fee line belongs to the month of its due date (a monthly tuition line is its
-- month; a one-time admission fee is the month it fell due; no due date = the
-- session's first month). Outstanding is the usual amount_due - amount_paid -
-- concession, so closed / written-off lines read 0. Lines carried from an older
-- session count where they are carried to (their academic_year).
--
-- "May have left": a child with no Present / Late mark in the last 21 days while
-- their class's attendance WAS taken on at least 5 of those days (so a holiday,
-- or a class whose register is not kept, raises no flag).
--
--   core.sp_fee_month_dues            one session, dues from / up to a month, class / section
--     cursor 1  months    month, due, collected, pending, children
--     cursor 2  classes   class, section, children, with dues, pending
--     cursor 3  students  one row per child with something pending (and the flag)
--   core.sp_student_attendance_brief  one child: month by month, last present, streak
-- ============================================================================

-- 19 Oct 2026: a "from" month was added; drop the first version so no overload is left behind
DROP PROCEDURE IF EXISTS core.sp_fee_month_dues(integer, integer, integer, varchar, varchar, varchar, varchar, refcursor, refcursor, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_fee_month_dues(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_academic_year  varchar,
    IN    p_from_month     varchar DEFAULT NULL,   -- 'YYYY-MM': dues falling due from the start of it; empty = from the beginning
    IN    p_upto_month     varchar DEFAULT NULL,   -- 'YYYY-MM': dues falling due up to the end of it; empty = this month
    IN    p_class          varchar DEFAULT NULL,
    IN    p_section        varchar DEFAULT NULL,
    INOUT p_months         refcursor DEFAULT 'fmd_months'::refcursor,
    INOUT p_classes        refcursor DEFAULT 'fmd_classes'::refcursor,
    INOUT p_students       refcursor DEFAULT 'fmd_students'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_upto  date;
    v_from  date;
    v_start date;
    v_class varchar := NULLIF(trim(COALESCE(p_class, '')), '');
    v_sec   varchar := NULLIF(trim(COALESCE(p_section, '')), '');
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;
    IF NULLIF(trim(p_academic_year), '') IS NULL THEN
        RAISE EXCEPTION 'Choose the session.';
    END IF;

    -- the last day of the chosen month (default: this month)
    v_upto := (date_trunc('month', COALESCE(to_date(NULLIF(trim(p_upto_month), ''), 'YYYY-MM'), CURRENT_DATE))
               + interval '1 month - 1 day')::date;
    -- the session's first day, for lines without a due date
    SELECT NULLIF(y.start_date, '')::date INTO v_start
      FROM academic.academic_years y
     WHERE y.tenant_id = p_tenant_id AND y.school_id = p_school_id AND y.academic_year_name = p_academic_year
     LIMIT 1;
    v_start := COALESCE(v_start, date_trunc('month', CURRENT_DATE)::date);
    v_from := COALESCE(to_date(NULLIF(trim(p_from_month), ''), 'YYYY-MM'), DATE '1900-01-01');
    IF v_from > v_upto THEN
        RAISE EXCEPTION 'The "from" month is after the "to" month.';
    END IF;

    DROP TABLE IF EXISTS _fmd_kids;
    CREATE TEMP TABLE _fmd_kids ON COMMIT DROP AS
    SELECT s.student_id, s.public_id, s.student_name, s.admission_no, s.guardian_name, s.mobile,
           COALESCE(e.class_name, s.class_name) AS class_name, COALESCE(e.section, s.section) AS section,
           COALESCE(NULLIF(trim(e.roll_no), ''), s.roll_no) AS roll_no,
           CASE WHEN e.status IN ('Left', 'PassedOut') THEN e.status
                WHEN NOT COALESCE(s.is_active, TRUE) THEN COALESCE(NULLIF(s.status, ''), 'Left')
                ELSE 'Active' END AS kid_status
      FROM core.students s
      LEFT JOIN core.student_enrolment e ON e.student_id = s.student_id AND e.academic_year = p_academic_year
     WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id
       AND (e.student_id IS NOT NULL
            OR EXISTS (SELECT 1 FROM core.student_ledger l WHERE l.student_id = s.student_id AND l.academic_year = p_academic_year))
       AND (v_class IS NULL OR COALESCE(e.class_name, s.class_name) = v_class)
       AND (v_sec   IS NULL OR COALESCE(e.section, s.section) = v_sec);

    DROP TABLE IF EXISTS _fmd_lines;
    CREATE TEMP TABLE _fmd_lines ON COMMIT DROP AS
    SELECT l.student_id,
           date_trunc('month', COALESCE(NULLIF(l.due_date, '')::date, v_start))::date AS month,
           l.amount_due, l.amount_paid + l.concession AS settled,
           GREATEST(l.amount_due - l.amount_paid - l.concession, 0) AS pending
      FROM core.student_ledger l
      JOIN _fmd_kids k ON k.student_id = l.student_id
     WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
       AND l.academic_year = p_academic_year
       AND COALESCE(NULLIF(l.due_date, '')::date, v_start) BETWEEN v_from AND v_upto;

    OPEN p_months FOR
    SELECT to_char(month, 'YYYY-MM') AS month, SUM(amount_due) AS due, SUM(settled) AS collected,
           SUM(pending) AS pending, COUNT(DISTINCT student_id) FILTER (WHERE pending > 0)::int AS children
      FROM _fmd_lines GROUP BY month ORDER BY month;

    OPEN p_classes FOR
    SELECT k.class_name, COALESCE(k.section, '') AS section, COUNT(*)::int AS children,
           COUNT(*) FILTER (WHERE p.pending > 0)::int AS with_dues, COALESCE(SUM(p.pending), 0) AS pending
      FROM _fmd_kids k
      LEFT JOIN (SELECT student_id, SUM(pending) AS pending FROM _fmd_lines GROUP BY student_id) p ON p.student_id = k.student_id
     GROUP BY k.class_name, k.section
     ORDER BY COALESCE((SELECT MIN(c.display_order) FROM academic.academic_classes c
                          JOIN academic.academic_years y ON y.academic_year_id = c.academic_year_id
                         WHERE c.tenant_id = p_tenant_id AND c.school_id = p_school_id
                           AND y.academic_year_name = p_academic_year AND c.class_name = k.class_name
                           AND NOT COALESCE(c.is_deleted, FALSE)), 999),
              k.class_name, k.section;

    OPEN p_students FOR
    WITH pend AS (
        SELECT student_id, SUM(pending) AS pending,
               COUNT(DISTINCT month) FILTER (WHERE pending > 0)::int AS months_count,
               string_agg(DISTINCT to_char(month, 'YYYY-MM'), ',') FILTER (WHERE pending > 0) AS months,
               MIN(month) FILTER (WHERE pending > 0) AS oldest
          FROM _fmd_lines GROUP BY student_id
        HAVING SUM(pending) > 0
    ), att AS (
        -- the last 21 days: days the child's class register was taken, and the child's own present days
        SELECT k.student_id,
               (SELECT MAX(a.attendance_date) FROM core.student_attendance a
                 WHERE a.student_id = k.student_id AND a.status IN ('Present', 'Late')) AS last_present,
               (SELECT COUNT(DISTINCT a.attendance_date) FROM core.student_attendance a
                 WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
                   AND a.class_name = k.class_name AND COALESCE(a.section, '') = COALESCE(k.section, '')
                   AND a.attendance_date >= to_char(CURRENT_DATE - 21, 'YYYY-MM-DD'))::int AS class_days,
               (SELECT COUNT(*) FROM core.student_attendance a
                 WHERE a.student_id = k.student_id AND a.status IN ('Present', 'Late')
                   AND a.attendance_date >= to_char(CURRENT_DATE - 21, 'YYYY-MM-DD'))::int AS present_days
          FROM _fmd_kids k
         WHERE k.student_id IN (SELECT student_id FROM pend)
    )
    SELECT k.student_id, k.public_id, k.student_name, COALESCE(k.admission_no, '') AS admission_no,
           COALESCE(k.guardian_name, '') AS guardian_name, COALESCE(k.mobile, '') AS mobile,
           k.class_name, COALESCE(k.section, '') AS section, COALESCE(k.roll_no, '') AS roll_no, k.kid_status,
           p.pending, p.months_count, COALESCE(p.months, '') AS months, to_char(p.oldest, 'YYYY-MM') AS oldest_month,
           COALESCE((SELECT MAX(fp.payment_date) FROM core.fee_payments fp
                      WHERE fp.student_id = k.student_id AND NOT COALESCE(fp.is_cancelled, FALSE)), '') AS last_payment,
           COALESCE(a.last_present, '') AS last_present, a.class_days, a.present_days,
           (k.kid_status = 'Active' AND a.class_days >= 5 AND a.present_days = 0) AS may_have_left
      FROM pend p
      JOIN _fmd_kids k ON k.student_id = p.student_id
      LEFT JOIN att a ON a.student_id = p.student_id
     ORDER BY p.pending DESC, k.student_name;
END;
$procedure$;


-- One child's attendance in a session: month by month, the last day present, and
-- the absent streak up to the latest marked day.
CREATE OR REPLACE PROCEDURE core.sp_student_attendance_brief(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_student_id     integer,
    IN    p_academic_year  varchar,
    INOUT p_summary        refcursor DEFAULT 'sab_summary'::refcursor,
    INOUT p_months         refcursor DEFAULT 'sab_months'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_last_present varchar;
    v_streak       integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM core.students WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id) THEN
        RAISE EXCEPTION 'Student not found.';
    END IF;

    SELECT MAX(attendance_date) INTO v_last_present FROM core.student_attendance
     WHERE student_id = p_student_id AND status IN ('Present', 'Late');
    -- marked days after the last present day: all of them are absences or leave
    SELECT COUNT(*) INTO v_streak FROM core.student_attendance
     WHERE student_id = p_student_id AND (v_last_present IS NULL OR attendance_date > v_last_present);

    OPEN p_summary FOR
    SELECT s.student_name, COALESCE(v_last_present, '') AS last_present, v_streak AS absent_streak,
           (SELECT MAX(attendance_date) FROM core.student_attendance WHERE student_id = p_student_id) AS last_marked,
           (SELECT COUNT(*) FROM core.student_attendance WHERE student_id = p_student_id AND academic_year = p_academic_year)::int AS marked,
           (SELECT COUNT(*) FROM core.student_attendance WHERE student_id = p_student_id AND academic_year = p_academic_year
                                                          AND status IN ('Present', 'Late'))::int AS present
      FROM core.students s WHERE s.student_id = p_student_id;

    OPEN p_months FOR
    SELECT left(attendance_date, 7) AS month,
           COUNT(*) FILTER (WHERE status IN ('Present', 'Late'))::int AS present,
           COUNT(*) FILTER (WHERE status = 'Absent')::int AS absent,
           COUNT(*) FILTER (WHERE status = 'Leave')::int AS on_leave
      FROM core.student_attendance
     WHERE student_id = p_student_id AND academic_year = p_academic_year
     GROUP BY left(attendance_date, 7)
     ORDER BY 1;
END;
$procedure$;
