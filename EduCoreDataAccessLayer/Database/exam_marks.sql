-- ============================================================================
-- Exam marks — the Marks Entry sheet behind an exam's per-class datesheet.
--
--   academic.exam_marks              one row per student per exam-subject
--   academic.exam_mark_sheets        the finalize/lock state of one sheet
--   academic.fn_exam_sheet_roster    who sits a sheet (ONE definition, two callers)
--   academic.sp_school_admin_exam_marks_manage
--         GetExamClasses | GetClassSetup | GetSheet | SaveMarks | ReopenSheet
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
-- Grades are NOT stored. A grade is derived from marks + the school's grade scale,
-- and no scale is configurable yet, so the page computes it for display only.
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
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    v_section := COALESCE(TRIM(p_section), '');

    -- Every operation works on one exam; resolve its academic year once.
    IF COALESCE(p_exam_id, 0) > 0 THEN
        SELECT academic_year_id INTO v_year_id
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
            sh.finalized_at
        FROM (SELECT 1) x
        LEFT JOIN academic.exam_mark_sheets sh
               ON sh.exam_id           = p_exam_id
              AND sh.academic_class_id = p_academic_class_id
              AND sh.subject_id        = p_subject_id
              AND sh.section           = v_section;

    ELSIF p_operation = 'SaveMarks' THEN

        SELECT es.max_marks, es.pass_marks INTO v_max, v_pass
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

        IF COALESCE(v_final, FALSE) THEN
            RAISE EXCEPTION 'These marks are finalized. Ask a school admin to reopen the sheet.';
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
                          updated_at        = now();

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

    ELSIF p_operation = 'ReopenSheet' THEN

        -- Admin-only; the caller enforces that (the proc cannot see roles).
        IF COALESCE(p_subject_id, 0) <= 0 THEN
            RAISE EXCEPTION 'Pick a subject first.';
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
