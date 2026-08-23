-- ============================================================================
-- Migration: exam timing, optional section targeting, and a publish status.
--
--   1. academic.exam_subjects gains start_time / end_time  (per paper, nullable)
--   2. academic.exam_class_sections (new)  which sections of a class sit the exam
--        NO rows for a (exam, class) = the whole class, which is the default
--   3. academic.exams gains status  Draft | Published
--        Draft is visible only on the Exam Schedule page; the Datesheet and
--        Marks Entry show Published exams only.
--
-- Existing exams are backfilled to 'Published' — they are already in use, so
-- defaulting them to Draft would make live datesheets and marks sheets vanish.
--
-- RUN ORDER:
--   1. this script       — adds the columns and table, drops the stale proc
--   2. exam_schedule.sql — installs the new sp_school_admin_exam_manage
--
-- Safe to re-run. Skip on a fresh database; exam_schedule.sql creates this shape.
-- ============================================================================

-- ── 1. timing, per paper ────────────────────────────────────────────────────
ALTER TABLE academic.exam_subjects
    ADD COLUMN IF NOT EXISTS start_time time,
    ADD COLUMN IF NOT EXISTS end_time   time;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_exam_subjects_time') THEN
        ALTER TABLE academic.exam_subjects
            ADD CONSTRAINT chk_exam_subjects_time
            CHECK (start_time IS NULL OR end_time IS NULL OR end_time > start_time);
    END IF;
END $$;


-- ── 2. optional section targeting ───────────────────────────────────────────
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

COMMENT ON TABLE academic.exam_class_sections IS
'Which sections of a class sit an exam. No rows for a (exam, class) means the whole class — that is the default and the common case.';


-- ── 3. publish status ───────────────────────────────────────────────────────
ALTER TABLE academic.exams
    ADD COLUMN IF NOT EXISTS status       varchar(20),
    ADD COLUMN IF NOT EXISTS published_by integer,
    ADD COLUMN IF NOT EXISTS published_at timestamptz;

-- Anything that already exists is live; keep it visible.
UPDATE academic.exams SET status = 'Published' WHERE status IS NULL;

ALTER TABLE academic.exams ALTER COLUMN status SET DEFAULT 'Draft';
ALTER TABLE academic.exams ALTER COLUMN status SET NOT NULL;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_exams_status') THEN
        ALTER TABLE academic.exams
            ADD CONSTRAINT chk_exams_status CHECK (status IN ('Draft', 'Published'));
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS ix_exams_status
    ON academic.exams (tenant_id, school_id, academic_year_id, status)
    WHERE NOT is_deleted;


-- ── 4. drop the stale proc ──────────────────────────────────────────────────
-- The argument list gains p_status, so CREATE OR REPLACE in exam_schedule.sql
-- would add a second overload instead of replacing this one.
DROP PROCEDURE IF EXISTS academic.sp_school_admin_exam_manage(
    character varying, integer, integer, integer, integer, integer, integer,
    character varying, character varying, date, date, text, refcursor, refcursor);
