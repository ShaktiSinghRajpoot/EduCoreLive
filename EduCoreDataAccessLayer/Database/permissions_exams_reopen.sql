-- ============================================================================
-- Two new permission keys (2026-10-11).
--
--   exams.marks   Examinations — Enter marks
--                 Saving and finalising marks on the Marks Entry page. Until now
--                 that needed exams.manage, which also lets a teacher create,
--                 delete and publish exams. exams.manage still includes marks.
--
--   fees.reopen   Fees & Collection — Re-open a closed day
--                 Was part of fees.manage. It is NOT copied to any role: the point
--                 is that only the school admin (who bypasses permissions) or a
--                 role the school ticks on purpose can re-open a closed day.
--
-- Data changes:
--   1. every role that has exams.manage today also gets exams.marks, so nobody
--      loses mark entry;
--   2. built-in TEACHER roles lose the exams.manage grant that
--      builtin_role_defaults.sql gave them (created_by = 0 and never edited on
--      the Roles page since). They keep mark entry through step 1.
--
-- config.fn_apply_builtin_role_defaults (builtin_role_defaults.sql) now gives
-- TEACHER exams.marks instead of exams.manage -- run that script after this one.
--
-- Target DB: PostgreSQL. Safe to re-run.
-- ============================================================================

INSERT INTO config.permissions (permission_key, module_group, display_name, sort_order)
VALUES
    ('exams.marks', 'Academic', 'Examinations — Enter marks',               63),
    ('fees.reopen', 'Finance',  'Fees & Collection — Re-open a closed day', 77)
ON CONFLICT (permission_key) DO NOTHING;

-- 1. Copy every live exams.manage grant to exams.marks (once).
INSERT INTO config.role_permissions (tenant_id, school_id, role_id, permission_id, is_allowed, created_by, created_at)
SELECT rp.tenant_id, rp.school_id, rp.role_id, np.permission_id, rp.is_allowed, rp.created_by, CURRENT_TIMESTAMP
FROM config.role_permissions rp
JOIN config.permissions mp ON mp.permission_id = rp.permission_id AND mp.permission_key = 'exams.manage'
JOIN config.permissions np ON np.permission_key = 'exams.marks'
WHERE COALESCE(rp.is_deleted, FALSE) = FALSE
  AND NOT EXISTS (
        SELECT 1 FROM config.role_permissions x
        WHERE x.tenant_id IS NOT DISTINCT FROM rp.tenant_id
          AND x.school_id IS NOT DISTINCT FROM rp.school_id
          AND x.role_id = rp.role_id
          AND x.permission_id = np.permission_id
          AND COALESCE(x.is_deleted, FALSE) = FALSE);

-- 2. Remove the default exams.manage from built-in TEACHER roles. Only rows the
--    defaults wrote and nobody changed since: a school that re-ticks exams.manage
--    on the Roles page revives the row with updated_by = that user, so a re-run
--    leaves it alone.
UPDATE config.role_permissions rp
SET is_deleted = TRUE, is_allowed = FALSE,
    updated_by = 0, updated_at = now(), deleted_by = 0, deleted_at = now()
FROM config.roles ro, config.permissions p
WHERE ro.role_id = rp.role_id
  AND ro.tenant_id = rp.tenant_id
  AND ro.role_code = 'TEACHER'
  AND p.permission_id = rp.permission_id
  AND p.permission_key = 'exams.manage'
  AND rp.is_deleted = FALSE
  AND rp.created_by = 0
  AND COALESCE(rp.updated_by, 0) = 0;
