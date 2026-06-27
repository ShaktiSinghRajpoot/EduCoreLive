-- ============================================================================
-- user_phone_unique.sql
--
-- Enforce one phone number per login user, per tenant — mirroring the existing
-- email rule (core.users.uq_user_email on (tenant_id, email)).
--
-- Why: forgot-password OTP can be requested by mobile number. If two login
-- users in a tenant share a phone, the lookup (sp_password_reset REQUEST) is
-- ambiguous (LIMIT 1) and the code silently routes to the wrong account.
-- Login users live only in core.user_profiles (students/parents are elsewhere),
-- so this constraint never touches student records.
--
-- The app-side guard lives in core.sp_school_manage ('Admin phone already
-- exists.'); this index is the hard safety net.
-- ============================================================================

-- 1) Clean up any pre-existing in-tenant duplicate phones so the unique index
--    can be created. Keep the earliest profile (lowest user_profile_id) for
--    each (tenant_id, phone); blank the phone on the rest.
UPDATE core.user_profiles up
SET    phone = NULL,
       updated_at = NOW()
WHERE  up.is_deleted = FALSE
  AND  up.phone IS NOT NULL
  AND  EXISTS (
        SELECT 1
        FROM core.user_profiles dup
        WHERE dup.tenant_id = up.tenant_id
          AND dup.phone     = up.phone
          AND dup.is_deleted = FALSE
          AND dup.user_profile_id < up.user_profile_id
       );

-- 2) Unique phone per tenant for live (non-deleted) login users. Partial index
--    because phone is nullable (many users may have no phone) and rows are
--    soft-deleted.
CREATE UNIQUE INDEX IF NOT EXISTS uq_user_profile_phone
    ON core.user_profiles (tenant_id, phone)
    WHERE phone IS NOT NULL AND is_deleted = FALSE;
