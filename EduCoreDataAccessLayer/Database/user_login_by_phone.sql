-- ============================================================================
-- LOGIN BY EMAIL **OR** PHONE
--
-- Until now core.sp_login_management ('GET_LOGIN_USER') matched on email only:
--     WHERE LOWER(u.email) = LOWER(p_email)
-- Parents and staff in India reliably remember a mobile number, not the address
-- someone typed for them at admission, so the sign-in box now accepts either.
--
-- core.sp_password_reset already worked this way (it matches
-- "LOWER(u.email) = LOWER(p_identifier) OR up.phone = p_identifier"), so this
-- brings login in line with a rule the app already used.
--
-- THE SAFETY PROBLEM
-- Login resolves an identifier with NO tenant filter, so a phone must identify
-- at most ONE signed-in-able user across the whole platform. The existing index
-- was per tenant:
--     uq_user_profile_phone (tenant_id, phone) WHERE phone IS NOT NULL AND NOT is_deleted
-- Two tenants could therefore hold the same number and login would silently pick
-- one (ORDER BY role_code). Exactly the hole that uq_user_email was leaving for
-- email — see user_email_unique.sql.
--
-- MATCHING RULE: compare DIGITS ONLY, last 10. So '+91 86016-33239',
-- '086016 33239' and '8601633239' are the same person, and an email identifier
-- can never be mistaken for a phone (an email yields far fewer than 10 digits).
-- Re-runnable.
-- ============================================================================

-- 1) Retire orphaned profiles before indexing.
--    core.user_profiles rows 10, 12 and 13 point at user_ids that do not exist
--    in core.users (leftovers from removed users). They can never sign in — login
--    INNER JOINs core.users — but row 12 still held a phone that collided with a
--    live user's, which would have blocked the unique index below.
--    Soft delete, not DELETE: keeps the row for forensics and takes it out of the
--    partial index, matching the soft-delete convention used everywhere else.
UPDATE core.user_profiles up
SET is_deleted = TRUE,
    is_active  = FALSE,
    updated_at = NOW()
WHERE up.is_deleted = FALSE
  AND NOT EXISTS (SELECT 1 FROM core.users u WHERE u.user_id = up.user_id);

-- 2) One phone = one signed-in-able user, platform-wide, ignoring formatting.
--    Replaces the per-tenant index, which was both too weak for a global login
--    lookup and too strong (a deactivated profile burned the number for its tenant).
DROP INDEX IF EXISTS core.uq_user_profile_phone;

CREATE UNIQUE INDEX IF NOT EXISTS uq_user_phone_active
    ON core.user_profiles ((right(regexp_replace(phone, '\D', '', 'g'), 10)))
    WHERE phone IS NOT NULL
      AND regexp_replace(phone, '\D', '', 'g') <> ''
      AND is_deleted = FALSE
      AND is_active  = TRUE;

-- 3) Shared guard, mirroring core.fn_user_email_taken, so every screen that
--    captures a login phone asks the same question the index enforces.
CREATE OR REPLACE FUNCTION core.fn_user_phone_taken(
    p_phone            character varying,
    p_exclude_user_id  integer DEFAULT NULL)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM core.user_profiles up
        WHERE up.phone IS NOT NULL
          AND length(regexp_replace(p_phone, '\D', '', 'g')) >= 10
          AND right(regexp_replace(up.phone, '\D', '', 'g'), 10)
              = right(regexp_replace(p_phone, '\D', '', 'g'), 10)
          AND up.is_deleted = FALSE
          AND up.is_active  = TRUE
          AND (p_exclude_user_id IS NULL OR up.user_id <> p_exclude_user_id)
    );
$$;

COMMENT ON FUNCTION core.fn_user_phone_taken(character varying, integer) IS
    'TRUE when the phone already belongs to an active login user (global, digits-only, last 10). Mirrors core.fn_user_email_taken; backed by uq_user_phone_active.';
