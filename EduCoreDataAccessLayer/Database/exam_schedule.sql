-- ============================================================================
-- Exam Schedule — the school's exams and the per-class datesheet behind each one.
--
--   academic.exams                            one row per exam, per academic year
--   academic.exam_subjects                    the datesheet: per CLASS, per subject
--   academic.sp_school_admin_exam_manage      GetExams | GetExam | SaveExam
--                                             | DeleteExam | GetDatesheet
--
-- An exam is SCHOOL-WIDE: "Unit Test 1" exists once per academic year. The
-- classes that sit it, and what each class sits on which date, live in
-- exam_subjects — so one exam covers many classes and each class can have a
-- different subject list, different dates and different marks.
--
-- (An earlier version keyed the exam itself to one class. That forced the same
-- name to be retyped per class, made the Marks Entry exam dropdown look like it
-- listed duplicates, and left nowhere to answer "what is 1st class sitting, and
-- when". See exam_multiclass_migration.sql for the upgrade path.)
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
    -- Lookup CODE from config.lookup_value category 'ExamType' (optional),
    -- stored the same way payment mode is.
    exam_type         varchar(80),
    start_date        date NOT NULL,
    end_date          date NOT NULL,
    is_deleted        boolean NOT NULL DEFAULT FALSE,
    created_by        integer,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_by        integer,
    updated_at        timestamptz,
    deleted_by        integer,
    deleted_at        timestamptz,

    CONSTRAINT chk_exams_scope CHECK (tenant_id > 1 AND school_id > 0),
    CONSTRAINT chk_exams_dates CHECK (end_date >= start_date)
);

-- One "Half Yearly" per academic year, case-insensitively. Soft-deleted rows are
-- excluded so a name can be reused after a delete.
CREATE UNIQUE INDEX IF NOT EXISTS uq_exams_name
    ON academic.exams (tenant_id, school_id, academic_year_id, lower(exam_name))
    WHERE NOT is_deleted;

CREATE INDEX IF NOT EXISTS ix_exams_year
    ON academic.exams (tenant_id, school_id, academic_year_id)
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
    max_marks         numeric(6,2) NOT NULL DEFAULT 100,
    pass_marks        numeric(6,2) NOT NULL DEFAULT 35,
    display_order     integer NOT NULL DEFAULT 0,

    CONSTRAINT chk_exam_subjects_marks
        CHECK (max_marks > 0 AND pass_marks >= 0 AND pass_marks <= max_marks),
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


-- ── Two more platform-default exam types ────────────────────────────────────
-- reference_data_lookup.sql seeded unit1/mid/final/annual; the exam page also
-- offered these two. Platform defaults only apply to schools with no override.
INSERT INTO config.lookup_value (tenant_id, school_id, category, code, label, display_order, is_system) VALUES
    (0,0,'ExamType','half','Half Yearly',5,FALSE),
    (0,0,'ExamType','preboard','Pre Board',6,FALSE)
ON CONFLICT ON CONSTRAINT uq_lookup_value DO NOTHING;


-- ── Resolve an exam type code to its label ──────────────────────────────────
-- The school's own row wins over the platform default; an unknown code shows as
-- itself. A function, not a join, so a school override cannot duplicate a row.
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
    v_max      numeric;
    v_pass     numeric;
    v_ord      integer;
    v_classes  integer[] := '{}';
    v_keep     integer[];
    v_total    integer   := 0;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    -- Everything is scoped to one academic year; default to the current one.
    v_year := COALESCE(p_academic_year_id,
        (SELECT academic_year_id
         FROM academic.academic_years
         WHERE tenant_id = p_tenant_id AND school_id = p_school_id
           AND is_current AND NOT is_deleted
         ORDER BY academic_year_id DESC
         LIMIT 1));

    IF p_operation = 'GetExams' THEN

        OPEN p_result FOR
        SELECT
            e.exam_id,
            e.exam_name,
            COALESCE(e.exam_type, '') AS exam_type,
            academic.fn_exam_type_label(p_tenant_id, p_school_id, e.exam_type) AS type_label,
            e.start_date,
            e.end_date,
            d.class_count,
            d.subject_count,
            COALESCE(d.class_names, '') AS class_names
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
                         WHERE academic_year_id = v_year), '') AS academic_year_name;

    ELSIF p_operation = 'GetExam' THEN

        OPEN p_result FOR
        SELECT
            e.exam_id,
            e.exam_name,
            COALESCE(e.exam_type, '') AS exam_type,
            e.start_date,
            e.end_date
        FROM academic.exams e
        WHERE e.exam_id   = p_exam_id
          AND e.tenant_id = p_tenant_id
          AND e.school_id = p_school_id
          AND NOT e.is_deleted;

        -- Every class's datesheet, so the edit form can load the whole exam.
        OPEN p_result2 FOR
        SELECT es.academic_class_id,
               c.class_name,
               es.subject_id,
               s.subject_name,
               es.exam_date,
               es.max_marks,
               es.pass_marks
        FROM academic.exam_subjects es
        JOIN academic.school_subjects  s ON s.subject_id        = es.subject_id
        JOIN academic.academic_classes c ON c.academic_class_id = es.academic_class_id
        WHERE es.exam_id   = p_exam_id
          AND es.tenant_id = p_tenant_id
          AND es.school_id = p_school_id
        ORDER BY c.display_order, c.class_name, es.display_order, s.subject_name;

    ELSIF p_operation = 'GetDatesheet' THEN

        -- The Datesheet page: what each class sits, in date order. p_academic_class_id
        -- NULL/0 means every class.
        OPEN p_result FOR
        SELECT es.exam_date,
               es.academic_class_id,
               c.class_name,
               s.subject_name,
               es.max_marks,
               es.pass_marks,
               e.exam_id,
               e.exam_name,
               academic.fn_exam_type_label(p_tenant_id, p_school_id, e.exam_type) AS type_label
        FROM academic.exam_subjects es
        JOIN academic.exams           e ON e.exam_id           = es.exam_id
        JOIN academic.school_subjects s ON s.subject_id        = es.subject_id
        JOIN academic.academic_classes c ON c.academic_class_id = es.academic_class_id
        WHERE es.tenant_id = p_tenant_id
          AND es.school_id = p_school_id
          AND e.academic_year_id = v_year
          AND NOT e.is_deleted
          AND (COALESCE(p_academic_class_id, 0) = 0
               OR es.academic_class_id = p_academic_class_id)
          AND (COALESCE(p_exam_id, 0) = 0 OR e.exam_id = p_exam_id)
        ORDER BY es.exam_date NULLS LAST, c.display_order, c.class_name, es.display_order;

        OPEN p_result2 FOR
        SELECT v_year AS academic_year_id,
               COALESCE((SELECT academic_year_name FROM academic.academic_years
                         WHERE academic_year_id = v_year), '') AS academic_year_name;

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

        -- p_items: [{ "classId": 1, "subjects": [{subjectId, examDate, maxMarks, passMarks}, ...] }, ...]
        v_items := COALESCE(NULLIF(p_items, ''), '[]')::jsonb;

        IF COALESCE(p_exam_id, 0) = 0 THEN
            BEGIN
                INSERT INTO academic.exams
                    (tenant_id, school_id, academic_year_id,
                     exam_name, exam_type, start_date, end_date, created_by, created_at)
                VALUES
                    (p_tenant_id, p_school_id, v_year,
                     v_name, NULLIF(trim(COALESCE(p_exam_type, '')), ''),
                     p_start_date, p_end_date, p_action_user_id, now())
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
            BEGIN
                UPDATE academic.exams
                   SET exam_name  = v_name,
                       exam_type  = NULLIF(trim(COALESCE(p_exam_type, '')), ''),
                       start_date = p_start_date,
                       end_date   = p_end_date,
                       updated_by = p_action_user_id,
                       updated_at = now()
                 WHERE exam_id = v_exam_id;
            EXCEPTION WHEN unique_violation THEN
                RAISE EXCEPTION 'An exam called "%" already exists this year.', v_name;
            END;
        END IF;

        -- One class at a time; each class's datesheet is replaced wholesale.
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
                v_max  := COALESCE(NULLIF(v_subject->>'maxMarks',  '')::numeric, 100);
                v_pass := COALESCE(NULLIF(v_subject->>'passMarks', '')::numeric, 35);

                SELECT subject_name INTO v_sname
                FROM academic.school_subjects
                WHERE subject_id = v_sid AND tenant_id = p_tenant_id AND school_id = p_school_id;

                IF v_sname IS NULL THEN
                    RAISE EXCEPTION 'That subject does not belong to this school.';
                END IF;

                -- A class's datesheet may only list subjects it actually studies.
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

                v_ord := v_ord + 1;

                INSERT INTO academic.exam_subjects
                    (tenant_id, school_id, exam_id, academic_class_id, subject_id,
                     exam_date, max_marks, pass_marks, display_order)
                VALUES
                    (p_tenant_id, p_school_id, v_exam_id, v_cls, v_sid,
                     v_date, v_max, v_pass, v_ord)
                ON CONFLICT ON CONSTRAINT uq_exam_subjects
                DO UPDATE SET exam_date     = EXCLUDED.exam_date,
                              max_marks     = EXCLUDED.max_marks,
                              pass_marks    = EXCLUDED.pass_marks,
                              display_order = EXCLUDED.display_order;

                v_keep := v_keep || v_sid;
            END LOOP;

            IF v_ord = 0 THEN
                RAISE EXCEPTION '% has no subjects on its datesheet.',
                    (SELECT class_name FROM academic.academic_classes WHERE academic_class_id = v_cls);
            END IF;

            -- Replace-all inside this class.
            DELETE FROM academic.exam_subjects
            WHERE exam_id = v_exam_id
              AND academic_class_id = v_cls
              AND NOT (subject_id = ANY (v_keep));

            v_classes := v_classes || v_cls;
            v_total   := v_total + v_ord;
        END LOOP;

        IF array_length(v_classes, 1) IS NULL THEN
            RAISE EXCEPTION 'Pick at least one class for this exam.';
        END IF;

        -- A class dropped from the exam loses its datesheet. Marks for it go too,
        -- via exam_marks' FK on (exam, class) — see exam_marks.sql.
        DELETE FROM academic.exam_subjects
        WHERE exam_id = v_exam_id
          AND NOT (academic_class_id = ANY (v_classes));

        OPEN p_result FOR
        SELECT TRUE AS success,
               v_exam_id AS exam_id,
               array_length(v_classes, 1) AS class_count,
               v_total AS subject_count,
               CASE WHEN COALESCE(p_exam_id, 0) = 0 THEN 'Exam created.' ELSE 'Exam updated.' END AS message;

        OPEN p_result2 FOR SELECT 1 WHERE FALSE;

    ELSIF p_operation = 'DeleteExam' THEN

        IF COALESCE(p_exam_id, 0) = 0 THEN
            RAISE EXCEPTION 'Pick an exam to delete.';
        END IF;

        -- Soft delete: marks reference these rows.
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
