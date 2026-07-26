-- ============================================================================
-- SCHOOL STATUS -> LOGIN GATE
--
-- Until now core.schools.status_id was a label and nothing else: it was written,
-- listed and filtered on, and read by no code path. Verified — sp_login_management
-- references core.schools ZERO times, and of the 65 procs that take p_school_id,
-- only 3 join core.schools at all. So "Closed" stopped nobody, and neither did
-- Delete (which only sets is_deleted on the schools row).
--
-- THE RULE NOW
--   Active        -> login allowed
--   Under Review  -> login allowed  (onboarding/audit; informational only)
--   Pending       -> blocked        (not activated yet)
--   Inactive      -> blocked
--   Suspended     -> blocked
--   Closed        -> blocked
--   ...and a DELETED school (schools.is_deleted) is blocked whatever its status.
--
-- Policy lives in DATA (allows_login + login_message), not a C# switch, so the
-- wording or the rule can be changed with an UPDATE. Same approach as
-- config.boards.requires_state.
--
-- status_code is the stable key. NEVER branch on `name` (renameable) or the id
-- (differs per environment).
--
-- Re-runnable. All 13 schools are currently Active, so nobody is locked out by
-- this migration itself.
-- ============================================================================

ALTER TABLE config.school_statuses
    ADD COLUMN IF NOT EXISTS status_code   varchar(30),
    ADD COLUMN IF NOT EXISTS allows_login  boolean NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS login_message varchar(250),
    ADD COLUMN IF NOT EXISTS display_order integer NOT NULL DEFAULT 0;

UPDATE config.school_statuses s
SET status_code   = p.code,
    allows_login  = p.allows,
    login_message = p.msg,
    display_order = p.ord
FROM (VALUES
    ('Active',       'ACTIVE',       TRUE,  NULL, 1),
    ('Under Review', 'UNDER_REVIEW', TRUE,  NULL, 2),
    ('Pending',      'PENDING',      FALSE,
        'This school has not been activated yet. Please contact EduCore support.', 3),
    ('Inactive',     'INACTIVE',     FALSE,
        'This school is currently inactive. Please contact EduCore support.', 4),
    ('Suspended',    'SUSPENDED',    FALSE,
        'Your school''s access has been suspended. Please contact EduCore support.', 5),
    ('Closed',       'CLOSED',       FALSE,
        'This school is closed and no longer accessible.', 6)
) AS p(nm, code, allows, msg, ord)
WHERE s.name = p.nm AND s.is_deleted = FALSE;

-- A status this migration doesn't know about (someone added their own): fail
-- CLOSED. An unknown status must not silently grant access.
UPDATE config.school_statuses
SET status_code   = 'CUSTOM_' || school_status_id,
    allows_login  = FALSE,
    login_message = COALESCE(login_message,
        'This school is not currently active. Please contact EduCore support.')
WHERE is_deleted = FALSE AND status_code IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_school_status_code
    ON config.school_statuses (status_code) WHERE is_deleted = FALSE;
