-- ============================================================================
-- Subject Management — the school's subject master + which subjects each class
-- studies. Replaces the localStorage-only version of the Subject Management page.
--
--   academic.school_subjects                      one row per subject name (school-wide)
--   academic.class_subjects                       class ↔ subject, per academic year
--   academic.sp_school_admin_subject_manage       GetClasses | GetClassSubjects
--                                                 | SaveClassSubjects | GetSubjectMaster
--
-- The page works in subject NAMES, so SaveClassSubjects auto-creates any name it
-- has not seen before in the master (case-insensitive), then replaces the class's
-- mapping wholesale — same replace-all shape as the period structure save.
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

CREATE TABLE IF NOT EXISTS academic.school_subjects (
    subject_id   serial PRIMARY KEY,
    tenant_id    integer NOT NULL,
    school_id    integer NOT NULL,
    subject_name varchar(80) NOT NULL,
    is_active    boolean NOT NULL DEFAULT TRUE,
    created_by   integer,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   integer,
    updated_at   timestamptz,

    CONSTRAINT chk_school_subjects_scope CHECK (tenant_id > 1 AND school_id > 0)
);

-- Case-insensitive uniqueness: "Maths" and "maths" are the same subject.
CREATE UNIQUE INDEX IF NOT EXISTS uq_school_subjects_name
    ON academic.school_subjects (tenant_id, school_id, lower(subject_name));

CREATE TABLE IF NOT EXISTS academic.class_subjects (
    class_subject_id  serial PRIMARY KEY,
    tenant_id         integer NOT NULL,
    school_id         integer NOT NULL,
    academic_year_id  integer NOT NULL,
    academic_class_id integer NOT NULL,
    subject_id        integer NOT NULL,
    display_order     integer NOT NULL DEFAULT 0,
    created_by        integer,
    created_at        timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT fk_class_subjects_class   FOREIGN KEY (academic_class_id)
        REFERENCES academic.academic_classes (academic_class_id),
    CONSTRAINT fk_class_subjects_subject FOREIGN KEY (subject_id)
        REFERENCES academic.school_subjects (subject_id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_class_subjects
    ON academic.class_subjects (tenant_id, school_id, academic_year_id, academic_class_id, subject_id);


CREATE OR REPLACE PROCEDURE academic.sp_school_admin_subject_manage(
    IN    p_operation         character varying,
    IN    p_tenant_id         integer,
    IN    p_school_id         integer,
    IN    p_action_user_id    integer,
    IN    p_academic_year_id  integer   DEFAULT NULL,
    IN    p_academic_class_id integer   DEFAULT NULL,
    IN    p_items             text      DEFAULT NULL,
    INOUT p_result            refcursor DEFAULT 'subject_cursor'::refcursor,
    INOUT p_result2           refcursor DEFAULT 'subject_cursor2'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_year   integer;
    v_items  jsonb;
    v_name   text;
    v_sid    integer;
    v_ord    integer := 0;
    v_keep   integer[] := '{}';
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

    IF p_operation = 'GetClasses' THEN

        -- Left panel: the school's real classes with how many subjects each has.
        OPEN p_result FOR
        SELECT
            c.academic_class_id,
            c.class_name,
            c.stream,
            c.display_order,
            COUNT(cs.class_subject_id)::int AS subject_count
        FROM academic.academic_classes c
        LEFT JOIN academic.class_subjects cs
               ON cs.academic_class_id = c.academic_class_id
              AND cs.academic_year_id  = v_year
        WHERE c.tenant_id = p_tenant_id
          AND c.school_id = p_school_id
          AND c.academic_year_id = v_year
          AND NOT c.is_deleted
          AND c.is_active
        GROUP BY c.academic_class_id, c.class_name, c.stream, c.display_order
        ORDER BY c.display_order, c.class_name;

        OPEN p_result2 FOR
        SELECT v_year AS academic_year_id,
               COALESCE((SELECT academic_year_name FROM academic.academic_years
                         WHERE academic_year_id = v_year), '') AS academic_year_name;

    ELSIF p_operation = 'GetClassSubjects' THEN

        OPEN p_result FOR
        SELECT s.subject_id, s.subject_name
        FROM academic.class_subjects cs
        JOIN academic.school_subjects s ON s.subject_id = cs.subject_id
        WHERE cs.tenant_id = p_tenant_id
          AND cs.school_id = p_school_id
          AND cs.academic_year_id  = v_year
          AND cs.academic_class_id = p_academic_class_id
        ORDER BY cs.display_order, s.subject_name;

        OPEN p_result2 FOR SELECT 1 WHERE FALSE;

    ELSIF p_operation = 'GetSubjectMaster' THEN

        -- Every subject the school uses — the timetable's subject dropdown.
        OPEN p_result FOR
        SELECT subject_id, subject_name
        FROM academic.school_subjects
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND is_active
        ORDER BY subject_name;

        OPEN p_result2 FOR SELECT 1 WHERE FALSE;

    ELSIF p_operation = 'SaveClassSubjects' THEN

        IF p_academic_class_id IS NULL THEN
            RAISE EXCEPTION 'Pick a class first.';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM academic.academic_classes
                       WHERE academic_class_id = p_academic_class_id
                         AND tenant_id = p_tenant_id AND school_id = p_school_id
                         AND NOT is_deleted) THEN
            RAISE EXCEPTION 'That class does not belong to this school.';
        END IF;

        v_items := COALESCE(NULLIF(p_items, ''), '[]')::jsonb;

        -- Walk the names in the order the page sent them: make sure each exists
        -- in the master, then map it to the class at that position.
        FOR v_name IN SELECT trim(value #>> '{}') FROM jsonb_array_elements(v_items)
        LOOP
            CONTINUE WHEN v_name IS NULL OR v_name = '';

            SELECT subject_id INTO v_sid
            FROM academic.school_subjects
            WHERE tenant_id = p_tenant_id AND school_id = p_school_id
              AND lower(subject_name) = lower(v_name);

            IF v_sid IS NULL THEN
                INSERT INTO academic.school_subjects
                    (tenant_id, school_id, subject_name, created_by, created_at)
                VALUES (p_tenant_id, p_school_id, v_name, p_action_user_id, now())
                RETURNING subject_id INTO v_sid;
            END IF;

            v_ord := v_ord + 1;

            INSERT INTO academic.class_subjects
                (tenant_id, school_id, academic_year_id, academic_class_id, subject_id, display_order, created_by, created_at)
            VALUES
                (p_tenant_id, p_school_id, v_year, p_academic_class_id, v_sid, v_ord, p_action_user_id, now())
            ON CONFLICT (tenant_id, school_id, academic_year_id, academic_class_id, subject_id)
            DO UPDATE SET display_order = EXCLUDED.display_order;

            v_keep := v_keep || v_sid;
        END LOOP;

        -- Replace-all: anything the page no longer lists is unmapped. The subject
        -- stays in the master (other classes may still use it).
        DELETE FROM academic.class_subjects
        WHERE tenant_id = p_tenant_id
          AND school_id = p_school_id
          AND academic_year_id  = v_year
          AND academic_class_id = p_academic_class_id
          AND NOT (subject_id = ANY (v_keep));

        OPEN p_result FOR
        SELECT TRUE AS success,
               v_ord AS subject_count,
               'Subjects saved.' AS message;

        OPEN p_result2 FOR SELECT 1 WHERE FALSE;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;
