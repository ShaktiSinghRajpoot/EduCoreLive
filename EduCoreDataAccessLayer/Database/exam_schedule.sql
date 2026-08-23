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
-- filters to Published too.
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
            d.subject_count
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
                         WHERE academic_year_id = v_year), '') AS academic_year_name;

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
                         WHERE academic_year_id = v_year), '') AS academic_year_name;

    ELSIF p_operation = 'SetStatus' THEN

        IF COALESCE(p_exam_id, 0) = 0 THEN
            RAISE EXCEPTION 'Pick an exam first.';
        END IF;
        IF COALESCE(p_status, '') NOT IN ('Draft', 'Published') THEN
            RAISE EXCEPTION 'Status must be Draft or Published.';
        END IF;

        -- An exam with no datesheet has nothing to publish.
        IF p_status = 'Published'
           AND NOT EXISTS (SELECT 1 FROM academic.exam_subjects
                           WHERE exam_id = p_exam_id) THEN
            RAISE EXCEPTION 'This exam has no subjects yet, so there is nothing to publish.';
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

        -- A class dropped from the exam loses its datesheet and its sections.
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
                      to_char(a.exam_date, 'DD Mon'), c.class_name)
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
                      sa.subject_name, to_char(a.exam_date, 'DD Mon'), c.class_name,
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
