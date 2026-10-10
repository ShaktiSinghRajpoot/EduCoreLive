-- ============================================================================
-- Payroll gets its own permission keys.
--
--   payroll.view    open Payroll & Salary, see salaries on the staff profile
--   payroll.manage  generate payroll, mark paid, add / void adjustments
--
-- Until now payroll sat behind staff.view (look) and staff.manage (write), so
-- anyone who could read the staff directory could read every salary. Here
-- BOTH new keys go only to roles that hold staff.manage today: nobody who
-- could run payroll loses it, and a staff.view-only role no longer sees pay.
-- School admins bypass permissions anyway.
--
-- Same pattern as fee_permissions_split.sql. Target DB: PostgreSQL. Safe to re-run.
-- ============================================================================

INSERT INTO config.permissions (permission_key, module_group, display_name, sort_order)
VALUES
    ('payroll.view',   'People', 'Payroll & Salary — View',   83),
    ('payroll.manage', 'People', 'Payroll & Salary — Manage', 84)
ON CONFLICT (permission_key) DO NOTHING;

-- Copy every live staff.manage grant to both payroll keys (once). The NOT
-- EXISTS looks at removed rows too: if a school has since taken payroll away
-- from a role on the Roles page (a soft-deleted row), a re-run leaves it away.
INSERT INTO config.role_permissions (tenant_id, school_id, role_id, permission_id, is_allowed, created_by, created_at)
SELECT rp.tenant_id, rp.school_id, rp.role_id, np.permission_id, rp.is_allowed, rp.created_by, CURRENT_TIMESTAMP
FROM config.role_permissions rp
JOIN config.permissions mp ON mp.permission_id = rp.permission_id AND mp.permission_key = 'staff.manage'
CROSS JOIN config.permissions np
WHERE np.permission_key IN ('payroll.view', 'payroll.manage')
  AND COALESCE(rp.is_deleted, FALSE) = FALSE
  AND NOT EXISTS (
        SELECT 1 FROM config.role_permissions x
        WHERE x.tenant_id IS NOT DISTINCT FROM rp.tenant_id
          AND x.school_id IS NOT DISTINCT FROM rp.school_id
          AND x.role_id = rp.role_id
          AND x.permission_id = np.permission_id);
