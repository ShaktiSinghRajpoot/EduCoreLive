-- Demo school (Angel's Paradise School, tenant 32 / school 45): the TEACHER role
-- had lost exams.marks (left switched off by an earlier permission test), so the
-- demo's teachers could not enter marks. Puts back the default grant. Data only;
-- does nothing on a database without that school.
UPDATE config.role_permissions rp
   SET is_allowed = TRUE, is_deleted = FALSE, deleted_by = NULL, deleted_at = NULL,
       updated_by = 1, updated_at = now()
  FROM config.roles r, config.permissions p
 WHERE r.role_id = rp.role_id AND p.permission_id = rp.permission_id
   AND r.tenant_id = 32 AND r.role_code = 'TEACHER'
   AND rp.school_id = 45 AND p.permission_key = 'exams.marks';
