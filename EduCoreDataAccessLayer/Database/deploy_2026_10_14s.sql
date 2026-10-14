-- Bundle 2026-10-14s: exam dates stored as text (an empty date is no date); results not published before every paper is written. Run with:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_14s.sql
-- Sources (re-runnable, in this order): exam_results_publish.sql, exam_marks.sql, exam_schedule.sql

-- ============================================================================
-- Exam results: grade scale, result publishing, grades and class rank.
--
--   academic.grade_scale                  a school's grade bands (none = CBSE default)
--   academic.fn_default_grade_scale       the CBSE 8-point default
--   academic.fn_school_grade_scale        the school's bands, or the default
--   academic.fn_grade_for_percent         percentage -> grade label
--   academic.exams.results_status         Unpublished | Published (new columns)
--   academic.exam_result_log              every publish / unpublish: who, when, why
--   academic.fn_exam_pending_sheets       mark sheets of an exam not finalised yet
--   academic.fn_exam_class_result         one exam, one class: totals, %, grade, rank
--   academic.sp_school_admin_grade_scale_manage    GetScale | SaveScale | ResetDefault
--   academic.sp_school_admin_exam_results_manage   GetStatus | PublishResults
--                                                  | UnpublishResults | GetClassResult
--
-- AN EXAM HAS TWO STATUSES. academic.exams.status is the DATESHEET (Draft |
-- Published): a published datesheet takes marks. results_status is the RESULT:
-- marks can be typed while it is Unpublished, and students/parents see nothing
-- until it is Published. Publishing needs every mark sheet of the exam to be
-- finalised; once published, marks are locked (SaveMarks / ReopenSheet / SaveExam
-- refuse) until someone unpublishes with a reason.
--
-- GRADE BANDS. A band runs from its min % up to the next band's min %. The
-- stored max % is what the school sees ("81-90"); a percentage that falls
-- between two whole-number bands (90.5) takes the lower band. SaveScale checks
-- the bands cover 0-100 with no overlap and no gap wider than 1.
--
-- RANK. By overall percentage within the class (and within the section), ties
-- share a rank (1, 1, 3). Today's result rules apply: an absent paper counts as
-- 0 out of its max marks (QA BUG-095 -- leaving it out gave the absent student a
-- higher % and rank than those who sat every paper), marks of a paper no longer
-- on the datesheet do not count, and a student absent from every paper has no
-- percentage, no grade and no rank. A paper with no mark yet is left out.
--
-- Run BEFORE exam_marks.sql, exam_result_student.sql and exam_schedule.sql (their
-- procs read results_status and fn_exam_class_result).
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── Grade scale ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS academic.grade_scale (
    grade_scale_id  serial PRIMARY KEY,
    tenant_id       integer NOT NULL,
    school_id       integer NOT NULL,
    grade_label     varchar(10) NOT NULL,
    min_percent     numeric(5,2) NOT NULL,
    max_percent     numeric(5,2) NOT NULL,
    grade_point     numeric(5,2),
    remark          varchar(100),
    display_order   integer NOT NULL DEFAULT 0,
    created_by      integer,
    created_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT chk_grade_scale_scope CHECK (tenant_id > 1 AND school_id > 0),
    CONSTRAINT chk_grade_scale_label CHECK (btrim(grade_label) <> ''),
    CONSTRAINT chk_grade_scale_range CHECK (min_percent >= 0 AND max_percent <= 100
                                            AND min_percent <= max_percent)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_grade_scale_label
    ON academic.grade_scale (tenant_id, school_id, lower(grade_label));
CREATE UNIQUE INDEX IF NOT EXISTS uq_grade_scale_min
    ON academic.grade_scale (tenant_id, school_id, min_percent);


-- The CBSE 8-point scale, used by every school that has not saved its own.
-- Kept in a function rather than seeded per school, so a new school needs no setup.
CREATE OR REPLACE FUNCTION academic.fn_default_grade_scale()
RETURNS TABLE (
    out_label  text,
    out_min    numeric,
    out_max    numeric,
    out_point  numeric,
    out_remark text,
    out_order  integer)
LANGUAGE sql
IMMUTABLE
AS $function$
    SELECT * FROM (VALUES
        ('A1'::text, 91::numeric, 100::numeric, 10::numeric, 'Outstanding'::text,       1),
        ('A2',       81,          90,           9,           'Excellent',               2),
        ('B1',       71,          80,           8,           'Very Good',               3),
        ('B2',       61,          70,           7,           'Good',                    4),
        ('C1',       51,          60,           6,           'Above Average',           5),
        ('C2',       41,          50,           5,           'Average',                 6),
        ('D',        33,          40,           4,           'Pass',                    7),
        ('E',        0,           32,           NULL,        'Needs Improvement',       8)
    ) v;
$function$;


-- The school's own bands, or the default when it has none.
CREATE OR REPLACE FUNCTION academic.fn_school_grade_scale(p_tenant_id integer, p_school_id integer)
RETURNS TABLE (
    out_label  text,
    out_min    numeric,
    out_max    numeric,
    out_point  numeric,
    out_remark text,
    out_order  integer)
LANGUAGE sql
STABLE
AS $function$
    SELECT g.grade_label::text, g.min_percent, g.max_percent, g.grade_point, g.remark::text, g.display_order
    FROM academic.grade_scale g
    WHERE g.tenant_id = p_tenant_id AND g.school_id = p_school_id
    UNION ALL
    SELECT d.*
    FROM academic.fn_default_grade_scale() d
    WHERE NOT EXISTS (SELECT 1 FROM academic.grade_scale g
                      WHERE g.tenant_id = p_tenant_id AND g.school_id = p_school_id);
$function$;


-- Percentage -> grade. The band with the highest min % at or below the percentage.
CREATE OR REPLACE FUNCTION academic.fn_grade_for_percent(
    p_tenant_id integer,
    p_school_id integer,
    p_percent   numeric)
RETURNS text
LANGUAGE sql
STABLE
AS $function$
    SELECT CASE WHEN p_percent IS NULL THEN NULL ELSE
        (SELECT s.out_label
         FROM academic.fn_school_grade_scale(p_tenant_id, p_school_id) s
         WHERE s.out_min <= p_percent
         ORDER BY s.out_min DESC
         LIMIT 1)
    END;
$function$;


-- ── Result status on the exam ───────────────────────────────────────────────
ALTER TABLE academic.exams ADD COLUMN IF NOT EXISTS results_status       varchar(20) NOT NULL DEFAULT 'Unpublished';
ALTER TABLE academic.exams ADD COLUMN IF NOT EXISTS results_published_by integer;
ALTER TABLE academic.exams ADD COLUMN IF NOT EXISTS results_published_at timestamptz;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_exams_results_status') THEN
        ALTER TABLE academic.exams
            ADD CONSTRAINT chk_exams_results_status CHECK (results_status IN ('Unpublished', 'Published'));
    END IF;
END $$;

-- Every publish and unpublish, so "who pulled the results back, and why" has an answer.
CREATE TABLE IF NOT EXISTS academic.exam_result_log (
    log_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   integer NOT NULL,
    school_id   integer NOT NULL,
    exam_id     integer NOT NULL,
    action      varchar(20) NOT NULL,
    reason      varchar(500),
    done_by     integer,
    done_at     timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT chk_exam_result_log_scope  CHECK (tenant_id > 1 AND school_id > 0),
    CONSTRAINT chk_exam_result_log_action CHECK (action IN ('Publish', 'Unpublish')),
    CONSTRAINT fk_exam_result_log_exam    FOREIGN KEY (exam_id)
        REFERENCES academic.exams (exam_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS ix_exam_result_log_exam
    ON academic.exam_result_log (tenant_id, school_id, exam_id);


-- ── Mark sheets of an exam that are not finalised yet ───────────────────────
-- The sheets an exam needs are the ones Marks Entry offers: each paper of each
-- class, times each section of that class that has students (narrowed to the
-- exam's chosen sections when it targets some). Same rule as GetClassSetup in
-- exam_marks.sql, so a sheet the teacher cannot open never blocks publishing.
CREATE OR REPLACE FUNCTION academic.fn_exam_pending_sheets(p_exam_id integer)
RETURNS TABLE (
    out_class_id     integer,
    out_class_name   text,
    out_section      text,
    out_subject_id   integer,
    out_subject_name text,
    out_finalized    boolean)
LANGUAGE sql
STABLE
AS $function$
    WITH ex AS (
        SELECT exam_id, tenant_id, school_id, academic_year_id
        FROM academic.exams WHERE exam_id = p_exam_id
    ),
    secs AS (
        SELECT DISTINCT en.academic_class_id, COALESCE(TRIM(en.section), '') AS section
        FROM core.student_enrolment en
        JOIN ex ON en.tenant_id = ex.tenant_id AND en.school_id = ex.school_id
               AND en.academic_year_id = ex.academic_year_id
        WHERE COALESCE(en.status, '') <> 'Left'
          AND en.academic_class_id IN (SELECT es.academic_class_id FROM academic.exam_subjects es
                                       WHERE es.exam_id = p_exam_id)
          AND (NOT EXISTS (SELECT 1 FROM academic.exam_class_sections x
                           WHERE x.exam_id = p_exam_id AND x.academic_class_id = en.academic_class_id)
               OR EXISTS (SELECT 1 FROM academic.exam_class_sections x
                          WHERE x.exam_id = p_exam_id AND x.academic_class_id = en.academic_class_id
                            AND x.section = COALESCE(TRIM(en.section), '')))
    )
    SELECT es.academic_class_id,
           c.class_name::text,
           secs.section,
           es.subject_id,
           s.subject_name::text,
           EXISTS (SELECT 1 FROM academic.exam_mark_sheets sh
                   WHERE sh.exam_id = p_exam_id
                     AND sh.academic_class_id = es.academic_class_id
                     AND sh.subject_id = es.subject_id
                     AND sh.section = secs.section
                     AND sh.is_finalized)
    FROM academic.exam_subjects es
    JOIN secs ON secs.academic_class_id = es.academic_class_id
    JOIN academic.academic_classes c ON c.academic_class_id = es.academic_class_id
    JOIN academic.school_subjects  s ON s.subject_id = es.subject_id
    WHERE es.exam_id = p_exam_id
    ORDER BY c.display_order, c.class_name, secs.section, es.display_order, s.subject_name;
$function$;


-- ── One exam, one class: totals, percentage, grade and rank per student ─────
-- Driven off the marks (not today's roster), so a student who sat the exam and
-- left later still has a result. Only papers still on the class's datesheet count.
CREATE OR REPLACE FUNCTION academic.fn_exam_class_result(
    p_tenant_id integer,
    p_school_id integer,
    p_exam_id   integer,
    p_class_id  integer)
RETURNS TABLE (
    out_student_id   integer,
    out_section      text,
    out_subjects     integer,
    out_obtained     numeric,
    out_total        numeric,
    out_percent      numeric,
    out_grade        text,
    out_absent       integer,
    out_failed       integer,
    out_class_rank   integer,
    out_section_rank integer,
    out_class_size   integer,
    out_section_size integer)
LANGUAGE sql
STABLE
AS $function$
    WITH t AS (
        SELECT m.student_id,
               MAX(m.section)::text AS section,
               COUNT(*) FILTER (WHERE m.marks_obtained IS NOT NULL)::int            AS subjects,
               COALESCE(SUM(m.marks_obtained), 0)                                   AS obtained,
               -- an absent paper is 0 out of its max
               COALESCE(SUM(es.max_marks) FILTER (WHERE m.marks_obtained IS NOT NULL OR m.is_absent), 0) AS total,
               COUNT(*) FILTER (WHERE m.is_absent)::int                             AS absent,
               COUNT(*) FILTER (WHERE m.marks_obtained IS NOT NULL
                                  AND m.marks_obtained < es.pass_marks)::int        AS failed
        FROM academic.exam_marks m
        JOIN academic.exam_subjects es
          ON es.exam_id = m.exam_id AND es.subject_id = m.subject_id
         AND es.academic_class_id = m.academic_class_id
        WHERE m.exam_id = p_exam_id
          AND m.academic_class_id = p_class_id
          AND m.tenant_id = p_tenant_id AND m.school_id = p_school_id
        GROUP BY m.student_id
    ),
    p AS (
        SELECT t.*,
               -- absent from every paper (nothing sat) = no percentage
               CASE WHEN t.subjects > 0 AND t.total > 0 THEN ROUND(t.obtained * 100.0 / t.total, 2) END AS pct
        FROM t
    )
    SELECT p.student_id,
           p.section,
           p.subjects,
           p.obtained,
           p.total,
           p.pct,
           academic.fn_grade_for_percent(p_tenant_id, p_school_id, p.pct),
           p.absent,
           p.failed,
           -- Ties share a rank (1, 1, 3). No percentage = not ranked.
           CASE WHEN p.pct IS NOT NULL
                THEN (RANK() OVER (PARTITION BY (p.pct IS NULL) ORDER BY p.pct DESC))::int END,
           CASE WHEN p.pct IS NOT NULL
                THEN (RANK() OVER (PARTITION BY (p.pct IS NULL), p.section ORDER BY p.pct DESC))::int END,
           (COUNT(p.pct) OVER ())::int,
           (COUNT(p.pct) OVER (PARTITION BY p.section))::int
    FROM p;
$function$;


-- ── Grade scale screen ──────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE academic.sp_school_admin_grade_scale_manage(
    IN    p_operation      character varying,
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_items          text      DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'grade_scale_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_items  jsonb;
    v_item   jsonb;
    v_label  text;
    v_min    numeric;
    v_max    numeric;
    v_point  numeric;
    v_remark text;
    v_msg    text;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    IF p_operation = 'GetScale' THEN

        OPEN p_result FOR
        SELECT s.out_label  AS grade_label,
               s.out_min    AS min_percent,
               s.out_max    AS max_percent,
               s.out_point  AS grade_point,
               s.out_remark AS remark,
               NOT EXISTS (SELECT 1 FROM academic.grade_scale g
                           WHERE g.tenant_id = p_tenant_id AND g.school_id = p_school_id) AS is_default
        FROM academic.fn_school_grade_scale(p_tenant_id, p_school_id) s
        ORDER BY s.out_min DESC;

    ELSIF p_operation = 'SaveScale' THEN

        -- p_items: [{ "label": "A1", "minPercent": 91, "maxPercent": 100,
        --             "gradePoint": 10, "remark": "Outstanding" }]
        BEGIN
            v_items := COALESCE(NULLIF(p_items, ''), '[]')::jsonb;
        EXCEPTION WHEN OTHERS THEN
            RAISE EXCEPTION 'The grade bands could not be read.';
        END;
        IF jsonb_typeof(v_items) <> 'array' OR jsonb_array_length(v_items) = 0 THEN
            RAISE EXCEPTION 'Add at least one grade band.';
        END IF;

        -- Each band on its own first, so the message names the band at fault.
        FOR v_item IN SELECT value FROM jsonb_array_elements(v_items)
        LOOP
            v_label := TRIM(COALESCE(v_item->>'label', ''));
            IF v_label = '' THEN
                RAISE EXCEPTION 'Every grade band needs a grade label.';
            END IF;
            IF length(v_label) > 10 THEN
                RAISE EXCEPTION 'Grade "%" is too long (10 characters at most).', v_label;
            END IF;

            BEGIN
                v_min   := NULLIF(TRIM(COALESCE(v_item->>'minPercent', '')), '')::numeric;
                v_max   := NULLIF(TRIM(COALESCE(v_item->>'maxPercent', '')), '')::numeric;
                v_point := NULLIF(TRIM(COALESCE(v_item->>'gradePoint', '')), '')::numeric;
            EXCEPTION WHEN OTHERS THEN
                RAISE EXCEPTION 'Grade %: min %%, max %% and grade point must be numbers.', v_label;
            END;

            IF v_min IS NULL OR v_max IS NULL THEN
                RAISE EXCEPTION 'Grade %: enter both the min %% and the max %%.', v_label;
            END IF;
            IF v_min < 0 OR v_max > 100 THEN
                RAISE EXCEPTION 'Grade %: percentages must be between 0 and 100.', v_label;
            END IF;
            IF v_min > v_max THEN
                RAISE EXCEPTION 'Grade %: the min %% cannot be more than the max %%.', v_label;
            END IF;
            IF v_point IS NOT NULL AND (v_point < 0 OR v_point > 100) THEN
                RAISE EXCEPTION 'Grade %: the grade point must be between 0 and 100.', v_label;
            END IF;
            IF length(TRIM(COALESCE(v_item->>'remark', ''))) > 100 THEN
                RAISE EXCEPTION 'Grade %: the remark is too long (100 characters at most).', v_label;
            END IF;
        END LOOP;

        -- Labels are unique, whatever the case.
        SELECT MIN(TRIM(value->>'label')) INTO v_msg
        FROM jsonb_array_elements(v_items)
        GROUP BY lower(TRIM(value->>'label'))
        HAVING COUNT(*) > 1
        LIMIT 1;
        IF v_msg IS NOT NULL THEN
            RAISE EXCEPTION 'Grade "%" appears more than once.', v_msg;
        END IF;

        -- Sorted by min %, the bands must start at 0, end at 100, never overlap
        -- and leave no gap wider than 1 (81-90 then 91-100 is contiguous).
        WITH b AS (
            SELECT TRIM(value->>'label') AS label,
                   ROUND((value->>'minPercent')::numeric, 2) AS mn,
                   ROUND((value->>'maxPercent')::numeric, 2) AS mx
            FROM jsonb_array_elements(v_items)
        ),
        o AS (
            SELECT b.*,
                   LAG(label) OVER (ORDER BY mn, mx) AS prev_label,
                   LAG(mx)    OVER (ORDER BY mn, mx) AS prev_max,
                   ROW_NUMBER() OVER (ORDER BY mn, mx) AS rn,
                   COUNT(*)     OVER ()                AS n
            FROM b
        )
        SELECT CASE
                 WHEN rn = 1 AND mn <> 0
                   THEN format('The lowest grade (%s) must start at 0%%.', label)
                 WHEN rn = n AND mx <> 100
                   THEN format('The highest grade (%s) must end at 100%%.', label)
                 WHEN prev_max IS NOT NULL AND mn <= prev_max
                   THEN format('Grades %s and %s overlap.', prev_label, label)
                 WHEN prev_max IS NOT NULL AND mn > prev_max + 1
                   THEN format('There is a gap between grade %s (ends at %s%%) and grade %s (starts at %s%%).',
                               prev_label, prev_max, label, mn)
               END
          INTO v_msg
        FROM o
        WHERE (rn = 1 AND mn <> 0)
           OR (rn = n AND mx <> 100)
           OR (prev_max IS NOT NULL AND (mn <= prev_max OR mn > prev_max + 1))
        ORDER BY rn
        LIMIT 1;
        IF v_msg IS NOT NULL THEN
            RAISE EXCEPTION '%', v_msg;
        END IF;

        -- Replace-all: the scale is edited as one table.
        DELETE FROM academic.grade_scale
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id;

        INSERT INTO academic.grade_scale
            (tenant_id, school_id, grade_label, min_percent, max_percent, grade_point, remark,
             display_order, created_by, created_at)
        SELECT p_tenant_id, p_school_id,
               TRIM(value->>'label'),
               ROUND((value->>'minPercent')::numeric, 2),
               ROUND((value->>'maxPercent')::numeric, 2),
               ROUND(NULLIF(TRIM(COALESCE(value->>'gradePoint', '')), '')::numeric, 2),
               NULLIF(TRIM(COALESCE(value->>'remark', '')), ''),
               (ROW_NUMBER() OVER (ORDER BY (value->>'minPercent')::numeric DESC))::int,
               p_action_user_id, now()
        FROM jsonb_array_elements(v_items);

        OPEN p_result FOR SELECT TRUE AS success, 'Grade scale saved.' AS message;

    ELSIF p_operation = 'ResetDefault' THEN

        DELETE FROM academic.grade_scale
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id;

        OPEN p_result FOR SELECT TRUE AS success, 'Grade scale reset to the CBSE default.' AS message;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;


-- ── Publish / unpublish results, and the class result sheet ─────────────────
CREATE OR REPLACE PROCEDURE academic.sp_school_admin_exam_results_manage(
    IN    p_operation         character varying,
    IN    p_tenant_id         integer,
    IN    p_school_id         integer,
    IN    p_action_user_id    integer,
    IN    p_exam_id           integer   DEFAULT NULL,
    IN    p_academic_class_id integer   DEFAULT NULL,
    IN    p_section           character varying DEFAULT NULL,
    IN    p_reason            text      DEFAULT NULL,
    INOUT p_result            refcursor DEFAULT 'exam_results_cursor'::refcursor,
    INOUT p_result2           refcursor DEFAULT 'exam_results_cursor2'::refcursor,
    INOUT p_result3           refcursor DEFAULT 'exam_results_cursor3'::refcursor,
    INOUT p_result4           refcursor DEFAULT 'exam_results_cursor4'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_year     integer;
    v_status   text;
    v_results  text;
    v_expected integer;
    v_pending  integer;
    v_first    text;
    v_reason   text;
    v_section  text;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;
    IF COALESCE(p_exam_id, 0) <= 0 THEN
        RAISE EXCEPTION 'Pick an exam first.';
    END IF;

    -- Every operation works on one exam of THIS school.
    SELECT academic_year_id, status, results_status INTO v_year, v_status, v_results
    FROM academic.exams
    WHERE exam_id = p_exam_id AND tenant_id = p_tenant_id AND school_id = p_school_id
      AND NOT is_deleted;

    IF v_year IS NULL THEN
        RAISE EXCEPTION 'That exam was not found.';
    END IF;

    IF p_operation = 'GetStatus' THEN

        SELECT COUNT(*)::int, COUNT(*) FILTER (WHERE NOT out_finalized)::int
          INTO v_expected, v_pending
        FROM academic.fn_exam_pending_sheets(p_exam_id);

        OPEN p_result FOR
        SELECT e.exam_id,
               e.exam_name,
               e.status,
               e.results_status,
               -- Display text in the database's (the school's) clock.
               to_char(e.results_published_at, 'DD Mon YYYY HH24:MI') AS results_published_at,
               core.fn_user_display_name(e.results_published_by) AS results_published_by,
               v_expected AS sheet_count,
               v_pending  AS pending_count
        FROM academic.exams e
        WHERE e.exam_id = p_exam_id;

        -- The sheets still to finalise — what stands between the exam and Publish.
        OPEN p_result2 FOR
        SELECT out_class_id AS academic_class_id, out_class_name AS class_name,
               out_section AS section, out_subject_id AS subject_id, out_subject_name AS subject_name
        FROM academic.fn_exam_pending_sheets(p_exam_id)
        WHERE NOT out_finalized;

        OPEN p_result3 FOR
        SELECT l.action, COALESCE(l.reason, '') AS reason,
               core.fn_user_display_name(l.done_by) AS done_by,
               to_char(l.done_at, 'DD Mon YYYY HH24:MI') AS done_at
        FROM academic.exam_result_log l
        WHERE l.exam_id = p_exam_id AND l.tenant_id = p_tenant_id AND l.school_id = p_school_id
        ORDER BY l.done_at DESC, l.log_id DESC;

        OPEN p_result4 FOR SELECT 1 WHERE FALSE;

    ELSIF p_operation = 'PublishResults' THEN

        IF v_status IS DISTINCT FROM 'Published' THEN
            RAISE EXCEPTION 'This exam''s datesheet is still a draft, so it has no results to publish.';
        END IF;
        IF v_results = 'Published' THEN
            RAISE EXCEPTION 'The results of this exam are already published.';
        END IF;

        -- A paper still to be written has no real marks (QA BUG-076).
        SELECT MIN(NULLIF(es.exam_date::text, '')::date)::text INTO v_first
          FROM academic.exam_subjects es
         WHERE es.exam_id = p_exam_id AND NULLIF(es.exam_date::text, '')::date > CURRENT_DATE;
        IF v_first IS NOT NULL THEN
            RAISE EXCEPTION 'Results cannot be published before every paper is written (next paper on %).',
                to_char(v_first::date, 'DD Mon YYYY');
        END IF;

        SELECT COUNT(*)::int, COUNT(*) FILTER (WHERE NOT out_finalized)::int
          INTO v_expected, v_pending
        FROM academic.fn_exam_pending_sheets(p_exam_id);

        IF v_expected = 0 THEN
            RAISE EXCEPTION 'No students sit this exam, so there are no results to publish.';
        END IF;

        IF v_pending > 0 THEN
            SELECT out_class_name || CASE WHEN out_section = '' THEN '' ELSE '-' || out_section END
                   || ' ' || out_subject_name
              INTO v_first
            FROM academic.fn_exam_pending_sheets(p_exam_id)
            WHERE NOT out_finalized
            LIMIT 1;
            RAISE EXCEPTION 'Results cannot be published yet: % mark sheet(s) are not finalised (for example %).',
                v_pending, v_first;
        END IF;

        UPDATE academic.exams
           SET results_status       = 'Published',
               results_published_by = p_action_user_id,
               results_published_at = now(),
               updated_by           = p_action_user_id,
               updated_at           = now()
         WHERE exam_id = p_exam_id;

        INSERT INTO academic.exam_result_log (tenant_id, school_id, exam_id, action, reason, done_by)
        VALUES (p_tenant_id, p_school_id, p_exam_id, 'Publish', NULL, p_action_user_id);

        OPEN p_result  FOR SELECT TRUE AS success, 'Results published. Marks are now locked.' AS message;
        OPEN p_result2 FOR SELECT 1 WHERE FALSE;
        OPEN p_result3 FOR SELECT 1 WHERE FALSE;
        OPEN p_result4 FOR SELECT 1 WHERE FALSE;

    ELSIF p_operation = 'UnpublishResults' THEN

        v_reason := TRIM(COALESCE(p_reason, ''));
        IF v_reason = '' THEN
            RAISE EXCEPTION 'Give a reason for unpublishing the results.';
        END IF;
        IF length(v_reason) > 500 THEN
            RAISE EXCEPTION 'The reason is too long (500 characters at most).';
        END IF;
        IF v_results IS DISTINCT FROM 'Published' THEN
            RAISE EXCEPTION 'The results of this exam are not published.';
        END IF;

        UPDATE academic.exams
           SET results_status = 'Unpublished',
               updated_by     = p_action_user_id,
               updated_at     = now()
         WHERE exam_id = p_exam_id;

        INSERT INTO academic.exam_result_log (tenant_id, school_id, exam_id, action, reason, done_by)
        VALUES (p_tenant_id, p_school_id, p_exam_id, 'Unpublish', v_reason, p_action_user_id);

        OPEN p_result  FOR SELECT TRUE AS success,
                                  'Results unpublished. Marks can be edited again (reopen the sheets that need it).' AS message;
        OPEN p_result2 FOR SELECT 1 WHERE FALSE;
        OPEN p_result3 FOR SELECT 1 WHERE FALSE;
        OPEN p_result4 FOR SELECT 1 WHERE FALSE;

    ELSIF p_operation = 'GetClassResult' THEN

        IF COALESCE(p_academic_class_id, 0) <= 0 THEN
            RAISE EXCEPTION 'Pick a class first.';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM academic.exam_subjects
                       WHERE exam_id = p_exam_id AND academic_class_id = p_academic_class_id) THEN
            RAISE EXCEPTION 'That class is not part of this exam.';
        END IF;

        -- NULL / '' = the whole class. Rank is always worked out over the whole
        -- class; the section column says where the student stands in their section.
        v_section := NULLIF(TRIM(COALESCE(p_section, '')), '');

        SELECT COUNT(*) FILTER (WHERE NOT out_finalized)::int INTO v_pending
        FROM academic.fn_exam_pending_sheets(p_exam_id)
        WHERE out_class_id = p_academic_class_id;

        OPEN p_result FOR
        SELECT e.exam_name,
               c.class_name,
               COALESCE(v_section, '') AS section,
               e.status,
               e.results_status,
               to_char(e.results_published_at, 'DD Mon YYYY') AS results_published_at,
               COALESCE(ay.academic_year_name, '') AS academic_year_name,
               v_pending AS pending_count
        FROM academic.exams e
        JOIN academic.academic_classes c ON c.academic_class_id = p_academic_class_id
        LEFT JOIN academic.academic_years ay ON ay.academic_year_id = e.academic_year_id
        WHERE e.exam_id = p_exam_id;

        -- The columns: this class's papers.
        OPEN p_result2 FOR
        SELECT es.subject_id, s.subject_name, es.max_marks, es.pass_marks
        FROM academic.exam_subjects es
        JOIN academic.school_subjects s ON s.subject_id = es.subject_id
        WHERE es.exam_id = p_exam_id AND es.academic_class_id = p_academic_class_id
        ORDER BY es.display_order, s.subject_name;

        -- The rows: one per student, in roll order.
        OPEN p_result3 FOR
        SELECT r.out_student_id AS student_id,
               COALESCE(NULLIF(TRIM(en.roll_no), ''), NULLIF(TRIM(st.roll_no), ''),
                        NULLIF(TRIM(st.admission_no), ''), '') AS roll_no,
               COALESCE(st.admission_no, '') AS admission_no,
               st.student_name,
               r.out_section      AS section,
               r.out_subjects     AS subjects,
               r.out_obtained     AS obtained,
               r.out_total        AS total,
               r.out_percent      AS percent,
               r.out_grade        AS grade,
               r.out_absent       AS absent_count,
               r.out_failed       AS failed_count,
               r.out_class_rank   AS class_rank,
               r.out_section_rank AS section_rank,
               r.out_class_size   AS class_size,
               r.out_section_size AS section_size
        FROM academic.fn_exam_class_result(p_tenant_id, p_school_id, p_exam_id, p_academic_class_id) r
        JOIN core.students st ON st.student_id = r.out_student_id
        LEFT JOIN core.student_enrolment en
               ON en.student_id = r.out_student_id
              AND en.academic_year_id = v_year
              AND en.academic_class_id = p_academic_class_id
        WHERE v_section IS NULL OR LOWER(r.out_section) = LOWER(v_section)
        ORDER BY
            CASE WHEN COALESCE(NULLIF(TRIM(en.roll_no), ''), NULLIF(TRIM(st.roll_no), '')) ~ '^[0-9]+$'
                 THEN lpad(COALESCE(NULLIF(TRIM(en.roll_no), ''), TRIM(st.roll_no)), 6, '0')
                 ELSE NULL END NULLS LAST,
            st.student_name;

        -- The cells: each student's mark per paper, with its grade.
        OPEN p_result4 FOR
        SELECT m.student_id,
               m.subject_id,
               m.marks_obtained,
               m.is_absent,
               academic.fn_grade_for_percent(p_tenant_id, p_school_id,
                   CASE WHEN m.marks_obtained IS NULL THEN NULL
                        ELSE ROUND(m.marks_obtained * 100.0 / es.max_marks, 2) END) AS grade,
               CASE WHEN m.marks_obtained IS NULL THEN NULL
                    ELSE m.marks_obtained >= es.pass_marks END AS passed
        FROM academic.exam_marks m
        JOIN academic.exam_subjects es
          ON es.exam_id = m.exam_id AND es.subject_id = m.subject_id
         AND es.academic_class_id = m.academic_class_id
        WHERE m.exam_id = p_exam_id
          AND m.academic_class_id = p_academic_class_id
          AND m.tenant_id = p_tenant_id AND m.school_id = p_school_id
          AND (v_section IS NULL OR LOWER(m.section) = LOWER(v_section));

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;


-- ============================================================================
-- Exam marks — the Marks Entry sheet behind an exam's per-class datesheet.
--
--   academic.exam_marks              one row per student per exam-subject
--   academic.exam_mark_sheets        the finalize/lock state of one sheet
--   academic.fn_exam_sheet_roster    who sits a sheet (ONE definition, two callers)
--   academic.sp_school_admin_exam_marks_manage
--         GetExamClasses | GetClassSetup | GetSheet | SaveMarks | ReopenSheet | GetMarkScope
--
-- A SHEET is one (exam, class, section, subject) — what a teacher fills in one
-- sitting. The exam is school-wide (see exam_schedule.sql), so the selector
-- cascade is Exam -> Class -> Section -> Subject. The class is part of the sheet
-- key: section 'A' exists in every class, so leaving it out would collide.
--
-- The roster comes from core.student_enrolment, NOT core.students: an exam on a
-- past session must list who was in that class THEN. Reading core.students would
-- show only the students who happen not to have been promoted since.
-- (See the 2026-08-12 entry in docs/SCALING-AND-FIXES.md.)
--
-- Grades are NOT stored. A grade is derived from the percentage + the school's
-- grade scale (exam_results_publish.sql) whenever a result is read.
--
-- RESULTS PUBLISHED = LOCKED. Once an exam's results are published
-- (academic.exams.results_status), SaveMarks and ReopenSheet refuse until the
-- results are unpublished. GetSheet says so, so the page can lock the grid.
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

CREATE TABLE IF NOT EXISTS academic.exam_marks (
    exam_mark_id      serial PRIMARY KEY,
    tenant_id         integer NOT NULL,
    school_id         integer NOT NULL,
    exam_id           integer NOT NULL,
    academic_class_id integer NOT NULL,
    subject_id        integer NOT NULL,
    student_id        integer NOT NULL,
    -- The session row the student sat this paper in. Carried from day one so
    -- marks stay attached to the session, not to the student's present class.
    enrolment_id      integer,
    -- Snapshot of the section the sheet was filled for.
    section           varchar(20) NOT NULL DEFAULT '',
    marks_obtained    numeric(6,2),
    is_absent         boolean NOT NULL DEFAULT FALSE,
    remarks           varchar(200),
    created_by        integer,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_by        integer,
    updated_at        timestamptz,

    CONSTRAINT chk_exam_marks_scope  CHECK (tenant_id > 1 AND school_id > 0),
    CONSTRAINT chk_exam_marks_value  CHECK (marks_obtained IS NULL OR marks_obtained >= 0),
    -- An absent student has no marks; the two can never disagree.
    CONSTRAINT chk_exam_marks_absent CHECK (NOT (is_absent AND marks_obtained IS NOT NULL)),
    CONSTRAINT fk_exam_marks_exam    FOREIGN KEY (exam_id)
        REFERENCES academic.exams (exam_id) ON DELETE CASCADE,
    CONSTRAINT fk_exam_marks_subject FOREIGN KEY (subject_id)
        REFERENCES academic.school_subjects (subject_id),
    CONSTRAINT fk_exam_marks_student FOREIGN KEY (student_id)
        REFERENCES core.students (student_id) ON DELETE CASCADE,
    -- A student sits a subject once per exam, whatever the section.
    CONSTRAINT uq_exam_marks UNIQUE (exam_id, subject_id, student_id)
);

CREATE INDEX IF NOT EXISTS ix_exam_marks_sheet
    ON academic.exam_marks (exam_id, academic_class_id, subject_id, section);

-- The lock lives on the SHEET, not on each mark — a half-finalized sheet is not
-- a state that should be representable.
CREATE TABLE IF NOT EXISTS academic.exam_mark_sheets (
    sheet_id          serial PRIMARY KEY,
    tenant_id         integer NOT NULL,
    school_id         integer NOT NULL,
    exam_id           integer NOT NULL,
    academic_class_id integer NOT NULL,
    subject_id        integer NOT NULL,
    -- '' rather than NULL: NULLs do not compare equal, so a nullable section
    -- would let the same sheet be created twice.
    section           varchar(20) NOT NULL DEFAULT '',
    is_finalized      boolean NOT NULL DEFAULT FALSE,
    finalized_by      integer,
    finalized_at      timestamptz,
    reopened_by       integer,
    reopened_at       timestamptz,

    CONSTRAINT chk_exam_mark_sheets_scope CHECK (tenant_id > 1 AND school_id > 0),
    CONSTRAINT fk_exam_mark_sheets_exam   FOREIGN KEY (exam_id)
        REFERENCES academic.exams (exam_id) ON DELETE CASCADE,
    CONSTRAINT uq_exam_mark_sheets UNIQUE (exam_id, academic_class_id, subject_id, section)
);


-- ── Who sits one sheet ──────────────────────────────────────────────────────
-- Output columns are out_-prefixed so the body can reference the real columns
-- without Postgres treating the name as the OUT variable.
CREATE OR REPLACE FUNCTION academic.fn_exam_sheet_roster(
    p_tenant_id integer,
    p_school_id integer,
    p_year_id   integer,
    p_class_id  integer,
    p_section   varchar)
RETURNS TABLE (
    out_student_id   integer,
    out_enrolment_id integer,
    out_roll_no      text,
    out_student_name text,
    out_gender       text)
LANGUAGE sql
STABLE
AS $function$
    SELECT
        e.student_id,
        e.enrolment_id,
        -- roll_no is not captured yet on most rows; fall back so the # column
        -- always shows something stable.
        COALESCE(NULLIF(TRIM(e.roll_no), ''),
                 NULLIF(TRIM(s.roll_no), ''),
                 NULLIF(TRIM(s.admission_no), ''), '')::text,
        s.student_name::text,
        COALESCE(s.gender, '')::text
    FROM core.student_enrolment e
    JOIN core.students s ON s.student_id = e.student_id
    WHERE e.tenant_id = p_tenant_id
      AND e.school_id = p_school_id
      AND e.academic_year_id  = p_year_id
      AND e.academic_class_id = p_class_id
      AND LOWER(COALESCE(TRIM(e.section), '')) = LOWER(COALESCE(TRIM(p_section), ''))
      -- A student who left mid-session does not sit the paper. 'Promoted' and
      -- 'PassedOut' are normal outcomes of a finished session and must stay.
      AND COALESCE(e.status, '') <> 'Left'
    ORDER BY
        CASE WHEN COALESCE(NULLIF(TRIM(e.roll_no), ''), NULLIF(TRIM(s.roll_no), '')) ~ '^[0-9]+$'
             THEN lpad(COALESCE(NULLIF(TRIM(e.roll_no), ''), TRIM(s.roll_no)), 6, '0')
             ELSE NULL END NULLS LAST,
        s.student_name;
$function$;


CREATE OR REPLACE PROCEDURE academic.sp_school_admin_exam_marks_manage(
    IN    p_operation         character varying,
    IN    p_tenant_id         integer,
    IN    p_school_id         integer,
    IN    p_action_user_id    integer,
    IN    p_exam_id           integer   DEFAULT NULL,
    IN    p_academic_class_id integer   DEFAULT NULL,
    IN    p_subject_id        integer   DEFAULT NULL,
    IN    p_section           character varying DEFAULT NULL,
    IN    p_items             text      DEFAULT NULL,
    IN    p_finalize          boolean   DEFAULT FALSE,
    INOUT p_result            refcursor DEFAULT 'exam_marks_cursor'::refcursor,
    INOUT p_result2           refcursor DEFAULT 'exam_marks_cursor2'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_section text;
    v_year_id integer;
    v_max     numeric;
    v_pass    numeric;
    v_paper   date;
    v_final   boolean;
    v_items   jsonb;
    v_item    jsonb;
    v_sid     integer;
    v_marks   numeric;
    v_absent  boolean;
    v_name    text;
    v_enrol   integer;
    v_saved   integer := 0;
    v_added   integer := 0;
    v_blank   integer := 0;
    v_status  text;
    v_results text;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    v_section := COALESCE(TRIM(p_section), '');

    -- Every operation works on one exam; resolve its academic year once.
    IF COALESCE(p_exam_id, 0) > 0 THEN
        SELECT academic_year_id, status, results_status INTO v_year_id, v_status, v_results
        FROM academic.exams
        WHERE exam_id   = p_exam_id
          AND tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND NOT is_deleted;

        IF v_year_id IS NULL THEN
            RAISE EXCEPTION 'That exam was not found.';
        END IF;
    END IF;

    -- Operations from GetClassSetup down all need a class that is on the exam.
    IF p_operation IN ('GetClassSetup', 'GetSheet', 'SaveMarks', 'ReopenSheet') THEN
        IF COALESCE(p_academic_class_id, 0) <= 0 THEN
            RAISE EXCEPTION 'Pick a class first.';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM academic.exam_subjects
                       WHERE exam_id = p_exam_id
                         AND academic_class_id = p_academic_class_id) THEN
            RAISE EXCEPTION 'That class is not part of this exam.';
        END IF;
    END IF;

    IF p_operation = 'GetExamClasses' THEN

        -- The classes this exam covers — the Class dropdown.
        OPEN p_result FOR
        SELECT es.academic_class_id,
               c.class_name,
               COUNT(*)::int AS subject_count
        FROM academic.exam_subjects es
        JOIN academic.academic_classes c ON c.academic_class_id = es.academic_class_id
        WHERE es.exam_id   = p_exam_id
          AND es.tenant_id = p_tenant_id
          AND es.school_id = p_school_id
        GROUP BY es.academic_class_id, c.class_name, c.display_order
        ORDER BY c.display_order, c.class_name;

        OPEN p_result2 FOR SELECT 1 WHERE FALSE;

    ELSIF p_operation = 'GetClassSetup' THEN

        -- That class's datesheet — the Subject dropdown and its marks scale.
        OPEN p_result FOR
        SELECT es.subject_id, s.subject_name, es.exam_date, es.start_time, es.end_time,
               es.max_marks, es.pass_marks
        FROM academic.exam_subjects es
        JOIN academic.school_subjects s ON s.subject_id = es.subject_id
        WHERE es.exam_id           = p_exam_id
          AND es.academic_class_id = p_academic_class_id
          AND es.tenant_id         = p_tenant_id
          AND es.school_id         = p_school_id
        ORDER BY es.display_order, s.subject_name;

        -- Sections that actually have students enrolled in this class that year,
        -- narrowed to the exam's chosen sections when it targets specific ones.
        -- No exam_class_sections rows for this (exam, class) = the whole class.
        OPEN p_result2 FOR
        SELECT COALESCE(TRIM(e.section), '') AS section, COUNT(*)::int AS student_count
        FROM core.student_enrolment e
        WHERE e.tenant_id = p_tenant_id
          AND e.school_id = p_school_id
          AND e.academic_year_id  = v_year_id
          AND e.academic_class_id = p_academic_class_id
          AND COALESCE(e.status, '') <> 'Left'
          AND (NOT EXISTS (SELECT 1 FROM academic.exam_class_sections x
                           WHERE x.exam_id = p_exam_id
                             AND x.academic_class_id = p_academic_class_id)
               OR EXISTS (SELECT 1 FROM academic.exam_class_sections x
                          WHERE x.exam_id = p_exam_id
                            AND x.academic_class_id = p_academic_class_id
                            AND x.section = COALESCE(TRIM(e.section), '')))
        GROUP BY COALESCE(TRIM(e.section), '')
        ORDER BY 1;

    ELSIF p_operation = 'GetSheet' THEN

        SELECT es.max_marks, es.pass_marks INTO v_max, v_pass
        FROM academic.exam_subjects es
        WHERE es.exam_id = p_exam_id
          AND es.academic_class_id = p_academic_class_id
          AND es.subject_id = p_subject_id;

        IF v_max IS NULL THEN
            RAISE EXCEPTION 'That subject is not on this class''s datesheet.';
        END IF;

        OPEN p_result FOR
        SELECT
            r.out_student_id   AS student_id,
            r.out_roll_no      AS roll_no,
            r.out_student_name AS student_name,
            r.out_gender       AS gender,
            m.marks_obtained,
            COALESCE(m.is_absent, FALSE) AS is_absent,
            (m.exam_mark_id IS NOT NULL) AS has_mark
        FROM academic.fn_exam_sheet_roster(p_tenant_id, p_school_id, v_year_id, p_academic_class_id, v_section) r
        LEFT JOIN academic.exam_marks m
               ON m.exam_id    = p_exam_id
              AND m.subject_id = p_subject_id
              AND m.student_id = r.out_student_id;

        OPEN p_result2 FOR
        SELECT
            v_max  AS max_marks,
            v_pass AS pass_marks,
            (SELECT es.exam_date FROM academic.exam_subjects es
             WHERE es.exam_id = p_exam_id
               AND es.academic_class_id = p_academic_class_id
               AND es.subject_id = p_subject_id) AS exam_date,
            (SELECT es.start_time FROM academic.exam_subjects es
             WHERE es.exam_id = p_exam_id
               AND es.academic_class_id = p_academic_class_id
               AND es.subject_id = p_subject_id) AS start_time,
            (SELECT es.end_time FROM academic.exam_subjects es
             WHERE es.exam_id = p_exam_id
               AND es.academic_class_id = p_academic_class_id
               AND es.subject_id = p_subject_id) AS end_time,
            (SELECT s.subject_name FROM academic.school_subjects s
             WHERE s.subject_id = p_subject_id) AS subject_name,
            COALESCE(sh.is_finalized, FALSE) AS is_finalized,
            sh.finalized_at,
            (v_results = 'Published') AS results_published
        FROM (SELECT 1) x
        LEFT JOIN academic.exam_mark_sheets sh
               ON sh.exam_id           = p_exam_id
              AND sh.academic_class_id = p_academic_class_id
              AND sh.subject_id        = p_subject_id
              AND sh.section           = v_section;

    ELSIF p_operation = 'SaveMarks' THEN

        SELECT es.max_marks, es.pass_marks, NULLIF(es.exam_date::text, '')::date INTO v_max, v_pass, v_paper
        FROM academic.exam_subjects es
        WHERE es.exam_id = p_exam_id
          AND es.academic_class_id = p_academic_class_id
          AND es.subject_id = p_subject_id;

        IF v_max IS NULL THEN
            RAISE EXCEPTION 'That subject is not on this class''s datesheet.';
        END IF;

        SELECT COALESCE(is_finalized, FALSE) INTO v_final
        FROM academic.exam_mark_sheets
        WHERE exam_id           = p_exam_id
          AND academic_class_id = p_academic_class_id
          AND subject_id        = p_subject_id
          AND section           = v_section;

        -- Published results are a record parents have seen; they change only
        -- after someone unpublishes them (with a reason, logged).
        IF v_results = 'Published' THEN
            RAISE EXCEPTION 'The results of this exam are published, so its marks are locked. Unpublish the results first.';
        END IF;

        IF COALESCE(v_final, FALSE) THEN
            RAISE EXCEPTION 'These marks are finalized. Ask a school admin to reopen the sheet.';
        END IF;

        -- A draft datesheet is still being built; the Marks Entry page hides
        -- drafts, and the server holds the same line.
        IF v_status IS DISTINCT FROM 'Published' THEN
            RAISE EXCEPTION 'This exam is still a draft. Publish it before entering marks.';
        END IF;

        -- No marks before the paper has been written (QA BUG-076).
        IF v_paper > CURRENT_DATE THEN
            RAISE EXCEPTION 'This paper is on %. Marks can be entered from that day.', to_char(v_paper, 'DD Mon YYYY');
        END IF;

        -- An exam that targets specific sections of this class takes marks only
        -- for those sections (no exam_class_sections rows = the whole class).
        IF EXISTS (SELECT 1 FROM academic.exam_class_sections x
                   WHERE x.exam_id = p_exam_id AND x.academic_class_id = p_academic_class_id)
           AND NOT EXISTS (SELECT 1 FROM academic.exam_class_sections x
                           WHERE x.exam_id = p_exam_id AND x.academic_class_id = p_academic_class_id
                             AND LOWER(x.section) = LOWER(v_section)) THEN
            RAISE EXCEPTION 'This exam is not held for section % of this class.',
                CASE WHEN v_section = '' THEN '(none)' ELSE v_section END;
        END IF;

        v_items := COALESCE(NULLIF(p_items, ''), '[]')::jsonb;

        FOR v_item IN SELECT value FROM jsonb_array_elements(v_items)
        LOOP
            v_sid := NULLIF(v_item->>'studentId', '')::int;
            CONTINUE WHEN v_sid IS NULL;

            v_absent := COALESCE((v_item->>'absent')::boolean, FALSE);
            v_marks  := CASE WHEN v_absent THEN NULL
                             ELSE NULLIF(v_item->>'marks', '')::numeric END;

            -- Only students actually on this sheet's roster.
            SELECT r.out_student_name, r.out_enrolment_id INTO v_name, v_enrol
            FROM academic.fn_exam_sheet_roster(p_tenant_id, p_school_id, v_year_id, p_academic_class_id, v_section) r
            WHERE r.out_student_id = v_sid;

            IF v_name IS NULL THEN
                RAISE EXCEPTION 'A student on this sheet is not enrolled in this class and section.';
            END IF;

            IF v_marks IS NOT NULL AND (v_marks < 0 OR v_marks > v_max) THEN
                RAISE EXCEPTION 'Marks for % must be between 0 and %.', v_name, v_max;
            END IF;

            INSERT INTO academic.exam_marks
                (tenant_id, school_id, exam_id, academic_class_id, subject_id, student_id,
                 enrolment_id, section, marks_obtained, is_absent, created_by, created_at)
            VALUES
                (p_tenant_id, p_school_id, p_exam_id, p_academic_class_id, p_subject_id, v_sid,
                 v_enrol, v_section, v_marks, v_absent, p_action_user_id, now())
            ON CONFLICT ON CONSTRAINT uq_exam_marks
            DO UPDATE SET marks_obtained    = EXCLUDED.marks_obtained,
                          is_absent         = EXCLUDED.is_absent,
                          enrolment_id      = EXCLUDED.enrolment_id,
                          academic_class_id = EXCLUDED.academic_class_id,
                          section           = EXCLUDED.section,
                          updated_by        = p_action_user_id,
                          updated_at        = now()
            -- An unchanged mark is not rewritten, so updated_by keeps meaning
            -- "who last changed it" and the history trigger stays quiet.
            WHERE academic.exam_marks.marks_obtained    IS DISTINCT FROM EXCLUDED.marks_obtained
               OR academic.exam_marks.is_absent         IS DISTINCT FROM EXCLUDED.is_absent
               OR academic.exam_marks.enrolment_id      IS DISTINCT FROM EXCLUDED.enrolment_id
               OR academic.exam_marks.academic_class_id IS DISTINCT FROM EXCLUDED.academic_class_id
               OR academic.exam_marks.section           IS DISTINCT FROM EXCLUDED.section;

            v_saved := v_saved + 1;
        END LOOP;

        IF p_finalize THEN
            -- Anyone still without a row is recorded Absent, which is exactly what
            -- the finalize dialog warns the teacher about.
            INSERT INTO academic.exam_marks
                (tenant_id, school_id, exam_id, academic_class_id, subject_id, student_id,
                 enrolment_id, section, marks_obtained, is_absent, created_by, created_at)
            SELECT p_tenant_id, p_school_id, p_exam_id, p_academic_class_id, p_subject_id,
                   r.out_student_id, r.out_enrolment_id, v_section, NULL, TRUE,
                   p_action_user_id, now()
            FROM academic.fn_exam_sheet_roster(p_tenant_id, p_school_id, v_year_id, p_academic_class_id, v_section) r
            WHERE NOT EXISTS (SELECT 1 FROM academic.exam_marks m
                              WHERE m.exam_id    = p_exam_id
                                AND m.subject_id = p_subject_id
                                AND m.student_id = r.out_student_id);

            GET DIAGNOSTICS v_added = ROW_COUNT;

            -- A blank that was saved as a draft (or a mark cleared later) is just
            -- as unmarked: it is recorded Absent too.
            UPDATE academic.exam_marks m
               SET is_absent  = TRUE,
                   updated_by = p_action_user_id,
                   updated_at = now()
             WHERE m.exam_id    = p_exam_id
               AND m.subject_id = p_subject_id
               AND m.marks_obtained IS NULL
               AND NOT m.is_absent
               AND m.student_id IN (SELECT r.out_student_id
                                    FROM academic.fn_exam_sheet_roster(p_tenant_id, p_school_id, v_year_id,
                                                                       p_academic_class_id, v_section) r);

            GET DIAGNOSTICS v_blank = ROW_COUNT;
            v_added := v_added + v_blank;

            INSERT INTO academic.exam_mark_sheets
                (tenant_id, school_id, exam_id, academic_class_id, subject_id, section,
                 is_finalized, finalized_by, finalized_at)
            VALUES
                (p_tenant_id, p_school_id, p_exam_id, p_academic_class_id, p_subject_id, v_section,
                 TRUE, p_action_user_id, now())
            ON CONFLICT ON CONSTRAINT uq_exam_mark_sheets
            DO UPDATE SET is_finalized = TRUE,
                          finalized_by = p_action_user_id,
                          finalized_at = now();
        END IF;

        OPEN p_result FOR
        SELECT TRUE AS success,
               v_saved AS saved,
               v_added AS marked_absent,
               p_finalize AS is_finalized,
               CASE WHEN p_finalize
                    THEN 'Marks finalized and locked.'
                    ELSE 'Marks saved as draft.' END AS message;

        OPEN p_result2 FOR SELECT 1 WHERE FALSE;

    ELSIF p_operation = 'GetMarkScope' THEN

        -- The sheets of this exam the calling user teaches (2026-10-12):
        -- every subject of a section they are class teacher of, plus each
        -- subject the timetable gives them in a section. A teacher with only
        -- exams.marks is limited to these; the caller skips this for school
        -- admins and exams.manage (the proc cannot see roles).
        -- Sections are per session, so joining on the exam's class id keeps
        -- this to the exam's own academic year.
        OPEN p_result FOR
        SELECT DISTINCT es.academic_class_id,
               sec.section_name AS section,
               es.subject_id
        FROM academic.exam_subjects es
        JOIN academic.academic_class_sections sec
             ON sec.academic_class_id = es.academic_class_id
            AND sec.tenant_id = p_tenant_id
            AND sec.school_id = p_school_id
            AND COALESCE(sec.is_deleted, FALSE) = FALSE
        JOIN core.staff st
             ON st.tenant_id = p_tenant_id
            AND st.school_id = p_school_id
            AND st.user_id   = p_action_user_id
            -- A teacher who has left must not keep entering marks.
            AND COALESCE(st.is_active, TRUE)   = TRUE
            AND COALESCE(st.is_deleted, FALSE) = FALSE
        WHERE es.exam_id   = p_exam_id
          AND es.tenant_id = p_tenant_id
          AND es.school_id = p_school_id
          AND (sec.class_teacher_staff_id = st.staff_id
               OR EXISTS (SELECT 1 FROM academic.timetable t
                          WHERE t.academic_class_section_id = sec.academic_class_section_id
                            AND t.subject_id = es.subject_id
                            AND t.staff_id   = st.staff_id
                            AND t.tenant_id  = p_tenant_id
                            AND t.school_id  = p_school_id));

        OPEN p_result2 FOR SELECT 1 WHERE FALSE;

    ELSIF p_operation = 'ReopenSheet' THEN

        -- Admin-only; the caller enforces that (the proc cannot see roles).
        IF COALESCE(p_subject_id, 0) <= 0 THEN
            RAISE EXCEPTION 'Pick a subject first.';
        END IF;
        IF v_results = 'Published' THEN
            RAISE EXCEPTION 'The results of this exam are published. Unpublish the results before reopening a sheet.';
        END IF;

        UPDATE academic.exam_mark_sheets
           SET is_finalized = FALSE,
               reopened_by  = p_action_user_id,
               reopened_at  = now()
         WHERE exam_id           = p_exam_id
           AND academic_class_id = p_academic_class_id
           AND subject_id        = p_subject_id
           AND section           = v_section
           AND tenant_id        = p_tenant_id
           AND school_id        = p_school_id
           AND is_finalized;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'That sheet is not finalized.';
        END IF;

        OPEN p_result FOR SELECT TRUE AS success, 'Sheet reopened for editing.' AS message;
        OPEN p_result2 FOR SELECT 1 WHERE FALSE;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;


-- ============================================================================
-- Exam Schedule — the school's exams and the per-class datesheet behind each one.
--
--   academic.exams                            one row per exam, per academic year
--   academic.exam_subjects                    the datesheet: per CLASS, per subject
--   academic.exam_class_sections              optional: which sections sit it
--   academic.sp_school_admin_exam_manage      GetExams | GetExamList | GetExam
--                                             | GetClassSections | SaveExam
--                                             | SetStatus | DeleteExam | GetDatesheet
--
-- An exam is SCHOOL-WIDE: "Unit Test 1" exists once per academic year. The
-- classes that sit it, and what each class sits on which date and at what time,
-- live in exam_subjects — so one exam covers many classes and each class can
-- have a different subject list, dates, times and marks.
--
-- Sections are OPTIONAL. No exam_class_sections rows for a (exam, class) means
-- the whole class sits it, which is the default. Ticking sections narrows it.
--
-- status is Draft | Published. Draft is visible only on the Exam Schedule page;
-- GetDatesheet returns Published exams only, and the Marks Entry dropdown
-- filters to Published too. That is the DATESHEET status; the RESULT has its own
-- (results_status, see exam_results_publish.sql). While results are published
-- the exam cannot be edited or moved back to draft.
--
-- Subjects come from Subject Management (academic.class_subjects), so SaveExam
-- rejects any subject a class does not study, then replaces each class's
-- datesheet wholesale.
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

CREATE TABLE IF NOT EXISTS academic.exams (
    exam_id           serial PRIMARY KEY,
    tenant_id         integer NOT NULL,
    school_id         integer NOT NULL,
    academic_year_id  integer NOT NULL,
    exam_name         varchar(80) NOT NULL,
    -- Lookup CODE from config.lookup_value category 'ExamType' (optional).
    exam_type         varchar(80),
    start_date        date NOT NULL,
    end_date          date NOT NULL,
    status            varchar(20) NOT NULL DEFAULT 'Draft',
    published_by      integer,
    published_at      timestamptz,
    is_deleted        boolean NOT NULL DEFAULT FALSE,
    created_by        integer,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_by        integer,
    updated_at        timestamptz,
    deleted_by        integer,
    deleted_at        timestamptz,

    CONSTRAINT chk_exams_scope  CHECK (tenant_id > 1 AND school_id > 0),
    CONSTRAINT chk_exams_dates  CHECK (end_date >= start_date),
    CONSTRAINT chk_exams_status CHECK (status IN ('Draft', 'Published'))
);

-- One "Half Yearly" per academic year, case-insensitively. Soft-deleted rows are
-- excluded so a name can be reused after a delete.
CREATE UNIQUE INDEX IF NOT EXISTS uq_exams_name
    ON academic.exams (tenant_id, school_id, academic_year_id, lower(exam_name))
    WHERE NOT is_deleted;

CREATE INDEX IF NOT EXISTS ix_exams_year
    ON academic.exams (tenant_id, school_id, academic_year_id)
    WHERE NOT is_deleted;

CREATE INDEX IF NOT EXISTS ix_exams_status
    ON academic.exams (tenant_id, school_id, academic_year_id, status)
    WHERE NOT is_deleted;

CREATE TABLE IF NOT EXISTS academic.exam_subjects (
    exam_subject_id   serial PRIMARY KEY,
    tenant_id         integer NOT NULL,
    school_id         integer NOT NULL,
    exam_id           integer NOT NULL,
    -- Which class sits this paper. A class is part of the exam exactly when it
    -- has rows here, so there is no separate exam-classes table to keep in step.
    academic_class_id integer NOT NULL,
    subject_id        integer NOT NULL,
    exam_date         date,
    start_time        time,
    end_time          time,
    max_marks         numeric(6,2) NOT NULL DEFAULT 100,
    pass_marks        numeric(6,2) NOT NULL DEFAULT 35,
    display_order     integer NOT NULL DEFAULT 0,

    CONSTRAINT chk_exam_subjects_marks
        CHECK (max_marks > 0 AND pass_marks >= 0 AND pass_marks <= max_marks),
    CONSTRAINT chk_exam_subjects_time
        CHECK (start_time IS NULL OR end_time IS NULL OR end_time > start_time),
    CONSTRAINT fk_exam_subjects_exam    FOREIGN KEY (exam_id)
        REFERENCES academic.exams (exam_id) ON DELETE CASCADE,
    CONSTRAINT fk_exam_subjects_class   FOREIGN KEY (academic_class_id)
        REFERENCES academic.academic_classes (academic_class_id),
    CONSTRAINT fk_exam_subjects_subject FOREIGN KEY (subject_id)
        REFERENCES academic.school_subjects (subject_id),
    CONSTRAINT uq_exam_subjects UNIQUE (exam_id, academic_class_id, subject_id)
);

CREATE INDEX IF NOT EXISTS ix_exam_subjects_class
    ON academic.exam_subjects (tenant_id, school_id, academic_class_id, exam_date);

-- Optional section targeting. No rows for a (exam, class) = the whole class.
CREATE TABLE IF NOT EXISTS academic.exam_class_sections (
    exam_class_section_id serial PRIMARY KEY,
    tenant_id             integer NOT NULL,
    school_id             integer NOT NULL,
    exam_id               integer NOT NULL,
    academic_class_id     integer NOT NULL,
    section               varchar(20) NOT NULL,

    CONSTRAINT chk_exam_class_sections_scope CHECK (tenant_id > 1 AND school_id > 0),
    CONSTRAINT chk_exam_class_sections_blank CHECK (btrim(section) <> ''),
    CONSTRAINT fk_exam_class_sections_exam FOREIGN KEY (exam_id)
        REFERENCES academic.exams (exam_id) ON DELETE CASCADE,
    CONSTRAINT uq_exam_class_sections UNIQUE (exam_id, academic_class_id, section)
);


-- ── Two more platform-default exam types ────────────────────────────────────
INSERT INTO config.lookup_value (tenant_id, school_id, category, code, label, display_order, is_system) VALUES
    (0,0,'ExamType','half','Half Yearly',5,FALSE),
    (0,0,'ExamType','preboard','Pre Board',6,FALSE)
ON CONFLICT ON CONSTRAINT uq_lookup_value DO NOTHING;


-- ── Resolve an exam type code to its label ──────────────────────────────────
CREATE OR REPLACE FUNCTION academic.fn_exam_type_label(
    p_tenant_id integer,
    p_school_id integer,
    p_code      varchar)
RETURNS text
LANGUAGE sql
STABLE
AS $function$
    SELECT COALESCE(
        (SELECT lv.label
         FROM config.lookup_value lv
         WHERE lv.category = 'ExamType' AND lv.code = p_code
           AND lv.is_active AND NOT lv.is_deleted
           AND ((lv.tenant_id = p_tenant_id AND lv.school_id = p_school_id)
             OR (lv.tenant_id = 0 AND lv.school_id = 0))
         ORDER BY (lv.tenant_id = p_tenant_id) DESC
         LIMIT 1),
        p_code, '');
$function$;


-- ── Do two exams touch the same students in one class? ──────────────────────
-- No exam_class_sections rows means the whole class, so an empty set on either
-- side overlaps everything. Used by the clash guard: 1st-A sitting a paper does
-- not clash with 1st-B sitting one at the same time.
CREATE OR REPLACE FUNCTION academic.fn_exam_sections_overlap(
    p_exam_a  integer,
    p_exam_b  integer,
    p_class_id integer)
RETURNS boolean
LANGUAGE sql
STABLE
AS $function$
    SELECT
        NOT EXISTS (SELECT 1 FROM academic.exam_class_sections
                    WHERE exam_id = p_exam_a AND academic_class_id = p_class_id)
     OR NOT EXISTS (SELECT 1 FROM academic.exam_class_sections
                    WHERE exam_id = p_exam_b AND academic_class_id = p_class_id)
     OR EXISTS (SELECT 1
                FROM academic.exam_class_sections x
                JOIN academic.exam_class_sections y
                  ON y.exam_id           = p_exam_b
                 AND y.academic_class_id = p_class_id
                 AND y.section           = x.section
                WHERE x.exam_id = p_exam_a AND x.academic_class_id = p_class_id);
$function$;


CREATE OR REPLACE PROCEDURE academic.sp_school_admin_exam_manage(
    IN    p_operation         character varying,
    IN    p_tenant_id         integer,
    IN    p_school_id         integer,
    IN    p_action_user_id    integer,
    IN    p_academic_year_id  integer   DEFAULT NULL,
    IN    p_academic_class_id integer   DEFAULT NULL,
    IN    p_exam_id           integer   DEFAULT NULL,
    IN    p_exam_name         character varying DEFAULT NULL,
    IN    p_exam_type         character varying DEFAULT NULL,
    IN    p_start_date        date      DEFAULT NULL,
    IN    p_end_date          date      DEFAULT NULL,
    IN    p_status            character varying DEFAULT NULL,
    IN    p_items             text      DEFAULT NULL,
    INOUT p_result            refcursor DEFAULT 'exam_cursor'::refcursor,
    INOUT p_result2           refcursor DEFAULT 'exam_cursor2'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_year     integer;
    v_items    jsonb;
    v_class    jsonb;
    v_subject  jsonb;
    v_exam_id  integer;
    v_name     text;
    v_cls      integer;
    v_sid      integer;
    v_sname    text;
    v_date     date;
    v_from     time;
    v_to       time;
    v_max      numeric;
    v_pass     numeric;
    v_ord      integer;
    v_sec      text;
    v_secs     text[];
    v_classes  integer[] := '{}';
    v_keep     integer[];
    v_total    integer   := 0;
    v_clash    text;
    v_missing  text;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    v_year := COALESCE(p_academic_year_id,
        (SELECT academic_year_id
         FROM academic.academic_years
         WHERE tenant_id = p_tenant_id AND school_id = p_school_id
           AND is_current AND NOT is_deleted
         ORDER BY academic_year_id DESC
         LIMIT 1));

    IF p_operation = 'GetExams' THEN

        -- Exam headers, for the dropdowns. Callers that must not show drafts
        -- filter on status.
        OPEN p_result FOR
        SELECT
            e.exam_id,
            e.exam_name,
            COALESCE(e.exam_type, '') AS exam_type,
            academic.fn_exam_type_label(p_tenant_id, p_school_id, e.exam_type) AS type_label,
            e.start_date,
            e.end_date,
            e.status,
            d.class_count,
            d.subject_count,
            COALESCE(d.class_names, '') AS class_names,
            e.results_status
        FROM academic.exams e
        LEFT JOIN (
            SELECT es.exam_id,
                   COUNT(DISTINCT es.academic_class_id)::int AS class_count,
                   COUNT(*)::int                             AS subject_count,
                   string_agg(DISTINCT c.class_name, ', ')   AS class_names
            FROM academic.exam_subjects es
            JOIN academic.academic_classes c ON c.academic_class_id = es.academic_class_id
            GROUP BY es.exam_id
        ) d ON d.exam_id = e.exam_id
        WHERE e.tenant_id = p_tenant_id
          AND e.school_id = p_school_id
          AND e.academic_year_id = v_year
          AND NOT e.is_deleted
        ORDER BY e.start_date DESC, e.exam_id DESC;

        OPEN p_result2 FOR
        SELECT v_year AS academic_year_id,
               COALESCE((SELECT academic_year_name FROM academic.academic_years
                         WHERE academic_year_id = v_year
                           AND tenant_id = p_tenant_id AND school_id = p_school_id), '') AS academic_year_name;

    ELSIF p_operation = 'GetExamList' THEN

        -- ONE ROW PER CLASS-SECTION — the Exam Schedule list. A class with no
        -- section rows yields a single row with section '' (whole class).
        OPEN p_result FOR
        SELECT
            e.exam_id,
            e.exam_name,
            academic.fn_exam_type_label(p_tenant_id, p_school_id, e.exam_type) AS type_label,
            COALESCE(ay.academic_year_name, '') AS academic_year_name,
            d.academic_class_id,
            c.class_name,
            COALESCE(s.section, '') AS section,
            e.start_date,
            e.end_date,
            e.status,
            d.subject_count,
            e.results_status
        FROM academic.exams e
        JOIN (SELECT es.exam_id, es.academic_class_id, COUNT(*)::int AS subject_count
              FROM academic.exam_subjects es
              GROUP BY es.exam_id, es.academic_class_id) d
          ON d.exam_id = e.exam_id
        JOIN academic.academic_classes c ON c.academic_class_id = d.academic_class_id
        LEFT JOIN academic.exam_class_sections s
               ON s.exam_id = e.exam_id AND s.academic_class_id = d.academic_class_id
        LEFT JOIN academic.academic_years ay ON ay.academic_year_id = e.academic_year_id
        WHERE e.tenant_id = p_tenant_id
          AND e.school_id = p_school_id
          AND e.academic_year_id = v_year
          AND NOT e.is_deleted
        ORDER BY e.start_date DESC, e.exam_id DESC, c.display_order, c.class_name,
                 COALESCE(s.section, '');

        OPEN p_result2 FOR
        SELECT v_year AS academic_year_id,
               COALESCE((SELECT academic_year_name FROM academic.academic_years
                         WHERE academic_year_id = v_year
                           AND tenant_id = p_tenant_id AND school_id = p_school_id), '') AS academic_year_name;

    ELSIF p_operation = 'GetClassSections' THEN

        -- Sections of one class that actually have students this year — the
        -- optional section chooser on the Exam Schedule form.
        OPEN p_result FOR
        SELECT COALESCE(TRIM(en.section), '') AS section, COUNT(*)::int AS student_count
        FROM core.student_enrolment en
        WHERE en.tenant_id = p_tenant_id
          AND en.school_id = p_school_id
          AND en.academic_year_id  = v_year
          AND en.academic_class_id = p_academic_class_id
          AND COALESCE(en.status, '') <> 'Left'
          AND COALESCE(TRIM(en.section), '') <> ''
        GROUP BY COALESCE(TRIM(en.section), '')
        ORDER BY 1;

        OPEN p_result2 FOR SELECT 1 WHERE FALSE;

    ELSIF p_operation = 'GetExam' THEN

        OPEN p_result FOR
        SELECT
            e.exam_id,
            e.exam_name,
            COALESCE(e.exam_type, '') AS exam_type,
            e.start_date,
            e.end_date,
            e.status
        FROM academic.exams e
        WHERE e.exam_id   = p_exam_id
          AND e.tenant_id = p_tenant_id
          AND e.school_id = p_school_id
          AND NOT e.is_deleted;

        -- Every class's datesheet. The class's chosen sections ride along as a
        -- comma list so the form can rebuild the section ticks in one read.
        OPEN p_result2 FOR
        SELECT es.academic_class_id,
               c.class_name,
               es.subject_id,
               s.subject_name,
               es.exam_date,
               es.start_time,
               es.end_time,
               es.max_marks,
               es.pass_marks,
               COALESCE((SELECT string_agg(x.section, ',' ORDER BY x.section)
                         FROM academic.exam_class_sections x
                         WHERE x.exam_id = es.exam_id
                           AND x.academic_class_id = es.academic_class_id), '') AS class_sections
        FROM academic.exam_subjects es
        JOIN academic.school_subjects  s ON s.subject_id        = es.subject_id
        JOIN academic.academic_classes c ON c.academic_class_id = es.academic_class_id
        WHERE es.exam_id   = p_exam_id
          AND es.tenant_id = p_tenant_id
          AND es.school_id = p_school_id
        ORDER BY c.display_order, c.class_name, es.display_order, s.subject_name;

    ELSIF p_operation = 'GetDatesheet' THEN

        -- Published only: a draft datesheet must not reach teachers or parents.
        OPEN p_result FOR
        SELECT es.exam_date,
               es.start_time,
               es.end_time,
               es.academic_class_id,
               c.class_name,
               COALESCE((SELECT string_agg(x.section, ', ' ORDER BY x.section)
                         FROM academic.exam_class_sections x
                         WHERE x.exam_id = es.exam_id
                           AND x.academic_class_id = es.academic_class_id), '') AS section_list,
               s.subject_name,
               es.max_marks,
               es.pass_marks,
               e.exam_id,
               e.exam_name,
               academic.fn_exam_type_label(p_tenant_id, p_school_id, e.exam_type) AS type_label,
               -- Already-saved rows can clash (they predate the guard). Flag them
               -- so the datesheet shows what needs fixing instead of hiding it.
               EXISTS (
                   SELECT 1
                   FROM academic.exam_subjects o
                   JOIN academic.exams oe ON oe.exam_id = o.exam_id
                                         AND NOT oe.is_deleted
                                         AND oe.academic_year_id = v_year
                   WHERE o.academic_class_id = es.academic_class_id
                     AND o.exam_date         = es.exam_date
                     AND o.exam_subject_id  <> es.exam_subject_id
                     AND (o.start_time IS NULL OR o.end_time IS NULL
                       OR es.start_time IS NULL OR es.end_time IS NULL
                       OR (es.start_time < o.end_time AND o.start_time < es.end_time))
                     AND (o.exam_id = es.exam_id
                       OR academic.fn_exam_sections_overlap(es.exam_id, o.exam_id, es.academic_class_id))
               ) AS has_clash
        FROM academic.exam_subjects es
        JOIN academic.exams           e ON e.exam_id           = es.exam_id
        JOIN academic.school_subjects s ON s.subject_id        = es.subject_id
        JOIN academic.academic_classes c ON c.academic_class_id = es.academic_class_id
        WHERE es.tenant_id = p_tenant_id
          AND es.school_id = p_school_id
          AND e.academic_year_id = v_year
          AND NOT e.is_deleted
          AND e.status = 'Published'
          AND (COALESCE(p_academic_class_id, 0) = 0
               OR es.academic_class_id = p_academic_class_id)
          AND (COALESCE(p_exam_id, 0) = 0 OR e.exam_id = p_exam_id)
        ORDER BY es.exam_date NULLS LAST, es.start_time NULLS LAST,
                 c.display_order, c.class_name, es.display_order;

        OPEN p_result2 FOR
        SELECT v_year AS academic_year_id,
               COALESCE((SELECT academic_year_name FROM academic.academic_years
                         WHERE academic_year_id = v_year
                           AND tenant_id = p_tenant_id AND school_id = p_school_id), '') AS academic_year_name;

    ELSIF p_operation = 'SetStatus' THEN

        IF COALESCE(p_exam_id, 0) = 0 THEN
            RAISE EXCEPTION 'Pick an exam first.';
        END IF;
        IF COALESCE(p_status, '') NOT IN ('Draft', 'Published') THEN
            RAISE EXCEPTION 'Status must be Draft or Published.';
        END IF;

        -- Published results sit on a published datesheet; pull them back first.
        IF p_status = 'Draft'
           AND EXISTS (SELECT 1 FROM academic.exams
                       WHERE exam_id = p_exam_id AND tenant_id = p_tenant_id AND school_id = p_school_id
                         AND results_status = 'Published') THEN
            RAISE EXCEPTION 'The results of this exam are published. Unpublish the results before moving it back to draft.';
        END IF;

        -- An exam with no datesheet has nothing to publish.
        IF p_status = 'Published'
           AND NOT EXISTS (SELECT 1 FROM academic.exam_subjects
                           WHERE exam_id = p_exam_id) THEN
            RAISE EXCEPTION 'This exam has no subjects yet, so there is nothing to publish.';
        END IF;

        -- Every paper needs its date before the datesheet goes out, or the admit
        -- card prints "-" for it (QA BUG-094).
        IF p_status = 'Published' THEN
            SELECT string_agg(COALESCE(sub.subject_name, 'Subject ' || es.subject_id)
                              || ' (' || COALESCE(c.class_name, 'class') || ')', ', ')
              INTO v_missing
            FROM academic.exam_subjects es
            LEFT JOIN academic.school_subjects sub ON sub.subject_id = es.subject_id
            LEFT JOIN academic.academic_classes c ON c.academic_class_id = es.academic_class_id
            WHERE es.exam_id = p_exam_id AND NULLIF(es.exam_date::text, '') IS NULL;
            IF v_missing IS NOT NULL THEN
                RAISE EXCEPTION 'These papers have no date yet: %. Give every paper a date before publishing.', v_missing;
            END IF;
        END IF;

        UPDATE academic.exams
           SET status       = p_status,
               published_by = CASE WHEN p_status = 'Published' THEN p_action_user_id ELSE published_by END,
               published_at = CASE WHEN p_status = 'Published' THEN now() ELSE published_at END,
               updated_by   = p_action_user_id,
               updated_at   = now()
         WHERE exam_id   = p_exam_id
           AND tenant_id = p_tenant_id
           AND school_id = p_school_id
           AND NOT is_deleted;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'That exam was not found.';
        END IF;

        OPEN p_result FOR
        SELECT TRUE AS success,
               p_status AS status,
               CASE WHEN p_status = 'Published'
                    THEN 'Exam published.' ELSE 'Exam moved back to draft.' END AS message;

        OPEN p_result2 FOR SELECT 1 WHERE FALSE;

    ELSIF p_operation = 'SaveExam' THEN

        v_name := trim(COALESCE(p_exam_name, ''));
        IF v_name = '' THEN
            RAISE EXCEPTION 'Enter an exam name.';
        END IF;
        IF p_start_date IS NULL OR p_end_date IS NULL THEN
            RAISE EXCEPTION 'Enter the exam start and end dates.';
        END IF;
        IF p_end_date < p_start_date THEN
            RAISE EXCEPTION 'End date cannot be before the start date.';
        END IF;
        IF v_year IS NULL THEN
            RAISE EXCEPTION 'No current academic year is set up.';
        END IF;

        -- p_items: [{ "classId": 1, "sections": ["A","B"],
        --             "subjects": [{subjectId, examDate, startTime, endTime, maxMarks, passMarks}] }]
        v_items := COALESCE(NULLIF(p_items, ''), '[]')::jsonb;

        IF COALESCE(p_exam_id, 0) = 0 THEN
            BEGIN
                INSERT INTO academic.exams
                    (tenant_id, school_id, academic_year_id,
                     exam_name, exam_type, start_date, end_date, status, created_by, created_at)
                VALUES
                    (p_tenant_id, p_school_id, v_year,
                     v_name, NULLIF(trim(COALESCE(p_exam_type, '')), ''),
                     p_start_date, p_end_date,
                     -- A new exam starts as a draft; publishing is deliberate.
                     COALESCE(NULLIF(p_status, ''), 'Draft'),
                     p_action_user_id, now())
                RETURNING exam_id INTO v_exam_id;
            EXCEPTION WHEN unique_violation THEN
                RAISE EXCEPTION 'An exam called "%" already exists this year.', v_name;
            END;
        ELSE
            v_exam_id := p_exam_id;
            IF NOT EXISTS (SELECT 1 FROM academic.exams
                           WHERE exam_id = v_exam_id
                             AND tenant_id = p_tenant_id AND school_id = p_school_id
                             AND NOT is_deleted) THEN
                RAISE EXCEPTION 'That exam was not found.';
            END IF;
            -- Changing papers or max marks would change results parents have seen.
            IF EXISTS (SELECT 1 FROM academic.exams
                       WHERE exam_id = v_exam_id AND results_status = 'Published') THEN
                RAISE EXCEPTION 'The results of this exam are published, so it cannot be edited. Unpublish the results first.';
            END IF;
            BEGIN
                UPDATE academic.exams
                   SET exam_name  = v_name,
                       exam_type  = NULLIF(trim(COALESCE(p_exam_type, '')), ''),
                       start_date = p_start_date,
                       end_date   = p_end_date,
                       -- Editing does not silently change whether it is published.
                       status     = COALESCE(NULLIF(p_status, ''), status),
                       updated_by = p_action_user_id,
                       updated_at = now()
                 WHERE exam_id = v_exam_id;
            EXCEPTION WHEN unique_violation THEN
                RAISE EXCEPTION 'An exam called "%" already exists this year.', v_name;
            END;
        END IF;

        FOR v_class IN SELECT value FROM jsonb_array_elements(v_items)
        LOOP
            v_cls := NULLIF(v_class->>'classId', '')::int;
            CONTINUE WHEN COALESCE(v_cls, 0) <= 0;

            IF NOT EXISTS (SELECT 1 FROM academic.academic_classes
                           WHERE academic_class_id = v_cls
                             AND tenant_id = p_tenant_id AND school_id = p_school_id
                             AND NOT is_deleted) THEN
                RAISE EXCEPTION 'A selected class does not belong to this school.';
            END IF;

            v_ord  := 0;
            v_keep := '{}';

            FOR v_subject IN SELECT value FROM jsonb_array_elements(COALESCE(v_class->'subjects', '[]'::jsonb))
            LOOP
                v_sid := NULLIF(v_subject->>'subjectId', '')::int;
                CONTINUE WHEN v_sid IS NULL;

                v_date := NULLIF(v_subject->>'examDate', '')::date;
                v_from := NULLIF(v_subject->>'startTime', '')::time;
                v_to   := NULLIF(v_subject->>'endTime', '')::time;
                v_max  := COALESCE(NULLIF(v_subject->>'maxMarks',  '')::numeric, 100);
                v_pass := COALESCE(NULLIF(v_subject->>'passMarks', '')::numeric, 35);

                SELECT subject_name INTO v_sname
                FROM academic.school_subjects
                WHERE subject_id = v_sid AND tenant_id = p_tenant_id AND school_id = p_school_id;

                IF v_sname IS NULL THEN
                    RAISE EXCEPTION 'That subject does not belong to this school.';
                END IF;

                IF NOT EXISTS (SELECT 1 FROM academic.class_subjects cs
                               WHERE cs.tenant_id = p_tenant_id AND cs.school_id = p_school_id
                                 AND cs.academic_year_id  = v_year
                                 AND cs.academic_class_id = v_cls
                                 AND cs.subject_id        = v_sid) THEN
                    RAISE EXCEPTION '% is not a subject of %. Check Subject Management.',
                        v_sname, (SELECT class_name FROM academic.academic_classes WHERE academic_class_id = v_cls);
                END IF;

                IF v_max <= 0 THEN
                    RAISE EXCEPTION 'Max marks for % must be more than 0.', v_sname;
                END IF;
                IF v_pass < 0 OR v_pass > v_max THEN
                    RAISE EXCEPTION 'Pass marks for % cannot be more than its max marks.', v_sname;
                END IF;
                IF v_date IS NOT NULL AND (v_date < p_start_date OR v_date > p_end_date) THEN
                    RAISE EXCEPTION '% is scheduled outside the exam dates.', v_sname;
                END IF;
                IF v_from IS NOT NULL AND v_to IS NOT NULL AND v_to <= v_from THEN
                    RAISE EXCEPTION 'The finish time for % must be after its start time.', v_sname;
                END IF;

                -- A paper cannot fall on a day the School Calendar has the school shut.
                IF v_date IS NOT NULL
                   AND academic.fn_school_day_type(p_tenant_id, p_school_id, v_date) IN ('holiday', 'weekly_off') THEN
                    RAISE EXCEPTION '% is scheduled on % (%), when the school is closed. Pick a working day.',
                        v_sname, to_char(v_date, 'DD Mon YYYY'),
                        COALESCE((SELECT title FROM academic.school_calendar
                                  WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                                    AND calendar_date = to_char(v_date, 'YYYY-MM-DD')),
                                 'weekly off');
                END IF;

                -- Marks already entered must still fit the paper.
                IF EXISTS (SELECT 1 FROM academic.exam_marks m
                           WHERE m.exam_id = v_exam_id AND m.academic_class_id = v_cls
                             AND m.subject_id = v_sid AND m.marks_obtained > v_max) THEN
                    RAISE EXCEPTION 'Max marks for % cannot go below % — that mark has already been entered.',
                        v_sname,
                        (SELECT MAX(m.marks_obtained) FROM academic.exam_marks m
                         WHERE m.exam_id = v_exam_id AND m.academic_class_id = v_cls AND m.subject_id = v_sid);
                END IF;

                v_ord := v_ord + 1;

                INSERT INTO academic.exam_subjects
                    (tenant_id, school_id, exam_id, academic_class_id, subject_id,
                     exam_date, start_time, end_time, max_marks, pass_marks, display_order)
                VALUES
                    (p_tenant_id, p_school_id, v_exam_id, v_cls, v_sid,
                     v_date, v_from, v_to, v_max, v_pass, v_ord)
                ON CONFLICT ON CONSTRAINT uq_exam_subjects
                DO UPDATE SET exam_date     = EXCLUDED.exam_date,
                              start_time    = EXCLUDED.start_time,
                              end_time      = EXCLUDED.end_time,
                              max_marks     = EXCLUDED.max_marks,
                              pass_marks    = EXCLUDED.pass_marks,
                              display_order = EXCLUDED.display_order;

                v_keep := v_keep || v_sid;
            END LOOP;

            IF v_ord = 0 THEN
                RAISE EXCEPTION '% has no subjects on its datesheet.',
                    (SELECT class_name FROM academic.academic_classes WHERE academic_class_id = v_cls);
            END IF;

            -- A paper that already has marks cannot be dropped: the marks would be
            -- orphaned. Clear them on Marks Entry first.
            SELECT s.subject_name INTO v_clash
            FROM academic.exam_marks m
            JOIN academic.school_subjects s ON s.subject_id = m.subject_id
            WHERE m.exam_id = v_exam_id AND m.academic_class_id = v_cls
              AND NOT (m.subject_id = ANY (v_keep))
              AND (m.marks_obtained IS NOT NULL OR m.is_absent)
            LIMIT 1;
            IF v_clash IS NOT NULL THEN
                RAISE EXCEPTION '% already has marks entered for %, so it cannot be removed from the datesheet.',
                    v_clash, (SELECT class_name FROM academic.academic_classes WHERE academic_class_id = v_cls);
            END IF;

            DELETE FROM academic.exam_subjects
            WHERE exam_id = v_exam_id
              AND academic_class_id = v_cls
              AND NOT (subject_id = ANY (v_keep));

            -- Sections: replace-all. An empty list means the whole class, which
            -- is stored as no rows at all.
            SELECT COALESCE(array_agg(DISTINCT trim(x)) FILTER (WHERE trim(x) <> ''), '{}')
              INTO v_secs
            FROM jsonb_array_elements_text(COALESCE(v_class->'sections', '[]'::jsonb)) AS t(x);

            DELETE FROM academic.exam_class_sections
            WHERE exam_id = v_exam_id
              AND academic_class_id = v_cls
              AND NOT (section = ANY (v_secs));

            IF array_length(v_secs, 1) IS NOT NULL THEN
                FOREACH v_sec IN ARRAY v_secs
                LOOP
                    INSERT INTO academic.exam_class_sections
                        (tenant_id, school_id, exam_id, academic_class_id, section)
                    VALUES (p_tenant_id, p_school_id, v_exam_id, v_cls, v_sec)
                    ON CONFLICT ON CONSTRAINT uq_exam_class_sections DO NOTHING;
                END LOOP;
            END IF;

            v_classes := v_classes || v_cls;
            v_total   := v_total + v_ord;
        END LOOP;

        IF array_length(v_classes, 1) IS NULL THEN
            RAISE EXCEPTION 'Pick at least one class for this exam.';
        END IF;

        -- A class dropped from the exam loses its datesheet and its sections —
        -- unless marks were already entered for it.
        SELECT c.class_name INTO v_clash
        FROM academic.exam_marks m
        JOIN academic.academic_classes c ON c.academic_class_id = m.academic_class_id
        WHERE m.exam_id = v_exam_id
          AND NOT (m.academic_class_id = ANY (v_classes))
          AND (m.marks_obtained IS NOT NULL OR m.is_absent)
        LIMIT 1;
        IF v_clash IS NOT NULL THEN
            RAISE EXCEPTION 'Class % already has marks entered for this exam, so it cannot be removed.', v_clash;
        END IF;

        DELETE FROM academic.exam_subjects
        WHERE exam_id = v_exam_id
          AND NOT (academic_class_id = ANY (v_classes));
        DELETE FROM academic.exam_class_sections
        WHERE exam_id = v_exam_id
          AND NOT (academic_class_id = ANY (v_classes));

        -- ── No class can sit two papers at once ──
        -- Same class, same day: the papers must have times that do not overlap.
        -- A missing time cannot be told apart from an overlap, so it is refused
        -- too — if two papers share a day, say when each one runs.
        SELECT format('%s and %s are both on %s for %s',
                      sa.subject_name, sb.subject_name,
                      to_char(a.exam_date::date, 'DD Mon'), c.class_name)
          INTO v_clash
        FROM academic.exam_subjects a
        JOIN academic.exam_subjects b
          ON b.exam_id           = a.exam_id
         AND b.academic_class_id = a.academic_class_id
         AND b.exam_date         = a.exam_date
         AND b.exam_subject_id   > a.exam_subject_id
        JOIN academic.school_subjects  sa ON sa.subject_id = a.subject_id
        JOIN academic.school_subjects  sb ON sb.subject_id = b.subject_id
        JOIN academic.academic_classes c  ON c.academic_class_id = a.academic_class_id
        WHERE a.exam_id = v_exam_id
          AND a.exam_date IS NOT NULL
          AND (a.start_time IS NULL OR a.end_time IS NULL
            OR b.start_time IS NULL OR b.end_time IS NULL
            OR (a.start_time < b.end_time AND b.start_time < a.end_time))
        LIMIT 1;

        IF v_clash IS NOT NULL THEN
            RAISE EXCEPTION '% at the same time. Give them different days, or different times on the same day.', v_clash;
        END IF;

        -- Same check against the school's OTHER exams: a class cannot sit a paper
        -- for this exam while it is already sitting one for another.
        SELECT format('%s on %s for %s clashes with %s in "%s"',
                      sa.subject_name, to_char(a.exam_date::date, 'DD Mon'), c.class_name,
                      sb.subject_name, e2.exam_name)
          INTO v_clash
        FROM academic.exam_subjects a
        JOIN academic.exam_subjects b
          ON b.academic_class_id = a.academic_class_id
         AND b.exam_date         = a.exam_date
         AND b.exam_id          <> a.exam_id
        JOIN academic.exams e2 ON e2.exam_id = b.exam_id
                              AND NOT e2.is_deleted
                              AND e2.academic_year_id = v_year
        JOIN academic.school_subjects  sa ON sa.subject_id = a.subject_id
        JOIN academic.school_subjects  sb ON sb.subject_id = b.subject_id
        JOIN academic.academic_classes c  ON c.academic_class_id = a.academic_class_id
        WHERE a.exam_id = v_exam_id
          AND a.exam_date IS NOT NULL
          AND (a.start_time IS NULL OR a.end_time IS NULL
            OR b.start_time IS NULL OR b.end_time IS NULL
            OR (a.start_time < b.end_time AND b.start_time < a.end_time))
          AND academic.fn_exam_sections_overlap(a.exam_id, b.exam_id, a.academic_class_id)
        LIMIT 1;

        IF v_clash IS NOT NULL THEN
            RAISE EXCEPTION '%. Move one of them.', v_clash;
        END IF;

        OPEN p_result FOR
        SELECT TRUE AS success,
               v_exam_id AS exam_id,
               array_length(v_classes, 1) AS class_count,
               v_total AS subject_count,
               CASE WHEN COALESCE(p_exam_id, 0) = 0 THEN 'Exam saved as draft.' ELSE 'Exam updated.' END AS message;

        OPEN p_result2 FOR SELECT 1 WHERE FALSE;

    ELSIF p_operation = 'DeleteExam' THEN

        IF COALESCE(p_exam_id, 0) = 0 THEN
            RAISE EXCEPTION 'Pick an exam to delete.';
        END IF;

        -- Finalised mark sheets are a record; such an exam can be moved back to
        -- draft (hidden from results) but not deleted.
        IF EXISTS (SELECT 1 FROM academic.exam_mark_sheets
                   WHERE exam_id = p_exam_id AND tenant_id = p_tenant_id
                     AND school_id = p_school_id AND is_finalized) THEN
            RAISE EXCEPTION 'This exam has finalised mark sheets and cannot be deleted. Move it back to draft instead.';
        END IF;

        UPDATE academic.exams
           SET is_deleted = TRUE,
               deleted_by = p_action_user_id,
               deleted_at = now()
         WHERE exam_id   = p_exam_id
           AND tenant_id = p_tenant_id
           AND school_id = p_school_id
           AND NOT is_deleted;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'That exam was not found.';
        END IF;

        OPEN p_result FOR SELECT TRUE AS success, 'Exam deleted.' AS message;
        OPEN p_result2 FOR SELECT 1 WHERE FALSE;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;


