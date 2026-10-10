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
-- share a rank (1, 1, 3). Today's result rules apply: an absent paper is out of
-- the total, marks of a paper no longer on the datesheet do not count, and a
-- student absent from every paper has no percentage, no grade and no rank.
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
               COALESCE(SUM(es.max_marks) FILTER (WHERE m.marks_obtained IS NOT NULL), 0) AS total,
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
               CASE WHEN t.total > 0 THEN ROUND(t.obtained * 100.0 / t.total, 2) END AS pct
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
