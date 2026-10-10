-- !! SUPERSEDED by deploy_2026_10_10b.sql. Already applied on Railway; do NOT re-run it
-- !! after bundle B -- it would put back older exam, calendar and transport procs.
-- ============================================================================
-- Hotfix 2026-10-10 (three procs). Two still called to_char() on columns that
-- dates_as_text.sql turned into varchar (exam_subjects.exam_date,
-- school_calendar.calendar_date). Every exam save failed with
-- "function to_char(character varying, unknown) does not exist", and the
-- School Calendar page could not load. Both now cast to date first.
--
-- The same fix is in exam_schedule.sql and school_calendar.sql; this file holds
-- only the two procs so it can run on its own, without the table DDL in those
-- scripts. Target DB: PostgreSQL. Safe to re-run.
-- ============================================================================

CREATE OR REPLACE PROCEDURE academic.sp_school_admin_exam_manage(IN p_operation character varying, IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_academic_year_id integer DEFAULT NULL::integer, IN p_academic_class_id integer DEFAULT NULL::integer, IN p_exam_id integer DEFAULT NULL::integer, IN p_exam_name character varying DEFAULT NULL::character varying, IN p_exam_type character varying DEFAULT NULL::character varying, IN p_start_date date DEFAULT NULL::date, IN p_end_date date DEFAULT NULL::date, IN p_status character varying DEFAULT NULL::character varying, IN p_items text DEFAULT NULL::text, INOUT p_result refcursor DEFAULT 'exam_cursor'::refcursor, INOUT p_result2 refcursor DEFAULT 'exam_cursor2'::refcursor)
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

CREATE OR REPLACE PROCEDURE academic.sp_school_admin_calendar_manage(IN p_operation character varying, IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_calendar_id integer DEFAULT NULL::integer, IN p_date date DEFAULT NULL::date, IN p_to_date date DEFAULT NULL::date, IN p_day_type character varying DEFAULT NULL::character varying, IN p_title character varying DEFAULT NULL::character varying, IN p_half_day_end time without time zone DEFAULT NULL::time without time zone, IN p_weekly_off character varying DEFAULT NULL::character varying, INOUT p_result refcursor DEFAULT 'calendar_cursor'::refcursor, INOUT p_result2 refcursor DEFAULT 'calendar_cursor2'::refcursor)
 LANGUAGE plpgsql
AS $procedure$

DECLARE

    v_type       text;

    v_title      text;

    v_offs       smallint[];

    v_dow        smallint;

    v_entry      academic.school_calendar%ROWTYPE;

    v_day_type   text;

    v_day_title  text;

    v_is_working boolean;

    v_half_end   time;

BEGIN

    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN

        RAISE EXCEPTION 'Invalid school admin scope.';

    END IF;



    -- ---------------------------------------------------------------- read --

    IF p_operation = 'GetCalendar' THEN



        OPEN p_result FOR

        SELECT

            calendar_id,

            to_char(calendar_date::date, 'YYYY-MM-DD')     AS calendar_date,

            day_type,

            title,

            to_char(half_day_end, 'HH24:MI')         AS half_day_end

        FROM academic.school_calendar

        WHERE tenant_id = p_tenant_id

          AND school_id = p_school_id

          AND calendar_date::date >= COALESCE(p_date,    date_trunc('year', CURRENT_DATE)::date)

          AND calendar_date::date <= COALESCE(p_to_date, (date_trunc('year', CURRENT_DATE) + interval '1 year - 1 day')::date)

        ORDER BY calendar_date;



        OPEN p_result2 FOR

        SELECT COALESCE(

            (SELECT array_to_string(weekly_off_days, ',')

             FROM academic.school_calendar_settings

             WHERE tenant_id = p_tenant_id AND school_id = p_school_id),

            '0') AS weekly_off_days;



    ELSIF p_operation = 'GetDayStatus' THEN



        -- Resolve one date the way the bell should see it.

        v_dow := EXTRACT(DOW FROM COALESCE(p_date, CURRENT_DATE))::smallint;   -- 0 = Sunday



        SELECT COALESCE(weekly_off_days, '{0}') INTO v_offs

        FROM academic.school_calendar_settings

        WHERE tenant_id = p_tenant_id AND school_id = p_school_id;

        IF v_offs IS NULL THEN

            v_offs := '{0}';                       -- unconfigured school: Sunday off

        END IF;



        SELECT * INTO v_entry

        FROM academic.school_calendar

        WHERE tenant_id = p_tenant_id

          AND school_id = p_school_id

          AND calendar_date::date = COALESCE(p_date, CURRENT_DATE);



        IF FOUND THEN

            -- A dated entry overrides the weekly pattern in both directions.

            v_day_type  := v_entry.day_type;

            v_day_title := v_entry.title;

            v_half_end  := v_entry.half_day_end;

            v_is_working := v_entry.day_type <> 'holiday';

            IF v_entry.day_type = 'working' THEN

                v_day_type := 'working';

            END IF;

        ELSIF v_dow = ANY (v_offs) THEN

            v_day_type   := 'weekly_off';

            v_day_title  := trim(to_char(COALESCE(p_date, CURRENT_DATE), 'Day'));

            v_is_working := FALSE;

        ELSE

            v_day_type   := 'working';

            v_day_title  := '';

            v_is_working := TRUE;

        END IF;



        OPEN p_result FOR

        SELECT

            to_char(COALESCE(p_date, CURRENT_DATE), 'YYYY-MM-DD') AS calendar_date,

            v_dow                          AS day_of_week,

            v_day_type                     AS day_type,

            COALESCE(v_day_title, '')      AS title,

            to_char(v_half_end, 'HH24:MI') AS half_day_end,

            v_is_working                   AS is_working;



        OPEN p_result2 FOR SELECT array_to_string(v_offs, ',') AS weekly_off_days;



    -- --------------------------------------------------------------- write --

    ELSIF p_operation = 'SaveEntry' THEN



        IF p_date IS NULL THEN

            RAISE EXCEPTION 'Pick a date first.';

        END IF;



        v_type  := lower(trim(COALESCE(p_day_type, 'holiday')));

        IF v_type NOT IN ('holiday', 'half_day', 'working') THEN

            RAISE EXCEPTION 'Unknown day type "%".', v_type;

        END IF;



        v_title := trim(COALESCE(p_title, ''));

        IF v_title = '' THEN

            v_title := CASE v_type

                         WHEN 'holiday'  THEN 'Holiday'

                         WHEN 'half_day' THEN 'Half Day'

                         ELSE 'Working Day'

                       END;

        END IF;



        IF v_type = 'half_day' AND p_half_day_end IS NULL THEN

            RAISE EXCEPTION 'A half day needs a closing time.';

        END IF;



        INSERT INTO academic.school_calendar

            (tenant_id, school_id, calendar_date, day_type, title, half_day_end, created_by, created_at)

        VALUES

            (p_tenant_id, p_school_id, p_date, v_type, v_title,

             CASE WHEN v_type = 'half_day' THEN p_half_day_end ELSE NULL END,

             p_action_user_id, now())

        ON CONFLICT (tenant_id, school_id, calendar_date) DO UPDATE

            SET day_type     = EXCLUDED.day_type,

                title        = EXCLUDED.title,

                half_day_end = EXCLUDED.half_day_end,

                updated_by   = p_action_user_id,

                updated_at   = now();



        OPEN p_result FOR SELECT TRUE AS success, 'Calendar updated.' AS message;

        OPEN p_result2 FOR SELECT 1 WHERE FALSE;



    ELSIF p_operation = 'DeleteEntry' THEN



        DELETE FROM academic.school_calendar

        WHERE tenant_id = p_tenant_id

          AND school_id = p_school_id

          AND (   (p_calendar_id IS NOT NULL AND calendar_id   = p_calendar_id)

               OR (p_calendar_id IS NULL     AND calendar_date::date = p_date));



        OPEN p_result FOR SELECT TRUE AS success, 'Entry removed.' AS message;

        OPEN p_result2 FOR SELECT 1 WHERE FALSE;



    ELSIF p_operation = 'SaveWeeklyOff' THEN



        -- csv of 0..6; empty string is allowed (a school that never closes weekly).

        SELECT COALESCE(array_agg(d::smallint ORDER BY d::smallint), '{}')

          INTO v_offs

        FROM (

            SELECT DISTINCT trim(x) AS d

            FROM regexp_split_to_table(COALESCE(p_weekly_off, ''), ',') x

            WHERE trim(x) ~ '^[0-6]$'

        ) s;



        INSERT INTO academic.school_calendar_settings

            (tenant_id, school_id, weekly_off_days, updated_by, updated_at)

        VALUES

            (p_tenant_id, p_school_id, v_offs, p_action_user_id, now())

        ON CONFLICT (tenant_id, school_id) DO UPDATE

            SET weekly_off_days = EXCLUDED.weekly_off_days,

                updated_by      = p_action_user_id,

                updated_at      = now();



        OPEN p_result FOR SELECT TRUE AS success, 'Weekly offs saved.' AS message;

        OPEN p_result2 FOR SELECT 1 WHERE FALSE;



    ELSE

        RAISE EXCEPTION 'Invalid operation %', p_operation;

    END IF;

END;

$procedure$;

-- ---------------------------------------------------------------------------
-- core.sp_transport_assign_manage: GetForStudent used alias "r" for routes while
-- "r" is also a record variable of the proc, so every call failed ("record r is
-- not assigned yet") and the Assign Transport page could not show or remove a
-- student's bus. Alias renamed to "rt" (same change in transport_module.sql).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE core.sp_transport_assign_manage(IN p_operation character varying, IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_student_id integer, IN p_route_id integer DEFAULT NULL::integer, IN p_stop_id integer DEFAULT NULL::integer, IN p_academic_year character varying DEFAULT NULL::character varying, IN p_start_date date DEFAULT NULL::date, IN p_months integer DEFAULT 12, INOUT p_result refcursor DEFAULT 'result_cursor'::refcursor)
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

        SELECT s.monthly_fare, s.stop_name, rt.route_name INTO v_fare, v_stop_name, v_route_name
        FROM core.transport_stops s
        JOIN core.transport_routes rt ON rt.route_id = s.route_id
        WHERE s.stop_id = p_stop_id AND s.route_id = p_route_id
          AND s.tenant_id = p_tenant_id AND s.school_id = p_school_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Selected stop not found.';
        END IF;

        v_start := COALESCE(p_start_date, CURRENT_DATE);
        v_year  := COALESCE(NULLIF(TRIM(p_academic_year), ''), v_student_year);

        -- Bill to the end of the SESSION the assignment is for, read from its
        -- real end date. The controllers used to send a month count worked out
        -- from the session NAME on an April-March assumption, and this proc
        -- trusted it, so a 12-month count from October ran into the next session.
        SELECT end_date INTO v_sess_end
        FROM academic.academic_years
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND academic_year_name = v_year AND COALESCE(is_deleted, FALSE) = FALSE
        LIMIT 1;

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
$procedure$

;
