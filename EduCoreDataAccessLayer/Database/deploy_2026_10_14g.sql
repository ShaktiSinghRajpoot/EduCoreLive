-- Bundle 2026-10-14g: Fee Dashboard + Attendance Overview (both read-only). Run with:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_14g.sql
-- Sources: fee_dashboard.sql, attendance_overview.sql.

-- ============================================================================
-- Fee Dashboard (Fee › Fee Dashboard). Read-only.
--
-- Money in uses core.fn_fee_money_lines (the Day Close / Collection Register
-- rule: a cancellation counts on the day it is made); "Advance" (paid from the
-- wallet) and "To wallet" lines are left out, so collected = money received.
-- Dues come from core.student_ledger:
--     billed      = amount_due - concession
--     outstanding = amount_due - amount_paid - concession   (closed rows read 0)
-- A row with no due date counts as due. "This session" = the current academic
-- year; dues of older sessions still owed are "Old dues".
--
-- Cursors:
--   summary   one row of headline figures
--   months    per due month of the session: billed, paid
--   daily     last 30 days of money in
--   modes     this month's money in by mode
--   staff     this month's money in by the staff member who took it, by mode
--   classes   per class / section (with class teacher): billed due, paid, overdue, students owing
--   matrix    class x fee head: billed due, paid
--   heads     per fee head: collected (session), overdue, not yet due
--   families  families (siblings share the guardian's mobile) owing the most, with their habit
--   given     money given away: concessions, written off, counter discount and voids, by staff
--   problems  billing checks (no price set, class without a fee structure, students never billed)
-- Re-runnable.
-- ============================================================================

CREATE OR REPLACE PROCEDURE core.sp_fee_dashboard(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    INOUT p_summary        refcursor DEFAULT 'fd_summary',
    INOUT p_months         refcursor DEFAULT 'fd_months',
    INOUT p_daily          refcursor DEFAULT 'fd_daily',
    INOUT p_modes          refcursor DEFAULT 'fd_modes',
    INOUT p_staff          refcursor DEFAULT 'fd_staff',
    INOUT p_classes        refcursor DEFAULT 'fd_classes',
    INOUT p_matrix         refcursor DEFAULT 'fd_matrix',
    INOUT p_heads          refcursor DEFAULT 'fd_heads',
    INOUT p_families       refcursor DEFAULT 'fd_families',
    INOUT p_given          refcursor DEFAULT 'fd_given',
    INOUT p_problems       refcursor DEFAULT 'fd_problems')
LANGUAGE plpgsql
AS $$
DECLARE
    v_year    varchar;
    v_today   date := CURRENT_DATE;
    v_month1  date := date_trunc('month', CURRENT_DATE)::date;
    v_prev1   date := (date_trunc('month', CURRENT_DATE) - interval '1 month')::date;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    SELECT y.academic_year_name INTO v_year
      FROM academic.academic_years y
     WHERE y.tenant_id = p_tenant_id AND y.school_id = p_school_id
       AND COALESCE(y.is_current, FALSE) AND NOT COALESCE(y.is_deleted, FALSE)
     LIMIT 1;

    -- every ledger line, with what is billed / paid / owed and who owes it
    CREATE TEMP TABLE IF NOT EXISTS tmp_fd (
        ledger_id int, student_id int, class_name varchar, section varchar, fee_head varchar,
        due_on date, billed numeric, paid numeric, owed numeric, in_session boolean, active boolean,
        family varchar, guardian varchar, student_name varchar) ON COMMIT DROP;
    TRUNCATE tmp_fd;
    INSERT INTO tmp_fd
    SELECT l.ledger_id, l.student_id, s.class_name, COALESCE(s.section, ''), l.fee_head_name,
           NULLIF(l.due_date, '')::date,
           l.amount_due - l.concession, l.amount_paid,
           GREATEST(l.amount_due - l.amount_paid - l.concession, 0),
           lower(COALESCE(NULLIF(trim(l.academic_year), ''), s.academic_year)) = lower(COALESCE(v_year, '')),
           COALESCE(s.is_active, TRUE),
           COALESCE(NULLIF(regexp_replace(COALESCE(s.mobile, ''), '\D', '', 'g'), ''), 'S' || s.student_id),
           COALESCE(NULLIF(trim(s.guardian_name), ''), s.student_name), s.student_name
      FROM core.student_ledger l
      JOIN core.students s ON s.student_id = l.student_id AND s.tenant_id = p_tenant_id AND s.school_id = p_school_id
     WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id;

    -- money in, last 90 days and this month (fn_fee_money_lines rule)
    CREATE TEMP TABLE IF NOT EXISTS tmp_fd_money (payment_id int, user_id int, line_date date, mode varchar, amount numeric) ON COMMIT DROP;
    TRUNCATE tmp_fd_money;
    INSERT INTO tmp_fd_money
    SELECT m.payment_id, m.user_id, m.line_date, m.mode, m.amount
      FROM core.fn_fee_money_lines(p_tenant_id, p_school_id, LEAST(v_prev1, v_today - 30), v_today) m
     WHERE m.mode NOT IN ('Advance', 'To wallet');

    -- family habit, from when each family paid its lines (fee_payment_details -> payment date)
    CREATE TEMP TABLE IF NOT EXISTS tmp_fd_habit (family varchar PRIMARY KEY, habit varchar) ON COMMIT DROP;
    TRUNCATE tmp_fd_habit;
    INSERT INTO tmp_fd_habit
    SELECT f.family,
           CASE WHEN f.oldest_overdue > 60 THEN 'Habitual defaulter'
                WHEN f.paid_lines >= 2 AND f.late_lines * 2 > f.paid_lines THEN 'Pays late'
                WHEN f.paid_lines >= 2 THEN 'Pays on time'
                ELSE 'Too new to tell' END
      FROM (
        SELECT t.family,
               MAX(CASE WHEN t.owed > 0 AND t.due_on IS NOT NULL AND t.due_on <= v_today THEN v_today - t.due_on ELSE 0 END) AS oldest_overdue,
               COUNT(DISTINCT d.detail_id) FILTER (WHERE d.detail_id IS NOT NULL)                                       AS paid_lines,
               COUNT(DISTINCT d.detail_id) FILTER (WHERE p.payment_date::date > t.due_on + 15)                           AS late_lines
          FROM tmp_fd t
          LEFT JOIN core.fee_payment_details d ON d.ledger_id = t.ledger_id
          LEFT JOIN core.fee_payments p ON p.payment_id = d.payment_id AND NOT COALESCE(p.is_cancelled, FALSE)
         GROUP BY t.family) f;

    -- ── summary
    OPEN p_summary FOR
    SELECT v_year AS session,
           (SELECT COALESCE(SUM(billed), 0) FROM tmp_fd WHERE in_session)                                               AS billed_session,
           (SELECT COALESCE(SUM(billed), 0) FROM tmp_fd WHERE in_session AND COALESCE(due_on, v_today) <= v_today)      AS billed_due,
           (SELECT COALESCE(SUM(paid), 0)   FROM tmp_fd WHERE in_session AND COALESCE(due_on, v_today) <= v_today)      AS paid_due,
           (SELECT COALESCE(SUM(paid), 0)   FROM tmp_fd WHERE in_session)                                               AS paid_session,
           (SELECT COALESCE(SUM(owed), 0)   FROM tmp_fd WHERE COALESCE(due_on, v_today) <= v_today)                     AS overdue,
           (SELECT COUNT(DISTINCT family)   FROM tmp_fd WHERE owed > 0 AND COALESCE(due_on, v_today) <= v_today)        AS overdue_families,
           (SELECT COALESCE(SUM(owed), 0)   FROM tmp_fd WHERE due_on > v_today)                                         AS not_yet_due,
           (SELECT COALESCE(SUM(owed), 0)   FROM tmp_fd WHERE due_on > v_today AND due_on <= v_today + 10)              AS due_next_10,
           (SELECT COUNT(DISTINCT family)   FROM tmp_fd WHERE owed > 0 AND due_on > v_today AND due_on <= v_today + 10) AS due_next_10_families,
           (SELECT COALESCE(SUM(owed), 0)   FROM tmp_fd WHERE owed > 0 AND (NOT active OR v_today - COALESCE(due_on, v_today) > 180)) AS likely_lost,
           (SELECT COALESCE(SUM(owed), 0)   FROM tmp_fd WHERE owed > 0 AND active AND v_today - COALESCE(due_on, v_today) BETWEEN 91 AND 180) AS doubtful,
           (SELECT COALESCE(SUM(owed), 0)   FROM tmp_fd WHERE owed > 0 AND active AND v_today - COALESCE(due_on, v_today) BETWEEN 31 AND 90)  AS at_risk,
           (SELECT COALESCE(SUM(owed), 0)   FROM tmp_fd WHERE owed > 0 AND active AND v_today - COALESCE(due_on, v_today) <= 30)              AS safe,
           (SELECT COALESCE(SUM(owed), 0)   FROM tmp_fd WHERE owed > 0 AND COALESCE(due_on, v_today) <= v_today AND v_today - COALESCE(due_on, v_today) <= 30) AS age_0_30,
           (SELECT COALESCE(SUM(owed), 0)   FROM tmp_fd WHERE owed > 0 AND v_today - due_on BETWEEN 31 AND 60)          AS age_31_60,
           (SELECT COALESCE(SUM(owed), 0)   FROM tmp_fd WHERE owed > 0 AND v_today - due_on BETWEEN 61 AND 90)          AS age_61_90,
           (SELECT COALESCE(SUM(owed), 0)   FROM tmp_fd WHERE owed > 0 AND v_today - due_on > 90)                        AS age_90_plus,
           (SELECT COALESCE(SUM(amount), 0) FROM tmp_fd_money WHERE line_date >= v_month1)                              AS collected_month,
           (SELECT COUNT(DISTINCT payment_id) FROM tmp_fd_money WHERE line_date >= v_month1 AND amount > 0)              AS receipts_month,
           (SELECT COALESCE(SUM(amount), 0) FROM tmp_fd_money WHERE line_date >= v_prev1 AND line_date < v_month1)       AS collected_prev_month,
           (SELECT COALESCE(SUM(amount), 0) FROM tmp_fd_money WHERE line_date = v_today)                                AS collected_today,
           (SELECT COUNT(*) FROM tmp_fd_habit WHERE habit = 'Pays on time')       AS fam_on_time,
           (SELECT COUNT(*) FROM tmp_fd_habit WHERE habit = 'Pays late')          AS fam_late,
           (SELECT COUNT(*) FROM tmp_fd_habit WHERE habit = 'Habitual defaulter') AS fam_defaulter,
           (SELECT COUNT(*) FROM tmp_fd_habit WHERE habit = 'Too new to tell')    AS fam_new;

    -- ── months of the session (by due month)
    OPEN p_months FOR
    SELECT to_char(date_trunc('month', COALESCE(due_on, v_today)), 'YYYY-MM') AS month,
           SUM(billed) AS billed, SUM(paid) AS paid, SUM(owed) AS owed
      FROM tmp_fd WHERE in_session
     GROUP BY 1 ORDER BY 1;

    -- ── last 30 days of money in
    OPEN p_daily FOR
    SELECT to_char(d, 'YYYY-MM-DD') AS day,
           COALESCE((SELECT SUM(m.amount) FROM tmp_fd_money m WHERE m.line_date = d::date), 0) AS amount
      FROM generate_series(v_today - 29, v_today, interval '1 day') d
     ORDER BY d;

    -- ── this month by mode
    OPEN p_modes FOR
    SELECT mode, SUM(amount) AS amount FROM tmp_fd_money WHERE line_date >= v_month1
     GROUP BY mode HAVING SUM(amount) <> 0 ORDER BY SUM(amount) DESC;

    -- ── this month by staff member and mode
    OPEN p_staff FOR
    SELECT core.fn_user_display_name(user_id) AS staff, mode, SUM(amount) AS amount
      FROM tmp_fd_money WHERE line_date >= v_month1
     GROUP BY user_id, mode HAVING SUM(amount) <> 0 ORDER BY 1, 2;

    -- ── classes / sections with the class teacher (session dues that are due)
    OPEN p_classes FOR
    SELECT t.class_name, t.section,
           (SELECT st.full_name FROM academic.academic_class_sections sec
              JOIN academic.academic_classes c ON c.academic_class_id = sec.academic_class_id
              JOIN academic.academic_years y ON y.academic_year_id = c.academic_year_id
              JOIN core.staff st ON st.staff_id = sec.class_teacher_staff_id
             WHERE sec.tenant_id = p_tenant_id AND sec.school_id = p_school_id
               AND c.class_name = t.class_name AND lower(sec.section_name) = lower(t.section)
               AND lower(y.academic_year_name) = lower(COALESCE(v_year, ''))
             LIMIT 1) AS class_teacher,
           SUM(t.billed) FILTER (WHERE t.in_session AND COALESCE(t.due_on, v_today) <= v_today) AS billed_due,
           SUM(t.paid)   FILTER (WHERE t.in_session AND COALESCE(t.due_on, v_today) <= v_today) AS paid_due,
           SUM(t.owed)   FILTER (WHERE COALESCE(t.due_on, v_today) <= v_today)                  AS overdue,
           COUNT(DISTINCT t.student_id) FILTER (WHERE t.owed > 0 AND COALESCE(t.due_on, v_today) <= v_today) AS students_owing,
           COUNT(DISTINCT t.student_id) AS students
      FROM tmp_fd t
     WHERE t.active
     GROUP BY t.class_name, t.section
     ORDER BY t.class_name, t.section;

    -- ── class x fee head (session dues that are due)
    OPEN p_matrix FOR
    SELECT class_name, fee_head, SUM(billed) AS billed_due, SUM(paid) AS paid_due
      FROM tmp_fd
     WHERE in_session AND COALESCE(due_on, v_today) <= v_today
     GROUP BY class_name, fee_head
    HAVING SUM(billed) > 0
     ORDER BY class_name, fee_head;

    -- ── fee heads (older sessions' unpaid lines are "Old dues")
    OPEN p_heads FOR
    SELECT CASE WHEN in_session THEN fee_head ELSE 'Old dues' END AS fee_head,
           SUM(paid) FILTER (WHERE in_session)                                AS collected,
           SUM(owed) FILTER (WHERE COALESCE(due_on, v_today) <= v_today)      AS overdue,
           SUM(owed) FILTER (WHERE due_on > v_today)                          AS not_yet_due
      FROM tmp_fd
     GROUP BY 1
     ORDER BY COALESCE(SUM(owed) FILTER (WHERE COALESCE(due_on, v_today) <= v_today), 0) DESC;

    -- ── families owing the most (overdue), with their habit
    OPEN p_families FOR
    SELECT t.family, MAX(t.guardian) AS guardian,
           string_agg(DISTINCT t.student_name || ' (' || t.class_name || COALESCE(NULLIF('-' || t.section, '-'), '') || ')', ', ') AS children,
           SUM(t.owed) FILTER (WHERE COALESCE(t.due_on, v_today) <= v_today) AS overdue,
           SUM(t.paid) AS paid,
           MAX(CASE WHEN t.owed > 0 AND COALESCE(t.due_on, v_today) <= v_today THEN v_today - COALESCE(t.due_on, v_today) END) AS oldest_days,
           h.habit
      FROM tmp_fd t
      LEFT JOIN tmp_fd_habit h ON h.family = t.family
     GROUP BY t.family, h.habit
    HAVING SUM(t.owed) FILTER (WHERE COALESCE(t.due_on, v_today) <= v_today) > 0
     ORDER BY 4 DESC
     LIMIT 25;

    -- ── money given away this session
    OPEN p_given FOR
    SELECT 'Concession'::varchar AS kind, NULL::varchar AS staff,
           COALESCE((SELECT SUM(l.concession) FROM core.student_ledger l JOIN tmp_fd t ON t.ledger_id = l.ledger_id WHERE t.in_session), 0) AS amount,
           NULL::int AS cnt
    UNION ALL
    SELECT 'Written off', NULL,
           COALESCE((SELECT SUM(l.closed_amount) FROM core.student_ledger l JOIN tmp_fd t ON t.ledger_id = l.ledger_id
                      WHERE t.in_session AND l.close_source = 'YearEnd'), 0), NULL
    UNION ALL
    SELECT 'Counter discount', core.fn_user_display_name(p.created_by), SUM(p.discount_amount), COUNT(*)::int
      FROM core.fee_payments p
     WHERE p.tenant_id = p_tenant_id AND p.school_id = p_school_id AND NOT COALESCE(p.is_cancelled, FALSE)
       AND COALESCE(p.discount_amount, 0) > 0 AND p.payment_date >= to_char(v_today - 365, 'YYYY-MM-DD')
     GROUP BY p.created_by
    UNION ALL
    SELECT 'Voided receipt', core.fn_user_display_name(COALESCE(p.cancelled_by, p.created_by)), SUM(p.amount), COUNT(*)::int
      FROM core.fee_payments p
     WHERE p.tenant_id = p_tenant_id AND p.school_id = p_school_id AND COALESCE(p.is_cancelled, FALSE)
       AND COALESCE(p.cancelled_at::date, p.payment_date::date) >= v_today - 365
     GROUP BY COALESCE(p.cancelled_by, p.created_by);

    -- ── billing checks
    OPEN p_problems FOR
    SELECT 'No price set'::varchar AS kind,
           fs.class_name || ': ' || string_agg(d.fee_head_name, ', ' ORDER BY d.fee_head_name) AS detail,
           COUNT(*)::int AS cnt
      FROM core.school_fee_structures fs
      JOIN core.school_fee_structure_details d ON d.fee_structure_id = fs.fee_structure_id
     WHERE fs.tenant_id = p_tenant_id AND fs.school_id = p_school_id
       AND NOT COALESCE(fs.is_deleted, FALSE) AND COALESCE(fs.is_active, TRUE)
       AND lower(fs.academic_year) = lower(COALESCE(v_year, ''))
       AND COALESCE(d.is_selected, TRUE) AND NOT COALESCE(d.is_deleted, FALSE) AND COALESCE(d.amount, 0) = 0
     GROUP BY fs.class_name
    UNION ALL
    SELECT 'No fee structure', c.class_name, (SELECT COUNT(*) FROM core.students s
                                              WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id AND COALESCE(s.is_active, TRUE)
                                                AND s.class_name = c.class_name AND lower(s.academic_year) = lower(COALESCE(v_year, '')))::int
      FROM academic.academic_classes c
      JOIN academic.academic_years y ON y.academic_year_id = c.academic_year_id
     WHERE c.tenant_id = p_tenant_id AND c.school_id = p_school_id AND NOT COALESCE(c.is_deleted, FALSE)
       AND lower(y.academic_year_name) = lower(COALESCE(v_year, ''))
       AND EXISTS (SELECT 1 FROM core.students s WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id
                     AND COALESCE(s.is_active, TRUE) AND s.class_name = c.class_name AND lower(s.academic_year) = lower(COALESCE(v_year, '')))
       AND NOT EXISTS (SELECT 1 FROM core.school_fee_structures fs
                        WHERE fs.tenant_id = p_tenant_id AND fs.school_id = p_school_id AND fs.class_name = c.class_name
                          AND lower(fs.academic_year) = lower(COALESCE(v_year, '')) AND NOT COALESCE(fs.is_deleted, FALSE))
    UNION ALL
    SELECT 'Never billed', string_agg(s.student_name || ' (' || s.class_name || ')', ', ' ORDER BY s.student_name), COUNT(*)::int
      FROM core.students s
     WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id AND COALESCE(s.is_active, TRUE)
       AND lower(s.academic_year) = lower(COALESCE(v_year, ''))
       AND NOT EXISTS (SELECT 1 FROM tmp_fd t WHERE t.student_id = s.student_id AND t.in_session)
    HAVING COUNT(*) > 0;
END;
$$;


-- ============================================================================
-- Attendance Overview (Attendance › Overview). Read-only.
--
-- A REGISTER is one class section's attendance on one school working day
-- (core.fn_school_working_days > 0 for that date). It is "taken" when at least
-- one student of the section has a mark that day. The class teacher of the
-- section (academic_class_sections.class_teacher_staff_id) is the one
-- responsible for it. Only sections of the current session that have students
-- count, and only days from the session start up to today.
--
--   p_day   (Today tab) cursor 1 sections: every section with that day's counts
--                                          (present / absent / late / leave), who marked it
--   p_from..p_to (Insights) cursor 2 sections: expected / taken registers, student-days
--                                              marked and present, registers taken the same day
--                            cursor 3 weeks:    the same per week
--                            cursor 4 missing:  every register not taken, newest first
--   cursor 5 day: whether p_day is a working day / the calendar's note
-- Present = Present or Late.
-- Re-runnable.
-- ============================================================================

CREATE OR REPLACE PROCEDURE core.sp_attendance_overview(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_day            date,
    IN    p_from           date,
    IN    p_to             date,
    INOUT p_today          refcursor DEFAULT 'ao_today',
    INOUT p_sections       refcursor DEFAULT 'ao_sections',
    INOUT p_weeks          refcursor DEFAULT 'ao_weeks',
    INOUT p_missing        refcursor DEFAULT 'ao_missing',
    INOUT p_dayinfo        refcursor DEFAULT 'ao_day')
LANGUAGE plpgsql
AS $$
DECLARE
    v_year_id integer;
    v_year    varchar;
    v_start   date;
    v_from    date;
    v_to      date;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    SELECT y.academic_year_id, y.academic_year_name, NULLIF(y.start_date::text, '')::date
      INTO v_year_id, v_year, v_start
      FROM academic.academic_years y
     WHERE y.tenant_id = p_tenant_id AND y.school_id = p_school_id
       AND COALESCE(y.is_current, FALSE) AND NOT COALESCE(y.is_deleted, FALSE)
     LIMIT 1;

    v_from := GREATEST(COALESCE(p_from, CURRENT_DATE - 29), COALESCE(v_start, p_from, CURRENT_DATE - 29));
    v_to   := LEAST(COALESCE(p_to, CURRENT_DATE), CURRENT_DATE);

    -- the session's sections that have students, with their class teacher
    CREATE TEMP TABLE IF NOT EXISTS tmp_ao_sec (section_id int PRIMARY KEY, class_name varchar, section varchar,
                                                display_order int, students int, teacher_id int, teacher varchar) ON COMMIT DROP;
    TRUNCATE tmp_ao_sec;
    INSERT INTO tmp_ao_sec
    SELECT x.* FROM (
        SELECT sec.academic_class_section_id, c.class_name, sec.section_name, COALESCE(c.display_order, 0),
               (SELECT COUNT(*) FROM core.students s
                 WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id AND COALESCE(s.is_active, TRUE)
                   AND s.class_name = c.class_name AND lower(COALESCE(s.section, '')) = lower(sec.section_name)
                   AND s.academic_year = v_year)::int AS students,
               sec.class_teacher_staff_id, st.full_name
          FROM academic.academic_class_sections sec
          JOIN academic.academic_classes c ON c.academic_class_id = sec.academic_class_id
          LEFT JOIN core.staff st ON st.staff_id = sec.class_teacher_staff_id
         WHERE sec.tenant_id = p_tenant_id AND sec.school_id = p_school_id AND sec.academic_year_id = v_year_id
           AND NOT COALESCE(sec.is_deleted, FALSE) AND NOT COALESCE(c.is_deleted, FALSE)) x
     WHERE x.students > 0;

    -- working days in the range
    CREATE TEMP TABLE IF NOT EXISTS tmp_ao_days (d date PRIMARY KEY) ON COMMIT DROP;
    TRUNCATE tmp_ao_days;
    IF v_from <= v_to THEN
        INSERT INTO tmp_ao_days
        SELECT g::date FROM generate_series(v_from, v_to, interval '1 day') g
         WHERE core.fn_school_working_days(p_tenant_id, p_school_id, g::date, g::date) > 0;
    END IF;

    -- registers actually taken in the range: section x date, with counts
    CREATE TEMP TABLE IF NOT EXISTS tmp_ao_reg (section_id int, d date, marked int, present int, same_day boolean) ON COMMIT DROP;
    TRUNCATE tmp_ao_reg;
    INSERT INTO tmp_ao_reg
    SELECT ts.section_id, a.attendance_date::date, COUNT(*)::int,
           COUNT(*) FILTER (WHERE a.status IN ('Present', 'Late'))::int,
           MIN(a.marked_at)::date <= a.attendance_date::date
      FROM core.student_attendance a
      JOIN tmp_ao_sec ts ON ts.class_name = a.class_name AND lower(ts.section) = lower(COALESCE(a.section, ''))
     WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id AND a.academic_year = v_year
       AND a.attendance_date BETWEEN to_char(v_from, 'YYYY-MM-DD') AND to_char(v_to, 'YYYY-MM-DD')
     GROUP BY ts.section_id, a.attendance_date;

    -- ── Today: every section with that day's marks
    OPEN p_today FOR
    SELECT ts.section_id, ts.class_name, ts.section, ts.display_order, ts.students, ts.teacher_id, ts.teacher,
           COUNT(a.attendance_id)::int                                         AS marked,
           COUNT(*) FILTER (WHERE a.status = 'Present')::int                   AS present,
           COUNT(*) FILTER (WHERE a.status = 'Absent')::int                    AS absent,
           COUNT(*) FILTER (WHERE a.status = 'Late')::int                      AS late,
           COUNT(*) FILTER (WHERE a.status = 'Leave')::int                     AS leave,
           core.fn_user_display_name(MIN(a.marked_by))                         AS marked_by,
           MIN(a.marked_at)                                                    AS marked_at
      FROM tmp_ao_sec ts
      LEFT JOIN core.student_attendance a
             ON a.tenant_id = p_tenant_id AND a.school_id = p_school_id AND a.academic_year = v_year
            AND a.class_name = ts.class_name AND lower(COALESCE(a.section, '')) = lower(ts.section)
            AND a.attendance_date = to_char(COALESCE(p_day, CURRENT_DATE), 'YYYY-MM-DD')
     GROUP BY ts.section_id, ts.class_name, ts.section, ts.display_order, ts.students, ts.teacher_id, ts.teacher
     ORDER BY ts.display_order, ts.class_name, ts.section;

    -- ── Insights per section
    OPEN p_sections FOR
    SELECT ts.section_id, ts.class_name, ts.section, ts.display_order, ts.students, ts.teacher_id, ts.teacher,
           (SELECT COUNT(*) FROM tmp_ao_days)::int                                                  AS expected,
           (SELECT COUNT(*) FROM tmp_ao_reg r JOIN tmp_ao_days dd ON dd.d = r.d WHERE r.section_id = ts.section_id)::int AS taken,
           (SELECT COUNT(*) FROM tmp_ao_reg r JOIN tmp_ao_days dd ON dd.d = r.d WHERE r.section_id = ts.section_id AND r.same_day)::int AS same_day,
           (SELECT COALESCE(SUM(r.marked), 0) FROM tmp_ao_reg r WHERE r.section_id = ts.section_id)::int  AS marked,
           (SELECT COALESCE(SUM(r.present), 0) FROM tmp_ao_reg r WHERE r.section_id = ts.section_id)::int AS present
      FROM tmp_ao_sec ts
     ORDER BY ts.display_order, ts.class_name, ts.section;

    -- ── week by week (week starting Monday)
    OPEN p_weeks FOR
    SELECT to_char(w.wk, 'YYYY-MM-DD') AS week_start, w.first_day::text AS first_day, w.last_day::text AS last_day,
           (w.days * (SELECT COUNT(*) FROM tmp_ao_sec))::int AS expected,
           (SELECT COUNT(*) FROM tmp_ao_reg r JOIN tmp_ao_days dd ON dd.d = r.d WHERE date_trunc('week', r.d) = w.wk)::int AS taken,
           (SELECT COALESCE(SUM(r.marked), 0) FROM tmp_ao_reg r WHERE date_trunc('week', r.d) = w.wk)::int AS marked,
           (SELECT COALESCE(SUM(r.present), 0) FROM tmp_ao_reg r WHERE date_trunc('week', r.d) = w.wk)::int AS present
      FROM (SELECT date_trunc('week', d) AS wk, MIN(d) AS first_day, MAX(d) AS last_day, COUNT(*) AS days
              FROM tmp_ao_days GROUP BY 1) w
     ORDER BY w.wk;

    -- ── registers never taken, newest first
    OPEN p_missing FOR
    SELECT to_char(dd.d, 'YYYY-MM-DD') AS day, ts.section_id, ts.class_name, ts.section, ts.teacher
      FROM tmp_ao_days dd
      CROSS JOIN tmp_ao_sec ts
     WHERE NOT EXISTS (SELECT 1 FROM tmp_ao_reg r WHERE r.section_id = ts.section_id AND r.d = dd.d)
     ORDER BY dd.d DESC, ts.display_order, ts.class_name, ts.section
     LIMIT 500;

    -- ── the chosen day
    OPEN p_dayinfo FOR
    SELECT core.fn_school_working_days(p_tenant_id, p_school_id, COALESCE(p_day, CURRENT_DATE), COALESCE(p_day, CURRENT_DATE)) AS working,
           (SELECT c.day_type || COALESCE(': ' || c.title, '') FROM academic.school_calendar c
             WHERE c.tenant_id = p_tenant_id AND c.school_id = p_school_id
               AND c.calendar_date = to_char(COALESCE(p_day, CURRENT_DATE), 'YYYY-MM-DD') LIMIT 1) AS note,
           to_char(v_from, 'YYYY-MM-DD') AS range_from, to_char(v_to, 'YYYY-MM-DD') AS range_to;
END;
$$;
