-- ============================================================================
-- Migration: an exam covers MANY classes.
--
-- The first cut of exam_schedule.sql keyed the exam itself to one class
-- (academic.exams.academic_class_id). That was wrong in three visible ways:
--   * "Unit Test 1" for eight classes meant eight exam rows all with that name,
--     so the name and the datesheet had to be retyped per class;
--   * the Marks Entry exam dropdown looked like it listed duplicates, and its
--     Class box had to go read-only because the exam had already decided it;
--   * there was nowhere to answer "what is 1st class sitting, and on which date".
--
-- After this migration the exam is school-wide and the CLASS moves down onto the
-- datesheet (academic.exam_subjects.academic_class_id) and onto the marks rows.
--
-- RUN ORDER:
--   1. this script          — moves the column, swaps the keys, drops the stale proc
--   2. exam_schedule.sql    — installs the new sp_school_admin_exam_manage
--   3. exam_marks.sql       — installs the new sp_school_admin_exam_marks_manage
--
-- Safe to re-run: every step is guarded. Skip it entirely on a fresh database —
-- exam_schedule.sql already creates the new shape.
-- ============================================================================

-- ── 1. exam_subjects: the datesheet becomes per class ───────────────────────
ALTER TABLE academic.exam_subjects
    ADD COLUMN IF NOT EXISTS academic_class_id integer;

DO $$
BEGIN
    -- Backfill from the exam only while the old column is still there.
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='academic' AND table_name='exams'
                 AND column_name='academic_class_id') THEN
        UPDATE academic.exam_subjects es
           SET academic_class_id = e.academic_class_id
          FROM academic.exams e
         WHERE e.exam_id = es.exam_id
           AND es.academic_class_id IS NULL;
    END IF;
END $$;

-- A datesheet row with no class cannot be repaired automatically; refuse rather
-- than silently attach it to the wrong class.
DO $$
DECLARE v_orphans integer;
BEGIN
    SELECT COUNT(*) INTO v_orphans
    FROM academic.exam_subjects WHERE academic_class_id IS NULL;

    IF v_orphans > 0 THEN
        RAISE EXCEPTION
            '% exam_subjects rows have no class and cannot be migrated. Inspect them first.', v_orphans;
    END IF;
END $$;

ALTER TABLE academic.exam_subjects ALTER COLUMN academic_class_id SET NOT NULL;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_exam_subjects_class') THEN
        ALTER TABLE academic.exam_subjects
            ADD CONSTRAINT fk_exam_subjects_class FOREIGN KEY (academic_class_id)
            REFERENCES academic.academic_classes (academic_class_id);
    END IF;
END $$;

-- (exam, subject) -> (exam, class, subject)
ALTER TABLE academic.exam_subjects DROP CONSTRAINT IF EXISTS uq_exam_subjects;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'uq_exam_subjects') THEN
        ALTER TABLE academic.exam_subjects
            ADD CONSTRAINT uq_exam_subjects UNIQUE (exam_id, academic_class_id, subject_id);
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS ix_exam_subjects_class
    ON academic.exam_subjects (tenant_id, school_id, academic_class_id, exam_date);


-- ── 2. exam_marks: carry the class ──────────────────────────────────────────
ALTER TABLE academic.exam_marks
    ADD COLUMN IF NOT EXISTS academic_class_id integer;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='academic' AND table_name='exams'
                 AND column_name='academic_class_id') THEN
        UPDATE academic.exam_marks m
           SET academic_class_id = e.academic_class_id
          FROM academic.exams e
         WHERE e.exam_id = m.exam_id
           AND m.academic_class_id IS NULL;
    END IF;

    -- Fall back to the student's own enrolment for anything still unset.
    UPDATE academic.exam_marks m
       SET academic_class_id = en.academic_class_id
      FROM core.student_enrolment en
     WHERE en.enrolment_id = m.enrolment_id
       AND m.academic_class_id IS NULL
       AND en.academic_class_id IS NOT NULL;
END $$;

DO $$
DECLARE v_orphans integer;
BEGIN
    SELECT COUNT(*) INTO v_orphans
    FROM academic.exam_marks WHERE academic_class_id IS NULL;

    IF v_orphans > 0 THEN
        RAISE EXCEPTION
            '% exam_marks rows have no class and cannot be migrated. Inspect them first.', v_orphans;
    END IF;
END $$;

ALTER TABLE academic.exam_marks ALTER COLUMN academic_class_id SET NOT NULL;

DROP INDEX IF EXISTS academic.ix_exam_marks_sheet;
CREATE INDEX IF NOT EXISTS ix_exam_marks_sheet
    ON academic.exam_marks (exam_id, academic_class_id, subject_id, section);


-- ── 3. exam_mark_sheets: the class is part of the sheet key ─────────────────
-- Without it, section 'A' of 1st and section 'A' of 2nd would share one lock.
ALTER TABLE academic.exam_mark_sheets
    ADD COLUMN IF NOT EXISTS academic_class_id integer;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='academic' AND table_name='exams'
                 AND column_name='academic_class_id') THEN
        UPDATE academic.exam_mark_sheets sh
           SET academic_class_id = e.academic_class_id
          FROM academic.exams e
         WHERE e.exam_id = sh.exam_id
           AND sh.academic_class_id IS NULL;
    END IF;
END $$;

DO $$
DECLARE v_orphans integer;
BEGIN
    SELECT COUNT(*) INTO v_orphans
    FROM academic.exam_mark_sheets WHERE academic_class_id IS NULL;

    IF v_orphans > 0 THEN
        RAISE EXCEPTION
            '% exam_mark_sheets rows have no class and cannot be migrated. Inspect them first.', v_orphans;
    END IF;
END $$;

ALTER TABLE academic.exam_mark_sheets ALTER COLUMN academic_class_id SET NOT NULL;

ALTER TABLE academic.exam_mark_sheets DROP CONSTRAINT IF EXISTS uq_exam_mark_sheets;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'uq_exam_mark_sheets') THEN
        ALTER TABLE academic.exam_mark_sheets
            ADD CONSTRAINT uq_exam_mark_sheets
            UNIQUE (exam_id, academic_class_id, subject_id, section);
    END IF;
END $$;


-- ── 4. exams: the class column goes away ────────────────────────────────────
-- The duplicate-name guard loses the class, so one "Half Yearly" per year. Two
-- exams that differed only by class now collide: report them by name first,
-- because the CREATE UNIQUE INDEX below would otherwise fail with a bare
-- "could not create unique index" and no hint about which rows to merge.
DO $$
DECLARE v_dupes text;
BEGIN
    SELECT string_agg(DISTINCT exam_name, ', ') INTO v_dupes
    FROM (
        SELECT exam_name
        FROM academic.exams
        WHERE NOT is_deleted
        GROUP BY tenant_id, school_id, academic_year_id, lower(exam_name), exam_name
        HAVING COUNT(*) > 1
    ) q;

    IF v_dupes IS NOT NULL THEN
        RAISE EXCEPTION
            'These exam names now repeat within one year and must be merged by hand first: %', v_dupes;
    END IF;
END $$;

DROP INDEX IF EXISTS academic.uq_exams_name;
CREATE UNIQUE INDEX IF NOT EXISTS uq_exams_name
    ON academic.exams (tenant_id, school_id, academic_year_id, lower(exam_name))
    WHERE NOT is_deleted;

ALTER TABLE academic.exams DROP CONSTRAINT IF EXISTS fk_exams_class;
ALTER TABLE academic.exams DROP COLUMN IF EXISTS academic_class_id;


-- ── 5. drop the stale marks proc ────────────────────────────────────────────
-- Its argument list gained p_academic_class_id, so CREATE OR REPLACE in
-- exam_marks.sql would add a second overload instead of replacing this one.
DROP PROCEDURE IF EXISTS academic.sp_school_admin_exam_marks_manage(
    character varying, integer, integer, integer, integer, integer,
    character varying, text, boolean, refcursor, refcursor);
