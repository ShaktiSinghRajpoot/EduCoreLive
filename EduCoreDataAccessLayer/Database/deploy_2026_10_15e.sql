-- Bundle 2026-10-15e: flow fixes part 2 (publish refused when marks are missing, advance wallet on the due list, bus start date / left driver / seats, a driver who leaves is taken off the bus, payroll Mark Paid rebuilds the draft and waits for the month end). Run with:
--   psql -v ON_ERROR_STOP=1 --single-transaction -f deploy_2026_10_15e.sql
-- Sources (re-runnable, in this order): exam_results_publish.sql, fee_due_list.sql, transport_module.sql, sp_staff_manage.sql, staff_payroll.sql

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

        -- A child admitted after a sheet was finalised is on the roster but has no
        -- mark row, so they had no result, rank or report card and nobody was told.
        SELECT COUNT(*), MIN(r.out_student_name || ' (' || ps.out_class_name
                             || CASE WHEN ps.out_section = '' THEN '' ELSE '-' || ps.out_section END
                             || ' ' || ps.out_subject_name || ')')
          INTO v_pending, v_first
          FROM academic.fn_exam_pending_sheets(p_exam_id) ps
          CROSS JOIN LATERAL academic.fn_exam_sheet_roster(
                p_tenant_id, p_school_id,
                (SELECT e.academic_year_id FROM academic.exams e WHERE e.exam_id = p_exam_id),
                ps.out_class_id, ps.out_section) r
         WHERE NOT EXISTS (SELECT 1 FROM academic.exam_marks m
                            WHERE m.exam_id = p_exam_id AND m.subject_id = ps.out_subject_id
                              AND m.student_id = r.out_student_id);
        IF v_pending > 0 THEN
            RAISE EXCEPTION '% student mark(s) are missing (for example %): they joined after the sheet was finalised. Reopen that sheet and enter them.',
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
-- Fee Due Reminders — server-side paged/filtered defaulters list.
--
-- One row per student who owes money that has FALLEN DUE (due_date on or before
-- today), with that total, how many days the OLDEST unpaid installment is
-- overdue, and an ageing bucket. Next months' instalments are not owed yet, so
-- they are not counted -- the amount here is the {due_amount} a reminder sends.
--
-- Same rule as core.sp_fee_defaulters_get, including for students who have left:
-- they are listed while they still owe (student_status says so), so the office
-- can chase them and the two screens total the same.
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
    IN    p_bucket         varchar   DEFAULT NULL,   -- 0-30 | 31-60 | 60+
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
          AND (sl.due_date IS NULL OR sl.due_date::date <= CURRENT_DATE)
    ),
    agg AS (
        SELECT s.student_id, s.student_name, s.admission_no,
               s.class_name, s.section, s.roll_no, s.mobile,
               -- Parent email drives the Email reminder channel (father first, else mother).
               COALESCE(NULLIF(TRIM(s.father_email), ''), NULLIF(TRIM(s.mother_email), '')) AS parent_email,
               CASE WHEN COALESCE(s.is_active, TRUE) THEN 'Active'
                    ELSE COALESCE(NULLIF(TRIM(s.status), ''), 'Left') END AS student_status,
               -- money waiting in the student's advance wallet is set against what is due:
               -- a parent who overpaid is not a defaulter (no reminder, no admit-card hold)
               SUM(d.outstanding) - COALESCE(MAX(adv.balance), 0) AS total_outstanding,
               -- days the OLDEST unpaid installment is past its due date (0 = due today)
               COALESCE(MAX(CURRENT_DATE - d.due_date::date), 0) AS overdue_days
        FROM dues d
        JOIN core.students s ON s.student_id = d.student_id
        LEFT JOIN core.student_advance adv
               ON adv.student_id = s.student_id AND adv.tenant_id = p_tenant_id AND adv.school_id = p_school_id
        WHERE s.tenant_id = p_tenant_id
          AND s.school_id = p_school_id
          AND (p_class IS NULL OR TRIM(p_class) = '' OR s.class_name = p_class)
          AND (p_search IS NULL OR TRIM(p_search) = ''
               OR s.student_name        ILIKE '%' || p_search || '%'
               OR s.admission_no        ILIKE '%' || p_search || '%'
               OR COALESCE(s.mobile,'') ILIKE '%' || p_search || '%')
        GROUP BY s.student_id, s.student_name, s.admission_no,
                 s.class_name, s.section, s.roll_no, s.mobile,
                 s.father_email, s.mother_email, s.is_active, s.status
        HAVING SUM(d.outstanding) - COALESCE(MAX(adv.balance), 0) > 0
    ),
    filtered AS (
        SELECT a.*,
               CASE WHEN a.overdue_days <= 30 THEN '0-30'
                    WHEN a.overdue_days <= 60 THEN '31-60'
                    ELSE '60+' END AS bucket
        FROM agg a
    )
    SELECT f.student_id, f.student_name, f.admission_no, f.class_name, f.section, f.roll_no,
           f.mobile, f.parent_email, f.student_status,
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

-- ============================================================================
-- Transport Module — routes (+ per-stop fares), vehicles, student assignment
--
-- A student's monthly bus fee is the fare of the STOP they board at. Assigning a
-- student to a route+stop snapshots that fare and generates monthly 'Transport
-- Fee' dues in core.student_ledger, so the Fee Collection counter bills bus fee
-- automatically alongside tuition (same Monthly mechanism as student_master_fields.sql).
--
-- Tables : core.transport_routes, core.transport_stops, core.transport_vehicles,
--          core.student_transport
-- Procs  : sp_transport_route_manage, sp_transport_vehicle_manage,
--          sp_transport_assign_manage, sp_transport_routes_dropdown
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── Tables ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS core.transport_routes
(
    route_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   integer NOT NULL,
    school_id   integer NOT NULL,
    route_name  varchar(80)  NOT NULL,
    description varchar(200),
    is_active   boolean NOT NULL DEFAULT TRUE,
    is_deleted  boolean NOT NULL DEFAULT FALSE,
    created_by  integer,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  integer,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT chk_transport_routes_scope CHECK ((tenant_id > 1) AND (school_id > 0))
);

CREATE TABLE IF NOT EXISTS core.transport_stops
(
    stop_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    route_id      integer NOT NULL REFERENCES core.transport_routes(route_id) ON DELETE CASCADE,
    tenant_id     integer NOT NULL,
    school_id     integer NOT NULL,
    stop_name     varchar(80) NOT NULL,
    monthly_fare  numeric(12,2) NOT NULL DEFAULT 0,
    display_order integer NOT NULL DEFAULT 0,
    is_active     boolean NOT NULL DEFAULT TRUE,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_transport_stops_route ON core.transport_stops(route_id);

CREATE TABLE IF NOT EXISTS core.transport_vehicles
(
    vehicle_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id    integer NOT NULL,
    school_id    integer NOT NULL,
    vehicle_no   varchar(40) NOT NULL,
    capacity     integer,
    driver_name  varchar(100),
    driver_phone varchar(20),
    route_id     integer REFERENCES core.transport_routes(route_id) ON DELETE SET NULL,
    is_active    boolean NOT NULL DEFAULT TRUE,
    is_deleted   boolean NOT NULL DEFAULT FALSE,
    created_by   integer,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   integer,
    updated_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT chk_transport_vehicles_scope CHECK ((tenant_id > 1) AND (school_id > 0))
);

-- Driver is an EMPLOYEE (core.staff, designation "Driver"), not free text. The
-- name/phone columns above are kept as a snapshot of the linked staff at save
-- time (like other snapshots in this schema); driver_staff_id is the real link.
ALTER TABLE core.transport_vehicles
    ADD COLUMN IF NOT EXISTS driver_staff_id integer REFERENCES core.staff(staff_id) ON DELETE SET NULL;

-- One active assignment per student. stop_id/route_id are stored by value (no hard
-- FK) and the fare is snapshotted, so editing/removing a stop never corrupts a
-- student's billed history.
CREATE TABLE IF NOT EXISTS core.student_transport
(
    assignment_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     integer NOT NULL,
    school_id     integer NOT NULL,
    student_id    integer NOT NULL,
    route_id      integer NOT NULL,
    stop_id       integer NOT NULL,
    monthly_fare  numeric(12,2) NOT NULL DEFAULT 0,
    academic_year varchar(12),
    start_date    date NOT NULL DEFAULT CURRENT_DATE,
    is_active     boolean NOT NULL DEFAULT TRUE,
    is_deleted    boolean NOT NULL DEFAULT FALSE,
    created_by    integer,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    integer,
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT chk_student_transport_scope CHECK ((tenant_id > 1) AND (school_id > 0))
);
CREATE INDEX IF NOT EXISTS idx_student_transport_student ON core.student_transport(student_id);

-- ── Riders and seats per route ──────────────────────────────────────────────
-- Riders = students on the roll with an active assignment on the route.
-- Seats  = total capacity of the route's active vehicles. NULL when no active
-- vehicle on the route has a capacity set: the route then has no known limit
-- and assignment is not capped (a school that never registers buses still works).
CREATE OR REPLACE FUNCTION core.fn_transport_route_riders(p_route_id integer, p_except_student integer DEFAULT NULL)
RETURNS integer LANGUAGE sql STABLE AS $fn$
    SELECT COUNT(DISTINCT a.student_id)::integer
    FROM core.student_transport a
    JOIN core.students st ON st.student_id = a.student_id AND st.is_active
    WHERE a.route_id = p_route_id
      AND a.is_active AND NOT COALESCE(a.is_deleted, FALSE)
      AND a.student_id IS DISTINCT FROM p_except_student;
$fn$;

CREATE OR REPLACE FUNCTION core.fn_transport_route_seats(p_route_id integer, p_except_vehicle integer DEFAULT NULL)
RETURNS integer LANGUAGE sql STABLE AS $fn$
    SELECT NULLIF(SUM(COALESCE(v.capacity, 0)), 0)::integer
    FROM core.transport_vehicles v
    WHERE v.route_id = p_route_id
      AND v.is_active AND NOT COALESCE(v.is_deleted, FALSE)
      AND v.vehicle_id IS DISTINCT FROM p_except_vehicle;
$fn$;

-- ── Routes (+ stops) manage ─────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE core.sp_transport_route_manage(
    IN    p_operation      varchar,
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_route_id       integer  DEFAULT NULL,
    IN    p_route_name     varchar  DEFAULT NULL,
    IN    p_description    varchar  DEFAULT NULL,
    IN    p_stops          jsonb    DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_route_id integer;
    v_stop     jsonb;
    v_stop_id  integer;
    v_keep     integer[] := ARRAY[]::integer[];
    v_busy     text;
    v_riders   integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    IF p_operation = 'GetRoutes' THEN
        OPEN p_result FOR
        SELECT r.route_id, r.route_name, r.description, r.is_active,
               COUNT(s.stop_id) FILTER (WHERE s.is_active)            AS stop_count,
               MIN(s.monthly_fare) FILTER (WHERE s.is_active)         AS min_fare,
               MAX(s.monthly_fare) FILTER (WHERE s.is_active)         AS max_fare,
               core.fn_transport_route_riders(r.route_id)             AS riders,
               core.fn_transport_route_seats(r.route_id)              AS seats
        FROM core.transport_routes r
        LEFT JOIN core.transport_stops s ON s.route_id = r.route_id
        WHERE r.tenant_id = p_tenant_id AND r.school_id = p_school_id
          AND COALESCE(r.is_deleted, FALSE) = FALSE
        GROUP BY r.route_id, r.route_name, r.description, r.is_active
        ORDER BY r.route_name;

    ELSIF p_operation = 'GetStops' THEN
        OPEN p_result FOR
        SELECT stop_id, route_id, stop_name, monthly_fare, display_order
        FROM core.transport_stops
        WHERE route_id = p_route_id AND tenant_id = p_tenant_id AND school_id = p_school_id
          AND is_active = TRUE
        ORDER BY display_order, stop_id;

    ELSIF p_operation = 'SaveRoute' THEN
        IF COALESCE(NULLIF(trim(p_route_name), ''), '') = '' THEN
            RAISE EXCEPTION 'Route name is required.';
        END IF;

        -- One route per name (case and spaces ignored), or the Assign dropdown
        -- offers two "North Zone"s and nobody knows which one a child is on.
        IF EXISTS (SELECT 1 FROM core.transport_routes
                    WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                      AND NOT COALESCE(is_deleted, FALSE)
                      AND lower(regexp_replace(trim(route_name), '\s+', ' ', 'g'))
                          = lower(regexp_replace(trim(p_route_name), '\s+', ' ', 'g'))
                      AND route_id IS DISTINCT FROM NULLIF(p_route_id, 0)) THEN
            RAISE EXCEPTION 'A route called "%" already exists.', trim(p_route_name);
        END IF;

        -- A fare is money the parent pays; it cannot be negative.
        IF p_stops IS NOT NULL AND jsonb_typeof(p_stops) = 'array' AND EXISTS (
               SELECT 1 FROM jsonb_array_elements(p_stops) e
                WHERE COALESCE(NULLIF(trim(e->>'stopName'), ''), '') <> ''
                  AND COALESCE((e->>'monthlyFare')::numeric, 0) < 0) THEN
            RAISE EXCEPTION 'A stop fare cannot be negative.';
        END IF;

        IF COALESCE(p_route_id, 0) > 0 THEN
            UPDATE core.transport_routes
            SET route_name = trim(p_route_name), description = NULLIF(trim(p_description), ''),
                updated_by = p_action_user_id, updated_at = NOW()
            WHERE route_id = p_route_id AND tenant_id = p_tenant_id AND school_id = p_school_id
              AND NOT COALESCE(is_deleted, FALSE)
            RETURNING route_id INTO v_route_id;
            -- Another school's id, or a deleted route: say so, do not pretend.
            IF v_route_id IS NULL THEN
                RAISE EXCEPTION 'Route not found.';
            END IF;
        ELSE
            INSERT INTO core.transport_routes (tenant_id, school_id, route_name, description, created_by)
            VALUES (p_tenant_id, p_school_id, trim(p_route_name), NULLIF(trim(p_description), ''), p_action_user_id)
            RETURNING route_id INTO v_route_id;
        END IF;

        -- Sync stops: upsert provided ones, switch off any existing not in the list.
        -- A fare change applies to NEW assignments only: a child already on the
        -- stop keeps the fare snapshotted when they were assigned.
        IF p_stops IS NOT NULL AND jsonb_typeof(p_stops) = 'array' THEN
            FOR v_stop IN SELECT * FROM jsonb_array_elements(p_stops)
            LOOP
                IF COALESCE(NULLIF(trim(v_stop->>'stopName'), ''), '') = '' THEN
                    CONTINUE;
                END IF;
                v_stop_id := NULLIF((v_stop->>'stopId'), '')::integer;
                IF COALESCE(v_stop_id, 0) > 0 THEN
                    UPDATE core.transport_stops
                    SET stop_name = trim(v_stop->>'stopName'),
                        monthly_fare = COALESCE((v_stop->>'monthlyFare')::numeric, 0),
                        display_order = COALESCE((v_stop->>'displayOrder')::integer, 0),
                        is_active = TRUE, updated_at = NOW()
                    WHERE stop_id = v_stop_id AND route_id = v_route_id;
                    IF NOT FOUND THEN
                        v_stop_id := NULL;   -- not a stop of this route: ignore it
                    END IF;
                ELSE
                    INSERT INTO core.transport_stops
                        (route_id, tenant_id, school_id, stop_name, monthly_fare, display_order)
                    VALUES
                        (v_route_id, p_tenant_id, p_school_id, trim(v_stop->>'stopName'),
                         COALESCE((v_stop->>'monthlyFare')::numeric, 0),
                         COALESCE((v_stop->>'displayOrder')::integer, 0))
                    RETURNING stop_id INTO v_stop_id;
                END IF;
                IF v_stop_id IS NOT NULL THEN
                    v_keep := array_append(v_keep, v_stop_id);
                END IF;
            END LOOP;
        END IF;

        -- A stop that children board at cannot be taken off the route: they
        -- would stay assigned (and billed) at a stop that no longer exists.
        SELECT string_agg(DISTINCT s.stop_name, ', ') INTO v_busy
        FROM core.transport_stops s
        JOIN core.student_transport a ON a.stop_id = s.stop_id
             AND a.is_active AND NOT COALESCE(a.is_deleted, FALSE)
        JOIN core.students st ON st.student_id = a.student_id AND st.is_active
        WHERE s.route_id = v_route_id AND s.is_active
          AND NOT (s.stop_id = ANY(v_keep));
        IF v_busy IS NOT NULL THEN
            RAISE EXCEPTION 'Stop(s) % still have students assigned. Move them to another stop first.', v_busy;
        END IF;

        -- Removed stops are switched off, never deleted: past assignments and
        -- their history still point at them.
        UPDATE core.transport_stops
        SET is_active = FALSE, updated_at = NOW()
        WHERE route_id = v_route_id AND is_active AND NOT (stop_id = ANY(v_keep));

        OPEN p_result FOR SELECT TRUE AS success, 'Route saved.' AS message, v_route_id AS route_id;

    ELSIF p_operation = 'DeleteRoute' THEN
        PERFORM 1 FROM core.transport_routes
         WHERE route_id = p_route_id AND tenant_id = p_tenant_id AND school_id = p_school_id
           AND NOT COALESCE(is_deleted, FALSE);
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Route not found.';
        END IF;

        -- Children still riding it: refuse. A deleted route would keep billing
        -- them on a route nobody can see.
        v_riders := core.fn_transport_route_riders(p_route_id);
        IF v_riders > 0 THEN
            RAISE EXCEPTION '% student(s) are still assigned to this route. Move or remove them first.', v_riders;
        END IF;

        -- Soft delete: the row stays so past assignments keep their route name.
        UPDATE core.transport_routes
        SET is_deleted = TRUE, is_active = FALSE, updated_by = p_action_user_id, updated_at = NOW()
        WHERE route_id = p_route_id AND tenant_id = p_tenant_id AND school_id = p_school_id;

        -- A bus left pointing at a deleted route would still show it on Vehicles.
        UPDATE core.transport_vehicles
        SET route_id = NULL, updated_by = p_action_user_id, updated_at = NOW()
        WHERE route_id = p_route_id AND tenant_id = p_tenant_id AND school_id = p_school_id;

        OPEN p_result FOR SELECT TRUE AS success, 'Route deleted.' AS message;

    ELSIF p_operation = 'ToggleRouteStatus' THEN
        -- Switching a route off only stops NEW assignments; children already on
        -- it stay until they are moved.
        UPDATE core.transport_routes
        SET is_active = NOT is_active, updated_by = p_action_user_id, updated_at = NOW()
        WHERE route_id = p_route_id AND tenant_id = p_tenant_id AND school_id = p_school_id
          AND NOT COALESCE(is_deleted, FALSE);
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Route not found.';
        END IF;
        OPEN p_result FOR SELECT TRUE AS success, 'Route status updated.' AS message;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;

-- ── Vehicles manage ─────────────────────────────────────────────────────────
-- Old signature (free-text driver only) is dropped so the driver_staff_id param
-- can be added without creating an ambiguous overload.
DROP PROCEDURE IF EXISTS core.sp_transport_vehicle_manage(
    varchar, integer, integer, integer, integer, varchar, integer,
    varchar, varchar, integer, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_transport_vehicle_manage(
    IN    p_operation       varchar,
    IN    p_tenant_id       integer,
    IN    p_school_id       integer,
    IN    p_action_user_id  integer,
    IN    p_vehicle_id      integer  DEFAULT NULL,
    IN    p_vehicle_no      varchar  DEFAULT NULL,
    IN    p_capacity        integer  DEFAULT NULL,
    IN    p_driver_name     varchar  DEFAULT NULL,
    IN    p_driver_phone    varchar  DEFAULT NULL,
    IN    p_route_id        integer  DEFAULT NULL,
    IN    p_driver_staff_id integer  DEFAULT NULL,
    INOUT p_result          refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_dname  varchar(100);
    v_dphone varchar(20);
    v_route  integer;
    v_active boolean;
    v_riders integer;
    v_old_route  integer;   -- route the vehicle was on before this save
    v_old_seats  integer;   -- seats of that route before the save
    v_new_seats  integer;   -- seats of the chosen route before the save
    v_seats      integer;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    IF p_operation = 'GetVehicles' THEN
        OPEN p_result FOR
        SELECT v.vehicle_id, v.vehicle_no, v.capacity, v.driver_name, v.driver_phone,
               v.route_id, r.route_name, v.is_active, v.driver_staff_id
        FROM core.transport_vehicles v
        -- Only this school's live routes: a route id from anywhere else must
        -- never surface another school's route name here.
        LEFT JOIN core.transport_routes r ON r.route_id = v.route_id
             AND r.tenant_id = v.tenant_id AND r.school_id = v.school_id
             AND NOT COALESCE(r.is_deleted, FALSE)
        WHERE v.tenant_id = p_tenant_id AND v.school_id = p_school_id
          AND COALESCE(v.is_deleted, FALSE) = FALSE
        ORDER BY v.vehicle_no;

    ELSIF p_operation = 'GetDrivers' THEN
        -- Transport-type staff (drivers/conductors) for the vehicle dropdown.
        OPEN p_result FOR
        SELECT staff_id, full_name, mobile, designation
        FROM   core.staff
        WHERE  tenant_id = p_tenant_id AND school_id = p_school_id
          AND  COALESCE(is_deleted, FALSE) = FALSE
          AND  COALESCE(status, 'Active') <> 'Inactive'
          AND  (staff_type = 'Transport' OR designation ILIKE '%driver%' OR designation ILIKE '%conductor%')
        ORDER BY full_name;

    ELSIF p_operation = 'SaveVehicle' THEN
        IF COALESCE(NULLIF(trim(p_vehicle_no), ''), '') = '' THEN
            RAISE EXCEPTION 'Vehicle number is required.';
        END IF;

        -- A registration number is one vehicle. Compared without case, spaces
        -- or dashes so "RJ14-AB-1234" and "rj14 ab 1234" are the same bus.
        IF EXISTS (SELECT 1 FROM core.transport_vehicles
                    WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                      AND NOT COALESCE(is_deleted, FALSE)
                      AND upper(regexp_replace(vehicle_no, '[\s-]', '', 'g'))
                          = upper(regexp_replace(p_vehicle_no, '[\s-]', '', 'g'))
                      AND vehicle_id IS DISTINCT FROM NULLIF(p_vehicle_id, 0)) THEN
            RAISE EXCEPTION 'Vehicle % is already registered.', trim(p_vehicle_no);
        END IF;

        IF p_capacity IS NOT NULL AND p_capacity < 1 THEN
            RAISE EXCEPTION 'Capacity must be at least 1 seat (or left blank).';
        END IF;

        -- The route must be one of this school's live routes.
        IF COALESCE(p_route_id, 0) > 0 AND NOT EXISTS (
               SELECT 1 FROM core.transport_routes
                WHERE route_id = p_route_id AND tenant_id = p_tenant_id AND school_id = p_school_id
                  AND NOT COALESCE(is_deleted, FALSE)) THEN
            RAISE EXCEPTION 'Route not found.';
        END IF;

        IF COALESCE(p_driver_staff_id, 0) > 0 AND NOT EXISTS (
               SELECT 1 FROM core.staff
                WHERE staff_id = p_driver_staff_id AND tenant_id = p_tenant_id AND school_id = p_school_id
                  AND COALESCE(is_deleted, FALSE) = FALSE) THEN
            RAISE EXCEPTION 'Driver not found.';
        END IF;
        -- A driver who has left cannot be put on a bus (sp_staff_release_duties
        -- takes them off their bus when they leave).
        IF COALESCE(p_driver_staff_id, 0) > 0 AND EXISTS (
               SELECT 1 FROM core.staff
                WHERE staff_id = p_driver_staff_id AND COALESCE(status, 'Active') = 'Inactive') THEN
            RAISE EXCEPTION 'This driver is marked as left. Pick an active driver.';
        END IF;

        -- Seats before the save, to check below that children are not left
        -- without a seat when capacity is lowered or the bus moves route.
        SELECT route_id INTO v_old_route FROM core.transport_vehicles
         WHERE vehicle_id = NULLIF(COALESCE(p_vehicle_id, 0), 0)
           AND tenant_id = p_tenant_id AND school_id = p_school_id;
        v_old_seats := core.fn_transport_route_seats(v_old_route);
        v_new_seats := core.fn_transport_route_seats(NULLIF(COALESCE(p_route_id, 0), 0));

        -- Snapshot driver name/phone from the linked staff row (single source);
        -- fall back to any free-text passed in when no staff is linked.
        IF COALESCE(p_driver_staff_id, 0) > 0 THEN
            SELECT full_name, mobile INTO v_dname, v_dphone
            FROM   core.staff
            WHERE  staff_id = p_driver_staff_id
              AND  tenant_id = p_tenant_id AND school_id = p_school_id
              AND  COALESCE(is_deleted, FALSE) = FALSE;
        END IF;
        v_dname  := COALESCE(v_dname,  p_driver_name);
        v_dphone := COALESCE(v_dphone, p_driver_phone);

        IF COALESCE(p_vehicle_id, 0) > 0 THEN
            UPDATE core.transport_vehicles
            SET vehicle_no = trim(p_vehicle_no), capacity = p_capacity,
                driver_name = v_dname, driver_phone = v_dphone,
                driver_staff_id = NULLIF(COALESCE(p_driver_staff_id, 0), 0),
                route_id = NULLIF(COALESCE(p_route_id, 0), 0),
                updated_by = p_action_user_id, updated_at = NOW()
            WHERE vehicle_id = p_vehicle_id AND tenant_id = p_tenant_id AND school_id = p_school_id
              AND NOT COALESCE(is_deleted, FALSE);
            IF NOT FOUND THEN
                RAISE EXCEPTION 'Vehicle not found.';
            END IF;
        ELSE
            INSERT INTO core.transport_vehicles
                (tenant_id, school_id, vehicle_no, capacity, driver_name, driver_phone,
                 driver_staff_id, route_id, created_by)
            VALUES
                (p_tenant_id, p_school_id, trim(p_vehicle_no), p_capacity, v_dname, v_dphone,
                 NULLIF(COALESCE(p_driver_staff_id, 0), 0), NULLIF(COALESCE(p_route_id, 0), 0), p_action_user_id);
        END IF;

        -- Fewer seats than children riding: refused (the save is rolled back).
        -- Only when this save took seats away, so an old full route can still be edited.
        IF v_old_route IS NOT NULL THEN
            v_seats  := core.fn_transport_route_seats(v_old_route);
            v_riders := core.fn_transport_route_riders(v_old_route);
            IF v_seats IS NOT NULL AND v_seats < COALESCE(v_old_seats, 2147483647) AND v_riders > v_seats THEN
                RAISE EXCEPTION 'The route would have % seat(s) for % student(s). Move some students or add a vehicle first.', v_seats, v_riders;
            END IF;
        END IF;
        IF COALESCE(p_route_id, 0) > 0 AND p_route_id IS DISTINCT FROM v_old_route THEN
            v_seats  := core.fn_transport_route_seats(p_route_id);
            v_riders := core.fn_transport_route_riders(p_route_id);
            IF v_seats IS NOT NULL AND v_seats < COALESCE(v_new_seats, 2147483647) AND v_riders > v_seats THEN
                RAISE EXCEPTION 'The route would have % seat(s) for % student(s). Move some students or add a vehicle first.', v_seats, v_riders;
            END IF;
        END IF;
        OPEN p_result FOR SELECT TRUE AS success, 'Vehicle saved.' AS message;

    ELSIF p_operation IN ('DeleteVehicle', 'ToggleVehicleStatus') THEN
        SELECT route_id, is_active INTO v_route, v_active
        FROM core.transport_vehicles
        WHERE vehicle_id = p_vehicle_id AND tenant_id = p_tenant_id AND school_id = p_school_id
          AND NOT COALESCE(is_deleted, FALSE);
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Vehicle not found.';
        END IF;

        -- Taking a bus off the road (switching it off, or deleting it) is
        -- refused when it is the last active bus of a route children ride:
        -- they would be assigned to a route with no bus. Switching ON is free.
        IF v_active AND v_route IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM core.transport_vehicles
                            WHERE route_id = v_route AND vehicle_id <> p_vehicle_id
                              AND is_active AND NOT COALESCE(is_deleted, FALSE)) THEN
            v_riders := core.fn_transport_route_riders(v_route);
            IF v_riders > 0 THEN
                RAISE EXCEPTION 'This is the only active vehicle on its route and % student(s) ride it. Add or move another vehicle to the route first.', v_riders;
            END IF;
        END IF;

        IF p_operation = 'DeleteVehicle' THEN
            UPDATE core.transport_vehicles
            SET is_deleted = TRUE, is_active = FALSE, updated_by = p_action_user_id, updated_at = NOW()
            WHERE vehicle_id = p_vehicle_id;
            OPEN p_result FOR SELECT TRUE AS success, 'Vehicle deleted.' AS message;
        ELSE
            UPDATE core.transport_vehicles
            SET is_active = NOT is_active, updated_by = p_action_user_id, updated_at = NOW()
            WHERE vehicle_id = p_vehicle_id;
            OPEN p_result FOR SELECT TRUE AS success, 'Vehicle status updated.' AS message;
        END IF;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;

-- ── Routes + stops for cascading dropdowns ──────────────────────────────────
CREATE OR REPLACE PROCEDURE core.sp_transport_routes_dropdown(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    INOUT p_result         refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    OPEN p_result FOR
    SELECT r.route_id, r.route_name, s.stop_id, s.stop_name, s.monthly_fare,
           core.fn_transport_route_riders(r.route_id) AS riders,
           core.fn_transport_route_seats(r.route_id)  AS seats
    FROM core.transport_routes r
    JOIN core.transport_stops s ON s.route_id = r.route_id AND s.is_active = TRUE
    WHERE r.tenant_id = p_tenant_id AND r.school_id = p_school_id
      AND r.is_active = TRUE AND COALESCE(r.is_deleted, FALSE) = FALSE
    ORDER BY r.route_name, s.display_order, s.stop_id;
END;
$procedure$;

-- ── Student assignment (snapshots fare + generates monthly transport dues) ──
-- Depends on student_money_lifecycle.sql (fn_ledger_close and the close columns).
CREATE OR REPLACE PROCEDURE core.sp_transport_assign_manage(
    IN    p_operation      varchar,
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_student_id     integer,
    IN    p_route_id       integer  DEFAULT NULL,
    IN    p_stop_id        integer  DEFAULT NULL,
    IN    p_academic_year  varchar  DEFAULT NULL,
    IN    p_start_date     date     DEFAULT NULL,
    IN    p_months         integer  DEFAULT 12,
    INOUT p_result         refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_fare        numeric(12,2);
    v_stop_name   varchar(80);
    v_route_name  varchar(80);
    v_start       date;
    v_month_start date;
    v_i           integer;
    v_made        integer := 0;
    v_student_year varchar;
    v_year        varchar;
    v_sess_end    date;
    v_months      integer;
    v_max         integer;
    v_due         date;
    v_already     numeric(12,2);
    v_closed      numeric(12,2);
    v_reason      varchar(200);
    v_open        boolean;
    v_same_route  boolean;
    v_same_stop   boolean;
    v_seats       integer;
    v_riders      integer;
    r             record;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR p_student_id <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;

    IF p_operation = 'GetForStudent' THEN
        OPEN p_result FOR
        SELECT a.assignment_id, a.route_id, a.stop_id, a.monthly_fare, a.start_date,
               rt.route_name, s.stop_name
        FROM core.student_transport a
        -- "rt", not "r": r is a record variable of this proc, and PL/pgSQL read
        -- r.route_name as that (unassigned) variable -- every call failed.
        LEFT JOIN core.transport_routes rt ON rt.route_id = a.route_id
        LEFT JOIN core.transport_stops  s ON s.stop_id  = a.stop_id
        WHERE a.student_id = p_student_id AND a.tenant_id = p_tenant_id AND a.school_id = p_school_id
          AND a.is_active = TRUE AND COALESCE(a.is_deleted, FALSE) = FALSE
        ORDER BY a.assignment_id DESC
        LIMIT 1;

    ELSIF p_operation = 'SaveAssignment' THEN
        -- The student must be ours and still on the roll. Without this a stop
        -- of this school could be billed to ANY student id, including another
        -- school's, with the ledger rows written under this school's tenant.
        SELECT academic_year INTO v_student_year
        FROM core.students
        WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
          AND is_active = TRUE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Student not found, or no longer on the roll.';
        END IF;

        SELECT s.monthly_fare, s.stop_name, rt.route_name,
               (s.is_active AND rt.is_active AND NOT COALESCE(rt.is_deleted, FALSE))
          INTO v_fare, v_stop_name, v_route_name, v_open
        FROM core.transport_stops s
        JOIN core.transport_routes rt ON rt.route_id = s.route_id
        WHERE s.stop_id = p_stop_id AND s.route_id = p_route_id
          AND s.tenant_id = p_tenant_id AND s.school_id = p_school_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Selected stop not found.';
        END IF;

        -- Is the child already on this route / stop? Promotion re-bills a kept
        -- route for the new session through this same call, and that must keep
        -- working even if the route has since been closed or filled up.
        v_same_route := EXISTS (SELECT 1 FROM core.student_transport
                                 WHERE student_id = p_student_id AND route_id = p_route_id
                                   AND is_active AND NOT COALESCE(is_deleted, FALSE));
        v_same_stop  := EXISTS (SELECT 1 FROM core.student_transport
                                 WHERE student_id = p_student_id AND stop_id = p_stop_id
                                   AND is_active AND NOT COALESCE(is_deleted, FALSE));

        -- A switched-off route, a deleted route or a removed stop takes no new
        -- riders.
        IF NOT v_open AND NOT v_same_stop THEN
            RAISE EXCEPTION 'Route % / stop % is not in service. Pick an active route and stop.',
                v_route_name, v_stop_name;
        END IF;

        -- Seats: the route's active buses decide how many children it takes.
        -- Unlimited when no active bus on the route has a capacity set.
        IF NOT v_same_route THEN
            v_seats  := core.fn_transport_route_seats(p_route_id);
            v_riders := core.fn_transport_route_riders(p_route_id, p_student_id);
            IF v_seats IS NOT NULL AND v_riders >= v_seats THEN
                RAISE EXCEPTION 'Route % is full: % of % seats taken. Add a vehicle or pick another route.',
                    v_route_name, v_riders, v_seats;
            END IF;
        END IF;

        v_start := COALESCE(p_start_date, CURRENT_DATE);
        v_year  := COALESCE(NULLIF(TRIM(p_academic_year), ''), v_student_year);

        -- A start before the child joined would bill months they were not here.
        IF v_start < (SELECT NULLIF(admission_date, '')::date FROM core.students WHERE student_id = p_student_id) THEN
            RAISE EXCEPTION 'The bus start date is before the student''s admission date.';
        END IF;

        -- Bill to the end of the SESSION the assignment is for, read from its
        -- real end date. The controllers used to send a month count worked out
        -- from the session NAME on an April-March assumption, and this proc
        -- trusted it, so a 12-month count from October ran into the next session.
        SELECT NULLIF(end_date, '')::date, GREATEST(v_start, NULLIF(start_date, '')::date)
          INTO v_sess_end, v_start
        FROM academic.academic_years
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND academic_year_name = v_year AND COALESCE(is_deleted, FALSE) = FALSE
        LIMIT 1;
        -- (a start before the session begins is moved to the session's first day:
        --  an advance admission in February does not bill March of the old session)
        v_start := COALESCE(v_start, COALESCE(p_start_date, CURRENT_DATE));

        v_months := GREATEST(COALESCE(NULLIF(p_months, 0), 12), 1);
        IF v_sess_end IS NOT NULL THEN
            v_max := ((EXTRACT(YEAR FROM v_sess_end) * 12 + EXTRACT(MONTH FROM v_sess_end))
                    - (EXTRACT(YEAR FROM v_start)    * 12 + EXTRACT(MONTH FROM v_start)))::integer + 1;
            IF v_max <= 0 THEN
                RAISE EXCEPTION 'The start date is after session % ends.', v_year;
            END IF;
            v_months := LEAST(v_months, v_max);
        END IF;

        -- Replace the current assignment. Its unpaid dues from the start month
        -- on are CLOSED, not deleted: the row stays (a cancelled receipt may
        -- still point at it) with the reason, who and when, and only the part
        -- nobody paid is taken off. See student_money_lifecycle.sql.
        v_reason := 'Route changed on ' || to_char(v_start, 'YYYY-MM-DD');
        FOR r IN
            SELECT ledger_id FROM core.student_ledger
            WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
              AND fee_head_name = 'Transport Fee'
              AND due_date::date >= DATE_TRUNC('month', v_start)::date
              AND amount_due - amount_paid - concession > 0
        LOOP
            PERFORM core.fn_ledger_close(r.ledger_id, v_reason, 'Transport', p_action_user_id);
        END LOOP;

        UPDATE core.student_transport
        SET is_active = FALSE, is_deleted = TRUE,
            end_reason = 'Replaced by ' || COALESCE(v_route_name, '') || ' / ' || COALESCE(v_stop_name, '') ||
                         ' on ' || to_char(v_start, 'YYYY-MM-DD'),
            ended_by = p_action_user_id, ended_at = NOW(),
            updated_by = p_action_user_id, updated_at = NOW()
        WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
          AND is_active = TRUE;

        INSERT INTO core.student_transport
            (tenant_id, school_id, student_id, route_id, stop_id, monthly_fare,
             academic_year, start_date, created_by)
        VALUES
            (p_tenant_id, p_school_id, p_student_id, p_route_id, p_stop_id, v_fare,
             v_year, v_start, p_action_user_id);

        -- One 'Transport Fee' due per month. A month that already holds settled
        -- money (paid, or paid then closed) is only topped up to the new fare,
        -- so a part-paid month is never charged twice.
        v_month_start := DATE_TRUNC('month', v_start)::date;
        FOR v_i IN 0 .. v_months - 1 LOOP
            v_due := (v_month_start + make_interval(months => v_i))::date;

            SELECT COALESCE(SUM(amount_due), 0) INTO v_already
            FROM core.student_ledger
            WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
              AND fee_head_name = 'Transport Fee'
              AND due_date::date = v_due;

            IF v_already < v_fare THEN
                INSERT INTO core.student_ledger
                    (tenant_id, school_id, student_id, fee_head_name, frequency,
                     installment_label, due_date, amount_due, status, academic_year)
                VALUES
                    (p_tenant_id, p_school_id, p_student_id, 'Transport Fee', 'Monthly',
                     TO_CHAR(v_due, 'Mon YYYY'), v_due, v_fare - v_already, 'Pending', v_year);
                v_made := v_made + 1;
            END IF;
        END LOOP;

        OPEN p_result FOR
        SELECT TRUE AS success,
               'Transport assigned. ' || v_made || ' monthly due(s) generated.' AS message,
               v_fare AS monthly_fare, v_made AS months_generated;

    ELSIF p_operation = 'RemoveAssignment' THEN
        -- Unpaid bus dues from this month on are CLOSED with a reason (never
        -- deleted), including the unpaid part of a month that was paid in
        -- part. Money already taken stays on the row and can be refunded.
        v_reason := 'Transport removed on ' || to_char(CURRENT_DATE, 'YYYY-MM-DD');
        v_closed := 0;
        FOR r IN
            SELECT ledger_id FROM core.student_ledger
            WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
              AND fee_head_name = 'Transport Fee'
              AND due_date::date >= DATE_TRUNC('month', CURRENT_DATE)::date
              AND amount_due - amount_paid - concession > 0
        LOOP
            v_closed := v_closed + core.fn_ledger_close(r.ledger_id, v_reason, 'Transport', p_action_user_id);
        END LOOP;

        UPDATE core.student_transport
        SET is_active = FALSE, is_deleted = TRUE,
            end_reason = v_reason, ended_by = p_action_user_id, ended_at = NOW(),
            updated_by = p_action_user_id, updated_at = NOW()
        WHERE student_id = p_student_id AND tenant_id = p_tenant_id AND school_id = p_school_id
          AND is_active = TRUE;

        OPEN p_result FOR SELECT TRUE AS success,
               'Transport removed.' ||
               CASE WHEN v_closed > 0
                    THEN ' ' || to_char(v_closed, 'FM99999990.00') || ' of unpaid bus fees closed.'
                    ELSE '' END AS message;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;

-- ============================================================================
-- sp_staff_manage.sql  —  CRUD for core.staff (HR/Staff module)
--
-- Operations (p_operation):
--   LIST       - all non-deleted staff for the school (UI filters client-side)
--   GET        - one staff row by p_staff_id
--   INSERT     - create a staff row; optionally also create a login user + role
--   UPDATE     - update a staff row; optionally create a login if not present
--   DELETE     - soft deactivate (status='Inactive', is_active=FALSE)
--   REACTIVATE - status='Active', is_active=TRUE
--
-- "Give login": when p_create_login = TRUE and email + password hash are
-- supplied, a core.users login is created (must_change_password=TRUE), a
-- profile + role (p_role_id) assigned, and core.staff.user_id linked. A bus
-- driver / peon left without a login is simply a staff row with user_id NULL.
--
-- Oct 2026 (platform_access_security_tests.sql) -- needs access_security_hardening.sql:
--   * DELETE also switches off the linked login; REACTIVATE switches it back on.
--     Nobody can deactivate their own login, and the last active school admin of a
--     school cannot be deactivated.
--   * Role ids must be roles of THIS tenant (there is no FK; a foreign id used to
--     become the primary role and lock the person out).
--   * Nobody can change their own roles. Only a school admin (or the platform)
--     can grant or remove SCHOOL_ADMIN, and the last school admin keeps it.
--   * Phone uniqueness uses core.fn_user_phone_taken (last 10 digits, like the index).
--   * Activation, role changes and admin password resets write admin_activity_logs.
--
-- Oct 2026 (hr_leave_payroll_tests.sql, docs/test-cases/hr_leave_payroll.md):
--   * core.staff.last_working_date: the day a leaver last worked. Payroll pays
--     the final month up to that day, so a leaver is no longer dropped from the
--     month they worked in. DELETE records it (p_last_working_date, default today).
--   * Choosing "Inactive" on the Edit form is the same as Deactivate: is_active
--     goes FALSE, status_changed_at and the last working day are stamped and the
--     login is switched off (same guards). Inactive -> Active/On Leave on the
--     form is the same as Reactivate. Before this only the status word changed,
--     so the person stayed in the teacher pools and kept signing in.
--   * UPDATE / DELETE / REACTIVATE check the staff row is in THIS school first.
--     An out-of-scope UPDATE with "create login" ticked used to create the login
--     before finding nothing to update, leaving an orphan account.
--   * Refused: employee code differing only by case, negative salary, a status
--     other than Active / On Leave / Inactive, a staff type outside the four
--     buckets, a new staff member created Inactive, a last working day in the
--     future or before the joining date, deactivating someone already inactive.
--   * p_last_working_date is the LAST parameter (after p_result) so existing
--     positional callers keep working.
--
-- NOTE: parameters are POSITIONAL (Npgsql CommandType.StoredProcedure). The C#
-- StaffService MUST build NpgsqlParameter[] in exactly this order.
-- ============================================================================

-- When a leaver last worked. Text 'YYYY-MM-DD' like every other date column on
-- core.staff (see dates_as_text.sql). NULL for anyone still working, and for
-- staff deactivated before this column existed (no honest value to fill in).
ALTER TABLE core.staff ADD COLUMN IF NOT EXISTS last_working_date varchar(10);

-- "zzhr-001" and "ZZHR-001" are the same badge. The proc checks this too; the
-- index makes it hold under concurrent saves.
CREATE UNIQUE INDEX IF NOT EXISTS uq_staff_employee_code_ci
    ON core.staff (tenant_id, school_id, UPPER(TRIM(employee_code)))
    WHERE employee_code IS NOT NULL AND is_deleted = FALSE;


-- ----------------------------------------------------------------------------
-- Switch a staff member's login off or on, with the guards that go with it.
-- One place for DELETE, REACTIVATE and an Edit-form status change.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE core.sp_staff_login_switch(
    p_tenant_id      integer,
    p_school_id      integer,
    p_action_user_id integer,
    p_staff_id       integer,
    p_user_id        integer,
    p_on             boolean)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_user_id IS NULL THEN
        RETURN;
    END IF;

    IF NOT p_on THEN
        IF p_user_id = p_action_user_id THEN
            RAISE EXCEPTION 'You cannot deactivate your own login.';
        END IF;
        IF core.fn_is_last_school_admin(p_school_id, p_user_id) THEN
            RAISE EXCEPTION 'This is the last active School Admin of the school. Make someone else a School Admin first.';
        END IF;

        -- Someone who has left must not keep signing in.
        UPDATE core.users
        SET    is_active = FALSE, updated_by = p_action_user_id, updated_at = now()
        WHERE  user_id = p_user_id AND tenant_id = p_tenant_id AND is_active = TRUE;

        IF FOUND THEN
            PERFORM core.fn_admin_audit(p_tenant_id, p_school_id, p_action_user_id, 'USER_DEACTIVATE',
                'Staff', 'core.users', p_user_id,
                format('Login deactivated with staff %s', p_staff_id));
        END IF;
        RETURN;
    END IF;

    -- Bring the login back, unless its email or phone now belongs to someone else.
    IF EXISTS (SELECT 1 FROM core.users WHERE user_id = p_user_id
               AND tenant_id = p_tenant_id AND is_active = FALSE AND is_deleted = FALSE) THEN
        IF core.fn_user_email_taken((SELECT email FROM core.users WHERE user_id = p_user_id), p_user_id) THEN
            RAISE EXCEPTION 'This person''s login email is now used by another user. Change it before re-activating.';
        END IF;
        IF EXISTS (SELECT 1 FROM core.user_profiles up WHERE up.user_id = p_user_id AND up.phone IS NOT NULL
                   AND core.fn_user_phone_taken(up.phone, p_user_id)) THEN
            RAISE EXCEPTION 'This person''s login phone is now used by another user. Change it before re-activating.';
        END IF;

        UPDATE core.users
        SET    is_active = TRUE, updated_by = p_action_user_id, updated_at = now()
        WHERE  user_id = p_user_id;

        PERFORM core.fn_admin_audit(p_tenant_id, p_school_id, p_action_user_id, 'USER_ACTIVATE',
            'Staff', 'core.users', p_user_id,
            format('Login re-activated with staff %s', p_staff_id));
    END IF;
END;
$procedure$;


-- ── a staff member leaves: their class charge and periods are freed ─────────
-- Left on them, the section showed a class teacher who had gone (only an admin
-- could take its attendance; the acting-teacher rule never fires for someone
-- inactive) and the timetable kept their periods, so no substitute was asked
-- for. In the current and later sessions the section gets no class teacher and
-- the periods no teacher, ready to be given to someone else.
CREATE OR REPLACE PROCEDURE core.sp_staff_release_duties(
    IN p_tenant_id      integer,
    IN p_school_id      integer,
    IN p_action_user_id integer,
    IN p_staff_id       integer)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    UPDATE academic.academic_class_sections sec
       SET class_teacher_staff_id = NULL, updated_by = p_action_user_id, updated_at = now()
      FROM academic.academic_years y
     WHERE sec.tenant_id = p_tenant_id AND sec.school_id = p_school_id
       AND sec.class_teacher_staff_id = p_staff_id
       AND y.academic_year_id = sec.academic_year_id
       AND NULLIF(y.end_date, '')::date >= CURRENT_DATE;

    UPDATE academic.timetable t
       SET staff_id = NULL, updated_by = p_action_user_id, updated_at = now()
      FROM academic.academic_years y
     WHERE t.tenant_id = p_tenant_id AND t.school_id = p_school_id
       AND t.staff_id = p_staff_id
       AND y.academic_year_id = t.academic_year_id
       AND NULLIF(y.end_date, '')::date >= CURRENT_DATE;

    -- A driver who leaves is taken off their bus; the name stays on the bus
    -- page until a new driver is picked.
    UPDATE core.transport_vehicles
       SET driver_staff_id = NULL, updated_by = p_action_user_id, updated_at = now()
     WHERE tenant_id = p_tenant_id AND school_id = p_school_id
       AND driver_staff_id = p_staff_id;
END;
$procedure$;


DROP PROCEDURE IF EXISTS core.sp_staff_manage(
    text, integer, integer, integer, integer,
    text, text, text, date, text, text, text, text, text,
    text, text, text, date, text, integer, text,
    numeric, text, text, text, text,
    boolean, text, integer[],
    text, text, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_staff_manage(
    p_operation        text,
    p_tenant_id        integer,
    p_school_id        integer,
    p_action_user_id   integer,
    p_staff_id         integer,
    -- personal
    p_employee_code    text,
    p_full_name        text,
    p_gender           text,
    p_dob              date,
    p_mobile           text,
    p_alt_mobile       text,
    p_email            text,
    p_blood_group      text,
    p_address          text,
    -- employment
    p_staff_type       text,
    p_department       text,
    p_designation      text,
    p_joining_date     date,
    p_qualification    text,
    p_experience_years integer,
    p_status           text,
    -- payroll / bank
    p_monthly_salary   numeric,
    p_bank_account_no  text,
    p_ifsc_code        text,
    p_pan              text,
    p_aadhaar          text,
    -- login linkage
    p_create_login     boolean,
    p_password_hash    text,
    p_role_ids         integer[],
    -- list filters
    p_search           text,
    p_status_filter    text,
    -- out
    INOUT p_result     refcursor DEFAULT 'staff_cursor',
    -- leaving (DELETE, or UPDATE to Inactive). Last so positional callers still work.
    p_last_working_date date DEFAULT NULL
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_staff_id    integer;
    v_user_id     integer;
    v_staff_type  text;
    v_old_roles   text;
    v_new_roles   text;
    v_admin_role  integer;
    v_had_admin   boolean;
    v_gets_admin  boolean;
    v_old_status  text;
    v_new_status  text;
    v_join        date;
    v_lwd         date;
    v_going_off   boolean := FALSE;
    v_coming_back boolean := FALSE;
BEGIN
    -- Multi-tenancy guard (tenant 1 = platform; real schools are tenant > 1).
    IF p_tenant_id IS NULL OR p_tenant_id <= 1 OR p_school_id IS NULL OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid tenant/school scope.';
    END IF;

    -- ---------------------------------------------------------------- LIST
    IF p_operation = 'LIST' THEN
        OPEN p_result FOR
        SELECT s.staff_id, s.public_id, s.employee_code, s.full_name, s.gender, s.dob,
               s.mobile, s.alt_mobile, s.email, s.blood_group, s.address,
               s.staff_type, s.department, s.designation, s.joining_date,
               s.qualification, s.experience_years, s.status,
               s.monthly_salary, s.bank_account_no, s.ifsc_code, s.pan, s.aadhaar,
               s.user_id, s.status_changed_at, s.last_working_date
        FROM   core.staff s
        WHERE  s.tenant_id = p_tenant_id
          AND  s.school_id = p_school_id
          AND  s.is_deleted = FALSE
          AND  (p_status_filter IS NULL OR p_status_filter = '' OR s.status = p_status_filter)
          AND  (p_search IS NULL OR p_search = ''
                OR s.full_name    ILIKE '%' || p_search || '%'
                OR s.employee_code ILIKE '%' || p_search || '%'
                OR s.designation  ILIKE '%' || p_search || '%')
        ORDER BY s.full_name;
        RETURN;
    END IF;

    -- ----------------------------------------------------------------- GET
    IF p_operation = 'GET' THEN
        OPEN p_result FOR
        SELECT s.staff_id, s.public_id, s.employee_code, s.full_name, s.gender, s.dob,
               s.mobile, s.alt_mobile, s.email, s.blood_group, s.address,
               s.staff_type, s.department, s.designation, s.joining_date,
               s.qualification, s.experience_years, s.status,
               s.monthly_salary, s.bank_account_no, s.ifsc_code, s.pan, s.aadhaar,
               s.user_id, s.status_changed_at, s.last_working_date
        FROM   core.staff s
        WHERE  s.tenant_id = p_tenant_id
          AND  s.school_id = p_school_id
          AND  s.staff_id  = p_staff_id
          AND  s.is_deleted = FALSE;
        RETURN;
    END IF;

    -- Every write below works on one staff row of THIS school. Find it first, so
    -- nothing (a login, a role) is created for a row that is not ours.
    IF p_operation IN ('UPDATE', 'DELETE', 'REACTIVATE') THEN
        SELECT user_id, status, NULLIF(joining_date, '')::date
          INTO v_user_id, v_old_status, v_join
        FROM core.staff
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND staff_id = p_staff_id AND is_deleted = FALSE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Staff member not found.';
        END IF;
    END IF;

    -- -------------------------------------------------------------- DELETE
    IF p_operation = 'DELETE' THEN
        IF v_old_status = 'Inactive' THEN
            RAISE EXCEPTION 'This staff member is already inactive.';
        END IF;

        v_lwd := COALESCE(p_last_working_date, CURRENT_DATE);
        IF v_lwd > CURRENT_DATE THEN
            RAISE EXCEPTION 'The last working day cannot be in the future. Deactivate on or after that day.';
        END IF;
        -- Someone hired for a future date who never joined: no working days at
        -- all, so no last working day (payroll then never pays them).
        IF p_last_working_date IS NULL AND v_join IS NOT NULL AND v_join > CURRENT_DATE THEN
            v_lwd := NULL;
        END IF;
        IF v_join IS NOT NULL AND v_lwd < v_join THEN
            RAISE EXCEPTION 'The last working day cannot be before the joining date (%).', to_char(v_join, 'DD Mon YYYY');
        END IF;

        UPDATE core.staff
        SET    status = 'Inactive', is_active = FALSE,
               status_changed_at = now(),
               last_working_date = to_char(v_lwd, 'YYYY-MM-DD'),
               updated_by = p_action_user_id, updated_at = now()
        WHERE  tenant_id = p_tenant_id AND school_id = p_school_id AND staff_id = p_staff_id;

        CALL core.sp_staff_login_switch(p_tenant_id, p_school_id, p_action_user_id, p_staff_id, v_user_id, FALSE);
        CALL core.sp_staff_release_duties(p_tenant_id, p_school_id, p_action_user_id, p_staff_id);

        OPEN p_result FOR SELECT p_staff_id AS staff_id;
        RETURN;
    END IF;

    -- ---------------------------------------------------------- REACTIVATE
    -- Meant for a mistaken deactivation. A re-hire after a real gap should also
    -- get a new joining date on the Edit form, or payroll would see the gap as
    -- employed time.
    IF p_operation = 'REACTIVATE' THEN
        UPDATE core.staff
        SET    status = 'Active', is_active = TRUE,
               status_changed_at = now(),
               last_working_date = NULL,
               updated_by = p_action_user_id, updated_at = now()
        WHERE  tenant_id = p_tenant_id AND school_id = p_school_id AND staff_id = p_staff_id;

        CALL core.sp_staff_login_switch(p_tenant_id, p_school_id, p_action_user_id, p_staff_id, v_user_id, TRUE);

        OPEN p_result FOR SELECT p_staff_id AS staff_id;
        RETURN;
    END IF;

    -- ============================ INSERT / UPDATE ========================
    IF p_operation IN ('INSERT', 'UPDATE') THEN

        IF p_full_name IS NULL OR TRIM(p_full_name) = '' THEN
            RAISE EXCEPTION 'Staff full name is required.';
        END IF;

        -- Payroll pays a salary only for the statuses it knows; any other word
        -- would silently drop the person from payroll.
        v_new_status := COALESCE(NULLIF(TRIM(p_status), ''), v_old_status, 'Active');
        IF v_new_status NOT IN ('Active', 'On Leave', 'Inactive') THEN
            RAISE EXCEPTION 'Status must be Active, On Leave or Inactive.';
        END IF;
        IF p_operation = 'INSERT' AND v_new_status = 'Inactive' THEN
            RAISE EXCEPTION 'A new staff member starts Active or On Leave.';
        END IF;

        IF p_monthly_salary IS NOT NULL AND p_monthly_salary < 0 THEN
            RAISE EXCEPTION 'Monthly salary cannot be negative.';
        END IF;

        -- Employee code unique per school (when supplied), ignoring case and spaces.
        IF p_employee_code IS NOT NULL AND TRIM(p_employee_code) <> ''
           AND EXISTS (
                SELECT 1 FROM core.staff
                WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                  AND is_deleted = FALSE
                  AND UPPER(TRIM(employee_code)) = UPPER(TRIM(p_employee_code))
                  AND (p_operation = 'INSERT' OR staff_id <> p_staff_id)
           ) THEN
            RAISE EXCEPTION 'Employee code already exists.';
        END IF;

        -- Mobile and email unique among this school's current staff (not the row
        -- being edited, not deleted or Inactive people, so a re-hire still works).
        -- Mobile compares the last 10 digits, the same rule as the login phone.
        IF p_mobile IS NOT NULL AND TRIM(p_mobile) <> ''
           AND EXISTS (
                SELECT 1 FROM core.staff
                WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                  AND is_deleted = FALSE AND status <> 'Inactive'
                  AND RIGHT(regexp_replace(mobile, '\D', '', 'g'), 10)
                      = RIGHT(regexp_replace(p_mobile, '\D', '', 'g'), 10)
                  AND (p_operation = 'INSERT' OR staff_id <> p_staff_id)
           ) THEN
            RAISE EXCEPTION 'A staff member with this mobile already exists.';
        END IF;

        IF p_email IS NOT NULL AND TRIM(p_email) <> ''
           AND EXISTS (
                SELECT 1 FROM core.staff
                WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                  AND is_deleted = FALSE AND status <> 'Inactive'
                  AND LOWER(TRIM(email)) = LOWER(TRIM(p_email))
                  AND (p_operation = 'INSERT' OR staff_id <> p_staff_id)
           ) THEN
            RAISE EXCEPTION 'A staff member with this email already exists.';
        END IF;

        -- Staff Type is DERIVED from the chosen Designation (single source of
        -- truth) so it can never contradict the title, even if the form is
        -- bypassed. Falls back to whatever the caller sent if the designation
        -- has no bucket set.
        IF p_designation IS NOT NULL AND TRIM(p_designation) <> '' THEN
            SELECT staff_type INTO v_staff_type
            FROM   config.designations
            WHERE  tenant_id = p_tenant_id AND is_deleted = FALSE
              AND  LOWER(TRIM(name)) = LOWER(TRIM(p_designation))
            LIMIT 1;
        END IF;
        v_staff_type := COALESCE(v_staff_type, NULLIF(TRIM(p_staff_type), ''));
        IF v_staff_type IS NOT NULL AND v_staff_type NOT IN ('Teaching', 'Non-Teaching', 'Transport', 'Support') THEN
            RAISE EXCEPTION 'Invalid staff type.';
        END IF;

        -- Status flips through the Edit form behave exactly like Deactivate /
        -- Reactivate (see the header).
        IF p_operation = 'UPDATE' THEN
            v_going_off   := v_new_status = 'Inactive' AND v_old_status <> 'Inactive';
            v_coming_back := v_old_status = 'Inactive' AND v_new_status <> 'Inactive';
        END IF;

        -- The last working day is set when someone goes Inactive, and can be
        -- corrected later while they stay Inactive.
        IF v_new_status = 'Inactive' AND (v_going_off OR p_last_working_date IS NOT NULL) THEN
            v_lwd := COALESCE(p_last_working_date, CURRENT_DATE);
            IF v_lwd > CURRENT_DATE THEN
                RAISE EXCEPTION 'The last working day cannot be in the future. Deactivate on or after that day.';
            END IF;
            IF p_last_working_date IS NULL AND COALESCE(p_joining_date, v_join) > CURRENT_DATE THEN
                v_lwd := NULL;   -- never joined (see DELETE)
            END IF;
            IF COALESCE(p_joining_date, v_join) IS NOT NULL AND v_lwd < COALESCE(p_joining_date, v_join) THEN
                RAISE EXCEPTION 'The last working day cannot be before the joining date.';
            END IF;
        END IF;

        -- Optionally create a login user (only when none is linked yet).
        IF COALESCE(p_create_login, FALSE) = TRUE
           AND v_user_id IS NULL
           AND p_email IS NOT NULL AND TRIM(p_email) <> ''
           AND p_password_hash IS NOT NULL AND TRIM(p_password_hash) <> '' THEN

            -- Shared guard (Database/user_email_unique.sql) so this can't drift from
            -- the uq_user_email_active index. The old inline check missed is_deleted.
            IF core.fn_user_email_taken(p_email) THEN
                RAISE EXCEPTION 'A login with this email already exists.';
            END IF;

            -- Same rule as uq_user_phone_active (last 10 digits), so '+91 98390 73643'
            -- gets this message instead of a raw constraint error.
            IF p_mobile IS NOT NULL AND TRIM(p_mobile) <> ''
               AND core.fn_user_phone_taken(p_mobile) THEN
                RAISE EXCEPTION 'A login with this phone already exists.';
            END IF;

            INSERT INTO core.users
                (tenant_id, school_id, email, password_hash, must_change_password, is_active, created_by, created_at)
            VALUES
                (p_tenant_id, p_school_id, LOWER(TRIM(p_email)), p_password_hash, TRUE, TRUE, p_action_user_id, NOW())
            RETURNING user_id INTO v_user_id;

            INSERT INTO core.user_profiles
                (tenant_id, user_id, school_id, full_name, phone, designation, is_active, created_by, created_at)
            VALUES
                (p_tenant_id, v_user_id, p_school_id, TRIM(p_full_name),
                 NULLIF(TRIM(p_mobile), ''), NULLIF(TRIM(p_designation), ''), TRUE, p_action_user_id, NOW());

        END IF;

        -- Reset the password of an EXISTING login when a new hash is supplied (admin
        -- "reset password" on the edit form). Force a self-reset on next sign-in.
        IF p_operation = 'UPDATE'
           AND COALESCE(p_create_login, FALSE) = FALSE
           AND v_user_id IS NOT NULL
           AND p_password_hash IS NOT NULL AND TRIM(p_password_hash) <> '' THEN
            UPDATE core.users
            SET    password_hash = p_password_hash,
                   must_change_password = TRUE,
                   password_changed_at = now(),   -- ends the person's open sessions
                   updated_by = p_action_user_id,
                   updated_at = now()
            WHERE  user_id = v_user_id AND tenant_id = p_tenant_id;

            PERFORM core.fn_admin_audit(p_tenant_id, p_school_id, p_action_user_id, 'PASSWORD_RESET_BY_ADMIN',
                'Staff', 'core.users', v_user_id, format('Password reset for staff %s', p_staff_id));
        END IF;

        -- Assign / sync the login's role(s). A user's effective permissions are the
        -- UNION of all their roles. Runs for a freshly-created OR an existing login,
        -- so the People edit form is the single place to manage a person's access.
        IF v_user_id IS NOT NULL AND p_role_ids IS NOT NULL THEN
            -- Every id must be a live role of THIS tenant (and never the platform role).
            IF EXISTS (SELECT 1 FROM unnest(p_role_ids) AS rid
                       WHERE NOT EXISTS (SELECT 1 FROM config.roles r
                                         WHERE r.role_id = rid AND r.tenant_id = p_tenant_id
                                           AND r.is_deleted = FALSE AND r.role_code <> 'SUPER_ADMIN')) THEN
                RAISE EXCEPTION 'Role not found.';
            END IF;

            SELECT string_agg(r.role_code, ', ' ORDER BY r.role_code) INTO v_old_roles
            FROM core.user_roles ur JOIN config.roles r ON r.role_id = ur.role_id
            WHERE ur.tenant_id = p_tenant_id AND ur.user_id = v_user_id
              AND ur.is_deleted = FALSE AND ur.is_active = TRUE;
            SELECT string_agg(r.role_code, ', ' ORDER BY r.role_code) INTO v_new_roles
            FROM config.roles r WHERE r.role_id = ANY (p_role_ids);

            IF v_old_roles IS DISTINCT FROM v_new_roles THEN
                IF v_user_id = p_action_user_id THEN
                    RAISE EXCEPTION 'You cannot change your own roles. Ask another School Admin.';
                END IF;

                SELECT role_id INTO v_admin_role FROM config.roles
                WHERE tenant_id = p_tenant_id AND role_code = 'SCHOOL_ADMIN' AND is_deleted = FALSE
                ORDER BY role_id LIMIT 1;
                v_had_admin  := COALESCE(v_old_roles, '') ~ '(^|, )SCHOOL_ADMIN(,|$)';
                v_gets_admin := v_admin_role = ANY (p_role_ids);

                IF v_had_admin IS DISTINCT FROM v_gets_admin
                   AND NOT core.fn_user_is_school_admin(p_tenant_id, p_action_user_id) THEN
                    RAISE EXCEPTION 'Only a School Admin can grant or remove the School Admin role.';
                END IF;
                IF v_had_admin AND NOT v_gets_admin
                   AND core.fn_is_last_school_admin(p_school_id, v_user_id) THEN
                    RAISE EXCEPTION 'This is the last active School Admin of the school. Make someone else a School Admin first.';
                END IF;

                PERFORM core.fn_admin_audit(p_tenant_id, p_school_id, p_action_user_id, 'USER_ROLES_CHANGE',
                    'Staff', 'core.user_roles', v_user_id,
                    format('Roles: [%s] -> [%s]', COALESCE(v_old_roles, ''), COALESCE(v_new_roles, '')));
            END IF;

            -- drop roles no longer selected
            UPDATE core.user_roles
            SET is_deleted = TRUE, is_active = FALSE, is_primary = FALSE,
                updated_by = p_action_user_id, updated_at = now()
            WHERE tenant_id = p_tenant_id AND user_id = v_user_id AND is_deleted = FALSE
              AND NOT (role_id = ANY (p_role_ids));

            -- revive previously-removed roles that are selected again
            UPDATE core.user_roles
            SET is_deleted = FALSE, is_active = TRUE, school_id = p_school_id,
                updated_by = p_action_user_id, updated_at = now()
            WHERE tenant_id = p_tenant_id AND user_id = v_user_id AND is_deleted = TRUE
              AND role_id = ANY (p_role_ids);

            -- insert brand-new selections
            INSERT INTO core.user_roles
                (tenant_id, user_id, role_id, school_id, is_primary, is_active, created_by, created_at)
            SELECT p_tenant_id, v_user_id, rid, p_school_id, FALSE, TRUE, p_action_user_id, now()
            FROM   unnest(p_role_ids) AS rid
            WHERE  NOT EXISTS (
                SELECT 1 FROM core.user_roles ur
                WHERE ur.tenant_id = p_tenant_id AND ur.user_id = v_user_id AND ur.role_id = rid);

            -- keep exactly one primary among the active roles (lowest role_id)
            UPDATE core.user_roles SET is_primary = FALSE
            WHERE tenant_id = p_tenant_id AND user_id = v_user_id AND is_deleted = FALSE AND is_primary = TRUE;
            UPDATE core.user_roles SET is_primary = TRUE
            WHERE user_role_id = (
                SELECT user_role_id FROM core.user_roles
                WHERE tenant_id = p_tenant_id AND user_id = v_user_id AND is_deleted = FALSE AND is_active = TRUE
                ORDER BY role_id LIMIT 1);
        END IF;

        IF p_operation = 'INSERT' THEN
            INSERT INTO core.staff
                (tenant_id, school_id, employee_code, full_name, gender, dob,
                 mobile, alt_mobile, email, blood_group, address,
                 staff_type, department, designation, joining_date, qualification,
                 experience_years, status, monthly_salary, bank_account_no, ifsc_code,
                 pan, aadhaar, user_id, created_by, updated_by)
            VALUES
                (p_tenant_id, p_school_id, NULLIF(TRIM(p_employee_code), ''), TRIM(p_full_name), p_gender, p_dob,
                 NULLIF(TRIM(p_mobile), ''), NULLIF(TRIM(p_alt_mobile), ''), NULLIF(TRIM(p_email), ''), p_blood_group, p_address,
                 v_staff_type, p_department, p_designation, p_joining_date, p_qualification,
                 p_experience_years, v_new_status, p_monthly_salary, p_bank_account_no, p_ifsc_code,
                 p_pan, p_aadhaar, v_user_id, p_action_user_id, p_action_user_id)
            RETURNING staff_id INTO v_staff_id;
        ELSE
            UPDATE core.staff
            SET employee_code   = NULLIF(TRIM(p_employee_code), ''),
                full_name       = TRIM(p_full_name),
                gender          = p_gender,
                dob             = p_dob,
                mobile          = NULLIF(TRIM(p_mobile), ''),
                alt_mobile      = NULLIF(TRIM(p_alt_mobile), ''),
                email           = NULLIF(TRIM(p_email), ''),
                blood_group     = p_blood_group,
                address         = p_address,
                staff_type      = v_staff_type,
                department      = p_department,
                designation     = p_designation,
                joining_date    = p_joining_date,
                qualification   = p_qualification,
                experience_years = p_experience_years,
                status          = v_new_status,
                -- is_active always follows the status, whichever screen set it.
                is_active       = (v_new_status <> 'Inactive'),
                status_changed_at = CASE WHEN v_going_off OR v_coming_back THEN now()
                                         ELSE status_changed_at END,
                last_working_date = CASE WHEN v_lwd IS NOT NULL THEN to_char(v_lwd, 'YYYY-MM-DD')
                                         WHEN v_coming_back THEN NULL
                                         ELSE last_working_date END,
                monthly_salary  = p_monthly_salary,
                bank_account_no = p_bank_account_no,
                ifsc_code       = p_ifsc_code,
                pan             = p_pan,
                aadhaar         = p_aadhaar,
                user_id         = COALESCE(v_user_id, user_id),
                updated_by      = p_action_user_id,
                updated_at      = now()
            WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND staff_id = p_staff_id
            RETURNING staff_id INTO v_staff_id;

            IF v_going_off THEN
                CALL core.sp_staff_login_switch(p_tenant_id, p_school_id, p_action_user_id, p_staff_id, v_user_id, FALSE);
                CALL core.sp_staff_release_duties(p_tenant_id, p_school_id, p_action_user_id, p_staff_id);
            ELSIF v_coming_back THEN
                CALL core.sp_staff_login_switch(p_tenant_id, p_school_id, p_action_user_id, p_staff_id, v_user_id, TRUE);
            END IF;
        END IF;

        OPEN p_result FOR SELECT v_staff_id AS staff_id;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation: %', p_operation;
END;
$procedure$;


-- ============================================================================
-- sp_staff_dropdowns — form source lists for the Add/Edit Staff screens:
--   cursor 0: departments      (department name)
--   cursor 1: designations     (name + default staff_type)
--   cursor 2: assignable roles (role_id + role_name) for the "give login" toggle
-- ============================================================================
DROP PROCEDURE IF EXISTS config.sp_staff_dropdowns(integer, integer, refcursor, refcursor, refcursor);

CREATE OR REPLACE PROCEDURE config.sp_staff_dropdowns(
    p_tenant_id integer,
    p_school_id integer,
    INOUT p_departments  refcursor DEFAULT 'departments_cursor',
    INOUT p_designations refcursor DEFAULT 'designations_cursor',
    INOUT p_roles        refcursor DEFAULT 'roles_cursor'
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    OPEN p_departments FOR
    SELECT name
    FROM   config.departments
    WHERE  tenant_id = p_tenant_id AND is_deleted = FALSE AND is_active = TRUE
    ORDER BY sort_order, name;

    OPEN p_designations FOR
    SELECT name, staff_type, default_department, default_role_id
    FROM   config.designations
    WHERE  tenant_id = p_tenant_id AND is_deleted = FALSE AND is_active = TRUE
    ORDER BY sort_order, name;

    -- School-scoped roles a new login can be given (exclude the platform SUPER_ADMIN).
    OPEN p_roles FOR
    SELECT role_id, role_name
    FROM   config.roles
    WHERE  tenant_id = p_tenant_id
      AND  is_deleted = FALSE AND is_active = TRUE
      AND  role_code <> 'SUPER_ADMIN'
    ORDER BY role_name;
END;
$procedure$;

-- ============================================================================
-- Staff payroll: run a month, mark a payslip paid, adjustments, money trail.
--
-- Like the leave page, this screen existed with no backend — Run Payroll and
-- Mark Paid only set a TempData message.
--
-- DESIGN NOTES
--
--   * Salary comes from core.staff.monthly_salary, snapshotted onto the payroll
--     row at run time (monthly_salary). A later salary revision must not
--     silently rewrite last month's payslip — that is the whole reason the
--     amount is stored here rather than joined at read time.
--
--   * Days are SCHOOL working days (core.fn_school_working_days — the School
--     Calendar's weekly offs and holidays excluded, half days 0.5), the same
--     function the leave screen counts with.
--
--   * Pro-rata: a joiner is paid from the joining date, a leaver up to the last
--     working day (core.staff.last_working_date). paid_days = school working days
--     employed in the month; gross = salary x paid_days / working_days. Nobody is
--     paid for a month before they joined or after they left; a leaver IS paid
--     for the days worked in the final month, even when deactivated before the
--     run. Staff "On Leave" (long leave) get a payslip; their unpaid leave is LOP.
--
--   * LOP (Loss of Pay) is APPROVED 'Unpaid' leave inside the employed part of
--     the month, plus the days Staff Attendance (core.staff_attendance) marks
--     Absent / HalfDay (0.5) / Leave on a school working day that no approved
--     leave of any type covers (absent_days). Late costs nothing. A day covered
--     by approved leave is never counted twice. A school that does not mark staff
--     attendance gets exactly the old leave-only LOP. Amounts are worked from the salary, not from a rounded per-day
--     rate, so a month that is all LOP nets exactly 0:
--         gross      = ROUND(salary x paid_days / working_days, 2)
--         lop_amount = gross - ROUND(salary x (paid_days - lop_days) / working_days, 2)
--         net_pay    = gross - lop_amount + other_add - other_deduct   (never below 0)
--
--   * Adjustments (core.staff_payroll_adjustment) are the only way to change
--     pay beyond salary and LOP: Addition (arrears, bonus, encashment, a
--     correction owed), Deduction (fine, advance recovery, a correction taken
--     back) and Advance (money handed over early — recorded with its payment
--     mode/reference and deducted from that month). Each row keeps who, when,
--     how much, which month and why; it is never edited, only voided with a
--     reason while its month is unpaid.
--
--   * A PAID payslip is history: RUN skips it (and reports it when today's
--     figures would differ), the trigger trg_staff_payroll_paid_lock refuses any
--     UPDATE of it, and corrections go as an adjustment in an unpaid month.
--     Mark Paid records the payment mode and reference (UTR / cheque no.), so a
--     "Paid" flag can be matched to a bank statement.
--
--   * Every generate / regenerate / remove / pay / adjust writes a row to
--     core.staff_payroll_history (append-only: a trigger refuses UPDATE). Draft
--     figures may be recomputed, but the trail of what they were is kept.
--
--   * Payroll cannot be run for a future month.
--
--   * One row per staff per month, enforced by a unique index rather than by
--     the proc remembering to check.
--
-- Target DB: PostgreSQL. Safe to re-run. Needs staff_leave.sql (fn_school_working_days),
-- sp_staff_manage.sql (core.staff.last_working_date) and staff_attendance.sql.
-- ============================================================================

CREATE TABLE IF NOT EXISTS core.staff_payroll (
    payroll_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     integer NOT NULL,
    school_id     integer NOT NULL,
    staff_id      integer NOT NULL,

    pay_month     integer NOT NULL,          -- 1..12
    pay_year      integer NOT NULL,

    gross         numeric(12,2) NOT NULL DEFAULT 0,   -- earned for the employed days
    lop_days      numeric(5,1)  NOT NULL DEFAULT 0,
    lop_amount    numeric(12,2) NOT NULL DEFAULT 0,
    other_deduct  numeric(12,2) NOT NULL DEFAULT 0,
    net_pay       numeric(12,2) NOT NULL DEFAULT 0,

    status        varchar(20) NOT NULL DEFAULT 'Draft',
    generated_by  integer NOT NULL DEFAULT 0,
    generated_at  timestamptz NOT NULL DEFAULT now(),
    paid_by       integer,
    paid_at       timestamptz,

    CONSTRAINT chk_staff_payroll_status CHECK (status IN ('Draft', 'Paid')),
    CONSTRAINT chk_staff_payroll_month  CHECK (pay_month BETWEEN 1 AND 12)
);

-- One payslip per staff per month. A constraint, not a convention.
CREATE UNIQUE INDEX IF NOT EXISTS ux_staff_payroll_period
    ON core.staff_payroll (tenant_id, school_id, staff_id, pay_year, pay_month);

-- Oct 2026: pro-rata, half-day LOP, additions, how a payment was made.
DO $mig$
BEGIN
    IF (SELECT data_type FROM information_schema.columns
        WHERE table_schema = 'core' AND table_name = 'staff_payroll' AND column_name = 'lop_days') = 'integer' THEN
        ALTER TABLE core.staff_payroll ALTER COLUMN lop_days TYPE numeric(5,1);
    END IF;
END $mig$;

ALTER TABLE core.staff_payroll ADD COLUMN IF NOT EXISTS monthly_salary    numeric(12,2);  -- salary rate used
ALTER TABLE core.staff_payroll ADD COLUMN IF NOT EXISTS working_days      numeric(5,1);   -- school days in the month
ALTER TABLE core.staff_payroll ADD COLUMN IF NOT EXISTS paid_days         numeric(5,1);   -- of those, days employed
ALTER TABLE core.staff_payroll ADD COLUMN IF NOT EXISTS other_add         numeric(12,2) NOT NULL DEFAULT 0;
ALTER TABLE core.staff_payroll ADD COLUMN IF NOT EXISTS payment_mode      varchar(20);
ALTER TABLE core.staff_payroll ADD COLUMN IF NOT EXISTS payment_reference varchar(60);
ALTER TABLE core.staff_payroll ADD COLUMN IF NOT EXISTS absent_days       numeric(5,1) NOT NULL DEFAULT 0;  -- of lop_days, from Staff Attendance

ALTER TABLE core.staff_payroll DROP CONSTRAINT IF EXISTS chk_staff_payroll_mode;
ALTER TABLE core.staff_payroll ADD CONSTRAINT chk_staff_payroll_mode
    CHECK (payment_mode IS NULL OR payment_mode IN ('Cash', 'Bank Transfer', 'Cheque', 'UPI'));
-- A paid slip says how it was paid. NOT VALID: slips paid before this release
-- have no mode and stay as they are; every new payment must carry one.
ALTER TABLE core.staff_payroll DROP CONSTRAINT IF EXISTS chk_staff_payroll_paid_mode;
ALTER TABLE core.staff_payroll ADD CONSTRAINT chk_staff_payroll_paid_mode
    CHECK (status <> 'Paid' OR payment_mode IS NOT NULL) NOT VALID;

-- A paid payslip is never rewritten -- not by RUN, not by anything else.
CREATE OR REPLACE FUNCTION core.fn_staff_payroll_paid_lock()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
    IF OLD.status = 'Paid' THEN
        RAISE EXCEPTION 'This payslip is already paid and cannot be changed. Record an adjustment in an unpaid month instead.';
    END IF;
    RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_staff_payroll_paid_lock ON core.staff_payroll;
CREATE TRIGGER trg_staff_payroll_paid_lock
    BEFORE UPDATE ON core.staff_payroll
    FOR EACH ROW EXECUTE FUNCTION core.fn_staff_payroll_paid_lock();


-- Additions, deductions and advances against one staff member's month.
CREATE TABLE IF NOT EXISTS core.staff_payroll_adjustment (
    adjustment_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id         integer NOT NULL,
    school_id         integer NOT NULL,
    staff_id          integer NOT NULL,
    pay_month         integer NOT NULL,
    pay_year          integer NOT NULL,
    kind              varchar(20) NOT NULL,      -- Addition | Deduction | Advance
    amount            numeric(12,2) NOT NULL,
    reason            text NOT NULL,
    payment_mode      varchar(20),               -- Advance: how the money was handed over
    payment_reference varchar(60),
    created_by        integer NOT NULL,
    created_at        timestamptz NOT NULL DEFAULT now(),
    is_void           boolean NOT NULL DEFAULT FALSE,
    voided_by         integer,
    voided_at         timestamptz,
    void_reason       text,
    CONSTRAINT chk_staff_payroll_adj_kind   CHECK (kind IN ('Addition', 'Deduction', 'Advance')),
    CONSTRAINT chk_staff_payroll_adj_amount CHECK (amount > 0),
    CONSTRAINT chk_staff_payroll_adj_month  CHECK (pay_month BETWEEN 1 AND 12),
    CONSTRAINT chk_staff_payroll_adj_mode   CHECK (payment_mode IS NULL OR payment_mode IN ('Cash', 'Bank Transfer', 'Cheque', 'UPI'))
);
CREATE INDEX IF NOT EXISTS ix_staff_payroll_adj_period
    ON core.staff_payroll_adjustment (tenant_id, school_id, pay_year, pay_month, staff_id);


-- The money trail. One row per event; never updated.
CREATE TABLE IF NOT EXISTS core.staff_payroll_history (
    history_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id         integer NOT NULL,
    school_id         integer NOT NULL,
    payroll_id        integer,                   -- NULL for an adjustment made before the run
    staff_id          integer NOT NULL,
    pay_month         integer NOT NULL,
    pay_year          integer NOT NULL,
    action            varchar(30) NOT NULL,      -- GENERATED | REGENERATED | DRAFT_REMOVED | PAID
                                                 -- | ADJUSTMENT_ADDED | ADJUSTMENT_VOIDED
    gross             numeric(12,2),
    lop_days          numeric(5,1),
    lop_amount        numeric(12,2),
    other_add         numeric(12,2),
    other_deduct      numeric(12,2),
    net_pay           numeric(12,2),
    payment_mode      varchar(20),
    payment_reference varchar(60),
    note              text,
    action_by         integer NOT NULL,
    action_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_staff_payroll_history_staff
    ON core.staff_payroll_history (tenant_id, school_id, staff_id, pay_year, pay_month);

CREATE OR REPLACE FUNCTION core.fn_staff_payroll_history_lock()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
    RAISE EXCEPTION 'Payroll history cannot be changed.';
END;
$fn$;

DROP TRIGGER IF EXISTS trg_staff_payroll_history_lock ON core.staff_payroll_history;
CREATE TRIGGER trg_staff_payroll_history_lock
    BEFORE UPDATE ON core.staff_payroll_history
    FOR EACH ROW EXECUTE FUNCTION core.fn_staff_payroll_history_lock();


-- Display name of a user for the trail ('' when unknown).
CREATE OR REPLACE FUNCTION core.fn_payroll_user_name(p_user_id integer)
RETURNS text
LANGUAGE sql
STABLE
AS $fn$
    SELECT COALESCE((SELECT up.full_name FROM core.user_profiles up
                     WHERE up.user_id = p_user_id ORDER BY up.user_profile_id LIMIT 1),
                    (SELECT u.email FROM core.users u WHERE u.user_id = p_user_id), '');
$fn$;


-- ----------------------------------------------------------------------------
-- Build (or rebuild) ONE staff member's payslip for one month. Used by RUN for
-- every staff member and by an adjustment for the one it touches.
--
-- Returns what happened:
--   'made'         draft created or brought up to date (unchanged drafts stay as they are)
--   'negative'     draft made, but deductions exceed pay -- net held at 0
--   'removed'      the person was not employed that month; a stale draft was removed
--   'none'         not employed that month, nothing to do
--   'paid'         already paid, today's figures agree
--   'paid_differs' already paid, today's figures would differ (left untouched)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_staff_payslip_build(
    p_tenant_id integer, p_school_id integer, p_action_user_id integer,
    p_staff_id integer, p_month integer, p_year integer)
RETURNS text
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_start   date := make_date(p_year, p_month, 1);
    v_end     date := (make_date(p_year, p_month, 1) + INTERVAL '1 month' - INTERVAL '1 day')::date;
    v_work    numeric;
    v_has     boolean;
    v_emp     boolean;
    p         record;
    s         record;
    v_from    date;
    v_to      date;
    v_paid    numeric := 0;
    v_lop     numeric := 0;
    v_abs     numeric := 0;
    v_salary  numeric;
    v_gross   numeric;
    v_after   numeric;
    v_lop_amt numeric;
    v_add     numeric;
    v_ded     numeric;
    v_raw     numeric;
    v_net     numeric;
BEGIN
    v_work := core.fn_school_working_days(p_tenant_id, p_school_id, v_start, v_end);

    SELECT * INTO p FROM core.staff_payroll
    WHERE tenant_id = p_tenant_id AND school_id = p_school_id
      AND staff_id = p_staff_id AND pay_year = p_year AND pay_month = p_month;
    v_has := FOUND;

    SELECT st.status, st.monthly_salary,
           NULLIF(st.joining_date, '')::date      AS join_d,
           NULLIF(st.last_working_date, '')::date AS lwd
      INTO s
    FROM core.staff st
    WHERE st.staff_id = p_staff_id AND st.tenant_id = p_tenant_id
      AND st.school_id = p_school_id AND st.is_deleted = FALSE;

    -- Employed in this month? An Inactive row without a last working day was
    -- deactivated before that column existed: no honest dates, so no pay.
    v_emp := FOUND AND v_work > 0 AND (s.status <> 'Inactive' OR s.lwd IS NOT NULL);
    IF v_emp THEN
        v_from := GREATEST(v_start, COALESCE(s.join_d, v_start));
        v_to   := LEAST(v_end, COALESCE(s.lwd, v_end));
        v_emp  := v_from <= v_to;
    END IF;
    IF v_emp THEN
        v_paid := core.fn_school_working_days(p_tenant_id, p_school_id, v_from, v_to);
    END IF;

    IF NOT v_emp OR v_paid = 0 THEN
        IF v_has AND p.status = 'Paid' THEN
            RETURN 'paid_differs';
        END IF;
        IF v_has THEN
            DELETE FROM core.staff_payroll WHERE payroll_id = p.payroll_id;
            INSERT INTO core.staff_payroll_history
                (tenant_id, school_id, payroll_id, staff_id, pay_month, pay_year, action,
                 gross, lop_days, lop_amount, other_add, other_deduct, net_pay, note, action_by)
            VALUES (p_tenant_id, p_school_id, p.payroll_id, p_staff_id, p_month, p_year, 'DRAFT_REMOVED',
                    p.gross, p.lop_days, p.lop_amount, p.other_add, p.other_deduct, p.net_pay,
                    'Not employed in this month (joining date / last working day).', p_action_user_id);
            RETURN 'removed';
        END IF;
        RETURN 'none';
    END IF;

    -- LOP: approved Unpaid leave inside the employed part of the month.
    SELECT COALESCE(SUM(CASE WHEN l.half_day THEN l.days
                             ELSE core.fn_school_working_days(p_tenant_id, p_school_id,
                                      GREATEST(l.from_date::date, v_from), LEAST(l.to_date::date, v_to)) END), 0)
      INTO v_lop
    FROM core.staff_leave l
    WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
      AND l.staff_id = p_staff_id
      AND l.status = 'Approved'
      AND LOWER(l.leave_type) = 'unpaid'
      AND l.from_date::date <= v_to AND l.to_date::date >= v_from;

    -- Plus Staff Attendance: Absent / HalfDay / Leave on a school working day
    -- with no approved leave of any type (a covered day is paid leave, or is
    -- already in the Unpaid sum above). A half school day weighs 0.5.
    SELECT COALESCE(SUM(core.fn_school_working_days(p_tenant_id, p_school_id, a.att_date, a.att_date)
                        * CASE a.status WHEN 'HalfDay' THEN 0.5 ELSE 1 END), 0)
      INTO v_abs
    FROM core.staff_attendance a
    WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
      AND a.staff_id = p_staff_id
      AND a.att_date BETWEEN v_from AND v_to
      AND a.status IN ('Absent', 'HalfDay', 'Leave')
      AND NOT EXISTS (SELECT 1 FROM core.staff_leave l
                       WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
                         AND l.staff_id = p_staff_id AND l.status = 'Approved'
                         AND a.att_date BETWEEN l.from_date::date AND l.to_date::date);

    v_lop := LEAST(v_lop + v_abs, v_paid);
    v_abs := LEAST(v_abs, v_lop);

    v_salary  := COALESCE(s.monthly_salary, 0);
    v_gross   := ROUND(v_salary * v_paid / v_work, 2);
    v_after   := ROUND(v_salary * (v_paid - v_lop) / v_work, 2);
    v_lop_amt := v_gross - v_after;

    SELECT COALESCE(SUM(amount) FILTER (WHERE kind = 'Addition'), 0),
           COALESCE(SUM(amount) FILTER (WHERE kind IN ('Deduction', 'Advance')), 0)
      INTO v_add, v_ded
    FROM core.staff_payroll_adjustment
    WHERE tenant_id = p_tenant_id AND school_id = p_school_id
      AND staff_id = p_staff_id AND pay_year = p_year AND pay_month = p_month
      AND is_void = FALSE;

    v_raw := v_after + v_add - v_ded;
    v_net := GREATEST(v_raw, 0);

    IF v_has AND p.status = 'Paid' THEN
        IF p.gross = v_gross AND p.lop_days = v_lop AND p.other_add = v_add
           AND p.other_deduct = v_ded AND p.net_pay = v_net THEN
            RETURN 'paid';
        END IF;
        RETURN 'paid_differs';
    END IF;

    IF NOT v_has THEN
        INSERT INTO core.staff_payroll (
            tenant_id, school_id, staff_id, pay_month, pay_year,
            monthly_salary, working_days, paid_days,
            gross, lop_days, absent_days, lop_amount, other_add, other_deduct, net_pay,
            status, generated_by, generated_at)
        VALUES (
            p_tenant_id, p_school_id, p_staff_id, p_month, p_year,
            v_salary, v_work, v_paid,
            v_gross, v_lop, v_abs, v_lop_amt, v_add, v_ded, v_net,
            'Draft', p_action_user_id, now())
        RETURNING * INTO p;

        INSERT INTO core.staff_payroll_history
            (tenant_id, school_id, payroll_id, staff_id, pay_month, pay_year, action,
             gross, lop_days, lop_amount, other_add, other_deduct, net_pay, action_by)
        VALUES (p_tenant_id, p_school_id, p.payroll_id, p_staff_id, p_month, p_year, 'GENERATED',
                v_gross, v_lop, v_lop_amt, v_add, v_ded, v_net, p_action_user_id);

    ELSIF (p.monthly_salary, p.working_days, p.paid_days, p.gross, p.lop_days, p.absent_days, p.lop_amount,
           p.other_add, p.other_deduct, p.net_pay)
          IS DISTINCT FROM
          (v_salary, v_work, v_paid, v_gross, v_lop, v_abs, v_lop_amt, v_add, v_ded, v_net) THEN
        UPDATE core.staff_payroll
        SET monthly_salary = v_salary, working_days = v_work, paid_days = v_paid,
            gross = v_gross, lop_days = v_lop, absent_days = v_abs, lop_amount = v_lop_amt,
            other_add = v_add, other_deduct = v_ded, net_pay = v_net,
            generated_by = p_action_user_id, generated_at = now()
        WHERE payroll_id = p.payroll_id;

        INSERT INTO core.staff_payroll_history
            (tenant_id, school_id, payroll_id, staff_id, pay_month, pay_year, action,
             gross, lop_days, lop_amount, other_add, other_deduct, net_pay, note, action_by)
        VALUES (p_tenant_id, p_school_id, p.payroll_id, p_staff_id, p_month, p_year, 'REGENERATED',
                v_gross, v_lop, v_lop_amt, v_add, v_ded, v_net,
                format('Was gross %s, LOP %s, net %s.', p.gross, p.lop_amount, p.net_pay), p_action_user_id);
    END IF;

    RETURN CASE WHEN v_raw < 0 THEN 'negative' ELSE 'made' END;
END;
$fn$;


-- The signature grew trailing payment parameters; drop the old one so a
-- 9-argument call is not ambiguous between two overloads.
DROP PROCEDURE IF EXISTS core.sp_staff_payroll_manage(
    text, integer, integer, integer, integer, integer, integer, text, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_staff_payroll_manage(
    IN    p_operation         text,          -- LIST | RUN | MARK_PAID | HISTORY
    IN    p_tenant_id         integer,
    IN    p_school_id         integer,
    IN    p_action_user_id    integer,
    IN    p_month             integer DEFAULT NULL,
    IN    p_year              integer DEFAULT NULL,
    IN    p_payroll_id        integer DEFAULT NULL,
    IN    p_department        text    DEFAULT NULL,
    INOUT p_result            refcursor DEFAULT 'payroll_cursor'::refcursor,
    -- MARK_PAID: how it was paid. Last so positional callers still work.
    IN    p_payment_mode      text    DEFAULT NULL,
    IN    p_payment_reference text    DEFAULT NULL)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_start    date;
    v_end      date;
    v_work     numeric;
    v_made     integer := 0;
    v_skipped  integer := 0;
    v_differs  integer := 0;
    v_removed  integer := 0;
    v_negative integer := 0;
    v_out      text;
    v_status   text;
    v_mode     text;
    v_ref      text;
    r          record;
    v_slip     record;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    -- ── LIST ────────────────────────────────────────────────────────────────
    IF p_operation = 'LIST' THEN
        IF p_month IS NULL OR p_year IS NULL THEN
            RAISE EXCEPTION 'Choose the payroll month.';
        END IF;

        OPEN p_result FOR
        SELECT p.payroll_id, p.staff_id, s.full_name, s.employee_code,
               s.designation, s.department,
               p.pay_month, p.pay_year,
               p.monthly_salary, p.working_days, p.paid_days,
               p.gross, p.lop_days, p.absent_days, p.lop_amount, p.other_add, p.other_deduct, p.net_pay,
               p.status, p.generated_at, p.paid_at, p.payment_mode, p.payment_reference,
               core.fn_payroll_user_name(p.paid_by) AS paid_by_name
        FROM core.staff_payroll p
        JOIN core.staff s ON s.staff_id = p.staff_id
        WHERE p.tenant_id = p_tenant_id AND p.school_id = p_school_id
          AND p.pay_month = p_month AND p.pay_year = p_year
          AND (p_department IS NULL OR TRIM(p_department) = ''
               OR LOWER(COALESCE(s.department, '')) = LOWER(TRIM(p_department)))
        ORDER BY s.full_name;
        RETURN;
    END IF;

    -- ── HISTORY: the money trail of one payslip's staff member and month ────
    IF p_operation = 'HISTORY' THEN
        SELECT staff_id, pay_month, pay_year INTO v_slip FROM core.staff_payroll
        WHERE payroll_id = p_payroll_id AND tenant_id = p_tenant_id AND school_id = p_school_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Payslip not found.';
        END IF;

        OPEN p_result FOR
        SELECT h.history_id, h.action, h.gross, h.lop_days, h.lop_amount, h.other_add,
               h.other_deduct, h.net_pay, h.payment_mode, h.payment_reference, h.note,
               h.action_at, core.fn_payroll_user_name(h.action_by) AS action_by_name
        FROM core.staff_payroll_history h
        WHERE h.tenant_id = p_tenant_id AND h.school_id = p_school_id
          AND h.staff_id = v_slip.staff_id AND h.pay_month = v_slip.pay_month AND h.pay_year = v_slip.pay_year
        ORDER BY h.action_at, h.history_id;
        RETURN;
    END IF;

    -- ── RUN ─────────────────────────────────────────────────────────────────
    IF p_operation = 'RUN' THEN
        IF p_month IS NULL OR p_year IS NULL THEN
            RAISE EXCEPTION 'Choose the payroll month.';
        END IF;
        IF p_month NOT BETWEEN 1 AND 12 THEN
            RAISE EXCEPTION 'Choose a month between 1 and 12.';
        END IF;

        v_start := make_date(p_year, p_month, 1);
        v_end   := (v_start + INTERVAL '1 month' - INTERVAL '1 day')::date;

        IF v_start > DATE_TRUNC('month', CURRENT_DATE)::date THEN
            RAISE EXCEPTION 'Payroll cannot be run for a future month.';
        END IF;

        v_work := core.fn_school_working_days(p_tenant_id, p_school_id, v_start, v_end);
        IF v_work = 0 THEN
            RAISE EXCEPTION 'That month has no working days on the school calendar.';
        END IF;

        -- One run per school and month at a time.
        PERFORM pg_advisory_xact_lock(p_school_id, p_year * 100 + p_month);

        -- Every staff row of the school (leavers too: their last month is owed),
        -- plus any draft whose staff row has gone, so stale drafts are removed.
        FOR r IN
            SELECT s.staff_id FROM core.staff s
            WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id AND s.is_deleted = FALSE
            UNION
            SELECT p2.staff_id FROM core.staff_payroll p2
            WHERE p2.tenant_id = p_tenant_id AND p2.school_id = p_school_id
              AND p2.pay_year = p_year AND p2.pay_month = p_month
        LOOP
            v_out := core.fn_staff_payslip_build(p_tenant_id, p_school_id, p_action_user_id,
                                                  r.staff_id, p_month, p_year);
            IF v_out IN ('made', 'negative') THEN v_made := v_made + 1; END IF;
            IF v_out = 'negative'            THEN v_negative := v_negative + 1; END IF;
            IF v_out IN ('paid', 'paid_differs') THEN v_skipped := v_skipped + 1; END IF;
            IF v_out = 'paid_differs'        THEN v_differs := v_differs + 1; END IF;
            IF v_out = 'removed'             THEN v_removed := v_removed + 1; END IF;
        END LOOP;

        OPEN p_result FOR
        SELECT TRUE AS success, v_made AS generated, v_skipped AS skipped, v_work AS working_days,
               v_made || ' payslip(s) generated for ' || trim_scale(v_work) || ' working day(s).'
               || CASE WHEN v_skipped > 0
                       THEN ' ' || v_skipped || ' already paid and left untouched.' ELSE '' END
               || CASE WHEN v_differs > 0
                       THEN ' ' || v_differs || ' paid payslip(s) differ from today''s salary/leave -- record an adjustment in an unpaid month if money is owed.' ELSE '' END
               || CASE WHEN v_removed > 0
                       THEN ' ' || v_removed || ' draft(s) removed for staff not employed that month.' ELSE '' END
               || CASE WHEN v_negative > 0
                       THEN ' ' || v_negative || ' payslip(s) have deductions larger than the pay; net held at zero.' ELSE '' END
               AS message;
        RETURN;
    END IF;

    -- ── MARK_PAID ───────────────────────────────────────────────────────────
    IF p_operation = 'MARK_PAID' THEN
        SELECT * INTO v_slip
        FROM core.staff_payroll
        WHERE payroll_id = p_payroll_id
          AND tenant_id = p_tenant_id AND school_id = p_school_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Payslip not found.';
        END IF;

        -- Paying twice would overwrite who paid it and when.
        IF v_slip.status = 'Paid' THEN
            RAISE EXCEPTION 'This payslip is already marked paid.';
        END IF;

        -- Leave or absence can still be marked until the month ends.
        IF CURRENT_DATE < (make_date(v_slip.pay_year, v_slip.pay_month, 1) + INTERVAL '1 month' - INTERVAL '1 day')::date THEN
            RAISE EXCEPTION 'This month is not over yet. Salary can be marked paid from its last day.';
        END IF;

        -- The draft may be old (leave approved or salary changed after it was made):
        -- bring it up to date first, so the money paid is today's figure.
        v_out := core.fn_staff_payslip_build(p_tenant_id, p_school_id, p_action_user_id,
                     v_slip.staff_id, v_slip.pay_month, v_slip.pay_year);
        IF v_out IN ('removed', 'none') THEN
            RAISE EXCEPTION 'This staff member was not employed in that month; the payslip was removed.';
        END IF;
        SELECT * INTO v_slip FROM core.staff_payroll
         WHERE tenant_id = p_tenant_id AND school_id = p_school_id
           AND staff_id = v_slip.staff_id AND pay_month = v_slip.pay_month AND pay_year = v_slip.pay_year;
        IF NOT FOUND OR v_slip.status = 'Paid' THEN
            RAISE EXCEPTION 'Payslip not found. Run payroll for the month again.';
        END IF;

        SELECT m INTO v_mode FROM unnest(ARRAY['Cash', 'Bank Transfer', 'Cheque', 'UPI']) AS m
        WHERE LOWER(m) = LOWER(TRIM(COALESCE(p_payment_mode, '')));
        IF v_mode IS NULL THEN
            RAISE EXCEPTION 'Choose how the salary was paid: Cash, Bank Transfer, Cheque or UPI.';
        END IF;
        v_ref := NULLIF(TRIM(COALESCE(p_payment_reference, '')), '');
        IF v_mode <> 'Cash' AND v_ref IS NULL THEN
            RAISE EXCEPTION 'Enter the % reference (UTR / cheque number / UPI id) so the payment can be traced.', v_mode;
        END IF;
        IF length(v_ref) > 60 THEN
            RAISE EXCEPTION 'The payment reference is too long (60 characters at most).';
        END IF;

        UPDATE core.staff_payroll
        SET status = 'Paid', paid_by = p_action_user_id, paid_at = now(),
            payment_mode = v_mode, payment_reference = v_ref
        WHERE payroll_id = v_slip.payroll_id
          AND tenant_id = p_tenant_id AND school_id = p_school_id
          AND status = 'Draft';
        IF NOT FOUND THEN
            RAISE EXCEPTION 'This payslip is already marked paid.';
        END IF;

        INSERT INTO core.staff_payroll_history
            (tenant_id, school_id, payroll_id, staff_id, pay_month, pay_year, action,
             gross, lop_days, lop_amount, other_add, other_deduct, net_pay,
             payment_mode, payment_reference, action_by)
        VALUES (p_tenant_id, p_school_id, v_slip.payroll_id, v_slip.staff_id, v_slip.pay_month, v_slip.pay_year, 'PAID',
                v_slip.gross, v_slip.lop_days, v_slip.lop_amount, v_slip.other_add, v_slip.other_deduct, v_slip.net_pay,
                v_mode, v_ref, p_action_user_id);

        OPEN p_result FOR
        SELECT TRUE AS success, 0 AS generated, 0 AS skipped, 0::numeric AS working_days,
               'Payslip marked paid (' || v_mode || COALESCE(', ' || v_ref, '') || ').' AS message;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation %.', p_operation;
END;
$procedure$;


-- ----------------------------------------------------------------------------
-- Payroll adjustments: LIST | ADD | VOID.
--   ADD  : Addition / Deduction / Advance for one staff member's month. Refused
--          when that month is already paid (corrections go to an unpaid month)
--          or the person was not employed in it. A draft for that month is
--          rebuilt at once; a deduction that would push its net below zero is
--          refused.
--   VOID : cancels an adjustment (with a reason) while its month is unpaid.
-- Nothing is ever deleted or edited in place.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE core.sp_staff_payroll_adjust(
    IN    p_operation         text,
    IN    p_tenant_id         integer,
    IN    p_school_id         integer,
    IN    p_action_user_id    integer,
    IN    p_adjustment_id     integer DEFAULT NULL,
    IN    p_staff_id          integer DEFAULT NULL,
    IN    p_month             integer DEFAULT NULL,
    IN    p_year              integer DEFAULT NULL,
    IN    p_kind              text    DEFAULT NULL,
    IN    p_amount            numeric DEFAULT NULL,
    IN    p_reason            text    DEFAULT NULL,
    IN    p_payment_mode      text    DEFAULT NULL,
    IN    p_payment_reference text    DEFAULT NULL,
    INOUT p_result            refcursor DEFAULT 'payroll_adjust_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_start  date;
    v_end    date;
    v_kind   text;
    v_mode   text;
    v_ref    text;
    v_reason text := NULLIF(TRIM(COALESCE(p_reason, '')), '');
    v_id     integer;
    v_out    text;
    v_pid    integer;
    v_pstat  text;
    a        record;
    s        record;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    -- ── LIST ────────────────────────────────────────────────────────────────
    IF p_operation = 'LIST' THEN
        IF p_month IS NULL OR p_year IS NULL THEN
            RAISE EXCEPTION 'Choose the payroll month.';
        END IF;
        OPEN p_result FOR
        SELECT a2.adjustment_id, a2.staff_id, st.full_name, st.employee_code,
               a2.pay_month, a2.pay_year, a2.kind, a2.amount, a2.reason,
               a2.payment_mode, a2.payment_reference,
               a2.created_at, core.fn_payroll_user_name(a2.created_by) AS created_by_name,
               a2.is_void, a2.voided_at, a2.void_reason
        FROM core.staff_payroll_adjustment a2
        JOIN core.staff st ON st.staff_id = a2.staff_id
        WHERE a2.tenant_id = p_tenant_id AND a2.school_id = p_school_id
          AND a2.pay_month = p_month AND a2.pay_year = p_year
          AND (p_staff_id IS NULL OR a2.staff_id = p_staff_id)
        ORDER BY st.full_name, a2.created_at, a2.adjustment_id;
        RETURN;
    END IF;

    -- ── ADD ─────────────────────────────────────────────────────────────────
    IF p_operation = 'ADD' THEN
        IF p_month IS NULL OR p_year IS NULL OR p_month NOT BETWEEN 1 AND 12 THEN
            RAISE EXCEPTION 'Choose the payroll month.';
        END IF;
        v_start := make_date(p_year, p_month, 1);
        v_end   := (v_start + INTERVAL '1 month' - INTERVAL '1 day')::date;
        IF v_start > DATE_TRUNC('month', CURRENT_DATE)::date THEN
            RAISE EXCEPTION 'Adjustments cannot be made for a future month.';
        END IF;

        SELECT k INTO v_kind FROM unnest(ARRAY['Addition', 'Deduction', 'Advance']) AS k
        WHERE LOWER(k) = LOWER(TRIM(COALESCE(p_kind, '')));
        IF v_kind IS NULL THEN
            RAISE EXCEPTION 'Choose Addition, Deduction or Advance.';
        END IF;
        IF p_amount IS NULL OR p_amount <= 0 THEN
            RAISE EXCEPTION 'Enter an amount greater than zero.';
        END IF;
        IF p_amount <> ROUND(p_amount, 2) THEN
            RAISE EXCEPTION 'Amounts are in rupees and paise (two decimals at most).';
        END IF;
        IF v_reason IS NULL THEN
            RAISE EXCEPTION 'Give a reason for the adjustment.';
        END IF;

        IF v_kind = 'Advance' THEN
            SELECT m INTO v_mode FROM unnest(ARRAY['Cash', 'Bank Transfer', 'Cheque', 'UPI']) AS m
            WHERE LOWER(m) = LOWER(TRIM(COALESCE(p_payment_mode, '')));
            IF v_mode IS NULL THEN
                RAISE EXCEPTION 'Choose how the advance was paid: Cash, Bank Transfer, Cheque or UPI.';
            END IF;
            v_ref := NULLIF(TRIM(COALESCE(p_payment_reference, '')), '');
            IF v_mode <> 'Cash' AND v_ref IS NULL THEN
                RAISE EXCEPTION 'Enter the % reference so the advance can be traced.', v_mode;
            END IF;
        END IF;

        SELECT status, NULLIF(joining_date, '')::date AS join_d, NULLIF(last_working_date, '')::date AS lwd
          INTO s
        FROM core.staff
        WHERE staff_id = p_staff_id AND tenant_id = p_tenant_id
          AND school_id = p_school_id AND is_deleted = FALSE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Staff member not found.';
        END IF;
        IF (s.status = 'Inactive' AND s.lwd IS NULL)
           OR COALESCE(s.join_d, v_start) > v_end
           OR COALESCE(s.lwd, v_end) < v_start THEN
            RAISE EXCEPTION 'This staff member was not on the payroll in that month.';
        END IF;

        SELECT payroll_id, status INTO v_pid, v_pstat FROM core.staff_payroll
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND staff_id = p_staff_id AND pay_year = p_year AND pay_month = p_month;
        IF v_pstat = 'Paid' THEN
            RAISE EXCEPTION 'Salary for % is already paid. Record this against the next unpaid month.',
                to_char(v_start, 'FMMonth YYYY');
        END IF;

        INSERT INTO core.staff_payroll_adjustment
            (tenant_id, school_id, staff_id, pay_month, pay_year, kind, amount, reason,
             payment_mode, payment_reference, created_by)
        VALUES (p_tenant_id, p_school_id, p_staff_id, p_month, p_year, v_kind, p_amount, v_reason,
                v_mode, v_ref, p_action_user_id)
        RETURNING adjustment_id INTO v_id;

        -- A draft for that month picks the adjustment up straight away.
        IF v_pid IS NOT NULL THEN
            v_out := core.fn_staff_payslip_build(p_tenant_id, p_school_id, p_action_user_id,
                                                  p_staff_id, p_month, p_year);
            IF v_out = 'negative' THEN
                RAISE EXCEPTION 'This deduction is more than the pay left for that month.';
            END IF;
        END IF;

        INSERT INTO core.staff_payroll_history
            (tenant_id, school_id, payroll_id, staff_id, pay_month, pay_year, action,
             net_pay, payment_mode, payment_reference, note, action_by)
        VALUES (p_tenant_id, p_school_id, v_pid, p_staff_id, p_month, p_year, 'ADJUSTMENT_ADDED',
                (SELECT net_pay FROM core.staff_payroll WHERE payroll_id = v_pid),
                v_mode, v_ref,
                format('#%s %s %s: %s', v_id, v_kind, p_amount, v_reason), p_action_user_id);

        OPEN p_result FOR
        SELECT TRUE AS success, v_id AS adjustment_id,
               v_kind || ' of ' || p_amount || ' recorded'
               || CASE WHEN v_pid IS NULL THEN '. It is included when payroll is run for that month.'
                       ELSE ' and the draft payslip updated.' END AS message;
        RETURN;
    END IF;

    -- ── VOID ────────────────────────────────────────────────────────────────
    IF p_operation = 'VOID' THEN
        SELECT * INTO a FROM core.staff_payroll_adjustment
        WHERE adjustment_id = p_adjustment_id AND tenant_id = p_tenant_id AND school_id = p_school_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Adjustment not found.';
        END IF;
        IF a.is_void THEN
            RAISE EXCEPTION 'This adjustment is already void.';
        END IF;
        IF v_reason IS NULL THEN
            RAISE EXCEPTION 'Give a reason for voiding the adjustment.';
        END IF;

        SELECT payroll_id INTO v_pid FROM core.staff_payroll
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND staff_id = a.staff_id AND pay_year = a.pay_year AND pay_month = a.pay_month;
        IF v_pid IS NOT NULL AND (SELECT status FROM core.staff_payroll WHERE payroll_id = v_pid) = 'Paid' THEN
            RAISE EXCEPTION 'Salary for that month is already paid, so this adjustment stays. Record a correction in an unpaid month.';
        END IF;

        UPDATE core.staff_payroll_adjustment
        SET is_void = TRUE, voided_by = p_action_user_id, voided_at = now(), void_reason = v_reason
        WHERE adjustment_id = p_adjustment_id;

        IF v_pid IS NOT NULL THEN
            v_out := core.fn_staff_payslip_build(p_tenant_id, p_school_id, p_action_user_id,
                                                  a.staff_id, a.pay_month, a.pay_year);
            IF v_out = 'negative' THEN
                RAISE EXCEPTION 'Voiding this addition would leave less than the deductions for that month.';
            END IF;
        END IF;

        INSERT INTO core.staff_payroll_history
            (tenant_id, school_id, payroll_id, staff_id, pay_month, pay_year, action,
             net_pay, note, action_by)
        VALUES (p_tenant_id, p_school_id, v_pid, a.staff_id, a.pay_month, a.pay_year, 'ADJUSTMENT_VOIDED',
                (SELECT net_pay FROM core.staff_payroll WHERE payroll_id = v_pid),
                format('#%s %s %s voided: %s', a.adjustment_id, a.kind, a.amount, v_reason), p_action_user_id);

        OPEN p_result FOR
        SELECT TRUE AS success, a.adjustment_id AS adjustment_id, 'Adjustment voided.' AS message;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation %.', p_operation;
END;
$procedure$;

