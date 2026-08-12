-- ============================================================================
-- Student enrolment — one row per student per academic session.
--
-- PHASE 1 of the enrolment migration: build the table, backfill it, and make
-- every write path keep it up to date. NOTHING READS IT YET — that is Phase 2.
-- Doing it in this order means Phase 1 cannot break a single existing page.
--
-- Why it exists
-- -------------
-- core.students holds ONE row per student with class_name / section /
-- academic_year on it, and promotion overwrites those three columns. The moment
-- a student moves up, where they came from is gone: "how many students were in
-- 3rd class in 2027-2028" has no answer, and a promotion can only be undone by
-- replaying core.student_promotion_history backwards.
--
-- Real school ERPs keep the student row as identity only (name, DOB, parents,
-- admission_no) and put the per-session facts — class, section, roll number,
-- status — in an enrolment table. Old rows are never overwritten; a new session
-- adds a new row. That is what makes year-wise reporting and a reversible
-- promotion possible.
--
-- core.students is deliberately left ALONE here. It keeps its class_name /
-- section / academic_year columns and every existing page keeps working off
-- them. This table is written in parallel (dual-write) until Phase 2 moves the
-- reads across.
--
-- Keyed on the year NAME, not the id
-- ----------------------------------
-- students.academic_year is text and that is what the whole app matches on, so
-- the unique key here is (student_id, academic_year). academic_year_id and
-- academic_class_id are resolved as a convenience for joins, and are allowed to
-- be NULL so a student whose session row is missing can still be admitted.
--
--   core.student_enrolment              the table
--   core.fn_student_enrolment_open      open/refresh a session's enrolment
--   core.fn_student_enrolment_close     close it with an outcome
-- ============================================================================

CREATE TABLE IF NOT EXISTS core.student_enrolment (
    enrolment_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id         integer     NOT NULL,
    school_id         integer     NOT NULL,
    student_id        integer     NOT NULL REFERENCES core.students(student_id) ON DELETE CASCADE,

    -- Session. The name is the key; the id is resolved for joins where possible.
    academic_year     varchar(20) NOT NULL,
    academic_year_id  integer,

    -- Position in that session. Names are snapshots, so renaming or removing a
    -- class later cannot rewrite history.
    class_name        varchar(50) NOT NULL,
    academic_class_id integer,
    section           varchar(20),
    roll_no           varchar(20),

    -- Active | Promoted | Retained | PassedOut | Left
    status            varchar(20) NOT NULL DEFAULT 'Active',
    -- TRUE on the row matching the student's present position (students.academic_year).
    is_current        boolean     NOT NULL DEFAULT TRUE,

    created_by        integer     NOT NULL DEFAULT 0,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_by        integer     NOT NULL DEFAULT 0,
    updated_at        timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT uq_student_enrolment_student_year UNIQUE (student_id, academic_year)
);

-- Year-wise reads (Phase 2): "class strength in 2027-2028".
CREATE INDEX IF NOT EXISTS idx_student_enrolment_year
    ON core.student_enrolment (tenant_id, school_id, academic_year, class_name, section);

-- "Where is this student now" / a student's full history.
CREATE INDEX IF NOT EXISTS idx_student_enrolment_student
    ON core.student_enrolment (student_id, is_current);

COMMENT ON TABLE core.student_enrolment IS
    'One row per student per academic session. Written in parallel with core.students (Phase 1); reads move here in Phase 2.';
COMMENT ON COLUMN core.student_enrolment.is_current IS
    'TRUE on the row matching the student''s present position. Exactly one per student.';
COMMENT ON COLUMN core.student_enrolment.status IS
    'Active | Promoted | Retained | PassedOut | Left. Promoted/Retained/PassedOut mean the session finished.';


-- ── open / refresh one session's enrolment ─────────────────────────────────
-- Re-runnable: the unique key makes it an upsert, so a double submit or a
-- re-applied backfill cannot create a second row for the same session.
-- Returns the enrolment_id.
CREATE OR REPLACE FUNCTION core.fn_student_enrolment_open(
    p_tenant_id      integer,
    p_school_id      integer,
    p_student_id     integer,
    p_academic_year  varchar,
    p_class_name     varchar,
    p_section        varchar,
    p_roll_no        varchar,
    p_action_user_id integer)
RETURNS integer
LANGUAGE plpgsql
AS $function$
DECLARE
    v_year     varchar := NULLIF(TRIM(COALESCE(p_academic_year, '')), '');
    v_class    varchar := NULLIF(TRIM(COALESCE(p_class_name, '')), '');
    v_year_id  integer;
    v_class_id integer;
    v_id       integer;
BEGIN
    -- Nothing to record without a session and a class. Callers treat this as a
    -- no-op rather than an error, so a half-filled student cannot block a save.
    IF p_student_id IS NULL OR v_year IS NULL OR v_class IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT academic_year_id INTO v_year_id
    FROM   academic.academic_years
    WHERE  tenant_id = p_tenant_id AND school_id = p_school_id
      AND  academic_year_name = v_year
      AND  COALESCE(is_deleted, FALSE) = FALSE
    LIMIT 1;

    IF v_year_id IS NOT NULL THEN
        SELECT academic_class_id INTO v_class_id
        FROM   academic.academic_classes
        WHERE  tenant_id = p_tenant_id AND school_id = p_school_id
          AND  academic_year_id = v_year_id
          AND  class_name = v_class
          AND  COALESCE(is_deleted, FALSE) = FALSE
        ORDER BY display_order, academic_class_id
        LIMIT 1;
    END IF;

    INSERT INTO core.student_enrolment (
        tenant_id, school_id, student_id,
        academic_year, academic_year_id,
        class_name, academic_class_id, section, roll_no,
        status, is_current, created_by, updated_by)
    VALUES (
        p_tenant_id, p_school_id, p_student_id,
        v_year, v_year_id,
        v_class, v_class_id, NULLIF(TRIM(COALESCE(p_section, '')), ''),
        NULLIF(TRIM(COALESCE(p_roll_no, '')), ''),
        'Active', TRUE, p_action_user_id, p_action_user_id)
    ON CONFLICT ON CONSTRAINT uq_student_enrolment_student_year DO UPDATE
    SET academic_year_id  = EXCLUDED.academic_year_id,
        class_name        = EXCLUDED.class_name,
        academic_class_id = EXCLUDED.academic_class_id,
        section           = EXCLUDED.section,
        -- A roll number already assigned for this session is not wiped by a
        -- caller that does not carry one.
        roll_no           = COALESCE(EXCLUDED.roll_no, core.student_enrolment.roll_no),
        status            = 'Active',
        is_current        = TRUE,
        updated_by        = EXCLUDED.updated_by,
        updated_at        = now()
    RETURNING enrolment_id INTO v_id;

    -- Exactly one current row per student.
    UPDATE core.student_enrolment
    SET    is_current = FALSE,
           updated_at = now()
    WHERE  student_id = p_student_id
      AND  enrolment_id <> v_id
      AND  is_current;

    RETURN v_id;
END;
$function$;


-- ── close one session's enrolment ──────────────────────────────────────────
-- p_status: Promoted | Retained | PassedOut | Left.
-- Leaves is_current alone — the caller decides whether the student has moved on
-- (promotion opens the next row, which clears this one) or simply stopped
-- (an exit leaves this as their latest row).
CREATE OR REPLACE FUNCTION core.fn_student_enrolment_close(
    p_student_id     integer,
    p_academic_year  varchar,
    p_status         varchar,
    p_action_user_id integer)
RETURNS integer
LANGUAGE plpgsql
AS $function$
DECLARE
    v_id integer;
BEGIN
    UPDATE core.student_enrolment
    SET    status     = p_status,
           updated_by = p_action_user_id,
           updated_at = now()
    WHERE  student_id    = p_student_id
      AND  academic_year = TRIM(COALESCE(p_academic_year, ''))
    RETURNING enrolment_id INTO v_id;

    RETURN v_id;
END;
$function$;


-- ── backfill ───────────────────────────────────────────────────────────────
-- Every existing student gets the enrolment row implied by their current
-- student row. Re-runnable (the upsert inside the function handles repeats).
--
-- core.students only remembers where a student is NOW, so the current session
-- comes from there; earlier sessions are rebuilt from student_promotion_history
-- in the second block below. From here on the history is captured as it happens.
DO $backfill$
DECLARE
    s record;
    v_status varchar;
    v_done   integer := 0;
BEGIN
    FOR s IN
        SELECT student_id, tenant_id, school_id, academic_year,
               class_name, section, roll_no, is_active, status
        FROM   core.students
        ORDER BY student_id
    LOOP
        PERFORM core.fn_student_enrolment_open(
            s.tenant_id, s.school_id, s.student_id,
            s.academic_year, s.class_name, s.section, s.roll_no, 0);

        -- A student who has already left keeps that outcome on the row.
        IF NOT COALESCE(s.is_active, TRUE) THEN
            v_status := CASE WHEN TRIM(COALESCE(s.status, '')) = 'Passout'
                             THEN 'PassedOut' ELSE 'Left' END;
            PERFORM core.fn_student_enrolment_close(
                s.student_id, s.academic_year, v_status, 0);
        END IF;

        v_done := v_done + 1;
    END LOOP;

    RAISE NOTICE 'Enrolment backfill: % students processed.', v_done;
END;
$backfill$;


-- Earlier sessions, rebuilt from the promotion audit trail. A promotion that
-- ran before this table existed left its "from" side only in
-- student_promotion_history, so replay those rows as closed enrolments.
--
-- ON CONFLICT DO NOTHING means a session already recorded properly is never
-- overwritten, and is_current is left FALSE — the row from core.students above
-- is the student's present position.
INSERT INTO core.student_enrolment (
    tenant_id, school_id, student_id,
    academic_year, academic_year_id,
    class_name, academic_class_id, section,
    status, is_current, created_by, updated_by, created_at)
SELECT h.tenant_id, h.school_id, h.student_id,
       h.from_year,
       (SELECT ay.academic_year_id FROM academic.academic_years ay
        WHERE ay.tenant_id = h.tenant_id AND ay.school_id = h.school_id
          AND ay.academic_year_name = h.from_year
          AND COALESCE(ay.is_deleted, FALSE) = FALSE LIMIT 1),
       h.from_class,
       (SELECT ac.academic_class_id FROM academic.academic_classes ac
        WHERE ac.tenant_id = h.tenant_id AND ac.school_id = h.school_id
          AND ac.class_name = h.from_class
          AND ac.academic_year_id = (
              SELECT ay2.academic_year_id FROM academic.academic_years ay2
              WHERE ay2.tenant_id = h.tenant_id AND ay2.school_id = h.school_id
                AND ay2.academic_year_name = h.from_year
                AND COALESCE(ay2.is_deleted, FALSE) = FALSE LIMIT 1)
          AND COALESCE(ac.is_deleted, FALSE) = FALSE
        ORDER BY ac.display_order, ac.academic_class_id LIMIT 1),
       h.from_section,
       CASE h.outcome WHEN 'Promote' THEN 'Promoted'
                      WHEN 'Retain'  THEN 'Retained'
                      WHEN 'PassOut' THEN 'PassedOut'
                      ELSE 'Promoted' END,
       FALSE, 0, 0, h.promoted_at
FROM   core.student_promotion_history h
ON CONFLICT ON CONSTRAINT uq_student_enrolment_student_year DO NOTHING;


-- ── a student's session-by-session timeline ────────────────────────────────
-- The reason this table exists: "which class was this student in, and when".
-- Newest session first, which is how the dashboard reads it.
CREATE OR REPLACE PROCEDURE core.sp_student_enrolment_history(
    IN  p_tenant_id      integer,
    IN  p_school_id      integer,
    IN  p_action_user_id integer,
    IN  p_student_id     integer,
    INOUT p_result       refcursor DEFAULT 'student_enrolment_history_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR COALESCE(p_student_id, 0) <= 0 THEN
        OPEN p_result FOR SELECT WHERE FALSE;
        RETURN;
    END IF;

    OPEN p_result FOR
    SELECT e.academic_year,
           e.class_name,
           e.section,
           e.roll_no,
           e.status,
           e.is_current,
           e.created_at
    FROM   core.student_enrolment e
    LEFT JOIN academic.academic_years ay
           ON ay.academic_year_id = e.academic_year_id
    WHERE  e.tenant_id  = p_tenant_id
      AND  e.school_id  = p_school_id
      AND  e.student_id = p_student_id
    -- Sessions that resolved to a real year row sort by its start date; the
    -- rest fall back to the name, which is "2027-2028" style and sorts fine.
    ORDER BY ay.start_date DESC NULLS LAST, e.academic_year DESC;
    RETURN;
END;
$procedure$;
