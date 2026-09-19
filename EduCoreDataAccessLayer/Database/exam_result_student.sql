-- ============================================================================
-- One student's exam results — the per-student view the Student Dashboard needs.
--
-- The exam module already answers "one sheet: this exam, this subject, this
-- section" (marks entry). This is the other axis: one student, every exam.
--
-- PUBLISHED EXAMS ONLY. academic.exams.status is 'Draft' until the school
-- publishes it, and a draft is a sheet the teacher is still typing into —
-- half-entered marks are not a result. The Marks Entry screen is where unpublished
-- work is seen; this is the parent-facing view.
--
-- ABSENT IS NOT ZERO. is_absent means the student did not sit the paper, which
-- is a different fact from scoring 0. An absent subject is reported as absent and
-- is left OUT of the totals and the percentage, so one missed paper does not read
-- as a failed one. The count of absences is returned so the page can say so.
--
-- Target DB: PostgreSQL. Safe to re-run.
-- ============================================================================

CREATE OR REPLACE PROCEDURE core.sp_exam_result_student(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_student_id     integer,
    IN    p_exam_id        integer DEFAULT NULL,   -- NULL = the most recent published exam
    INOUT p_exams          refcursor DEFAULT 'er_exams'::refcursor,
    INOUT p_marks          refcursor DEFAULT 'er_marks'::refcursor,
    INOUT p_summary        refcursor DEFAULT 'er_summary'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_exam_id integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR COALESCE(p_student_id, 0) <= 0 THEN
        OPEN p_exams   FOR SELECT NULL::int AS exam_id, NULL::text AS exam_name WHERE FALSE;
        OPEN p_marks   FOR SELECT NULL::text AS subject, NULL::numeric AS obtained WHERE FALSE;
        OPEN p_summary FOR SELECT 0 AS subjects, 0::numeric AS obtained, 0::numeric AS total,
                                  0::numeric AS percent, 0 AS absent_count, 0 AS failed_count;
        RETURN;
    END IF;

    -- ── 1. The published exams this student has marks in ────────────────────
    -- Driven off their own marks rather than the exam list, so an exam held for
    -- another class never appears on their dashboard.
    OPEN p_exams FOR
    SELECT DISTINCT e.exam_id, e.exam_name, e.exam_type, e.start_date
    FROM academic.exams e
    JOIN academic.exam_marks m ON m.exam_id = e.exam_id
    WHERE e.tenant_id = p_tenant_id AND e.school_id = p_school_id
      AND m.student_id = p_student_id
      AND COALESCE(e.is_deleted, FALSE) = FALSE
      AND e.status = 'Published'
    ORDER BY e.start_date DESC NULLS LAST, e.exam_id DESC;

    -- Default to their most recent published exam.
    IF p_exam_id IS NULL OR p_exam_id <= 0 THEN
        SELECT e.exam_id INTO v_exam_id
        FROM academic.exams e
        JOIN academic.exam_marks m ON m.exam_id = e.exam_id
        WHERE e.tenant_id = p_tenant_id AND e.school_id = p_school_id
          AND m.student_id = p_student_id
          AND COALESCE(e.is_deleted, FALSE) = FALSE
          AND e.status = 'Published'
        ORDER BY e.start_date DESC NULLS LAST, e.exam_id DESC
        LIMIT 1;
    ELSE
        -- An explicitly asked-for exam still has to be published and theirs.
        SELECT e.exam_id INTO v_exam_id
        FROM academic.exams e
        JOIN academic.exam_marks m ON m.exam_id = e.exam_id
        WHERE e.exam_id   = p_exam_id
          AND e.tenant_id = p_tenant_id AND e.school_id = p_school_id
          AND m.student_id = p_student_id
          AND COALESCE(e.is_deleted, FALSE) = FALSE
          AND e.status = 'Published'
        LIMIT 1;
    END IF;

    IF v_exam_id IS NULL THEN
        OPEN p_marks   FOR SELECT NULL::text AS subject, NULL::numeric AS obtained WHERE FALSE;
        OPEN p_summary FOR SELECT 0 AS subjects, 0::numeric AS obtained, 0::numeric AS total,
                                  0::numeric AS percent, 0 AS absent_count, 0 AS failed_count;
        RETURN;
    END IF;

    -- ── 2. Subject by subject ───────────────────────────────────────────────
    OPEN p_marks FOR
    SELECT COALESCE(sub.subject_name, 'Subject ' || m.subject_id) AS subject,
           m.marks_obtained                                        AS obtained,
           es.max_marks,
           es.pass_marks,
           COALESCE(m.is_absent, FALSE)                            AS is_absent,
           CASE WHEN COALESCE(m.is_absent, FALSE) THEN NULL
                WHEN es.pass_marks IS NULL        THEN NULL
                ELSE m.marks_obtained >= es.pass_marks END          AS passed,
           CASE WHEN COALESCE(m.is_absent, FALSE) OR COALESCE(es.max_marks, 0) = 0 THEN NULL
                ELSE ROUND(m.marks_obtained * 100.0 / es.max_marks, 1) END AS percent
    FROM academic.exam_marks m
    LEFT JOIN academic.exam_subjects es
           ON es.exam_id = m.exam_id AND es.subject_id = m.subject_id
    LEFT JOIN academic.school_subjects sub
           ON sub.subject_id = m.subject_id
          AND sub.tenant_id = p_tenant_id AND sub.school_id = p_school_id
    WHERE m.exam_id    = v_exam_id
      AND m.student_id = p_student_id
      AND m.tenant_id  = p_tenant_id AND m.school_id = p_school_id
    ORDER BY es.display_order NULLS LAST, subject;

    -- ── 3. Totals, absences excluded ────────────────────────────────────────
    OPEN p_summary FOR
    SELECT COUNT(*) FILTER (WHERE NOT COALESCE(m.is_absent, FALSE))::int   AS subjects,
           COALESCE(SUM(m.marks_obtained) FILTER (WHERE NOT COALESCE(m.is_absent, FALSE)), 0) AS obtained,
           COALESCE(SUM(es.max_marks)     FILTER (WHERE NOT COALESCE(m.is_absent, FALSE)), 0) AS total,
           CASE WHEN COALESCE(SUM(es.max_marks) FILTER (WHERE NOT COALESCE(m.is_absent, FALSE)), 0) = 0
                THEN 0::numeric
                ELSE ROUND(SUM(m.marks_obtained) FILTER (WHERE NOT COALESCE(m.is_absent, FALSE)) * 100.0
                         / SUM(es.max_marks)     FILTER (WHERE NOT COALESCE(m.is_absent, FALSE)), 1)
           END                                                             AS percent,
           COUNT(*) FILTER (WHERE COALESCE(m.is_absent, FALSE))::int       AS absent_count,
           COUNT(*) FILTER (WHERE NOT COALESCE(m.is_absent, FALSE)
                              AND es.pass_marks IS NOT NULL
                              AND m.marks_obtained < es.pass_marks)::int   AS failed_count
    FROM academic.exam_marks m
    LEFT JOIN academic.exam_subjects es
           ON es.exam_id = m.exam_id AND es.subject_id = m.subject_id
    WHERE m.exam_id    = v_exam_id
      AND m.student_id = p_student_id
      AND m.tenant_id  = p_tenant_id AND m.school_id = p_school_id;
END;
$procedure$;
