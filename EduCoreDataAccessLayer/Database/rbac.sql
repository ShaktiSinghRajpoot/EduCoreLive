-- ============================================================================
-- rbac.sql  —  Dynamic RBAC: the permission CATALOG (the missing keystone)
--
-- config.role_permissions already exists and maps role_id -> permission_id, but
-- there was never a config.permissions table for permission_id to reference.
-- This script creates that catalog, clears the stray/invalid rows, and seeds the
-- app's capability list.
--
-- DESIGN: the catalog is GLOBAL (no tenant_id). It is the set of things the app
-- can do, defined by developers — identical for every tenant. Which ROLE (a
-- tenant-scoped config.roles row) holds which permission is the tenant-scoped
-- part, and that lives in config.role_permissions.
--
-- Granularity: two permissions per feature — "<feature>.view" and
-- "<feature>.manage" (manage implies create/edit/delete). A couple of features
-- are single-level (rbac = manage only, reports = view only).
-- ============================================================================

-- ---------------------------------------------------------------- catalog table
CREATE TABLE IF NOT EXISTS config.permissions
(
    permission_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    permission_key varchar(100) NOT NULL,
    module_group   varchar(50)  NOT NULL,
    display_name   varchar(100) NOT NULL,
    sort_order     integer      NOT NULL DEFAULT 0,
    is_active      boolean      NOT NULL DEFAULT TRUE,
    created_at     timestamp without time zone NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_permissions_key
    ON config.permissions (permission_key);

-- ------------------------------------------------------ remove stray/invalid rows
-- The 4 pre-existing config.role_permissions rows are platform-scoped test data
-- (tenant_id = 1) that referenced permission ids before this catalog existed and
-- mismatched their role's tenant. Tenant 1 (SUPER_ADMIN) is governed by the
-- admin-bypass at runtime and never needs explicit grants, so clearing tenant 1
-- here is safe and starts the mapping table clean.
DELETE FROM config.role_permissions WHERE tenant_id = 1;

-- ------------------------------------------------------------------- seed catalog
-- Idempotent: re-running adds only missing keys. One row per (feature, level),
-- skipping the levels that don't apply to rbac/reports.
INSERT INTO config.permissions (permission_key, module_group, display_name, sort_order)
SELECT f.feat || '.' || lv.lvl,
       f.grp,
       f.label || ' — ' || initcap(lv.lvl),
       f.sort * 10 + lv.ord
FROM (VALUES
    -- feature key,        module group,      display label,          sort
    ('enquiry',            'Academic',        'Admission Enquiry',      1),
    ('registration',       'Academic',        'Registrations',          2),
    ('students',           'Academic',        'Students',               3),
    ('academics',          'Academic',        'Academics',              4),
    ('attendance',         'Academic',        'Attendance',             5),
    ('exams',              'Academic',        'Examinations',           6),
    ('fees',               'Finance',         'Fees & Collection',      7),
    ('staff',              'People',          'Human Resources',        8),
    ('transport',          'People',          'Transport',              9),
    ('inventory',          'People',          'Inventory / Store',     10),
    ('settings',           'Administration',  'School Settings',       11),
    ('admission_workflow', 'Administration',  'Admission Workflow',    12),
    ('reports',            'Administration',  'Reports & Analytics',   13),
    ('rbac',               'Administration',  'Users & Roles',         14)
) AS f(feat, grp, label, sort)
CROSS JOIN (VALUES ('view', 1), ('manage', 2)) AS lv(lvl, ord)
WHERE NOT (f.feat = 'rbac'    AND lv.lvl = 'view')    -- rbac: manage only
  AND NOT (f.feat = 'reports' AND lv.lvl = 'manage')  -- reports: view only
ON CONFLICT (permission_key) DO NOTHING;
