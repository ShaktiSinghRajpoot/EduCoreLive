-- ============================================================================
-- staff_hr_module.sql
--
-- HR / Staff foundation. Establishes the employee master and the 3-layer job
-- taxonomy, so payroll / attendance / leave can be built on top of it.
--
-- The three layers (deliberately separated from login ROLES):
--   1. Employee Type  -> small fixed bucket (Teaching / Non-Teaching / Transport
--                        / Support). Stored as core.staff.staff_type.
--   2. Department      -> configurable per-tenant list (config.departments).
--   3. Designation     -> configurable per-tenant list (config.designations),
--                        the actual job title (Driver, Peon, PGT Teacher...).
--
-- A bus driver / peon / guard is an EMPLOYEE (a core.staff row) but NOT a login
-- role. Only when a staff member needs to use the app is core.staff.user_id
-- set (pointing at a core.users login), and a role assigned via core.user_roles.
-- So staff (employees) is the big set; login users-with-roles is a subset.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) Department master  (configurable list; feeds the Department dropdown)
--    Tenant-scoped, mirroring config.document_types.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS config.departments (
    department_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id     integer NOT NULL,
    name          varchar(100) NOT NULL,
    sort_order    integer NOT NULL DEFAULT 0,
    is_active     boolean NOT NULL DEFAULT TRUE,
    created_by    integer NOT NULL DEFAULT 0,
    created_at    timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_by    integer,
    updated_at    timestamp,
    deleted_by    integer,
    deleted_at    timestamp,
    is_deleted    boolean NOT NULL DEFAULT FALSE,
    CONSTRAINT uq_department_name UNIQUE (tenant_id, name)
);
CREATE INDEX IF NOT EXISTS idx_departments_tenant ON config.departments (tenant_id);

-- ----------------------------------------------------------------------------
-- 2) Designation master (configurable list; feeds the Designation dropdown)
--    staff_type is the default Employee-Type bucket suggested for this title.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS config.designations (
    designation_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id      integer NOT NULL,
    name           varchar(100) NOT NULL,
    staff_type     varchar(20)  NOT NULL DEFAULT 'Non-Teaching',
    sort_order     integer NOT NULL DEFAULT 0,
    is_active      boolean NOT NULL DEFAULT TRUE,
    created_by     integer NOT NULL DEFAULT 0,
    created_at     timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_by     integer,
    updated_at     timestamp,
    deleted_by     integer,
    deleted_at     timestamp,
    is_deleted     boolean NOT NULL DEFAULT FALSE,
    CONSTRAINT uq_designation_name UNIQUE (tenant_id, name)
);
CREATE INDEX IF NOT EXISTS idx_designations_tenant ON config.designations (tenant_id);

-- ----------------------------------------------------------------------------
-- 3) Staff / Employee master  (operational, tenant+school scoped like students)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core.staff (
    staff_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       integer NOT NULL,
    school_id       integer NOT NULL,
    employee_code   varchar(50),

    -- personal
    full_name       varchar(150) NOT NULL,
    gender          varchar(10),
    dob             date,
    mobile          varchar(15),
    alt_mobile      varchar(15),
    email           varchar(120),
    blood_group     varchar(5),
    address         text,

    -- employment (3-layer taxonomy; department/designation are name snapshots
    -- of the chosen config.* rows, the way core.students snapshots class_name)
    staff_type      varchar(20),                 -- Employee Type bucket
    department      varchar(100),
    designation     varchar(100),
    joining_date    date,
    qualification   varchar(120),
    experience_years integer,
    status          varchar(20) NOT NULL DEFAULT 'Active',  -- Active / On Leave / Inactive

    -- payroll / bank
    monthly_salary  numeric(12,2),
    bank_account_no varchar(30),
    ifsc_code       varchar(15),
    pan             varchar(10),
    aadhaar         varchar(12),

    -- login linkage: set ONLY when this employee is given app access.
    -- NULL = employee with no login (driver, peon, guard...). Role lives in
    -- core.user_roles against this user_id.
    user_id         integer,

    -- audit
    is_active       boolean NOT NULL DEFAULT TRUE,
    created_by      integer NOT NULL DEFAULT 0,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_by      integer NOT NULL DEFAULT 0,
    updated_at      timestamptz NOT NULL DEFAULT now(),
    deleted_by      integer,
    deleted_at      timestamptz,
    is_deleted      boolean NOT NULL DEFAULT FALSE,

    CONSTRAINT fk_staff_user FOREIGN KEY (user_id) REFERENCES core.users (user_id)
);

CREATE INDEX IF NOT EXISTS idx_staff_school ON core.staff (tenant_id, school_id);
CREATE INDEX IF NOT EXISTS idx_staff_user   ON core.staff (user_id);

-- Employee code unique per school (when present, for live rows) — mirrors the
-- partial-unique pattern used for user phone.
CREATE UNIQUE INDEX IF NOT EXISTS uq_staff_employee_code
    ON core.staff (tenant_id, school_id, employee_code)
    WHERE employee_code IS NOT NULL AND is_deleted = FALSE;

-- One login user maps to at most one staff record.
CREATE UNIQUE INDEX IF NOT EXISTS uq_staff_user
    ON core.staff (user_id)
    WHERE user_id IS NOT NULL AND is_deleted = FALSE;

-- ============================================================================
-- SEED: standard Indian-school Departments & Designations for every real tenant
-- (tenant_id > 1). Schools edit these lists later; ON CONFLICT keeps re-runs
-- idempotent and never overwrites a school's customisations.
-- ============================================================================
INSERT INTO config.departments (tenant_id, name, sort_order)
SELECT t.tenant_id, d.name, d.ord
FROM   (SELECT DISTINCT tenant_id FROM config.roles WHERE tenant_id > 1) t
CROSS JOIN (VALUES
    ('Academics',       1),
    ('Administration',  2),
    ('Accounts',        3),
    ('Front Office',    4),
    ('Library',         5),
    ('Transport',       6),
    ('Housekeeping',    7),
    ('Security',        8),
    ('Sports',          9),
    ('IT / Computer Lab', 10)
) AS d(name, ord)
ON CONFLICT (tenant_id, name) DO NOTHING;

INSERT INTO config.designations (tenant_id, name, staff_type, sort_order)
SELECT t.tenant_id, g.name, g.staff_type, g.ord
FROM   (SELECT DISTINCT tenant_id FROM config.roles WHERE tenant_id > 1) t
CROSS JOIN (VALUES
    -- Teaching
    ('Principal',              'Teaching',      1),
    ('Vice Principal',         'Teaching',      2),
    ('Headmaster / Headmistress','Teaching',    3),
    ('Academic Coordinator',   'Teaching',      4),
    ('PGT Teacher',            'Teaching',      5),
    ('TGT Teacher',            'Teaching',      6),
    ('PRT Teacher',            'Teaching',      7),
    ('Pre-Primary Teacher',    'Teaching',      8),
    ('Sports / PT Instructor', 'Teaching',      9),
    ('Music Teacher',          'Teaching',     10),
    ('Art Teacher',            'Teaching',     11),
    -- Non-Teaching / office
    ('Office Administrator',   'Non-Teaching', 20),
    ('Accountant',             'Non-Teaching', 21),
    ('Cashier',                'Non-Teaching', 22),
    ('Receptionist',           'Non-Teaching', 23),
    ('Clerk',                  'Non-Teaching', 24),
    ('Data Entry Operator',    'Non-Teaching', 25),
    ('Computer Operator',      'Non-Teaching', 26),
    ('Librarian',              'Non-Teaching', 27),
    ('Lab Assistant',          'Non-Teaching', 28),
    ('HR Manager',             'Non-Teaching', 29),
    ('Nurse',                  'Non-Teaching', 30),
    -- Transport
    ('Driver',                 'Transport',    40),
    ('Conductor / Bus Attendant','Transport',  41),
    -- Support
    ('Peon',                   'Support',      50),
    ('Attendant / Helper',     'Support',      51),
    ('Sweeper / Cleaner',      'Support',      52),
    ('Gardener',               'Support',      53),
    ('Cook',                   'Support',      54),
    ('Security Guard',         'Support',      55)
) AS g(name, staff_type, ord)
ON CONFLICT (tenant_id, name) DO NOTHING;
