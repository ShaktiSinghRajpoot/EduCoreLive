-- ============================================================================
-- Classes & Sections: stop duplicate class / section names at the database.
--
-- Names are the join key everywhere downstream (core.student_enrolment joins on
-- class_name + section, as do attendance and fees), so two sections called "A"
-- in one class make those joins ambiguous. Until now nothing but the page's
-- JavaScript prevented it.
--
-- Matching is case-insensitive, and only live rows count: the save procedure
-- soft-deletes the whole structure and re-inserts it in one transaction, so the
-- partial predicate keeps the old rows out of the way during that rebuild.
--
-- RUN THE CHECK BELOW FIRST. Creating the index fails if duplicates already
-- exist, and each one has to be resolved by hand (renaming a section moves the
-- students enrolled under the old name, so this is not a blind UPDATE).
--
--   SELECT ac.tenant_id, ac.school_id, ac.academic_year_id, ac.class_name,
--          lower(acs.section_name) AS section, count(*)
--   FROM   academic.academic_class_sections acs
--   JOIN   academic.academic_classes ac
--          ON ac.academic_class_id = acs.academic_class_id
--   WHERE  COALESCE(acs.is_deleted, FALSE) = FALSE
--     AND  COALESCE(ac.is_deleted, FALSE) = FALSE
--   GROUP  BY 1,2,3,4,5 HAVING count(*) > 1;
--
--   SELECT tenant_id, school_id, academic_year_id, lower(class_name), count(*)
--   FROM   academic.academic_classes
--   WHERE  COALESCE(is_deleted, FALSE) = FALSE
--   GROUP  BY 1,2,3,4 HAVING count(*) > 1;
-- ============================================================================

CREATE UNIQUE INDEX IF NOT EXISTS ux_academic_classes_name
    ON academic.academic_classes (tenant_id, school_id, academic_year_id, lower(class_name))
    WHERE COALESCE(is_deleted, FALSE) = FALSE;

CREATE UNIQUE INDEX IF NOT EXISTS ux_academic_class_sections_name
    ON academic.academic_class_sections (academic_class_id, lower(section_name))
    WHERE COALESCE(is_deleted, FALSE) = FALSE;
