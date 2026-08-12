-- ============================================================================
-- One-off data repair — reverse the 2026-08-11 promotion runs.
--
-- Those runs moved 14 students into session 2028-2029, which has no classes and
-- no sections defined, because sp_student_promote only checked that the target
-- session EXISTED, not that it had any structure. Two students also landed in
-- "2nd-C", a section that class 2nd has never had.
--
-- Every affected row is a clean 1:1 'Promote' with the student still active, so
-- the history table is a complete reverse map. The guards in the WHERE clause
-- mean this is a no-op for anything that has since been moved by hand.
--
-- Run once, then apply the hardened student_promotion.sql.
-- ============================================================================

BEGIN;

UPDATE core.students s
SET    academic_year = h.from_year,
       class_name    = h.from_class,
       section       = h.from_section,
       updated_at    = now()
FROM   core.student_promotion_history h
WHERE  s.student_id    = h.student_id
  AND  h.outcome       = 'Promote'
  AND  s.academic_year = h.to_year      -- still where the promotion put them
  AND  s.class_name    = h.to_class
  AND  s.is_active;

DELETE FROM core.student_promotion_history
WHERE outcome = 'Promote';

COMMIT;
