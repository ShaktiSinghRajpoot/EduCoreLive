-- ============================================================================
-- Edit history for attendance marks and exam marks.
--
-- A register or a mark sheet is a record the school may have to defend ("who
-- changed my child's absence to present, and when?"). The live rows only keep
-- the LAST editor, so every change is copied here first: old value, new value,
-- who, when.
--
-- Written by AFTER UPDATE triggers, and only when a value actually changes. A
-- re-save that sends the same mark writes nothing (the save procs also skip
-- the UPDATE in that case, so updated_by is not re-stamped).
--
--   core.student_attendance_history   one row per changed attendance mark
--   academic.exam_marks_history       one row per changed exam mark
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

CREATE TABLE IF NOT EXISTS core.student_attendance_history (
    history_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       integer NOT NULL,
    school_id       integer NOT NULL,
    attendance_id   integer NOT NULL,
    student_id      integer NOT NULL,
    attendance_date varchar(10) NOT NULL,
    old_status      varchar(20),
    new_status      varchar(20),
    old_remarks     varchar(200),
    new_remarks     varchar(200),
    changed_by      integer,
    changed_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_student_attendance_history_student
    ON core.student_attendance_history (tenant_id, school_id, student_id, attendance_date);

CREATE OR REPLACE FUNCTION core.fn_student_attendance_history()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    INSERT INTO core.student_attendance_history
        (tenant_id, school_id, attendance_id, student_id, attendance_date,
         old_status, new_status, old_remarks, new_remarks, changed_by, changed_at)
    VALUES
        (NEW.tenant_id, NEW.school_id, NEW.attendance_id, NEW.student_id, NEW.attendance_date,
         OLD.status, NEW.status, OLD.remarks, NEW.remarks, NEW.updated_by, now());
    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_student_attendance_history ON core.student_attendance;
CREATE TRIGGER trg_student_attendance_history
    AFTER UPDATE ON core.student_attendance
    FOR EACH ROW
    WHEN (OLD.status  IS DISTINCT FROM NEW.status
       OR OLD.remarks IS DISTINCT FROM NEW.remarks)
    EXECUTE FUNCTION core.fn_student_attendance_history();


CREATE TABLE IF NOT EXISTS academic.exam_marks_history (
    history_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       integer NOT NULL,
    school_id       integer NOT NULL,
    exam_mark_id    integer NOT NULL,
    exam_id         integer NOT NULL,
    subject_id      integer NOT NULL,
    student_id      integer NOT NULL,
    old_marks       numeric(6,2),
    new_marks       numeric(6,2),
    old_absent      boolean,
    new_absent      boolean,
    changed_by      integer,
    changed_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_exam_marks_history_student
    ON academic.exam_marks_history (tenant_id, school_id, exam_id, student_id);

CREATE OR REPLACE FUNCTION academic.fn_exam_marks_history()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    INSERT INTO academic.exam_marks_history
        (tenant_id, school_id, exam_mark_id, exam_id, subject_id, student_id,
         old_marks, new_marks, old_absent, new_absent, changed_by, changed_at)
    VALUES
        (NEW.tenant_id, NEW.school_id, NEW.exam_mark_id, NEW.exam_id, NEW.subject_id, NEW.student_id,
         OLD.marks_obtained, NEW.marks_obtained, OLD.is_absent, NEW.is_absent, NEW.updated_by, now());
    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_exam_marks_history ON academic.exam_marks;
CREATE TRIGGER trg_exam_marks_history
    AFTER UPDATE ON academic.exam_marks
    FOR EACH ROW
    WHEN (OLD.marks_obtained IS DISTINCT FROM NEW.marks_obtained
       OR OLD.is_absent      IS DISTINCT FROM NEW.is_absent)
    EXECUTE FUNCTION academic.fn_exam_marks_history();
